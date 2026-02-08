import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuTests {
    private func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.menuRefreshEnabled = false
    }

    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create UserDefaults suite '\(suite)'")
        }
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    @Test
    func remembersProviderWhenMenuOpens() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: false)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let claudeMenu = controller.makeMenu()
        controller.menuWillOpen(claudeMenu)
        #expect(controller.lastMenuProvider == .claude)

        // No providers enabled: fall back to Codex.
        for provider in UsageProvider.allCases {
            if let meta = registry.metadata[provider] {
                settings.setProviderEnabled(provider: provider, metadata: meta, enabled: false)
            }
        }
        let unmappedMenu = controller.makeMenu()
        controller.menuWillOpen(unmappedMenu)
        #expect(controller.lastMenuProvider == .codex)
    }

    @Test
    func menuOpenRefreshTriggersUserInitiatedThenBackground() async {
        let oldMenuCards = StatusItemController.menuCardRenderingEnabled
        let oldMenuRefresh = StatusItemController.menuRefreshEnabled
        let oldDelay = StatusItemController._menuOpenRefreshDelayOverride
        defer {
            StatusItemController.menuCardRenderingEnabled = oldMenuCards
            StatusItemController.menuRefreshEnabled = oldMenuRefresh
            StatusItemController._menuOpenRefreshDelayOverride = oldDelay
        }

        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.menuRefreshEnabled = true
        // Give the immediate refresh task time to run so the delayed "stale/no snapshot" retry doesn't race it.
        StatusItemController._menuOpenRefreshDelayOverride = .milliseconds(800)

        let suite = "StatusMenuTests-MenuRefreshTriggers-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite '\(suite)'")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        // Avoid background provider-detection work during this test; it can schedule refreshes.
        defaults.set(true, forKey: "providerDetectionCompleted")
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.providerDetectionCompleted = true
        // Ensure menu-open refresh is user-initiated even when Claude isn't the visible provider.
        settings.selectedMenuProvider = .codex

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let meta = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: meta,
                enabled: provider == .codex || provider == .claude)
        }

        let fetcher = UsageFetcher()

        actor TriggerRecorder {
            private var enabled = false
            private var triggers: [ProviderFetchTrigger] = []
            private var totalCalls = 0

            func startRecording() {
                self.enabled = true
                self.triggers.removeAll()
            }

            func noteCall(_ trigger: ProviderFetchTrigger) {
                self.totalCalls += 1
                guard self.enabled else { return }
                self.triggers.append(trigger)
            }

            func snapshot() -> [ProviderFetchTrigger] {
                self.triggers
            }

            func total() -> Int {
                self.totalCalls
            }
        }

        let recorder = TriggerRecorder()

        #if DEBUG
        let override: @Sendable (Bool, ProviderFetchTrigger) async -> Void = { _, trigger in
            await recorder.noteCall(trigger)
        }

        await UsageStore.$refreshOverrideForTesting.withValue(override) {
            let store = UsageStore(
                fetcher: fetcher,
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)
            let controller = StatusItemController(
                store: store,
                settings: settings,
                account: fetcher.loadAccountInfo(),
                updater: DisabledUpdaterController(),
                preferencesSelection: PreferencesSelection(),
                statusBar: self.makeStatusBarForTesting())

            // UsageStore always schedules an initial background refresh from init.
            // Wait for it to run before recording, so the first recorded trigger is menu-open userInitiated.
            let initialDeadline = Date().addingTimeInterval(2.0)
            while Date() < initialDeadline {
                if await recorder.total() >= 1 { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            let settleDeadline = Date().addingTimeInterval(2.0)
            while store.isRefreshing, Date() < settleDeadline {
                try? await Task.sleep(for: .milliseconds(5))
            }

            await recorder.startRecording()

            // Force the "stale/no snapshot" condition so the delayed retry runs.
            store._setSnapshotForTesting(nil, provider: .codex)
            store._setErrorForTesting(nil, provider: .codex)

            let menu = controller.makeMenu()
            let baselineCount = await recorder.snapshot().count
            controller.menuWillOpen(menu)

            // First menu-open refresh must be user-initiated (even if other background refresh calls happen nearby).
            let firstDeadline = Date().addingTimeInterval(2.0)
            var userInitiatedIndex: Int?
            while Date() < firstDeadline {
                let snapshot = await recorder.snapshot()
                let newTriggers = Array(snapshot.dropFirst(baselineCount))
                if let index = newTriggers.firstIndex(of: .userInitiated) {
                    userInitiatedIndex = index
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let userInitiatedIndex else {
                let snapshot = await recorder.snapshot()
                let newTriggers = Array(snapshot.dropFirst(baselineCount))
                Issue.record("Expected a menu-open refresh call with trigger=userInitiated, got none.")
                Issue.record("newTriggers=\(newTriggers)")
                return
            }

            // If the delayed retry fires (stale/no snapshot), it must be background to avoid multiple prompts.
            let secondDeadline = Date().addingTimeInterval(2.5)
            while Date() < secondDeadline {
                let snapshot = await recorder.snapshot()
                let newTriggers = Array(snapshot.dropFirst(baselineCount))
                if newTriggers.count >= userInitiatedIndex + 2 { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let maybeSecond = await recorder.snapshot()
            let newTriggers = Array(maybeSecond.dropFirst(baselineCount))
            if newTriggers.count >= userInitiatedIndex + 2 {
                #expect(newTriggers[userInitiatedIndex + 1] == .background)
            }
        }
        #else
        Issue.record("Test requires DEBUG TaskLocal overrides")
        #endif
    }

    @Test
    func providerToggleUpdatesStatusItemVisibility() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.providerDetectionCompleted = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        #expect(controller.statusItems[.claude]?.isVisible == true)

        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        }
        controller.handleProviderConfigChange(reason: "test")
        #expect(controller.statusItems[.claude]?.isVisible == false)
    }

    @Test
    func hidesOpenAIWebSubmenusWhenNoHistory() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let titles = Set(menu.items.map(\.title))
        #expect(!titles.contains("Credits history"))
        #expect(!titles.contains("Usage breakdown"))
    }

    @Test
    func showsOpenAIWebSubmenusWhenHistoryExists() throws {
        self.disableMenuCardsForTesting()
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusMenuTests-history"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2025
        components.month = 12
        components.day = 18
        let date = try #require(components.date)

        let events = [CreditEvent(date: date, service: "CLI", creditsUsed: 1)]
        let breakdown = OpenAIDashboardSnapshot.makeDailyBreakdown(from: events, maxDays: 30)
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: events,
            dailyBreakdown: breakdown,
            usageBreakdown: breakdown,
            creditsPurchaseURL: nil,
            updatedAt: Date())

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let usageItem = menu.items.first { ($0.representedObject as? String) == "menuCardUsage" }
        let creditsItem = menu.items.first { ($0.representedObject as? String) == "menuCardCredits" }
        #expect(
            usageItem?.submenu?.items
                .contains { ($0.representedObject as? String) == "usageBreakdownChart" } == true)
        #expect(
            creditsItem?.submenu?.items
                .contains { ($0.representedObject as? String) == "creditsHistoryChart" } == true)
    }

    @Test
    func showsCreditsBeforeCostInCodexMenuCardSections() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.costUsageEnabled = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.credits = CreditsSnapshot(remaining: 100, events: [], updatedAt: Date())
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 0.12,
            last30DaysTokens: 123,
            last30DaysCostUSD: 1.23,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2025-12-23",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 123,
                    costUSD: 1.23,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date()), provider: .codex)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let ids = menu.items.compactMap { $0.representedObject as? String }
        let creditsIndex = try #require(ids.firstIndex(of: "menuCardCredits"))
        let costIndex = try #require(ids.firstIndex(of: "menuCardCost"))
        #expect(creditsIndex < costIndex)
    }

    @Test
    func showsExtraUsageForClaudeWhenUsingMenuCardSections() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.costUsageEnabled = true
        settings.claudeWebExtrasEnabled = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: false)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: "user@example.com",
            accountOrganization: nil,
            loginMethod: "web")
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: "Resets soon"),
            secondary: nil,
            tertiary: nil,
            providerCost: ProviderCostSnapshot(
                used: 0,
                limit: 2000,
                currencyCode: "EUR",
                period: "Monthly",
                resetsAt: nil,
                updatedAt: Date()),
            updatedAt: Date(),
            identity: identity)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 123,
            sessionCostUSD: 0.12,
            last30DaysTokens: 123,
            last30DaysCostUSD: 1.23,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2025-12-23",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 123,
                    costUSD: 1.23,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date()), provider: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let ids = menu.items.compactMap { $0.representedObject as? String }
        #expect(ids.contains("menuCardExtraUsage"))
    }

    @Test
    func showsVertexCostWhenUsageErrorPresent() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .vertexai
        settings.costUsageEnabled = true

        let registry = ProviderRegistry.shared
        if let vertexMeta = registry.metadata[.vertexai] {
            settings.setProviderEnabled(provider: .vertexai, metadata: vertexMeta, enabled: true)
        }
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: false)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setErrorForTesting("No Vertex AI usage data found for the current project.", provider: .vertexai)
        store._setTokenSnapshotForTesting(CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 0.01,
            last30DaysTokens: 100,
            last30DaysCostUSD: 1.0,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2025-12-23",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 100,
                    costUSD: 1.0,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: Date()), provider: .vertexai)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let ids = menu.items.compactMap { $0.representedObject as? String }
        #expect(ids.contains("menuCardCost"))
    }
}
