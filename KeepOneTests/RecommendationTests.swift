import Testing
@testable import KeepOne

@Suite("Recommendations & protection")
struct RecommendationTests {
    func snapshot(_ records: [AssetRecord], settings: AppSettings = AppSettings(), marks: [String: AssetMark] = [:],
                  queued: Set<String> = [], preference: PreferenceModel = PreferenceModel()) -> RecommendationSnapshot {
        let grouping = GroupingEngine.compute(records: records, featurePrints: [:], embeddings: [:], context: GroupingContext(
            forcedKeepers: ProtectionPolicy.forcedKeepers(records: records, marks: marks, settings: settings)))
        return RecommendationEngine.compute(EngineInput(records: records, grouping: grouping, settings: settings, marks: marks,
                                                        queued: queued, preference: preference, now: Fixtures.now))
    }

    static let black = Fixtures.quality(sharpness: 1.0, meanLuma: 0.02, entropy: 1.5, edge: 0.0, crushed: 0.95, dynamicRange: 0.05)
    static let blurry = Fixtures.quality(sharpness: 2.0, entropy: 6.5, edge: 0.004)

    @Test func exactDuplicateIsSafeAndKeeperIsNeverRecommended() {
        let s = snapshot([Fixtures.record("a", hash: 7, contentHash: "x"), Fixtures.record("b", date: Fixtures.days(3), hash: 7, contentHash: "x")])
        #expect(s.recommendations["b"]?.tier == .safe)
        #expect(s.recommendations["b"]?.category == .exactDuplicates)
        #expect(s.recommendations["a"] == nil)
        #expect(s.summary(.exactDuplicates)?.count == 1)
    }

    @Test func favoritesAreNeverRecommended() {
        let s = snapshot([Fixtures.record("fav", quality: Self.black, favorite: true, aesthetics: -0.9)])
        #expect(s.recommendations.isEmpty)
    }

    @Test func recentPhotosAreProtectedButCopiesAreNot() {
        let recentBlack = Fixtures.record("recent", date: Fixtures.days(2), quality: Self.black, aesthetics: -0.9)
        let original = Fixtures.record("o", date: Fixtures.days(2), hash: 0x1234, contentHash: "same")
        let copy = Fixtures.record("c", date: Fixtures.days(1), hash: 0x1234, contentHash: "same")
        let s = snapshot([recentBlack, original, copy])
        #expect(s.recommendations["recent"] == nil)
        #expect(s.recommendations["c"]?.tier == .safe)
    }

    @Test func blackFrameWithoutPeopleIsLikely() {
        let s = snapshot([Fixtures.record("black", quality: Self.black, aesthetics: -0.9)])
        let rec = try! #require(s.recommendations["black"])
        #expect(rec.category == .blurryFailed)
        #expect(rec.tier == .likely)
        #expect(rec.reasons.contains { $0.code == .nearlyBlack })
    }

    @Test func blurryUniqueMomentWithPeopleIsOnlyReviewed() {
        let s = snapshot([Fixtures.record("kid", quality: Self.blurry, faces: [0.4], aesthetics: -0.5,
                                          semantic: [.memory: 0.6])])
        let rec = try! #require(s.recommendations["kid"])
        #expect(rec.tier == .review)
        #expect(!rec.preselect)
        #expect(rec.reasons.contains { $0.code == .uniqueMoment })
    }

    @Test func suspectedSensitiveDocumentsAreProtected() {
        let s = snapshot([Fixtures.record("passport", utility: true, semantic: [.sensitiveDocument: 0.6])])
        #expect(s.recommendations["passport"] == nil)
        #expect(s.protectedImportant == ["passport"])
    }

    @Test func damageEvidenceIsProtected() {
        let s = snapshot([Fixtures.record("dent", semantic: [.evidence: 0.5, .parking: 0.3])])
        #expect(s.recommendations["dent"] == nil)
        #expect(s.protectedImportant.contains("dent"))
    }

