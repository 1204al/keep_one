import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import KeepOne

/// In-memory stand-in for PhotoKit so the real ScanCoordinator can be exercised.
final class FakeLibrary: PhotoLibraryProviding, ThumbnailProviding, AssetResourceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var assets: [AssetMetadata]
    private var requests: [String] = []

    init(_ assets: [AssetMetadata]) { self.assets = assets }

    func setAssets(_ new: [AssetMetadata]) { lock.withLock { assets = new } }
    var thumbnailRequests: [String] { lock.withLock { requests } }
    func resetRequests() { lock.withLock { requests.removeAll() } }

    func authorizationStatus() -> LibraryAuthorization { .authorized }
    func requestAuthorization() async -> LibraryAuthorization { .authorized }
    func fetchAllMetadata() async -> [AssetMetadata] { lock.withLock { assets } }
    func changeNotifications() -> AsyncStream<Void> { AsyncStream { _ in } }
    func delete(_ plan: DeletionPlan) async throws -> [String] { plan.assetIDs }
    func analysisImage(for id: String, maxDimension: Int, allowNetwork: Bool) async -> CGImage? {
        // Only first-pass (analysis-size) requests count as "re-analysis".
        if maxDimension == AssetAnalyzer.analysisDimension { lock.withLock { requests.append(id) } }
        let h = Fixtures.stableHash(id)
        return Fixtures.image(cell: 4 + Int(h % 17), luma: (Int((h >> 8) % 100), 155 + Int((h >> 16) % 100)))
    }
    func resourceInfo(for id: String) async -> ResourceInfo { ResourceInfo(bytes: 1_000, filename: id + ".JPG") }
    func originalContentHash(for id: String) async -> String? { "hash-" + id }
    func videoAsset(for id: String, allowNetwork: Bool) async -> AVAsset? { nil }
}

struct FakeVision: VisionAnalyzing {
    func analyze(_ image: CGImage) async -> VisionOutput {
        VisionOutput(features: VisionFeatures(faceCount: 0, faceQualities: [], largestFaceArea: 0, facesTouchingEdge: 0, humanCount: 0,
                                              aesthetics: 0.2, isUtility: false, smudge: nil, labels: []),
                     featurePrint: Fixtures.vector(Int(truncatingIfNeeded: ImageMetrics.fingerprint(for: image)?.pHash ?? 0) & 0xFFFF))
    }
}

struct FakeText: TextAnalyzing {
    func recognize(_ image: CGImage) async -> TextRecognitionOutput {
        TextRecognitionOutput(lines: [], meanConfidence: 0, barcodeCount: 0, qrCount: 0)
    }
}

struct FakeVideo: VideoAnalyzing {
    func analyze(asset: AVAsset, duration: Double, semantic: SemanticEngine?) async -> (VideoFeatures, exactBytes: Int64?) {
        fatalError("not used")
    }
}

@Suite("Incremental scanning & cache", .serialized)
struct IncrementalScanTests {
    func makeCoordinator(_ library: FakeLibrary, store: LibraryStore) -> ScanCoordinator {
        let analyzer = AssetAnalyzer(thumbnails: library, resources: library, vision: FakeVision(), semantic: nil,
                                     text: FakeText(), video: FakeVideo())
        return ScanCoordinator(store: store, library: library, analyzer: analyzer)
    }

    func runToCompletion(_ coordinator: ScanCoordinator) async {
        let events = coordinator.events
        await coordinator.start()
        let deadline = Date().addingTimeInterval(30)
        for await event in events {
            if case .progress(let p) = event, case .completed = p.state { return }
            if Date() > deadline { Issue.record("scan timed out"); return }
        }
    }

    func asset(_ id: String, days: Double, favorite: Bool = false, edited: Bool = false) -> AssetMetadata {
        AssetMetadata(id: id, creationDate: Fixtures.days(days), modificationDate: Fixtures.days(days), isFavorite: favorite, hasAdjustments: edited)
    }

