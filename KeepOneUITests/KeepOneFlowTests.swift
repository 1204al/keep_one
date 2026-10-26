import XCTest

/// End-to-end user pipelines against seeded Simulator media (see docs/TESTING.md). Every test starts
/// from the same suggestions (`-KeepOneResetUserState` clears the Trash Queue, marks and learning in
/// DEBUG builds; the analysis cache is kept). None of these tests deletes anything from Photos.
@MainActor
final class KeepOneFlowTests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-KeepOneSkipOnboarding", "YES", "-KeepOneResetUserState", "YES"]
        app.launch()
        tapSystemButton(["Allow Full Access", "Allow Access to All Photos"], timeout: 2)
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 20))
        // Suggestions are computed asynchronously after launch.
        _ = button(beginningWith: "Similar shots").waitForExistence(timeout: 120)
    }

    // MARK: Group review

    func testSelectingMultipleGroupsAndCancellingDoesNotQueuePhotos() throws {
        try openGroupList()
        app.buttons["Select"].tap()
        XCTAssertTrue(app.buttons["deleteSelectedGroups"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["deleteSelectedGroups"].isEnabled)
        XCTAssertFalse(app.buttons["deleteGroupsKeepBest"].isEnabled)
        let rows = groupRows
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        rows.element(boundBy: 0).tap()
        rows.element(boundBy: 1).tap()
        XCTAssertEqual(app.staticTexts["selectedGroupCount"].label, "2 groups selected")
        XCTAssertEqual(rows.element(boundBy: 0).value as? String, "Selected")
        rows.element(boundBy: 0).tap()
        XCTAssertEqual(app.staticTexts["selectedGroupCount"].label, "1 group selected")
        app.buttons["Select all"].tap()
        XCTAssertTrue(app.buttons["Deselect all"].waitForExistence(timeout: 3))
        app.buttons["Deselect all"].tap()
        XCTAssertEqual(app.staticTexts["selectedGroupCount"].label, "Tap groups to select")
        snapshot("group-list-multiple-selection")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Review groups"].waitForExistence(timeout: 3))
        XCTAssertFalse(trashBar.exists, "Selecting and cancelling never queues photos")
    }

    func testDeletingSelectedGroupsKeepsBestWhenChosen() throws {
        try openGroupList()
        let keepers = groupListPhotos.matching(NSPredicate(format: "value == 'Recommended keeper'"))
            .allElementsBoundByIndex.map(\.identifier)
        app.buttons["Select"].tap()
        groupRows.element(boundBy: 0).tap()
        groupRows.element(boundBy: 1).tap()
        let keepBest = app.buttons["deleteGroupsKeepBest"]
        let expected = selectedGroupPhotoCount(keepBest)
        XCTAssertGreaterThan(expected, 0)
        XCTAssertGreaterThan(selectedGroupPhotoCount(app.buttons["deleteSelectedGroups"]), expected)
        snapshot("group-list-keep-best-selection")
        keepBest.tap()
        XCTAssertEqual(trashCount(), expected)
        trashBar.tap()
        XCTAssertTrue(button(beginningWith: "Delete \(expected) ").waitForExistence(timeout: 5))
        for keeper in keepers {
            let id = keeper.replacingOccurrences(of: "groupListPhoto.", with: "trashPhoto.")
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: id).firstMatch.exists)
        }
        snapshot("group-list-keep-best-final-review")
    }

    func testDeletingEntireSelectedGroupsIncludesKeepersAndCanBeUndoneTogether() throws {
        try openGroupList()
        app.buttons["Select"].tap()
        groupRows.element(boundBy: 0).tap()
        groupRows.element(boundBy: 1).tap()
        let delete = app.buttons["deleteSelectedGroups"]
        let expected = selectedGroupPhotoCount(delete)
        XCTAssertGreaterThan(expected, selectedGroupPhotoCount(app.buttons["deleteGroupsKeepBest"]))
        snapshot("group-list-entire-groups-selection")
        delete.tap()
        XCTAssertEqual(trashCount(), expected, "All shots, including the best, wait for final review")
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))
        app.buttons["Undo"].tap()
        XCTAssertTrue(trashBar.waitForNonExistence(timeout: 5), "One Undo restores the entire group selection")
        XCTAssertTrue(app.buttons["Review groups"].waitForExistence(timeout: 5))
    }

    func testHoldingGroupListPhotoReturnsWithoutOpeningAGroup() throws {
        try openGroupList()
        let photo = groupListPhotos.matching(NSPredicate(format: "value == 'Recommended keeper'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(forDuration: 6)
        XCTAssertTrue(app.buttons["Review groups"].exists, "Releasing the preview doesn't navigate into the group")
        XCTAssertFalse(app.buttons["More actions"].exists)
        XCTAssertFalse(trashBar.exists)
        snapshot("group-list-hold-released")
        groupRows.firstMatch.tap()
        XCTAssertTrue(groupAccept.waitForExistence(timeout: 5), "A normal row tap still opens group review")
        app.buttons["All groups"].tap()
        XCTAssertTrue(app.buttons["Review groups"].waitForExistence(timeout: 5))
    }

    func testHoldingGroupListPhotosDuringSelectionPreservesSelectedGroups() throws {
        try openGroupList()
        app.buttons["Select"].tap()
        groupRows.firstMatch.tap()
        let originalCount = app.staticTexts["selectedGroupCount"].label
        let originalAction = app.buttons["deleteSelectedGroups"].label
        let keeper = groupListPhotos.matching(NSPredicate(format: "value == 'Recommended keeper'")).firstMatch
        keeper.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(forDuration: 6)
        XCTAssertEqual(app.staticTexts["selectedGroupCount"].label, originalCount)
        XCTAssertEqual(groupRows.firstMatch.value as? String, "Selected")
        let alternative = groupListPhotos.matching(NSPredicate(format: "value != 'Recommended keeper'")).firstMatch
        XCTAssertTrue(alternative.exists)
        alternative.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(forDuration: 6)
        XCTAssertEqual(app.staticTexts["selectedGroupCount"].label, originalCount)
        XCTAssertEqual(app.buttons["deleteSelectedGroups"].label, originalAction)
        XCTAssertFalse(app.buttons["More actions"].exists)
        snapshot("group-list-selection-hold-released")
    }

    func testHoldingGroupThumbnailPreviewsWithoutChangingSelection() throws {
        try open(card: "Similar shots")
        XCTAssertTrue(groupAccept.waitForExistence(timeout: 10))
        let originalAction = groupAccept.label
        let photo = app.buttons.matching(NSPredicate(format: "value == 'Selected for Trash'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        let originalValue = photo.value as? String
        try holdToPreview(photo, snapshotName: "group-hold-preview")
        XCTAssertEqual(photo.value as? String, originalValue)
        XCTAssertEqual(groupAccept.label, originalAction, "Holding a thumbnail only previews it")
    }

    func testHoldingSetPhotoPreviewsWithoutChangingSelection() throws {
        button(beginningWith: "Start cleanup").tap()
        let move = button(beginningWith: "Move ")
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        let originalAction = move.label
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'setPhoto.' AND value == 'Selected for Trash'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        try holdToPreview(photo, snapshotName: "set-hold-preview")
        XCTAssertEqual(move.label, originalAction, "Holding a photo doesn't toggle its selection badge")
        XCTAssertEqual(photo.value as? String, "Selected for Trash")
    }

    func testHoldingSelectedCategoryPhotoReturnsOnRelease() throws {
        try open(card: "Blurry")
        app.buttons["Select"].tap()
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'categoryPhoto.' AND value == 'Selected'"))
        XCTAssertTrue(selected.firstMatch.waitForExistence(timeout: 5))
        let originalCount = selected.count
        let photo = selected.firstMatch
        let identifier = photo.identifier
        let label = photo.label
        try holdToPreview(photo, snapshotName: "selected-grid-hold-preview")
        XCTAssertEqual(app.buttons[identifier].value as? String, "Selected")
        XCTAssertEqual(selected.count, originalCount, "Releasing a held preview preserves the whole selection")
        XCTAssertFalse(trashBar.exists, "Previewing doesn't queue anything for deletion")
        app.buttons["Cancel"].tap()
        app.buttons[identifier].tap()
        XCTAssertTrue(app.buttons["More actions"].waitForExistence(timeout: 5))
        let image = try XCTUnwrap(app.images.matching(identifier: "photoPreviewImage").allElementsBoundByIndex.first { $0.isHittable })
        XCTAssertEqual(image.label, label)
        image.pinch(withScale: 2, velocity: 1)
        snapshot("selected-grid-hold-preview-zoomed")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Select"].exists, "A normal tap still opens the persistent viewer")
        XCTAssertFalse(trashBar.exists, "Previewing doesn't queue anything for deletion")
    }

    func testHoldingTrashPhotoPreviewsWithoutRemovingIt() throws {
        try queueSafeDuplicates()
        let originalCount = trashCount()
        trashBar.tap()
        let photo = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'trashPhoto.'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        let delete = button(beginningWith: "Delete ")
        let originalAction = delete.label
        try holdToPreview(photo, snapshotName: "trash-hold-preview")
        XCTAssertEqual(delete.label, originalAction, "The final deletion selection stays unchanged")
        XCTAssertTrue(photo.exists)
        app.buttons["Close"].tap()
        XCTAssertEqual(trashCount(), originalCount)
    }

    func testHoldingVideoReturnsOnRelease() throws {
        try open(card: "Accidental videos")
        let video = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'videoPhoto.'")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        let identifier = video.identifier
        // Keep the touch down long enough to observe autoplay and looping in the Simulator recording.
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).press(forDuration: 8)
        XCTAssertTrue(peekPreview.waitForNonExistence(timeout: 2), "Release closes the playing preview immediately")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists)
        XCTAssertFalse(app.buttons["More actions"].exists)
        XCTAssertFalse(trashBar.exists)
        snapshot("video-hold-released")
        video.tap()
        XCTAssertTrue(app.buttons["More actions"].waitForExistence(timeout: 5), "A normal tap still opens the video viewer")
        app.buttons["Done"].tap()
    }

    func testTappingMainPhotoOpensZoomablePreview() throws {
        try open(card: "Similar shots")
        XCTAssertTrue(groupAccept.waitForExistence(timeout: 10))
        let originalAction = groupAccept.label
        let keeperLabel = app.buttons.matching(NSPredicate(format: "value == 'Recommended keeper'")).firstMatch.label
        snapshot("group-before-photo-preview")
        app.buttons["groupPhotoPreview"].tap()
        snapshot("group-after-photo-tap")
        XCTAssertTrue(app.buttons["More actions"].waitForExistence(timeout: 5))
        let image = app.images.matching(identifier: "photoPreviewImage").allElementsBoundByIndex.first { $0.isHittable }
        let preview = try XCTUnwrap(image)
        XCTAssertEqual(preview.label, keeperLabel, "The preview shows the tapped photo")
        snapshot("photo-preview-before-zoom")
        preview.pinch(withScale: 2, velocity: 1)
        snapshot("photo-preview-zoomed")
        XCTAssertTrue(app.buttons["Done"].isHittable)
        app.buttons["Done"].tap()
        XCTAssertTrue(groupAccept.waitForExistence(timeout: 5))
        XCTAssertEqual(groupAccept.label, originalAction, "Previewing doesn't change the cleanup selection")
    }

    func testTappingThumbnailPreviewsTheChosenShot() throws {
        try open(card: "Similar shots")
        XCTAssertTrue(groupAccept.waitForExistence(timeout: 10))
        let originalAction = groupAccept.label
        let alternative = app.buttons.matching(NSPredicate(format: "value == 'Selected for Trash'")).firstMatch
        XCTAssertTrue(alternative.waitForExistence(timeout: 5))
        alternative.tap()
        XCTAssertTrue(app.buttons["More actions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 of'")).firstMatch.exists)
        snapshot("thumbnail-photo-preview")
        app.buttons["Done"].tap()
        XCTAssertTrue(groupAccept.waitForExistence(timeout: 5))
        XCTAssertEqual(groupAccept.label, originalAction)
        XCTAssertTrue(app.buttons["Make best"].exists, "Returning keeps the chosen shot in focus")
    }

    func testTappingSetPhotoPreviewsWithoutChangingSelection() throws {
        let start = button(beginningWith: "Start cleanup")
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let move = button(beginningWith: "Move ")
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        let originalAction = move.label
        let photo = app.buttons.matching(NSPredicate(format: "value == 'Selected for Trash'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        XCTAssertTrue(app.buttons["More actions"].waitForExistence(timeout: 5))
        snapshot("set-photo-preview")
        app.buttons["Done"].tap()
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        XCTAssertEqual(move.label, originalAction, "A tap previews the photo without deselecting it")
    }

    func testGroupBadgeChangesSelectionWithoutOpeningPreview() throws {
        try open(card: "Similar shots")
        XCTAssertTrue(groupAccept.waitForExistence(timeout: 10))
        let selected = app.buttons.matching(NSPredicate(format: "value == 'Selected for Trash'"))
        let before = selected.count
        XCTAssertGreaterThan(before, 0)
        selected.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.1)).tap()
        XCTAssertEqual(selected.count, before - 1)
        XCTAssertFalse(app.buttons["More actions"].exists, "Only tapping the photo opens a preview")
        XCTAssertTrue(app.buttons["groupPhotoPreview"].isHittable)
    }

    func testTrashAllQueuesEveryShotIncludingTheKeeper() throws {
        try open(card: "Similar shots")
        XCTAssertTrue(groupAccept.waitForExistence(timeout: 10))
        let members = app.buttons.matching(NSPredicate(format: "value IN %@", ["Recommended keeper", "Selected for Trash", "Keep"]))
        let count = members.count
        XCTAssertGreaterThanOrEqual(count, 2)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "value == 'Recommended keeper'")).firstMatch.exists)
        snapshot("group-trash-all-option")
        app.buttons["Trash all"].tap()
        goBack()
        XCTAssertEqual(trashCount(), count, "Trash all includes the recommended keeper, not only the suggested removals")
        trashBar.tap()
        XCTAssertTrue(button(beginningWith: "Delete \(count) items").waitForExistence(timeout: 5), "Every shot waits for the final review")
        snapshot("group-trash-all-final-review")
    }

    func testTrashAllCanBeUndone() throws {
        try open(card: "Similar shots")
        XCTAssertTrue(groupAccept.waitForExistence(timeout: 10))
        app.buttons["Trash all"].tap()
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.tap()
        goBack()
        XCTAssertTrue(trashBar.waitForNonExistence(timeout: 5), "Undo restores the whole group, including its keeper")
        XCTAssertTrue(scrollTo(button(beginningWith: "Similar shots")), "The group can be reviewed again")
    }

    func testGroupReviewKeepBestShowsItemSummary() throws {
        try open(card: "Similar shots")
        let keepBest = groupAccept
        XCTAssertTrue(keepBest.waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["Home"].isHittable, "Group review hides the tab bar (focus mode)")
        snapshot("group-review")

        app.buttons["Why this one?"].tap()
        XCTAssertTrue(app.navigationBars["Why this one?"].waitForExistence(timeout: 5))
        snapshot("why-this-one")
        app.buttons["Done"].firstMatch.tap()

        // Accept every remaining group with one tap each.
        var accepted = 0
        while groupAccept.waitForExistence(timeout: 4), accepted < 10 {
            groupAccept.tap()
            accepted += 1
        }
        XCTAssertTrue(app.staticTexts["Nice."].waitForExistence(timeout: 5))
        let reviewed = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'items reviewed'")).firstMatch
        XCTAssertTrue(reviewed.exists, "The summary counts photos, not groups")
        snapshot("group-summary")
        XCTAssertTrue(app.buttons["Review Trash"].waitForExistence(timeout: 5), "The summary leads to the final step")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
    }

    func testSkippingAGroupMovesToTheNextOne() throws {
        try open(card: "Similar shots")
        XCTAssertTrue(groupAccept.waitForExistence(timeout: 10))
        let first = app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 of'")).firstMatch
        guard first.exists, first.label != "1 of 1" else { throw XCTSkip("Needs at least two similar groups") }
        app.buttons["Skip"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 of'")).firstMatch
            .waitForExistence(timeout: 5))
    }

    /// Home → group review → All groups → a group → All groups must go *back* to the list, not push another one.
    func testAllGroupsButtonDoesNotStackScreens() throws {
        try open(card: "Similar shots")
        let allGroups = app.buttons["All groups"]
        guard allGroups.waitForExistence(timeout: 10) else { throw XCTSkip("Only one similar group") }
        allGroups.tap()
        let review = app.buttons["Review groups"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        XCTAssertTrue(allGroups.waitForExistence(timeout: 5))
        allGroups.tap()
        XCTAssertTrue(review.waitForExistence(timeout: 5), "Returned to the same list")
        goBack()
        XCTAssertTrue(groupAccept.waitForExistence(timeout: 5), "List → first review")
        goBack()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5), "Two Backs reach Home")
    }

    // MARK: Category grid

    func testCategoryTrashAutomaticallySelectsTheNextBatch() throws {
        selectionBatchLimit(2)
        try open(card: "Blurry")
        app.buttons["Select"].tap()
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'categoryPhoto.' AND value == 'Selected'"))
        snapshot("grid-first-batch-selected")
        XCTAssertEqual(selected.count, 2)
        let firstBatch = Set(selected.allElementsBoundByIndex.map(\.identifier))
        app.buttons["Trash"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "The grid stays in selection mode")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2' AND label CONTAINS 'selected'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(selected.count, 2)
        XCTAssertTrue(firstBatch.isDisjoint(with: selected.allElementsBoundByIndex.map(\.identifier)))
        snapshot("grid-next-batch-selected")
    }

    func testUncheckedPhotoStaysUncheckedAfterTrashAndRelaunch() throws {
        selectionBatchLimit(2)
        try open(card: "Blurry")
        app.buttons["Select"].tap()
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'categoryPhoto.' AND value == 'Selected'")).firstMatch
        let id = photo.identifier
        photo.tap()
        XCTAssertEqual(app.buttons[id].value as? String, "Not selected")
        app.buttons["Trash"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons[id].value as? String, "Not selected", "The next batch skips a manually unchecked photo")
        snapshot("grid-unchecked-photo-remembered")
        // Relaunch without the per-test reset; this verifies the saved on-device preference.
        app.launchArguments = ["-KeepOneSkipOnboarding", "YES", "-KeepOneSelectionCap", "2"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 20))
        try open(card: "Blurry")
        app.buttons["Select"].tap()
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), "An unchecked photo stays available for manual selection")
        XCTAssertEqual(app.buttons[id].value as? String, "Not selected")
    }

    func testFingerSweepSelectsAndUnselectsPhotos() throws {
        try open(card: "Blurry")
        app.buttons["Select"].tap()
        if app.buttons["Select all"].exists { app.buttons["Select all"].tap() }
        app.buttons["Deselect all"].tap()
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'categoryPhoto.'"))
            .allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertGreaterThanOrEqual(photos.count, 3)
        let start = photos[0].coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
        let end = photos[2].coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        snapshot("grid-after-finger-sweep")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'categoryPhoto.' AND value == 'Selected'")).count, 3)
        XCTAssertFalse(app.buttons["More actions"].exists)
        snapshot("grid-finger-sweep-selected")
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'categoryPhoto.' AND value == 'Selected'")).count, 0)
        XCTAssertTrue(app.staticTexts["Tap photos to select"].exists)
    }

    func testVerticalSwipeDoesNotChangeTheSelection() throws {
        selectionBatchLimit(2)
        try open(card: "Blurry")
        app.buttons["Select"].tap()
        let count = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2' AND label CONTAINS 'selected'")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let before = count.label
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertEqual(count.label, before, "A vertical swipe scrolls instead of selecting photos")
        XCTAssertFalse(app.buttons["More actions"].exists)
    }

    func testGroupUncheckedShotStaysUncheckedWhenReopened() throws {
        try open(card: "Similar shots")
        let photo = app.buttons.matching(NSPredicate(format: "value == 'Selected for Trash'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        let id = photo.identifier
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.1)).tap()
        XCTAssertEqual(app.buttons[id].value as? String, "Keep")
        goBack()
        try open(card: "Similar shots")
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons[id].value as? String, "Keep")
    }

    func testSetUncheckedPhotoStaysUncheckedWhenReopened() throws {
        button(beginningWith: "Start cleanup").tap()
        let photo = app.buttons.matching(NSPredicate(format: "value == 'Selected for Trash'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        let id = photo.identifier
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.1)).tap()
        XCTAssertEqual(app.buttons[id].value as? String, "Kept")
        goBack()
        button(beginningWith: "Start cleanup").tap()
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons[id].value as? String, "Kept")
    }

    func testFingerSweepInCleanupSetSelectsAcrossGroups() throws {
        button(beginningWith: "Start cleanup").tap()
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'setPhoto.'"))
            .allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(photos.count, 4, "Seeded identical copies: two pairs side by side")
        let start = photos[0].coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6))
        let end = photos[3].coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(button(beginningWith: "Move 4 to Trash").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["More actions"].exists, "A sweep selects without opening a photo")
        snapshot("set-finger-sweep-selected")
    }

    func testCategoryGridSelectionStartsFromSuggestions() throws {
        try open(card: "Blurry")
        let select = app.buttons["Select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        let selectAll = app.buttons["Select all"]
        let deselectAll = app.buttons["Deselect all"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3) || deselectAll.exists)
        snapshot("grid-select-mode")
        if selectAll.exists { selectAll.tap() }
        XCTAssertTrue(deselectAll.waitForExistence(timeout: 3))
        deselectAll.tap()
        XCTAssertTrue(app.staticTexts["Tap photos to select"].waitForExistence(timeout: 3))
        selectAll.tap()
        app.buttons["Trash"].tap()
        XCTAssertTrue(trashBar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All done"].waitForExistence(timeout: 5), "Every item left the grid")
        snapshot("grid-after-trash")
    }

    // MARK: Viewer & Trash

    func testSharingPhotoPresentsFileAndReturnsToViewer() throws {
        try open(card: "Blurry")
        let photo = element(containing: "Suggested: Blurry")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        try shareFileAndReturn(snapshotName: "share-photo", saveAction: "Save Image")
    }

    func testSharingVideoPresentsFileAndReturnsToViewer() throws {
        try open(card: "Accidental videos")
        let video = element(containing: "Suggested: Accidental videos")
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.tap()
        try shareFileAndReturn(snapshotName: "share-video", saveAction: "Save Video")
    }

    func testKeepInViewerTakesItemOutOfTrash() throws {
        try queueSafeDuplicates()
        let before = trashCount()
        trashBar.tap()
        // Cells are buttons (they open the photo), so match by label rather than element type.
        let photo = element(containing: "In Trash Queue")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        let keep = app.buttons["Keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Trash"].exists, "A queued item offers Keep only — no second, contradictory action")
        snapshot("viewer-queued-item")
        keep.tap()
        if app.buttons["Done"].waitForExistence(timeout: 2) { app.buttons["Done"].firstMatch.tap() }
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        XCTAssertEqual(trashCount(), before - 1)
    }

    func testRestoreAllAsksFirstAndEmptiesTheQueue() throws {
        try queueSafeDuplicates()
        trashBar.tap()
        let restore = app.navigationBars.buttons["Keep all"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Keep all'")).element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "A confirmation is shown")
        snapshot("restore-all-confirmation")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Trash is empty"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertFalse(trashBar.waitForExistence(timeout: 2))
    }

    func testCancellingTheSystemDeleteDialogKeepsEverything() throws {
        try queueSafeDuplicates()
        let before = trashCount()
        trashBar.tap()
        let delete = button(beginningWith: "Delete ")
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(tapSystemButton(["Don’t Allow", "Don't Allow", "Cancel"], timeout: 8), "iOS asks before deleting")
        XCTAssertTrue(app.staticTexts["Deletion was cancelled. Nothing was removed."].waitForExistence(timeout: 5))
        snapshot("delete-cancelled")
        app.buttons["Close"].tap()
        XCTAssertEqual(trashCount(), before)
    }

    // MARK: Sessions

    /// Home → guided cleanup: unselect one photo, finish the set, Undo brings it back, Back reaches Home.
    func testCleanupSetsMoveUndoAndReturn() throws {
        let start = button(beginningWith: "Start cleanup")
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let first = app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Set 1 of'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Home"].isHittable, "Focus: no tab bar")
        XCTAssertFalse(trashBar.exists, "Focus: the set's own buttons, no second bar")
        snapshot("set-first")

        let move = button(beginningWith: "Move ")
        XCTAssertTrue(move.waitForExistence(timeout: 3), "Suggestions arrive selected")
        let count = Int(move.label.components(separatedBy: " ")[1]) ?? 0
        app.buttons.matching(identifier: "setSelectionBadge")
            .matching(NSPredicate(format: "label == 'Keep this photo'")).firstMatch.tap()
        XCTAssertFalse(app.buttons["More actions"].exists, "The badge changes selection without opening a preview")
        snapshot("set-after-unselecting")
        let finish = count > 1 ? button(beginningWith: "Move \(count - 1) to Trash") : app.buttons["Keep all · Next"]
        XCTAssertTrue(finish.waitForExistence(timeout: 3), "Unselecting updates the button")
        finish.tap()

        let second = app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Set 2 of'")).firstMatch
        if second.waitForExistence(timeout: 5) {
            snapshot("set-second")
            app.buttons["Undo"].tap()
            XCTAssertTrue(first.waitForExistence(timeout: 5), "Undo returns to the previous set")
        } else {
            XCTAssertTrue(app.staticTexts["All sets done"].waitForExistence(timeout: 5))
        }
        goBack()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
    }

    func testSwipeDeckTrashAndKeep() throws {
        app.tabBars.buttons["Review"].tap()
        let swipe = button(beginningWith: "Swipe through uncertain items")
        XCTAssertTrue(swipe.waitForExistence(timeout: 5))
        guard swipe.isEnabled else { throw XCTSkip("No uncertain items in the seeded library") }
        swipe.tap()
        let progress = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 of'")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        snapshot("swipe-deck")
        let card = app.images.firstMatch
        card.swipeLeft()
        if app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 of'")).firstMatch.waitForExistence(timeout: 3) {
            app.images.firstMatch.swipeRight()
        }
        if app.buttons["Done"].exists { app.buttons["Done"].tap() } else { goBack() }
        XCTAssertTrue(trashBar.waitForExistence(timeout: 5), "The swiped-left photo is in the Trash Queue")
    }

    // MARK: Search

    func testSearchSelectAndTrash() throws {
        app.buttons["Search and filters"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("blurry photos\n")  // submit: results stay, the keyboard goes away
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Understood'")).firstMatch.waitForExistence(timeout: 3))
        let count = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' items'")).firstMatch
        guard count.waitForExistence(timeout: 3) else { throw XCTSkip("No blurry photos found") }
        snapshot("search-results")
        _ = app.keyboards.element.waitForNonExistence(timeout: 3)  // let the layout settle
        app.buttons["Select"].tap()
        snapshot("search-select")
        app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let move = button(beginningWith: "Move 1 to Trash")
        XCTAssertTrue(move.waitForExistence(timeout: 3))
        move.tap()
        XCTAssertTrue(trashBar.waitForExistence(timeout: 5))
    }

    // MARK: Settings

    func testRetentionRuleChangeIsReflected() throws {
        app.tabBars.buttons["Settings"].tap()
        let rules = app.buttons["Temporary item rules"]
        XCTAssertTrue(scrollTo(rules))
        rules.tap()
        let parking = button(beginningWith: "Parking photos")
        XCTAssertTrue(parking.waitForExistence(timeout: 5))
        parking.tap()
        let choice = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'after 14 days'")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3))
        choice.tap()
        XCTAssertTrue(button(beginningWith: "Parking photos").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'after 14 days'")).firstMatch.exists)
        snapshot("retention-rules")
        // Restore the default so other runs see the same suggestions.
        button(beginningWith: "Parking photos").tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'after 7 days'")).firstMatch.tap()
    }

    // MARK: Undo, mute, protect

    func testUndoToastRestoresTheQueue() throws {
        try open(card: "Blurry")
        let trash = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Trash' AND label CONTAINS '·'")).firstMatch
        guard trash.waitForExistence(timeout: 5) else { throw XCTSkip("No pre-selected blurry photos") }
        trash.tap()
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.tap()
        XCTAssertTrue(trashBar.waitForNonExistence(timeout: 5), "Undo empties what was just queued")
    }

    func testMutingACategoryOffersShowAgainInPlace() throws {
        try open(card: "Blurry")
        let photo = element(containing: "Suggested: Blurry")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        app.buttons["More actions"].tap()
        let mute = app.buttons["Never suggest blurry & failed"]
        XCTAssertTrue(mute.waitForExistence(timeout: 3))
        mute.tap()
        XCTAssertTrue(app.staticTexts["Suggestions turned off"].waitForExistence(timeout: 5), "No “All done” dead end")
        snapshot("muted-category")
        app.buttons["Show again"].tap()
        XCTAssertTrue(element(containing: "Suggested: Blurry").waitForExistence(timeout: 5))
    }

    func testProtectedItemLandsInSkipListAndCanBeReleased() throws {
        try open(card: "Blurry")
        let photo = element(containing: "Suggested: Blurry")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        app.buttons["More actions"].tap()
        app.buttons["Protect"].tap()
        if app.buttons["Done"].waitForExistence(timeout: 2) { app.buttons["Done"].firstMatch.tap() }
        goBack()
        app.tabBars.buttons["Review"].tap()
        let skipList = button(beginningWith: "Protected & skip list")
        XCTAssertTrue(scrollTo(skipList))
        XCTAssertFalse(skipList.label.hasSuffix(", 0"), "The count includes the protected photo")
        skipList.tap()
        let protected = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        XCTAssertTrue(protected.waitForExistence(timeout: 5))
        snapshot("skip-list")
        protected.tap()
        XCTAssertTrue(app.buttons["More actions"].waitForExistence(timeout: 5))
        app.buttons["More actions"].tap()
        let allow = app.buttons["Allow suggestions again"]
        XCTAssertTrue(allow.waitForExistence(timeout: 3))
        allow.tap()
        if app.buttons["Done"].waitForExistence(timeout: 2) { app.buttons["Done"].tap() }
        XCTAssertTrue(app.staticTexts["Nothing here"].waitForExistence(timeout: 5))
    }

    // MARK: Group decisions

    func testMakeBestPromotesTheChosenShot() throws {
        try open(card: "Similar shots")
        let alternative = app.buttons.matching(NSPredicate(format: "value == 'Selected for Trash'")).firstMatch
        XCTAssertTrue(alternative.waitForExistence(timeout: 10))
        alternative.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Will move to Trash"].waitForExistence(timeout: 3))
        app.buttons["Make best"].tap()
        XCTAssertTrue(app.staticTexts["Recommended"].waitForExistence(timeout: 5), "The chosen shot is now the keeper")
        XCTAssertFalse(app.buttons["Make best"].exists)
        snapshot("make-best")
    }

    func testKeepAllMovesOn() throws {
        try open(card: "Similar shots")
        XCTAssertTrue(groupAccept.waitForExistence(timeout: 10))
        let title = app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 of'")).firstMatch.label
        app.buttons["Keep all"].firstMatch.tap()
        let next = app.navigationBars.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 of'")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5) || (title == "1 of 1" && app.staticTexts["Nice."].waitForExistence(timeout: 5)))
    }

    // MARK: Videos

    func testVideoCategoryOneTapTrash() throws {
        try open(card: "Accidental videos")
        let trash = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Trash' AND label CONTAINS 'suggested'")).firstMatch
        guard trash.waitForExistence(timeout: 5) else { throw XCTSkip("No pre-selectable accidental videos") }
        trash.tap()
        XCTAssertTrue(trashBar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All done"].waitForExistence(timeout: 5))
    }

    // MARK: Maintenance

    func testClearingTheCacheRescansAndSuggestionsReturn() throws {
        app.tabBars.buttons["Settings"].tap()
        let clear = app.buttons["Clear analysis cache"]
        XCTAssertTrue(scrollTo(clear))
        clear.tap()
        app.buttons["Clear and rescan"].tap()
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(element(containing: "Analyzing your library").waitForExistence(timeout: 10), "The cleared cache starts a first scan")
        XCTAssertTrue(button(beginningWith: "Similar shots").waitForExistence(timeout: 180), "A fresh scan rebuilds the suggestions")
        snapshot("after-rescan")
    }

    // MARK: Real deletion (runs last; needs an extra identical copy seeded — see docs/TESTING.md)

    func testZDeletingOneCopyRemovesItForGood() throws {
        try queueSafeDuplicates()
        trashBar.tap()
        let minus = app.buttons.matching(NSPredicate(format: "label == 'Keep, remove from Trash'"))
        XCTAssertTrue(minus.firstMatch.waitForExistence(timeout: 5))
        // The grid is lazy (only visible cells exist), so keep removing until exactly one item is left.
        var removed = 0
        while !button(beginningWith: "Delete 1 item").exists, minus.firstMatch.exists, removed < 80 {
            minus.firstMatch.tap()
            removed += 1
            usleep(400_000)
        }
        let delete = button(beginningWith: "Delete 1 item")
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(tapSystemButton(["Delete"], timeout: 8))
        let done = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1 item moved to Recently Deleted'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        snapshot("deleted")
        XCTAssertTrue(trashBar.waitForNonExistence(timeout: 5))
    }

    // MARK: Helpers

    private var groupRows: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'groupRow.'"))
    }

    private var groupListPhotos: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'groupListPhoto.'"))
    }

    private func openGroupList() throws {
        try open(card: "Similar shots")
        let allGroups = app.buttons["All groups"]
        XCTAssertTrue(allGroups.waitForExistence(timeout: 10), "The seeded library has multiple similar groups")
        allGroups.tap()
        XCTAssertTrue(app.buttons["Review groups"].waitForExistence(timeout: 5))
        XCTAssertTrue(groupRows.firstMatch.waitForExistence(timeout: 5))
    }

    private func selectedGroupPhotoCount(_ button: XCUIElement) -> Int {
        let detail = button.label.components(separatedBy: ", ").dropFirst().joined(separator: ", ")
        return Int(detail.components(separatedBy: " ").first ?? "") ?? 0
    }

    private func shareFileAndReturn(snapshotName: String, saveAction: String) throws {
        XCTAssertTrue(app.buttons["More actions"].waitForExistence(timeout: 5))
        app.buttons["More actions"].tap()
        app.buttons["Share this file"].tap()
        XCTAssertTrue(app.cells["Save to Files"].waitForExistence(timeout: 30), "The actual file can be saved, not just a thumbnail")
        XCTAssertTrue(app.cells[saveAction].exists, "The share sheet recognizes the correct media type")
        snapshot(snapshotName)
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.buttons["More actions"].waitForExistence(timeout: 5), "Cancelling sharing returns to the same viewer")
        XCTAssertTrue(app.buttons["Trash"].exists, "Sharing doesn't move the item to Trash")
        // Export a second time to exercise temporary-file cleanup after the first sheet closes.
        app.buttons["More actions"].tap()
        app.buttons["Share this file"].tap()
        XCTAssertTrue(app.cells["Save to Files"].waitForExistence(timeout: 30))
        close.tap()
    }

    private var peekPreview: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "photoPeekPreview").firstMatch
    }

    private func holdToPreview(_ photo: XCUIElement, snapshotName: String) throws {
        let identifier = photo.identifier
        let originalValue = photo.value as? String
        // Stay away from keep/trash badges in the top corner.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(forDuration: 3)
        XCTAssertTrue(peekPreview.waitForNonExistence(timeout: 2), "The preview is gone as soon as the touch is released")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists)
        XCTAssertEqual(photo.value as? String, originalValue, "Releasing a preview must not also trigger a tap")
        XCTAssertFalse(app.menus.firstMatch.exists, "A hold does not leave a context menu behind")
        XCTAssertFalse(app.buttons["More actions"].exists, "The quick preview stays over the gallery")
        snapshot(snapshotName + "-released")
    }

    private func element(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private var trashBar: XCUIElement { button(beginningWith: "Trash Queue") }

    /// The group CTA: "Keep Best · Trash 2", or "Keep 2 · Trash 1" when the user keeps more than one.
    private var groupAccept: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Keep' AND label CONTAINS '· Trash'")).firstMatch
    }

    private func trashCount() -> Int {
        guard trashBar.waitForExistence(timeout: 5) else { return 0 }
        // "Trash Queue, 3 items, 236 KB. Opens final review."
        let parts = trashBar.label.components(separatedBy: ", ")
        return parts.count > 1 ? Int(parts[1].components(separatedBy: " ")[0]) ?? 0 : 0
    }

    /// The guided cleanup starts with identical copies, pre-selected: one tap queues them.
    private func selectionBatchLimit(_ limit: Int) {
        app.launchArguments += ["-KeepOneSelectionCap", "\(limit)"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 20))
        _ = button(beginningWith: "Similar shots").waitForExistence(timeout: 120)
    }

    private func queueSafeDuplicates() throws {
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start cleanup' OR label BEGINSWITH 'Continue cleanup'")).firstMatch
        guard start.waitForExistence(timeout: 10) else { throw XCTSkip("No cleanup sets in the seeded library") }
        start.tap()
        let move = button(beginningWith: "Move ")
        guard move.waitForExistence(timeout: 5) else { throw XCTSkip("The first set has nothing pre-selected") }
        move.tap()
        goBack()
        XCTAssertTrue(trashBar.waitForExistence(timeout: 5))
    }

    private func open(card title: String) throws {
        let card = button(beginningWith: title)
        guard scrollTo(card) else { throw XCTSkip("No \(title) suggestions in the seeded library") }
        card.tap()
    }

    @discardableResult
    private func scrollTo(_ element: XCUIElement, maxSwipes: Int = 6) -> Bool {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
        return element.exists && element.isHittable
    }

    private func goBack() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func button(beginningWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    @discardableResult
    private func tapSystemButton(_ labels: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for label in labels {
                for button in [springboard.buttons[label], app.alerts.buttons[label], app.buttons[label]] where button.exists && button.isHittable {
                    button.tap()
                    return true
                }
            }
            usleep(250_000)
        }
        return false
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
