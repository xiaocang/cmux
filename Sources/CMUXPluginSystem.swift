import AppKit
import Darwin
import Foundation
import CMUXPluginAPI

protocol WorkspaceDigestServicing: AnyObject {
    func refreshSummaryPriority(
        force: Bool,
        sort: WorkspaceSidebarSummaryPrioritySort,
        assistantContext: WorkspaceSidebarAssistantContext?,
        completion: @escaping (Result<WorkspaceSidebarSummaryPriorityState, Error>) -> Void
    )
    func setDisplayMode(_ mode: WorkspaceSidebarDisplayMode, completion: @escaping (Result<Void, Error>) -> Void)
    func refreshWorkspace(
        workspaceId: String,
        force: Bool,
        refinement: String?,
        sort: WorkspaceSidebarSummaryPrioritySort,
        completion: @escaping (Result<WorkspaceSidebarSummaryPriorityItem, Error>) -> Void
    )
    func scoreWorkspace(
        workspaceId: String,
        sort: WorkspaceSidebarSummaryPrioritySort,
        completion: @escaping (Result<WorkspaceSidebarSummaryPriorityItem, Error>) -> Void
    )
    func setOverride(
        workspaceId: String,
        patch: [String: Any],
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func progress(completion: @escaping (Result<WorkspaceSidebarDigestProgressState, Error>) -> Void)
}

extension WorkspaceDigestServicing {
    func refreshSummaryPriority(
        force: Bool,
        sort: WorkspaceSidebarSummaryPrioritySort,
        completion: @escaping (Result<WorkspaceSidebarSummaryPriorityState, Error>) -> Void
    ) {
        refreshSummaryPriority(
            force: force,
            sort: sort,
            assistantContext: nil,
            completion: completion
        )
    }
}

enum CMUXBuiltinSidebarExtensionID {
    static let summaryPriority = "@cmux/sidebar-extension.summary-priority"
}

enum CMUXBuiltinPluginID {
    static let noop = "@cmux/plugin-noop"
    static let contextBridge = "@cmux/plugin-context-bridge"
    static let tmuxPrefix = "@cmux/plugin-tmux-prefix"
    static let ghpr = "@cmux/plugin-ghpr"
    static let digest = "@cmux/plugin-digest"
}

enum CMUXBuiltinPluginCommandID {
    static let toggleSummaryPriority = "plugin.digest.summary_priority.toggle"
    static let restartDigest = "plugin.digest.restart"
}

enum CMUXBuiltinSettingsContributionID {
    static let tmuxPrefix = "@cmux/plugin-tmux-prefix.settings"
    static let ghpr = "@cmux/plugin-ghpr.settings"
    static let digest = "@cmux/plugin-digest.settings"
}

protocol CMUXPluginAppProviding: AnyObject {
    var workspaceDigestService: WorkspaceDigestServicing { get }
    func commandContributions() -> [CMUXCommandContribution]
    func runCommand(id: String) -> Bool
    func sidebarExtensions(placement: CMUXSidebarExtensionPlacement) -> [CMUXSidebarExtensionContribution]
    func toggleSidebarExtension(id: String) -> Bool
    func setSidebarExtensionOpen(id: String, open: Bool) -> Bool
}

protocol CMUXPluginLifecycleManaging: AnyObject {
    func start()
    func shutdown()
}

protocol CMUXPluginSettingsManaging: AnyObject {
    func reloadDigest(enabled: Bool)
    func reloadGHPRIntegration()
    func settingsContribution(id: String) -> CMUXSettingsContribution?
}

protocol CMUXGHPRContextRefreshProviding: AnyObject {
    func requestGHPRContextRefresh(workspaceId: String)
}

private func runOnMainSync<T>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated { body() }
    }
    return DispatchQueue.main.sync {
        MainActor.assumeIsolated { body() }
    }
}

fileprivate enum CMUXPluginParams {
    static func string(_ params: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            guard let value = params[key], !(value is NSNull) else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}

protocol CMUXLeaderModeOwner: AnyObject {
    @MainActor var isLeaderModeActive: Bool { get set }
}

typealias CMUXTmuxPrefixAction = LeaderKeySettings.LeaderAction

struct CMUXLeaderActionContribution: Equatable {
    let action: CMUXTmuxPrefixAction
    let isConfigurable: Bool

    var id: String { action.rawValue }
    var label: String { action.label }
    var defaultKey: String { action.defaultKey }
}

protocol CMUXLeaderActionContributionRegistration {
    func dispose()
}

private final class CMUXLeaderActionContributionBlockRegistration: CMUXLeaderActionContributionRegistration {
    private let lock = NSLock()
    private var onDispose: (() -> Void)?

    init(_ onDispose: @escaping () -> Void) {
        self.onDispose = onDispose
    }

    func dispose() {
        lock.lock()
        let action = onDispose
        onDispose = nil
        lock.unlock()
        action?()
    }
}

protocol CMUXLeaderActionRegistry: AnyObject {
    func registerLeaderActionContribution(_ contribution: CMUXLeaderActionContribution) -> CMUXLeaderActionContributionRegistration

    @MainActor
    func registerLeaderAction(
        _ action: CMUXTmuxPrefixAction,
        handler: @escaping (NSEvent) -> Bool
    ) -> CMUXPluginDisposable
}

enum CMUXLeaderSecondKeyOutcome {
    case notHandled
    case dispatched
    case passToTerminal
}

final class CMUXTmuxPrefixService: CMUXLeaderActionRegistry {
    typealias KeyMatcher = @MainActor (NSEvent, CMUXTmuxPrefixAction, String) -> Bool
    typealias LeaderShortcutMatcher = @MainActor (NSEvent) -> Bool
    typealias RoutingContextSync = @MainActor (NSEvent) -> Bool
    typealias TimeoutScheduler = @MainActor (_ timeout: TimeInterval, _ workItem: DispatchWorkItem) -> Void

    static let enabledSettingsKey = LeaderKeySettings.enabledKey
    static let enabledDefault = LeaderKeySettings.enabledDefault
    static let timeoutSettingsKey = LeaderKeySettings.timeoutKey
    static let timeoutDefault = LeaderKeySettings.timeoutDefault
    static let timeoutRange = LeaderKeySettings.timeoutRange
    static let workspaceTagsEnabledSettingsKey = LeaderKeySettings.workspaceTagsEnabledKey
    static let workspaceTagsEnabledDefault = LeaderKeySettings.workspaceTagsEnabledDefault
    static let defaultActionContributions: [CMUXLeaderActionContribution] = CMUXTmuxPrefixAction.allCases.map { action in
        CMUXLeaderActionContribution(
            action: action,
            isConfigurable: LeaderKeySettings.configurableActions.contains(action)
        )
    }
    static let actions = defaultActionContributions.map(\.action)
    static let configurableActions = defaultActionContributions.filter(\.isConfigurable).map(\.action)

    private enum LeaderState {
        case inactive
        case waitingForSecondKey
    }

    @MainActor private var state: LeaderState = .inactive
    @MainActor private weak var owner: CMUXLeaderModeOwner?
    @MainActor private var timeoutWorkItem: DispatchWorkItem?
    @MainActor private var disableObserver: NSObjectProtocol?
    @MainActor private var actionHandlers: [CMUXTmuxPrefixAction: (NSEvent) -> Bool] = [:]
    @MainActor private var keyMatcher: KeyMatcher?
    @MainActor private var leaderShortcutMatcher: LeaderShortcutMatcher?
    @MainActor private var routingContextSync: RoutingContextSync?
    @MainActor private var timeoutScheduler: TimeoutScheduler
    private let actionContributionLock = NSLock()
    private var actionContributions: [CMUXTmuxPrefixAction: CMUXLeaderActionContribution] = [:]

    init(timeoutScheduler: @escaping TimeoutScheduler = { timeout, workItem in
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }) {
        self.timeoutScheduler = timeoutScheduler
    }

    func isEnabled() -> Bool {
        LeaderKeySettings.isEnabled
    }

    func timeout() -> Double {
        LeaderKeySettings.timeout
    }

    func workspaceTagsEnabled() -> Bool {
        LeaderKeySettings.workspaceTagsEnabled
    }

    func key(for action: CMUXTmuxPrefixAction) -> String {
        LeaderKeySettings.key(for: action)
    }

    func setKey(_ key: String, for action: CMUXTmuxPrefixAction) {
        LeaderKeySettings.setKey(key, for: action)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledSettingsKey)
    }

    func setTimeout(_ timeout: Double) {
        let clamped = min(max(timeout, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
        UserDefaults.standard.set(clamped, forKey: Self.timeoutSettingsKey)
    }

    func setWorkspaceTagsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.workspaceTagsEnabledSettingsKey)
    }

    func resetSettings() {
        LeaderKeySettings.resetAll()
    }

    @MainActor
    func replaceTimeoutScheduler(_ scheduler: @escaping TimeoutScheduler) -> () -> Void {
        let previous = timeoutScheduler
        timeoutScheduler = scheduler
        return { [weak self] in
            MainActor.assumeIsolated {
                self?.timeoutScheduler = previous
            }
        }
    }

    func statusPayload() -> [String: Any] {
        [
            "enabled": isEnabled(),
            "timeout": timeout(),
            "workspace_tags_enabled": workspaceTagsEnabled(),
            "actions": leaderActionContributions().map { contribution in
                [
                    "id": contribution.id,
                    "label": contribution.label,
                    "key": key(for: contribution.action),
                    "default_key": contribution.defaultKey,
                    "configurable": contribution.isConfigurable,
                ]
            },
        ]
    }

    func registerLeaderActionContribution(_ contribution: CMUXLeaderActionContribution) -> CMUXLeaderActionContributionRegistration {
        actionContributionLock.lock()
        actionContributions[contribution.action] = contribution
        actionContributionLock.unlock()

        return CMUXLeaderActionContributionBlockRegistration { [weak self] in
            guard let self else { return }
            self.actionContributionLock.lock()
            if self.actionContributions[contribution.action] == contribution {
                self.actionContributions.removeValue(forKey: contribution.action)
            }
            self.actionContributionLock.unlock()
        }
    }

    func registerBuiltInLeaderActionContributions() -> CMUXLeaderActionContributionRegistration {
        let registrations = Self.defaultActionContributions.map { registerLeaderActionContribution($0) }
        return CMUXLeaderActionContributionBlockRegistration {
            registrations.forEach { $0.dispose() }
        }
    }

    func registeredLeaderActionContributions() -> [CMUXLeaderActionContribution] {
        actionContributionLock.lock()
        let contributions = Array(actionContributions.values)
        actionContributionLock.unlock()
        return Self.sortActionContributions(contributions)
    }

    func leaderActionContributions() -> [CMUXLeaderActionContribution] {
        let registered = registeredLeaderActionContributions()
        return registered.isEmpty ? Self.defaultActionContributions : registered
    }

    func configurableLeaderActions() -> [CMUXTmuxPrefixAction] {
        leaderActionContributions()
            .filter(\.isConfigurable)
            .map(\.action)
    }

    @MainActor
    func configure(
        keyMatcher: @escaping KeyMatcher,
        leaderShortcutMatcher: @escaping LeaderShortcutMatcher,
        routingContextSync: @escaping RoutingContextSync
    ) {
        self.keyMatcher = keyMatcher
        self.leaderShortcutMatcher = leaderShortcutMatcher
        self.routingContextSync = routingContextSync
        installDisableObserverIfNeeded()
    }

    @MainActor
    func registerBuiltInLeaderActions(
        handler: @escaping (CMUXTmuxPrefixAction, NSEvent) -> Bool
    ) -> CMUXPluginDisposable {
        let disposables = Self.actions.map { action in
            registerLeaderAction(action) { event in
                handler(action, event)
            }
        }
        return CMUXBlockDisposable {
            disposables.forEach { $0.dispose() }
        }
    }

    @MainActor
    func registerLeaderAction(
        _ action: CMUXTmuxPrefixAction,
        handler: @escaping (NSEvent) -> Bool
    ) -> CMUXPluginDisposable {
        actionHandlers[action] = handler
        return CMUXBlockDisposable { [weak self] in
            MainActor.assumeIsolated {
                self?.actionHandlers.removeValue(forKey: action)
            }
        }
    }

    @MainActor
    var isArmed: Bool {
        state == .waitingForSecondKey
    }

    @MainActor
    func handleSecondKey(event: NSEvent) -> CMUXLeaderSecondKeyOutcome {
        guard state == .waitingForSecondKey, isEnabled() else { return .notHandled }
        guard let routingContextSync, routingContextSync(event) else {
            cancelLeaderMode()
            return .notHandled
        }
        cancelLeaderMode()

        if leaderShortcutMatcher?(event) == true {
            return .passToTerminal
        }
        if event.keyCode == 53 {
            return .dispatched
        }

        if let keyMatcher {
            for action in leaderActionContributions().map(\.action) {
                let configuredKey = key(for: action)
                if keyMatcher(event, action, configuredKey) {
                    if let handler = actionHandlers[action] {
                        _ = handler(event)
                    }
                    return .dispatched
                }
            }
        }

        NSSound.beep()
        return .dispatched
    }

    @MainActor
    func handleLeaderArm(event: NSEvent, owner: CMUXLeaderModeOwner) -> Bool {
        guard state == .inactive, isEnabled() else { return false }
        guard let routingContextSync, routingContextSync(event) else { return false }
        guard leaderShortcutMatcher?(event) == true else { return false }

        state = .waitingForSecondKey
        self.owner = owner
        owner.isLeaderModeActive = true
        startTimeout()
        return true
    }

    @MainActor
    func cancelLeaderMode() {
        state = .inactive
        owner?.isLeaderModeActive = false
        owner = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }

    @MainActor
    private func startTimeout() {
        timeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.cancelLeaderMode()
            }
        }
        timeoutWorkItem = workItem
        timeoutScheduler(timeout(), workItem)
    }

    @MainActor
    private func installDisableObserverIfNeeded() {
        guard disableObserver == nil else { return }
        disableObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state != .inactive else { return }
                if !self.isEnabled() {
                    self.cancelLeaderMode()
                }
            }
        }
    }

    private static func sortActionContributions(_ contributions: [CMUXLeaderActionContribution]) -> [CMUXLeaderActionContribution] {
        contributions.sorted { lhs, rhs in
            let lhsIndex = CMUXTmuxPrefixAction.allCases.firstIndex(of: lhs.action) ?? .max
            let rhsIndex = CMUXTmuxPrefixAction.allCases.firstIndex(of: rhs.action) ?? .max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.id < rhs.id
        }
    }
}

