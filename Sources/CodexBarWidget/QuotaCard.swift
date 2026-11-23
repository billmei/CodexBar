import CodexBarCore
import Foundation

/// The card one Quota Card widget is pinned to: a provider, or one of its separately metered model families.
struct QuotaCardSelection: Hashable {
    typealias Family = AntigravityQuotaFamilyVisibility.KnownFamily

    let provider: UsageProvider
    var family: Family?

    init(provider: UsageProvider, family: Family? = nil) {
        self.provider = provider
        self.family = family
    }

    /// Saved in widget configurations; keep the format stable.
    init?(id: String) {
        let parts = id.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let provider = parts.first.flatMap(UsageProvider.init(rawValue:)) else { return nil }
        if parts.count == 2 {
            guard let family = Family(rawValue: parts[1]) else { return nil }
            self.init(provider: provider, family: family)
        } else {
            self.init(provider: provider)
        }
    }

    var id: String {
        self.family.map { "\(self.provider.rawValue)/\($0.rawValue)" } ?? self.provider.rawValue
    }

    var providerName: String {
        ProviderDefaults.metadata[self.provider]?.displayName ?? self.provider.rawValue.capitalized
    }

    var familyName: String? {
        // Provider-specific by design: Antigravity quota families carry their own card names.
        switch self.family {
        case .gemini: "Gemini"
        case .claudeGPT: "Claude / GPT"
        case nil: nil
        }
    }

    var displayName: String {
        self.familyName.map { "\(self.providerName) · \($0)" } ?? self.providerName
    }

    /// Cards with quota windows in the snapshot, in provider order. A provider that meters model families
    /// separately offers one card per family; the combined card remains only when some window has no family.
    static func available(in snapshot: WidgetSnapshot) -> [QuotaCardSelection] {
        snapshot.enabledProviders.flatMap { instanceID -> [QuotaCardSelection] in
            guard let provider = instanceID.firstPartyProvider,
                  let entry = snapshot.entries.first(where: { $0.provider == instanceID })
            else { return [] }
            let families = (entry.usageRows ?? []) + (entry.idleUsageRows ?? [])
            let familyByRow = families.map { Self.family(id: $0.id, title: $0.title) }
            let cards = Family.allCases
                .filter { familyByRow.contains($0) }
                .map { QuotaCardSelection(provider: provider, family: $0) }
            let visibleRows = WidgetUsageRow.rows(for: entry, applyBindingCap: false)
            let hasUngrouped = visibleRows.contains { Self.family(id: $0.id, title: $0.title) == nil }
            return (hasUngrouped ? [QuotaCardSelection(provider: provider)] : []) + cards
        }
    }

    static func family(id: String, title: String) -> Family? {
        AntigravityQuotaFamilyVisibility.knownFamily(windowID: id, title: title)
    }
}

/// Everything a Quota Card draws, resolved for one moment.
struct QuotaCard: Equatable {
    struct Row: Equatable, Identifiable {
        let id: String
        let label: String
        let remainingPercent: Double?
        let resetsAt: Date?

        /// The floating widget turns a bar red once 90% of its window is used.
        var isLow: Bool {
            QuotaSeverity.isLow(remaining: self.remainingPercent)
        }
    }

    static let maximumRows = 2

    let selection: QuotaCardSelection
    let rows: [Row]
    let overflowCount: Int
    let updatedAt: Date

    init?(snapshot: WidgetSnapshot, selection: QuotaCardSelection) {
        let instanceID = selection.provider.instanceID
        guard snapshot.enabledProviders.contains(instanceID),
              let entry = snapshot.entries.first(where: { $0.provider == instanceID })
        else { return nil }
        let rows = Self.rows(for: entry, family: selection.family)
        guard !rows.isEmpty else { return nil }
        self.selection = selection
        self.rows = Array(rows.prefix(Self.maximumRows))
        self.overflowCount = max(0, rows.count - Self.maximumRows)
        self.updatedAt = entry.updatedAt
    }

