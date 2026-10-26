import Foundation

/// Coarse semantic groups. Raw values must match `group` in scripts/semantic_concepts.json.
enum SemanticGroup: String, Codable, Sendable, CaseIterable {
    case receipt
    case parking
    case productLabel
    case priceTag
    case ticketQR
    case package
    case menuSign
    case screenPhoto
    case document
    case sensitiveDocument
    case evidence
    case screenshotLike
    case meme
    case accidental
    case memory
    case food
    case neutral

    /// Temporary-reference groups and the cleanup category they map to.
    var temporaryCategory: CleanupCategory? {
        switch self {
        case .receipt: .receipts
        case .parking: .parking
        case .productLabel: .productLabels
        case .priceTag: .priceTags
        case .ticketQR: .ticketsQR
        case .package: .packages
        case .menuSign: .menusSigns
        case .screenPhoto: .screens
        default: nil
        }
    }

    static let temporaryGroups: [SemanticGroup] = allCases.filter { $0.temporaryCategory != nil }
}

/// Apple Vision scene-classification identifiers used as cheap corroborating evidence.
/// (Verified against `ClassifyImageRequest().supportedIdentifiers` on the iOS 27 SDK.)
enum VisionLabel {
    static let receipt = ["receipt"]
    static let parking = ["parking_lot", "garage"]
    static let vehicles = ["car", "automobile", "vehicle", "license_plate", "tire", "wheel"]
    static let documents = ["document", "handwriting", "whiteboard", "chalkboard", "book", "envelope", "calendar", "chart", "diagram"]
    static let sensitive = ["passport", "credit_card", "money", "wallet"]
    static let tickets = ["ticket"]
    static let packages = ["cardboard_box"]
    static let signs = ["sign", "street_sign", "banner", "billboards"]
    static let screens = ["computer_monitor", "television", "computer", "laptop", "computer_keyboard", "phone", "consumer_electronics"]
    static let devices = ["appliance", "circuit_board", "consumer_electronics"]
    static let store = ["interior_shop", "shopping_cart"]
    static let screenshot = ["screenshot"]
    static let people = ["people", "adult", "child", "baby", "teen", "crowd", "wedding"]
    static let memories = ["beach", "mountain", "sky", "night_sky", "dog", "cat", "birthday_cake", "wedding", "crowd"]
    static let food = ["food", "tableware"]

    /// Labels worth persisting (keeps the cache small).
    static let interesting: Set<String> = Set(
        receipt + parking + vehicles + documents + sensitive + tickets + packages + signs + screens + devices
            + store + screenshot + people + memories + food + ["map", "interior_room", "road", "street", "outdoor", "structure", "building", "textile", "curtain"]
    )
}
