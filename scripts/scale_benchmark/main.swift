// KeepOne scale benchmark (macOS). A synthetic, already-analysed library of N assets — moments,
// long events with drifting looks, later copies — run through the production persistence, grouping
// and recommendation code, the way a refresh does on the phone. Nothing touches real photos.
// Usage: scripts/run_scale_benchmark.sh [N] [dump-file]   (N defaults to 50000)
// With a dump file, every group and suggestion is written out so two builds can be compared with
// cmp: optimisations must leave it byte-for-byte identical.
import Foundation

struct RNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func unit(_ v: [Float]) -> [Float] { let n = sqrt(v.reduce(0) { $0 + $1 * $1 }); return v.map { $0 / max(n, 1e-6) } }
func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

@main struct Bench {
    static func main() async throws {
        let n = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 50_000 : 50_000
        var rng = RNG(state: 42)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var records: [AssetRecord] = []
        var fps: [String: [Float]] = [:], embs: [String: [Float]] = [:]
        records.reserveCapacity(n)
        var t = now.addingTimeInterval(-3 * 365 * 86_400)
        var i = 0
        let groups = SemanticGroup.allCases
        func perturb(_ v: [Float], _ amp: Float) -> [Float] { unit(v.map { $0 + Float.random(in: -amp...amp, using: &rng) }) }
        func perturbHash(_ h: UInt64, _ bits: Int) -> UInt64 { var h = h; for _ in 0..<bits { h ^= 1 << UInt64.random(in: 0..<64, using: &rng) }; return h }
        while i < n {
            // Either an event (20–150 shots over an hour or two, looks drifting → chains) or a moment (1–8 shots in seconds).
            let event = Int.random(in: 0..<100, using: &rng) < 12
            let count = event ? Int.random(in: 20...150, using: &rng) : (Int.random(in: 1...8, using: &rng) > 5 ? Int.random(in: 2...8, using: &rng) : 1)
            t = t.addingTimeInterval(Double.random(in: 600...60_000, using: &rng))
            var baseHash = UInt64.random(in: 0...UInt64.max, using: &rng)
            var baseFP = unit((0..<768).map { _ in Float.random(in: -1...1, using: &rng) })
            var baseEmb = unit((0..<512).map { _ in Float.random(in: -1...1, using: &rng) })
            var baseMicro = Data((0..<256).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let isShot = !event && Int.random(in: 0..<10, using: &rng) == 0
            let isVideo = !event && Int.random(in: 0..<14, using: &rng) == 0
            let lat = Double.random(in: 40...55, using: &rng), lon = Double.random(in: 0...30, using: &rng)
            var shotTime = t
            for k in 0..<count where i < n {
                if event, k > 0 {
                    shotTime = shotTime.addingTimeInterval(Double.random(in: 2...90, using: &rng))
                    if Int.random(in: 0..<10, using: &rng) < 4 {   // new subject
                        baseHash = UInt64.random(in: 0...UInt64.max, using: &rng)
                        baseFP = unit((0..<768).map { _ in Float.random(in: -1...1, using: &rng) })
                        baseEmb = unit((0..<512).map { _ in Float.random(in: -1...1, using: &rng) })
                        baseMicro = Data((0..<256).map { _ in UInt8.random(in: 0...255, using: &rng) })
                    } else {                                     // drift from the previous shot
                        baseHash = perturbHash(baseHash, Int.random(in: 1...5, using: &rng))
                        baseFP = perturb(baseFP, 0.03); baseEmb = perturb(baseEmb, 0.02)
                    }
                } else if k > 0 {
                    shotTime = shotTime.addingTimeInterval(1)
                }
                let id = String(format: "%08X-0000-4000-8000-%012X/L0/001", i, i)
                var md = AssetMetadata(id: id, mediaType: isVideo ? .video : .image, subtypes: isShot ? .screenshot : [],
                                       creationDate: shotTime, pixelWidth: isShot ? 1206 : 4032,
                                       pixelHeight: isShot ? 2622 : 3024, duration: isVideo ? Double.random(in: 1...300, using: &rng) : 0,
                                       isFavorite: Int.random(in: 0..<40, using: &rng) == 0,
                                       latitude: lat + Double.random(in: -0.0005...0.0005, using: &rng), longitude: lon + Double.random(in: -0.0005...0.0005, using: &rng))
                md.hasAdjustments = Int.random(in: 0..<30, using: &rng) == 0
                var r = AssetRecord(metadata: md)
                if !isVideo {
                    let hash = event || k == 0 ? baseHash : perturbHash(baseHash, Int.random(in: 0...6, using: &rng))
                    var micro = baseMicro
                    for j in 0..<micro.count where k > 0 { micro[j] = UInt8(clamping: Int(micro[j]) + Int.random(in: -6...6, using: &rng)) }
                    let q = QualityMetrics(sharpness: Float.random(in: 2...8, using: &rng), globalSharpness: Float.random(in: 2...8, using: &rng),
                                           detailSharpness: nil, motionBlur: Float.random(in: 0...0.6, using: &rng),
                                           meanLuma: Float.random(in: 0.2...0.7, using: &rng), lumaStdDev: 0.2, clippedHighlights: 0.01,
                                           crushedShadows: 0.02, dynamicRange: 0.6, entropy: 7, colorfulness: 0.4, edgeDensity: 0.1)
                    r.fingerprint = ImageFingerprint(pHash: hash, micro: micro, meanColor: [120, 110, 100], analyzedWidth: 384, analyzedHeight: 288, quality: q)
                    r.fingerprintVersion = PipelineVersion.fingerprint
                    let faces = Int.random(in: 0..<4, using: &rng) == 0 ? Int.random(in: 1...4, using: &rng) : 0
                    r.vision = VisionFeatures(faceCount: faces, faceQualities: (0..<faces).map { _ in Float.random(in: 0.2...0.9, using: &rng) },
                                              largestFaceArea: faces > 0 ? 0.05 : 0, facesTouchingEdge: 0, humanCount: faces,
                                              aesthetics: Float.random(in: -0.5...0.8, using: &rng), isUtility: isShot, smudge: 0,
                                              labels: [LabelScore(id: "outdoor", confidence: 0.6), LabelScore(id: "sky", confidence: 0.4)],
                                              textRegionCount: isShot ? 12 : 0, textCoverage: isShot ? 0.2 : 0)
                    r.visionVersion = PipelineVersion.vision
                    var scores: [String: Float] = [:]
                    var rest: Float = 1
                    for g in groups.shuffled(using: &rng).prefix(4) { let s = Float.random(in: 0...rest * 0.6, using: &rng); scores[g.rawValue] = s; rest -= s }
                    scores[SemanticGroup.memory.rawValue, default: 0] += rest
                    r.semantic = SemanticFeatures(modelID: "MobileCLIP2-S0", groupScores: scores, topConcept: "photo", topConceptScore: 0.3)
                    r.semanticVersion = PipelineVersion.semantic
                    r.textVersion = PipelineVersion.text
                    r.detailVersion = PipelineVersion.detail
                    fps[id] = event || k == 0 ? baseFP : perturb(baseFP, 0.08)
                    embs[id] = event || k == 0 ? baseEmb : perturb(baseEmb, 0.05)
                }
                r.storage = StorageInfo(bytes: isVideo ? 80_000_000 : 3_000_000, isExact: true)
                r.lastAnalyzedAt = now
                records.append(r)
                i += 1
            }
        }
        // Exact and smaller copies saved weeks later (messengers, re-imports) — exercises duplicates + far pairs.
        let originals = records.filter { $0.metadata.isImage && !$0.metadata.isScreenshot }
        for (c, src) in originals.enumerated() where c % 40 == 0 {
            var copy = src
            copy.metadata.id = String(format: "C%07X-0000-4000-8000-%012X/L0/001", c, c)
            copy.metadata.creationDate = src.metadata.creationDate?.addingTimeInterval(Double(14 + c % 50) * 86_400)
            if c % 80 == 0 { copy.metadata.pixelWidth = 1600; copy.metadata.pixelHeight = 1200 }
            copy.metadata.latitude = nil; copy.metadata.longitude = nil
            fps[copy.id] = fps[src.id]; embs[copy.id] = embs[src.id]
            records.append(copy)
        }
        let images = records.count(where: \.metadata.isImage)
        print("library: \(records.count) assets (\(images) photos, \(records.count - images) videos)")

        // Persistence: 24-asset transactions, as during a scan.
        let dbURL = URL(fileURLWithPath: NSTemporaryDirectory() + "keepone-scale-benchmark.sqlite")
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + suffix) }
        let store = try LibraryStore(database: SQLiteDatabase(url: dbURL))
        let clock = ContinuousClock()
        var start = clock.now
        var batch: [AssetRecord] = []
        var vecs: [(id: String, kind: VectorKind, vector: [Float])] = []
        for r in records {
            batch.append(r)
            if let f = fps[r.id] { vecs.append((r.id, .featurePrint, f)) }
            if let e = embs[r.id] { vecs.append((r.id, .semantic, e)) }
            if batch.count == 24 { try await store.commitAnalysis(records: batch, vectors: vecs); batch.removeAll(); vecs.removeAll() }
        }
        try await store.commitAnalysis(records: batch, vectors: vecs)
        print(String(format: "store analysis:   %7.0f ms", ms(clock.now - start)))
        let size = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int) ?? 0
        print(String(format: "database size:    %7.1f MB", Double(size) / 1_048_576))

        // Launch: what ScanCoordinator.bootstrap loads.
        records = []; fps = [:]; embs = [:]
        start = clock.now
        let loaded = try await store.loadAllRecords()
        let prints = PackedVectors(try await store.loadPackedVectors(kind: .featurePrint))
        let embeddings = PackedVectors(try await store.loadPackedVectors(kind: .semantic))
        print(String(format: "launch load:      %7.0f ms", ms(clock.now - start)))

        // A user with history: learned preferences, some kept/protected items, some queued.
        let byID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var settings = AppSettings()
        settings.hasCompletedOnboarding = true
        let sortedIDs = byID.keys.sorted()
        var preference = PreferenceModel()
        for (k, id) in sortedIDs.prefix(3_000).enumerated() where byID[id]!.metadata.isImage {
            let features = PreferenceFeatures.vector(record: byID[id]!, category: .similarPhotos, tier: .likely, clusterSize: 2, now: now)
            preference.observe(UserDecision(id: nil, assetID: id, kind: k % 3 == 0 ? .keep : .delete,
                                            category: k % 2 == 0 ? .similarPhotos : .blurryFailed,
                                            context: "benchmark", timestamp: now, features: features))
        }
        var marks: [String: AssetMark] = [:]
        for (k, id) in sortedIDs.enumerated() where k % 97 == 0 { marks[id] = k % 2 == 0 ? .kept : .protected }
        let queued = Set(sortedIDs.enumerated().filter { $0.offset % 71 == 0 }.map(\.element))
        let context = GroupingContext(forcedKeepers: Set(marks.filter { $0.value == .protected }.map(\.key)), preference: preference, now: now)

        // One refresh: grouping + recommendations.
        let all = Array(byID.values)
        start = clock.now
        let first = GroupingEngine.compute(records: all, featurePrints: prints, embeddings: embeddings, context: context, reusing: nil)
        print(String(format: "grouping:         %7.0f ms  (%d groups)", ms(clock.now - start), first.result.clusters.count))
        start = clock.now
        let snapshot = RecommendationEngine.compute(EngineInput(records: all, grouping: first.result, settings: settings, marks: marks,
                                                                queued: queued, preference: preference, now: now))
        let count = CleanupCategory.allCases.reduce(0) { $0 + snapshot.recommendations(in: $1).count }
        print(String(format: "recommendations:  %7.0f ms  (%d suggestions)", ms(clock.now - start), count))

        // A tap (Keep / Make best) changes keepers: detection is reused, only ranking reruns.
        var tapped = context
        tapped.forcedKeepers.insert(sortedIDs[sortedIDs.count / 3])
        tapped.chosenKeepers.insert(sortedIDs[sortedIDs.count / 2])
        start = clock.now
        _ = GroupingEngine.compute(records: all, featurePrints: prints, embeddings: embeddings, context: tapped, reusing: first.intermediates)
        print(String(format: "regroup after tap:%7.0f ms", ms(clock.now - start)))

        if CommandLine.arguments.count > 2 {
            var dump = ""
            for c in first.result.clusters.sorted(by: { $0.id < $1.id }) {
                dump += "\(c.id)|\(c.kind.rawValue)|\(c.memberIDs)|\(c.keeperIDs)|\(c.memberTiers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rawValue)" })|\(c.similarity)|\(c.keeperReasons.map(\.text))|\(c.scores.sorted { $0.key < $1.key }.map { "\($0.value)" })\n"
            }
            dump += "H\(first.result.hashCandidates.sorted())D\(first.result.detailCandidates.sorted())\n"
            for cat in CleanupCategory.allCases {
                for rec in snapshot.recommendations(in: cat) { dump += "\(cat.rawValue)|\(rec.id)|\(rec.tier.rawValue)|\(rec.reasons.map(\.text))\n" }
            }
            try dump.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
            print("results written to \(CommandLine.arguments[2])")
        }
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + suffix) }
    }
}
