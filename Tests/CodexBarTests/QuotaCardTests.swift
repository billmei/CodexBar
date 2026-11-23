import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
import WidgetKit
@testable import CodexBarWidget

@MainActor
struct QuotaCardTests {
    private let now = Date(timeIntervalSince1970: 1_782_000_000)

    @Test
    func `card identifiers round trip and reject unknown values`() {
        let ids = ["claude", "codex", "antigravity", "antigravity/gemini", "antigravity/claude-gpt"]
        #expect(ids.compactMap { QuotaCardSelection(id: $0)?.id } == ids)
        #expect(["", "nope", "antigravity/nope", "antigravity/", "/gemini"].allSatisfy {
            QuotaCardSelection(id: $0) == nil
        })
        #expect(QuotaCardSelection(id: "antigravity/claude-gpt")?.displayName == "Antigravity · Claude / GPT")
        #expect(QuotaCardSelection(id: "claude")?.displayName == "Claude")
    }

    @Test
    func `picker offers one card per provider and splits antigravity families`() {
        let ids = QuotaCardQuery.suggestedEntities(in: self.snapshot()).map(\.id)
        #expect(ids == ["claude", "codex", "antigravity/gemini", "antigravity/claude-gpt"])
        #expect(QuotaCardQuery.suggestedEntities(in: nil).isEmpty)
    }

    @Test
    func `picker keeps the combined antigravity card for windows without a known family`() {
        var entry = self.antigravity()
        entry.usageRows?.append(self.antigravityRow("grok-5h", "Grok 5-hour", used: 30, minutes: 300))
        let legacy = WidgetSnapshot.ProviderEntry(
            provider: .antigravity,
            updatedAt: self.now,
            primary: self.window(used: 10, minutes: 300),
            secondary: nil)
        #expect(QuotaCardSelection.available(in: self.snapshot(entries: [entry])).map(\.id) ==
            ["antigravity", "antigravity/gemini", "antigravity/claude-gpt"])
        #expect(QuotaCardSelection.available(in: self.snapshot(entries: [legacy])).map(\.id) == ["antigravity"])
    }

    @Test
    func `picker skips disabled providers and providers without quota windows`() {
        let empty = WidgetSnapshot.ProviderEntry(provider: .claude, updatedAt: self.now, primary: nil, secondary: nil)
        let snapshot = WidgetSnapshot(
            entries: [empty, self.codex()],
            enabledProviders: [UsageProvider.claude.instanceID],
            generatedAt: self.now)
        #expect(QuotaCardSelection.available(in: snapshot).isEmpty)
    }

    @Test
    func `cards use the floating widget labels`() throws {
        for provider in [UsageProvider.claude, .codex] {
            let card = try #require(QuotaCard(snapshot: self.snapshot(), selection: .init(provider: provider)))
            #expect(card.rows.map(\.label) == ["5-Hour", "Week"])
            #expect(card.rows.allSatisfy { $0.resetsAt != nil })
        }
    }

    @Test
    func `only generic lane names become cadence labels`() throws {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: self.now,
            primary: nil,
            secondary: nil,
            usageRows: [
                .init(id: "session", title: "Session", percentLeft: 40, window: self.window(used: 60, minutes: 1440)),
                .init(id: "spark", title: "Spark weekly", percentLeft: 50, window: self.window(used: 50, minutes: 300)),
            ])
        let card = try #require(QuotaCard(
            snapshot: self.snapshot(entries: [entry]),
            selection: .init(provider: .codex)))
        #expect(card.rows.map(\.label) == ["Session", "Spark weekly"])
    }

    @Test
    func `family cards read their own lanes and stay available at zero usage`() throws {
        let gemini = try #require(QuotaCard(
            snapshot: self.snapshot(),
            selection: .init(provider: .antigravity, family: .gemini)))
        let claude = try #require(QuotaCard(
            snapshot: self.snapshot(),
            selection: .init(provider: .antigravity, family: .claudeGPT)))
        #expect(gemini.rows.map(\.label) == ["5-Hour", "Week"])
        #expect(gemini.rows.map(\.remainingPercent) == [82, 71])
        #expect(claude.rows.map(\.label) == ["5-Hour", "Week"])
        #expect(claude.rows.map(\.remainingPercent) == [100, 100])
        #expect(claude.rows.allSatisfy { $0.resetsAt != nil })
    }

    @Test
    func `idle lanes do not reach other widget tiles`() {
        let lanes = WidgetTileLane.lanes(for: self.antigravity())
        #expect(lanes.map(\.id) == ["antigravity-quota-summary-gemini-weekly", "antigravity-quota-summary-gemini-5h"])
    }

    @Test
    func `versioned gemini quotas keep their own name after the shared windows`() throws {
        var entry = self.antigravity()
        entry.usageRows?.insert(
            self.antigravityRow("gemini-4-argon-5h", "Gemini 4 Argon 5-hour", used: 50, minutes: 300), at: 0)
        let card = try #require(QuotaCard(
            snapshot: self.snapshot(entries: [entry]),
            selection: .init(provider: .antigravity, family: .gemini)))
        #expect(card.rows.map(\.label) == ["5-Hour", "Week"])
        #expect(card.rows.map(\.remainingPercent) == [82, 71])
        #expect(card.overflowCount == 1)
    }

    @Test
    func `saved card never falls back to another provider`() {
        let claudeOnly = self.snapshot(entries: [self.claude()])
        let pinned = QuotaCardTimelineProvider.makeEntry(
            snapshot: claudeOnly, selection: .init(provider: .codex), now: self.now)
        #expect(pinned.selection?.provider == .codex)
        #expect(pinned.card == nil)
        let unconfigured = QuotaCardTimelineProvider.makeEntry(snapshot: claudeOnly, selection: nil, now: self.now)
        #expect(unconfigured.selection?.provider == .claude)
        #expect(unconfigured.card != nil)
    }

    @Test
    func `older snapshots without idle rows still decode`() throws {
        let data = try WidgetSnapshotStore.encodedData(self.snapshot(entries: [self.claude()]))
        #expect(String(data: data, encoding: .utf8)?.contains("idleUsageRows") == false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(WidgetSnapshot.self, from: data).entries.first?.idleUsageRows == nil)
        let current = try WidgetSnapshotStore.encodedData(self.snapshot())
        let antigravity = try decoder.decode(WidgetSnapshot.self, from: current).entries
            .first { $0.provider == UsageProvider.antigravity.instanceID }
        #expect(antigravity?.idleUsageRows?.count == 2)
    }

    @Test(arguments: [
        (4 * 3600 + 52 * 60, "4h 52m"),
        (5 * 86400 + 22 * 3600, "5d 22h"),
        (5 * 3600, "5h"),
        (7 * 86400, "7d"),
        (90, "2m"),
        (1, "1m"),
        (3599.5, "1h"),
        (0, "Reset due"),
        (-60, "Reset due"),
    ] as [(TimeInterval, String)])
    func `countdowns match the floating widget format`(interval: TimeInterval, expected: String) {
        WidgetLocalizationOverride.$language.withValue("en") {
            #expect(QuotaCardCountdown.text(until: self.now.addingTimeInterval(interval), now: self.now) == expected)
            #expect(QuotaCardCountdown.text(until: nil, now: self.now) == "—")
        }
    }

    @Test
    func `timeline advances countdowns each minute until the next reload`() {
        let timeline = QuotaCardTimelineProvider.makeTimeline(
            snapshot: self.snapshot(), selection: .init(provider: .claude), now: self.now)
        #expect(timeline.entries.count == 30)
        #expect(timeline.entries.first?.date == self.now)
        #expect(timeline.entries.last?.date == self.now.addingTimeInterval(29 * 60))
        let empty = QuotaCardTimelineProvider.makeTimeline(
            snapshot: self.snapshot(entries: []), selection: .init(provider: .claude), now: self.now)
        #expect(empty.entries.count == 1)
    }

    @Test
    func `red bars start at ninety percent used`() throws {
        for (used, isLow) in [(89.0, false), (90.0, true), (100.0, true)] {
            let entry = WidgetSnapshot.ProviderEntry(
                provider: .claude, updatedAt: self.now, primary: self.window(used: used, minutes: 300), secondary: nil)
            let card = try #require(QuotaCard(
                snapshot: self.snapshot(entries: [entry]), selection: .init(provider: .claude)))
            #expect(card.rows.map(\.isLow) == [isLow])
        }
    }

    @Test(arguments: ["en", "de", "ar"])
    func `card renders at the small widget size`(language: String) throws {
        try WidgetLocalizationOverride.$language.withValue(language) {
            for selection in QuotaCardSelection.available(in: self.snapshot()) {
                let entry = QuotaCardTimelineProvider.makeEntry(
                    snapshot: self.snapshot(), selection: selection, now: self.now)
                for mode in [WidgetRenderingMode.fullColor, .accented] {
                    let name = selection.id.replacingOccurrences(of: "/", with: "-")
                    try self.render(
                        entry,
                        mode: mode,
                        isRightToLeft: language == "ar",
                        name: "\(name)-\(language)-\(mode == .fullColor ? "color" : "accented")")
                }
            }
        }
    }

    @Test
    func `stale overflowing card fits without moving its content out of the tile`() throws {
        var claude = self.claude(updatedAt: self.now.addingTimeInterval(-2 * 86400))
        claude.usageRows?.append(.init(id: "tertiary", title: "Sonnet", percentLeft: 40))
        let entry = QuotaCardTimelineProvider.makeEntry(
            snapshot: self.snapshot(entries: [claude]), selection: .init(provider: .claude), now: self.now)
        #expect(entry.card?.overflowCount == 1)
        let accent = QuotaCardPalette.accent(for: .claude)
        let natural = NSHostingView(rootView: QuotaCardTile(entry: entry, accent: accent)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 155))
        #expect(natural.fittingSize.height <= 155)
        try self.render(entry, mode: .fullColor, isRightToLeft: false, name: "stale-overflow")
    }

    private func render(
        _ entry: QuotaCardEntry,
        mode: WidgetRenderingMode,
        isRightToLeft: Bool,
        name: String) throws
    {
        let accent = QuotaCardPalette.accent(for: entry.selection?.provider)
        let view = QuotaCardTile(entry: entry, accent: accent)
            .environment(\.widgetRenderingModeOverride, mode)
            .environment(\.layoutDirection, isRightToLeft ? .rightToLeft : .leftToRight)
            .environment(\.colorScheme, .dark)
            .frame(width: 155, height: 155)
            .background(QuotaCardBackground(accent: accent))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 310)
        #expect(image.height == 310)
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_WIDGET_HEADLINE_PROOF_DIR"] else { return }
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("quota-card-\(name).png"))
    }

    // MARK: - Fixtures

    private func snapshot(entries: [WidgetSnapshot.ProviderEntry]? = nil) -> WidgetSnapshot {
        WidgetSnapshot(
            entries: entries ?? [self.claude(), self.codex(), self.antigravity()],
            generatedAt: self.now)
    }

    private func window(used: Double, minutes: Int, resetsIn: TimeInterval = 3600 * 2 + 60 * 7) -> RateWindow {
        RateWindow(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: self.now.addingTimeInterval(resetsIn),
            resetDescription: nil)
    }

    private func claude(updatedAt: Date? = nil) -> WidgetSnapshot.ProviderEntry {
        WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: updatedAt ?? self.now,
            primary: self.window(used: 0, minutes: 300, resetsIn: 4 * 3600 + 52 * 60),
            secondary: self.window(used: 26, minutes: 10080, resetsIn: 5 * 86400 + 22 * 3600),
            usageRows: [
                .init(id: "primary", title: "Session", percentLeft: 100),
                .init(id: "secondary", title: "Weekly", percentLeft: 74),
            ])
    }

    private func codex() -> WidgetSnapshot.ProviderEntry {
        let session = self.window(used: 93, minutes: 300)
        let weekly = self.window(used: 37, minutes: 10080, resetsIn: 5 * 86400 + 10 * 3600)
        return WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: self.now,
            primary: session,
            secondary: weekly,
            usageRows: [
                .init(id: "session", title: "Session", percentLeft: 7, window: session),
                .init(id: "weekly", title: "Weekly", percentLeft: 63, window: weekly),
            ])
    }

    private func antigravity() -> WidgetSnapshot.ProviderEntry {
        WidgetSnapshot.ProviderEntry(
            provider: .antigravity,
            updatedAt: self.now,
            primary: nil,
            secondary: nil,
            usageRows: [
                self.antigravityRow("gemini-weekly", "Gemini weekly", used: 29, minutes: 10080),
                self.antigravityRow("gemini-5h", "Gemini 5-hour", used: 18, minutes: 300),
            ],
            idleUsageRows: [
                self.antigravityRow("3p-5h", "Claude/GPT 5-hour", used: 0, minutes: 300),
                self.antigravityRow("3p-weekly", "Claude/GPT weekly", used: 0, minutes: 10080),
            ])
    }

    private func antigravityRow(
        _ bucket: String,
        _ title: String,
        used: Double,
        minutes: Int) -> WidgetSnapshot.WidgetUsageRowSnapshot
    {
        .init(
            id: "antigravity-quota-summary-" + bucket,
            title: title,
            percentLeft: 100 - used,
            window: self.window(used: used, minutes: minutes, resetsIn: TimeInterval(minutes * 60)))
    }
}
