import Foundation
import Testing
@testable import KeepOne

/// Invariant: recommendation ≠ selection ≠ deletion.
@Suite("Trash Queue & deletion invariant")
struct TrashQueueTests {
    func entry(_ id: String, _ category: CleanupCategory? = .screenshots, bytes: Int64 = 1_000) -> TrashEntry {
        TrashEntry(id: id, category: category, clusterID: nil, addedAt: Date(), bytes: bytes, bytesExact: true, context: "test")
    }

    @Test func addingIsIdempotentAndTotalsAreTracked() {
        var queue = TrashQueue()
        #expect(queue.add([entry("a"), entry("b", bytes: 500)]).count == 2)
        #expect(queue.add([entry("a")]).isEmpty)
        #expect(queue.count == 2)
        #expect(queue.totalBytes == 1_500)
        queue.remove(["a"])
        #expect(queue.ids == ["b"])
    }

    @Test func groupsByReasonLargestFirst() {
        let queue = TrashQueue(entries: [entry("a", .receipts), entry("b", .exactDuplicates), entry("c", .exactDuplicates)])
        #expect(queue.groupedByReason.first?.category == .exactDuplicates)
        #expect(queue.groupedByReason.first?.entries.count == 2)
    }

    @Test func deletionPlanRequiresFinalReviewConfirmation() {
        var queue = TrashQueue(entries: [entry("a"), entry("b")])
        let confirmation = FinalReviewConfirmation(reviewedIDs: ["a", "b"], confirmedAt: Date())
        queue.add([entry("late")])   // added after the user looked at the final review
        let plan = try! #require(queue.makeDeletionPlan(confirmation: confirmation))
        #expect(plan.assetIDs == ["a", "b"])
        #expect(!plan.assetIDs.contains("late"))
    }

    @Test func itemsRemovedFromTheQueueAreNeverDeleted() {
        var queue = TrashQueue(entries: [entry("a"), entry("b")])
        let confirmation = FinalReviewConfirmation(reviewedIDs: ["a", "b"], confirmedAt: Date())
        queue.remove(["b"])
        #expect(queue.makeDeletionPlan(confirmation: confirmation)?.assetIDs == ["a"])
    }

    @Test func nothingConfirmedMeansNoPlan() {
        let queue = TrashQueue(entries: [entry("a")])
        #expect(queue.makeDeletionPlan(confirmation: FinalReviewConfirmation(reviewedIDs: [], confirmedAt: Date())) == nil)
        #expect(TrashQueue().makeDeletionPlan(confirmation: FinalReviewConfirmation(reviewedIDs: ["a"], confirmedAt: Date())) == nil)
    }

    @Test func computingRecommendationsNeverSelectsOrQueues() {
        let records = [Fixtures.record("a", hash: 7, contentHash: "x"), Fixtures.record("b", date: Fixtures.days(3), hash: 7, contentHash: "x")]
        let queue = TrashQueue()
        let grouping = GroupingEngine.compute(records: records, featurePrints: [:], embeddings: [:], context: GroupingContext())
        let snapshot = RecommendationEngine.compute(EngineInput(records: records, grouping: grouping, settings: AppSettings(), marks: [:],
                                                                queued: queue.ids, preference: PreferenceModel(), now: Fixtures.now))
        #expect(snapshot.recommendations["b"]?.preselect == true, "a SAFE item may be pre-ticked in a review screen…")
        #expect(queue.isEmpty, "…but nothing enters the Trash Queue without an explicit action")
        #expect(queue.makeDeletionPlan(confirmation: FinalReviewConfirmation(reviewedIDs: ["b"], confirmedAt: Date())) == nil)
    }
}
