import Foundation

/// Age-based suggestion rule for temporary items.
enum RetentionPeriod: Codable, Sendable, Hashable, Identifiable {
    case days(Int)
    /// Never use age to suggest — items stay "Needs review" at most.
    case never

    var id: String {
        switch self {
        case .days(let d): "d\(d)"
        case .never: "never"
        }
    }

    var title: String {
        switch self {
        case .days(let d):
            switch d {
            case 365: "after 1 year"
            case let d where d % 30 == 0 && d >= 60: "after \(d / 30) months"
            default: "after \(d) days"
            }
        case .never: "never by age"
        }
    }

    var days: Int? {
        if case .days(let d) = self { return d }
        return nil
    }

    static let choices: [RetentionPeriod] = [.days(1), .days(7), .days(14), .days(30), .days(90), .days(180), .days(365), .never]
}

struct RetentionRules: Codable, Sendable, Equatable {
    var parking: RetentionPeriod = .days(7)
    var screenshots: RetentionPeriod = .days(30)
    var receipts: RetentionPeriod = .days(90)
    var screenRecordings: RetentionPeriod = .days(30)
    var tickets: RetentionPeriod = .days(30)
    var otherReferences: RetentionPeriod = .days(30)

    func period(for category: CleanupCategory) -> RetentionPeriod? {
        switch category {
        case .parking: parking
        case .screenshots: screenshots
        case .receipts: receipts
        case .screenRecordings: screenRecordings
        case .ticketsQR: tickets
        case .productLabels, .priceTags, .packages, .menusSigns, .screens, .otherReferences: otherReferences
        default: nil
        }
    }
}

/// Weights for the best-shot score. Calibrated online when the user picks a different keeper.
struct BestShotWeights: Codable, Sendable, Equatable {
    var sharpness: Double = 0.22
    var exposure: Double = 0.10
    var faceQuality: Double = 0.20
    var aesthetics: Double = 0.15
    var framing: Double = 0.08
    var resolution: Double = 0.08
    var personal: Double = 0.12
    var faceCount: Double = 0.05

    static let `default` = BestShotWeights()

    var asArray: [Double] { [sharpness, exposure, faceQuality, aesthetics, framing, resolution, personal, faceCount] }

    init() {}

    init(array: [Double]) {
        precondition(array.count == 8)
        sharpness = array[0]; exposure = array[1]; faceQuality = array[2]; aesthetics = array[3]
        framing = array[4]; resolution = array[5]; personal = array[6]; faceCount = array[7]
    }

    /// Keep weights positive and summing to 1 so scores stay interpretable.
    func normalized() -> BestShotWeights {
        let clipped = asArray.map { max(0.02, $0) }
        let sum = clipped.reduce(0, +)
        return BestShotWeights(array: clipped.map { $0 / sum })
    }
}

enum SemanticComputePreference: String, Codable, Sendable, CaseIterable {
    /// Neural Engine where available (most efficient).
    case all
    /// GPU — numerically closest to the reference model, slightly more power.
    case cpuAndGPU

    var title: String {
        switch self {
        case .all: "Neural Engine (efficient)"
        case .cpuAndGPU: "GPU (highest precision)"
        }
    }
}

struct AppSettings: Codable, Sendable, Equatable {
    var protectFavorites = true
    var protectEdited = true
    var protectRecent = true
    var recentDays = 7
    var protectImportantDocuments = true
    var retention = RetentionRules()
    var livePhotoCleanupEnabled = false
    var defaultBatchSize = 50
    var bestShotWeights = BestShotWeights.default
    var mutedCategories: Set<CleanupCategory> = []
    var developerMode = false
    var allowBackgroundScanning = true
    var autoResumeScan = true
    var allowICloudDownloads = false
    var semanticCompute: SemanticComputePreference = .all
    var hasCompletedOnboarding = false

    init() {}

    // Tolerant decoding so new settings never wipe old ones.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        protectFavorites = (try? c.decode(Bool.self, forKey: .protectFavorites)) ?? d.protectFavorites
        protectEdited = (try? c.decode(Bool.self, forKey: .protectEdited)) ?? d.protectEdited
        protectRecent = (try? c.decode(Bool.self, forKey: .protectRecent)) ?? d.protectRecent
        recentDays = (try? c.decode(Int.self, forKey: .recentDays)) ?? d.recentDays
        protectImportantDocuments = (try? c.decode(Bool.self, forKey: .protectImportantDocuments)) ?? d.protectImportantDocuments
        retention = (try? c.decode(RetentionRules.self, forKey: .retention)) ?? d.retention
        livePhotoCleanupEnabled = (try? c.decode(Bool.self, forKey: .livePhotoCleanupEnabled)) ?? d.livePhotoCleanupEnabled
        defaultBatchSize = (try? c.decode(Int.self, forKey: .defaultBatchSize)) ?? d.defaultBatchSize
        bestShotWeights = (try? c.decode(BestShotWeights.self, forKey: .bestShotWeights)) ?? d.bestShotWeights
        // One unknown (e.g. renamed) category must not drop all the others.
        mutedCategories = (try? c.decode([String].self, forKey: .mutedCategories))
            .map { Set($0.compactMap(CleanupCategory.init(rawValue:))) } ?? d.mutedCategories
        developerMode = (try? c.decode(Bool.self, forKey: .developerMode)) ?? d.developerMode
        allowBackgroundScanning = (try? c.decode(Bool.self, forKey: .allowBackgroundScanning)) ?? d.allowBackgroundScanning
        autoResumeScan = (try? c.decode(Bool.self, forKey: .autoResumeScan)) ?? d.autoResumeScan
        allowICloudDownloads = (try? c.decode(Bool.self, forKey: .allowICloudDownloads)) ?? d.allowICloudDownloads
        semanticCompute = (try? c.decode(SemanticComputePreference.self, forKey: .semanticCompute)) ?? d.semanticCompute
        hasCompletedOnboarding = (try? c.decode(Bool.self, forKey: .hasCompletedOnboarding)) ?? d.hasCompletedOnboarding
    }
}

// Field-by-field decoding for nested settings too: adding a rule or a weight later must not reset
// the user's other choices to defaults.
extension RetentionRules {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RetentionRules()
        func value(_ key: CodingKeys, _ fallback: RetentionPeriod) -> RetentionPeriod {
            (try? c.decode(RetentionPeriod.self, forKey: key)) ?? fallback
        }
        self.init()
        parking = value(.parking, d.parking)
        screenshots = value(.screenshots, d.screenshots)
        receipts = value(.receipts, d.receipts)
        screenRecordings = value(.screenRecordings, d.screenRecordings)
        tickets = value(.tickets, d.tickets)
        otherReferences = value(.otherReferences, d.otherReferences)
    }
}

extension BestShotWeights {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        func value(_ key: CodingKeys, _ fallback: Double) -> Double {
            (try? c.decode(Double.self, forKey: key)).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? fallback
        }
        sharpness = value(.sharpness, sharpness)
        exposure = value(.exposure, exposure)
        faceQuality = value(.faceQuality, faceQuality)
        aesthetics = value(.aesthetics, aesthetics)
        framing = value(.framing, framing)
        resolution = value(.resolution, resolution)
        personal = value(.personal, personal)
        faceCount = value(.faceCount, faceCount)
    }
}
