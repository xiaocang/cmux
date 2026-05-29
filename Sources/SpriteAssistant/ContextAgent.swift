import CMUXContextAgent
import Foundation

typealias ContextRefreshPriority = CMUXContextAgent.ContextRefreshPriority
typealias ContextAttentionLease = CMUXContextAgent.ContextAttentionLease
typealias ContextRefreshJob = CMUXContextAgent.ContextRefreshJob
typealias ContextProviderRefreshPolicy = CMUXContextAgent.ContextProviderRefreshPolicy
typealias ContextProviderExecutionPolicy = CMUXContextAgent.ContextProviderExecutionPolicy
typealias ContextProviderExecutionError = CMUXContextAgent.ContextProviderExecutionError
typealias ContextWorkspaceLeaseDiagnostic = CMUXContextAgent.ContextWorkspaceLeaseDiagnostic
typealias ContextProviderCollectionDiagnostic = CMUXContextAgent.ContextProviderCollectionDiagnostic
typealias ContextSchedulerDiagnosticsSnapshot = CMUXContextAgent.ContextSchedulerDiagnosticsSnapshot
typealias ContextAgentDiagnosticsSnapshot = CMUXContextAgent.ContextAgentDiagnosticsSnapshot
typealias ContextAgentEvent = CMUXContextAgent.ContextAgentEvent
typealias ContextAgentEventLog = CMUXContextAgent.ContextAgentEventLog
typealias ContextAgentEventLogError = CMUXContextAgent.ContextAgentEventLogError
typealias ContextScheduler = CMUXContextAgent.ContextScheduler
typealias ProviderRunRecord = CMUXContextAgent.ProviderRunRecord
typealias ProviderRunStore = CMUXContextAgent.ProviderRunStore
typealias WorkspaceSnapshotProviding = CMUXContextAgent.WorkspaceSnapshotProviding
typealias WorkspaceSnapshotStoring = CMUXContextAgent.WorkspaceSnapshotStoring
typealias ProviderRegistry = CMUXContextAgent.ProviderRegistry
typealias ContextAgentBatchResult = CMUXContextAgent.ContextAgentBatchResult
typealias ContextAgent = CMUXContextAgent.ContextAgent

extension WorkspaceSnapshotStore: WorkspaceSnapshotStoring {}

extension ContextAgent {
    private static var eventCategories: Set<String> {
        [
            "workspace",
            "sidebar",
            "notification",
            "surface",
            "agent",
            "assistant",
        ]
    }

    func enqueueRetainedEvents(
        from eventBus: CmuxEventBus = .shared,
        afterSequence: Int64? = nil
    ) async -> Int {
        let snapshot = eventBus.subscribe(
            afterSequence: afterSequence,
            names: [],
            categories: Self.eventCategories
        )
        defer { eventBus.unsubscribe(snapshot.subscription) }

        var handledCount = 0
        for rawEvent in snapshot.replay {
            guard let event = ContextAgentEvent(cmuxEvent: rawEvent),
                  !event.affectedWorkspaceIds.isEmpty else {
                continue
            }
            await handle(event)
            handledCount += 1
        }
        return handledCount
    }

    nonisolated func startEventStream(
        from eventBus: CmuxEventBus = .shared,
        afterSequence: Int64? = nil,
        pollTimeout: TimeInterval = 1,
        batchMaxJobs: Int = 16,
        onBatch: (@Sendable (ContextAgentBatchResult) async -> Void)? = nil
    ) -> Task<Void, Never> {
        let snapshot = eventBus.subscribe(
            afterSequence: afterSequence,
            names: [],
            categories: Self.eventCategories
        )
        return Task.detached { [snapshot, eventBus, onBatch] in
            defer { eventBus.unsubscribe(snapshot.subscription) }
            for rawEvent in snapshot.replay {
                await self.handleAndDrain(rawEvent, maxJobs: batchMaxJobs, onBatch: onBatch)
            }
            while !Task.isCancelled {
                guard let rawEvent = snapshot.subscription.next(timeout: pollTimeout) else {
                    if snapshot.subscription.isClosed {
                        return
                    }
                    continue
                }
                await self.handleAndDrain(rawEvent, maxJobs: batchMaxJobs, onBatch: onBatch)
            }
        }
    }

    private func handleAndDrain(
        _ rawEvent: [String: Any],
        maxJobs: Int,
        onBatch: (@Sendable (ContextAgentBatchResult) async -> Void)?
    ) async {
        guard let event = ContextAgentEvent(cmuxEvent: rawEvent),
              !event.affectedWorkspaceIds.isEmpty else {
            return
        }
        await handle(event)
        let result = await runScheduledBatch(maxJobs: maxJobs)
        // Notify the consumer only when something actually changed or failed, so we
        // never wake the main actor on empty poll-cadence drains. The batch already
        // merged snapshots into the store; this callback is a pure notification hook.
        if let onBatch, !result.updatedWorkspaceIds.isEmpty || !result.failures.isEmpty {
            await onBatch(result)
        }
    }
}