enum CMUXWorkspaceTagSettings {
    static var isEnabledProvider: () -> Bool = {
        LeaderKeySettings.workspaceTagsEnabled
    }

    static func isEnabled() -> Bool {
        isEnabledProvider()
    }
}

struct CMUXGHPRConfiguration: Equatable {
    var enabled: Bool
    var socketPath: String
    var displayItemsText: String
    var jiraBaseURL: String?

    static func load(defaults: UserDefaults = .standard) -> CMUXGHPRConfiguration {
        let socketPath = defaults.string(forKey: CMUXGHPRIntegrationSettings.socketPathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayItemsText = defaults.string(forKey: CMUXGHPRIntegrationSettings.displayItemsKey)
        let jiraBaseURL = defaults.string(forKey: CMUXGHPRIntegrationSettings.jiraBaseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return CMUXGHPRConfiguration(
            enabled: CMUXGHPRService.metadataRefreshEnabled(defaults: defaults),
            socketPath: Self.nonEmpty(socketPath) ?? CMUXGHPRIntegrationSettings.defaultSocketPath,
            displayItemsText: displayItemsText ?? CMUXGHPRIntegrationSettings.defaultDisplayItemsText,
            jiraBaseURL: Self.nonEmpty(jiraBaseURL)
        )
    }

    var payload: [String: Any] {
        [
            "enabled": enabled,
            "socket_path": socketPath,
            "display_items": displayItemsText,
            "jira_base_url": jiraBaseURL ?? NSNull(),
        ]
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

struct CMUXGHPRPullRequestReference {
    let repository: String
    let number: Int
}

struct CMUXGHPRPullRequestContext {
    let repository: String
    let number: Int
    let title: String
    let author: String
    let url: String
    let state: String
    let isDraft: Bool
    let isPinned: Bool
    let hasBaseConflicts: Bool
    let unresolvedCount: Int
    let ciStatus: String?
    let checkSuccessCount: Int
    let checkFailureCount: Int
    let checkPendingCount: Int
    let ciIsRunning: Bool
    let approvalCount: Int
    let changesRequestedCount: Int?
    let myReviewStatus: String?
    let jiraTicket: String?
    let jiraURL: String?
    let updatedAt: String
    let mergedAt: String?
    let section: String?
    let source: String

    var payload: [String: Any] {
        var payload: [String: Any] = [
            "repository": repository,
            "number": number,
            "title": title,
            "author": author,
            "url": url,
            "state": state,
            "isDraft": isDraft,
            "isPinned": isPinned,
            "hasBaseConflicts": hasBaseConflicts,
            "unresolvedCount": unresolvedCount,
            "checkSuccessCount": checkSuccessCount,
            "checkFailureCount": checkFailureCount,
            "checkPendingCount": checkPendingCount,
            "ciIsRunning": ciIsRunning,
            "approvalCount": approvalCount,
            "updatedAt": updatedAt,
            "source": source,
        ]
        if let ciStatus { payload["ciStatus"] = ciStatus }
        if let changesRequestedCount { payload["changesRequestedCount"] = changesRequestedCount }
        if let myReviewStatus { payload["myReviewStatus"] = myReviewStatus }
        if let jiraTicket { payload["jiraTicket"] = jiraTicket }
        if let jiraURL { payload["jiraURL"] = jiraURL }
        if let mergedAt { payload["mergedAt"] = mergedAt }
        if let section { payload["section"] = section }
        return payload
    }

    var summaryText: String {
        var parts = [
            "Linked PR \(repository)#\(number) is \(state.lowercased()): \(title)."
        ]
        if let ciStatus {
            parts.append("CI: \(ciStatus).")
        }
        if unresolvedCount > 0 {
            parts.append("\(unresolvedCount) unresolved review thread\(unresolvedCount == 1 ? "" : "s").")
        }
        if let jiraTicket {
            parts.append("Jira: \(jiraTicket).")
        }
        return parts.joined(separator: " ")
    }

    var encodedPayload: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

protocol CMUXGHPRContextProviding: AnyObject {
    func pullRequestContext(workspaceId: String?) throws -> CMUXGHPRPullRequestContext?
}

final class CMUXGHPRService: CMUXGHPRContextProviding {
    private static let refreshDebounceQueue = DispatchQueue(label: "com.cmux.plugin-ghpr.refresh-debounce")
    private static var refreshPending: Set<String> = []
    private static let refreshDebounceInterval: TimeInterval = 1.5

    private let defaults: UserDefaults
    private let logger: CMUXPluginLogger
    private let lock = NSLock()
    private weak var digestService: WorkspaceDigestService?

    init(defaults: UserDefaults = .standard, logger: CMUXPluginLogger) {
        self.defaults = defaults
        self.logger = logger
    }

    func attachDigestService(_ service: WorkspaceDigestService) {
        lock.lock()
        digestService = service
        lock.unlock()
    }

    func configuration() -> CMUXGHPRConfiguration {
        CMUXGHPRConfiguration.load(defaults: defaults)
    }

    func pullRequestContext(workspaceId: String?) throws -> CMUXGHPRPullRequestContext? {
        let configuration = configuration()
        guard configuration.enabled else { return nil }
        guard let reference = pullRequestReference(workspaceId: workspaceId) else { return nil }
        return try CMUXGHPRSocketClient(path: configuration.socketPath).pullRequestContext(
            reference: reference,
            jiraBaseURL: configuration.jiraBaseURL
        )
    }

    func reload() {
        logger.debug("Reloading ghpr plugin integration")
        digestServiceSnapshot()?.restartIfRunning()
    }

    func requestRefresh(workspaceId: String) {
        let trimmedWorkspaceId = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWorkspaceId.isEmpty else { return }

        guard configuration().enabled else {
            logger.debug("ghpr refresh skipped for workspace \(trimmedWorkspaceId): integration disabled")
            return
        }

        let digestService = digestServiceSnapshot()
        digestService?.update(enabled: true)
        logger.debug("ghpr refresh requested for workspace \(trimmedWorkspaceId)")
        Self.refreshDebounceQueue.async { [weak self] in
            guard let self else { return }
            if Self.refreshPending.contains(trimmedWorkspaceId) { return }
            Self.refreshPending.insert(trimmedWorkspaceId)
            Self.refreshDebounceQueue.asyncAfter(deadline: .now() + Self.refreshDebounceInterval) { [weak self] in
                Self.refreshPending.remove(trimmedWorkspaceId)
                self?.digestServiceSnapshot()?.refreshGHPRSidebarMetadata(workspaceId: trimmedWorkspaceId)
            }
        }
    }

    private func digestServiceSnapshot() -> WorkspaceDigestService? {
        lock.lock()
        defer { lock.unlock() }
        return digestService
    }

    private func pullRequestReference(workspaceId: String?) -> CMUXGHPRPullRequestReference? {
        runOnMainSync {
            guard let tabManager = AppDelegate.shared?.tabManager else { return nil }
            let workspace: Workspace?
            if let workspaceId,
               let uuid = UUID(uuidString: workspaceId) {
                workspace = tabManager.tabs.first { $0.id == uuid }
            } else {
                workspace = tabManager.selectedTabId.flatMap { selectedId in
                    tabManager.tabs.first { $0.id == selectedId }
                }
            }
            guard let pullRequest = workspace?.sidebarPullRequestsInDisplayOrder().first,
                  let repository = Self.githubRepositorySlug(fromPullRequestURL: pullRequest.url) else {
                return nil
            }
            return CMUXGHPRPullRequestReference(repository: repository, number: pullRequest.number)
        }
    }

    private static func githubRepositorySlug(fromPullRequestURL url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 4,
              components[2] == "pull",
              Int(components[3]) != nil else {
            return nil
        }
        let owner = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return "\(owner)/\(repo)"
    }

    static func metadataRefreshEnabled(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: CMUXGHPRIntegrationSettings.enabledKey) as? Bool)
            ?? CMUXGHPRIntegrationSettings.defaultEnabled
    }

    static func writesSidebarMetadata(
        digestEnabled: Bool,
        ghprEnabled: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let defaultValue = digestEnabled || ghprEnabled
        guard let storedValue = defaults.object(forKey: "digest.writeSidebarMetadata") as? Bool else {
            return defaultValue
        }
        return storedValue && defaultValue
    }
}

private final class CMUXGHPRSocketClient {
    private let path: String
    private let maxResponseBytes = 4 * 1024 * 1024

    init(path: String) {
        self.path = path
    }

    func pullRequestContext(
        reference: CMUXGHPRPullRequestReference,
        jiraBaseURL: String?
    ) throws -> CMUXGHPRPullRequestContext? {
        let response = try call([
            "command": "pr",
            "repository": reference.repository,
            "number": reference.number,
        ])
        guard (response["schemaVersion"] as? Int) == 1 else {
            throw CMUXSocketCommandError(code: "ghpr_schema", message: "Unsupported ghpr schemaVersion")
        }
        guard (response["ok"] as? Bool) == true else {
            if let error = response["error"] as? [String: Any],
               (error["code"] as? String) == "not_found" {
                return nil
            }
            let message = ((response["error"] as? [String: Any])?["message"] as? String)
                ?? "ghpr socket request failed"
            throw CMUXSocketCommandError(code: "ghpr_failed", message: message)
        }
        guard let raw = response["pullRequest"] as? [String: Any] else {
            return nil
        }
        return CMUXGHPRPullRequestContext(raw: raw, fallback: reference, jiraBaseURL: jiraBaseURL)
    }

    private func call(_ request: [String: Any]) throws -> [String: Any] {
        let fd = try connect()
        defer { Darwin.close(fd) }

        let data = try JSONSerialization.data(withJSONObject: request, options: [])
        var payload = data
        payload.append(0x0A)
        try writeAll(payload, to: fd)
        Darwin.shutdown(fd, SHUT_WR)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw CMUXSocketCommandError(code: "ghpr_read_failed", message: "ghpr socket read failed")
            }
            if count == 0 { break }
            responseData.append(buffer, count: count)
            if responseData.count > maxResponseBytes {
                throw CMUXSocketCommandError(code: "ghpr_response_too_large", message: "ghpr socket response exceeded 4 MiB")
            }
        }
        guard !responseData.isEmpty,
              let response = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] else {
            throw CMUXSocketCommandError(code: "ghpr_invalid_response", message: "ghpr socket returned an invalid response")
        }
        return response
    }

