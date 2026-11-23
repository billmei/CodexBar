import CodexBarCore
import SwiftUI
import WidgetKit

struct QuotaCardWidgetView: View {
    let entry: QuotaCardEntry

    var body: some View {
        let accent = QuotaCardPalette.accent(for: self.entry.selection?.provider)
        QuotaCardTile(entry: self.entry, accent: accent)
            .environment(\.widgetUsageShowsUsed, self.entry.snapshot.usageBarsShowUsed)
            .containerBackground(for: .widget) {
                QuotaCardBackground(accent: accent)
            }
    }
}

/// The floating widget's card colors. The card keeps its dark surface in both system appearances.
enum QuotaCardPalette {
    static let surface = Color(quotaCardHex: 0x151317)
    static let track = Color(quotaCardHex: 0x212025)
    static let text = Color(quotaCardHex: 0xF5F1F8)
    static let heading = Color(quotaCardHex: 0xC1B8C7)
    static let secondary = Color(quotaCardHex: 0xB5ADBE)
    static let low = Color(quotaCardHex: 0xFB5B60)

    /// Provider-specific by design: these accents match the floating widget's card for the same provider.
    private static let accents: [UsageProvider: UInt32] = [
        .claude: 0xE58360,
        .codex: 0x29D898,
        .antigravity: 0xA782FF,
    ]

    static func accent(for provider: UsageProvider?) -> Color {
        guard let provider else { return Color(quotaCardHex: 0x8DA4EE) }
        // A color the user picked in CodexBar always wins over the built-in card palette.
        if ProviderAccentColors.sharedOverride(for: provider.instanceID) == nil,
           let hex = self.accents[provider]
        {
            return Color(quotaCardHex: hex)
        }
        return WidgetColors.color(for: provider.instanceID)
    }
}

extension Color {
    fileprivate init(quotaCardHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

struct QuotaCardBackground: View {
    let accent: Color

    var body: some View {
        QuotaCardPalette.surface.overlay(self.accent.opacity(0.06))
    }
}

struct QuotaCardTile: View {
    @Environment(\.widgetUsageShowsUsed) private var showsUsed
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.widgetRenderingModeOverride) private var renderingModeOverride

    let entry: QuotaCardEntry
    let accent: Color

    private var fullColor: Bool {
        (self.renderingModeOverride ?? self.renderingMode) == .fullColor
    }

    var body: some View {
        VStack(spacing: 0) {
            self.heading
            if let card = self.entry.card {
                Spacer(minLength: 2)
                VStack(spacing: 8) {
                    ForEach(card.rows) { row in
                        QuotaCardRowView(
                            row: row,
                            now: self.entry.date,
                            accent: self.accent,
                            showsUsed: self.showsUsed,
                            fullColor: self.fullColor)
                    }
                }
                Spacer(minLength: 2)
                self.footer(card)
            } else {
                Spacer(minLength: 2)
                Text(self.emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(self.secondary)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var secondary: Color {
        self.fullColor ? QuotaCardPalette.secondary : .primary.opacity(0.75)
    }

    /// Both lines are always reserved so cards placed side by side keep their bars level.
    private var heading: some View {
        VStack(spacing: 0) {
            Text(self.entry.selection?.providerName ?? "CodexBar")
                .font(.system(size: 10.5, weight: .bold))
                .kerning(1.9)
                .foregroundStyle(self.fullColor ? QuotaCardPalette.heading : .primary)
                .frame(height: 14)
            Text(self.entry.selection?.familyName ?? " ")
                .font(.system(size: 9, weight: .bold))
                .kerning(0.7)
                .foregroundStyle(self.secondary)
                .frame(height: 12)
                .accessibilityHidden(self.entry.selection?.familyName == nil)
        }
        .textCase(.uppercase)
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }

    @ViewBuilder
    private func footer(_ card: QuotaCard) -> some View {
        let isStale = WidgetFreshness.isStale(card.updatedAt, now: self.entry.date)
        if isStale || card.overflowCount > 0 {
            HStack(spacing: 6) {
                if isStale {
                    FreshnessLabel(updatedAt: card.updatedAt)
                        .multilineTextAlignment(.center)
                }
                if card.overflowCount > 0 {
                    Text(W("+%@ more", String(card.overflowCount)))
                        .foregroundStyle(self.secondary)
                        .fixedSize()
                }
            }
            .font(.system(size: 9))
            .lineLimit(1)
            .frame(height: 11)
        }
    }

    private var emptyMessage: String {
        guard let selection = self.entry.selection else {
            return W("Enable a provider in CodexBar → Settings → Providers.")
        }
        return WidgetEmptyStateCopy.message(provider: selection.provider, snapshot: self.entry.snapshot)
    }
}

private struct QuotaCardRowView: View {
    let row: QuotaCard.Row
    let now: Date
    let accent: Color
    let showsUsed: Bool
    let fullColor: Bool

    var body: some View {
        let percent = WidgetUsageDisplay.percent(
            fromRemaining: self.row.remainingPercent,
            showUsed: self.showsUsed)
        let countdown = QuotaCardCountdown.text(until: self.row.resetsAt, now: self.now)
        let secondary: Color = self.fullColor ? QuotaCardPalette.secondary : .primary.opacity(0.75)
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(WidgetFormat.percent(percent))
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(self.fullColor ? QuotaCardPalette.text : .primary)
                    if percent != nil {
                        Text(self.showsUsed ? W("used") : W("left"))
                            .font(.system(size: 9))
                            .foregroundStyle(secondary)
                    }
                }
                .fixedSize()
                Text(self.row.label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(secondary)
                    .minimumScaleFactor(0.8)
            }
            .lineLimit(1)
            .frame(height: 15)

            QuotaCardBar(
                percent: percent,
                color: self.row.isLow ? QuotaCardPalette.low : self.accent,
                trackTint: self.accent,
                fullColor: self.fullColor)
                .overlay {
                    Text(countdown)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(self.fullColor ? Color.white : .primary)
                        .shadow(color: .black.opacity(self.fullColor ? 0.9 : 0), radius: 1.5, y: 1)
                        .shadow(color: .black.opacity(self.fullColor ? 0.6 : 0), radius: 2.5)
                        .padding(.horizontal, 6)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(W("%@ %@", self.row.label, WidgetLaneCopy.caption(
            title: WidgetFormat.percent(percent),
            showUsed: self.showsUsed))))
        .accessibilityValue(Text(W("Reset: %@", countdown)))
    }
}

private struct QuotaCardBar: View {
    let percent: Double?
    let color: Color
    let trackTint: Color
    let fullColor: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if self.fullColor {
                    QuotaCardPalette.track.overlay(self.trackTint.opacity(0.09))
                } else {
                    Color.primary.opacity(0.12)
                }
                // Outside full color WidgetKit keeps only luminance, so a solid fill would swallow the countdown.
                shape
                    .fill(self.fullColor ? self.color : .primary.opacity(0.35))
                    .frame(width: QuotaBar.fillFraction(self.percent) * proxy.size.width)
            }
        }
        .clipShape(shape)
        .frame(height: 24)
    }
}