    private static func rows(
        for entry: WidgetSnapshot.ProviderEntry,
        family: QuotaCardSelection.Family?) -> [Row]
    {
        var entry = entry
        if family != nil {
            // A pinned family stays useful at zero usage, so restore lanes the other tiles hide.
            entry.usageRows = (entry.usageRows ?? []) + (entry.idleUsageRows ?? [])
        }
        let windows = Dictionary(
            (entry.usageRows ?? []).compactMap { row in row.window.map { (row.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        let rows = WidgetUsageRow.rows(for: entry, applyBindingCap: false)
        guard let family else {
            return rows.map { row in
                let window = windows[row.id] ?? WidgetUsageRow.slotWindow(for: row.id, entry: entry)
                return Self.row(row, cadence: Cadence(title: row.title, windowMinutes: window?.windowMinutes))
            }
        }

        let members = rows.filter { QuotaCardSelection.family(id: $0.id, title: $0.title) == family }
            .map { ($0, Cadence.shared(id: $0.id, title: $0.title, family: family)) }
        // The shared 5-hour and weekly windows lead; separately named quotas such as "Gemini 4 Argon" follow.
        let ordered = Cadence.allCases.flatMap { cadence in members.filter { $0.1 == cadence } }
            + members.filter { $0.1 == nil }
        return ordered.map { Self.row($0.0, cadence: $0.1) }
    }

    private static func row(_ row: WidgetUsageRow, cadence: Cadence?) -> Row {
        Row(
            id: row.id,
            label: cadence?.label ?? W(row.title),
            remainingPercent: row.percentLeft.flatMap { $0.isFinite ? $0 : nil },
            resetsAt: row.resetsAt)
    }

    private enum Cadence: CaseIterable {
        case fiveHour
        case weekly

        var label: String {
            switch self {
            case .fiveHour: W("5-Hour")
            case .weekly: W("Week")
            }
        }

        /// Only generic lane names are replaced; a provider's own quota name always survives.
        init?(title: String, windowMinutes: Int?) {
            switch (title, windowMinutes) {
            case ("Session", 300?): self = .fiveHour
            case ("Weekly", _): self = .weekly
            default: return nil
            }
        }

        /// The window's cadence when it is the family's shared lane, or nil for a separately named quota.
        static func shared(id: String, title: String, family: QuotaCardSelection.Family) -> Cadence? {
            let id = id.lowercased()
            let title = title.lowercased()
            for (cadence, titleSuffix, idSuffixes) in [
                (Cadence.fiveHour, " 5-hour", ["-5h", "-5-hour", "-session", "-five-hour"]),
                (Cadence.weekly, " weekly", ["-weekly"]),
            ] {
                let idSuffix = idSuffixes.first { id.hasSuffix($0) }
                guard title.hasSuffix(titleSuffix) || idSuffix != nil else { continue }
                // Provider-specific by design: Antigravity meters versioned Gemini quotas separately.
                guard family == .gemini else { return cadence }
                let isShared = title == family.rawValue + titleSuffix
                    || idSuffix.map { id.hasSuffix("summary-" + family.rawValue + $0) } == true
                return isShared ? cadence : nil
            }
            return nil
        }
    }
}

/// Two-unit countdowns in the floating widget's format: `5d 22h`, `4h 52m`, `12m`.
enum QuotaCardCountdown {
    static func text(until resetsAt: Date?, now: Date) -> String {
        guard let resetsAt else { return WidgetFormat.unavailable }
        let interval = resetsAt.timeIntervalSince(now)
        guard interval.isFinite else { return WidgetFormat.unavailable }
        guard interval > 0 else { return W("Reset due") }
        let total = Int(min(interval / 60, 60 * 24 * 10000).rounded(.up))
        let days = total / (24 * 60)
        let hours = (total / 60) % 24
        let minutes = total % 60
        if days > 0 {
            return hours > 0 ? W("%@d %@h", String(days), String(hours)) : W("%@d", String(days))
        }
        if hours > 0 {
            return minutes > 0 ? W("%@h %@m", String(hours), String(minutes)) : W("%@h", String(hours))
        }
        return W("%@m", String(minutes))
    }
}

/// Minute entries keep the countdowns moving between snapshot reloads; they carry the same data.
enum QuotaCardTimeline {
    static let step: TimeInterval = 60

    static func dates(from now: Date, until refresh: Date, card: QuotaCard?) -> [Date] {
        guard let card, card.rows.contains(where: { ($0.resetsAt ?? .distantPast) > now }) else { return [now] }
        return Array(stride(from: now, to: max(refresh, now.addingTimeInterval(1)), by: self.step))
    }
}
