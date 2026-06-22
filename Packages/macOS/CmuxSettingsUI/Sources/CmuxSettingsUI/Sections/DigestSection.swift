import CmuxSettings
import Darwin
import SwiftUI

/// **Digest** section — cmux-digest workspace summarization plus its ghpr /
/// PRDashboard integration. Mirrors the legacy in-app Digest and ghpr cards:
/// Enable Workspace Digest, Provider, Model, Enable Summary Priority, then a
/// ghpr card with Enable ghpr Integration, Socket Path, Display Items, and Jira
/// Base URL.
///
/// The legacy provider-preset model picker (`DigestModelPicker`) and the
/// "Restart Digest Daemon" action are host-bound and not yet ported here; the
/// Model field accepts a custom CLI model name directly.
@MainActor
public struct DigestSection: View {
    @State private var enabled: DefaultsValueModel<Bool>
    @State private var provider: DefaultsValueModel<DigestProvider>
    @State private var model: DefaultsValueModel<String>
    @State private var summaryPriority: DefaultsValueModel<Bool>
    @State private var ghprEnabled: DefaultsValueModel<Bool>
    @State private var ghprSocketPath: DefaultsValueModel<String>
    @State private var ghprDisplayItems: DefaultsValueModel<String>
    @State private var ghprJiraBaseURL: DefaultsValueModel<String>

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        _enabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.digest.enabled))
        _provider = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.digest.provider))
        _model = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.digest.model))
        _summaryPriority = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.digest.summaryPriorityEnabled))
        _ghprEnabled = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.digest.ghprEnabled))
        _ghprSocketPath = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.digest.ghprSocketPath))
        _ghprDisplayItems = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.digest.ghprDisplayItems))
        _ghprJiraBaseURL = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.digest.ghprJiraBaseURL))
    }

    private static let columnWidth: CGFloat = 196

    private var ghprSocketPlaceholder: String {
        "/tmp/com.xiaocang.PRDashboard.\(getuid()).sock"
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.digest", defaultValue: "Digest"), section: .digest)
                .accessibilityIdentifier("SettingsDigestSection")
            digestCard
            ghprCard
        }
    }

    @ViewBuilder
    private var digestCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("digest.enabled"),
                String(localized: "settings.digest.enabled", defaultValue: "Enable Workspace Digest"),
                subtitle: String(localized: "settings.digest.enabled.subtitle", defaultValue: "Allow cmux-digest to summarize workspace state for sidebar and Radar views.")
            ) {
                Toggle("", isOn: Binding(get: { enabled.current }, set: { enabled.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsDigestEnabledToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("digest.provider"),
                String(localized: "settings.digest.provider", defaultValue: "Provider"),
                subtitle: String(localized: "settings.digest.provider.subtitle", defaultValue: "Use Claude Code or Codex CLI for summaries."),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { provider.current }, set: { provider.set($0) })) {
                    Text(String(localized: "settings.digest.provider.claude", defaultValue: "Claude Code")).tag(DigestProvider.claudeCode)
                    Text(String(localized: "settings.digest.provider.codex", defaultValue: "Codex")).tag(DigestProvider.codex)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("digest.model"),
                String(localized: "settings.digest.model", defaultValue: "Model"),
                subtitle: String(localized: "settings.digest.model.subtitle", defaultValue: "Provider default unless you enter a custom CLI model name."),
                controlWidth: 220
            ) {
                TextField(
                    String(localized: "settings.digest.model.placeholder", defaultValue: "provider default"),
                    text: Binding(get: { model.current }, set: { model.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("workspaceTab.summaryPriority.enabled"),
                String(localized: "settings.summaryPriority.enabled", defaultValue: "Enable Summary Priority"),
                subtitle: String(localized: "settings.summaryPriority.enabled.subtitle", defaultValue: "Rank workspace summaries in the extension column.")
            ) {
                Toggle("", isOn: Binding(get: { summaryPriority.current }, set: { summaryPriority.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsSummaryPriorityToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.digest.note", defaultValue: "The provider-preset model picker and Restart Digest Daemon action live in the legacy Settings and the cmux JSON config; they are not yet available from this pane."))
        }
    }

    @ViewBuilder
    private var ghprCard: some View {
        let enabled = ghprEnabled.current
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("digest.ghpr.enabled"),
                String(localized: "settings.digest.ghpr.enabled", defaultValue: "Enable ghpr Integration"),
                subtitle: String(localized: "settings.digest.ghpr.enabled.subtitle", defaultValue: "Read PRDashboard's local socket for read-only PR context and feed it into Workspace Digest.")
            ) {
                Toggle("", isOn: Binding(get: { ghprEnabled.current }, set: { ghprEnabled.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsGhprEnabledToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("digest.ghpr.socketPath"),
                String(localized: "settings.digest.ghpr.socketPath", defaultValue: "ghpr Socket Path"),
                subtitle: String(localized: "settings.digest.ghpr.socketPath.subtitle", defaultValue: "Unix socket used by PRDashboard. Leave empty for the default unless you run a custom socket."),
                controlWidth: 260
            ) {
                TextField(ghprSocketPlaceholder, text: Binding(get: { ghprSocketPath.current }, set: { ghprSocketPath.set($0) }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!enabled)
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("digest.ghpr.displayItems"),
                String(localized: "settings.digest.ghpr.displayItems", defaultValue: "ghpr Display Items"),
                subtitle: String(localized: "settings.digest.ghpr.displayItems.subtitle", defaultValue: "Comma-separated sidebar items, such as ci, review, unresolved, jira, title, draft, conflicts."),
                controlWidth: 220
            ) {
                TextField("ci, review, unresolved, jira", text: Binding(get: { ghprDisplayItems.current }, set: { ghprDisplayItems.set($0) }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!enabled)
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("digest.ghpr.jiraBaseURL"),
                String(localized: "settings.digest.ghpr.jiraBaseURL", defaultValue: "Jira Base URL"),
                subtitle: String(localized: "settings.digest.ghpr.jiraBaseURL.subtitle", defaultValue: "Optional Jira base, for example https://jira.example.com. Use {ticket} for custom URL templates."),
                controlWidth: 260
            ) {
                TextField(
                    String(localized: "settings.digest.ghpr.jiraBaseURL.placeholder", defaultValue: "https://jira.example.com"),
                    text: Binding(get: { ghprJiraBaseURL.current }, set: { ghprJiraBaseURL.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .disabled(!enabled)
            }
        }
    }
}
