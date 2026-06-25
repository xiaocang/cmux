import Foundation

/// Settings under the dotted-id prefix `terminal.*`.
public struct TerminalCatalogSection: SettingCatalogSection {
    public let showScrollBar = DefaultsKey<Bool>(
        id: "terminal.showScrollBar",
        defaultValue: true,
        userDefaultsKey: "terminal.showScrollBar"
    )

    public let copyOnSelect = DefaultsKey<Bool>(
        id: "terminal.copyOnSelect",
        defaultValue: false,
        userDefaultsKey: "terminal.copyOnSelect"
    )

    public let autoResumeAgentSessions = DefaultsKey<Bool>(
        id: "terminal.autoResumeAgentSessions",
        defaultValue: true,
        userDefaultsKey: "terminal.autoResumeAgentSessions"
    )

    public let agentHibernationEnabled = DefaultsKey<Bool>(
        id: "terminal.agentHibernation.enabled",
        defaultValue: false,
        userDefaultsKey: "terminal.agentHibernation.enabled"
    )

    public let agentHibernationIdleSeconds = DefaultsKey<Double>(
        id: "terminal.agentHibernation.idleSeconds",
        defaultValue: 5,
        userDefaultsKey: "terminal.agentHibernation.idleSeconds"
    )

    public let agentHibernationMaxLiveTerminals = DefaultsKey<Int>(
        id: "terminal.agentHibernation.maxLiveTerminals",
        defaultValue: 12,
        userDefaultsKey: "terminal.agentHibernation.maxLiveTerminals"
    )

    /// Whether off-screen terminals release their GPU renderer memory while
    /// idle (rebuilt instantly on re-show). Non-destructive; on by default.
    public let rendererRealizationEnabled = DefaultsKey<Bool>(
        id: "terminal.rendererRealization.enabled",
        defaultValue: true,
        userDefaultsKey: "terminal.rendererRealization.enabled"
    )

    /// Seconds a terminal must stay off-screen before its renderer memory is
    /// reclaimed.
    public let rendererRealizationIdleSeconds = DefaultsKey<Double>(
        id: "terminal.rendererRealization.idleSeconds",
        defaultValue: 30,
        userDefaultsKey: "terminal.rendererRealization.idleSeconds"
    )

    /// Most-recently-visible terminals to keep renderer-ready so switching stays
    /// instant. Extra off-screen renderers are reclaimed oldest first.
    public let rendererRealizationMaxWarmRenderers = DefaultsKey<Int>(
        id: "terminal.rendererRealization.maxWarmRenderers",
        defaultValue: 12,
        userDefaultsKey: "terminal.rendererRealization.maxWarmRenderers"
    )

    public let showTextBoxOnNewTerminals = DefaultsKey<Bool>(
        id: "terminal.showTextBoxOnNewTerminals",
        defaultValue: false,
        userDefaultsKey: "terminal.showTextBoxOnNewTerminals"
    )

    public let focusTextBoxOnNewTerminals = DefaultsKey<Bool>(
        id: "terminal.focusTextBoxOnNewTerminals",
        defaultValue: false,
        userDefaultsKey: "terminal.focusTextBoxOnNewTerminals"
    )

    public let textBoxMaxLines = DefaultsKey<Int>(
        id: "terminal.textBoxMaxLines",
        defaultValue: 10,
        userDefaultsKey: "terminal.textBoxMaxLines"
    )

    public let resumeCommands = JSONKey<[String]>(
        id: "terminal.resumeCommands",
        defaultValue: []
    )

    /// Whether new terminal panes run their shell directly or wrap it in
    /// livesh. Defaults to ``TerminalShellBackend/direct``.
    public let shellBackend = DefaultsKey<TerminalShellBackend>(
        id: "terminal.shellBackend",
        defaultValue: .direct,
        userDefaultsKey: "terminalShellBackend"
    )

    /// Absolute path override for the `livesh` executable. Empty means cmux
    /// searches the user's default install locations and `PATH`.
    public let liveshExecutablePath = DefaultsKey<String>(
        id: "terminal.liveshExecutablePath",
        defaultValue: "",
        userDefaultsKey: "terminalLiveshExecutablePath"
    )

    /// Absolute path override for the `liveshctl` executable used by live-shell
    /// management commands. Empty means cmux searches the user's default install
    /// locations and `PATH`.
    public let liveshctlExecutablePath = DefaultsKey<String>(
        id: "terminal.liveshctlExecutablePath",
        defaultValue: "",
        userDefaultsKey: "terminalLiveshctlExecutablePath"
    )

    public init() {}
}
