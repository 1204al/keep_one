// KeepOne pipeline harness (macOS).
// Runs the real ScanCoordinator, Vision, Core ML, OCR, grouping and recommendation engine on a
// folder of photos/videos through file-backed fakes of the PhotoKit protocols — no Photos library,
// nothing leaves the Mac. Usage: scripts/run_pipeline_harness.sh <folder>
import AVFoundation
import CoreML
import CryptoKit
import Foundation
import ImageIO

final class FileLibrary: PhotoLibraryProviding, ThumbnailProviding, AssetResourceProviding, @unchecked Sendable {
    let files: [String: URL]
    let metadata: [AssetMetadata]
    init(dir: String) async {
        var f: [String: URL] = [:]; var m: [AssetMetadata] = []
        let df = DateFormatter(); df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        for name in try! FileManager.default.contentsOfDirectory(atPath: dir).sorted() {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            let id = name
            if ["mov", "mp4", "m4v"].contains((name as NSString).pathExtension.lowercased()) {
                let asset = AVURLAsset(url: url)
                let duration = (try? await asset.load(.duration).seconds) ?? 0
                let track = try? await asset.loadTracks(withMediaType: .video).first
                let size = (try? await track?.load(.naturalSize)) ?? .zero
                var date: Date?
                if let items = try? await asset.load(.metadata) {
                    for item in items where item.commonKey == .commonKeyCreationDate {
                        if let s = try? await item.load(.stringValue) { date = ISO8601DateFormatter().date(from: s) }
                    }
                }
                m.append(AssetMetadata(id: id, mediaType: .video, creationDate: date, pixelWidth: Int(size.width), pixelHeight: Int(size.height), duration: duration))
                f[id] = url
            } else if ["jpg", "jpeg", "heic", "png"].contains((name as NSString).pathExtension.lowercased()) {
                let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
                let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
                let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
                let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
                let date = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap { df.date(from: $0) }
                var lat = gps?[kCGImagePropertyGPSLatitude] as? Double, lon = gps?[kCGImagePropertyGPSLongitude] as? Double
                if (gps?[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = lat.map { -$0 } }
                if (gps?[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = lon.map { -$0 } }
                m.append(AssetMetadata(id: id, mediaType: .image, creationDate: date, pixelWidth: props[kCGImagePropertyPixelWidth] as! Int,
                                       pixelHeight: props[kCGImagePropertyPixelHeight] as! Int, latitude: lat, longitude: lon))
                f[id] = url
            }
        }
        files = f; metadata = m
    }
    func authorizationStatus() -> LibraryAuthorization { .authorized }
    func requestAuthorization() async -> LibraryAuthorization { .authorized }
    func fetchAllMetadata() async -> [AssetMetadata] { metadata }
    func changeNotifications() -> AsyncStream<Void> { AsyncStream { _ in } }
    func delete(_ plan: DeletionPlan) async throws -> [String] { [] }
    func analysisImage(for id: String, maxDimension: Int, allowNetwork: Bool) async -> CGImage? {
        guard let url = files[id], let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxDimension, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }
    func resourceInfo(for id: String) async -> ResourceInfo {
        let size = (try? files[id]!.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
        return ResourceInfo(bytes: size, filename: id, pairedVideoBytes: nil)
    }
    func originalContentHash(for id: String) async -> String? {
        guard let data = try? Data(contentsOf: files[id]!) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func videoAsset(for id: String, allowNetwork: Bool) async -> AVAsset? { files[id].map { AVURLAsset(url: $0) } }
}

@main struct E2E {
    static func main() async throws {
        let dir = CommandLine.arguments[1]
        let modelURL = try await MLModel.compileModel(at: URL(fileURLWithPath: CommandLine.arguments[2]))
        let bankBase = CommandLine.arguments[3]
        let lib = await FileLibrary(dir: dir)
        let config = MLModelConfiguration(); config.computeUnits = .all
        // Build encoder from a temp bundle-less path.
        let encoder = try TestEncoder(url: modelURL)
        let bank = try ConceptBank.load(json: Data(contentsOf: URL(fileURLWithPath: bankBase + ".json")), bin: Data(contentsOf: URL(fileURLWithPath: bankBase + ".bin")))
        let semantic = SemanticEngine(encoder: encoder, bank: bank)
        let analyzer = AssetAnalyzer(thumbnails: lib, resources: lib, vision: AppleVisionAnalyzer(), semantic: semantic, text: AppleTextAnalyzer(), video: AppleVideoAnalyzer())
        let store = try LibraryStore.inMemory()
        let coordinator = ScanCoordinator(store: store, library: lib, analyzer: analyzer)
        var settings = AppSettings(); settings.hasCompletedOnboarding = true
        await coordinator.configure(settings: settings)
        let start = Date()
        await coordinator.start()
        for await event in coordinator.events {
            if case .progress(let p) = event, case .completed = p.state { break }
        }
        print(String(format: "Scan finished in %.1f s for %d assets", Date().timeIntervalSince(start), lib.metadata.count))
        let perf = await PerformanceMonitor.shared.current()
        for (stage, t) in perf.timings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print(String(format: "  %-20@ mean %7.2f ms  max %7.2f ms  n=%d", stage.rawValue as NSString, t.meanMs, t.maxMs, t.count))
        }
        let (byID, grouping) = await coordinator.groupingSnapshot(context: GroupingContext())
        let records = Array(byID.values)
        let snap = RecommendationEngine.compute(EngineInput(records: records, grouping: grouping, settings: settings, marks: [:], queued: [], preference: PreferenceModel(), now: Date()))
        print("\nCLUSTERS")
        for c in grouping.clusters {
            print(" ", c.kind.rawValue, "keeper:", c.keeperIDs, "remove:", c.memberTiers.map { "\($0.key)=\($0.value.title)" }.sorted(), "why:", c.keeperReasons.map(\.text))
        }
        print("\nRECOMMENDATIONS")
        for cat in CleanupCategory.allCases {
            for rec in snap.recommendations(in: cat) {
                print(String(format: "  %-18@ %-12@ %-24@ %@", cat.rawValue as NSString, rec.tier.title as NSString, rec.id as NSString, rec.reasons.map(\.text).joined(separator: " | ") as NSString))
            }
        }
        print("\nPROTECTED:", snap.protectedImportant)
        print("\nCLEANUP SETS")
        let sets = CleanupSetBuilder.build(snapshot: snap, records: byID)
        for (n, set) in sets.enumerated() {
            print(String(format: "  %2d. %-22@ %-26@ %2d items, %2d pre-selected", n + 1, set.kind.title as NSString,
                         CleanupSetBuilder.dateLine(set) as NSString, set.count, set.suggestedIDs.count))
        }
        print("\nPER-ASSET SIGNALS")
        for r in records.sorted(by: { $0.id < $1.id }) where r.metadata.isImage {
            let top = (r.semantic?.groupScores ?? [:]).sorted { $0.value > $1.value }.prefix(2).map { "\($0.key)=\(String(format: "%.2f", $0.value))" }
            let t = r.text?.signals
            print(String(format: "  %-24@ aes=%@ util=%@ faces=%d txt=%d sem=%@ ocr[r=%.1f p=%.1f d=%.1f t=%.1f s=%.1f] qr=%d lines=%d extracted=%@",
                         r.id as NSString, r.vision?.aesthetics.map { String(format: "%.2f", $0) } ?? "-", r.vision?.isUtility.map { "\($0)" } ?? "-",
                         r.vision?.faceCount ?? -1, r.vision?.textRegionCount ?? -1, top.joined(separator: ",") as NSString,
                         t?.receipt ?? -1, t?.parking ?? -1, t?.deviceLabel ?? -1, t?.ticket ?? -1, t?.sensitive ?? -1, r.text?.qrCount ?? -1, r.text?.lineCount ?? -1,
                         (r.text?.extracted?.plainText.replacingOccurrences(of: "\n", with: " / ") ?? "-") as NSString))
        }
    }
}

final class TestEncoder: SemanticImageEncoder, @unchecked Sendable {
    let modelID = "MobileCLIP2-S0"; let inputSize = 256
    let model: MLModel
    init(url: URL) throws { let c = MLModelConfiguration(); c.computeUnits = .all; model = try MLModel(contentsOf: url, configuration: c) }
    func embedding(for image: CGImage) async throws -> [Float] {
        let buf = try PixelBufferFactory.squareBGRA(from: image, side: 256)
        let out = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buf)]))
        let arr = out.featureValue(for: "embedding")!.multiArrayValue!
        var v = [Float](repeating: 0, count: arr.count)
        arr.withUnsafeBufferPointer(ofType: Float16.self) { p in for i in 0..<v.count { v[i] = Float(p[i]) } }
        return VectorMath.normalized(v)
    }
}
