import CMUXActions
import CMUXContracts
import Foundation

public struct AssistantRuntimeContextRead: Equatable, Sendable {
    public var workingContext: AssistantWorkingContext
    public var snapshotVersions: [UUID: Int]
    public var staleProviderIds: [String]
    public var missingSnapshot: Bool

    public init(
        workingContext: AssistantWorkingContext,
        snapshotVersions: [UUID: Int],
        staleProviderIds: [String],
        missingSnapshot: Bool
    ) {
        self.workingContext = workingContext
        self.snapshotVersions = snapshotVersions
        self.staleProviderIds = staleProviderIds
        self.missingSnapshot = missingSnapshot
    }
}

public enum AssistantRuntimeError: Error, Equatable {
    case actionGatewayUnavailable
}

public actor AssistantRuntime {
    private let contextReader: any AssistantContextReadable
    private let actionGateway: SemanticActionGateway?

    public init(
        contextReader: any AssistantContextReadable,
        actionGateway: SemanticActionGateway? = nil
    ) {
        self.contextReader = contextReader
        self.actionGateway = actionGateway
    }

    public func readContextForAnswer(now: Date = Date()) async -> AssistantRuntimeContextRead {
        let context = await contextReader.assistantWorkingContext()
        let staleProviderIds = orderedUniqueAssistant(context.snapshots.flatMap { snapshot in
            snapshot.freshness.evaluated(at: now).providers
                .filter(\.stale)
                .map(\.providerId)
        })
        return AssistantRuntimeContextRead(
            workingContext: context,
            snapshotVersions: Dictionary(uniqueKeysWithValues: context.snapshots.map {
                ($0.workspaceId, $0.version)
            }),
            staleProviderIds: staleProviderIds,
            missingSnapshot: context.snapshots.isEmpty
        )
    }

    public func submitAction(_ intent: ActionIntent) async throws -> SemanticReviewResult {
        guard let actionGateway else {
            throw AssistantRuntimeError.actionGatewayUnavailable
        }
        return try await actionGateway.submit(intent)
    }
}

private func orderedUniqueAssistant(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for value in values where !seen.contains(value) {
        seen.insert(value)
        ordered.append(value)
    }
    return ordered
}
