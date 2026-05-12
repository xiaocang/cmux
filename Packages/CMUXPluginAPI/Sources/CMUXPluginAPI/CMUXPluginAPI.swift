import Foundation

public struct CMUXPluginManifest: Equatable {
    public var id: String
    public var name: String?
    public var version: String?
    public var apiVersion: String
    public var activation: [String]
    public var permissions: [String]

    public init(
        id: String,
        name: String? = nil,
        version: String? = nil,
        apiVersion: String = "0.1",
        activation: [String] = [],
        permissions: [String] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.apiVersion = apiVersion
        self.activation = activation
        self.permissions = permissions
    }
}

public protocol CMUXPlugin {
    var manifest: CMUXPluginManifest { get }

    func activate(context: CMUXPluginContext) throws
    func deactivate()
}

public extension CMUXPlugin {
    func deactivate() {}
}

public protocol CMUXPluginContext {
    var logger: CMUXPluginLogger { get }
    var events: CMUXEventRegistry { get }
    var storage: CMUXPluginStorage { get }
    var workspace: CMUXWorkspaceAPI { get }
    var context: CMUXContextRegistry { get }
    var digest: CMUXDigestRegistry { get }
    var prompt: CMUXPromptRegistry { get }
    var commands: CMUXCommandRegistry { get }
    var sidebarExtensions: CMUXSidebarExtensionRegistry { get }
    var settings: CMUXSettingsRegistry { get }
}

public protocol CMUXPluginLogger {
    func debug(_ message: String)
    func info(_ message: String)
    func warning(_ message: String)
    func error(_ message: String)
}

public protocol CMUXPluginDisposable {
    func dispose()
}

public final class CMUXBlockDisposable: CMUXPluginDisposable {
    private let lock = NSLock()
    private var onDispose: (() -> Void)?

    public init(_ onDispose: @escaping () -> Void) {
        self.onDispose = onDispose
    }

    public func dispose() {
        lock.lock()
        let action = onDispose
        onDispose = nil
        lock.unlock()
        action?()
    }
}

public struct CMUXPluginEvent {
    public var name: String
    public var category: String
    public var source: String
    public var workspaceId: String?
    public var surfaceId: String?
    public var paneId: String?
    public var windowId: String?
    public var sequence: Int64?
    public var payload: [String: Any]
    public var raw: [String: Any]

    public init(
        name: String,
        category: String,
        source: String,
        workspaceId: String? = nil,
        surfaceId: String? = nil,
        paneId: String? = nil,
        windowId: String? = nil,
        sequence: Int64? = nil,
        payload: [String: Any] = [:],
        raw: [String: Any] = [:]
    ) {
        self.name = name
        self.category = category
        self.source = source
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.paneId = paneId
        self.windowId = windowId
        self.sequence = sequence
        self.payload = payload
        self.raw = raw
    }
}

public protocol CMUXEventRegistry {
    @discardableResult
    func subscribe(
        names: Set<String>,
        categories: Set<String>,
        handler: @escaping (CMUXPluginEvent) -> Void
    ) -> CMUXPluginDisposable
}

public struct CMUXContextItem: Codable, Hashable {
    public var id: String
    public var source: String
    public var kind: String
    public var text: String
    public var metadata: [String: String]
    public var createdAt: String?
    public var updatedAt: String?

