// FILE: CodexMobileUITests.swift
// Purpose: Measures timeline scrolling and streaming append performance on deterministic fixtures.
// Layer: UI Test
// Exports: CodexMobileUITests
// Depends on: XCTest

import XCTest

final class CodexMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTurnTimelineScrollingPerformance() {
        let app = launchFixtureApp(messageCount: 1200)
        let timeline = app.scrollViews["turn.timeline.scrollview"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))

        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric]) {
            timeline.swipeUp(velocity: .fast)
            timeline.swipeUp(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
        }
    }

    func testTurnStreamingAppendPerformance() {
        let app = launchFixtureApp(messageCount: 500, autoStream: true)
        XCTAssertTrue(app.scrollViews["turn.timeline.scrollview"].waitForExistence(timeout: 5))

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            // Wait window where fixture appends streaming chunks into the active timeline.
            RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        }
    }

    func testOversizedHistoryWithLocalTranscriptKeepsTimelineUsable() {
        let app = launchFixtureApp(
            messageCount: 24,
            scenario: "oversizedHistoryWithLocalTranscript"
        )

        XCTAssertTrue(app.scrollViews["turn.timeline.scrollview"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.otherElements["turn.connection-recovery.card"].waitForExistence(timeout: 2),
            "Expected local oversized-history fallback to avoid reconnect recovery UI."
        )
    }

    func testOversizedHistoryWithoutLocalTranscriptShowsRecoveryCard() {
        let app = launchFixtureApp(
            messageCount: 0,
            scenario: "oversizedHistoryWithoutLocalTranscript"
        )

        XCTAssertTrue(
            app.otherElements["turn.connection-recovery.card"].waitForExistence(timeout: 5),
            "Expected reconnect recovery UI when oversized history cannot fall back to local transcript."
        )
    }

    func testThreadOpenFailureDoesNotStayOnLoadingChatForever() {
        let app = launchFixtureApp(
            messageCount: 0,
            scenario: "threadOpenFailure"
        )

        XCTAssertTrue(app.staticTexts["Loading chat..."].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Request timed out after 15s while waiting for thread/resume."].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["Hi! How can I help you?"].waitForExistence(timeout: 5),
            "Expected the app to fall back to the empty-thread state after thread open fails."
        )
    }

    func testThreadOpenFailureKeepsSidebarMenuResponsive() {
        let app = launchFixtureApp(
            messageCount: 0,
            scenario: "threadOpenFailure"
        )

        XCTAssertTrue(app.staticTexts["Loading chat..."].waitForExistence(timeout: 5))

        let menuButton = app.buttons["Menu"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5))
        menuButton.tap()

        let closeMenuButton = app.buttons["Close menu"]
        XCTAssertTrue(
            closeMenuButton.waitForExistence(timeout: 5),
            "Expected the sidebar to remain openable while the thread resume request is still pending."
        )
    }

    private func launchFixtureApp(
        messageCount: Int,
        autoStream: Bool = false,
        scenario: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CodexUITestsFixture",
            "-CodexUITestsMessageCount", String(messageCount),
        ]
        if autoStream {
            app.launchArguments += ["-CodexUITestsAutoStream"]
        }
        if let scenario {
            app.launchArguments += ["-CodexUITestsScenario", scenario]
        }
        app.launch()
        return app
    }
}
