import Foundation
import Testing
@testable import KeepOne

/// Regressions for edge cases found while testing the end-to-end pipelines.
@Suite("Edge cases", .serialized)
struct EdgeCaseTests {
    func makeCoordinator(_ library: FakeLibrary, store: LibraryStore) -> ScanCoordinator {
        let analyzer = AssetAnalyzer(thumbnails: library, resources: library, vision: FakeVision(), semantic: nil,
                                     text: FakeText(), video: FakeVideo())
        return ScanCoordinator(store: store, library: library, analyzer: analyzer)
    }

    func asset(_ id: String, days: Double) -> AssetMetadata {
        AssetMetadata(id: id, creationDate: Fixtures.days(days), modificationDate: Fixtures.days(days))
    }

    /// Runs `action`, then waits until no scan is running and returns the final state. Polls instead of
    /// reading `events`: that stream is buffered, so it would replay states from earlier runs.
    func settle(_ coordinator: ScanCoordinator, after action: () async -> Void) async -> ScanState {
        await action()
        let deadline = Date().addingTimeInterval(30)
        while await coordinator.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await coordinator.currentProgress.state
    }

    @Test func deletedAssetsDoNotComeBackWhilePhotoKitStillReportsThem() async throws {
        let store = try LibraryStore.inMemory()
        let library = FakeLibrary((0..<4).map { asset("a\($0)", days: Double($0 + 10)) })
        let coordinator = makeCoordinator(library, store: store)
        await coordinator.bootstrap()
        _ = await settle(coordinator) { await coordinator.start() }

        // Deleted in KeepOne, but a stale fetch still lists it.
        await coordinator.removeAssets(["a1"])
        _ = await settle(coordinator) { await coordinator.start() }
        #expect(await coordinator.record(for: "a1") == nil)

        // Once Photos stops reporting it, the tombstone is dropped; a restored asset is analysed again.
        library.setAssets((0..<4).filter { $0 != 1 }.map { asset("a\($0)", days: Double($0 + 10)) })
        _ = await settle(coordinator) { await coordinator.start() }
        library.setAssets((0..<4).map { asset("a\($0)", days: Double($0 + 10)) })
        _ = await settle(coordinator) { await coordinator.start() }
        #expect(await coordinator.record(for: "a1")?.fingerprint != nil)
    }

    @Test func aFinishedPausedRunNeverClearsTheNextOne() async throws {
        let store = try LibraryStore.inMemory()
        let library = FakeLibrary((0..<40).map { asset("p\($0)", days: Double($0 + 10)) })
        let coordinator = makeCoordinator(library, store: store)
        await coordinator.bootstrap()
        await coordinator.start()
        await coordinator.pause(.user)
        #expect(!(await coordinator.isRunning))
        // Resume: the new run must own the task until it completes (the old run's cleanup used to clear it).
        let final = await settle(coordinator) { await coordinator.start() }
        guard case .completed = final else {
            Issue.record("expected the resumed scan to complete, got \(final)")
            return
        }
        #expect(!(await coordinator.isRunning))
    }

    @Test func removingAssetsFromTheIndexKeepsMarksAndQueue() async throws {
        let store = try LibraryStore.inMemory()
        try await store.upsert([Fixtures.record("hidden")])
        try await store.setMarks(["hidden"], mark: .protected)
        try await store.saveTrash([TrashEntry(id: "hidden", category: .screenshots, clusterID: nil, addedAt: Date(),
                                              bytes: 1, bytesExact: true, context: "t")])
        try await store.deleteAssets(["hidden"])
        #expect(try await store.loadAllRecords().isEmpty)
        #expect(try await store.loadMarks()["hidden"] == .protected, "unhiding the photo restores its protection")
        #expect(try await store.loadTrash().map(\.id) == ["hidden"])
    }

    @Test func replacingDecisionsIsAtomic() async throws {
        let store = try LibraryStore.inMemory()
        let decision = UserDecision(id: nil, assetID: "a", kind: .delete, category: .screenshots, context: "t",
                                    timestamp: Date(), features: [1])
        try await store.appendDecisions([decision])
        try await store.replaceDecisions([decision, decision])
        #expect(try await store.loadDecisions().count == 2)
    }

    @Test func similarGroupIDsDoNotDependOnInputOrder() {
        // Same capture second (burst) and missing dates: order used to follow dictionary iteration.
        let t = Fixtures.days(20)
        let records = ["z", "m", "a"].map { Fixtures.record($0, date: t, hash: 1 << 40) }
        let prints = Dictionary(uniqueKeysWithValues: records.map { ($0.id, Fixtures.vector(7)) })
        let clusterer = SimilarityClusterer(featurePrints: prints, embeddings: [:])
        let forward = clusterer.cluster(records).map(\.memberIDs)
        let backward = clusterer.cluster(records.reversed()).map(\.memberIDs)
        #expect(forward == backward)
        #expect(forward.first?.first == "a")
    }

    @Test func unknownMutedCategoryKeepsTheKnownOnes() throws {
        let json = #"{"mutedCategories": ["screenshots", "somethingRemovedLater"], "retention": {"parking": {"days": {"_0": 14}}}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.mutedCategories == [.screenshots])
        #expect(settings.retention.parking == .days(14))
        #expect(settings.retention.receipts == .days(90), "a missing rule keeps its default, not the whole struct")
    }

    @Test func trainingKeepsAtMost4000Examples() {
        let features = [Float](repeating: 0.1, count: PreferenceFeatures.dimension)
        let decisions = (0..<4_500).map {
            UserDecision(id: nil, assetID: "a\($0)", kind: .delete, category: .screenshots, context: "t",
                         timestamp: Date(timeIntervalSince1970: Double($0)), features: features)
        }
        let model = PreferenceModel.train(from: decisions, epochs: 1)
        #expect(model.examples.count == 4_000)
        #expect(model.categoryStats[.screenshots]?.accepted == 4_500, "statistics still count every decision")
    }

    @Test func allSafeSessionAndBatchesNeverIncludeQueuedItems() {
        let rec = Recommendation(id: "x", category: .screenshots, tier: .safe, reasons: [], clusterID: nil, bytes: 1,
                                 bytesExact: true, priority: 1, personalScore: nil, preselect: true, creationDate: nil)
        var snapshot = RecommendationSnapshot.empty
        snapshot.recommendations = ["x": rec]
        snapshot.byCategory = [.screenshots: ["x"]]
        #expect(ReviewQueueBuilder.build(snapshot: snapshot, mode: .allSafe) == [.single("x")])
        #expect(ReviewQueueBuilder.build(snapshot: snapshot, mode: .allSafe, excluding: ["s:x"]).isEmpty,
                "“Another round” is only offered when a rebuild isn't empty")
    }
}
