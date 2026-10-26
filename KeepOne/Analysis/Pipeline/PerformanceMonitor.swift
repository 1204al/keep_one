import Foundation

enum MetricStage: String, CaseIterable, Sendable {
    case thumbnail = "Image decode"
    case pixelMetrics = "pHash & quality"
    case vision = "Vision"
    case featurePrint = "Feature print"
    case semantic = "MobileCLIP"
    case ocr = "OCR"
    case videoFrames = "Video frames"
    case persistence = "Persistence"
    case grouping = "Grouping"
    case recommendations = "Recommendations"
    case contentHash = "Content hash"
    case detailSharpness = "Detail sharpness"
}

struct StageTiming: Sendable, Equatable {
    var count = 0
    var totalMs: Double = 0
    var maxMs: Double = 0
    var meanMs: Double { count == 0 ? 0 : totalMs / Double(count) }
}

struct PerformanceSnapshot: Sendable, Equatable {
    var timings: [MetricStage: StageTiming] = [:]
    var assetsPerSecond: Double = 0
    var analyzedThisSession = 0
    var cacheHits = 0
    var cacheMisses = 0
    var memoryMB: Double = 0
    var thermalState: String = "nominal"
    var concurrency = 0
    var semanticModel: String = "—"
    var semanticComputeUnits: String = "—"

    var cacheHitRate: Double {
        let total = cacheHits + cacheMisses
        return total == 0 ? 0 : Double(cacheHits) / Double(total)
    }
}

/// Aggregate-only diagnostics. Never stores per-asset data, file names or content.
actor PerformanceMonitor {
    static let shared = PerformanceMonitor()

    private var snapshot = PerformanceSnapshot()
    private var completions: [Date] = []

    func record(_ stage: MetricStage, ms: Double) {
        var t = snapshot.timings[stage] ?? StageTiming()
        t.count += 1
        t.totalMs += ms
        t.maxMs = max(t.maxMs, ms)
        snapshot.timings[stage] = t
    }

    func assetCompleted() {
        snapshot.analyzedThisSession += 1
        let now = Date()
        completions.append(now)
        completions.removeAll { now.timeIntervalSince($0) > 20 }
        if let first = completions.first, completions.count > 1 {
            snapshot.assetsPerSecond = Double(completions.count - 1) / max(0.001, now.timeIntervalSince(first))
        }
    }

    func cache(hits: Int, misses: Int) {
        snapshot.cacheHits = hits
        snapshot.cacheMisses = misses
    }

    func setConcurrency(_ value: Int) { snapshot.concurrency = value }

    func setSemanticModel(_ name: String, computeUnits: String) {
        snapshot.semanticModel = name
        snapshot.semanticComputeUnits = computeUnits
    }

    func current() -> PerformanceSnapshot {
        var s = snapshot
        s.memoryMB = Self.memoryFootprintMB()
        s.thermalState = ThermalGovernor.describe(ProcessInfo.processInfo.thermalState)
        return s
    }

    func reset() {
        let model = snapshot.semanticModel, units = snapshot.semanticComputeUnits
        snapshot = PerformanceSnapshot()
        snapshot.semanticModel = model
        snapshot.semanticComputeUnits = units
        completions.removeAll()
    }

    static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

/// Measures a block and reports it to the shared monitor.
@discardableResult
func measure<T>(
    _ stage: MetricStage,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async rethrows -> T {
    let start = ContinuousClock.now
    let value = try await body()
    let elapsed = ContinuousClock.now - start
    let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    await PerformanceMonitor.shared.record(stage, ms: ms)
    return value
}

enum ThermalGovernor {
    /// Concurrent analysis tasks for the current device state.
    static func concurrency(thermal: ProcessInfo.ThermalState, lowPower: Bool, heavy: Bool) -> Int {
        var n: Int
        switch thermal {
        case .nominal: n = heavy ? 2 : 4
        case .fair: n = heavy ? 2 : 3
        case .serious: n = 1
        case .critical: n = 0
        @unknown default: n = 1
        }
        if lowPower { n = min(n, heavy ? 1 : 2) }
        return n
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