    private func connect() throws -> Int32 {
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw CMUXSocketCommandError(code: "ghpr_socket_not_found", message: "ghpr socket not found")
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            throw CMUXSocketCommandError(code: "ghpr_not_socket", message: "ghpr path is not a socket")
        }
        guard st.st_uid == getuid() else {
            throw CMUXSocketCommandError(code: "ghpr_socket_owner", message: "ghpr socket is not owned by current user")
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CMUXSocketCommandError(code: "ghpr_socket_create", message: "failed to create ghpr socket")
        }

        do {
            try configureTimeouts(fd)

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            guard path.utf8CString.count <= maxLen else {
                throw CMUXSocketCommandError(code: "ghpr_socket_path", message: "ghpr socket path too long")
            }
            path.withCString { src in
                withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                    let dst = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                    strncpy(dst, src, maxLen - 1)
                }
            }

            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw CMUXSocketCommandError(code: "ghpr_connect_failed", message: "failed to connect to ghpr socket")
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func configureTimeouts(_ fd: Int32) throws {
        var timeout = timeval(tv_sec: time_t(2), tv_usec: suseconds_t(0))
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0 else {
            throw CMUXSocketCommandError(code: "ghpr_timeout_failed", message: "failed to configure ghpr socket timeout")
        }
        var nosigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw CMUXSocketCommandError(code: "ghpr_write_failed", message: "ghpr socket write failed")
                }
                if written == 0 {
                    throw CMUXSocketCommandError(code: "ghpr_write_closed", message: "ghpr socket closed during write")
                }
                offset += written
            }
        }
    }
}

private extension CMUXGHPRPullRequestContext {
    init(raw: [String: Any], fallback: CMUXGHPRPullRequestReference, jiraBaseURL: String?) {
        let ticket = Self.string(raw["jiraTicket"])
        self.repository = Self.string(raw["repository"]) ?? fallback.repository
        self.number = Self.int(raw["number"]) ?? fallback.number
        self.title = Self.string(raw["title"]) ?? "Pull Request #\(self.number)"
        self.author = Self.string(raw["author"]) ?? "unknown"
        self.url = Self.string(raw["url"]) ?? ""
        self.state = Self.string(raw["state"]) ?? "UNKNOWN"
        self.isDraft = Self.bool(raw["isDraft"]) ?? false
        self.isPinned = Self.bool(raw["isPinned"]) ?? false
        self.hasBaseConflicts = Self.bool(raw["hasBaseConflicts"]) ?? false
        self.unresolvedCount = Self.int(raw["unresolvedCount"]) ?? 0
        self.ciStatus = Self.string(raw["ciStatus"])
        self.checkSuccessCount = Self.int(raw["checkSuccessCount"]) ?? 0
        self.checkFailureCount = Self.int(raw["checkFailureCount"]) ?? 0
        self.checkPendingCount = Self.int(raw["checkPendingCount"]) ?? 0
        self.ciIsRunning = Self.bool(raw["ciIsRunning"]) ?? false
        self.approvalCount = Self.int(raw["approvalCount"]) ?? 0
        self.changesRequestedCount = Self.int(raw["changesRequestedCount"])
        self.myReviewStatus = Self.string(raw["myReviewStatus"])
        self.jiraTicket = ticket
        self.jiraURL = Self.jiraURL(ticket: ticket, baseURL: jiraBaseURL)
        self.updatedAt = Self.string(raw["updatedAt"]) ?? ""
        self.mergedAt = Self.string(raw["mergedAt"])
        self.section = Self.string(raw["section"])
        self.source = "@cmux/plugin-ghpr"
    }

    private static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        CMUXPluginParams.bool(value)
    }

    private static func jiraURL(ticket: String?, baseURL: String?) -> String? {
        guard let ticket,
              let rawBase = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawBase.isEmpty else {
            return nil
        }
        let encodedTicket = ticket.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ticket
        if rawBase.contains("{ticket}") {
            return rawBase.replacingOccurrences(of: "{ticket}", with: encodedTicket)
        }
        let trimmedBase = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBase.isEmpty else { return nil }
        if trimmedBase.hasSuffix("/browse") {
            return "\(trimmedBase)/\(encodedTicket)"
        }
        return "\(trimmedBase)/browse/\(encodedTicket)"
    }
}

final class CMUXPluginSystem {
    static let shared = CMUXPluginSystem()

    let digestService: WorkspaceDigestService
    let ghprService: CMUXGHPRService
    let events: CMUXAppEventRegistry
    let prompt: CMUXAppPromptRegistry
    let context: CMUXAppContextRegistry
    let commands: CMUXAppCommandRegistry
    let sidebarExtensions: CMUXAppSidebarExtensionRegistry
    let settings: CMUXAppSettingsRegistry
    let storage: CMUXAppPluginStorage
    let workspace: CMUXAppWorkspaceAPI
    let logger: CMUXAppPluginLogger
    private let tmuxPrefixService: CMUXTmuxPrefixService

    private let host: CMUXPluginHost
    private let lock = NSLock()
    private var started = false
    private var plugins: [CMUXPlugin] = []

    private init(tmuxPrefixService: CMUXTmuxPrefixService = CMUXEnhancementSystem.shared.tmuxPrefix) {
        let logger = CMUXAppPluginLogger()
        let ghprService = CMUXGHPRService(logger: logger)
        let digestRuntime = DigestPluginRuntime(ghprConfigurationProvider: {
            ghprService.configuration()
        })
        let digestService = WorkspaceDigestService(runtime: digestRuntime)
        ghprService.attachDigestService(digestService)
        let events = CMUXAppEventRegistry()
        let prompt = CMUXAppPromptRegistry()
        let context = CMUXAppContextRegistry(logger: logger)
        let commands = CMUXAppCommandRegistry()
        let sidebarExtensions = CMUXAppSidebarExtensionRegistry()
        let settings = CMUXAppSettingsRegistry()
        let storage = CMUXAppPluginStorage(pluginDirectoryOverrides: [
            CMUXBuiltinPluginID.digest: DigestPluginRuntime.defaultHomeDirectory()
        ])
        let workspace = CMUXAppWorkspaceAPI()
        let pluginContext = CMUXAppPluginContext(
            logger: logger,
            events: events,
            storage: storage,
            workspace: workspace,
            context: context,
            digest: digestService,
            prompt: prompt,
            commands: commands,
            sidebarExtensions: sidebarExtensions,
            settings: settings
        )

        self.logger = logger
        self.digestService = digestService
        self.ghprService = ghprService
        self.events = events
        self.prompt = prompt
        self.context = context
        self.commands = commands
        self.sidebarExtensions = sidebarExtensions
        self.settings = settings
        self.storage = storage
        self.workspace = workspace
        self.tmuxPrefixService = tmuxPrefixService
        self.host = CMUXPluginHost(context: pluginContext, logger: logger)
    }

    var activatedPluginIds: [String] {
        host.activatedPluginIds
    }

    func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let plugins = CMUXBuiltinPlugins.make(
            tmuxPrefixService: tmuxPrefixService,
            ghprService: ghprService,
            digestService: digestService
        )
        lock.lock()
        self.plugins = plugins
        lock.unlock()

        do {
            try host.activate(plugins)
        } catch {
            lock.lock()
            started = false
            self.plugins = []
            lock.unlock()
            logger.error("Plugin activation failed: \(error.localizedDescription)")
        }
    }

    func activate(trigger: CMUXPluginHost.ActivationTrigger) {
        lock.lock()
        let shouldActivate = started
        let plugins = self.plugins
        lock.unlock()

        guard shouldActivate else { return }
        do {
            try host.activate(plugins, trigger: trigger)
        } catch {
            logger.error("Plugin activation trigger \(trigger.rawValue) failed: \(error.localizedDescription)")
        }
    }

    func shutdown() {
        lock.lock()
        let wasStarted = started
        started = false
        plugins = []
        lock.unlock()

        guard wasStarted else {
            digestService.shutdown()
            return
        }
        host.deactivate()
        digestService.shutdown()
    }

    func reloadDigest(enabled: Bool) {
        digestService.reload(enabled: enabled)
    }

    func restartDigestIfRunning() {
        digestService.restartIfRunning()
    }

    func reloadGHPRIntegration() {
        ghprService.reload()
    }

    func settingsContribution(id: String) -> CMUXSettingsContribution? {
        settings.settingsContribution(id: id)
    }

    func requestGHPRContextRefresh(workspaceId: String) {
        ghprService.requestRefresh(workspaceId: workspaceId)
    }

    func digestSocketPath() -> String {
        digestService.socketPath()
    }

    @discardableResult
    func runCommand(id: String) -> Bool {
        guard let command = commands.command(id: id) else {
            return false
        }
        command.handler()
        return true
    }

    @discardableResult
    func setSidebarExtensionOpen(id: String, open: Bool) -> Bool {
        guard let contribution = sidebarExtensions.sidebarExtension(id: id) else {
            return false
        }
        UserDefaults.standard.set(open, forKey: contribution.openStateKey)
        return true
    }

    @discardableResult
    func toggleSidebarExtension(id: String) -> Bool {
        guard let contribution = sidebarExtensions.sidebarExtension(id: id) else {
            return false
        }
        let current = UserDefaults.standard.object(forKey: contribution.openStateKey) as? Bool
            ?? contribution.defaultOpen
        UserDefaults.standard.set(!current, forKey: contribution.openStateKey)
        return true
    }

}

extension CMUXPluginSystem: CMUXPluginAppProviding, CMUXPluginLifecycleManaging, CMUXPluginSettingsManaging, CMUXGHPRContextRefreshProviding {
    var workspaceDigestService: WorkspaceDigestServicing {
        digestService
    }

    func commandContributions() -> [CMUXCommandContribution] {
        commands.commands()
    }

    func sidebarExtensions(placement: CMUXSidebarExtensionPlacement) -> [CMUXSidebarExtensionContribution] {
        sidebarExtensions.sidebarExtensions().filter { $0.placement == placement }
    }
}

final class CMUXPluginHost {
    enum ActivationTrigger: String {
        case onAppStart
        case onWorkspaceOpen
        case onAgentEvent
    }

    enum HostError: Error, LocalizedError, Equatable {
        case unsupportedPermissions(pluginId: String, permissions: [String])

