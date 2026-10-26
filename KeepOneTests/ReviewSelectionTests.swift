import Foundation
import Testing
@testable import KeepOne

@Suite("Review selection & finger ranges")
struct ReviewSelectionTests {
    private func recommendations(_ count: Int, category: CleanupCategory = .priceTags, suggested: Int = 20) -> [Recommendation] {
        (0..<count).map { index in
            Recommendation(id: "photo-\(index)", category: category, tier: index < suggested ? .likely : .review,
                           reasons: [], clusterID: nil, bytes: 1_000, bytesExact: true, priority: 1,
                           personalScore: nil, preselect: index < suggested, creationDate: nil)
        }
    }

    @Test func priceTagsSelectTheWholeCategoryEvenWhenOnlyTwentyAreSuggested() {
        let items = recommendations(100)
        let selected = ReviewSelectionMemory().automaticIDs(in: .priceTags, from: items, queued: [], limit: 200)
        #expect(selected.count == 100)
        #expect(Set(selected) == Set(items.map(\.id)))
        #expect(items.filter(\.preselect).count == 20, "Selection doesn't change confidence or recommendations")
        #expect(TrashQueue().isEmpty, "Selecting never queues or deletes anything")
    }

    @Test func otherCategoriesKeepTheirConfidenceRules() {
        for category in [CleanupCategory.receipts, .documents, .largeVideos] {
            let items = recommendations(100, category: category, suggested: category == .largeVideos ? 0 : 20)
            let selected = ReviewSelectionMemory().automaticIDs(in: category, from: items, queued: [], limit: 200)
            #expect(selected.count == (category == .largeVideos ? 0 : 20))
        }
    }

    @Test func laterBatchesSkipQueuedAndManuallyUncheckedPhotosBeforeApplyingTheCap() {
        let items = recommendations(450)
        var memory = ReviewSelectionMemory()
        memory.rememberChange(from: ["photo-0", "photo-1"], to: [])
        let first = memory.automaticIDs(in: .priceTags, from: items, queued: [], limit: 200)
        #expect(first.count == 200)
        #expect(first.first == "photo-2")
        let second = memory.automaticIDs(in: .priceTags, from: items, queued: Set(first), limit: 200)
        #expect(second.count == 200)
        #expect(second.first == "photo-202")
        let last = memory.automaticIDs(in: .priceTags, from: items, queued: Set(first + second), limit: 200)
        #expect(last.count == 48)
        #expect(last.first == "photo-402")
        #expect(!Set(first + second + last).contains("photo-0"))
        #expect(!Set(first + second + last).contains("photo-1"))
    }

    @Test func manuallySelectingAnUncheckedPhotoOptsItBackIn() {
        var memory = ReviewSelectionMemory()
        memory.rememberChange(from: ["a", "b"], to: ["b"])
        #expect(memory.automaticIDs(from: ["a", "b"], queued: [], limit: 200) == ["b"])
        memory.rememberChange(from: ["b"], to: ["a", "b"])
        #expect(memory.automaticIDs(from: ["a", "b"], queued: [], limit: 200) == ["a", "b"])
    }

    @Test func uncheckedChoicesSurvivePersistenceAndClearingTheAnalysisCache() async throws {
        let store = try LibraryStore.inMemory()
        var memory = ReviewSelectionMemory()
        memory.rememberChange(from: ["a", "b"], to: ["b"])
        try await store.setCodable(memory, for: "selection.memory")
        try await store.clearAnalysisCache()
        let loaded = try #require(await store.codable(ReviewSelectionMemory.self, for: "selection.memory"))
        #expect(loaded.automaticIDs(from: ["a", "b"], queued: [], limit: 200) == ["b"])
        #expect(try await store.loadTrash().isEmpty)
        #expect(try await store.loadMarks().isEmpty, "Unchecked photos stay visible for manual selection")
    }

    @Test func draggingAcrossRowsSelectsARangeAndBacktrackingRestoresTheOriginalChoices() throws {
        let drag = try #require(ReviewSelectionDrag(ids: (0..<9).map(String.init), selection: ["8"], startingAt: "1", limit: 200))
        #expect(drag.selection(endingAt: "5") == ["1", "2", "3", "4", "5", "8"])
        #expect(drag.selection(endingAt: "2") == ["1", "2", "8"])
    }

