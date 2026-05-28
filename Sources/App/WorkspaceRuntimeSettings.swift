import Darwin
import Foundation

enum WorkspaceTitlebarSettings {
    static let showTitlebarKey = "workspaceTitlebarVisible"
    static let defaultShowTitlebar = true

    static func isVisible(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showTitlebarKey) == nil {
            return defaultShowTitlebar
        }
        return defaults.bool(forKey: showTitlebarKey)
    }
}
enum WorkspacePresentationModeSettings {
    static let modeKey = "workspacePresentationMode"

    enum Mode: String {
        case standard
        case minimal
    }

    static let defaultMode: Mode = .standard

    static func mode(for rawValue: String?) -> Mode {
        Mode(rawValue: rawValue ?? "") ?? defaultMode
    }

    static func mode(defaults: UserDefaults = .standard) -> Mode {
        mode(for: defaults.string(forKey: modeKey))
    }

    static func isMinimal(defaults: UserDefaults = .standard) -> Bool {
        mode(defaults: defaults) == .minimal
    }
}

enum WorkspaceButtonFadeSettings {
    static let modeKey = "workspaceButtonsFadeMode"
    static let legacyTitlebarControlsVisibilityModeKey = "titlebarControlsVisibilityMode"
    static let legacyPaneTabBarControlsVisibilityModeKey = "paneTabBarControlsVisibilityMode"

    enum Mode: String {
        case enabled
        case disabled
    }

    static let defaultMode: Mode = .disabled

    static func mode(for rawValue: String?) -> Mode {
        Mode(rawValue: rawValue ?? "") ?? defaultMode
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        mode(for: defaults.string(forKey: modeKey)) == .enabled
    }

    static func initializeStoredModeIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: modeKey) == nil else { return }

        if let migratedMode = migratedLegacyMode(defaults: defaults) {
            defaults.set(migratedMode.rawValue, forKey: modeKey)
            return
        }

        let initialMode: Mode = WorkspaceTitlebarSettings.isVisible(defaults: defaults) ? .disabled : .enabled
        defaults.set(initialMode.rawValue, forKey: modeKey)
    }

    private static func migratedLegacyMode(defaults: UserDefaults) -> Mode? {
        let legacyValues = [
            defaults.string(forKey: legacyTitlebarControlsVisibilityModeKey),
            defaults.string(forKey: legacyPaneTabBarControlsVisibilityModeKey),
        ]

        if legacyValues.contains(where: { $0 == "onHover" || $0 == "hover" || $0 == "enabled" }) {
            return .enabled
        }
        if legacyValues.contains(where: { $0 == "always" || $0 == "disabled" }) {
            return .disabled
        }
        return nil
    }
}

enum PaneFirstClickFocusSettings {
    static let enabledKey = "paneFirstClickFocus.enabled"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}

enum TerminalScrollBarSettings {
    static let showScrollBarKey = "terminal.showScrollBar"
    static let defaultShowScrollBar = true
    static let didChangeNotification = Notification.Name("cmux.terminalScrollBarSettingsDidChange")

    static func isVisible(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showScrollBarKey) == nil {
            return defaultShowScrollBar
        }
        return defaults.bool(forKey: showScrollBarKey)
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

enum CMUXGHPRIntegrationSettings {
    static let enabledKey = "digest.ghpr.enabled"
    static let socketPathKey = "digest.ghpr.socketPath"
    static let displayItemsKey = "digest.ghpr.displayItems"
    static let jiraBaseURLKey = "digest.ghpr.jiraBaseURL"

    static let defaultEnabled = false
    static let defaultDisplayItems = ["ci", "review", "unresolved", "jira"]
    static let defaultJiraBaseURL = ""

    static var defaultSocketPath: String {
        "/tmp/com.xiaocang.PRDashboard.\(getuid()).sock"
    }

    static var defaultDisplayItemsText: String {
        defaultDisplayItems.joined(separator: ", ")
    }
}

enum TerminalTextBoxInputSettings {
    static let maxLinesKey = "terminal.textBoxMaxLines"
    static let defaultMaxLines = 10
    static let minimumMaxLines = 1
    static let maximumMaxLines = 20

    static func resolvedMaxLines(_ value: Int) -> Int {
        min(max(value, minimumMaxLines), maximumMaxLines)
    }