        var errorDescription: String? {
            switch self {
            case let .unsupportedPermissions(pluginId, permissions):
                return "Plugin \(pluginId) declares unsupported permissions: \(permissions.joined(separator: ","))"
            }
        }
    }

    private static let supportedPermissions: Set<String> = [
        "commands:register",
        "context:contribute",
        "context:read",
        "digest:read",
        "digest:write",
        "events:read",
        "prompt:contribute",
        "settings:contribute",
        "sidebar:contribute",
        "workspace:read",
    ]

    private let context: CMUXPluginContext
    private let logger: CMUXPluginLogger
    private var activatedPlugins: [CMUXPlugin] = []

    init(context: CMUXPluginContext, logger: CMUXPluginLogger) {
        self.context = context
        self.logger = logger
    }

    var activatedPluginIds: [String] {
        activatedPlugins.map(\.manifest.id)
    }

    func activate(
        _ plugins: [CMUXPlugin],
        trigger: ActivationTrigger = .onAppStart
    ) throws {
        var activatedIds = Set(activatedPlugins.map(\.manifest.id))
        for plugin in plugins {
            let manifest = plugin.manifest
            guard shouldActivate(manifest, for: trigger) else {
                logger.debug("Skipping plugin \(manifest.id) for activation trigger \(trigger.rawValue)")
                continue
            }
            guard !activatedIds.contains(manifest.id) else {
                logger.debug("Skipping already-active plugin \(manifest.id)")
                continue
            }
            let unsupportedPermissions = manifest.permissions.filter { !Self.supportedPermissions.contains($0) }
            guard unsupportedPermissions.isEmpty else {
                let error = HostError.unsupportedPermissions(
                    pluginId: manifest.id,
                    permissions: unsupportedPermissions.sorted()
                )
                logger.error(error.localizedDescription)
                deactivate()
                throw error
            }
            logger.info("Activating plugin \(manifest.id)")
            if !manifest.permissions.isEmpty {
                logger.debug("Plugin \(manifest.id) declares permissions: \(manifest.permissions.joined(separator: ","))")
            }
            do {
                try plugin.activate(context: context)
                activatedPlugins.append(plugin)
                activatedIds.insert(manifest.id)
            } catch {
                logger.error("Plugin \(manifest.id) activation failed: \(error.localizedDescription)")
                deactivate()
                throw error
            }
        }
    }

    func deactivate() {
        let plugins = activatedPlugins.reversed()
        activatedPlugins.removeAll()
        for plugin in plugins {
            logger.info("Deactivating plugin \(plugin.manifest.id)")
            plugin.deactivate()
        }
    }

    private func shouldActivate(_ manifest: CMUXPluginManifest, for trigger: ActivationTrigger) -> Bool {
        if manifest.activation.isEmpty {
            return trigger == .onAppStart
        }
        return manifest.activation.contains(trigger.rawValue)
    }
}

enum CMUXBuiltinPlugins {
    static func make(
        tmuxPrefixService: CMUXTmuxPrefixService,
        ghprService: CMUXGHPRService,
        digestService: WorkspaceDigestService
    ) -> [CMUXPlugin] {
        [
            CMUXNoopPlugin(),
            CMUXPluginContextBridgePlugin(),
            CMUXTmuxPrefixPlugin(service: tmuxPrefixService),
            CMUXGHPRPlugin(service: ghprService),
            CMUXDigestPlugin(digestService: digestService),
        ]
    }
}

final class CMUXNoopPlugin: CMUXPlugin {
    let manifest = CMUXPluginManifest(
        id: CMUXBuiltinPluginID.noop,
        name: "cmux No-op",
        version: "0.1.0",
        activation: ["onAppStart"],
        permissions: []
    )

    private(set) var isActive = false

    func activate(context: CMUXPluginContext) {
        isActive = true
        context.logger.debug("No-op plugin activated")
    }

    func deactivate() {
        isActive = false
    }
}

private final class CMUXPluginContextBridgePlugin: CMUXPlugin {
    let manifest = CMUXPluginManifest(
        id: CMUXBuiltinPluginID.contextBridge,
        name: "cmux Plugin Context Bridge",
        version: "0.1.0",
        activation: ["onAppStart"],
        permissions: [
            "context:read",
            "commands:register",
        ]
    )

    private var disposables: [CMUXPluginDisposable] = []

    func activate(context: CMUXPluginContext) {
        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.context.collect",
                    title: "Collect Plugin Context",
                    executionContext: .socketWorker
                ) { input in
                    let collectInput = CMUXContextCollectInput(
                        workspaceId: CMUXPluginParams.string(input.params, "workspaceId", "workspace_id"),
                        conversationId: CMUXPluginParams.string(input.params, "conversationId", "conversation_id"),
                        taskId: CMUXPluginParams.string(input.params, "taskId", "task_id")
                    )
                    return .ok([
                        "items": context.context.collect(input: collectInput).map(Self.payload(for:))
                    ])
                }
            )
        )
    }

    func deactivate() {
        disposables.forEach { $0.dispose() }
        disposables.removeAll()
    }

    private static func payload(for item: CMUXContextItem) -> [String: Any] {
        [
            "id": item.id,
            "source": item.source,
            "kind": item.kind,
            "text": item.text,
            "metadata": item.metadata,
            "created_at": item.createdAt ?? NSNull(),
            "updated_at": item.updatedAt ?? NSNull(),
        ]
    }
}

private final class CMUXTmuxPrefixPlugin: CMUXPlugin {
    let manifest = CMUXPluginManifest(
        id: CMUXBuiltinPluginID.tmuxPrefix,
        name: "cmux tmux Prefix",
        version: "0.1.0",
        activation: ["onAppStart"],
        permissions: [
            "commands:register",
            "settings:contribute",
            "workspace:read",
        ]
    )

    private let service: CMUXTmuxPrefixService
    private var disposables: [CMUXPluginDisposable] = []

    init(service: CMUXTmuxPrefixService) {
        self.service = service
    }

    func activate(context: CMUXPluginContext) {
        registerSettings(context: context)
        registerSocketCommands(context: context)
    }

    func deactivate() {
        disposables.forEach { $0.dispose() }
        disposables.removeAll()
    }

    private func registerSocketCommands(context: CMUXPluginContext) {
        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.tmux_prefix.status",
                    title: "tmux Prefix Status",
                    executionContext: .socketWorker
                ) { [service] input in
                    .ok([
                        "protocol_version": input.protocolVersion.rawValue,
                        "tmux_prefix": service.statusPayload(),
                    ])
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.tmux_prefix.set_enabled",
                    title: "Set tmux Prefix Enabled",
                    executionContext: .socketWorker
                ) { [service] input in
                    guard let enabled = CMUXPluginParams.bool(input.params["enabled"]) else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: "plugin.tmux_prefix.set_enabled requires params.enabled"
                        )
                    }
                    service.setEnabled(enabled)
                    return .ok(["enabled": service.isEnabled()])
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.tmux_prefix.set_timeout",
                    title: "Set tmux Prefix Timeout",
                    executionContext: .socketWorker
                ) { [service] input in
                    guard let timeout = Self.double(input.params["timeout"]) else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: "plugin.tmux_prefix.set_timeout requires params.timeout"
                        )
                    }
                    service.setTimeout(timeout)
                    return .ok(["timeout": service.timeout()])
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.tmux_prefix.set_workspace_tags_enabled",
                    title: "Set tmux Prefix Workspace Tags Enabled",
                    executionContext: .socketWorker
                ) { [service] input in
                    guard let enabled = CMUXPluginParams.bool(input.params["enabled"]) else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: "plugin.tmux_prefix.set_workspace_tags_enabled requires params.enabled"
                        )
                    }
                    service.setWorkspaceTagsEnabled(enabled)
                    return .ok(["workspace_tags_enabled": service.workspaceTagsEnabled()])
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.tmux_prefix.reset",
                    title: "Reset tmux Prefix Settings",
                    executionContext: .socketWorker
                ) { [service] _ in
                    service.resetSettings()
                    return .ok(["tmux_prefix": service.statusPayload()])
                }
            )
        )
    }

    private func registerSettings(context: CMUXPluginContext) {
        disposables.append(
            context.settings.registerSettingsContribution(
                CMUXSettingsContribution(
                    id: CMUXBuiltinSettingsContributionID.tmuxPrefix,
                    target: SettingsNavigationTarget.keyboardShortcuts.rawValue,
                    title: String(localized: "settings.section.tmuxPrefix", defaultValue: "tmux Prefix"),
                    subtitle: String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts"),
                    symbolName: "keyboard",
                    searchText: "leader key tmux prefix ctrl-b control-b workspace tags",
                    anchorID: SettingsSearchIndex.settingID(for: .keyboardShortcuts, idSuffix: "tmux-prefix")
                )
            )
        )
    }

    private static func double(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let double = value as? Double {
            return double
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

enum CMUXSummaryPrioritySidebarExtension {
    static func registerPaletteCommands(
        context: CMUXPluginContext,
        disposables: inout [CMUXPluginDisposable]
    ) {
        disposables.append(
            context.commands.registerCommand(
                CMUXCommandContribution(
                    id: CMUXBuiltinPluginCommandID.toggleSummaryPriority,
                    title: String(
                        localized: "extensionColumn.plugin.summaryPriority.title",
                        defaultValue: "Summary Priority"
                    ),
                    subtitle: String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout"),
                    keywords: ["digest", "summary", "priority", "sidebar", "toggle", "workspace"]
                ) { [sidebarExtensions = context.sidebarExtensions] in
                    guard Self.toggleSidebarExtension(
                        id: CMUXBuiltinSidebarExtensionID.summaryPriority,
                        sidebarExtensions: sidebarExtensions
                    ) != nil else {
                        NSSound.beep()
                        return
                    }
                }
            )
        )
    }

    static func registerSocketCommands(
        context: CMUXPluginContext,
        disposables: inout [CMUXPluginDisposable]
    ) {
        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.sidebar_extension.list",
                    title: "List Sidebar Extensions"
                ) { [sidebarExtensions = context.sidebarExtensions] _ in
                    .ok([
                        "extensions": sidebarExtensions.sidebarExtensions().map(Self.payload(for:))
                    ])
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.sidebar_extension.toggle",
                    title: "Toggle Sidebar Extension"
                ) { [sidebarExtensions = context.sidebarExtensions] input in
                    let id = CMUXPluginParams.string(input.params, "id")
                        ?? CMUXBuiltinSidebarExtensionID.summaryPriority
                    guard let contribution = Self.toggleSidebarExtension(id: id, sidebarExtensions: sidebarExtensions) else {
                        throw CMUXSocketCommandError(
                            code: "not_found",
                            message: "Sidebar extension not found"
                        )
                    }
                    return .ok([
                        "id": id,
                        "open": Self.isOpen(contribution),
                    ])
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.sidebar_extension.set_open",
                    title: "Set Sidebar Extension Open State"
                ) { [sidebarExtensions = context.sidebarExtensions] input in
                    let id = CMUXPluginParams.string(input.params, "id")
                        ?? CMUXBuiltinSidebarExtensionID.summaryPriority
                    guard let open = CMUXPluginParams.bool(input.params["open"]) else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: "plugin.sidebar_extension.set_open requires params.open"
                        )
                    }
                    guard Self.setSidebarExtensionOpen(id: id, open: open, sidebarExtensions: sidebarExtensions) else {
                        throw CMUXSocketCommandError(
                            code: "not_found",
                            message: "Sidebar extension not found"
                        )
                    }
                    return .ok(["id": id, "open": open])
                }
            )
        )
    }

    @discardableResult
    static func toggleSidebarExtension(
        id: String,
        sidebarExtensions: CMUXSidebarExtensionRegistry
    ) -> CMUXSidebarExtensionContribution? {
        guard let contribution = sidebarExtensions.sidebarExtension(id: id) else {
            return nil
        }
        let current = UserDefaults.standard.object(forKey: contribution.openStateKey) as? Bool
            ?? contribution.defaultOpen
        UserDefaults.standard.set(!current, forKey: contribution.openStateKey)
        return contribution
    }

    @discardableResult
    static func setSidebarExtensionOpen(
        id: String,
        open: Bool,
        sidebarExtensions: CMUXSidebarExtensionRegistry
    ) -> Bool {
        guard let contribution = sidebarExtensions.sidebarExtension(id: id) else {
            return false
        }
        UserDefaults.standard.set(open, forKey: contribution.openStateKey)
        return true
    }

    static func contribution() -> CMUXSidebarExtensionContribution {
        CMUXSidebarExtensionContribution(
            id: CMUXBuiltinSidebarExtensionID.summaryPriority,
            title: String(localized: "extensionColumn.plugin.summaryPriority.title", defaultValue: "Summary Priority"),
            placement: .workspaceSidebarTrailingOverlay,
            openStateKey: ExtensionColumnSettings.openKey,
            defaultOpen: ExtensionColumnSettings.defaultOpen,
            priority: 100,
            metadata: [
                "renderer": "summary-priority",
                "settingsPrefix": "workspaceTab.summaryPriority",
            ]
        )
    }

    private static func payload(for contribution: CMUXSidebarExtensionContribution) -> [String: Any] {
        [
            "id": contribution.id,
            "title": contribution.title,
            "placement": contribution.placement.rawValue,
            "open_state_key": contribution.openStateKey,
            "default_open": contribution.defaultOpen,
            "priority": contribution.priority,
            "open": isOpen(contribution),
            "metadata": contribution.metadata,
        ]
    }

    private static func isOpen(_ contribution: CMUXSidebarExtensionContribution) -> Bool {
        UserDefaults.standard.object(forKey: contribution.openStateKey) as? Bool
            ?? contribution.defaultOpen
    }
}

