import Foundation

enum ProtectionReason: String, Sendable, CaseIterable {
    case favorite, edited, recent, manual, neverSuggest, kept, hidden

    var reason: ReasonCode {
        switch self {
        case .favorite: .favorite
        case .edited: .edited
        case .recent: .age
        case .manual: .manuallyProtected
        case .neverSuggest: .manuallyProtected
        case .kept: .userChosen
        case .hidden: .manuallyProtected
        }
    }
}

/// Default protection signals. Protected assets are never recommended for removal — they can only
/// act as keepers. (Exact byte/visual copies ignore the *recent* rule: a copy has no value of its own.)
enum ProtectionPolicy {
    static func protections(for record: AssetRecord, settings: AppSettings, mark: AssetMark?, now: Date) -> Set<ProtectionReason> {
        var result = Set<ProtectionReason>()
        let m = record.metadata
        if settings.protectFavorites && m.isFavorite { result.insert(.favorite) }
        if settings.protectEdited && m.hasAdjustments { result.insert(.edited) }
        if settings.protectRecent && m.ageInDays(now: now) < Double(settings.recentDays) { result.insert(.recent) }
        if m.isHidden { result.insert(.hidden) }
        switch mark {
        case .protected: result.insert(.manual)
        case .neverSuggest: result.insert(.neverSuggest)
        case .kept: result.insert(.kept)
        case nil: break
        }
        return result
    }

    /// Protections that still allow an asset to be suggested as an exact copy of a kept original.
    static let duplicateExempt: Set<ProtectionReason> = [.recent]

    static func blocks(_ protections: Set<ProtectionReason>, forExactDuplicate: Bool) -> Bool {
        let effective = forExactDuplicate ? protections.subtracting(duplicateExempt) : protections
        return !effective.isEmpty
    }

    /// Assets that must stay keepers inside any group.
    static func forcedKeepers(records: [AssetRecord], marks: [String: AssetMark], settings: AppSettings) -> Set<String> {
        var ids = Set<String>()
        for (id, mark) in marks where mark == .protected || mark == .kept || mark == .neverSuggest { ids.insert(id) }
        for r in records {
            if settings.protectFavorites && r.metadata.isFavorite { ids.insert(r.id) }
            if settings.protectEdited && r.metadata.hasAdjustments { ids.insert(r.id) }
        }
        return ids
    }
}

enum RetentionEligibility: Equatable, Sendable {
    /// Younger than the rule — not suggested yet.
    case tooRecent(days: Int)
    /// Older than the rule.
    case eligible(days: Int)
    /// Age isn't used for this category ("never by age") — capped at Needs review.
    case ageNotUsed
    /// No rule applies to the category.
    case noRule
}

enum RetentionPolicy {
    static func eligibility(category: CleanupCategory, ageDays: Double, rules: RetentionRules) -> RetentionEligibility {
        guard let period = rules.period(for: category) else { return .noRule }
        switch period {
        case .never: return .ageNotUsed
        case .days(let days): return ageDays < Double(days) ? .tooRecent(days: days) : .eligible(days: days)
        }
    }
}