    @Test func onlyNewOrChangedAssetsAreReanalysed() async throws {
        let store = try LibraryStore.inMemory()
        let library = FakeLibrary((0..<6).map { asset("a\($0)", days: Double($0 * 10 + 1)) })
        let first = makeCoordinator(library, store: store)
        await first.bootstrap()
        await runToCompletion(first)
        #expect(Set(library.thumbnailRequests) == Set((0..<6).map { "a\($0)" }))

        // New asset, a favourite toggle (metadata only), an edit (pixels changed) and a removal.
        library.resetRequests()
        var assets = (0..<6).map { asset("a\($0)", days: Double($0 * 10 + 1)) }
        assets[1].isFavorite = true
        assets[2].hasAdjustments = true
        assets.remove(at: 5)
        assets.append(asset("new", days: 0.5))
        library.setAssets(assets)
        await runToCompletion(first)
        #expect(Set(library.thumbnailRequests) == ["a2", "new"])
        #expect(await first.record(for: "a5") == nil)
        #expect(await first.record(for: "a1")?.metadata.isFavorite == true)
        #expect(await first.record(for: "a1")?.fingerprint != nil, "analysis kept for metadata-only changes")

        // A fresh launch reuses the persisted cache: nothing to analyse.
        library.resetRequests()
        let relaunched = makeCoordinator(library, store: store)
        await relaunched.bootstrap()
        await runToCompletion(relaunched)
        #expect(library.thumbnailRequests.isEmpty)
        #expect(await relaunched.record(for: "new")?.fingerprint != nil)
    }

    @Test func pipelineVersionBumpInvalidatesOnlyThatStage() {
        var r = Fixtures.record("x", semantic: [.memory: 0.5])
        #expect(!r.needsFingerprint && !r.needsVision)
        #expect(!r.needsSemantic(modelID: "test"))
        #expect(r.needsSemantic(modelID: "MobileCLIP2-S2"), "a different model invalidates semantics only")
        r.visionVersion = 0
        #expect(r.needsVision && !r.needsFingerprint)
    }

    @Test func contentChangesAreDistinguishedFromMetadataChanges() {
        let base = AssetMetadata(id: "x", pixelWidth: 4032, pixelHeight: 3024)
        var fav = base; fav.isFavorite = true
        var edited = base; edited.hasAdjustments = true
        var cropped = base; cropped.pixelWidth = 3000
        #expect(!fav.contentDiffers(from: base))
        #expect(edited.contentDiffers(from: base))
        #expect(cropped.contentDiffers(from: base))
    }

    @Test func clearingTheCacheKeepsUserData() async throws {
        let store = try LibraryStore.inMemory()
        try await store.upsert([Fixtures.record("a")])
        try await store.commitAnalysis(records: [], vectors: [("a", .featurePrint, Fixtures.vector(1))])
        try await store.saveTrash([TrashEntry(id: "a", category: .screenshots, clusterID: nil, addedAt: Date(), bytes: 1, bytesExact: true, context: "t")])
        try await store.setMarks(["b"], mark: .protected)
        try await store.appendDecisions([UserDecision(id: nil, assetID: "a", kind: .delete, category: .screenshots, context: "t",
                                                      timestamp: Date(), features: [1, 2, 3])])
        try await store.clearAnalysisCache()
        #expect(try await store.loadAllRecords().isEmpty)
        #expect(try await store.loadVectors(kind: .featurePrint).isEmpty)
        #expect(try await store.loadTrash().map(\.id) == ["a"])
        #expect(try await store.loadMarks()["b"] == .protected)
        #expect(try await store.loadDecisions().first?.features == [1, 2, 3])
    }

    @Test func recordsRoundTripThroughTheStore() async throws {
        let store = try LibraryStore.inMemory()
        var r = Fixtures.record("x", semantic: [.receipt: 0.7])
        r.text = TextFeatures(lineCount: 3, characterCount: 20, meanConfidence: 0.9, text: "SUMA 1,00", signals: OCRSignals(receipt: 0.8),
                              barcodeCount: 0, qrCount: 1, extracted: nil)
        try await store.upsert([r])
        let loaded = try #require(try await store.loadAllRecords().first)
        #expect(loaded.metadata == r.metadata)
        #expect(loaded.fingerprint == r.fingerprint)
        #expect(loaded.semantic == r.semantic)
        #expect(loaded.text == r.text)
    }
}