private final class CMUXGHPRPlugin: CMUXPlugin {
    let manifest = CMUXPluginManifest(
        id: CMUXBuiltinPluginID.ghpr,
        name: "cmux ghpr Context",
        version: "0.1.0",
        activation: ["onAppStart", "onWorkspaceOpen"],
        permissions: [
            "context:contribute",
            "commands:register",
            "settings:contribute",
            "workspace:read",
        ]
    )

    private let service: CMUXGHPRService
    private var disposables: [CMUXPluginDisposable] = []

    init(service: CMUXGHPRService) {
        self.service = service
    }

    func activate(context: CMUXPluginContext) {
        registerSettings(context: context)
        disposables.append(
            context.context.registerCollector(
                CMUXGHPRContextCollector(service: service, logger: context.logger)
            )
        )
        registerSocketCommands(context: context)
    }

    func deactivate() {
        disposables.forEach { $0.dispose() }
        disposables.removeAll()
    }

    private func registerSocketCommands(context: CMUXPluginContext) {
        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.ghpr.status",
                    title: "ghpr Context Status",
                    executionContext: .socketWorker
                ) { [service] _ in
                    .ok(["ghpr": service.configuration().payload])
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.ghpr.refresh",
                    title: "Refresh ghpr Context",
                    executionContext: .socketWorker
                ) { [service, workspace = context.workspace] input in
                    guard let workspaceId = CMUXPluginParams.string(input.params, "workspaceId", "workspace_id")
                        ?? workspace.currentWorkspaceId() else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: "plugin.ghpr.refresh requires workspaceId"
                        )
                    }
                    service.requestRefresh(workspaceId: workspaceId)
                    return .ok(["scheduled": true, "workspace_id": workspaceId])
                }
            )
        )
    }

    private func registerSettings(context: CMUXPluginContext) {
        disposables.append(
            context.settings.registerSettingsContribution(
                CMUXSettingsContribution(
                    id: CMUXBuiltinSettingsContributionID.ghpr,
                    target: SettingsNavigationTarget.enhancements.rawValue,
                    title: String(localized: "settings.section.ghpr", defaultValue: "ghpr"),
                    subtitle: String(localized: "settings.section.enhancements", defaultValue: "Enhancements"),
                    symbolName: "puzzlepiece.extension",
                    searchText: "github pull request pr dashboard socket jira digest context",
                    anchorID: SettingsSearchIndex.settingID(for: .enhancements, idSuffix: "ghpr")
                )
            )
        )
    }
}

final class CMUXGHPRContextCollector: CMUXContextCollector {
    let id = "ghpr.context"
    private let service: CMUXGHPRContextProviding
    private let logger: CMUXPluginLogger?

    init(service: CMUXGHPRContextProviding, logger: CMUXPluginLogger? = nil) {
        self.service = service
        self.logger = logger
    }

    func collect(input: CMUXContextCollectInput) throws -> [CMUXContextItem] {
        let context: CMUXGHPRPullRequestContext?
        do {
            context = try service.pullRequestContext(workspaceId: input.workspaceId)
        } catch {
            logger?.warning(
                "ghpr.context.collect failed workspace=\(input.workspaceId ?? "global"): \(error.localizedDescription)"
            )
            return []
        }
        guard let context,
              let encodedPayload = context.encodedPayload else {
            return []
        }

        return [
            CMUXContextItem(
                id: "ghpr.context.\(input.workspaceId ?? "global")",
                source: "@cmux/plugin-ghpr",
                kind: "pull_request",
                text: context.summaryText,
                metadata: [
                    "pullRequestJSON": encodedPayload,
                    "repository": context.repository,
                    "number": String(context.number),
                    "url": context.url,
                    "state": context.state,
                    "source": context.source,
                ]
            )
        ]
    }
}

final class CMUXDigestPlugin: CMUXPlugin {
    let manifest = CMUXPluginManifest(
        id: CMUXBuiltinPluginID.digest,
        name: "cmux Digest",
        version: "0.1.0",
        activation: ["onAppStart", "onWorkspaceOpen", "onAgentEvent"],
        permissions: [
            "events:read",
            "digest:read",
            "digest:write",
            "prompt:contribute",
            "sidebar:contribute",
            "commands:register",
            "settings:contribute",
            "workspace:read",
        ]
    )

    private let digestService: WorkspaceDigestService
    private var disposables: [CMUXPluginDisposable] = []

    init(digestService: WorkspaceDigestService) {
        self.digestService = digestService
    }

    func activate(context: CMUXPluginContext) {
        registerSettings(context: context)
        do {
            digestService.setHomeDirectory(try context.storage.url(forPluginId: manifest.id))
        } catch {
            context.logger.warning("Digest plugin storage unavailable: \(error.localizedDescription)")
        }
        digestService.update(enabled: UserDefaults.standard.bool(forKey: "digest.enabled"))
        disposables.append(
            context.sidebarExtensions.registerSidebarExtension(
                CMUXSummaryPrioritySidebarExtension.contribution()
            )
        )
        CMUXSummaryPrioritySidebarExtension.registerSocketCommands(
            context: context,
            disposables: &disposables
        )
        CMUXSummaryPrioritySidebarExtension.registerPaletteCommands(
            context: context,
            disposables: &disposables
        )
        registerPaletteCommands(context: context)
        disposables.append(
            context.events.subscribe(
                names: [],
                categories: ["agent", "feed", "workspace"]
            ) { event in
                guard Self.shouldScheduleDigest(for: event) else {
                    return
                }
                guard let workspaceId = event.workspaceId ?? event.payload["workspace_id"] as? String else {
                    return
                }
                context.digest.schedule(
                    CMUXDigestScheduleRequest(
                        scope: CMUXDigestScope(workspaceId: workspaceId),
                        reason: event.name
                    )
                )
            }
        )
        disposables.append(
            context.prompt.registerContributor(CMUXDigestPromptContributor(digest: context.digest))
        )
        registerSocketCommands(context: context)
    }

    func deactivate() {
        disposables.forEach { $0.dispose() }
        disposables.removeAll()
    }

    private func registerPaletteCommands(context: CMUXPluginContext) {
        disposables.append(
            context.commands.registerCommand(
                CMUXCommandContribution(
                    id: CMUXBuiltinPluginCommandID.restartDigest,
                    title: String(localized: "settings.digest.restartDaemon", defaultValue: "Restart Digest Daemon"),
                    subtitle: String(localized: "settings.section.digest", defaultValue: "Workspace Digest"),
                    keywords: ["digest", "restart", "daemon", "summary", "workspace"]
                ) { [digestService] in
                    digestService.restartIfRunning()
                }
            )
        )
    }

    private func registerSocketCommands(context: CMUXPluginContext) {
        let digest = context.digest

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.digest.schedule",
                    title: "Schedule Workspace Digest",
                    executionContext: .socketWorker
                ) { input in
                    let scope = Self.scope(from: input.params)
                    let reason = CMUXPluginParams.string(input.params, "reason") ?? "socket"
                    let force = CMUXPluginParams.bool(input.params["force"]) ?? false
                    digest.schedule(CMUXDigestScheduleRequest(scope: scope, reason: reason, force: force))
                    return .ok(["scheduled": true])
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.digest.get",
                    title: "Get Workspace Digest",
                    executionContext: .socketWorker
                ) { input in
                    let result = try digest.get(scope: Self.scope(from: input.params))
                    return .ok(["digest": Self.payload(forOptional: result)])
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.digest.refresh",
                    title: "Refresh Workspace Digest",
                    executionContext: .socketWorker
                ) { input in
                    let force = CMUXPluginParams.bool(input.params["force"]) ?? false
                    let result = try digest.refresh(scope: Self.scope(from: input.params), force: force)
                    return .ok(["digest": Self.payload(forOptional: result)])
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.digest.progress",
                    title: "Workspace Digest Progress",
                    executionContext: .socketWorker
                ) { _ in
                    let snapshot = try digest.progress()
                    return .ok(Self.payload(for: snapshot))
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.digest.set_override",
                    title: "Set Workspace Digest Override",
                    executionContext: .socketWorker
                ) { input in
                    let scope = Self.scope(from: input.params)
                    guard let workspaceId = scope.workspaceId, !workspaceId.isEmpty else {
                        throw CMUXSocketCommandError(
                            code: "invalid_params",
                            message: "plugin.digest.set_override requires workspaceId"
                        )
                    }
                    let values = Self.overrideValues(from: input.params)
                    try digest.setOverride(scope: CMUXDigestScope(workspaceId: workspaceId), values: values)
                    return .ok(["updated": true])
                }
            )
        )

        disposables.append(
            context.commands.registerSocketCommand(
                CMUXSocketCommandContribution(
                    id: "plugin.digest.restart",
                    title: "Restart Workspace Digest",
                    executionContext: .socketWorker
                ) { [digestService] input in
                    let enabled = CMUXPluginParams.bool(input.params["enabled"]) ?? UserDefaults.standard.bool(forKey: "digest.enabled")
                    digestService.reload(enabled: enabled)
                    return .ok(["restarted": enabled])
                }
            )
        )
    }

    private func registerSettings(context: CMUXPluginContext) {
        disposables.append(
            context.settings.registerSettingsContribution(
                CMUXSettingsContribution(
                    id: CMUXBuiltinSettingsContributionID.digest,
                    target: SettingsNavigationTarget.enhancements.rawValue,
                    title: String(localized: "settings.section.digest", defaultValue: "Workspace Digest"),
                    subtitle: String(localized: "settings.section.enhancements", defaultValue: "Enhancements"),
                    symbolName: "puzzlepiece.extension",
                    searchText: "workspace digest summary priority sidebar radar model provider claude code codex",
                    anchorID: SettingsSearchIndex.settingID(for: .enhancements, idSuffix: "workspace-digest")
                )
            )
        )
    }

    static func shouldScheduleDigest(for event: CMUXPluginEvent) -> Bool {
        event.name.hasPrefix("agent.hook.")
            || event.name.hasPrefix("feed.item.")
            || event.name.hasPrefix("workspace.")
    }

    private static func scope(from params: [String: Any]) -> CMUXDigestScope {
        CMUXDigestScope(
            workspaceId: CMUXPluginParams.string(params, "workspaceId", "workspace_id"),
            conversationId: CMUXPluginParams.string(params, "conversationId", "conversation_id"),
            taskId: CMUXPluginParams.string(params, "taskId", "task_id")
        )
    }

    private static func overrideValues(from params: [String: Any]) -> [String: Any] {
        if let values = params["values"] as? [String: Any] {
            return values
        }
        if let values = params["patch"] as? [String: Any] {
            return values
        }
        let scopeKeys: Set<String> = [
            "workspaceId",
            "workspace_id",
            "conversationId",
            "conversation_id",
            "taskId",
            "task_id",
        ]
        return params.filter { !scopeKeys.contains($0.key) }
    }

    private static func payload(for result: CMUXDigestResult) -> [String: Any] {
        [
            "id": result.id,
            "scope": payload(for: result.scope),
            "text": result.text,
            "summary": result.summary ?? NSNull(),
            "status": result.status ?? NSNull(),
            "next_actions": result.nextActions,
            "items_used": result.itemsUsed,
            "created_at": result.createdAt,
            "metadata": result.metadata,
        ]
    }

    private static func payload(forOptional result: CMUXDigestResult?) -> Any {
        guard let result else { return NSNull() }
        return payload(for: result)
    }

    private static func payload(for scope: CMUXDigestScope) -> [String: Any] {
        [
            "workspace_id": scope.workspaceId ?? NSNull(),
            "conversation_id": scope.conversationId ?? NSNull(),
            "task_id": scope.taskId ?? NSNull(),
        ]
    }

    private static func payload(for snapshot: CMUXDigestProgressSnapshot) -> [String: Any] {
        [
            "generated_at": snapshot.generatedAt ?? NSNull(),
            "summary_stage": snapshot.summaryStage ?? NSNull(),
            "workspace_stages": snapshot.workspaceStages,
        ]
    }

}

