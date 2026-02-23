import CodexBarCore
import Foundation

struct BurnRateSample: Sendable {
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double?
    let timestamp: Date
}

extension UsageStore {
    func burnRate(for provider: UsageProvider) -> BurnRate? {
        self.burnRates[provider]
    }

    func burnCostRateUSDPerHour(for provider: UsageProvider) -> Double? {
        self.burnCostRatesUSDPerHour[provider]
    }

    func estimatedBurnCostRateUSDPerHour(for provider: UsageProvider, burnRate: BurnRate) -> Double? {
        if let measured = self.burnCostRatesUSDPerHour[provider] {
            return measured
        }

        switch provider {
        case .codex:
            // Fallback estimate for unknown model pricing: GPT-5 base rates.
            let inputCostPerToken = 1.25e-6
            let outputCostPerToken = 1e-5
            let usdPerMinute = burnRate.inputRate * inputCostPerToken + burnRate.outputRate * outputCostPerToken
            return usdPerMinute * 60
        case .zai, .claude, .gemini, .antigravity, .cursor, .opencode, .factory, .copilot, .minimax, .kiro, .kimi,
             .kimik2, .augment, .jetbrains, .amp, .ollama, .synthetic, .openrouter, .warp, .vertexai:
            return nil
        }
    }

    func refreshBurnRateTierMappings() {
        let thresholds = self.settings.burnRateThresholds
        for (provider, burnRate) in self.burnRates {
            let tier = BurnTier.tier(for: burnRate.tokensPerMinute, thresholds: thresholds)
            guard tier != burnRate.tier else { continue }
            let remapped = BurnRate(
                tokensPerMinute: burnRate.tokensPerMinute,
                inputRate: burnRate.inputRate,
                outputRate: burnRate.outputRate,
                tier: tier,
                sampleInterval: burnRate.sampleInterval,
                timestamp: burnRate.timestamp)
            self.burnRates[provider] = remapped
            self.applyBurnRate(remapped, to: provider)
        }
    }

    func clearBurnRateState(for provider: UsageProvider) {
        self.burnRates.removeValue(forKey: provider)
        self.burnCostRatesUSDPerHour.removeValue(forKey: provider)
        self.burnRateSamples.removeValue(forKey: provider)
        if let snapshot = self.snapshots[provider], snapshot.burnRate != nil {
            self.snapshots[provider] = snapshot.withBurnRate(nil)
        }
    }

    func refreshBurnRates() async {
        for provider in UsageProvider.allCases {
            guard self.supportsBurnRate(provider) else {
                self.clearBurnRateState(for: provider)
                continue
            }
            guard self.isEnabled(provider) else {
                self.clearBurnRateState(for: provider)
                continue
            }
            await self.refreshBurnRate(provider)
        }
    }

    private func refreshBurnRate(_ provider: UsageProvider) async {
        guard !self.burnRateRefreshInFlight.contains(provider) else { return }
        guard !self.tokenRefreshInFlight.contains(provider) else { return }
        self.burnRateRefreshInFlight.insert(provider)
        defer { self.burnRateRefreshInFlight.remove(provider) }

        do {
            let snapshot = try await self.costUsageFetcher.loadTokenSnapshot(
                provider: provider,
                now: Date(),
                forceRefresh: false,
                allowVertexClaudeFallback: !self.isEnabled(.claude),
                refreshMinIntervalSeconds: self.burnRateSamplingInterval)

            guard let sample = Self.makeBurnRateSample(from: snapshot, timestamp: Date()) else {
                self.clearBurnRateState(for: provider)
                return
            }
            self.recordBurnRateSample(sample, for: provider)
        } catch {
            // Keep the previous burn-rate snapshot if we have one; transient scanner failures are common.
            if self.burnRates[provider] == nil {
                self.clearBurnRateState(for: provider)
            }
        }
    }