    static func maxLines(defaults: UserDefaults = .standard) -> Int {
        guard let value = defaults.object(forKey: maxLinesKey) as? Int else {
            return defaultMaxLines
        }
        return resolvedMaxLines(value)
    }
}

enum TerminalCopyOnSelectSettings {
    static let copyOnSelectKey = "terminal.copyOnSelect"
    static let defaultCopyOnSelect = false
    static let didChangeNotification = Notification.Name("cmux.terminalCopyOnSelectSettingsDidChange")

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        storedValue(defaults: defaults) ?? defaultCopyOnSelect
    }

    static func storedValue(defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: copyOnSelectKey) as? Bool
    }

    static func ghosttyCopyOnSelectValue(defaults: UserDefaults = .standard) -> String? {
        guard let enabled = storedValue(defaults: defaults) else { return nil }
        return enabled ? "clipboard" : "false"
    }

    static func ghosttyConfigContents(defaults: UserDefaults = .standard) -> String? {
        guard let value = ghosttyCopyOnSelectValue(defaults: defaults) else { return nil }
        return "copy-on-select = \(value)"
    }

    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.set(enabled, forKey: copyOnSelectKey)
        if wasEnabled != enabled {
            notifyDidChange(notificationCenter: notificationCenter)
        }
    }

    @discardableResult
    static func reset(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.removeObject(forKey: copyOnSelectKey)
        let didChange = wasEnabled != isEnabled(defaults: defaults)
        if didChange {
            notifyDidChange(notificationCenter: notificationCenter)
        }
        return didChange
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

enum TerminalManagedGhosttySettings {
    static func ghosttyConfigContents(defaults: UserDefaults = .standard) -> String? {
        let lines = [
            TerminalCopyOnSelectSettings.ghosttyConfigContents(defaults: defaults),
        ].compactMap { $0 }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}

enum AgentSessionAutoResumeSettings {
    static let autoResumeAgentSessionsKey = "terminal.autoResumeAgentSessions"
    static let defaultAutoResumeAgentSessions = true
    static let didChangeNotification = Notification.Name("cmux.agentSessionAutoResumeSettingsDidChange")

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: autoResumeAgentSessionsKey) != nil else {
            return defaultAutoResumeAgentSessions
        }
        return defaults.bool(forKey: autoResumeAgentSessionsKey)
    }

    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.set(enabled, forKey: autoResumeAgentSessionsKey)
        if wasEnabled != enabled {
            notifyDidChange(notificationCenter: notificationCenter)
        }
    }

    @discardableResult
    static func reset(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.removeObject(forKey: autoResumeAgentSessionsKey)
        let didChange = wasEnabled != isEnabled(defaults: defaults)
        if didChange {
            notifyDidChange(notificationCenter: notificationCenter)
        }
        return didChange
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

enum RightSidebarBetaFeatureSettings {
    static let dockEnabledKey = "rightSidebar.beta.dock.enabled"

    static let defaultDockEnabled = false

    nonisolated static func isDockEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: dockEnabledKey) != nil else { return defaultDockEnabled }
        return defaults.bool(forKey: dockEnabledKey)
    }
}

enum UITestLaunchManifest {
    static let argumentName = "-cmuxUITestLaunchManifest"

    struct Payload: Decodable {
        let environment: [String: String]
    }

    static func applyIfPresent(
        arguments: [String] = CommandLine.arguments,
        loadData: (String) -> Data? = { path in
            try? Data(contentsOf: URL(fileURLWithPath: path))
        },
        applyEnvironment: (String, String) -> Void = { key, value in
            setenv(key, value, 1)
        }
    ) {
        guard let path = manifestPath(from: arguments),
              let data = loadData(path),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return
        }

        for (key, value) in payload.environment {
            applyEnvironment(key, value)
        }
    }

    static func manifestPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argumentName) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }

        let rawPath = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return rawPath.isEmpty ? nil : rawPath
    }
}

struct CmuxRuntimeMode: Equatable, Sendable {
    static let uiTestArgument = "--cmux-ui-test"
    static let fixtureArgument = "--fixture"
    static let disableNetworkArgument = "--disable-network"
    static let disableSparkleArgument = "--disable-sparkle"
    static let disableRealLLMArgument = "--disable-real-llm"
    static let disableAutoUpdateArgument = "--disable-auto-update"
    static let disableAnimationsArgument = "--disable-animations"
    static let resetTestStateArgument = "--reset-test-state"
    static let fixedNowArgument = "--fixed-now"
    static let appearanceArgument = "--appearance"