private final class CMUXDigestPromptContributor: CMUXPromptContributor {
    let id = "digest.promptContext"
    private let digest: CMUXDigestRegistry

    init(digest: CMUXDigestRegistry) {
        self.digest = digest
    }

    func contribute(input: CMUXPromptContextInput) throws -> [CMUXPromptContribution] {
        let result = try digest.get(
            scope: CMUXDigestScope(
                workspaceId: input.workspaceId,
                conversationId: input.conversationId,
                taskId: input.taskId
            )
        )
        guard let result else { return [] }

        var lines = ["Workspace digest:", result.text]
        if let summary = result.summary, summary != result.text {
            lines.append(summary)
        }
        if !result.nextActions.isEmpty {
            lines.append("Next actions: " + result.nextActions.joined(separator: "; "))
        }
        return [
            CMUXPromptContribution(
                id: "digest.promptContext.\(result.id)",
                source: "@cmux/plugin-digest",
                role: "system",
                priority: 80,
                content: lines.joined(separator: "\n"),
                tokenEstimate: nil
            )
        ]
    }
}

final class CMUXAppPluginContext: CMUXPluginContext {
    let logger: CMUXPluginLogger
    let events: CMUXEventRegistry
    let storage: CMUXPluginStorage
    let workspace: CMUXWorkspaceAPI
    let context: CMUXContextRegistry
    let digest: CMUXDigestRegistry
    let prompt: CMUXPromptRegistry
    let commands: CMUXCommandRegistry
    let sidebarExtensions: CMUXSidebarExtensionRegistry
    let settings: CMUXSettingsRegistry

    init(
        logger: CMUXPluginLogger,
        events: CMUXEventRegistry,
        storage: CMUXPluginStorage,
        workspace: CMUXWorkspaceAPI,
        context: CMUXContextRegistry,
        digest: CMUXDigestRegistry,
        prompt: CMUXPromptRegistry,
        commands: CMUXCommandRegistry,
        sidebarExtensions: CMUXSidebarExtensionRegistry,
        settings: CMUXSettingsRegistry
    ) {
        self.logger = logger
        self.events = events
        self.storage = storage
        self.workspace = workspace
        self.context = context
        self.digest = digest
        self.prompt = prompt
        self.commands = commands
        self.sidebarExtensions = sidebarExtensions
        self.settings = settings
    }
}

final class CMUXAppPluginLogger: CMUXPluginLogger {
    func debug(_ message: String) {
#if DEBUG
        cmuxDebugLog("plugin.debug \(message)")
#endif
    }

    func info(_ message: String) {
#if DEBUG
        cmuxDebugLog("plugin.info \(message)")
#else
        NSLog("cmux plugin: %@", message)
#endif
    }

    func warning(_ message: String) {
        NSLog("cmux plugin warning: %@", message)
    }

    func error(_ message: String) {
        NSLog("cmux plugin error: %@", message)
    }
}

final class CMUXAppEventRegistry: CMUXEventRegistry {
    private let bus: CmuxEventBus
    private let queue: DispatchQueue

    init(
        bus: CmuxEventBus = .shared,
        queue: DispatchQueue = DispatchQueue(
            label: "com.cmux.plugin-events",
            qos: .utility,
            attributes: .concurrent
        )
    ) {
        self.bus = bus
        self.queue = queue
    }

    @discardableResult
    func subscribe(
        names: Set<String>,
        categories: Set<String>,
        handler: @escaping (CMUXPluginEvent) -> Void
    ) -> CMUXPluginDisposable {
        let snapshot = bus.subscribe(afterSequence: nil, names: names, categories: categories)
        let disposable = CMUXEventRegistrySubscription(bus: bus, subscription: snapshot.subscription)
        // dispose() unsubscribes which close()s the subscription and signals its semaphore,
        // so a long timeout here is safe — we don't need a 1Hz wakeup to detect disposal.
        queue.async { [weak disposable] in
            while disposable?.isDisposed == false {
                guard let event = snapshot.subscription.next(timeout: 3600) else { continue }
                handler(Self.pluginEvent(from: event))
            }
        }
        return disposable
    }

    private static func pluginEvent(from event: [String: Any]) -> CMUXPluginEvent {
        let payload = event["payload"] as? [String: Any] ?? [:]
        return CMUXPluginEvent(
            name: string(event["name"]) ?? "",
            category: string(event["category"]) ?? "",
            source: string(event["source"]) ?? "",
            workspaceId: string(event["workspace_id"]),
            surfaceId: string(event["surface_id"]),
            paneId: string(event["pane_id"]),
            windowId: string(event["window_id"]),
            sequence: CmuxEventBus.int64(event["seq"]),
            payload: payload,
            raw: event
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? String
    }
}

private final class CMUXEventRegistrySubscription: CMUXPluginDisposable {
    private let lock = NSLock()
    private let bus: CmuxEventBus
    private let subscription: CmuxEventSubscription
    private var disposed = false

    init(bus: CmuxEventBus, subscription: CmuxEventSubscription) {
        self.bus = bus
        self.subscription = subscription
    }

    var isDisposed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return disposed
    }

    func dispose() {
        lock.lock()
        guard !disposed else {
            lock.unlock()
            return
        }
        disposed = true
        lock.unlock()
        bus.unsubscribe(subscription)
    }
}

private final class IdentifiedStore<Value> {
    private let lock = NSLock()
    private var items: [String: Value] = [:]

    @discardableResult
    func register(id: String, _ value: Value) -> CMUXPluginDisposable {
        lock.lock()
        items[id] = value
        lock.unlock()
        return CMUXBlockDisposable { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.items.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    func get(_ id: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return items[id]
    }

    func values() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return Array(items.values)
    }
}

final class CMUXAppContextRegistry: CMUXContextRegistry {
    private let logger: CMUXPluginLogger
    private let store = IdentifiedStore<CMUXContextCollector>()

    init(logger: CMUXPluginLogger) {
        self.logger = logger
    }

    @discardableResult
    func registerCollector(_ collector: CMUXContextCollector) -> CMUXPluginDisposable {
        store.register(id: collector.id, collector)
    }

    func collect(input: CMUXContextCollectInput) -> [CMUXContextItem] {
        store.values().flatMap { collector in
            do {
                return try collector.collect(input: input)
            } catch {
                logger.warning("Context collector \(collector.id) failed: \(error.localizedDescription)")
                return []
            }
        }
    }
}

final class CMUXAppPromptRegistry: CMUXPromptRegistry {
    private let store = IdentifiedStore<CMUXPromptContributor>()

    @discardableResult
    func registerContributor(_ contributor: CMUXPromptContributor) -> CMUXPluginDisposable {
        store.register(id: contributor.id, contributor)
    }

    func collect(input: CMUXPromptContextInput) -> [CMUXPromptContribution] {
        store.values().flatMap { contributor in
            (try? contributor.contribute(input: input)) ?? []
        }.sorted {
            if $0.priority != $1.priority {
                return $0.priority > $1.priority
            }
            return $0.id < $1.id
        }
    }
}

final class CMUXAppCommandRegistry: CMUXCommandRegistry {
    private let commandStore = IdentifiedStore<CMUXCommandContribution>()
    private let socketCommandStore = IdentifiedStore<CMUXSocketCommandContribution>()

    @discardableResult
    func registerCommand(_ command: CMUXCommandContribution) -> CMUXPluginDisposable {
        commandStore.register(id: command.id, command)
    }

    func command(id: String) -> CMUXCommandContribution? {
        commandStore.get(id)
    }

    func commands() -> [CMUXCommandContribution] {
        commandStore.values().sorted { $0.id < $1.id }
    }

    @discardableResult
    func registerSocketCommand(_ command: CMUXSocketCommandContribution) -> CMUXPluginDisposable {
        socketCommandStore.register(id: command.id, command)
    }

    func socketCommand(id: String) -> CMUXSocketCommandContribution? {
        socketCommandStore.get(id)
    }

    func socketCommands() -> [CMUXSocketCommandContribution] {
        socketCommandStore.values().sorted { $0.id < $1.id }
    }
}

final class CMUXAppSidebarExtensionRegistry: CMUXSidebarExtensionRegistry {
    private let store = IdentifiedStore<CMUXSidebarExtensionContribution>()

    @discardableResult
    func registerSidebarExtension(_ extensionContribution: CMUXSidebarExtensionContribution) -> CMUXPluginDisposable {
        store.register(id: extensionContribution.id, extensionContribution)
    }

    func sidebarExtension(id: String) -> CMUXSidebarExtensionContribution? {
        store.get(id)
    }

    func sidebarExtensions() -> [CMUXSidebarExtensionContribution] {
        store.values().sorted {
            if $0.priority != $1.priority {
                return $0.priority > $1.priority
            }
            return $0.id < $1.id
        }
    }
}

final class CMUXAppSettingsRegistry: CMUXSettingsRegistry {
    private let store = IdentifiedStore<CMUXSettingsContribution>()

    @discardableResult
    func registerSettingsContribution(_ contribution: CMUXSettingsContribution) -> CMUXPluginDisposable {
        store.register(id: contribution.id, contribution)
    }

    func settingsContribution(id: String) -> CMUXSettingsContribution? {
        store.get(id)
    }

    func settingsContributions() -> [CMUXSettingsContribution] {
        store.values().sorted { $0.id < $1.id }
    }
}

final class CMUXAppPluginStorage: CMUXPluginStorage {
    private let lock = NSLock()
    private var cache: [String: URL] = [:]
    private let applicationSupportDirectory: URL?
    private let pluginDirectoryOverrides: [String: URL]

