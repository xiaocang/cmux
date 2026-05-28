import CMUXContracts
import Foundation

private func orderedUniqueContextAgent(_ ids: [UUID]) -> [UUID] {
    var seen = Set<UUID>()
    var ordered: [UUID] = []
    for id in ids where !seen.contains(id) {
        seen.insert(id)
        ordered.append(id)
    }
    return ordered
}

public enum ContextRefreshPriority: Int, Codable, Comparable, Sendable {
    case background = 0
    case visible = 10
    case userInitiated = 20

    public static func < (lhs: ContextRefreshPriority, rhs: ContextRefreshPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ContextAttentionLease: Int, Codable, Comparable, Sendable {
    case cold = 0
    case visible = 10
    case hot = 20

    public static func < (lhs: ContextAttentionLease, rhs: ContextAttentionLease) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var refreshPriority: ContextRefreshPriority {
        switch self {
        case .cold:
            return .background
        case .visible:
            return .visible
        case .hot:
            return .userInitiated
        }
    }
}

public struct ContextRefreshJob: Codable, Equatable, Sendable {
    public var workspaceId: UUID
    public var reason: String
    public var priority: ContextRefreshPriority
    public var enqueuedAt: Date
    public var providerId: String? = nil
    public var payload: [String: String] = [:]

    public init(
        workspaceId: UUID,
        reason: String,
        priority: ContextRefreshPriority,
        enqueuedAt: Date,
        providerId: String? = nil,
        payload: [String: String] = [:]
    ) {
        self.workspaceId = workspaceId
        self.reason = reason
        self.priority = priority
        self.enqueuedAt = enqueuedAt
        self.providerId = providerId
        self.payload = payload
    }
}

public struct ContextProviderRefreshPolicy: Equatable, Sendable {
    public var providerId: String
    public var hotIntervalSeconds: TimeInterval
    public var visibleIntervalSeconds: TimeInterval
    public var coldIntervalSeconds: TimeInterval
    public var debounceSeconds: TimeInterval

    public init(
        providerId: String,
        hotIntervalSeconds: TimeInterval = 20,
        visibleIntervalSeconds: TimeInterval = 60,
        coldIntervalSeconds: TimeInterval = 300,
        debounceSeconds: TimeInterval = 2
    ) {
        self.providerId = providerId
        self.hotIntervalSeconds = hotIntervalSeconds
        self.visibleIntervalSeconds = visibleIntervalSeconds
        self.coldIntervalSeconds = coldIntervalSeconds
        self.debounceSeconds = debounceSeconds
    }

    public func interval(for lease: ContextAttentionLease) -> TimeInterval {
        switch lease {
        case .hot:
            return hotIntervalSeconds
        case .visible:
            return visibleIntervalSeconds
        case .cold:
            return coldIntervalSeconds
        }
    }
}

public struct ContextProviderExecutionPolicy: Equatable, Sendable {
    public var maxConcurrentProviderRuns: Int
    public var providerTimeoutSeconds: TimeInterval?

    public init(
        maxConcurrentProviderRuns: Int = 4,
        providerTimeoutSeconds: TimeInterval? = 15
    ) {
        self.maxConcurrentProviderRuns = max(1, maxConcurrentProviderRuns)
        self.providerTimeoutSeconds = providerTimeoutSeconds
    }
}

public enum ContextProviderExecutionError: Error, Equatable, Sendable {
    case timeout(providerId: String, seconds: TimeInterval)
}

private struct ContextRefreshJobKey: Hashable {
    var workspaceId: UUID
    var providerId: String?
}

private struct ContextProviderCollectionKey: Hashable {
    var workspaceId: UUID
    var providerId: String
}

private struct ContextProviderRunOutcome: Sendable {
    var providerId: String
    var startedAt: Date
    var finishedAt: Date
    var snapshot: WorkspaceSnapshot?
    var errorMessage: String?
}

public struct ContextWorkspaceLeaseDiagnostic: Codable, Equatable, Sendable {
    public var workspaceId: UUID
    public var lease: ContextAttentionLease

    public init(workspaceId: UUID, lease: ContextAttentionLease) {
        self.workspaceId = workspaceId
        self.lease = lease
    }
}

public struct ContextProviderCollectionDiagnostic: Codable, Equatable, Sendable {
    public var workspaceId: UUID
    public var providerId: String
    public var lastCollectedAt: Date?
    public var lastSignaledAt: Date?
}

public struct ContextSchedulerDiagnosticsSnapshot: Codable, Equatable, Sendable {
    public var pendingJobs: [ContextRefreshJob]
    public var workspaceLeases: [ContextWorkspaceLeaseDiagnostic]
    public var providerCollections: [ContextProviderCollectionDiagnostic]
}

public struct ContextAgentDiagnosticsSnapshot: Codable, Equatable, Sendable {
    public var providerIds: [String]
    public var scheduler: ContextSchedulerDiagnosticsSnapshot
    public var providerRuns: [ProviderRunRecord]
}

public struct ContextAgentEvent: Codable, Equatable, Sendable {
    public static let agentMessageAppendedName = "dev.cmux.agent.message_appended.v1"

    public var name: String
    public var workspaceId: UUID?
    public var relatedWorkspaceIds: [UUID]
    public var occurredAt: Date
    public var payload: [String: String]

    private enum CodingKeys: String, CodingKey {
        case name
        case workspaceId
        case relatedWorkspaceIds
        case occurredAt
        case payload
    }

    public var affectedWorkspaceIds: [UUID] {
        orderedUniqueContextAgent(([workspaceId].compactMap { $0 }) + relatedWorkspaceIds)
    }

    public init(
        name: String,
        workspaceId: UUID?,
        relatedWorkspaceIds: [UUID] = [],
        occurredAt: Date,
        payload: [String: String] = [:]
    ) {
        self.name = name
        self.workspaceId = workspaceId
        self.relatedWorkspaceIds = relatedWorkspaceIds
        self.occurredAt = occurredAt
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.workspaceId = try container.decodeIfPresent(UUID.self, forKey: .workspaceId)
        self.relatedWorkspaceIds = try container.decodeIfPresent([UUID].self, forKey: .relatedWorkspaceIds) ?? []
        self.occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        self.payload = try container.decodeIfPresent([String: String].self, forKey: .payload) ?? [:]
    }

    public init?(cmuxEvent: [String: Any]) {
        guard let name = cmuxEvent["name"] as? String else { return nil }
        let workspaceId = Self.uuid(cmuxEvent["workspace_id"] ?? cmuxEvent["workspaceId"])
            ?? Self.uuid((cmuxEvent["payload"] as? [String: Any])?["workspace_id"])
            ?? Self.uuid((cmuxEvent["payload"] as? [String: Any])?["workspaceId"])
        let payload = Self.stringPayload(cmuxEvent["payload"] as? [String: Any] ?? [:])
        let relatedWorkspaceIds = Self.uuidArray(
            cmuxEvent["related_workspace_ids"]
                ?? cmuxEvent["relatedWorkspaceIds"]
                ?? (cmuxEvent["payload"] as? [String: Any])?["related_workspace_ids"]
                ?? (cmuxEvent["payload"] as? [String: Any])?["relatedWorkspaceIds"]
        )
        let occurredAt = Self.date(cmuxEvent["occurred_at"] ?? cmuxEvent["occurredAt"])
            ?? Date()
        self.init(
            name: name,
            workspaceId: workspaceId,
            relatedWorkspaceIds: relatedWorkspaceIds,
            occurredAt: occurredAt,
            payload: payload
        )
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let string = value as? String else { return nil }
        return UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func uuidArray(_ value: Any?) -> [UUID] {
        if let strings = value as? [String] {
            return strings.compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        if let values = value as? [Any] {
            return values.compactMap(uuid)
        }
        if let string = value as? String {
            return string
                .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
                .compactMap { UUID(uuidString: String($0)) }
        }
        return []
    }

    private static func stringPayload(_ payload: [String: Any]) -> [String: String] {
        var output: [String: String] = [:]
        for (key, value) in payload {
            switch value {
            case let string as String:
                output[key] = string
            case let number as NSNumber:
                output[key] = number.stringValue
            case is NSNull:
                continue
            default:
                output[key] = String(describing: value)
            }
        }
        return output
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return ContextAgentEventLog.date(from: string)
    }
}

public enum ContextAgentEventLog {
    public static func date(from raw: String) -> Date? {
        iso8601DateFormatter().date(from: raw)
            ?? fallbackISO8601DateFormatter().date(from: raw)
    }

    private static func iso8601DateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func fallbackISO8601DateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    public static func decodeJSONLines(_ data: Data) throws -> [ContextAgentEvent] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ContextAgentEventLogError.invalidUTF8
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(raw)"
            )
        }

        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let data = Data(line.utf8)
                return try decoder.decode(ContextAgentEvent.self, from: data)
            }
    }
}

