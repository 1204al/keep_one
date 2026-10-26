import Foundation

enum ScanStage: String, CaseIterable, Sendable, Identifiable {
    case index
    case duplicates
    case similar
    case references
    case videos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .index: "Library index"
        case .duplicates: "Exact duplicates"
        case .similar: "Similar photos"
        case .references: "Temporary references"
        case .videos: "Videos"
        }
    }

    var symbol: String {
        switch self {
        case .index: "photo.stack"
        case .duplicates: "plus.square.on.square"
        case .similar: "square.stack.3d.down.right"
        case .references: "pin"
        case .videos: "film"
        }
    }
}

struct StageProgress: Sendable, Equatable {
    var completed = 0
    var total = 0
    var isDone = false

    var fraction: Double {
        if isDone { return 1 }
        return total == 0 ? 0 : min(1, Double(completed) / Double(total))
    }
}

enum ScanPhase: String, Sendable {
    case idle, indexing, photos, refining, text, videos, finishing
}

enum PauseReason: String, Sendable, Equatable {
    case user, thermal, background, interrupted

    var message: String {
        switch self {
        case .user: "Paused"
        case .thermal: "Paused while your iPhone cools down"
        case .background: "Paused in the background"
        case .interrupted: "Interrupted — will resume"
        }
    }
}

enum ScanState: Sendable, Equatable {
    case idle
    case running
    case paused(PauseReason)
    case completed(Date)
    case failed(String)

    var isRunning: Bool { self == .running }
    var isPaused: Bool { if case .paused = self { true } else { false } }
}

struct ScanProgress: Sendable, Equatable {
    var state: ScanState = .idle
    var phase: ScanPhase = .idle
    var stages: [ScanStage: StageProgress] = [:]
    var totalCount = 0
    var analyzedCount = 0
    var currentLabel: String?
    var lastCompleted: Date?
    var isFirstScan = true
    var thermalLimited = false
    var concurrency = 0

    func stage(_ s: ScanStage) -> StageProgress { stages[s] ?? StageProgress() }

    var overallFraction: Double {
        let weights: [ScanStage: Double] = [.index: 0.05, .duplicates: 0.2, .similar: 0.3, .references: 0.3, .videos: 0.15]
        return weights.reduce(0) { $0 + $1.value * stage($1.key).fraction }
    }

    var isComplete: Bool {
        if case .completed = state { return true }
        return false
    }
}

enum ScanEvent: Sendable {
    case progress(ScanProgress)
    /// Analysis data changed; recommendations should be refreshed.
    case dataChanged
}