    private func recordBurnRateSample(_ sample: BurnRateSample, for provider: UsageProvider) {
        var samples = self.burnRateSamples[provider] ?? []
        if let last = samples.last,
           sample.totalTokens < last.totalTokens ||
           sample.inputTokens < last.inputTokens ||
           sample.outputTokens < last.outputTokens
        {
            samples.removeAll(keepingCapacity: true)
        }

        samples.append(sample)
        let cutoff = sample.timestamp.addingTimeInterval(-self.burnRateWindowInterval)
        samples.removeAll { $0.timestamp < cutoff }
        self.burnRateSamples[provider] = samples

        guard let newest = samples.last,
              let oldest = samples.first,
              newest.timestamp > oldest.timestamp
        else {
            let idle = BurnRate(
                tokensPerMinute: 0,
                inputRate: 0,
                outputRate: 0,
                tier: .idle,
                sampleInterval: 0,
                timestamp: sample.timestamp)
            self.burnRates[provider] = idle
            self.burnCostRatesUSDPerHour.removeValue(forKey: provider)
            self.applyBurnRate(idle, to: provider)
            return
        }

        let interval = newest.timestamp.timeIntervalSince(oldest.timestamp)
        guard interval > 0 else { return }

        let deltaTotal = max(0, newest.totalTokens - oldest.totalTokens)
        let deltaInput = max(0, newest.inputTokens - oldest.inputTokens)
        let deltaOutput = max(0, newest.outputTokens - oldest.outputTokens)

        let tokensPerMinute = Double(deltaTotal) / interval * 60
        let inputRate = Double(deltaInput) / interval * 60
        let outputRate = Double(deltaOutput) / interval * 60
        let tier = BurnTier.tier(for: tokensPerMinute, thresholds: self.settings.burnRateThresholds)
        let burnRate = BurnRate(
            tokensPerMinute: tokensPerMinute,
            inputRate: inputRate,
            outputRate: outputRate,
            tier: tier,
            sampleInterval: interval,
            timestamp: newest.timestamp)

        self.burnRates[provider] = burnRate
        if let newestCost = newest.costUSD, let oldestCost = oldest.costUSD, newestCost >= oldestCost {
            let deltaCost = newestCost - oldestCost
            self.burnCostRatesUSDPerHour[provider] = deltaCost / interval * 3600
        } else {
            self.burnCostRatesUSDPerHour.removeValue(forKey: provider)
        }
        self.applyBurnRate(burnRate, to: provider)
    }

    private func applyBurnRate(_ burnRate: BurnRate, to provider: UsageProvider) {
        guard let snapshot = self.snapshots[provider] else { return }
        self.snapshots[provider] = snapshot.withBurnRate(burnRate)
    }

    private func supportsBurnRate(_ provider: UsageProvider) -> Bool {
        // First end-to-end rollout: Codex/OpenAI only.
        provider == .codex
    }

    private static func makeBurnRateSample(from snapshot: CostUsageTokenSnapshot, timestamp: Date) -> BurnRateSample? {
        guard let latest = self.latestDailyEntry(from: snapshot) else { return nil }
        let input = max(0, latest.inputTokens ?? 0)
            + max(0, latest.cacheReadTokens ?? 0)
            + max(0, latest.cacheCreationTokens ?? 0)
        let output = max(0, latest.outputTokens ?? 0)
        let total = max(snapshot.sessionTokens ?? 0, latest.totalTokens ?? (input + output))
        let cost = latest.costUSD ?? snapshot.sessionCostUSD

        return BurnRateSample(
            totalTokens: total,
            inputTokens: input,
            outputTokens: output,
            costUSD: cost,
            timestamp: timestamp)
    }

    private static func latestDailyEntry(from snapshot: CostUsageTokenSnapshot) -> CostUsageDailyReport.Entry? {
        snapshot.daily.max(by: { lhs, rhs in lhs.date < rhs.date })
    }
}