public enum ContextAgentEventLogError: Error, Equatable {
    case invalidUTF8
}

public actor ContextScheduler {
    private var queuedJobs: [ContextRefreshJobKey: ContextRefreshJob] = [:]
    private var attentionLeases: [UUID: ContextAttentionLease] = [:]
    private var lastProviderCollections: [ContextProviderCollectionKey: Date] = [:]
    private var lastProviderSignals: [ContextProviderCollectionKey: Date] = [:]

    public init() {}

    public func enqueue(_ job: ContextRefreshJob) {
        enqueueResolved(job)
    }

    public func enqueue(
        _ job: ContextRefreshJob,
        honoringAttentionLease: Bool
    ) {
        guard honoringAttentionLease else {
            enqueueResolved(job)
            return
        }
        var promoted = job
        if let lease = attentionLeases[job.workspaceId] {
            promoted.priority = max(job.priority, lease.refreshPriority)
        }
        enqueueResolved(promoted)
    }

    public func setLease(_ lease: ContextAttentionLease, for workspaceId: UUID) {
        attentionLeases[workspaceId] = lease
    }

    public func lease(for workspaceId: UUID) -> ContextAttentionLease {
        attentionLeases[workspaceId] ?? .cold
    }

    public func markProviderCollected(
        _ providerId: String,
        workspace workspaceId: UUID,
        at date: Date
    ) {
        lastProviderCollections[ContextProviderCollectionKey(
            workspaceId: workspaceId,
            providerId: providerId
        )] = date
    }

    public func enqueueDueProviderRefreshes(
        policy: ContextProviderRefreshPolicy,
        workspaceIds: [UUID],
        now: Date,
        reason: String
    ) {
        for workspaceId in orderedUniqueContextAgent(workspaceIds) {
            let lease = self.lease(for: workspaceId)
            let key = ContextProviderCollectionKey(
                workspaceId: workspaceId,
                providerId: policy.providerId
            )
            if let lastCollectedAt = lastProviderCollections[key],
               now.timeIntervalSince(lastCollectedAt) < policy.interval(for: lease) {
                continue
            }
            enqueue(ContextRefreshJob(
                workspaceId: workspaceId,
                reason: reason,
                priority: lease.refreshPriority,
                enqueuedAt: now,
                providerId: policy.providerId,
                payload: ["providerId": policy.providerId]
            ), honoringAttentionLease: true)
        }
    }

    public func enqueueProviderSignal(
        providerId: String,
        workspaceId: UUID,
        reason: String,
        enqueuedAt: Date,
        debounceSeconds: TimeInterval
    ) {
        let key = ContextProviderCollectionKey(
            workspaceId: workspaceId,
            providerId: providerId
        )
        if let lastSignalAt = lastProviderSignals[key],
           enqueuedAt.timeIntervalSince(lastSignalAt) < debounceSeconds {
            return
        }
        lastProviderSignals[key] = enqueuedAt
        enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: reason,
            priority: lease(for: workspaceId).refreshPriority,
            enqueuedAt: enqueuedAt,
            providerId: providerId,
            payload: ["providerId": providerId]
        ), honoringAttentionLease: true)
    }

    private func enqueueResolved(_ job: ContextRefreshJob) {
        let key = ContextRefreshJobKey(
            workspaceId: job.workspaceId,
            providerId: job.providerId
        )
        if let existing = queuedJobs[key],
           existing.priority > job.priority {
            return
        }
        queuedJobs[key] = job
    }

    public func pendingJobCount() -> Int {
        queuedJobs.count
    }

    public func pendingJobs() -> [ContextRefreshJob] {
        sortedJobs()
    }

    public func diagnostics() -> ContextSchedulerDiagnosticsSnapshot {
        let collectionKeys = Set(lastProviderCollections.keys).union(lastProviderSignals.keys)
        return ContextSchedulerDiagnosticsSnapshot(
            pendingJobs: sortedJobs(),
            workspaceLeases: attentionLeases
                .map { workspaceId, lease in
                    ContextWorkspaceLeaseDiagnostic(workspaceId: workspaceId, lease: lease)
                }
                .sorted { lhs, rhs in lhs.workspaceId.uuidString < rhs.workspaceId.uuidString },
            providerCollections: collectionKeys
                .map { key in
                    ContextProviderCollectionDiagnostic(
                        workspaceId: key.workspaceId,
                        providerId: key.providerId,
                        lastCollectedAt: lastProviderCollections[key],
                        lastSignaledAt: lastProviderSignals[key]
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.workspaceId.uuidString != rhs.workspaceId.uuidString {
                        return lhs.workspaceId.uuidString < rhs.workspaceId.uuidString
                    }
                    return lhs.providerId < rhs.providerId
                }
        )
    }

    public func nextBatch(maxJobs: Int = Int.max) -> [ContextRefreshJob] {
        let jobs = Array(sortedJobs().prefix(maxJobs))
        for job in jobs {
            queuedJobs[ContextRefreshJobKey(
                workspaceId: job.workspaceId,
                providerId: job.providerId
            )] = nil
        }
        return jobs
    }

    private func sortedJobs() -> [ContextRefreshJob] {
        queuedJobs.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            if lhs.enqueuedAt != rhs.enqueuedAt {
                return lhs.enqueuedAt < rhs.enqueuedAt
            }
            if lhs.workspaceId != rhs.workspaceId {
                return lhs.workspaceId.uuidString < rhs.workspaceId.uuidString
            }
            return (lhs.providerId ?? "") < (rhs.providerId ?? "")
        }
    }
}

