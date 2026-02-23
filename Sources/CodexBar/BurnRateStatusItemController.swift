import AppKit
import CodexBarCore
import Observation

@MainActor
final class BurnRateStatusItemController: NSObject, NSMenuDelegate {
    private struct ProviderBurnEntry {
        let provider: UsageProvider
        let burnRate: BurnRate
    }

    private enum TrendDirection {
        case rising
        case steady
        case falling

        var label: String {
            switch self {
            case .rising:
                return "rising"
            case .steady:
                return "steady"
            case .falling:
                return "falling"
            }
        }
    }

    private enum MenuTextStyle {
        case headline
        case primary
        case secondary
    }

    private static let flameSymbolName = "flame.fill"
    private static let sparklineLevels: [Character] = Array("._-:=+*#%@")

    private let store: UsageStore
    private let settings: SettingsStore
    private let statusItem: NSStatusItem
    private let menu: NSMenu

    init(store: UsageStore, settings: SettingsStore, statusBar: NSStatusBar = .system) {
        self.store = store
        self.settings = settings
        self.statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        super.init()
        self.configureStatusItem()
        self.observeStoreChanges()
        self.observeSettingsChanges()
        self.refreshStatusItem()
    }

    private func configureStatusItem() {
        self.menu.autoenablesItems = false
        self.menu.delegate = self
        self.statusItem.menu = self.menu
        self.statusItem.button?.imageScaling = .scaleProportionallyDown
        self.statusItem.button?.imagePosition = .imageOnly
        self.statusItem.button?.title = ""
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        self.rebuildMenu()
    }

