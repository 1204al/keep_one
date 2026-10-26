import Testing
@testable import KeepOne

@Suite("Best shot")
struct BestShotTests {
    let ranker = BestShotRanker(weights: .default)

    @Test func sharpestWinsAndIsExplained() {
        let sharp = Fixtures.record("sharp", quality: Fixtures.quality(sharpness: 7.5))
        let soft = Fixtures.record("soft", quality: Fixtures.quality(sharpness: 4.0))
        let outcome = ranker.rank([soft, sharp], forcedKeepers: [], protectEdited: true)
        #expect(outcome.keeperIDs == ["sharp"])
        #expect(outcome.keeperReasons.contains { $0.code == .sharpest })
        #expect(outcome.memberReasons["soft"]?.contains { $0.code == .blurrierThanKeeper } == true)
        #expect(!outcome.keeperReasons.contains { $0.text.contains("AI") })
    }

    @Test func faceQualityDecidesBetweenEquallySharpShots() {
        let eyesClosed = Fixtures.record("closed", faces: [0.2, 0.3])
        let eyesOpen = Fixtures.record("open", faces: [0.8, 0.75])
        let outcome = ranker.rank([eyesClosed, eyesOpen], forcedKeepers: [], protectEdited: true)
        #expect(outcome.keeperIDs.first == "open")
        #expect(outcome.keeperReasons.contains { $0.code == .bestFaces })
    }

    @Test func favoriteIsAnExtremelyStrongKeepSignal() {
        let best = Fixtures.record("best", quality: Fixtures.quality(sharpness: 8), aesthetics: 0.9)
        let fav = Fixtures.record("fav", quality: Fixtures.quality(sharpness: 3), favorite: true, aesthetics: -0.5)
        let outcome = ranker.rank([best, fav], forcedKeepers: [], protectEdited: true)
        #expect(outcome.keeperIDs.first == "fav")
    }

    @Test func editedPhotosAreAlwaysKept() {
        let a = Fixtures.record("a", quality: Fixtures.quality(sharpness: 8))
        let edited = Fixtures.record("edited", quality: Fixtures.quality(sharpness: 5), edited: true)
        let outcome = ranker.rank([a, edited], forcedKeepers: [], protectEdited: true)
        #expect(outcome.keeperIDs.contains("edited"))
    }

    @Test func userChoiceOverridesScores() {
        let a = Fixtures.record("a", quality: Fixtures.quality(sharpness: 8))
        let b = Fixtures.record("b", quality: Fixtures.quality(sharpness: 3))
        let outcome = ranker.rank([a, b], forcedKeepers: ["b"], protectEdited: true)
        #expect(outcome.keeperIDs.first == "b")
        #expect(outcome.keeperReasons.first?.code == .userChosen)
    }

    @Test func calibrationMovesWeightsTowardsTheUsersChoice() {
        let chosen = BestShotFeatures(sharpness: 0, exposure: 0, faceQuality: 1, aesthetics: 0.5, framing: 1, resolution: 0.5, personal: 0.5, faceCount: 0.5)
        let rejected = BestShotFeatures(sharpness: 1, exposure: 0, faceQuality: 0, aesthetics: 0.5, framing: 1, resolution: 0.5, personal: 0.5, faceCount: 0.5)
        let updated = BestShotCalibrator.update(weights: .default, chosen: chosen, rejected: rejected, learningRate: 0.2)
        #expect(updated.faceQuality > BestShotWeights.default.normalized().faceQuality)
        #expect(updated.sharpness < BestShotWeights.default.normalized().sharpness)
        #expect(abs(updated.asArray.reduce(0, +) - 1) < 1e-9)
    }
}
