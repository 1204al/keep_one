import Foundation

/// Media kind mirrored from PhotoKit so analysis code never needs to import Photos.
enum AssetMediaType: Int, Codable, Sendable {
    case unknown = 0
    case image = 1
    case video = 2
    case audio = 3
}

/// Mirrors `PHAssetMediaSubtype` raw values (stable public constants).
struct MediaSubtype: OptionSet, Codable, Sendable, Hashable {
    let rawValue: UInt

    static let panorama = MediaSubtype(rawValue: 1 << 0)
    static let hdr = MediaSubtype(rawValue: 1 << 1)
    static let screenshot = MediaSubtype(rawValue: 1 << 2)
    static let livePhoto = MediaSubtype(rawValue: 1 << 3)
    static let depthEffect = MediaSubtype(rawValue: 1 << 4)
    static let animation = MediaSubtype(rawValue: 1 << 6)
    static let spatial = MediaSubtype(rawValue: 1 << 10)
    static let videoStreamed = MediaSubtype(rawValue: 1 << 16)
    static let videoHighFrameRate = MediaSubtype(rawValue: 1 << 17)
    static let videoTimelapse = MediaSubtype(rawValue: 1 << 18)
    static let screenRecording = MediaSubtype(rawValue: 1 << 19)
    static let cinematic = MediaSubtype(rawValue: 1 << 21)
}

/// Mirrors `PHAssetSourceType`.
struct AssetSourceType: OptionSet, Codable, Sendable, Hashable {
    let rawValue: UInt
    static let userLibrary = AssetSourceType(rawValue: 1 << 0)
    static let cloudShared = AssetSourceType(rawValue: 1 << 1)
    static let iTunesSynced = AssetSourceType(rawValue: 1 << 2)
}

/// Cheap PhotoKit metadata. Everything here is available without decoding pixels.
struct AssetMetadata: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var mediaType: AssetMediaType
    var subtypes: MediaSubtype
    var creationDate: Date?
    var modificationDate: Date?
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: Double
    var isFavorite: Bool
    var isHidden: Bool
    var hasAdjustments: Bool
    var burstIdentifier: String?
    var representsBurst: Bool
    var latitude: Double?
    var longitude: Double?
    var sourceType: AssetSourceType
    /// When the asset was last edited (iOS 18+). A change means pixels changed.
    var adjustmentTimestamp: Date? = nil

    init(
        id: String,
        mediaType: AssetMediaType = .image,
        subtypes: MediaSubtype = [],
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        pixelWidth: Int = 4032,
        pixelHeight: Int = 3024,
        duration: Double = 0,
        isFavorite: Bool = false,
        isHidden: Bool = false,
        hasAdjustments: Bool = false,
        burstIdentifier: String? = nil,
        representsBurst: Bool = false,
        latitude: Double? = nil,
        longitude: Double? = nil,
        sourceType: AssetSourceType = .userLibrary,
        adjustmentTimestamp: Date? = nil
    ) {
        self.id = id
        self.mediaType = mediaType
        self.subtypes = subtypes
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.hasAdjustments = hasAdjustments
        self.burstIdentifier = burstIdentifier
        self.representsBurst = representsBurst
        self.latitude = latitude
        self.longitude = longitude
        self.sourceType = sourceType
        self.adjustmentTimestamp = adjustmentTimestamp
    }

    /// True when pixel content may differ (edit, revert, resize) — cached pixel analysis is stale.
    func contentDiffers(from old: AssetMetadata) -> Bool {
        pixelWidth != old.pixelWidth || pixelHeight != old.pixelHeight || hasAdjustments != old.hasAdjustments
            || adjustmentTimestamp != old.adjustmentTimestamp || duration != old.duration
    }

    var isImage: Bool { mediaType == .image }
    var isVideo: Bool { mediaType == .video }
    var isScreenshot: Bool { subtypes.contains(.screenshot) }
    var isLivePhoto: Bool { subtypes.contains(.livePhoto) }
    var isScreenRecording: Bool { subtypes.contains(.screenRecording) }
    var pixelCount: Int { pixelWidth * pixelHeight }
    var aspectRatio: Double {
        guard pixelHeight > 0 else { return 1 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
    var hasLocation: Bool { latitude != nil && longitude != nil }
    var is4KOrMore: Bool { max(pixelWidth, pixelHeight) >= 3840 }

    /// Undated items (some imports and scans) fall back to the last modification — never older than
    /// the truth, so age rules stay conservative — instead of counting as "taken today" forever.
    func ageInDays(now: Date) -> Double {
        guard let date = creationDate ?? modificationDate else { return 0 }
        return max(0, now.timeIntervalSince(date) / 86_400)
    }
}
