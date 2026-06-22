import Foundation

/// Settings under the dotted-id prefix `automation.*`.
public struct AutomationCatalogSection: SettingCatalogSection {
    public let socketControlMode = DefaultsKey<SocketControlMode>(
        id: "automation.socketControlMode",
        defaultValue: .cmuxOnly,
        userDefaultsKey: "socketControlMode"
    )

    public let socketPassword = SecretFileKey(
        id: "automation.socketPassword",
        fileName: "socket-control-password"
    )

    public let claudeCodeIntegration = DefaultsKey<Bool>(
        id: "automation.claudeCodeIntegration",
        defaultValue: true,
        userDefaultsKey: "claudeCodeHooksEnabled"
    )

    public let claudeBinaryPath = DefaultsKey<String>(
        id: "automation.claudeBinaryPath",
        defaultValue: "",
        userDefaultsKey: "claudeCodeCustomClaudePath"
    )

    /// Opt-in AI auto-naming of workspaces and tabs from agent conversation
    /// content. Default off: enabling it lets cmux run the user's own agent
    /// binary (`claude -p` / `codex exec`) to summarize sessions into titles.
    public let workspaceAutoNaming = DefaultsKey<Bool>(
        id: "automation.workspaceAutoNaming",
        defaultValue: false,
        userDefaultsKey: "workspaceAutoNamingEnabled"
    )

    /// Which agent generates the auto-names. Stored as an open string so it
    /// stays fully customizable: ``AutoNamingAgentCatalog/autoSlug`` ("auto",
    /// the default) names each session with its own agent — identical to the
    /// original behavior — while any agent slug (see ``AutoNamingAgentCatalog``)
    /// overrides naming for every session. Unknown/undriveable slugs fall back
    /// to the session's own agent, so a bad value never breaks naming.
    public let autoNamingAgent = DefaultsKey<String>(
        id: "automation.autoNamingAgent",
        defaultValue: AutoNamingAgentCatalog.autoSlug,
        userDefaultsKey: "autoNamingAgent"
    )

    public let ripgrepBinaryPath = DefaultsKey<String>(
        id: "automation.ripgrepBinaryPath",
        defaultValue: "",
        userDefaultsKey: "ripgrepCustomBinaryPath"
    )

    public let suppressSubagentNotifications = DefaultsKey<Bool>(
        id: "automation.suppressSubagentNotifications",
        defaultValue: true,
        userDefaultsKey: "suppressSubagentNotifications"
    )

    // Several agent-integration toggles are intentionally exposed under both
    // `automation.*` (this catalog) and `integrations.*` (IntegrationsCatalogSection)
    // with the same `userDefaultsKey`, so writes through either namespace land
    // on the same persisted value. The shared keys are claudeCode*, cursor*,
    // gemini*, kiro* (including kiroNotificationLevel), amp*,
    // ripgrepCustomBinaryPath, and suppressSubagentNotifications. There is no
    // precedence ambiguity because both DefaultsKey wrappers read/write the
    // same `UserDefaults` slot — the dual namespace exists to keep the JSON
    // config UX (`automation.*`) and the Settings-catalog UX
    // (`integrations.*`) separately discoverable.
    public let ampIntegration = DefaultsKey<Bool>(
        id: "automation.ampIntegration",
        defaultValue: true,
        userDefaultsKey: "ampHooksEnabled"
    )

    public let cursorIntegration = DefaultsKey<Bool>(
        id: "automation.cursorIntegration",
        defaultValue: true,
        userDefaultsKey: "cursorHooksEnabled"
    )

    public let geminiIntegration = DefaultsKey<Bool>(
        id: "automation.geminiIntegration",
        defaultValue: true,
        userDefaultsKey: "geminiHooksEnabled"
    )

    public let kiroIntegration = DefaultsKey<Bool>(
        id: "automation.kiroIntegration",
        defaultValue: true,
        userDefaultsKey: "kiroHooksEnabled"
    )

    public let kiroNotificationLevel = DefaultsKey<String>(
        id: "automation.kiroNotificationLevel",
        defaultValue: "standard",
        userDefaultsKey: "kiroNotificationLevel"
    )

    public let portBase = DefaultsKey<Int>(
        id: "automation.portBase",
        defaultValue: 9100,
        userDefaultsKey: "cmuxPortBase"
    )

    public let portRange = DefaultsKey<Int>(
        id: "automation.portRange",
        defaultValue: 10,
        userDefaultsKey: "cmuxPortRange"
    )

    /// Master switch for the sprite's local semantic router. When on (and a
    /// model is set) the router classifies requests before falling back to
    /// Claude Code. Default on, matching the legacy
    /// `sprite.semanticRouter.enabled` value.
    public let spriteSemanticRouterEnabled = DefaultsKey<Bool>(
        id: "automation.spriteSemanticRouterEnabled",
        defaultValue: true,
        userDefaultsKey: "sprite.semanticRouter.enabled"
    )

    /// Backend powering the local semantic router. Defaults to ``SpriteSemanticRouterProvider/ollama``.
    public let spriteSemanticRouterProvider = DefaultsKey<SpriteSemanticRouterProvider>(
        id: "automation.spriteSemanticRouterProvider",
        defaultValue: .ollama,
        userDefaultsKey: "sprite.semanticRouter.provider"
    )

    /// Model name used only for simple semantic routing (e.g. `qwen2.5-coder:7b`).
    /// Empty disables routing until a model is chosen.
    public let spriteSemanticRouterModel = DefaultsKey<String>(
        id: "automation.spriteSemanticRouterModel",
        defaultValue: "",
        userDefaultsKey: "sprite.semanticRouter.model"
    )

    /// Override for the router endpoint base URL. Empty falls back to the
    /// provider's default (Ollama → `http://localhost:11434`).
    public let spriteSemanticRouterBaseURL = DefaultsKey<String>(
        id: "automation.spriteSemanticRouterBaseURL",
        defaultValue: "",
        userDefaultsKey: "sprite.semanticRouter.baseURL"
    )

    /// Seconds to wait for the router before falling back to Claude Code routing.
    public let spriteSemanticRouterTimeoutSeconds = DefaultsKey<Double>(
        id: "automation.spriteSemanticRouterTimeoutSeconds",
        defaultValue: 12,
        userDefaultsKey: "sprite.semanticRouter.timeoutSeconds"
    )

    /// When on, coalesces rapid sidebar pull-request shell refreshes into a
    /// single debounced run. Default off.
    public let sidebarPullRequestShellDebounceEnabled = DefaultsKey<Bool>(
        id: "automation.sidebarPullRequestShellDebounceEnabled",
        defaultValue: false,
        userDefaultsKey: "sidebarPullRequestShellDebounceEnabled"
    )

    /// Debounce window, in seconds, for sidebar pull-request shell refreshes
    /// when ``sidebarPullRequestShellDebounceEnabled`` is on. Default 5.
    public let sidebarPullRequestShellDebounceSeconds = DefaultsKey<Int>(
        id: "automation.sidebarPullRequestShellDebounceSeconds",
        defaultValue: 5,
        userDefaultsKey: "sidebarPullRequestShellDebounceSeconds"
    )

    public init() {}
}