    @Test func draggingFromASelectedPhotoUnchecksTheRange() throws {
        let drag = try #require(ReviewSelectionDrag(ids: (0..<9).map(String.init), selection: ["1", "2", "3", "4", "8"], startingAt: "1", limit: 200))
        #expect(drag.selection(endingAt: "4") == ["8"])
        #expect(drag.selection(endingAt: "2") == ["3", "4", "8"])
    }

    @Test func backwardDraggingRespectsTheCapAndKeepsExistingSelections() throws {
        let drag = try #require(ReviewSelectionDrag(ids: (0..<9).map(String.init), selection: ["8"], startingAt: "4", limit: 3))
        #expect(drag.selection(endingAt: "0") == ["3", "4", "8"])
        #expect(ReviewSelectionDrag(ids: ["a"], selection: [], startingAt: "missing", limit: 200) == nil)
    }
}

@Suite("Group selection for Trash")
struct GroupRemovalTests {
    private func group(_ id: String, members: [String], keepers: [String]) -> AssetCluster {
        let alternatives = members.filter { !keepers.contains($0) }
        return AssetCluster(id: id, kind: .similar, memberIDs: members, keeperIDs: keepers, tier: .likely,
                            similarity: 0.95, keeperReasons: [], memberReasons: [:], scores: [:],
                            memberTiers: Dictionary(uniqueKeysWithValues: alternatives.map { ($0, .review) }))
    }

    @Test func keepBestRemovesAlternativesFromMultipleSelectedGroups() {
        let groups = [group("one", members: ["a", "b", "c"], keepers: ["a"]),
                      group("two", members: ["d", "e"], keepers: ["d"])]
        let plan = GroupRemovalPlan(clusters: groups, mode: .keepBest, available: ["a", "b", "c", "d", "e"], queued: [])
        #expect(plan.assetIDs == ["b", "c", "e"], "Explicit group selection includes review-tier alternatives")
        #expect(TrashQueue().isEmpty, "Selecting groups never deletes or queues photos")
    }

    @Test func entireGroupsIncludesBestAndProtectedPhotosOnlyWhenExplicitlyChosen() {
        let groups = [group("one", members: ["a", "b", "c"], keepers: ["a", "b"])]
        let all = GroupRemovalPlan(clusters: groups, mode: .entireGroups, available: ["a", "b", "c"], queued: [], protected: ["c"])
        let best = GroupRemovalPlan(clusters: groups, mode: .keepBest, available: ["a", "b", "c"], queued: [], protected: ["c"])
        #expect(all.assetIDs == ["a", "b", "c"])
        #expect(best.assetIDs.isEmpty)
    }

    @Test func queuedAndVanishedPhotosDropOutAndMembersAreNotRepeated() {
        let groups = [group("one", members: ["a", "b", "missing"], keepers: ["a"]),
                      group("two", members: ["d", "b", "e"], keepers: ["d"])]
        for mode in [GroupRemovalMode.keepBest, .entireGroups] {
            let plan = GroupRemovalPlan(clusters: groups, mode: mode, available: ["a", "b", "d", "e"], queued: ["e"])
            #expect(plan.assetIDs == (mode == .keepBest ? ["b"] : ["a", "b", "d"]))
        }
    }

    @Test func keepersStaySafeEvenIfAnotherSelectedGroupSuggestsThem() {
        let groups = [group("one", members: ["a", "b"], keepers: ["a"]),
                      group("two", members: ["b", "c"], keepers: ["b"])]
        let plan = GroupRemovalPlan(clusters: groups, mode: .keepBest, available: ["a", "b", "c"], queued: [])
        #expect(plan.assetIDs == ["c"])
    }

    @Test func fallbackKeeperIsNeverRemovedAndNewPhotosDoNotJoinAFrozenSelection() {
        let frozen = [group("one", members: ["a", "b"], keepers: [])]
        let plan = GroupRemovalPlan(clusters: frozen, mode: .keepBest, available: ["a", "b", "new-photo"], queued: [])
        #expect(plan.assetIDs == ["b"])
        #expect(GroupRemovalPlan(clusters: [], mode: .entireGroups, available: ["a", "b"], queued: []).assetIDs.isEmpty)
    }
}
