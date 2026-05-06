import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression tests for `parseDigestSection` / `parseWorkspaceTabSection`.
///
/// Earlier versions used `return` inside the validation `guard`s, so a single
/// out-of-range field silently dropped every later field in the same section.
/// These tests place an invalid value before valid ones and assert that the
/// later valid keys still land in the resolved snapshot (via UserDefaults).
final class WorkspaceDigestSettingsParsingTests: XCTestCase {

    private var primaryPath: String = ""
    private var fallbackPath: String = ""
    private var temporaryDirectoryURL: URL?

    private static let touchedDefaultsKeys: [String] = [
        "digest.enabled",
        "digest.daemonEnabled",
        "digest.provider",
        "digest.model",
        "digest.claudeCodeModel",
        "digest.currentWorkspaceMinIntervalSec",
        "digest.backgroundMinIntervalSec",
        "digest.screenLines",
        "digest.includeDiffStat",
        "digest.sendFullDiffToLLM",
        "digest.writeSidebarMetadata",
        "workspaceTab.displayMode",
        "workspaceTab.summaryPriority.enabled",
        "workspaceTab.summaryPriority.sortMode",
        "workspaceTab.summaryPriority.sortDimensionId",
        "workspaceTab.summaryPriority.sortDirection",
    ]

    override func setUp() {
        super.setUp()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-digest-settings-parsing-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        temporaryDirectoryURL = dir
        primaryPath = dir.appendingPathComponent("settings.json").path
        fallbackPath = dir.appendingPathComponent("fallback.json").path
        clearTouchedDefaults()
    }

    override func tearDown() {
        clearTouchedDefaults()
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        temporaryDirectoryURL = nil
        super.tearDown()
    }

