import CmuxSettings
import SwiftUI

/// **Automation** section — mirrors the legacy in-app section
/// row-for-row: Socket Control (mode picker, password subrow when
/// .password, warnings, overrides note), then separate cards for
/// Claude Code Integration, Claude Binary Path, Ripgrep Binary Path,
/// Suppress Subagent Notifications, Cursor Integration, Gemini
/// Integration, and Port Base / Port Range Size.
@MainActor
public struct AutomationSection: View {
    private let catalog: SettingCatalog
    private let hostActions: SettingsHostActions

    @State private var socketPasswordModel: SecretValueModel
    @State private var modeModel: DefaultsValueModel<SocketControlMode>
    @State private var claudeCodeModel: DefaultsValueModel<Bool>
    @State private var claudePathModel: DefaultsValueModel<String>
    @State private var ripgrepPathModel: DefaultsValueModel<String>
    @State private var suppressSubagentModel: DefaultsValueModel<Bool>
    @State private var cursorModel: DefaultsValueModel<Bool>
    @State private var geminiModel: DefaultsValueModel<Bool>
    @State private var kiroModel: DefaultsValueModel<Bool>
    @State private var kiroLevelModel: DefaultsValueModel<String>
    @State private var portBaseModel: DefaultsValueModel<Int>
    @State private var portRangeModel: DefaultsValueModel<Int>
    @State private var routerEnabledModel: DefaultsValueModel<Bool>
    @State private var routerProviderModel: DefaultsValueModel<SpriteSemanticRouterProvider>
    @State private var routerModelNameModel: DefaultsValueModel<String>
    @State private var routerBaseURLModel: DefaultsValueModel<String>
    @State private var routerTimeoutModel: DefaultsValueModel<Double>
    @State private var prDebounceEnabledModel: DefaultsValueModel<Bool>
    @State private var prDebounceSecondsModel: DefaultsValueModel<Int>
    @State private var routerOllamaModels: [String] = []
    @State private var routerOllamaLoading = false
    @State private var routerOllamaStatus: String?
    @State private var routerOllamaStatusIsError = false
    @State private var routerTesting = false
    @State private var routerTestStatus: String?
    @State private var routerTestStatusIsError = false
    @State private var socketPasswordDraft: String = ""
    @State private var socketPasswordStatus: SocketPasswordStatus?
    @State private var showOpenAccessConfirmation: Bool = false
    @State private var pendingOpenAccessMode: SocketControlMode?
    @State private var modeBeforePendingOpenAccess: SocketControlMode?

    private struct SocketPasswordStatus: Equatable {
        let message: String
        let isError: Bool
    }

