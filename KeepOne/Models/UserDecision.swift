import Foundation

/// Every user action is a local training signal.
enum DecisionKind: Int, Codable, Sendable {
    case keep = 0
    case delete = 1
    case protect = 2
    case changeBestShot = 3
    case neverSuggestType = 4
    case restoreFromTrash = 5
    case confirmedDeletion = 6
    /// A correction (Undo / clearing the queue): cancels the previous choice, teaches nothing.
    case undo = 7

    /// Label for the preference model: 1 = removed, 0 = kept, nil = not a removal signal.
    var trainingLabel: Double? {
        switch self {
        case .delete, .confirmedDeletion: 1
        case .keep, .protect, .restoreFromTrash: 0
        case .changeBestShot, .neverSuggestType, .undo: nil
        }
    }
}

struct UserDecision: Codable, Sendable, Identifiable {
    var id: Int64?
    var assetID: String
    var kind: DecisionKind
    var category: CleanupCategory?
    /// Free-form context, e.g. "similarGroup", "swipe", "fiveMinute".
    var context: String
    var timestamp: Date
    /// Feature vector at decision time (see `PreferenceFeatures`).
    var features: [Float]
}

/// Persistent per-asset user marks that exclude an asset from suggestions.
enum AssetMark: Int, Codable, Sendable {
    /// Reviewed and kept — hidden from current suggestions.
    case kept = 0
    /// Valued — always kept, a strong keeper inside groups.
    case protected = 1
    /// "Never suggest this again" (Skip List).
    case neverSuggest = 2

    var title: String {
        switch self {
        case .kept: "Reviewed & kept"
        case .protected: "Protected"
        case .neverSuggest: "Never suggest"
        }
    }

    var symbol: String {
        switch self {
        case .kept: "checkmark.circle"
        case .protected: "lock.fill"
        case .neverSuggest: "nosign"
        }
    }
}

/// An item the user explicitly placed in KeepOne's internal Trash Queue.
/// Nothing touches PhotoKit until the final review is confirmed.
struct TrashEntry: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var category: CleanupCategory?
    var clusterID: String?
    var addedAt: Date
    var bytes: Int64
    var bytesExact: Bool
    var context: String
}
