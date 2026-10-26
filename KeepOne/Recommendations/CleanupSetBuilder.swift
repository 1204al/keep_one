import Foundation

/// One screen of the guided cleanup: up to `CleanupSetBuilder.maxSize` related items that the user
/// clears with one tap. Items in a set are always connected — the same kind of suggestion, from the
/// same day (look-alikes) or the same month (everything else) — so a set can be judged at a glance.
struct CleanupSet: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, CaseIterable {
        case duplicates, similar, screenshots, blurry, temporary, accidentalVideos, videoCopies
        case screenRecordings, savedImages, documents, largeVideos

        var title: String {
            switch self {
            case .duplicates: "Identical copies"
            case .similar: "Similar shots"
            case .screenshots: "Screenshots"
            case .blurry: "Blurry & failed shots"
            case .temporary: "Temporary photos"
            case .accidentalVideos: "Accidental videos"
            case .videoCopies: "Repeated videos"
            case .screenRecordings: "Screen recordings"
            case .savedImages: "Saved & shared images"
            case .documents: "Notes & documents"
            case .largeVideos: "Large videos"
            }
        }

        /// One sentence: why these are here and what is pre-selected.
        var explanation: String {
            switch self {
            case .duplicates: "Exact copies. The starred copy in each group stays."
            case .similar: "Near-identical shots. The starred one in each group is the best and stays."
            case .videoCopies: "Copies and repeated takes. The starred video in each group stays."
            case .screenshots: "Older screenshots. Ones that may still matter aren't selected."
            case .blurry: "Blurry, very dark or accidental shots."
            case .temporary: "Receipts, parking spots, tickets and labels you probably don't need anymore."
            case .accidentalVideos: "Very short or accidental clips."
            case .screenRecordings: "Older screen recordings."
            case .savedImages: "Images saved from apps, chats and the web."
            case .documents: "Notes and documents. Nothing is selected — pick what you don't need."
            case .largeVideos: "Your largest videos. Nothing is selected — pick what you don't need."
            }
        }

        var symbol: String {
            switch self {
            case .duplicates: CleanupCategory.exactDuplicates.symbol
            case .similar: CleanupCategory.similarPhotos.symbol
            case .videoCopies: CleanupCategory.duplicateVideos.symbol
            case .screenshots: CleanupCategory.screenshots.symbol
            case .blurry: CleanupCategory.blurryFailed.symbol
            case .temporary: "pin"
            case .accidentalVideos: CleanupCategory.accidentalVideos.symbol
            case .screenRecordings: CleanupCategory.screenRecordings.symbol
            case .savedImages: CleanupCategory.memes.symbol
            case .documents: CleanupCategory.documents.symbol
            case .largeVideos: CleanupCategory.largeVideos.symbol
            }
        }

        /// Look-alike sets show one row per group, best shot first.
        var isGrouped: Bool { self == .duplicates || self == .similar || self == .videoCopies }

        static func of(_ category: CleanupCategory) -> Kind {
            switch category {
            case .exactDuplicates: .duplicates
            case .similarPhotos: .similar
            case .duplicateVideos: .videoCopies
            case .screenshots: .screenshots
            case .blurryFailed: .blurry
            case .accidentalVideos: .accidentalVideos
            case .screenRecordings: .screenRecordings
            case .memes: .savedImages
            case .documents: .documents
            case .largeVideos: .largeVideos
            case .receipts, .parking, .productLabels, .priceTags, .ticketsQR, .packages, .menusSigns, .screens, .otherReferences:
                .temporary
            }
        }
    }

    /// One row of a look-alike set (a group), or the whole set for other kinds.
    struct Row: Hashable, Sendable {
        /// Display order: keepers first.
        var itemIDs: [String]
        /// Shown starred ("best"); kept unless the user selects them.
        var keeperIDs: Set<String>
    }

    let id: String
    let kind: Kind
    let rows: [Row]
    /// Pre-selected for Trash: confident suggestions only.
    let suggestedIDs: Set<String>
    let firstDate: Date?
    let lastDate: Date?

    var itemIDs: [String] { rows.flatMap(\.itemIDs) }
    var keeperIDs: Set<String> { rows.reduce(into: Set<String>()) { $0.formUnion($1.keeperIDs) } }
    var count: Int { rows.reduce(0) { $0 + $1.itemIDs.count } }
}

/// Splits the current suggestions into small, connected sets for the guided cleanup.
enum CleanupSetBuilder {
    /// The most items a set ever shows (a screen of 4 × 6 thumbnails).
    static let maxSize = 24
    /// Sets smaller than this absorb neighbours of the same kind from nearby weeks or months, so the
    /// user isn't asked about dozens of two-photo sets.
    static let minFill = 16

    /// Order of kinds: the clearest, most valuable decisions first; ones that need thought last.
    static let kindOrder: [CleanupSet.Kind] = [
        .duplicates, .similar, .screenshots, .blurry, .temporary, .accidentalVideos, .videoCopies,
        .screenRecordings, .savedImages, .documents, .largeVideos,
    ]

