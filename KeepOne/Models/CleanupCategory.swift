import Foundation

/// Confidence tiers. Deliberately coarse — no fake precision.
enum RecommendationTier: Int, Codable, Sendable, Comparable, CaseIterable {
    case review = 1
    case likely = 2
    case safe = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .safe: "Safe"
        case .likely: "Likely"
        case .review: "Needs review"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.seal.fill"
        case .likely: "checkmark.circle"
        case .review: "eye"
        }
    }

    var explanation: String {
        switch self {
        case .safe: "Extremely strong evidence, such as an identical copy."
        case .likely: "Strong evidence, but worth a quick look."
        case .review: "Possibly unnecessary. You decide."
        }
    }

    /// Only Safe and Likely items are ever preselected — and only inside a review the user opened.
    var isPreselectable: Bool { self >= .likely }

    func demoted() -> RecommendationTier {
        switch self {
        case .safe: .likely
        case .likely, .review: .review
        }
    }
}

/// Home-screen sections.
enum CategorySection: String, CaseIterable, Sendable {
    case safeCleanup
    case worthReviewing
    case temporary
    case videos

    var title: String {
        switch self {
        case .safeCleanup: "Duplicates & similar"
        case .worthReviewing: "Worth reviewing"
        case .temporary: "Temporary photos"
        case .videos: "Videos"
        }
    }
}

/// First-class junk taxonomy.
enum CleanupCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case exactDuplicates
    case similarPhotos
    case blurryFailed
    case screenshots
    case receipts
    case parking
    case productLabels
    case priceTags
    case ticketsQR
    case packages
    case menusSigns
    case screens
    case otherReferences
    case documents
    case memes
    case largeVideos
    case screenRecordings
    case accidentalVideos
    case duplicateVideos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exactDuplicates: "Exact duplicates"
        case .similarPhotos: "Similar shots"
        case .blurryFailed: "Blurry & failed"
        case .screenshots: "Screenshots"
        case .receipts: "Receipts"
        case .parking: "Parking"
        case .productLabels: "Device & product labels"
        case .priceTags: "Price tags"
        case .ticketsQR: "QR codes & tickets"
        case .packages: "Packages"
        case .menusSigns: "Menus & signs"
        case .screens: "Screens & errors"
        case .otherReferences: "Other references"
        case .documents: "Notes & documents"
        case .memes: "Saved & shared images"
        case .largeVideos: "Large videos"
        case .screenRecordings: "Screen recordings"
        case .accidentalVideos: "Accidental videos"
        case .duplicateVideos: "Duplicate videos"
        }
    }

    var symbol: String {
        switch self {
        case .exactDuplicates: "plus.square.on.square"
        case .similarPhotos: "square.stack.3d.down.right"
        case .blurryFailed: "camera.metering.unknown"
        case .screenshots: "iphone"
        case .receipts: "receipt"
        case .parking: "parkingsign.circle"
        case .productLabels: "barcode.viewfinder"
        case .priceTags: "tag"
        case .ticketsQR: "qrcode"
        case .packages: "shippingbox"
        case .menusSigns: "signpost.right"
        case .screens: "display"
        case .otherReferences: "pin"
        case .documents: "doc.text"
        case .memes: "square.and.arrow.down"
        case .largeVideos: "film.stack"
        case .screenRecordings: "record.circle"
        case .accidentalVideos: "video.slash"
        case .duplicateVideos: "film.circle"
        }
    }

    var section: CategorySection {
        switch self {
        case .exactDuplicates, .similarPhotos: .safeCleanup
        case .blurryFailed, .screenshots, .documents, .memes: .worthReviewing
        case .receipts, .parking, .productLabels, .priceTags, .ticketsQR, .packages, .menusSigns, .screens, .otherReferences:
            .temporary
        case .largeVideos, .screenRecordings, .accidentalVideos, .duplicateVideos: .videos
        }
    }

    var isTemporaryReference: Bool { section == .temporary }
    var isVideo: Bool { section == .videos }
    var isGrouped: Bool { self == .exactDuplicates || self == .similarPhotos || self == .duplicateVideos }

    /// Short description shown on category pages.
    var blurb: String {
        switch self {
        case .exactDuplicates: "Identical copies. KeepOne keeps the best original of each set."
        case .similarPhotos: "Several shots of the same moment. Keep the best, remove the rest."
        case .blurryFailed: "Out-of-focus, dark or accidental captures."
        case .screenshots: "Screenshots, oldest first."
        case .receipts: "Shopping and restaurant receipts. Some may matter for warranty or taxes."
        case .parking: "Photos taken to remember where you parked."
        case .productLabels: "Serial numbers, model plates and device stickers."
        case .priceTags: "Price labels and products photographed in stores."
        case .ticketsQR: "Tickets, reservations and QR codes."
        case .packages: "Shipping labels and parcels."
        case .menusSigns: "Menus, opening hours, timetables and signs."
        case .screens: "Photos of screens and error messages."
        case .otherReferences: "Other photos that look like quick references."
        case .documents: "Notes, whiteboards and documents. Review with care."
        case .memes: "Images saved from the web or messaging apps."
        case .largeVideos: "Your biggest videos, largest first."
        case .screenRecordings: "Screen recordings, oldest first."
        case .accidentalVideos: "Very short, dark or shaky clips."
        case .duplicateVideos: "Copies and near-copies of the same clip."
        }
    }

    /// Ordering for "primary category" resolution and Home display.
    var displayOrder: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    static var temporaryCategories: [CleanupCategory] {
        allCases.filter(\.isTemporaryReference)
    }
}