    public init(
        id: String,
        source: String,
        kind: String,
        text: String,
        metadata: [String: String] = [:],
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.text = text
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CMUXContextCollectInput: Codable, Hashable {
    public var workspaceId: String?
    public var conversationId: String?
    public var taskId: String?

    public init(workspaceId: String? = nil, conversationId: String? = nil, taskId: String? = nil) {
        self.workspaceId = workspaceId
        self.conversationId = conversationId
        self.taskId = taskId
    }
}

public protocol CMUXContextCollector {
    var id: String { get }
    func collect(input: CMUXContextCollectInput) throws -> [CMUXContextItem]
}

public protocol CMUXContextRegistry {
    @discardableResult
    func registerCollector(_ collector: CMUXContextCollector) -> CMUXPluginDisposable
    func collect(input: CMUXContextCollectInput) -> [CMUXContextItem]
}

public struct CMUXDigestScope: Codable, Hashable {
    public var workspaceId: String?
    public var conversationId: String?
    public var taskId: String?

    public init(workspaceId: String? = nil, conversationId: String? = nil, taskId: String? = nil) {
        self.workspaceId = workspaceId
        self.conversationId = conversationId
        self.taskId = taskId
    }
}

public struct CMUXDigestScheduleRequest: Codable, Hashable {
    public var scope: CMUXDigestScope
    public var reason: String
    public var force: Bool

    public init(scope: CMUXDigestScope, reason: String, force: Bool = false) {
        self.scope = scope
        self.reason = reason
        self.force = force
    }
}

public struct CMUXDigestResult: Codable, Hashable {
    public var id: String
    public var scope: CMUXDigestScope
    public var text: String
    public var summary: String?
    public var status: String?
    public var nextActions: [String]
    public var itemsUsed: [String]
    public var createdAt: String
    public var metadata: [String: String]

    public init(
        id: String,
        scope: CMUXDigestScope,
        text: String,
        summary: String? = nil,
        status: String? = nil,
        nextActions: [String] = [],
        itemsUsed: [String] = [],
        createdAt: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.scope = scope
        self.text = text
        self.summary = summary
        self.status = status
        self.nextActions = nextActions
        self.itemsUsed = itemsUsed
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public struct CMUXDigestProgressSnapshot: Codable, Hashable {
    public var generatedAt: String?
    public var summaryStage: String?
    public var workspaceStages: [String: String]

    public init(generatedAt: String? = nil, summaryStage: String? = nil, workspaceStages: [String: String] = [:]) {
        self.generatedAt = generatedAt
        self.summaryStage = summaryStage
        self.workspaceStages = workspaceStages
    }
}

public protocol CMUXDigestRegistry {
    func schedule(_ request: CMUXDigestScheduleRequest)
    func get(scope: CMUXDigestScope) throws -> CMUXDigestResult?
    func refresh(scope: CMUXDigestScope, force: Bool) throws -> CMUXDigestResult?
    func progress() throws -> CMUXDigestProgressSnapshot
    func setOverride(scope: CMUXDigestScope, values: [String: Any]) throws
}

public struct CMUXPromptContextInput: Codable, Hashable {
    public var workspaceId: String?
    public var conversationId: String?
    public var taskId: String?
    public var model: String?
    public var tokenBudget: Int?

    public init(
        workspaceId: String? = nil,
        conversationId: String? = nil,
        taskId: String? = nil,
        model: String? = nil,
        tokenBudget: Int? = nil
    ) {
        self.workspaceId = workspaceId
        self.conversationId = conversationId
        self.taskId = taskId
        self.model = model
        self.tokenBudget = tokenBudget
    }
}

public struct CMUXPromptContribution: Codable, Hashable {
    public var id: String
    public var source: String
    public var role: String
    public var priority: Int
    public var content: String
    public var tokenEstimate: Int?

    public init(
        id: String,
        source: String,
        role: String = "system",
        priority: Int,
        content: String,
        tokenEstimate: Int? = nil
    ) {
        self.id = id
        self.source = source
        self.role = role
        self.priority = priority
        self.content = content
        self.tokenEstimate = tokenEstimate
    }
}

public protocol CMUXPromptContributor {
    var id: String { get }
    func contribute(input: CMUXPromptContextInput) throws -> [CMUXPromptContribution]
}

public protocol CMUXPromptRegistry {
    @discardableResult
    func registerContributor(_ contributor: CMUXPromptContributor) -> CMUXPluginDisposable
    func collect(input: CMUXPromptContextInput) -> [CMUXPromptContribution]
}

public protocol CMUXPluginStorage {
    func url(forPluginId pluginId: String) throws -> URL
}

public protocol CMUXWorkspaceAPI {
    func currentWorkspaceId() -> String?
}

public struct CMUXCommandContribution {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var keywords: [String]
    public var dismissOnRun: Bool
    public var handler: () -> Void

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        dismissOnRun: Bool = true,
        handler: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.dismissOnRun = dismissOnRun
        self.handler = handler
    }
}

public enum CMUXSocketProtocolVersion: String {
    case v1
    case v2
}

public struct CMUXSocketCommandInput {
    public var commandId: String
    public var protocolVersion: CMUXSocketProtocolVersion
    public var rawLine: String
    public var params: [String: Any]
    public var arguments: String?
    public var jsonRPCId: Any?

    public init(
        commandId: String,
        protocolVersion: CMUXSocketProtocolVersion,
        rawLine: String,
        params: [String: Any] = [:],
        arguments: String? = nil,
        jsonRPCId: Any? = nil
    ) {
        self.commandId = commandId
        self.protocolVersion = protocolVersion
        self.rawLine = rawLine
        self.params = params
        self.arguments = arguments
        self.jsonRPCId = jsonRPCId
    }
}

public struct CMUXSocketCommandResult {
    public var payload: [String: Any]

    public init(payload: [String: Any] = [:]) {
        self.payload = payload
    }

    public static func ok(_ payload: [String: Any] = [:]) -> CMUXSocketCommandResult {
        CMUXSocketCommandResult(payload: payload)
    }
}

public struct CMUXSocketCommandError: Error {
    public var code: String
    public var message: String
    public var data: [String: Any]?

    public init(code: String, message: String, data: [String: Any]? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public enum CMUXSocketCommandExecutionContext: String, Equatable {
    case mainActor
    case socketWorker
}

public struct CMUXSocketCommandContribution {
    public var id: String
    public var title: String?
    public var executionContext: CMUXSocketCommandExecutionContext
    public var handler: (CMUXSocketCommandInput) throws -> CMUXSocketCommandResult

    public init(
        id: String,
        title: String? = nil,
        executionContext: CMUXSocketCommandExecutionContext = .mainActor,
        handler: @escaping (CMUXSocketCommandInput) throws -> CMUXSocketCommandResult
    ) {
        self.id = id
        self.title = title
        self.executionContext = executionContext
        self.handler = handler
    }
}

public protocol CMUXCommandRegistry {
    @discardableResult
    func registerCommand(_ command: CMUXCommandContribution) -> CMUXPluginDisposable
    func command(id: String) -> CMUXCommandContribution?
    func commands() -> [CMUXCommandContribution]

    @discardableResult
    func registerSocketCommand(_ command: CMUXSocketCommandContribution) -> CMUXPluginDisposable
    func socketCommand(id: String) -> CMUXSocketCommandContribution?
    func socketCommands() -> [CMUXSocketCommandContribution]
}

public struct CMUXSettingsContribution: Equatable {
    public var id: String
    public var target: String
    public var title: String
    public var subtitle: String?
    public var symbolName: String?
    public var searchText: String
    public var anchorID: String?

    public init(
        id: String,
        target: String,
        title: String,
        subtitle: String? = nil,
        symbolName: String? = nil,
        searchText: String = "",
        anchorID: String? = nil
    ) {
        self.id = id
        self.target = target
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.searchText = searchText
        self.anchorID = anchorID
    }
}

public protocol CMUXSettingsRegistry {
    @discardableResult
    func registerSettingsContribution(_ contribution: CMUXSettingsContribution) -> CMUXPluginDisposable
    func settingsContribution(id: String) -> CMUXSettingsContribution?
    func settingsContributions() -> [CMUXSettingsContribution]
}

public enum CMUXSidebarExtensionPlacement: String, Equatable {
    case workspaceSidebarTrailingOverlay
}

public struct CMUXSidebarExtensionContribution: Equatable {
    public var id: String
    public var title: String
    public var placement: CMUXSidebarExtensionPlacement
    public var openStateKey: String
    public var defaultOpen: Bool
    public var priority: Int
    public var metadata: [String: String]

    public init(
        id: String,
        title: String,
        placement: CMUXSidebarExtensionPlacement,
        openStateKey: String,
        defaultOpen: Bool,
        priority: Int = 0,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.placement = placement
        self.openStateKey = openStateKey
        self.defaultOpen = defaultOpen
        self.priority = priority
        self.metadata = metadata
    }
}

public protocol CMUXSidebarExtensionRegistry {
    @discardableResult
    func registerSidebarExtension(_ extensionContribution: CMUXSidebarExtensionContribution) -> CMUXPluginDisposable
    func sidebarExtension(id: String) -> CMUXSidebarExtensionContribution?
    func sidebarExtensions() -> [CMUXSidebarExtensionContribution]
}
