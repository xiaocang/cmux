import XCTest

final class SpriteAssistantUITests: XCTestCase {
    private let launchTag = "ui-tests-sprite-assistant"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAssistantFixtureWorkspaceTitlesLoad() {
        let app = launchDeterministicApp()

        XCTAssertTrue(waitForVisibleText("API fix", in: app, timeout: 8))
        XCTAssertTrue(waitForVisibleText("CI failure", in: app, timeout: 3))
        XCTAssertTrue(waitForVisibleText("Refactor agent", in: app, timeout: 3))
        XCTAssertTrue(waitForVisibleText("Ready to merge", in: app, timeout: 3))
    }

    func testSpriteAssistantPanelHasStableAutomationAnchors() {
        let app = launchDeterministicApp()

        openSpriteAssistant(in: app)
        XCTAssertTrue(waitForElement("SortAssistantThread", in: app, timeout: 4))
        XCTAssertTrue(waitForElement("SortAssistantInput", in: app, timeout: 4))
        XCTAssertTrue(waitForElement("SortAssistantSuggestionList", in: app, timeout: 4))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "SortAssistantSuggestionCard.review_agent_waiting_user."))
                .firstMatch
                .waitForExistence(timeout: 4),
            "Expected fixture status to surface as a proactive suggestion card"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "SortAssistantSuggestionCard.fix_ci_failure."))
                .firstMatch
                .waitForExistence(timeout: 4),
            "Expected CI-failed fixture status to surface as a proactive suggestion card"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "SortAssistantSuggestionCard.merge_ready."))
                .firstMatch
                .waitForExistence(timeout: 4),
            "Expected ready-to-merge fixture status to surface as a proactive suggestion card"
        )
        XCTAssertTrue(app.buttons["SortAssistantSendButton"].exists)
        XCTAssertTrue(waitForElement("SortAssistantInputField", in: app, timeout: 4))

        ScreenshotAssert.matchWindow(app, name: "sprite-assistant-panel", testCase: self)
    }

    func testSuggestionActionWithStaleFixtureContextShowsConfirmation() {
        let app = launchDeterministicApp()

        openSpriteAssistant(in: app)
        let openSuggestion = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "SortAssistantSuggestionOpen."))
            .firstMatch
        XCTAssertTrue(openSuggestion.waitForExistence(timeout: 4), "Expected a suggestion action button")
        openSuggestion.click()

        XCTAssertTrue(
            waitForElement("SortAssistantSemanticActionConfirmation", in: app, timeout: 4),
            "Expected stale fixture context to require semantic action confirmation"
        )
        XCTAssertTrue(waitForElement("SortAssistantSemanticActionConfirm", in: app, timeout: 4))
        XCTAssertTrue(waitForElement("SortAssistantSemanticActionCancel", in: app, timeout: 4))

        ScreenshotAssert.matchWindow(app, name: "sprite-assistant-semantic-confirmation", testCase: self)
    }

    func testFakeAssistantAnswersFromFixtureContext() {
        let app = launchDeterministicApp()

        openSpriteAssistant(in: app)
        focusAssistantInput(in: app)
        app.typeText("summarize context")
        app.buttons["SortAssistantSendButton"].click()

        XCTAssertTrue(
            app.descendants(matching: .any)["SortAssistantContextFreshnessWarning"]
                .waitForExistence(timeout: 8),
            "Expected fixture mode to expose a stable freshness warning anchor"
        )

        let response = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Fixture assistant"))
            .firstMatch
        XCTAssertTrue(
            response.waitForExistence(timeout: 8),
            "Expected fake assistant response to come from the deterministic fixture runtime"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "API fix"))
                .firstMatch
                .waitForExistence(timeout: 2),
            "Expected fake assistant response to include the active fixture workspace"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "CI failure"))
                .firstMatch
                .waitForExistence(timeout: 2),
            "Expected fake assistant response to include the CI-failed fixture workspace"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "fix CI failure"))
                .firstMatch
                .waitForExistence(timeout: 2),
            "Expected fake assistant response to explain the CI failure suggestion"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Ready to merge"))
                .firstMatch
                .waitForExistence(timeout: 2),
            "Expected fake assistant response to include the ready-to-merge fixture workspace"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "ready to merge"))
                .firstMatch
                .waitForExistence(timeout: 2),
            "Expected fake assistant response to explain the merge-ready suggestion"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "summary_priority"))
                .firstMatch
                .waitForExistence(timeout: 2),
            "Expected fake assistant response to include stale provider freshness"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "github_context"))
                .firstMatch
                .waitForExistence(timeout: 2),
            "Expected fake assistant response to include stale PR provider freshness"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Sprite MCP request failed"))
                .firstMatch
                .exists
        )

        ScreenshotAssert.matchWindow(app, name: "sprite-assistant-fake-response", testCase: self)
    }

    func testContextAgentInspectorHasStableVisualAnchor() {
        let app = launchDeterministicApp()

        openContextAgentInspector(in: app)

        XCTAssertTrue(
            app.otherElements["ContextAgentInspector"].waitForExistence(timeout: 6)
                || app.windows["Context Agent Inspector"].waitForExistence(timeout: 6),
            "Expected Context Agent Inspector debug window to appear"
        )
        XCTAssertTrue(app.staticTexts["Context Agent Inspector"].exists)
        XCTAssertTrue(app.staticTexts["Provider Freshness"].exists)
        XCTAssertTrue(app.staticTexts["Snapshot Versions"].exists)
        XCTAssertTrue(app.staticTexts["Runtime Diagnostics"].exists)
        XCTAssertTrue(app.staticTexts["Pending"].exists)

        ScreenshotAssert.matchWindow(app, name: "context-agent-inspector", testCase: self)
    }

    private func launchDeterministicApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
            "--cmux-ui-test",
            "--fixture", "assistant-context-agent-basic",
            "--disable-network",
            "--disable-sparkle",
            "--disable-real-llm",
            "--disable-auto-update",
            "--reset-test-state",
            "--fixed-now", "2026-05-23T10:00:00Z",
            "--appearance", "light",
        ]
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_WINDOW_SIZE"] = "1280x900"
        app.launch()
        registerFailureArtifactsAndTermination(for: app)

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12),
            "Expected app to reach foreground before opening Sprite Assistant. state=\(app.state.rawValue)"
        )
        return app
    }

    private func registerFailureArtifactsAndTermination(for app: XCUIApplication) {
        addTeardownBlock { [weak self] in
            guard let self else {
                app.terminate()
                return
            }
            if (self.testRun?.totalFailureCount ?? 0) > 0 {
                let directory = ScreenshotAssert.writeFailureArtifacts(
                    app,
                    name: "sprite-assistant-\(self.name)",
                    testCase: self
                )
                if let directory {
                    print("SpriteAssistantUITests failure artifacts: \(directory.path)")
                }
            }
            if app.state != .notRunning {
                app.terminate()
            }
        }
    }

    private func openSpriteAssistant(in app: XCUIApplication) {
        let panel = app.otherElements["SortAssistantFloatingPanel"]
        if panel.waitForExistence(timeout: 1) {
            return
        }

        let tabBarButton = app.descendants(matching: .any)["paneTabBarControl.custom.cmux.sortAssistant"]
        if tabBarButton.waitForExistence(timeout: 4) {
            tabBarButton.click()
        } else {
            app.typeKey("s", modifierFlags: [.command, .shift])
        }

        XCTAssertTrue(waitForAssistantContent(in: app, timeout: 6), "Expected Sprite Assistant floating panel to appear")
    }

    private func waitForAssistantContent(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let anchors = [
            "SortAssistantFloatingPanel",
            "SortAssistantThread",
            "SortAssistantInput",
            "SortAssistantInputField",
            "SortAssistantSendButton",
        ]
        while Date() < deadline {
            if anchors.contains(where: { app.descendants(matching: .any)[$0].exists }) {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitForElement(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        app.descendants(matching: .any)[identifier].waitForExistence(timeout: timeout)
    }

    private func focusAssistantInput(in app: XCUIApplication) {
        let textField = app.textFields["SortAssistantInputField"]
        if textField.waitForExistence(timeout: 3) {
            textField.click()
            return
        }

        let input = app.otherElements["SortAssistantInputField"]
        if input.waitForExistence(timeout: 3) {
            input.click()
            return
        }

        let anyInput = app.descendants(matching: .any)["SortAssistantInputField"]
        XCTAssertTrue(anyInput.waitForExistence(timeout: 3), "Expected Sprite Assistant input field")
        anyInput.click()
    }

    private func openContextAgentInspector(in app: XCUIApplication) {
        let debugMenu = app.menuBars.menuBarItems["Debug"]
        XCTAssertTrue(debugMenu.waitForExistence(timeout: 6), "Expected Debug menu")
        debugMenu.click()

        let debugWindowsItem = app.menuItems["Debug Windows"]
        XCTAssertTrue(debugWindowsItem.waitForExistence(timeout: 3), "Expected Debug Windows submenu")
        debugWindowsItem.hover()

        let inspectorItem = app.menuItems["Context Agent Inspector…"]
        XCTAssertTrue(inspectorItem.waitForExistence(timeout: 3), "Expected Context Agent Inspector menu item")
        inspectorItem.click()
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6)
        }
        return false
    }

    private func waitForVisibleText(_ text: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
            .waitForExistence(timeout: timeout)
    }
}