    static func build(snapshot: RecommendationSnapshot, records: [String: AssetRecord],
                      deprioritized: Set<String> = [], calendar: Calendar = .current) -> [CleanupSet] {
        func date(_ id: String) -> Date? {
            records[id]?.metadata.creationDate ?? snapshot.recommendations[id]?.creationDate
        }
        var atomsByKind: [CleanupSet.Kind: [Atom]] = [:]

        // Look-alike groups: one atom per group (best shot + its suggested removals).
        for cluster in snapshot.clusters.values {
            let suggested = cluster.suggestedRemovals.filter { snapshot.recommendations[$0] != nil }
            guard !suggested.isEmpty else { continue }
            let kind = CleanupSet.Kind.of(cluster.kind.category)
            let keepers = cluster.keeperIDs.filter { records[$0] != nil }
            let preselected = suggested.filter { snapshot.recommendations[$0]?.preselect == true }
            let dates = (keepers + suggested).compactMap(date)
            // A group too big for one screen is split; its best shot heads every part.
            let room = max(1, maxSize - keepers.count)
            for (part, chunk) in suggested.chunked(into: room).enumerated() {
                atomsByKind[kind, default: []].append(Atom(
                    id: cluster.id + (part == 0 ? "" : "#\(part)"), itemIDs: keepers + chunk, keeperIDs: Set(keepers),
                    suggestedIDs: Set(chunk).intersection(preselected), date: dates.max(), firstDate: dates.min()
                ))
            }
        }
        // Everything else: one atom per item.
        for rec in snapshot.recommendations.values where rec.clusterID == nil {
            let kind = CleanupSet.Kind.of(rec.category)
            guard !kind.isGrouped else { continue }
            let d = date(rec.id)
            atomsByKind[kind, default: []].append(Atom(
                id: rec.id, itemIDs: [rec.id], keeperIDs: [], suggestedIDs: rec.preselect ? [rec.id] : [], date: d, firstDate: d
            ))
        }

        var sets: [CleanupSet] = []
        for kind in kindOrder {
            guard var atoms = atomsByKind[kind], !atoms.isEmpty else { continue }
            // Newest first: recent moments are the easiest to judge. ID breaks ties for stable sets.
            atoms.sort { a, b in
                let da = a.date ?? .distantPast, db = b.date ?? .distantPast
                return da == db ? a.id < b.id : da > db
            }
            let grouped = merge(atoms, kind: kind, calendar: calendar)
            // Sets the user skipped earlier go to the back of their kind.
            let fresh = grouped.filter { !$0.itemIDs.allSatisfy(deprioritized.contains) }
            let skipped = grouped.filter { $0.itemIDs.allSatisfy(deprioritized.contains) }
            sets += fresh + skipped
        }
        return sets
    }

    struct Atom {
        let id: String
        let itemIDs: [String]
        let keeperIDs: Set<String>
        let suggestedIDs: Set<String>
        /// Newest and oldest capture dates.
        let date: Date?
        let firstDate: Date?
    }

    /// Consecutive atoms join while they fit and stay connected: same day (look-alikes) or same month
    /// (others); a small set may also take in neighbours up to a month / three months from its first
    /// item, so a set never drifts across a long stretch of time.
    static func merge(_ atoms: [Atom], kind: CleanupSet.Kind, calendar: Calendar) -> [CleanupSet] {
        let bucket: Calendar.Component = kind.isGrouped ? .day : .month
        // Exact copies are the same easy decision whenever they were made: what connects them is
        // being copies, so they fill sets regardless of date. Everything else stays close in time.
        let reach: TimeInterval = switch kind {
        case .duplicates, .videoCopies: .infinity
        case .similar: 31 * 86_400
        default: 92 * 86_400
        }
        var sets: [CleanupSet] = []
        var current: [Atom] = []
        var size = 0

        func flush() {
            guard !current.isEmpty else { return }
            let rows: [CleanupSet.Row] = kind.isGrouped
                ? current.map { CleanupSet.Row(itemIDs: $0.itemIDs, keeperIDs: $0.keeperIDs) }
                : [CleanupSet.Row(itemIDs: current.flatMap(\.itemIDs), keeperIDs: [])]
            let dates = current.flatMap { [$0.date, $0.firstDate] }.compactMap { $0 }
            sets.append(CleanupSet(
                id: kind.rawValue + ":" + current[0].id, kind: kind, rows: rows,
                suggestedIDs: current.reduce(into: Set<String>()) { $0.formUnion($1.suggestedIDs) },
                firstDate: dates.min(), lastDate: dates.max()
            ))
            current = []
            size = 0
        }

        for atom in atoms {
            if let first = current.first, let last = current.last {
                let fits = size + atom.itemIDs.count <= maxSize
                let together: Bool = {
                    if reach.isInfinite { return true }  // copies: fill the set whatever the dates
                    guard let a = last.date, let b = atom.date, let start = first.date else { return last.date == nil && atom.date == nil }
                    if calendar.isDate(a, equalTo: b, toGranularity: bucket) { return true }
                    return size < minFill && abs(start.timeIntervalSince(b)) <= reach
                }()
                if !fits || !together { flush() }
            }
            current.append(atom)
            size += atom.itemIDs.count
        }
        flush()
        return sets
    }

    /// "Sat 4 Jul 2025", "July 2025", "May – Jul 2025".
    static func dateLine(_ set: CleanupSet, calendar: Calendar = .current) -> String {
        guard let first = set.firstDate, let last = set.lastDate else { return "Undated" }
        if calendar.isDate(first, inSameDayAs: last) {
            return last.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        }
        if calendar.isDate(first, equalTo: last, toGranularity: .month) {
            return last.formatted(.dateTime.month(.wide).year())
        }
        let sameYear = calendar.isDate(first, equalTo: last, toGranularity: .year)
        let start = sameYear ? first.formatted(.dateTime.month(.abbreviated)) : first.formatted(.dateTime.month(.abbreviated).year())
        return start + " – " + last.formatted(.dateTime.month(.abbreviated).year())
    }
}
