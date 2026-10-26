import Foundation
import Testing
@testable import KeepOne

@Suite("Personal learning")
struct PersonalizationTests {
    func decision(_ id: String, _ kind: DecisionKind, _ category: CleanupCategory, record: AssetRecord) -> UserDecision {
        UserDecision(id: nil, assetID: id, kind: kind, category: category, context: "test", timestamp: Fixtures.now,
                     features: PreferenceFeatures.vector(record: record, category: category, tier: .review, clusterSize: 1, now: Fixtures.now))
    }

    @Test func learnsWhatThisUserConsidersJunk() {
        var decisions: [UserDecision] = []
        for i in 0..<15 {
            let receipt = Fixtures.record("r\(i)", date: Fixtures.days(120 + Double(i)), utility: true, semantic: [.receipt: 0.8])
            decisions.append(decision(receipt.id, .delete, .receipts, record: receipt))
            let kid = Fixtures.record("k\(i)", date: Fixtures.days(100 + Double(i)), faces: [0.7], semantic: [.memory: 0.8])
            decisions.append(decision(kid.id, .keep, .blurryFailed, record: kid))
        }
        let model = PreferenceModel.train(from: decisions)
        #expect(model.isActive)
        let newReceipt = Fixtures.record("new-r", date: Fixtures.days(150), utility: true, semantic: [.receipt: 0.75])
        let newKid = Fixtures.record("new-k", date: Fixtures.days(150), faces: [0.6], semantic: [.memory: 0.7])
        let pReceipt = model.probability(PreferenceFeatures.vector(record: newReceipt, category: .receipts, tier: .review, clusterSize: 1, now: Fixtures.now))!
        let pKid = model.probability(PreferenceFeatures.vector(record: newKid, category: .blurryFailed, tier: .review, clusterSize: 1, now: Fixtures.now))!
        #expect(pReceipt > 0.7)
        #expect(pKid < 0.3)
        #expect(model.trust(for: .blurryFailed) == .reduced)
        #expect(model.trust(for: .receipts) == .boosted)
    }

    @Test func restoringFromTrashCountsAsKeep() {
        let r = Fixtures.record("x")
        let model = PreferenceModel.train(from: [decision("x", .delete, .screenshots, record: r), decision("x", .restoreFromTrash, .screenshots, record: r)])
        #expect(model.categoryStats[.screenshots] == CategoryStat(accepted: 0, rejected: 1))
    }

    @Test func inactiveUntilEnoughDecisions() {
        let r = Fixtures.record("x")
        let model = PreferenceModel.train(from: [decision("x", .delete, .screenshots, record: r)])
        #expect(!model.isActive)
        #expect(model.probability(PreferenceFeatures.vector(record: r, category: .screenshots, tier: .review, clusterSize: 1, now: Fixtures.now)) == nil)
        #expect(!PreferenceModel.train(from: []).isActive, "reset ⇒ no learned influence")
    }

    @Test func featureVectorHasFixedDimension() {
        let v = PreferenceFeatures.vector(record: Fixtures.record("x"), category: .parking, tier: .likely, clusterSize: 3, now: Fixtures.now)
        #expect(v.count == PreferenceFeatures.dimension)
    }
}

@Suite("Retention rules")
struct RetentionTests {
    @Test func eligibility() {
        let rules = RetentionRules()
        #expect(RetentionPolicy.eligibility(category: .parking, ageDays: 3, rules: rules) == .tooRecent(days: 7))
        #expect(RetentionPolicy.eligibility(category: .parking, ageDays: 8, rules: rules) == .eligible(days: 7))
        #expect(RetentionPolicy.eligibility(category: .receipts, ageDays: 60, rules: rules) == .tooRecent(days: 90))
        #expect(RetentionPolicy.eligibility(category: .similarPhotos, ageDays: 1, rules: rules) == .noRule)
        var never = rules
        never.screenshots = .never
        #expect(RetentionPolicy.eligibility(category: .screenshots, ageDays: 999, rules: never) == .ageNotUsed)
    }

    @Test func settingsDecodeTolerantly() throws {
        let partial = #"{"protectFavorites": false, "recentDays": 3}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: partial)
        #expect(!settings.protectFavorites)
        #expect(settings.recentDays == 3)
        #expect(settings.retention.receipts == .days(90))
    }
}

@Suite("Sessions & filters")
struct SessionTests {
    func snapshot() -> RecommendationSnapshot {
        var records: [AssetRecord] = []
        for i in 0..<30 {
            let h = Fixtures.stableHash("pair\(i)")
            records.append(Fixtures.record("dup\(i)a", hash: h, contentHash: "h\(i)"))
            records.append(Fixtures.record("dup\(i)b", date: Fixtures.days(3), hash: h, contentHash: "h\(i)"))
        }
        for i in 0..<40 {
            records.append(Fixtures.record("black\(i)", quality: RecommendationTests.black, aesthetics: -0.9))
        }
        let grouping = GroupingEngine.compute(records: records, featurePrints: [:], embeddings: [:], context: GroupingContext())
        return RecommendationEngine.compute(EngineInput(records: records, grouping: grouping, settings: AppSettings(), marks: [:],
                                                        queued: [], preference: PreferenceModel(), now: Fixtures.now))
    }

    @Test func cleanupSetsStartWithExactDuplicates() {
        let s = snapshot()
        let records = Dictionary(uniqueKeysWithValues: s.recommendations.keys.map { ($0, Fixtures.record($0)) })
        let sets = CleanupSetBuilder.build(snapshot: s, records: records)
        #expect(sets.first?.kind == .duplicates)
    }

    @Test func smartFilterParsing() {
        #expect(SmartFilter.parse("receipts older than 1 year") == [.receipts, .olderThan1Year])
        #expect(SmartFilter.parse("videos over 500 MB") == [.videos, .over500MB])
        #expect(SmartFilter.parse("screenshots with no people") == [.screenshots, .noPeople])
    }
}