public struct ProviderRunRecord: Codable, Equatable, Sendable {
    public var workspaceId: UUID
    public var providerId: String
    public var reason: String
    public var priority: ContextRefreshPriority
    public var startedAt: Date
    public var finishedAt: Date
    public var success: Bool
    public var snapshotVersion: Int?
    public var errorMessage: String?

    public init(
        workspaceId: UUID,
        providerId: String,
        reason: String,
        priority: ContextRefreshPriority,
        startedAt: Date,
        finishedAt: Date,
        success: Bool,
        snapshotVersion: Int?,
        errorMessage: String?
    ) {
        self.workspaceId = workspaceId
        self.providerId = providerId
        self.reason = reason
        self.priority = priority
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.success = success
        self.snapshotVersion = snapshotVersion
        self.errorMessage = errorMessage
    }
}

public actor ProviderRunStore {
    private var records: [ProviderRunRecord] = []

    public init() {}

    public func record(_ record: ProviderRunRecord) {
        records.append(record)
    }

    public func allRecords() -> [ProviderRunRecord] {
        records
    }

    public func latestRecords(limit: Int = Int.max) -> [ProviderRunRecord] {
        guard limit != Int.max else { return records }
        return Array(records.suffix(max(0, limit)))
    }

    public func records(for workspaceId: UUID) -> [ProviderRunRecord] {
        records.filter { $0.workspaceId == workspaceId }
    }
}

