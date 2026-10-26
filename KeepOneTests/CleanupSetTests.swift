import Foundation
import Testing
@testable import KeepOne

@Suite("Cleanup sets")
struct CleanupSetTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Duplicate pairs over many days, a long burst, and screenshots spread over months.
    func library() -> (snapshot: RecommendationSnapshot, records: [String: AssetRecord]) {
        var records: [AssetRecord] = []
        for day in 0..<20 {
            let t = Fixtures.days(40 + Double(day) * 3)
            for pair in 0..<3 {
                let h = Fixtures.stableHash("d\(day)p\(pair)")
                records.append(Fixtures.record("d\(day)p\(pair)a", date: t, hash: h, contentHash: "c\(day)\(pair)"))
                records.append(Fixtures.record("d\(day)p\(pair)b", date: t.addingTimeInterval(60), hash: h, contentHash: "c\(day)\(pair)"))
            }
        }
        // 40 identical copies of one shot: larger than a set, must be split with its best copy repeated.
        let big = Fixtures.days(200)
        for i in 0..<40 {
            records.append(Fixtures.record("big\(i)", date: big.addingTimeInterval(Double(i)), hash: 0xABCD, contentHash: "big"))
        }
        for month in 0..<8 {
            for i in 0..<(month % 2 == 0 ? 30 : 4) {
                records.append(Fixtures.record("s\(month)-\(i)", date: Fixtures.days(120 + Double(month) * 31 + Double(i) * 0.2),
                                               screenshot: true))
            }
        }
        let grouping = GroupingEngine.compute(records: records, featurePrints: [:], embeddings: [:], context: GroupingContext(now: Fixtures.now))
        let snapshot = RecommendationEngine.compute(EngineInput(records: records, grouping: grouping, settings: AppSettings(), marks: [:],
                                                                queued: [], preference: PreferenceModel(), now: Fixtures.now))
        return (snapshot, Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }))
    }

    @Test func setsAreSmallAndNeverRepeatASuggestion() {
        let lib = library()
        let sets = CleanupSetBuilder.build(snapshot: lib.snapshot, records: lib.records, calendar: calendar)
        #expect(!sets.isEmpty)
        var seen = Set<String>()
        for set in sets {
            #expect(set.count <= CleanupSetBuilder.maxSize)
            for id in set.itemIDs where !set.keeperIDs.contains(id) {
                #expect(seen.insert(id).inserted, "\(id) appears in two sets")
            }
        }
        // Every suggestion is offered somewhere.
        #expect(seen == Set(lib.snapshot.recommendations.keys))
    }

    @Test func groupsStayWholeAndOversizedOnesKeepTheirBestShot() {
        let lib = library()
        let sets = CleanupSetBuilder.build(snapshot: lib.snapshot, records: lib.records, calendar: calendar)
        for cluster in lib.snapshot.clusters.values where cluster.memberIDs.count <= CleanupSetBuilder.maxSize {
            // Where the group's suggestions are offered (a best copy elsewhere may reappear as a best shot).
            let holding = sets.filter { set in cluster.suggestedRemovals.contains { set.itemIDs.contains($0) && !set.keeperIDs.contains($0) } }
            #expect(holding.count == 1, "a small group is never split across sets")
        }
        let bigParts = sets.filter { $0.itemIDs.contains { $0.hasPrefix("big") } }
        #expect(bigParts.count == 2)
        let keepers = bigParts.map(\.keeperIDs)
        #expect(keepers.allSatisfy { $0 == keepers[0] && !$0.isEmpty }, "each part shows the same best copy")
    }

    @Test func setsAreConnectedInTime() {
        let lib = library()
        let sets = CleanupSetBuilder.build(snapshot: lib.snapshot, records: lib.records, calendar: calendar)
        for set in sets where set.kind != .duplicates && set.kind != .videoCopies {  // copies are connected by being copies
            guard let first = set.firstDate, let last = set.lastDate else { continue }
            let span = last.timeIntervalSince(first)
            if set.kind.isGrouped {
                #expect(span <= 32 * 86_400, "look-alike sets cover a day, or up to a month when small")
            } else {
                #expect(span <= 124 * 86_400, "other sets cover a month, or up to a season when small")
            }
        }
        // A busy month is one set of its own; quiet months merge with a neighbour.
        let screenshotSets = sets.filter { $0.kind == .screenshots }
        #expect(screenshotSets.count < 8)
    }

    @Test func onlyConfidentSuggestionsArePreselected() {
        let lib = library()
        for set in CleanupSetBuilder.build(snapshot: lib.snapshot, records: lib.records, calendar: calendar) {
            for id in set.suggestedIDs {
                #expect(lib.snapshot.recommendations[id]?.preselect == true)
                #expect(!set.keeperIDs.contains(id))
            }
        }
    }

    @Test func skippedSetsMoveToTheBackOfTheirKind() throws {
        let lib = library()
        let sets = CleanupSetBuilder.build(snapshot: lib.snapshot, records: lib.records, calendar: calendar)
        let duplicates = sets.filter { $0.kind == .duplicates }
        try #require(duplicates.count > 1)
        let skipped = Set(duplicates[0].itemIDs)
        let again = CleanupSetBuilder.build(snapshot: lib.snapshot, records: lib.records, deprioritized: skipped, calendar: calendar)
            .filter { $0.kind == .duplicates }
        #expect(again.last?.id == duplicates[0].id)
        #expect(again.first?.id != duplicates[0].id)
    }

    @Test func dateLinesReadNaturally() {
        let day = CleanupSet(id: "a", kind: .similar, rows: [], suggestedIDs: [], firstDate: Fixtures.days(10), lastDate: Fixtures.days(10))
        #expect(!CleanupSetBuilder.dateLine(day, calendar: calendar).contains("–"))
        let range = CleanupSet(id: "b", kind: .screenshots, rows: [], suggestedIDs: [], firstDate: Fixtures.days(100), lastDate: Fixtures.days(10))
        #expect(CleanupSetBuilder.dateLine(range, calendar: calendar).contains("–"))
    }
}
