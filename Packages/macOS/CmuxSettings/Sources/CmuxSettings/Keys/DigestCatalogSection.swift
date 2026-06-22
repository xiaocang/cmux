import Foundation

/// Settings under the dotted-id prefix `digest.*` (plus the related
/// `workspaceTab.summaryPriority.enabled` toggle) — cmux-digest workspace
/// summarization and its ghpr / PRDashboard integration.
///
/// All keys are UserDefaults-backed under their dotted id, matching the legacy
/// `@AppStorage("digest.*")` values.
public struct DigestCatalogSection: SettingCatalogSection {
    /// Master switch for cmux-digest workspace summaries. Default off.
    public let enabled = DefaultsKey<Bool>(
        id: "digest.enabled",
        defaultValue: false,
        userDefaultsKey: "digest.enabled"
    )

    /// CLI backend used for summaries. Defaults to ``DigestProvider/claudeCode``.
    public let provider = DefaultsKey<DigestProvider>(
        id: "digest.provider",
        defaultValue: .claudeCode,
        userDefaultsKey: "digest.provider"
    )

    /// Provider preset or custom CLI model name used for summaries. Empty uses
    /// the provider's default model.
    public let model = DefaultsKey<String>(
        id: "digest.model",
        defaultValue: "",
        userDefaultsKey: "digest.model"
    )

    /// When on, reads PRDashboard's local socket for read-only PR context and
    /// feeds it into Workspace Digest. Default off.
    public let ghprEnabled = DefaultsKey<Bool>(
        id: "digest.ghpr.enabled",
        defaultValue: false,
        userDefaultsKey: "digest.ghpr.enabled"
    )

    /// Override for the PRDashboard Unix socket path. Empty uses the default
    /// per-user socket.
    public let ghprSocketPath = DefaultsKey<String>(
        id: "digest.ghpr.socketPath",
        defaultValue: "",
        userDefaultsKey: "digest.ghpr.socketPath"
    )

    /// Comma-separated sidebar items shown from ghpr (e.g. `ci, review,
    /// unresolved, jira`). Empty uses the built-in default set.
    public let ghprDisplayItems = DefaultsKey<String>(
        id: "digest.ghpr.displayItems",
        defaultValue: "",
        userDefaultsKey: "digest.ghpr.displayItems"
    )

    /// Optional Jira base URL for ghpr ticket links (e.g.
    /// `https://jira.example.com`; `{ticket}` for custom templates).
    public let ghprJiraBaseURL = DefaultsKey<String>(
        id: "digest.ghpr.jiraBaseURL",
        defaultValue: "",
        userDefaultsKey: "digest.ghpr.jiraBaseURL"
    )

    /// When on, ranks workspace summaries in the sidebar extension column.
    /// Stored under `workspaceTab.summaryPriority.enabled`; default on.
    public let summaryPriorityEnabled = DefaultsKey<Bool>(
        id: "workspaceTab.summaryPriority.enabled",
        defaultValue: true,
        userDefaultsKey: "workspaceTab.summaryPriority.enabled"
    )

    public init() {}
}
