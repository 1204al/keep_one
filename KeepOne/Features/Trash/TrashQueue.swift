import Foundation

/// Evidence that the user looked at the final Trash Review and confirmed it.
/// Only the final review screen creates one, with exactly the items it showed.
struct FinalReviewConfirmation: Sendable, Equatable {
    let reviewedIDs: Set<String>
    let confirmedAt: Date
}

/// The only value PhotoKit deletion accepts. It can be produced solely from the Trash Queue plus a
/// final-review confirmation, so a recommendation can never reach PhotoKit directly.
struct DeletionPlan: Sendable, Equatable {
    let assetIDs: [String]
    let bytes: Int64
    let createdAt: Date

    fileprivate init(assetIDs: [String], bytes: Int64, createdAt: Date) {
        self.assetIDs = assetIDs
        self.bytes = bytes
        self.createdAt = createdAt
    }
}

/// KeepOne's internal Trash Queue. Selecting ≠ deleting.
struct TrashQueue: Sendable, Equatable {
    private(set) var entries: [String: TrashEntry] = [:]
    private(set) var order: [String] = []

    init(entries: [TrashEntry] = []) {
        for e in entries.sorted(by: { $0.addedAt < $1.addedAt }) where self.entries[e.id] == nil {
            self.entries[e.id] = e
            order.append(e.id)
        }
    }

    var count: Int { order.count }
    var isEmpty: Bool { order.isEmpty }
    var ids: Set<String> { Set(order) }
    var orderedEntries: [TrashEntry] { order.compactMap { entries[$0] } }
    var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.bytes } }
    var bytesExact: Bool { entries.values.allSatisfy(\.bytesExact) }

    func contains(_ id: String) -> Bool { entries[id] != nil }

    /// Adds entries; returns the ones that were new.
    @discardableResult
    mutating func add(_ newEntries: [TrashEntry]) -> [TrashEntry] {
        var added: [TrashEntry] = []
        for e in newEntries where entries[e.id] == nil {
            entries[e.id] = e
            order.append(e.id)
            added.append(e)
        }
        return added
    }

    @discardableResult
    mutating func remove(_ ids: [String]) -> [TrashEntry] {
        var removed: [TrashEntry] = []
        for id in ids {
            if let e = entries.removeValue(forKey: id) { removed.append(e) }
        }
        let gone = Set(ids)
        order.removeAll { gone.contains($0) }
        return removed
    }

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    /// Groups for the final review, largest group first.
    var groupedByReason: [(category: CleanupCategory?, entries: [TrashEntry])] {
        let grouped = Dictionary(grouping: orderedEntries, by: \.category)
        return grouped.map { (category: $0.key, entries: $0.value) }
            .sorted { lhs, rhs in
                if lhs.entries.count != rhs.entries.count { return lhs.entries.count > rhs.entries.count }
                return (lhs.category?.displayOrder ?? 99) < (rhs.category?.displayOrder ?? 99)
            }
    }

    /// Builds the plan PhotoKit will execute: only items that are both still queued and were shown
    /// in the confirmed final review. Anything added afterwards is not deleted.
    func makeDeletionPlan(confirmation: FinalReviewConfirmation) -> DeletionPlan? {
        let ids = order.filter { confirmation.reviewedIDs.contains($0) }
        guard !ids.isEmpty else { return nil }
        let bytes = ids.compactMap { entries[$0]?.bytes }.reduce(0, +)
        return DeletionPlan(assetIDs: ids, bytes: bytes, createdAt: confirmation.confirmedAt)
    }
}