    public init(
        defaultsStore: UserDefaultsSettingsStore,
        jsonStore: JSONConfigStore,
        secretStore: SecretFileStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        hostActions: SettingsHostActions
    ) {
        self.catalog = catalog
        self.hostActions = hostActions
        _socketPasswordModel = State(initialValue: SecretValueModel(
            store: secretStore,
            key: catalog.automation.socketPassword,
            errorLog: errorLog
        ))
        _modeModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.socketControlMode))
        _claudeCodeModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.claudeCodeHooksEnabled))
        _claudePathModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.claudeCodeCustomClaudePath))
        _ripgrepPathModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.ripgrepCustomBinaryPath))
        _suppressSubagentModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.suppressSubagentNotifications))
        _cursorModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.cursorHooksEnabled))
        _geminiModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.geminiHooksEnabled))
        _kiroModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.kiroHooksEnabled))
        _kiroLevelModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.integrations.kiroNotificationLevel))
        _portBaseModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.portBase))
        _portRangeModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.portRange))
        _routerEnabledModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.spriteSemanticRouterEnabled))
        _routerProviderModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.spriteSemanticRouterProvider))
        _routerModelNameModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.spriteSemanticRouterModel))
        _routerBaseURLModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.spriteSemanticRouterBaseURL))
        _routerTimeoutModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.spriteSemanticRouterTimeoutSeconds))
        _prDebounceEnabledModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.sidebarPullRequestShellDebounceEnabled))
        _prDebounceSecondsModel = State(initialValue: DefaultsValueModel(store: defaultsStore, key: catalog.automation.sidebarPullRequestShellDebounceSeconds))
    }

    private static let columnWidth: CGFloat = 196

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.automation", defaultValue: "Automation"), section: .automation)

            socketControlCard
            Group {
                claudeCodeCard
                claudePathCard
                ripgrepPathCard
                suppressSubagentCard
                cursorCard
                geminiCard
                kiroCard
            }
            portCard
            spriteLocalLLMCard
            prShellDebounceCard
        }
        .confirmationDialog(
            String(localized: "settings.automation.openAccess.dialog.title", defaultValue: "Enable full open access?"),
            isPresented: $showOpenAccessConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "settings.automation.openAccess.dialog.confirm", defaultValue: "Enable Full Open Access"),
                role: .destructive
            ) {
                if let pending = pendingOpenAccessMode {
                    modeModel.set(pending)
                }
                pendingOpenAccessMode = nil
                modeBeforePendingOpenAccess = nil
            }
            Button(
                String(localized: "settings.automation.openAccess.dialog.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) {
                pendingOpenAccessMode = nil
                modeBeforePendingOpenAccess = nil
            }
        } message: {
            Text(String(
                localized: "settings.automation.openAccess.dialog.message",
                defaultValue: "This disables ancestry and password checks and opens the socket to all local users. Only enable when you understand the risk."
            ))
        }
    }

    @ViewBuilder
    private var socketControlCard: some View {
        let isPassword = modeModel.current == .password
        let isAllowAll = modeModel.current == .allowAll
        let hasPassword = !socketPasswordModel.current.isEmpty

        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.socketControlMode"),
                String(localized: "settings.automation.socketMode", defaultValue: "Socket Control Mode"),
                subtitle: modeModel.current.description,
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(
                    get: { modeModel.current },
                    set: { newValue in
                        if newValue == .allowAll && modeModel.current != .allowAll {
                            modeBeforePendingOpenAccess = modeModel.current
                            pendingOpenAccessMode = newValue
                            showOpenAccessConfirmation = true
                            return
                        }
                        modeModel.set(newValue)
                        if newValue != .password {
                            socketPasswordStatus = nil
                        }
                    }
                )) {
                    ForEach(SocketControlMode.uiCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("AutomationSocketModePicker")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.socketMode.note", defaultValue: "Controls access to the local Unix socket for programmatic control. Choose a mode that matches your threat model."))

            if isPassword {
                SettingsCardDivider()
                SettingsCardRow(
                    configurationReview: .json("automation.socketPassword"),
                    String(localized: "settings.automation.socketPassword", defaultValue: "Socket Password"),
                    subtitle: hasPassword
                        ? String(localized: "settings.automation.socketPassword.subtitleSet", defaultValue: "Stored in Application Support.")
                        : String(localized: "settings.automation.socketPassword.subtitleUnset", defaultValue: "No password set. External clients will be blocked until one is configured.")
                ) {
                    HStack(spacing: 8) {
                        SecureField(
                            String(localized: "settings.automation.socketPassword.placeholder", defaultValue: "Password"),
                            text: $socketPasswordDraft
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        Button(
                            hasPassword
                                ? String(localized: "settings.automation.socketPassword.change", defaultValue: "Change")
                                : String(localized: "settings.automation.socketPassword.set", defaultValue: "Set")
                        ) {
                            saveSocketPassword()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasPassword {
                            Button(String(localized: "settings.automation.socketPassword.clear", defaultValue: "Clear")) {
                                clearSocketPassword()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                if let status = socketPasswordStatus {
                    Text(status.message)
                        .font(.caption)
                        .foregroundStyle(status.isError ? Color.red : Color.secondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }
            }

            if isAllowAll {
                SettingsCardDivider()
                Text(String(localized: "settings.automation.openAccessWarning", defaultValue: "Warning: Full open access makes the control socket world-readable/writable on this Mac and disables auth checks. Use only for local debugging."))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }

            SettingsCardNote(String(localized: "settings.automation.socketOverrides.note", defaultValue: "Overrides: CMUX_SOCKET_ENABLE, CMUX_SOCKET_MODE, and CMUX_SOCKET_PATH (set CMUX_ALLOW_SOCKET_OVERRIDE=1 for stable/nightly builds)."))
        }
    }

    @ViewBuilder
    private var claudeCodeCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.claudeCodeIntegration"),
                String(localized: "settings.automation.claudeCode", defaultValue: "Claude Code Integration"),
                subtitle: claudeCodeModel.current
                    ? String(localized: "settings.automation.claudeCode.subtitleOn", defaultValue: "Sidebar shows Claude session status and notifications.")
                    : String(localized: "settings.automation.claudeCode.subtitleOff", defaultValue: "Claude Code runs without cmux integration.")
            ) {
                Toggle("", isOn: Binding(get: { claudeCodeModel.current }, set: { claudeCodeModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsClaudeCodeHooksToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.claudeCode.note", defaultValue: "When enabled, cmux wraps the claude command to inject session tracking and notification hooks. Disable if you prefer to manage Claude Code hooks yourself."))
        }
    }

    @ViewBuilder
    private var claudePathCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.claudeBinaryPath"),
                String(localized: "settings.automation.claudeCode.customPath", defaultValue: "Claude Binary Path"),
                subtitle: String(localized: "settings.automation.claudeCode.customPath.subtitle", defaultValue: "Custom path to the claude binary. Leave empty to use PATH.")
            ) {
                TextField(
                    String(localized: "settings.automation.claudeCode.customPath.placeholder", defaultValue: "e.g. /usr/local/bin/claude"),
                    text: Binding(get: { claudePathModel.current }, set: { claudePathModel.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
        }
    }

    @ViewBuilder
    private var ripgrepPathCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.ripgrepBinaryPath"),
                String(localized: "settings.automation.ripgrep.customPath", defaultValue: "Ripgrep Binary Path"),
                subtitle: String(localized: "settings.automation.ripgrep.customPath.subtitle", defaultValue: "Custom path to the rg binary used by Find. Leave empty to use common install locations and PATH.")
            ) {
                TextField(
                    String(localized: "settings.automation.ripgrep.customPath.placeholder", defaultValue: "e.g. /etc/profiles/per-user/you/bin/rg"),
                    text: Binding(get: { ripgrepPathModel.current }, set: { ripgrepPathModel.set($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            }
        }
    }

    @ViewBuilder
    private var suppressSubagentCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.suppressSubagentNotifications"),
                String(localized: "settings.automation.suppressSubagentNotifications", defaultValue: "Suppress Subagent Notifications"),
                subtitle: suppressSubagentModel.current
                    ? String(localized: "settings.automation.suppressSubagentNotifications.subtitleOn", defaultValue: "Child agent completions stay in Feed without notifications.")
                    : String(localized: "settings.automation.suppressSubagentNotifications.subtitleOff", defaultValue: "Child agent completions notify like top-level agents.")
            ) {
                Toggle("", isOn: Binding(get: { suppressSubagentModel.current }, set: { suppressSubagentModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsSuppressSubagentNotificationsToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.suppressSubagentNotifications.note", defaultValue: "Uses process ancestry from hook processes. Disable if nested Codex or Claude sessions should trigger completion notifications."))
        }
    }

    @ViewBuilder
    private var cursorCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.cursorIntegration"),
                String(localized: "settings.automation.cursor", defaultValue: "Cursor Integration"),
                subtitle: cursorModel.current
                    ? String(localized: "settings.automation.cursor.subtitleOn", defaultValue: "Sidebar shows Cursor agent status and notifications.")
                    : String(localized: "settings.automation.cursor.subtitleOff", defaultValue: "Cursor runs without cmux integration.")
            ) {
                Toggle("", isOn: Binding(get: { cursorModel.current }, set: { cursorModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsCursorHooksToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.cursor.note", defaultValue: "Hooks must be installed with `cmux hooks cursor install`. They no-op outside cmux terminals."))
        }
    }

    @ViewBuilder
    private var geminiCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.geminiIntegration"),
                String(localized: "settings.automation.gemini", defaultValue: "Gemini CLI Integration"),
                subtitle: geminiModel.current
                    ? String(localized: "settings.automation.gemini.subtitleOn", defaultValue: "Sidebar shows Gemini session status and notifications.")
                    : String(localized: "settings.automation.gemini.subtitleOff", defaultValue: "Gemini runs without cmux integration.")
            ) {
                Toggle("", isOn: Binding(get: { geminiModel.current }, set: { geminiModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsGeminiHooksToggle")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.gemini.note", defaultValue: "Hooks must be installed with `cmux hooks gemini install`. They no-op outside cmux terminals."))
        }
    }

    @ViewBuilder
    private var kiroCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.kiroIntegration"),
                String(localized: "settings.automation.kiro", defaultValue: "Kiro CLI Integration"),
                subtitle: kiroModel.current
                    ? String(localized: "settings.automation.kiro.subtitleOn", defaultValue: "Sidebar shows Kiro session status, notifications, and Feed tool events.")
                    : String(localized: "settings.automation.kiro.subtitleOff", defaultValue: "Kiro runs without cmux integration.")
            ) {
                Toggle("", isOn: Binding(get: { kiroModel.current }, set: { kiroModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsKiroHooksToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("automation.kiroNotificationLevel"),
                String(localized: "settings.automation.kiro.notificationLevel", defaultValue: "Kiro Notification Level"),
                subtitle: String(localized: "settings.automation.kiro.notificationLevel.subtitle", defaultValue: "Controls how many Kiro tool events appear in Feed."),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { kiroLevelModel.current }, set: { kiroLevelModel.set($0) })) {
                    Text(String(localized: "settings.automation.kiro.notificationLevel.minimal", defaultValue: "Minimal")).tag("minimal")
                    Text(String(localized: "settings.automation.kiro.notificationLevel.standard", defaultValue: "Standard")).tag("standard")
                    Text(String(localized: "settings.automation.kiro.notificationLevel.verbose", defaultValue: "Verbose")).tag("verbose")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("SettingsKiroNotificationLevelPicker")
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.kiro.note", defaultValue: "Hooks must be installed with `cmux hooks kiro install`, then run Kiro with `kiro-cli chat --agent cmux` (or set it as your default agent). They no-op outside cmux terminals."))
        }
    }

    @ViewBuilder
    private var portCard: some View {
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.portBase"),
                String(localized: "settings.automation.portBase", defaultValue: "Port Base"),
                subtitle: String(localized: "settings.automation.portBase.subtitle", defaultValue: "Starting port for CMUX_PORT env var."),
                controlWidth: Self.columnWidth
            ) {
                TextField("", value: Binding(get: { portBaseModel.current }, set: { portBaseModel.set($0) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("automation.portRange"),
                String(localized: "settings.automation.portRange", defaultValue: "Port Range Size"),
                subtitle: String(localized: "settings.automation.portRange.subtitle", defaultValue: "Number of ports per workspace."),
                controlWidth: Self.columnWidth
            ) {
                TextField("", value: Binding(get: { portRangeModel.current }, set: { portRangeModel.set($0) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }
            SettingsCardDivider()
            SettingsCardNote(String(localized: "settings.automation.port.note", defaultValue: "Each workspace gets CMUX_PORT and CMUX_PORT_END env vars with a dedicated port range. New terminals inherit these values."))
        }
    }

    private var routerBaseURLPlaceholder: String {
        routerProviderModel.current == .ollama ? "http://localhost:11434" : "https://api.openai.com/v1"
    }

    private func refreshOllamaModels() {
        guard routerProviderModel.current == .ollama else { return }
        routerOllamaLoading = true
        routerOllamaStatus = nil
        routerOllamaStatusIsError = false
        let baseURL = routerBaseURLModel.current
        let timeout = routerTimeoutModel.current
        Task {
            do {
                let models = try await hostActions.fetchSpriteOllamaModels(baseURL: baseURL, timeoutSeconds: timeout)
                routerOllamaModels = models
                routerOllamaLoading = false
                routerOllamaStatusIsError = false
                routerOllamaStatus = models.isEmpty
                    ? String(localized: "settings.sprite.localLLM.models.empty", defaultValue: "No Ollama models found.")
                    : String(
                        format: String(localized: "settings.sprite.localLLM.models.loaded", defaultValue: "Loaded %d model(s)."),
                        models.count
                    )
                if routerModelNameModel.current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let first = models.first {
                    routerModelNameModel.set(first)
                }
            } catch {
                routerOllamaModels = []
                routerOllamaLoading = false
                routerOllamaStatusIsError = true
                routerOllamaStatus = String(localized: "settings.sprite.localLLM.models.failed", defaultValue: "Could not load Ollama models.")
            }
        }
    }

    private func testRouter() {
        let model = routerModelNameModel.current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            routerTestStatus = String(localized: "settings.sprite.localLLM.test.missingModel", defaultValue: "Set a model before testing.")
            routerTestStatusIsError = true
            return
        }
        routerTesting = true
        routerTestStatusIsError = false
        routerTestStatus = String(localized: "settings.sprite.localLLM.test.running", defaultValue: "Sending test request...")
        let provider = routerProviderModel.current.rawValue
        let baseURL = routerBaseURLModel.current
        let timeout = routerTimeoutModel.current
        Task {
            let result = await hostActions.testSpriteRouter(provider: provider, model: model, baseURL: baseURL, timeoutSeconds: timeout)
            routerTesting = false
            routerTestStatusIsError = !result.passed
            routerTestStatus = result.message
        }
    }

    @ViewBuilder
    private var spriteLocalLLMCard: some View {
        let enabled = routerEnabledModel.current
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                searchAnchorID: "setting:automation:sprite-local-llm",
                String(localized: "settings.sprite.localLLM.title", defaultValue: "Sprite Local LLM Router"),
                subtitle: String(localized: "settings.sprite.localLLM.subtitle", defaultValue: "Route simple sprite requests through a local LLM before falling back to Claude Code.")
            ) {
                Toggle("", isOn: Binding(get: { routerEnabledModel.current }, set: { routerEnabledModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsSpriteLocalLLMEnabledToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.sprite.localLLM.provider", defaultValue: "Provider"),
                subtitle: String(localized: "settings.sprite.localLLM.provider.subtitle", defaultValue: "Defaults to Ollama for local semantic routing."),
                controlWidth: Self.columnWidth
            ) {
                Picker("", selection: Binding(get: { routerProviderModel.current }, set: { routerProviderModel.set($0) })) {
                    Text(String(localized: "settings.sprite.localLLM.provider.ollama", defaultValue: "Ollama")).tag(SpriteSemanticRouterProvider.ollama)
                    Text(String(localized: "settings.sprite.localLLM.provider.openAICompatible", defaultValue: "OpenAI-compatible")).tag(SpriteSemanticRouterProvider.openAICompatible)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(!enabled)
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.sprite.localLLM.baseURL", defaultValue: "Base URL"),
                subtitle: String(localized: "settings.sprite.localLLM.baseURL.subtitle", defaultValue: "Ollama default is http://localhost:11434."),
                controlWidth: 280
            ) {
                TextField(routerBaseURLPlaceholder, text: Binding(get: { routerBaseURLModel.current }, set: { routerBaseURLModel.set($0) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(!enabled)
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.sprite.localLLM.model", defaultValue: "Model"),
                subtitle: String(localized: "settings.sprite.localLLM.model.subtitle", defaultValue: "Model name used only for simple semantic routing."),
                controlWidth: 330
            ) {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField(
                            String(localized: "settings.sprite.localLLM.model.placeholder", defaultValue: "e.g. qwen2.5-coder:7b"),
                            text: Binding(get: { routerModelNameModel.current }, set: { routerModelNameModel.set($0) })
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                        if routerProviderModel.current == .ollama {
                            Button(
                                routerOllamaLoading
                                    ? String(localized: "settings.sprite.localLLM.models.loading", defaultValue: "Loading")
                                    : String(localized: "settings.sprite.localLLM.models.refresh", defaultValue: "Refresh")
                            ) {
                                refreshOllamaModels()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!enabled || routerOllamaLoading)
                            .accessibilityIdentifier("SettingsSpriteLocalLLMRefreshModelsButton")
                        }
                    }

                    if routerProviderModel.current == .ollama, !routerOllamaModels.isEmpty {
                        Picker("", selection: Binding(get: { routerModelNameModel.current }, set: { routerModelNameModel.set($0) })) {
                            ForEach(routerOllamaModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("SettingsSpriteLocalLLMModelPicker")
                    }

                    if let status = routerOllamaStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(routerOllamaStatusIsError ? Color.red : Color.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .disabled(!enabled)
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.sprite.localLLM.timeout", defaultValue: "Timeout"),
                subtitle: String(localized: "settings.sprite.localLLM.timeout.subtitle", defaultValue: "Seconds to wait before falling back to Claude Code routing."),
                controlWidth: Self.columnWidth
            ) {
                TextField("", value: Binding(get: { routerTimeoutModel.current }, set: { routerTimeoutModel.set($0) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .disabled(!enabled)
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.sprite.localLLM.test", defaultValue: "Test Router"),
                subtitle: String(localized: "settings.sprite.localLLM.test.subtitle", defaultValue: "Sends a repo-context request and verifies the JSON route format."),
                controlWidth: 330
            ) {
                VStack(alignment: .trailing, spacing: 6) {
                    Button(
                        routerTesting
                            ? String(localized: "settings.sprite.localLLM.test.testing", defaultValue: "Testing")
                            : String(localized: "settings.sprite.localLLM.test.button", defaultValue: "Test")
                    ) {
                        testRouter()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(
                        !enabled
                            || routerTesting
                            || routerModelNameModel.current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("SettingsSpriteLocalLLMTestButton")

                    if let status = routerTestStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(routerTestStatusIsError ? Color.red : Color.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var prShellDebounceCard: some View {
        let enabled = prDebounceEnabledModel.current
        SettingsCard {
            SettingsCardRow(
                configurationReview: .json("automation.sidebarPullRequestShellDebounceEnabled"),
                String(localized: "settings.automation.prShellDebounce", defaultValue: "Debounce Sidebar PR Shell Refreshes"),
                subtitle: String(localized: "settings.automation.prShellDebounce.subtitle", defaultValue: "Coalesce rapid pull-request shell refreshes in the sidebar into a single debounced run.")
            ) {
                Toggle("", isOn: Binding(get: { prDebounceEnabledModel.current }, set: { prDebounceEnabledModel.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsPRShellDebounceToggle")
            }
            SettingsCardDivider()
            SettingsCardRow(
                configurationReview: .json("automation.sidebarPullRequestShellDebounceSeconds"),
                String(localized: "settings.automation.prShellDebounce.seconds", defaultValue: "Debounce Window"),
                subtitle: String(localized: "settings.automation.prShellDebounce.seconds.subtitle", defaultValue: "Seconds to wait before running a coalesced refresh."),
                controlWidth: Self.columnWidth
            ) {
                TextField("", value: Binding(get: { prDebounceSecondsModel.current }, set: { prDebounceSecondsModel.set($0) }), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .disabled(!enabled)
            }
        }
    }

    private func saveSocketPassword() {
        let trimmed = socketPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            socketPasswordStatus = SocketPasswordStatus(
                message: String(localized: "settings.automation.socketPassword.empty", defaultValue: "Enter a password first."),
                isError: true
            )
            return
        }
        socketPasswordModel.set(trimmed)
        socketPasswordDraft = ""
        socketPasswordStatus = SocketPasswordStatus(
            message: String(localized: "settings.automation.socketPassword.saved", defaultValue: "Saved."),
            isError: false
        )
    }

    private func clearSocketPassword() {
        socketPasswordModel.reset()
        socketPasswordDraft = ""
        socketPasswordStatus = SocketPasswordStatus(
            message: String(localized: "settings.automation.socketPassword.cleared", defaultValue: "Cleared."),
            isError: false
        )
    }

}
