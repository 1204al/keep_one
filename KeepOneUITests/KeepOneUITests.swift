import XCTest

/// UI smoke test against seeded Simulator media (see docs/TESTING.md): grants Photos access,
/// waits for analysis, walks the main screens and performs a real (Simulator) deletion through the
/// Trash Queue → final review → PhotoKit flow. Screenshots are attached to the result bundle.
@MainActor
final class KeepOneUITests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-KeepOneSkipOnboarding", "YES"]
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func tapSystemButton(_ labels: [String], timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for label in labels {
                for button in [springboard.buttons[label], app.buttons[label]] where button.exists && button.isHittable {
                    button.tap()
                    return true
                }
            }
            usleep(250_000)
        }
        return false
    }

    private func button(beginningWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func testMainFlow() throws {
        app.launch()
        tapSystemButton(["Allow Full Access", "Allow Access to All Photos"])
        let allow = app.buttons["Allow Access to Photos"]
        if allow.waitForExistence(timeout: 3) {
            snapshot("00-onboarding")
            allow.tap()
            tapSystemButton(["Allow Full Access", "Allow Access to All Photos"], timeout: 5)
        }

        // Wait for analysis to surface groups.
        let similarCard = button(beginningWith: "Similar shots")
        _ = similarCard.waitForExistence(timeout: 180)
        sleep(2)
        snapshot("02-home-top")
        app.swipeUp()
        snapshot("03-home-middle")
        app.swipeUp()
        snapshot("04-home-bottom")
        app.swipeDown(); app.swipeDown(); app.swipeDown()

        // Category card opens straight into the one-by-one group review.
        if similarCard.waitForExistence(timeout: 5) {
            similarCard.tap()
            sleep(3)
            snapshot("06-group-review")
            if app.buttons["Why this one?"].exists {
                app.buttons["Why this one?"].tap()
                sleep(2)
                snapshot("07-why-this-one")
                app.buttons["Done"].firstMatch.tap()
                sleep(1)
            }
            let keepBest = button(beginningWith: "Keep Best")
            if keepBest.exists {
                keepBest.tap()
                sleep(3)
                snapshot("08-after-keep-best")
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(1)
        }

        // A single-item category with its one-tap bottom bar.
        app.swipeUp()
        let blurry = button(beginningWith: "Blurry")
        if blurry.waitForExistence(timeout: 3) {
            blurry.tap()
            sleep(2)
            snapshot("09-category-grid")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            sleep(1)
        }
        let temporary = button(beginningWith: "Temporary photos")
        if temporary.waitForExistence(timeout: 3) {
            temporary.tap()
            sleep(2)
            snapshot("10-temporary-hub")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.swipeDown(); app.swipeDown()

        app.tabBars.buttons["Review"].tap()
        sleep(1)
        snapshot("11-review-hub")
        app.tabBars.buttons["Home"].tap()
        let start = button(beginningWith: "Start cleanup")
        if start.waitForExistence(timeout: 3) {
            start.tap()
            sleep(3)
            snapshot("12-cleanup-set")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.tabBars.buttons["Settings"].tap()
        sleep(1)
        snapshot("13-settings")
        app.tabBars.buttons["Home"].tap()
        sleep(1)

        // Final review → one tap → iOS confirmation → PhotoKit moves Simulator test media to Recently Deleted.
        let trashBar = button(beginningWith: "Trash Queue")
        if trashBar.waitForExistence(timeout: 5) {
            trashBar.tap()
            sleep(2)
            snapshot("14-trash-review")
            let delete = button(beginningWith: "Delete ")
            if delete.waitForExistence(timeout: 3) {
                delete.tap()
                sleep(1)
                snapshot("15-system-alert")
                tapSystemButton(["Delete", "Allow"], timeout: 8)
                sleep(2)
                snapshot("16-after-deletion")
            }
        }
    }
}
