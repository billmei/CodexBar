import AppIntents
import CodexBarCore
import SwiftUI
import WidgetKit

struct CodexBarQuotaCardWidget: Widget {
    private let kind = "CodexBarQuotaCardWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: self.kind,
            intent: QuotaCardSelectionIntent.self,
            provider: QuotaCardTimelineProvider())
        { entry in
            QuotaCardWidgetView(entry: entry)
        }
        .configurationDisplayName(Text(W("CodexBar Quota Card")))
        .description(Text(W("One provider's quota bars and reset countdowns.")))
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct QuotaCardSelectionIntent: AppIntent, WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Provider"
    static let description = IntentDescription("Select the provider to display in the widget.")

    @Parameter(title: "Provider")
    var card: QuotaCardEntity?
}

struct QuotaCardEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")
    static let defaultQuery = QuotaCardQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(QuotaCardSelection(id: self.id)?.displayName ?? self.id)")
    }
}

struct QuotaCardQuery: EntityQuery {
    /// Resolve every well-formed pin, so a provider that is temporarily unavailable keeps its widget.
    func entities(for identifiers: [String]) async throws -> [QuotaCardEntity] {
        identifiers.filter { QuotaCardSelection(id: $0) != nil }.map { QuotaCardEntity(id: $0) }
    }

    func suggestedEntities() async throws -> [QuotaCardEntity] {
        Self.suggestedEntities(in: WidgetSnapshotStore.load())
    }

    func defaultResult() async -> QuotaCardEntity? {
        Self.suggestedEntities(in: WidgetSnapshotStore.load()).first
    }

    static func suggestedEntities(in snapshot: WidgetSnapshot?) -> [QuotaCardEntity] {
        snapshot.map { QuotaCardSelection.available(in: $0).map { QuotaCardEntity(id: $0.id) } } ?? []
    }
}

struct QuotaCardEntry: TimelineEntry {
    let date: Date
    let selection: QuotaCardSelection?
    let card: QuotaCard?
    let snapshot: WidgetSnapshot
}

struct QuotaCardTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in _: Context) -> QuotaCardEntry {
        Self.makeEntry(snapshot: WidgetPreviewData.snapshot(), selection: nil, now: Date())
    }

    func snapshot(for configuration: QuotaCardSelectionIntent, in context: Context) async -> QuotaCardEntry {
        let selection = Self.selection(for: configuration)
        let entry = Self.makeEntry(snapshot: Self.load(selection), selection: selection, now: Date())
        guard context.isPreview, entry.card == nil else { return entry }
        return self.placeholder(in: context)
    }

    func timeline(
        for configuration: QuotaCardSelectionIntent,
        in _: Context) async -> Timeline<QuotaCardEntry>
    {
        let selection = Self.selection(for: configuration)
        return Self.makeTimeline(snapshot: Self.load(selection), selection: selection, now: Date())
    }

    private static func selection(for configuration: QuotaCardSelectionIntent) -> QuotaCardSelection? {
        configuration.card.flatMap { QuotaCardSelection(id: $0.id) }
    }

    private static func load(_ selection: QuotaCardSelection?) -> WidgetSnapshot {
        WidgetSnapshotStore.load(provider: selection?.provider) ?? WidgetPreviewData.emptySnapshot()
    }

    /// Only a widget that was never configured falls back to the first card; a saved pin never changes provider.
    static func makeEntry(snapshot: WidgetSnapshot, selection: QuotaCardSelection?, now: Date) -> QuotaCardEntry {
        let selection = selection ?? QuotaCardSelection.available(in: snapshot).first
        return QuotaCardEntry(
            date: now,
            selection: selection,
            card: selection.flatMap { QuotaCard(snapshot: snapshot, selection: $0) },
            snapshot: snapshot)
    }

    static func makeTimeline(
        snapshot: WidgetSnapshot,
        selection: QuotaCardSelection?,
        now: Date) -> Timeline<QuotaCardEntry>
    {
        let entry = self.makeEntry(snapshot: snapshot, selection: selection, now: now)
        let refresh = entry.selection.map {
            BurnDownRefreshSchedule.nextRefresh(snapshot: snapshot, provider: $0.provider, now: now)
        } ?? now.addingTimeInterval(30 * 60)
        let entries = QuotaCardTimeline.dates(from: now, until: refresh, card: entry.card).map { date in
            QuotaCardEntry(date: date, selection: entry.selection, card: entry.card, snapshot: snapshot)
        }
        return Timeline(entries: entries, policy: .after(refresh))
    }
}