    func receipt(_ id: String, age: Double) -> AssetRecord {
        var r = Fixtures.record(id, date: Fixtures.days(age), utility: true, semantic: [.receipt: 0.8])
        r.text = TextFeatures(lineCount: 20, characterCount: 300, meanConfidence: 0.9, text: nil,
                              signals: OCRSignalExtractor.extract(lines: ["PARAGON FISKALNY", "SUMA PLN 37,67", "PTU A 23%"]),
                              barcodeCount: 0, qrCount: 0, extracted: nil)
        return r
    }

    @Test func receiptsFollowTheirRetentionRule() {
        let s = snapshot([receipt("old", age: 200), receipt("young", age: 30)])
        #expect(s.recommendations["old"]?.category == .receipts)
        #expect(s.recommendations["old"]?.tier == .likely)
        #expect(s.recommendations["old"]?.reasons.contains { $0.code == .mayMatterForWarranty } == true)
        #expect(s.recommendations["young"] == nil, "younger than the 90-day default")

        var never = AppSettings()
        never.retention.receipts = .never
        #expect(snapshot([receipt("old", age: 200)], settings: never).recommendations["old"]?.tier == .review)
    }

    @Test func mutedCategoriesDisappear() {
        var settings = AppSettings()
        settings.mutedCategories = [.blurryFailed]
        #expect(snapshot([Fixtures.record("black", quality: Self.black, aesthetics: -0.9)], settings: settings).recommendations.isEmpty)
    }

    @Test func skipListAndProtectionMarksAreRespected() {
        let s = snapshot([Fixtures.record("a", quality: Self.black, aesthetics: -0.9), Fixtures.record("b", quality: Self.black, aesthetics: -0.9)],
                         marks: ["a": .neverSuggest, "b": .protected])
        #expect(s.recommendations.isEmpty)
    }

    @Test func documentsAreNeverPreselected() {
        let s = snapshot([Fixtures.record("note", utility: true, semantic: [.document: 0.7])])
        let rec = try! #require(s.recommendations["note"])
        #expect(rec.category == .documents)
        #expect(!rec.preselect)
        #expect(rec.tier == .review)
    }

    @Test func lowTrustCategoriesAreDemoted() {
        var preference = PreferenceModel()
        preference.categoryStats[.blurryFailed] = CategoryStat(accepted: 1, rejected: 12)
        let s = snapshot([Fixtures.record("black", quality: Self.black, aesthetics: -0.9)], preference: preference)
        let rec = try! #require(s.recommendations["black"])
        #expect(rec.tier == .review)
        #expect(!rec.preselect)
        #expect(rec.reasons.contains { $0.code == .lowTrust })
    }

    @Test func similarGroupKeepsBestAndSuggestsTheRest() {
        let t = Fixtures.days(40)
        let sharp = Fixtures.record("sharp", date: t, hash: 0, quality: Fixtures.quality(sharpness: 7.5))
        let soft = Fixtures.record("soft", date: t.addingTimeInterval(1), hash: 0xFF, quality: Fixtures.quality(sharpness: 4.0))
        let grouping = GroupingEngine.compute(records: [sharp, soft],
                                              featurePrints: ["sharp": Fixtures.vector(1), "soft": Fixtures.vector(1, noise: 0.1, noiseSeed: 2)],
                                              embeddings: [:], context: GroupingContext())
        let s = RecommendationEngine.compute(EngineInput(records: [sharp, soft], grouping: grouping, settings: AppSettings(), marks: [:],
                                                         queued: [], preference: PreferenceModel(), now: Fixtures.now))
        #expect(s.recommendations["soft"]?.category == .similarPhotos)
        #expect(s.recommendations["sharp"] == nil)
        #expect(s.summary(.similarPhotos)?.groupCount == 1)
    }

    @Test func queuedItemsAreExcludedButNeverAddedByTheEngine() {
        let records = [Fixtures.record("a", hash: 7, contentHash: "x"), Fixtures.record("b", date: Fixtures.days(3), hash: 7, contentHash: "x")]
        let s = snapshot(records, queued: ["b"])
        #expect(s.recommendations["b"] == nil)
        #expect(s.clusters.isEmpty, "a group whose removals are all queued is done")
    }
}