public protocol WorkspaceSnapshotProviding: Sendable {
    var providerId: String { get }
    func snapshot(for job: ContextRefreshJob) async throws -> WorkspaceSnapshot
}

public protocol WorkspaceSnapshotStoring: Sendable {
    func mergeProviderSnapshot(
        _ snapshot: WorkspaceSnapshot,
        activeWorkspaceId: UUID?
    ) async -> WorkspaceSnapshot
}

public extension WorkspaceSnapshotProviding {
    var providerId: String {
        String(describing: Self.self)
    }
}

public actor ProviderRegistry {
    private var orderedProviderIds: [String] = []
    private var providersById: [String: any WorkspaceSnapshotProviding] = [:]
    private var disabledProviderIds: Set<String> = []

    public init(providers: [any WorkspaceSnapshotProviding] = []) {
        for provider in providers {
            let providerId = provider.providerId
            if providersById[providerId] == nil {
                orderedProviderIds.append(providerId)
            }
            providersById[providerId] = provider
            disabledProviderIds.remove(providerId)
        }
    }

    public func register(_ provider: any WorkspaceSnapshotProviding) {
        registerWithoutIsolation(provider)
    }

    public func setEnabled(_ enabled: Bool, providerId: String) {
        if enabled {
            disabledProviderIds.remove(providerId)
        } else {
            disabledProviderIds.insert(providerId)
        }
    }

    public func providerIds(includeDisabled: Bool = false) -> [String] {
        orderedProviderIds.filter { includeDisabled || !disabledProviderIds.contains($0) }
    }

    public func providers(matching providerId: String?) -> [any WorkspaceSnapshotProviding] {
        if let providerId {
            guard !disabledProviderIds.contains(providerId),
                  let provider = providersById[providerId] else {
                return []
            }
            return [provider]
        }

        return orderedProviderIds.compactMap { providerId in
            guard !disabledProviderIds.contains(providerId) else { return nil }
            return providersById[providerId]
        }
    }

    private func registerWithoutIsolation(_ provider: any WorkspaceSnapshotProviding) {
        let providerId = provider.providerId
        if providersById[providerId] == nil {
            orderedProviderIds.append(providerId)
        }
        providersById[providerId] = provider
        disabledProviderIds.remove(providerId)
    }
}