    init(
        applicationSupportDirectory: URL? = nil,
        pluginDirectoryOverrides: [String: URL] = [:]
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.pluginDirectoryOverrides = pluginDirectoryOverrides
    }

    func url(forPluginId pluginId: String) throws -> URL {
        lock.lock()
        if let cached = cache[pluginId] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let fm = FileManager.default
        let url: URL
        if let overrideURL = pluginDirectoryOverrides[pluginId] {
            url = overrideURL
        } else {
            let safeName = pluginId.map { ch in
                ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? String(ch) : "_"
            }.joined()
            guard let appSupport = applicationSupportDirectory
                ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            url = appSupport
                .appendingPathComponent("cmux/plugins", isDirectory: true)
                .appendingPathComponent(safeName, isDirectory: true)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)

        lock.lock()
        cache[pluginId] = url
        lock.unlock()
        return url
    }
}

final class CMUXAppWorkspaceAPI: CMUXWorkspaceAPI {
    func currentWorkspaceId() -> String? {
        runOnMainSync {
            AppDelegate.shared?.tabManager?.selectedTabId?.uuidString
        }
    }
}

protocol WorkspaceDigestRuntime: AnyObject {
    func setHomeDirectory(_ url: URL?)
    func update(enabled: Bool)
    func reload(enabled: Bool)
    func restartIfRunning()
    func shutdown()
    func socketPath() -> String
}

final class WorkspaceDigestService: WorkspaceDigestServicing, CMUXDigestRegistry {
    private static let socketQueue = DispatchQueue(
        label: "com.cmux.plugin-digest.socket-client",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let progressSocketQueue = DispatchQueue(label: "com.cmux.plugin-digest.progress-client", qos: .utility)
    private static let scheduleQueue = DispatchQueue(label: "com.cmux.plugin-digest.schedule", qos: .utility)
    private static let digestSocketTimeoutSeconds: TimeInterval = 420
    private static let digestProgressSocketTimeoutSeconds: TimeInterval = 5
    private static let digestSocketStartupWaitSeconds: TimeInterval = 2

    private let runtime: WorkspaceDigestRuntime
    private let decoder = JSONDecoder()
    private struct ScheduledRefresh {
        let token: UUID
        let workItem: DispatchWorkItem
    }
    private let scheduleLock = NSLock()
    private var scheduledRefreshes: [String: ScheduledRefresh] = [:]

    init(runtime: WorkspaceDigestRuntime) {
        self.runtime = runtime
    }

    func setHomeDirectory(_ url: URL?) {
        runtime.setHomeDirectory(url)
    }

    func update(enabled: Bool) {
        if !enabled {
            cancelScheduledRefreshes()
        }
        runtime.update(enabled: enabled)
    }

    func reload(enabled: Bool) {
        if !enabled {
            cancelScheduledRefreshes()
        }
        runtime.reload(enabled: enabled)
    }

    func restartIfRunning() {
        runtime.restartIfRunning()
    }

    func shutdown() {
        cancelScheduledRefreshes()
        runtime.shutdown()
    }

    func socketPath() -> String {
        runtime.socketPath()
    }

    func refreshSummaryPriority(
        force: Bool,
        sort: WorkspaceSidebarSummaryPrioritySort,
        assistantContext: WorkspaceSidebarAssistantContext?,
        completion: @escaping (Result<WorkspaceSidebarSummaryPriorityState, Error>) -> Void
    ) {
        var payload: [String: Any] = [
            "force": force,
            "sort": sort.requestPayload,
        ]
        if let assistantContext {
            payload["assistantContext"] = assistantContext.requestPayload
        }
        sendDigestCommand(
            "refresh_summary_priority",
            payload: payload,
            decoding: WorkspaceSidebarSummaryPriorityState.self,
            completion: completion
        )
    }

    func setDisplayMode(_ mode: WorkspaceSidebarDisplayMode, completion: @escaping (Result<Void, Error>) -> Void) {
        sendDigestCommand("set_workspace_tab_mode", payload: ["displayMode": mode.rawValue], completion: completion)
    }

    func refreshWorkspace(
        workspaceId: String,
        force: Bool,
        refinement: String?,
        sort: WorkspaceSidebarSummaryPrioritySort,
        completion: @escaping (Result<WorkspaceSidebarSummaryPriorityItem, Error>) -> Void
    ) {
        var payload: [String: Any] = [
            "workspaceId": workspaceId,
            "force": force,
            "sort": sort.requestPayload,
        ]
        if let refinement {
            payload["refinement"] = refinement
        }
        sendDigestCommand(
            "refresh_summary_priority_workspace",
            payload: payload,
            decoding: WorkspaceSidebarSummaryPriorityItem.self,
            completion: completion
        )
    }

    func scoreWorkspace(
        workspaceId: String,
        sort: WorkspaceSidebarSummaryPrioritySort,
        completion: @escaping (Result<WorkspaceSidebarSummaryPriorityItem, Error>) -> Void
    ) {
        sendDigestCommand(
            "score_summary_priority_workspace",
            payload: ["workspaceId": workspaceId, "sort": sort.requestPayload],
            decoding: WorkspaceSidebarSummaryPriorityItem.self,
            completion: completion
        )
    }

    func setOverride(
        workspaceId: String,
        patch: [String: Any],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var payload = patch
        payload["workspaceId"] = workspaceId
        sendDigestCommand("set_summary_priority_override", payload: payload, completion: completion)
    }

    func progress(completion: @escaping (Result<WorkspaceSidebarDigestProgressState, Error>) -> Void) {
        sendDigestCommand(
            "digest_progress",
            payload: [:],
            queue: Self.progressSocketQueue,
            timeoutSeconds: Self.digestProgressSocketTimeoutSeconds,
            decoding: WorkspaceSidebarDigestProgressState.self,
            completion: completion
        )
    }

    func refreshGHPRSidebarMetadata(workspaceId: String) {
        let trimmedWorkspaceId = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWorkspaceId.isEmpty else { return }
        // Lightweight sidebar badge write path; cmux-digest gets ghpr data through plugin.context.collect.
        sendDigestCommandRaw(
            "refresh_ghpr_metadata",
            payload: ["workspaceId": trimmedWorkspaceId],
            queue: Self.progressSocketQueue,
            timeoutSeconds: Self.digestProgressSocketTimeoutSeconds
        ) { result in
            switch result {
            case .success(let response):
#if DEBUG
                cmuxDebugLog(
                    "plugin.ghpr.digest_refresh.response workspace=\(trimmedWorkspaceId) response=\(Self.debugResponseSummary(response))"
                )
#else
                _ = response
#endif
            case .failure(let error):
                NSLog(
                    "cmux plugin warning: ghpr sidebar metadata refresh failed workspace=%@ error=%@",
                    trimmedWorkspaceId,
                    error.localizedDescription
                )
#if DEBUG
                cmuxDebugLog(
                    "plugin.ghpr.digest_refresh.failed workspace=\(trimmedWorkspaceId) error=\(error.localizedDescription)"
                )
#endif
            }
        }
    }

    func schedule(_ request: CMUXDigestScheduleRequest) {
        guard UserDefaults.standard.bool(forKey: "digest.enabled") else { return }
        guard let workspaceId = request.scope.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspaceId.isEmpty else { return }
        let key = workspaceId
        let token = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduleLock.lock()
            let isCurrent = self.scheduledRefreshes[key]?.token == token
            if isCurrent {
                self.scheduledRefreshes.removeValue(forKey: key)
            }
            self.scheduleLock.unlock()

            guard isCurrent else { return }
            guard UserDefaults.standard.bool(forKey: "digest.enabled") else {
                return
            }
            _ = try? self.refresh(scope: request.scope, force: request.force)
        }
        scheduleLock.lock()
        scheduledRefreshes[key]?.workItem.cancel()
        scheduledRefreshes[key] = ScheduledRefresh(token: token, workItem: workItem)
        scheduleLock.unlock()
        Self.scheduleQueue.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func cancelScheduledRefreshes() {
        scheduleLock.lock()
        let pending = scheduledRefreshes.values.map(\.workItem)
        scheduledRefreshes.removeAll()
        scheduleLock.unlock()

        for workItem in pending {
            workItem.cancel()
        }
    }

    func get(scope: CMUXDigestScope) throws -> CMUXDigestResult? {
        guard let workspaceId = scope.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspaceId.isEmpty else { return nil }
        do {
            let digest = try sendDigestCommandSync(
                "show_digest",
                payload: ["workspaceId": workspaceId],
                decoding: DigestWorkspaceResult.self
            )
            return digest.pluginResult(scope: scope)
        } catch {
            if (error as? CmuxSocketError)?.message.contains("digest not found") == true {
                return nil
            }
            throw error
        }
    }

    func refresh(scope: CMUXDigestScope, force: Bool) throws -> CMUXDigestResult? {
        guard let workspaceId = scope.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspaceId.isEmpty else { return nil }
        let digest = try sendDigestCommandSync(
            "refresh_digest",
            payload: ["workspaceId": workspaceId, "force": force],
            decoding: DigestWorkspaceResult.self
        )
        return digest.pluginResult(scope: scope)
    }

    func progress() throws -> CMUXDigestProgressSnapshot {
        let state = try sendDigestCommandSync(
            "digest_progress",
            payload: [:],
            timeoutSeconds: Self.digestProgressSocketTimeoutSeconds,
            decoding: WorkspaceSidebarDigestProgressState.self
        )
        return CMUXDigestProgressSnapshot(
            generatedAt: state.generatedAt,
            summaryStage: state.summaryPriority?.stage,
            workspaceStages: state.workspaces.mapValues(\.stage)
        )
    }

    func setOverride(scope: CMUXDigestScope, values: [String: Any]) throws {
        guard let workspaceId = scope.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspaceId.isEmpty else { return }
        var payload = values
        payload["workspaceId"] = workspaceId
        _ = try sendDigestCommandSync("set_summary_priority_override", payload: payload)
    }

    private func sendDigestCommand(
        _ command: String,
        payload: [String: Any],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        sendDigestCommandRaw(command, payload: payload) { result in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func sendDigestCommand<Response: Decodable>(
        _ command: String,
        payload: [String: Any],
        queue: DispatchQueue = WorkspaceDigestService.socketQueue,
        timeoutSeconds: TimeInterval = WorkspaceDigestService.digestSocketTimeoutSeconds,
        decoding _: Response.Type,
        completion: @escaping (Result<Response, Error>) -> Void
    ) {
        sendDigestCommandRaw(command, payload: payload, queue: queue, timeoutSeconds: timeoutSeconds) { [decoder] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let body):
                guard let data = body.data(using: .utf8) else {
                    completion(.failure(CmuxSocketError(message: "Invalid UTF-8 from digest daemon")))
                    return
                }
                do {
                    completion(.success(try decoder.decode(Response.self, from: data)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func sendDigestCommandRaw(
        _ command: String,
        payload: [String: Any],
        queue: DispatchQueue = WorkspaceDigestService.socketQueue,
        timeoutSeconds: TimeInterval = WorkspaceDigestService.digestSocketTimeoutSeconds,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        queue.async {
            let result = Result {
                try self.sendDigestCommandSync(command, payload: payload, timeoutSeconds: timeoutSeconds)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    @discardableResult
    private func sendDigestCommandSync(
        _ command: String,
        payload: [String: Any],
        timeoutSeconds: TimeInterval = WorkspaceDigestService.digestSocketTimeoutSeconds
    ) throws -> String {
        runtime.update(enabled: true)
        let socketPath = runtime.socketPath()
        _ = Self.waitForDigestSocket(at: socketPath, timeout: Self.digestSocketStartupWaitSeconds)
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [])
        let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"
        let client = CmuxSocketClient(path: socketPath, timeoutSeconds: timeoutSeconds)
        try client.connect()
        defer { client.close() }
        return try DigestSocketResponseParser.parse(client.send(command: "\(command) \(payloadString)"))
    }

    private func sendDigestCommandSync<Response: Decodable>(
        _ command: String,
        payload: [String: Any],
        timeoutSeconds: TimeInterval = WorkspaceDigestService.digestSocketTimeoutSeconds,
        decoding _: Response.Type
    ) throws -> Response {
        let body = try sendDigestCommandSync(command, payload: payload, timeoutSeconds: timeoutSeconds)
        guard let data = body.data(using: .utf8) else {
            throw CmuxSocketError(message: "Invalid UTF-8 from digest daemon")
        }
        return try decoder.decode(Response.self, from: data)
    }

    private static func waitForDigestSocket(at path: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var info = stat()
            if stat(path, &info) == 0,
               (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

#if DEBUG
    private static func debugResponseSummary(_ response: String) -> String {
        let singleLine = response
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        guard singleLine.count > 240 else { return singleLine }
        return String(singleLine.prefix(240)) + "..."
    }
#endif
}

enum DigestSocketResponseParser {
    static func parse(_ response: String) throws -> String {
        if response.hasPrefix("ERROR:") {
            let message = response.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CmuxSocketError(message: message)
        }
        if response.hasPrefix("OK ") {
            return String(response.dropFirst(3))
        }
        if response == "OK" {
            return ""
        }
        throw CmuxSocketError(message: "Unexpected response: \(response)")
    }
}

private struct DigestWorkspaceResult: Decodable {
    struct Topic: Decodable {
        var text: String
    }

    struct Summary: Decodable {
        var short: String
        var detailed: String
    }

    struct State: Decodable {
        var currentStatus: String
        var nextActions: [String]
    }

    var workspaceId: String
    var generatedAt: String
    var topic: Topic
    var summary: Summary
    var state: State
    var inputHash: String?

    func pluginResult(scope: CMUXDigestScope) -> CMUXDigestResult {
        CMUXDigestResult(
            id: workspaceId,
            scope: scope,
            text: summary.short,
            summary: summary.detailed,
            status: state.currentStatus,
            nextActions: state.nextActions,
            itemsUsed: [],
            createdAt: generatedAt,
            metadata: [
                "topic": topic.text,
                "inputHash": inputHash ?? "",
            ].filter { !$0.value.isEmpty }
        )
    }
}

final class DigestPluginRuntime: WorkspaceDigestRuntime {
    private var process: Process?
    private var lastStartFailureAt: Date?
    private var homeDirectory: URL?
    private let ghprConfigurationProvider: () -> CMUXGHPRConfiguration
#if DEBUG
    private var logHandle: FileHandle?
#endif

    private static let startFailureRetryInterval: TimeInterval = 5

    init(ghprConfigurationProvider: @escaping () -> CMUXGHPRConfiguration = {
        CMUXGHPRConfiguration.load()
    }) {
        self.ghprConfigurationProvider = ghprConfigurationProvider
    }

    private static let debugBundleIdentifierPrefix = "com.cmuxterm.app.debug."

    static func digestSocketPath() -> String {
        if let tag = currentDebugTag() {
            return "/tmp/cmux-digest-\(tag).sock"
        }
        return "/tmp/cmux-digest.sock"
    }

    func socketPath() -> String {
        Self.digestSocketPath()
    }

    static func defaultHomeDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cmux/digest", isDirectory: true)
    }

    func setHomeDirectory(_ url: URL?) {
        homeDirectory = url
    }

    private static func currentDebugTag(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let bundleIdentifier = Bundle.main.bundleIdentifier,
           bundleIdentifier.hasPrefix(debugBundleIdentifierPrefix) {
            return String(bundleIdentifier.dropFirst(debugBundleIdentifierPrefix.count))
                .replacingOccurrences(of: ".", with: "-")
        }
        if let envTag = environment["CMUX_TAG"]?.trimmingCharacters(in: .whitespacesAndNewlines), !envTag.isEmpty {
            return envTag.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        }
        return nil
    }

    func update(enabled: Bool) {
        if enabled {
            startIfNeeded()
        } else {
            stop()
        }
    }

    func reload(enabled: Bool) {
        guard enabled else {
            stop()
            return
        }
        stop(waitUntilExit: true)
        startIfNeeded(ignoreFailureThrottle: true)
    }

    func restartIfRunning() {
        guard process?.isRunning == true else { return }
        stop()
        startIfNeeded(ignoreFailureThrottle: true)
    }

    func shutdown() {
        stop(waitUntilExit: true)
    }

    private func startIfNeeded(ignoreFailureThrottle: Bool = false) {
        guard process?.isRunning != true else { return }
        if !ignoreFailureThrottle,
           let lastStartFailureAt,
           Date().timeIntervalSince(lastStartFailureAt) < Self.startFailureRetryInterval {
            return
        }
        guard let resources = Bundle.main.resourceURL else { return }
        let digestURL = resources.appendingPathComponent("bin/cmux-digest")
        guard FileManager.default.isExecutableFile(atPath: digestURL.path) else { return }

#if DEBUG
        Self.terminateStaleDebugDaemons(at: digestURL)
#endif

        let digestSocket = Self.digestSocketPath()
        unlink(digestSocket)

        let socketPath = SocketControlSettings.socketPath()
        let environment = Self.environmentForLaunch(
            resources: resources,
            digestSocket: digestSocket,
            socketPath: socketPath,
            digestHome: homeDirectory,
            ghprConfiguration: ghprConfigurationProvider()
        )

        let process = Process()
        process.executableURL = digestURL
        process.arguments = ["daemon"]
        process.environment = environment

#if DEBUG
        var daemonLogHandle: FileHandle?
        let daemonLogURL = Self.daemonLogURL(environment: environment, socketPath: digestSocket)
        FileManager.default.createFile(atPath: daemonLogURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: daemonLogURL) {
            handle.write(Data("cmux-app: starting cmux-digest socket=\(digestSocket) cmuxSocket=\(socketPath) cli=\(environment["CMUX_DIGEST_CMUX"] ?? "nil")\n".utf8))
            process.standardOutput = handle
            process.standardError = handle
            daemonLogHandle = handle
            cmuxDebugLog("digest.daemon.start socket=\(digestSocket) cmuxSocket=\(socketPath) log=\(daemonLogURL.path)")
        }
#endif

        do {
            try process.run()
            lastStartFailureAt = nil
            self.process = process
#if DEBUG
            self.logHandle = daemonLogHandle
#endif
        } catch {
            lastStartFailureAt = Date()
#if DEBUG
            daemonLogHandle?.closeFile()
#endif
            NSLog("Failed to launch cmux-digest daemon: %@", error.localizedDescription)
        }
    }

    static func environmentForLaunch(
        resources: URL,
        digestSocket: String,
        socketPath: String,
        digestHome: URL? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        defaults: UserDefaults = .standard,
        ghprConfiguration: CMUXGHPRConfiguration
    ) -> [String: String] {
        var environment = baseEnvironment
        environment["CMUX_DIGEST_SOCKET_PATH"] = digestSocket
        if let digestHome {
            environment["CMUX_DIGEST_HOME"] = digestHome.path
        }

        let cmuxURL = resources.appendingPathComponent("bin/cmux")
        if FileManager.default.isExecutableFile(atPath: cmuxURL.path) {
            environment["CMUX_DIGEST_CMUX"] = cmuxURL.path
        }

        applyDigestPreferences(
            to: &environment,
            defaults: defaults,
            ghprConfiguration: ghprConfiguration
        )

        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_SOCKET"] = socketPath
        if let bundleIdentifier,
           bundleIdentifier.hasPrefix(debugBundleIdentifierPrefix) {
            environment["CMUX_TAG"] = bundleIdentifier
                .dropFirst(debugBundleIdentifierPrefix.count)
                .replacingOccurrences(of: ".", with: "-")
        }
#if DEBUG
        environment["CMUX_DIGEST_DEBUG_LOG"] = "1"
#endif
        return environment
    }

    private static func applyDigestPreferences(
        to environment: inout [String: String],
        defaults: UserDefaults = .standard,
        ghprConfiguration: CMUXGHPRConfiguration
    ) {
        let digestEnabled = defaults.bool(forKey: "digest.enabled")
        environment["CMUX_DIGEST_ENABLED"] = digestEnabled ? "1" : "0"
        let ghprEnabled = ghprConfiguration.enabled

        let rawProvider = defaults.string(forKey: "digest.provider")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawProvider, !rawProvider.isEmpty {
            environment["CMUX_DIGEST_PROVIDER"] = DigestProviderOption.normalizedRawValue(rawProvider)
        }

        if let model = defaults.string(forKey: "digest.model")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            environment["CMUX_DIGEST_MODEL"] = model
        } else if let legacyModel = defaults.string(forKey: "digest.claudeCodeModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
                  !legacyModel.isEmpty {
            environment["CMUX_DIGEST_CLAUDE_MODEL"] = legacyModel
        }

        if let value = defaults.object(forKey: "digest.currentWorkspaceMinIntervalSec") as? Int {
            environment["CMUX_DIGEST_CURRENT_INTERVAL"] = "\(value)"
        }
        if let value = defaults.object(forKey: "digest.backgroundMinIntervalSec") as? Int {
            environment["CMUX_DIGEST_BACKGROUND_INTERVAL"] = "\(value)"
        }
        if let value = defaults.object(forKey: "digest.screenLines") as? Int {
            environment["CMUX_DIGEST_SCREEN_LINES"] = "\(value)"
        }
        if let value = defaults.object(forKey: "digest.includeDiffStat") as? Bool {
            environment["CMUX_DIGEST_INCLUDE_DIFF_STAT"] = value ? "1" : "0"
        }
        if let value = defaults.object(forKey: "digest.maxConcurrentLLM") as? Int {
            environment["CMUX_DIGEST_MAX_CONCURRENT_LLM"] = "\(value)"
        }

        environment["CMUX_DIGEST_WRITE_SIDEBAR"] = CMUXGHPRService.writesSidebarMetadata(
            digestEnabled: digestEnabled,
            ghprEnabled: ghprEnabled,
            defaults: defaults
        ) ? "1" : "0"

        // cmux-digest gets ghpr data through plugin.context.collect; keep only
        // formatting and gating preferences in the sidecar environment.
        environment["CMUX_DIGEST_GHPR_ENABLED"] = ghprEnabled ? "1" : "0"
        environment["CMUX_DIGEST_GHPR_DISPLAY_ITEMS"] = ghprConfiguration.displayItemsText
    }

#if DEBUG
    private static func daemonLogURL(environment: [String: String], socketPath: String) -> URL {
        let tag = environment["CMUX_TAG"] ?? URL(fileURLWithPath: socketPath)
            .deletingPathExtension()
            .lastPathComponent
        let safeTag = tag.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        return URL(fileURLWithPath: "/tmp/cmux-digest-\(safeTag).log")
    }

    private static func terminateStaleDebugDaemons(at digestURL: URL) {
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        cleanup.arguments = ["-f", "\(digestURL.path) daemon"]
        cleanup.standardOutput = FileHandle.nullDevice
        cleanup.standardError = FileHandle.nullDevice
        do {
            try cleanup.run()
            cleanup.waitUntilExit()
            if cleanup.terminationStatus == 0 {
                cmuxDebugLog("digest.daemon.cleanup path=\(digestURL.path)")
            }
        } catch {
            cmuxDebugLog("digest.daemon.cleanup.failed error=\(error.localizedDescription)")
        }
    }
#endif

    private func stop(waitUntilExit: Bool = false) {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            if waitUntilExit {
                process.waitUntilExit()
            }
        }
        self.process = nil
#if DEBUG
        logHandle?.closeFile()
        logHandle = nil
#endif
    }
}
