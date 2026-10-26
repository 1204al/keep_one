import CoreGraphics
import SwiftUI

/// Hidden diagnostics: aggregate timings only, no per-photo data.
struct DeveloperView: View {
    @Environment(AppModel.self) private var model
    @State private var snapshot = PerformanceSnapshot()
    @State private var benchmark: String?
    @State private var benchmarking = false

    var body: some View {
        List {
            Section("Throughput") {
                LabeledContent("Assets / second", value: String(format: "%.1f", snapshot.assetsPerSecond))
                LabeledContent("Analyzed this session", value: "\(snapshot.analyzedThisSession)")
                LabeledContent("Cache hit rate", value: Format.percent(snapshot.cacheHitRate))
                LabeledContent("Parallel tasks", value: "\(snapshot.concurrency)")
            }
            Section("Device") {
                LabeledContent("Memory", value: String(format: "%.0f MB", snapshot.memoryMB))
                LabeledContent("Thermal state", value: snapshot.thermalState)
                LabeledContent("Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
            }
            Section("Stage timings (mean / max)") {
                ForEach(MetricStage.allCases, id: \.self) { stage in
                    if let t = snapshot.timings[stage] {
                        LabeledContent(stage.rawValue) {
                            Text("\(Format.milliseconds(t.meanMs)) / \(Format.milliseconds(t.maxMs)) · \(t.count)")
                                .monospacedDigit()
                                .font(.caption)
                        }
                    }
                }
            }
            Section("Semantic model") {
                LabeledContent("Model", value: snapshot.semanticModel)
                LabeledContent("Compute units", value: snapshot.semanticComputeUnits)
                Picker("Precision", selection: Binding(get: { model.settings.semanticCompute }, set: { model.settings.semanticCompute = $0 })) {
                    ForEach(SemanticComputePreference.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button {
                    runBenchmark()
                } label: {
                    if benchmarking { ProgressView() } else { Text("Benchmark MobileCLIP (100 runs)") }
                }
                .disabled(benchmarking)
                if let benchmark { Text(benchmark).font(.footnote).monospacedDigit() }
            }
            Section("Library") {
                LabeledContent("Cached records", value: "\(model.records.count)")
                LabeledContent("Recommendations", value: "\(model.snapshot.totalCount)")
                LabeledContent("Groups", value: "\(model.snapshot.clusters.count)")
                LabeledContent("Trash Queue", value: "\(model.trash.count)")
                LabeledContent("Decisions", value: "\(model.decisionCount)")
            }
        }
        .navigationTitle("Diagnostics")
        .task {
            while !Task.isCancelled {
                snapshot = await PerformanceMonitor.shared.current()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func runBenchmark() {
        benchmarking = true
        let units: SemanticComputePreference = model.settings.semanticCompute
        Task.detached(priority: .userInitiated) {
            let result: String
            do {
                let encoder = try CoreMLSemanticEncoder(computeUnits: units == .cpuAndGPU ? .cpuAndGPU : .all)
                let image = Self.syntheticImage()
                _ = try await encoder.embedding(for: image)   // warm-up / compile
                let start = ContinuousClock.now
                for _ in 0..<100 { _ = try await encoder.embedding(for: image) }
                let elapsed = ContinuousClock.now - start
                let ms = (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15) / 100
                result = String(format: "%@ · %.2f ms per image (%@)", encoder.modelID, ms, encoder.computeUnitsDescription)
            } catch {
                result = "Model unavailable: \(error)"
            }
            await MainActor.run {
                benchmark = result
                benchmarking = false
            }
        }
    }

    nonisolated private static func syntheticImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 384, height: 288, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for i in 0..<12 {
            ctx.setFillColor(CGColor(red: CGFloat(i) / 12, green: 0.5, blue: 1 - CGFloat(i) / 12, alpha: 1))
            ctx.fill(CGRect(x: i * 32, y: 0, width: 32, height: 288))
        }
        return ctx.makeImage()!
    }
}