    func testInvalidDigestIntervalDoesNotDropLaterFields() throws {
        // currentWorkspaceMinIntervalSec must be >= 10. The earlier `return`
        // bug caused includeDiffStat/sendFullDiffToLLM/writeSidebarMetadata
        // to be silently dropped when this field was invalid.
        let json = """
        {
          "digest": {
            "currentWorkspaceMinIntervalSec": 5,
            "backgroundMinIntervalSec": 600,
            "screenLines": 200,
            "includeDiffStat": false,
            "sendFullDiffToLLM": true,
            "writeSidebarMetadata": false
          }
        }
        """
        try writeSettings(json)

        _ = CmuxSettingsFileStore(
            primaryPath: primaryPath,
            fallbackPath: nil,
            startWatching: false
        )

        // The invalid field must not be applied.
        XCTAssertNil(
            UserDefaults.standard.object(forKey: "digest.currentWorkspaceMinIntervalSec"),
            "Out-of-range currentWorkspaceMinIntervalSec must not be applied"
        )

        // Every later field must still land — this is the regression assertion.
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "digest.backgroundMinIntervalSec"), 600)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "digest.screenLines"), 200)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "digest.includeDiffStat"), false)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "digest.sendFullDiffToLLM"), true)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "digest.writeSidebarMetadata"), false)
    }

    func testInvalidScreenLinesDoesNotDropLaterBooleans() throws {
        // screenLines must fall in 20...1000.
        let json = """
        {
          "digest": {
            "screenLines": 5,
            "includeDiffStat": true,
            "sendFullDiffToLLM": false,
            "writeSidebarMetadata": true
          }
        }
        """
        try writeSettings(json)

        _ = CmuxSettingsFileStore(
            primaryPath: primaryPath,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertNil(UserDefaults.standard.object(forKey: "digest.screenLines"))
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "digest.includeDiffStat"), true)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "digest.sendFullDiffToLLM"), false)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "digest.writeSidebarMetadata"), true)
    }

    func testInvalidWorkspaceTabDisplayModeStillAppliesSummaryPrioritySort() throws {
        // Earlier `return` inside parseWorkspaceTabSection caused an unknown
        // defaultDisplayMode to drop the entire summaryPriority.defaultSort block.
        let json = """
        {
          "workspaceTab": {
            "defaultDisplayMode": "totally_invalid",
            "summaryPriority": {
              "defaultSort": {
                "mode": "dimension",
                "dimensionId": "urgency",
                "direction": "desc"
              }
            }
          }
        }
        """
        try writeSettings(json)

        _ = CmuxSettingsFileStore(
            primaryPath: primaryPath,
            fallbackPath: nil,
            startWatching: false
        )

        // Invalid display mode must not be applied.
        XCTAssertNil(UserDefaults.standard.object(forKey: "workspaceTab.displayMode"))

        // Sort fields must still apply — regression assertion.
        XCTAssertEqual(UserDefaults.standard.string(forKey: "workspaceTab.summaryPriority.sortMode"), "dimension")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "workspaceTab.summaryPriority.sortDimensionId"), "urgency")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "workspaceTab.summaryPriority.sortDirection"), "desc")
    }

    func testInvalidSortModeStillAppliesDirection() throws {
        // Mode is constrained; direction must still land for an invalid mode.
        let json = """
        {
          "workspaceTab": {
            "defaultDisplayMode": "summary_priority",
            "summaryPriority": {
              "defaultSort": {
                "mode": "not_a_mode",
                "dimensionId": "importance",
                "direction": "asc"
              }
            }
          }
        }
        """
        try writeSettings(json)

        _ = CmuxSettingsFileStore(
            primaryPath: primaryPath,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(UserDefaults.standard.string(forKey: "workspaceTab.displayMode"), "summary_priority")
        XCTAssertNil(UserDefaults.standard.object(forKey: "workspaceTab.summaryPriority.sortMode"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: "workspaceTab.summaryPriority.sortDimensionId"), "importance")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "workspaceTab.summaryPriority.sortDirection"), "asc")
    }

    func testValidDigestSectionAppliesEveryField() throws {
        let json = """
        {
          "digest": {
            "enabled": true,
            "daemonEnabled": true,
            "provider": "openai",
            "model": "gpt-test",
            "claudeCodeModel": "haiku-test",
            "currentWorkspaceMinIntervalSec": 60,
            "backgroundMinIntervalSec": 360,
            "screenLines": 120,
            "includeDiffStat": false,
            "sendFullDiffToLLM": true,
            "writeSidebarMetadata": false
          }
        }
        """
        try writeSettings(json)

        _ = CmuxSettingsFileStore(
            primaryPath: primaryPath,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(UserDefaults.standard.bool(forKey: "digest.enabled"), true)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "digest.daemonEnabled"), true)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "digest.provider"), "openai")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "digest.model"), "gpt-test")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "digest.claudeCodeModel"), "haiku-test")
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "digest.currentWorkspaceMinIntervalSec"), 60)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "digest.backgroundMinIntervalSec"), 360)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "digest.screenLines"), 120)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "digest.includeDiffStat"), false)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "digest.sendFullDiffToLLM"), true)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "digest.writeSidebarMetadata"), false)
    }

    func testSummaryPriorityEnabledAppliesWithoutDefaultSort() throws {
        let json = """
        {
          "workspaceTab": {
            "summaryPriority": {
              "enabled": false
            }
          }
        }
        """
        try writeSettings(json)

        _ = CmuxSettingsFileStore(
            primaryPath: primaryPath,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(UserDefaults.standard.object(forKey: "workspaceTab.summaryPriority.enabled") as? Bool, false)
        XCTAssertNil(UserDefaults.standard.object(forKey: "workspaceTab.summaryPriority.sortMode"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "workspaceTab.summaryPriority.sortDimensionId"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "workspaceTab.summaryPriority.sortDirection"))
    }

    private func writeSettings(_ json: String) throws {
        try json.data(using: .utf8)?.write(to: URL(fileURLWithPath: primaryPath))
    }

    private func clearTouchedDefaults() {
        let defaults = UserDefaults.standard
        for key in Self.touchedDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