    let isUITest: Bool
    let fixtureName: String?
    let disableNetwork: Bool
    let disableSparkle: Bool
    let disableRealLLM: Bool
    let disableAutoUpdate: Bool
    let disableAnimations: Bool
    let resetTestState: Bool
    let fakeContextAgent: Bool
    let fakeAssistant: Bool
    let fixedNow: Date?
    let appearanceMode: String?

    static func current(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CmuxRuntimeMode {
        let overrides = environmentOverrides(from: arguments)
        let fixedNowRaw = overrides["CMUX_FIXED_NOW"] ?? environment["CMUX_FIXED_NOW"]
        let appearanceRaw = normalizedAppearanceMode(value(after: appearanceArgument, in: arguments))
            ?? normalizedAppearanceMode(environment["CMUX_UI_TEST_APPEARANCE"])
            ?? overrides["CMUX_UI_TEST_APPEARANCE"]
        return CmuxRuntimeMode(
            isUITest: enabled("CMUX_UI_TEST_MODE", overrides: overrides, environment: environment)
                || enabled("CMUX_TEST_MODE", overrides: overrides, environment: environment),
            fixtureName: overrides["CMUX_UI_TEST_FIXTURE"] ?? environment["CMUX_UI_TEST_FIXTURE"],
            disableNetwork: enabled("CMUX_DISABLE_NETWORK", overrides: overrides, environment: environment),
            disableSparkle: enabled("CMUX_DISABLE_SPARKLE", overrides: overrides, environment: environment),
            disableRealLLM: enabled("CMUX_DISABLE_REAL_LLM", overrides: overrides, environment: environment),
            disableAutoUpdate: enabled("CMUX_DISABLE_AUTO_UPDATE", overrides: overrides, environment: environment)
                || enabled("CMUX_DISABLE_SPARKLE", overrides: overrides, environment: environment),
            disableAnimations: enabled("CMUX_DISABLE_ANIMATIONS", overrides: overrides, environment: environment),
            resetTestState: enabled("CMUX_RESET_TEST_STATE", overrides: overrides, environment: environment),
            fakeContextAgent: enabled("CMUX_FAKE_CONTEXT_AGENT", overrides: overrides, environment: environment),
            fakeAssistant: enabled("CMUX_FAKE_ASSISTANT", overrides: overrides, environment: environment),
            fixedNow: fixedNowRaw.flatMap { fixedNowDate(from: $0) },
            appearanceMode: normalizedAppearanceMode(appearanceRaw)
        )
    }

    static func applyLaunchArgumentsIfPresent(
        arguments: [String] = CommandLine.arguments,
        applyEnvironment: (String, String) -> Void = { key, value in
            setenv(key, value, 1)
        }
    ) {
        for (key, value) in environmentOverrides(from: arguments) {
            applyEnvironment(key, value)
        }
    }

    static func environmentOverrides(from arguments: [String]) -> [String: String] {
        var overrides: [String: String] = [:]
        if arguments.contains(uiTestArgument) {
            overrides["CMUX_UI_TEST_MODE"] = "1"
            overrides["CMUX_TEST_MODE"] = "1"
            overrides["CMUX_DISABLE_ANIMATIONS"] = "1"
            overrides["CMUX_FAKE_CONTEXT_AGENT"] = "1"
            overrides["CMUX_FAKE_ASSISTANT"] = "1"
            overrides["CMUX_UI_TEST_APPEARANCE"] = "light"
        }
        if arguments.contains(disableNetworkArgument) {
            overrides["CMUX_DISABLE_NETWORK"] = "1"
        }
        if arguments.contains(disableSparkleArgument) {
            overrides["CMUX_DISABLE_SPARKLE"] = "1"
            overrides["CMUX_DISABLE_AUTO_UPDATE"] = "1"
        }
        if arguments.contains(disableRealLLMArgument) {
            overrides["CMUX_DISABLE_REAL_LLM"] = "1"
        }
        if arguments.contains(disableAutoUpdateArgument) {
            overrides["CMUX_DISABLE_AUTO_UPDATE"] = "1"
        }
        if arguments.contains(disableAnimationsArgument) {
            overrides["CMUX_DISABLE_ANIMATIONS"] = "1"
        }
        if arguments.contains(resetTestStateArgument) {
            overrides["CMUX_RESET_TEST_STATE"] = "1"
        }
        if let fixture = value(after: fixtureArgument, in: arguments) {
            overrides["CMUX_UI_TEST_FIXTURE"] = fixture
        }
        if let fixedNow = value(after: fixedNowArgument, in: arguments) {
            overrides["CMUX_FIXED_NOW"] = fixedNow
        }
        if let appearance = normalizedAppearanceMode(value(after: appearanceArgument, in: arguments)) {
            overrides["CMUX_UI_TEST_APPEARANCE"] = appearance
        }
        return overrides
    }

    private static func enabled(
        _ key: String,
        overrides: [String: String],
        environment: [String: String]
    ) -> Bool {
        overrides[key] == "1" || environment[key] == "1"
    }

    private static func fixedNowDate(from rawValue: String) -> Date? {
        ISO8601DateFormatter().date(from: rawValue)
    }

    private static func normalizedAppearanceMode(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              ["light", "dark"].contains(rawValue) else {
            return nil
        }
        return rawValue
    }

    private static func value(after argument: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argument) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        let value = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("--") else { return nil }
        return value
    }
}