    private func observeStoreChanges() {
        withObservationTracking {
            _ = self.store.menuObservationToken
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeStoreChanges()
                self.refreshStatusItem()
            }
        }
    }

    private func observeSettingsChanges() {
        withObservationTracking {
            _ = self.settings.burnRateHideWhenIdle
            _ = self.settings.configRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSettingsChanges()
                self.refreshStatusItem()
            }
        }
    }

    private func refreshStatusItem() {
        let enabledProviders = self.store.enabledProviders()
        guard !enabledProviders.isEmpty else {
            self.statusItem.isVisible = false
            self.menu.removeAllItems()
            return
        }

        let entries = self.providerBurnEntries(providers: enabledProviders)
        let tier = self.highestTier(in: entries.map(\.burnRate.tier))
        let isIdle = tier == .idle
        let shouldHide = isIdle && self.settings.burnRateHideWhenIdle
        self.statusItem.isVisible = !shouldHide
        guard !shouldHide else { return }

        if let image = self.iconImage(for: tier) {
            self.statusItem.button?.image = image
        }
        self.statusItem.button?.toolTip = "Burn rate (\(tier.label))"
        self.rebuildMenu()
    }

    private func providerBurnEntries(providers: [UsageProvider]) -> [ProviderBurnEntry] {
        providers.compactMap { provider in
            guard let burnRate = self.store.burnRate(for: provider) else { return nil }
            return ProviderBurnEntry(provider: provider, burnRate: burnRate)
        }
        .sorted { lhs, rhs in
            let lhsRank = self.tierRank(lhs.burnRate.tier)
            let rhsRank = self.tierRank(rhs.burnRate.tier)
            if lhsRank != rhsRank {
                return lhsRank > rhsRank
            }
            return lhs.provider.rawValue < rhs.provider.rawValue
        }
    }

    private func highestTier(in tiers: [BurnTier]) -> BurnTier {
        guard let strongest = tiers.max(by: { self.tierRank($0) < self.tierRank($1) }) else {
            return .idle
        }
        return strongest
    }

    private func tierRank(_ tier: BurnTier) -> Int {
        switch tier {
        case .idle:
            return 0
        case .low:
            return 1
        case .medium:
            return 2
        case .high:
            return 3
        case .burning:
            return 4
        }
    }

    private func iconImage(for tier: BurnTier) -> NSImage? {
        let symbol: NSImage? = if #available(macOS 15, *) {
            NSImage(
                systemSymbolName: Self.flameSymbolName,
                variableValue: self.variableValue(for: tier),
                accessibilityDescription: "Burn rate")
        } else {
            NSImage(systemSymbolName: Self.flameSymbolName, accessibilityDescription: "Burn rate")
        }
        guard let symbol else {
            return nil
        }
        let baseConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: self.iconColor(for: tier))
        let configuration = baseConfig.applying(colorConfig)
        let image = symbol.withSymbolConfiguration(configuration) ?? symbol
        image.isTemplate = false
        return image
    }

    private func variableValue(for tier: BurnTier) -> Double {
        switch tier {
        case .idle:
            return 0
        case .low:
            return 0.25
        case .medium:
            return 0.5
        case .high:
            return 0.75
        case .burning:
            return 1.0
        }
    }

    private func iconColor(for tier: BurnTier) -> NSColor {
        switch tier {
        case .idle:
            return .systemGray
        case .low:
            return NSColor(srgbRed: 0.18, green: 0.70, blue: 0.68, alpha: 1)
        case .medium:
            return NSColor(srgbRed: 0.70, green: 0.78, blue: 0.24, alpha: 1)
        case .high:
            return NSColor(srgbRed: 0.94, green: 0.57, blue: 0.19, alpha: 1)
        case .burning:
            return NSColor(srgbRed: 0.90, green: 0.24, blue: 0.20, alpha: 1)
        }
    }

    private func rebuildMenu() {
        self.menu.removeAllItems()

        let enabledProviders = self.store.enabledProviders()
        let entries = self.providerBurnEntries(providers: enabledProviders)
        guard !entries.isEmpty else {
            self.menu.addItem(self.menuItem("Burn rate data is collecting...", style: .secondary))
            return
        }

        for (index, entry) in entries.enumerated() {
            let providerName = self.store.metadata(for: entry.provider).displayName
            self.menu.addItem(self.menuItem(providerName, style: .headline))

            let tokenRate = UsageFormatter.tokenCountString(Int(entry.burnRate.tokensPerMinute.rounded()))
            self.menu.addItem(self.menuItem("Burn: \(tokenRate)/min", style: .primary))

            let costText: String = {
                guard let usdPerHour = self.store.estimatedBurnCostRateUSDPerHour(
                    for: entry.provider,
                    burnRate: entry.burnRate)
                else {
                    return "n/a"
                }
                return "\(UsageFormatter.usdString(usdPerHour))/hr"
            }()
            self.menu.addItem(self.menuItem("Cost rate: \(costText)", style: .secondary))
            self.menu.addItem(self.menuItem("Tier: \(entry.burnRate.tier.label)", style: .secondary))
            self.menu.addItem(self.menuItem("Trend: \(self.trendLine(for: entry.provider))", style: .secondary))

            if index < entries.count - 1 {
                self.menu.addItem(.separator())
            }
        }
    }

    private func menuItem(_ text: String, style: MenuTextStyle) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false

        switch style {
        case .headline:
            item.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)])
        case .primary:
            break
        case .secondary:
            item.attributedTitle = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
        }
        return item
    }

    private func trendLine(for provider: UsageProvider) -> String {
        let points = self.trendPoints(for: provider, limit: 12)
        guard !points.isEmpty else { return "collecting data" }
        let sparkline = self.sparkline(for: points)
        let direction = self.trendDirection(for: points).label
        return "\(sparkline) \(direction)"
    }

    private func trendPoints(for provider: UsageProvider, limit: Int) -> [Double] {
        guard let samples = self.store.burnRateSamples[provider], samples.count > 1 else { return [] }
        var rates: [Double] = []
        rates.reserveCapacity(samples.count - 1)

        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            let interval = current.timestamp.timeIntervalSince(previous.timestamp)
            guard interval > 0 else { continue }
            let delta = max(0, current.totalTokens - previous.totalTokens)
            let rate = Double(delta) / interval * 60
            rates.append(rate)
        }

        guard rates.count > limit else { return rates }
        return Array(rates.suffix(limit))
    }

    private func sparkline(for points: [Double]) -> String {
        let peak = max(points.max() ?? 0, 1)
        let levelCount = Double(Self.sparklineLevels.count - 1)
        let chars = points.map { value -> Character in
            let normalized = max(0, min(value / peak, 1))
            let level = Int((normalized * levelCount).rounded())
            return Self.sparklineLevels[level]
        }
        return String(chars)
    }

    private func trendDirection(for points: [Double]) -> TrendDirection {
        guard points.count >= 4 else { return .steady }
        let split = max(1, points.count / 2)
        let older = Array(points.prefix(split))
        let newer = Array(points.suffix(points.count - split))
        let olderAverage = self.average(of: older)
        let newerAverage = self.average(of: newer)
        let delta = newerAverage - olderAverage
        let threshold = max(50, olderAverage * 0.2)

        if delta > threshold { return .rising }
        if delta < -threshold { return .falling }
        return .steady
    }

    private func average(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
