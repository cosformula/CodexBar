import SwiftUI

@MainActor
struct DisplayPane: View {
    @Bindable var settings: SettingsStore
    private static let burnThresholdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimum = 1
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(contentSpacing: 12) {
                    Text("Menu bar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    PreferenceToggleRow(
                        title: "Merge Icons",
                        subtitle: "Use a single menu bar icon with a provider switcher.",
                        binding: self.$settings.mergeIcons)
                    PreferenceToggleRow(
                        title: "Switcher shows icons",
                        subtitle: "Show provider icons in the switcher (otherwise show a weekly progress line).",
                        binding: self.$settings.switcherShowsIcons)
                        .disabled(!self.settings.mergeIcons)
                        .opacity(self.settings.mergeIcons ? 1 : 0.5)
                    PreferenceToggleRow(
                        title: "Show most-used provider",
                        subtitle: "Menu bar auto-shows the provider closest to its rate limit.",
                        binding: self.$settings.menuBarShowsHighestUsage)
                        .disabled(!self.settings.mergeIcons)
                        .opacity(self.settings.mergeIcons ? 1 : 0.5)
                    PreferenceToggleRow(
                        title: "Menu bar shows percent",
                        subtitle: "Replace critter bars with provider branding icons and a percentage.",
                        binding: self.$settings.menuBarShowsBrandIconWithPercent)
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Display mode")
                                .font(.body)
                            Text("Choose what to show in the menu bar (Pace shows usage vs. expected).")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Picker("Display mode", selection: self.$settings.menuBarDisplayMode) {
                            ForEach(MenuBarDisplayMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200)
                    }
                    .disabled(!self.settings.menuBarShowsBrandIconWithPercent)
                    .opacity(self.settings.menuBarShowsBrandIconWithPercent ? 1 : 0.5)
                }

                Divider()

                SettingsSection(contentSpacing: 10) {
                    Text("Burn rate icon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    PreferenceToggleRow(
                        title: "Hide icon when idle",
                        subtitle: "Hide the burn-rate flame when no tokens are being consumed.",
                        binding: self.$settings.burnRateHideWhenIdle)
                    self.burnThresholdRow(
                        title: "Medium starts at",
                        subtitle: "Low is any activity below this level.",
                        value: self.$settings.burnRateMediumThreshold)
                    self.burnThresholdRow(
                        title: "High starts at",
                        subtitle: "Medium runs until this threshold.",
                        value: self.$settings.burnRateHighThreshold)
                    self.burnThresholdRow(
                        title: "Burning starts at",
                        subtitle: "High runs until this threshold.",
                        value: self.$settings.burnRateBurningThreshold)
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text("Menu content")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    PreferenceToggleRow(
                        title: "Show usage as used",
                        subtitle: "Progress bars fill as you consume quota (instead of showing remaining).",
                        binding: self.$settings.usageBarsShowUsed)
                    PreferenceToggleRow(
                        title: "Show reset time as clock",
                        subtitle: "Display reset times as absolute clock values instead of countdowns.",
                        binding: self.$settings.resetTimesShowAbsolute)
                    PreferenceToggleRow(
                        title: "Show credits + extra usage",
                        subtitle: "Show Codex Credits and Claude Extra usage sections in the menu.",
                        binding: self.$settings.showOptionalCreditsAndExtraUsage)
                    PreferenceToggleRow(
                        title: "Show all token accounts",
                        subtitle: "Stack token accounts in the menu (otherwise show an account switcher bar).",
                        binding: self.$settings.showAllTokenAccountsInMenu)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func burnThresholdRow(title: String, subtitle: String, value: Binding<Double>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            HStack(alignment: .center, spacing: 6) {
                TextField("", value: value, formatter: Self.burnThresholdFormatter)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                Text("tok/min")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