public struct ContextAgentBatchResult: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public var workspaceId: UUID
        public var providerId: String
        public var message: String

        public init(workspaceId: UUID, providerId: String, message: String) {
            self.workspaceId = workspaceId
            self.providerId = providerId
            self.message = message
        }
    }

    public var updatedWorkspaceIds: [UUID]
    public var failures: [Failure]

    public init(updatedWorkspaceIds: [UUID], failures: [Failure]) {
        self.updatedWorkspaceIds = updatedWorkspaceIds
        self.failures = failures
    }
}

public actor ContextAgent {
    private nonisolated static let eventCategories: Set<String> = [
        "workspace",
        "sidebar",
        "notification",
        "surface",
        "agent",
        "assistant",
    ]

    private let snapshotStore: any WorkspaceSnapshotStoring
    private let scheduler: ContextScheduler
    private let providerRunStore: ProviderRunStore
    private let providerRegistry: ProviderRegistry
    private let executionPolicy: ContextProviderExecutionPolicy

    public init(
        snapshotStore: any WorkspaceSnapshotStoring,
        scheduler: ContextScheduler = ContextScheduler(),
        providerRunStore: ProviderRunStore = ProviderRunStore(),
        providerRegistry: ProviderRegistry? = nil,
        executionPolicy: ContextProviderExecutionPolicy = ContextProviderExecutionPolicy(),
        providers: [any WorkspaceSnapshotProviding]
    ) {
        self.snapshotStore = snapshotStore
        self.scheduler = scheduler
        self.providerRunStore = providerRunStore
        self.providerRegistry = providerRegistry ?? ProviderRegistry(providers: providers)
        self.executionPolicy = executionPolicy
    }

    public func enqueue(_ job: ContextRefreshJob) async {
        await scheduler.enqueue(job)
    }

    public func handle(_ event: ContextAgentEvent) async {
        let availableProviderIds = await providerRegistry.providerIds()
        let routedProviderIds = providerIds(for: event, availableProviderIds: availableProviderIds)
        for workspaceId in event.affectedWorkspaceIds {
            if let lease = attentionLease(for: event) {
                await scheduler.setLease(lease, for: workspaceId)
            }
            for providerId in routedProviderIds {
                await scheduler.enqueue(ContextRefreshJob(
                    workspaceId: workspaceId,
                    reason: event.name,
                    priority: refreshPriority(for: event),
                    enqueuedAt: event.occurredAt,
                    providerId: providerId,
                    payload: event.payload
                ), honoringAttentionLease: true)
            }
        }
    }

    public func handleWorkspaceAttention(
        workspaceId: UUID,
        reason: String,
        lease: ContextAttentionLease,
        now: Date = Date()
    ) async {
        await scheduler.setLease(lease, for: workspaceId)
        await scheduler.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: reason,
            priority: lease.refreshPriority,
            enqueuedAt: now
        ), honoringAttentionLease: true)
    }

    public func queuedJobCount() async -> Int {
        await scheduler.pendingJobCount()
    }

    public func providerRunRecords() async -> [ProviderRunRecord] {
        await providerRunStore.allRecords()
    }

    public func providerIds() async -> [String] {
        await providerRegistry.providerIds()
    }

    public func registerProvider(_ provider: any WorkspaceSnapshotProviding) async {
        await providerRegistry.register(provider)
    }

    public func diagnostics(providerRunLimit: Int = 50) async -> ContextAgentDiagnosticsSnapshot {
        let providerIds = await providerRegistry.providerIds(includeDisabled: true)
        let schedulerDiagnostics = await scheduler.diagnostics()
        let providerRuns = await providerRunStore.latestRecords(limit: providerRunLimit)
        return ContextAgentDiagnosticsSnapshot(
            providerIds: providerIds,
            scheduler: schedulerDiagnostics,
            providerRuns: providerRuns
        )
    }

    public func runScheduledBatch(maxJobs: Int = Int.max) async -> ContextAgentBatchResult {
        let jobs = await scheduler.nextBatch(maxJobs: maxJobs)

        var updatedWorkspaceIds: [UUID] = []
        var failures: [ContextAgentBatchResult.Failure] = []
        for job in jobs {
            var didUpdate = false
            let providersForJob = await providerRegistry.providers(matching: job.providerId)
            for chunk in Self.chunks(
                providersForJob,
                size: executionPolicy.maxConcurrentProviderRuns
            ) {
                let outcomes = await runProviderChunk(chunk, job: job)
                for outcome in outcomes {
                    var mergedSnapshotVersion: Int?
                    if let snapshot = outcome.snapshot {
                        let merged = await snapshotStore.mergeProviderSnapshot(
                            snapshot,
                            activeWorkspaceId: nil
                        )
                        mergedSnapshotVersion = merged.version
                        await scheduler.markProviderCollected(
                            outcome.providerId,
                            workspace: job.workspaceId,
                            at: outcome.finishedAt
                        )
                        didUpdate = true
                    }

                    await providerRunStore.record(ProviderRunRecord(
                        workspaceId: job.workspaceId,
                        providerId: outcome.providerId,
                        reason: job.reason,
                        priority: job.priority,
                        startedAt: outcome.startedAt,
                        finishedAt: outcome.finishedAt,
                        success: outcome.snapshot != nil,
                        snapshotVersion: mergedSnapshotVersion,
                        errorMessage: outcome.errorMessage
                    ))

                    if let message = outcome.errorMessage {
                        failures.append(ContextAgentBatchResult.Failure(
                            workspaceId: job.workspaceId,
                            providerId: outcome.providerId,
                            message: message
                        ))
                    }
                }
            }
            if didUpdate {
                updatedWorkspaceIds.append(job.workspaceId)
            }
        }

        return ContextAgentBatchResult(
            updatedWorkspaceIds: updatedWorkspaceIds,
            failures: failures
        )
    }

    private nonisolated func refreshPriority(for event: ContextAgentEvent) -> ContextRefreshPriority {
        switch event.name {
        case "assistant.query_started":
            return .userInitiated
        case ContextAgentEvent.agentMessageAppendedName,
             "workspace.selected",
             "workspace.created",
             "sidebar.metadata.updated",
             "notification.requested":
            return .visible
        default:
            return .background
        }
    }

    private nonisolated func attentionLease(for event: ContextAgentEvent) -> ContextAttentionLease? {
        switch event.name {
        case "assistant.query_started":
            return .hot
        case ContextAgentEvent.agentMessageAppendedName,
             "workspace.selected":
            return .visible
        default:
            return nil
        }
    }

    private nonisolated func providerIds(
        for event: ContextAgentEvent,
        availableProviderIds: [String]
    ) -> [String?] {
        let candidates = providerCandidates(for: event)
        let available = Set(availableProviderIds)
        let routed = candidates.filter { available.contains($0) }
        return routed.isEmpty ? [nil] : routed.map(Optional.some)
    }

    private nonisolated func providerCandidates(for event: ContextAgentEvent) -> [String] {
        if event.name == "assistant.query_started" {
            return [
                "list_state",
                "agent_session",
                "github_context",
                "summary_priority",
            ]
        }
        if event.name == ContextAgentEvent.agentMessageAppendedName {
            return [
                "agent_session",
                "summary_priority",
            ]
        }
        if event.name == "workspace.selected" || event.name == "workspace.created" {
            return [
                "list_state",
                "summary_priority",
            ]
        }
        if event.name == "sidebar.metadata.updated" {
            return [
                "list_state",
                "github_context",
                "summary_priority",
            ]
        }
        if isGitContextEvent(event.name) {
            return [
                "git_context",
                "summary_priority",
            ]
        }
        if event.name == "notification.requested" {
            return [
                "summary_priority",
            ]
        }
        if event.name.contains("github") || event.name.contains("pull_request") || event.name.contains("pr.") {
            return [
                "github_context",
                "summary_priority",
            ]
        }
        if event.name.hasPrefix("surface.") || event.name.hasPrefix("pane.") {
            return [
                "list_state",
            ]
        }
        return []
    }

    private nonisolated func isGitContextEvent(_ name: String) -> Bool {
        let normalized = name
            .lowercased()
            .replacingOccurrences(of: "_", with: ".")
        guard !normalized.contains("github") else {
            return false
        }
        return normalized == "git.changed"
            || normalized.hasPrefix("git.")
            || normalized.contains(".git.")
    }

    private func runProviderChunk(
        _ providers: [any WorkspaceSnapshotProviding],
        job: ContextRefreshJob
    ) async -> [ContextProviderRunOutcome] {
        let policy = executionPolicy
        return await withTaskGroup(of: ContextProviderRunOutcome.self) { group in
            for provider in providers {
                group.addTask {
                    await Self.runProvider(provider, job: job, policy: policy)
                }
            }

            var outcomes: [ContextProviderRunOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes.sorted { lhs, rhs in
                lhs.providerId < rhs.providerId
            }
        }
    }

    private nonisolated static func runProvider(
        _ provider: any WorkspaceSnapshotProviding,
        job: ContextRefreshJob,
        policy: ContextProviderExecutionPolicy
    ) async -> ContextProviderRunOutcome {
        let startedAt = Date()
        do {
            let snapshot = try await withTimeout(
                providerTimeoutSeconds: policy.providerTimeoutSeconds,
                providerId: provider.providerId
            ) {
                try await provider.snapshot(for: job)
            }
            return ContextProviderRunOutcome(
                providerId: provider.providerId,
                startedAt: startedAt,
                finishedAt: Date(),
                snapshot: snapshot,
                errorMessage: nil
            )
        } catch {
            return ContextProviderRunOutcome(
                providerId: provider.providerId,
                startedAt: startedAt,
                finishedAt: Date(),
                snapshot: nil,
                errorMessage: String(describing: error)
            )
        }
    }

    private nonisolated static func withTimeout<T: Sendable>(
        providerTimeoutSeconds: TimeInterval?,
        providerId: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let providerTimeoutSeconds else {
            return try await operation()
        }
        let nanoseconds = UInt64(max(0, providerTimeoutSeconds) * 1_000_000_000)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw ContextProviderExecutionError.timeout(
                    providerId: providerId,
                    seconds: providerTimeoutSeconds
                )
            }
            guard let result = try await group.next() else {
                throw ContextProviderExecutionError.timeout(
                    providerId: providerId,
                    seconds: providerTimeoutSeconds
                )
            }
            group.cancelAll()
            return result
        }
    }

    private nonisolated static func chunks<T>(_ values: [T], size: Int) -> [[T]] {
        let chunkSize = max(1, size)
        var chunks: [[T]] = []
        var index = values.startIndex
        while index < values.endIndex {
            let end = values.index(index, offsetBy: chunkSize, limitedBy: values.endIndex) ?? values.endIndex
            chunks.append(Array(values[index..<end]))
            index = end
        }
        return chunks
    }
}