enum CmuxRuntimeAppearanceOverride {
    @discardableResult
    static func applyIfRequested(
        mode: CmuxRuntimeMode = .current(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard mode.isUITest,
              let rawMode = mode.appearanceMode,
              let appearanceMode = AppearanceMode(rawValue: rawMode) else {
            return false
        }

        defaults.set(appearanceMode.rawValue, forKey: AppearanceSettings.appearanceModeKey)
        return true
    }
}

enum CmuxRuntimeTestStateReset {
    @discardableResult
    static func applyIfRequested(
        mode: CmuxRuntimeMode = .current(),
        defaults: UserDefaults = .standard,
        domainName: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard mode.isUITest, mode.resetTestState else { return false }
        guard let domainName = domainName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !domainName.isEmpty else {
            return false
        }

        defaults.removePersistentDomain(forName: domainName)
        _ = defaults.synchronize()
        return true
    }
}

struct CmuxUITestWorkspaceFixture: Equatable {
    struct Entry: Equatable {
        struct PullRequest: Equatable {
            let number: Int
            let label: String
            let url: String
            let status: String
            let branch: String?
            let isStale: Bool
        }

        let title: String
        let description: String?
        let color: String?
        let status: String?
        let workingDirectory: String?
        let pullRequest: PullRequest?

        init(
            title: String,
            description: String?,
            color: String?,
            status: String?,
            workingDirectory: String?,
            pullRequest: PullRequest? = nil
        ) {
            self.title = title
            self.description = description
            self.color = color
            self.status = status
            self.workingDirectory = workingDirectory
            self.pullRequest = pullRequest
        }
    }

    let name: String
    let entries: [Entry]

    static func current(
        mode: CmuxRuntimeMode = CmuxRuntimeMode.current()
    ) -> CmuxUITestWorkspaceFixture? {
        guard mode.isUITest else { return nil }
        return fixture(named: mode.fixtureName)
    }

    static func fixture(named name: String?) -> CmuxUITestWorkspaceFixture? {
        switch normalizedName(name) {
        case "assistant-context-agent-basic":
            return CmuxUITestWorkspaceFixture(
                name: "assistant-context-agent-basic",
                entries: [
                    Entry(
                        title: "API fix",
                        description: "Agent is waiting for user review.",
                        color: "#D97706",
                        status: "waiting_user",
                        workingDirectory: nil
                    ),
                    Entry(
                        title: "CI failure",
                        description: "CI is failing and needs attention.",
                        color: "#DC2626",
                        status: "ci_failed",
                        workingDirectory: nil
                    ),
                    Entry(
                        title: "Refactor agent",
                        description: "Refactor work is in progress.",
                        color: "#2563EB",
                        status: "running",
                        workingDirectory: nil
                    ),
                    Entry(
                        title: "Ready to merge",
                        description: "PR is ready but cached pull request context is stale.",
                        color: "#16A34A",
                        status: "ready_to_merge",
                        workingDirectory: nil,
                        pullRequest: Entry.PullRequest(
                            number: 42,
                            label: "PR",
                            url: "https://github.com/manaflow-ai/cmux/pull/42",
                            status: "open",
                            branch: nil,
                            isStale: true
                        )
                    ),
                ]
            )
        default:
            return nil
        }
    }

    private static func normalizedName(_ name: String?) -> String {
        name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        ?? ""
    }
}
