import Foundation

/// Structured local filters. No language model needed: chips plus a tiny keyword parser.
enum SmartFilter: String, CaseIterable, Hashable, Identifiable, Sendable {
    case olderThan7Days, olderThan30Days, olderThan90Days, olderThan1Year
    case over100MB, over500MB, uhd4K
    case noPeople, withPeople
    case photos, videos, screenshots, receipts, parking, blurry, duplicates, withQR
    case notFavorite, safeOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .olderThan7Days: "Older than 7 days"
        case .olderThan30Days: "Older than 30 days"
        case .olderThan90Days: "Older than 90 days"
        case .olderThan1Year: "Older than 1 year"
        case .over100MB: "Over 100 MB"
        case .over500MB: "Over 500 MB"
        case .uhd4K: "4K"
        case .noPeople: "No people"
        case .withPeople: "With people"
        case .photos: "Photos"
        case .videos: "Videos"
        case .screenshots: "Screenshots"
        case .receipts: "Receipts"
        case .parking: "Parking"
        case .blurry: "Blurry"
        case .duplicates: "Duplicates"
        case .withQR: "QR codes"
        case .notFavorite: "Not favorite"
        case .safeOnly: "Safe only"
        }
    }

    var symbol: String {
        switch self {
        case .olderThan7Days, .olderThan30Days, .olderThan90Days, .olderThan1Year: "calendar"
        case .over100MB, .over500MB: "externaldrive"
        case .uhd4K: "4k.tv"
        case .noPeople: "person.slash"
        case .withPeople: "person.2"
        case .photos: "photo"
        case .videos: "video"
        case .screenshots: "iphone"
        case .receipts: "receipt"
        case .parking: "parkingsign"
        case .blurry: "camera.metering.unknown"
        case .duplicates: "plus.square.on.square"
        case .withQR: "qrcode"
        case .notFavorite: "heart.slash"
        case .safeOnly: "checkmark.seal"
        }
    }

    /// Mutually exclusive groups (selecting one replaces the other).
    var exclusivityGroup: String? {
        switch self {
        case .olderThan7Days, .olderThan30Days, .olderThan90Days, .olderThan1Year: "age"
        case .over100MB, .over500MB: "size"
        case .noPeople, .withPeople: "people"
        case .photos, .videos: "media"
        default: nil
        }
    }

    static let ageFilters: [SmartFilter] = [.olderThan7Days, .olderThan30Days, .olderThan90Days, .olderThan1Year]

    func matches(_ record: AssetRecord, recommendation: Recommendation?, now: Date) -> Bool {
        let m = record.metadata
        let age = m.ageInDays(now: now)
        switch self {
        case .olderThan7Days: return age > 7
        case .olderThan30Days: return age > 30
        case .olderThan90Days: return age > 90
        case .olderThan1Year: return age > 365
        case .over100MB: return record.storageEstimate.bytes > 100_000_000
        case .over500MB: return record.storageEstimate.bytes > 500_000_000
        case .uhd4K: return m.is4KOrMore
        case .noPeople: return !record.hasPeople
        case .withPeople: return record.hasPeople
        case .photos: return m.isImage
        case .videos: return m.isVideo
        case .screenshots: return m.isScreenshot || m.isScreenRecording
        case .receipts: return recommendation?.category == .receipts || (record.semantic?.score(.receipt) ?? 0) >= 0.4
        case .parking: return recommendation?.category == .parking || (record.semantic?.score(.parking) ?? 0) >= 0.4
        case .blurry: return recommendation?.category == .blurryFailed
            || (record.fingerprint.map { QualityAssessor.assess(quality: $0.quality, vision: record.vision, semantic: record.semantic).isFailed } ?? false)
        case .duplicates: return recommendation?.category == .exactDuplicates || recommendation?.category == .duplicateVideos
        case .withQR: return (record.text?.qrCount ?? 0) > 0
        case .notFavorite: return !m.isFavorite
        case .safeOnly: return recommendation?.tier == .safe
        }
    }

    static func apply(_ filters: Set<SmartFilter>, record: AssetRecord, recommendation: Recommendation?, now: Date) -> Bool {
        filters.allSatisfy { $0.matches(record, recommendation: recommendation, now: now) }
    }

    /// Parses phrases such as "receipts older than 1 year", "videos over 500 mb", "no people".
    static func parse(_ query: String) -> Set<SmartFilter> {
        let q = query.lowercased()
        var result = Set<SmartFilter>()
        if q.contains("1 year") || q.contains("a year") || q.contains("12 months") { result.insert(.olderThan1Year) }
        else if q.contains("90 days") || q.contains("3 months") { result.insert(.olderThan90Days) }
        else if q.contains("30 days") || q.contains("month") { result.insert(.olderThan30Days) }
        else if q.contains("7 days") || q.contains("week") { result.insert(.olderThan7Days) }
        if q.contains("500") && (q.contains("mb") || q.contains("over")) { result.insert(.over500MB) }
        else if q.contains("100") && (q.contains("mb") || q.contains("over")) { result.insert(.over100MB) }
        if q.contains("no people") || q.contains("without people") { result.insert(.noPeople) }
        else if q.contains("with people") || q.contains("people") { result.insert(.withPeople) }
        if q.contains("4k") { result.insert(.uhd4K) }
        if q.contains("video") { result.insert(.videos) }
        if q.contains("photo") && !q.contains("video") { result.insert(.photos) }
        if q.contains("screenshot") || q.contains("screen recording") { result.insert(.screenshots) }
        if q.contains("receipt") { result.insert(.receipts) }
        if q.contains("parking") { result.insert(.parking) }
        if q.contains("blur") { result.insert(.blurry) }
        if q.contains("duplicate") { result.insert(.duplicates) }
        if q.contains("qr") { result.insert(.withQR) }
        if q.contains("not favorite") || q.contains("not favourite") { result.insert(.notFavorite) }
        if q.contains("safe") { result.insert(.safeOnly) }
        return result
    }
}
