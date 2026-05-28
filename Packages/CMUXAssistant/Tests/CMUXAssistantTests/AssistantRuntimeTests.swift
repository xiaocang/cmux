import CMUXActions
import CMUXContracts
import XCTest
@testable import CMUXAssistant

final class AssistantRuntimeTests: XCTestCase {
    func testReadContextReportsMissingSnapshot() async {
        let runtime = AssistantRuntime(contextReader: FixtureContextReader(context: FixtureContextReader.empty))

        let read = await runtime.readContextForAnswer(now: Date(timeIntervalSince1970: 1_000))

        XCTAssertTrue(read.missingSnapshot)
        XCTAssertTrue(read.snapshotVersions.isEmpty)
    }

    func testReadContextReportsSnapshotVersionsAndStaleProviders() async {
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let snapshot = Self.snapshot(
            workspaceId: workspaceId,
            version: 3,
            providerId: "github_context",
            lastCollectedAt: Date(timeIntervalSince1970: 800),
            ttlSeconds: 60
        )
        let runtime = AssistantRuntime(contextReader: FixtureContextReader(context: AssistantWorkingContext(
            activeWorkspaceId: workspaceId,
            snapshots: [snapshot],
            freshness: snapshot.freshness,
            activeSuggestions: [],
            latestRanking: nil
        )))

        let read = await runtime.readContextForAnswer(now: Date(timeIntervalSince1970: 1_000))

        XCTAssertFalse(read.missingSnapshot)
        XCTAssertEqual(read.snapshotVersions, [workspaceId: 3])
        XCTAssertEqual(read.staleProviderIds, ["github_context"])
        XCTAssertEqual(read.workingContext.activeWorkspaceId, workspaceId)
    }

    func testSubmitActionRequiresGateway() async {
        let runtime = AssistantRuntime(contextReader: FixtureContextReader(context: FixtureContextReader.empty))
        let intent = Self.actionIntent(kind: .writeMemory)

        do {
            _ = try await runtime.submitAction(intent)
            XCTFail("Expected AssistantRuntime to reject action submission without a gateway")
        } catch {
            XCTAssertEqual(error as? AssistantRuntimeError, .actionGatewayUnavailable)
        }
    }

    func testSubmitActionDelegatesToSemanticActionGateway() async throws {
        let executor = RecordingActionExecutor()
        let auditLog = RecordingActionAuditLog()
        let gateway = SemanticActionGateway(
            reviewers: [AllowingActionReviewer()],
            executor: executor,
            auditLog: auditLog
        )
        let runtime = AssistantRuntime(
            contextReader: FixtureContextReader(context: FixtureContextReader.empty),
            actionGateway: gateway
        )
        let intent = Self.actionIntent(kind: .writeMemory)

        let result = try await runtime.submitAction(intent)

        XCTAssertEqual(result.decision, .allow)
        XCTAssertTrue(result.executed)
        let executedIntentIds = await executor.executedIntentIds()
        let reviewedIntentIds = await auditLog.reviewedIntentIds()
        let auditExecutedIntentIds = await auditLog.executedIntentIds()
        XCTAssertEqual(executedIntentIds, [intent.id])
        XCTAssertEqual(reviewedIntentIds, [intent.id])
        XCTAssertEqual(auditExecutedIntentIds, [intent.id])
    }

    private static func snapshot(
        workspaceId: UUID,
        version: Int,
        providerId: String,
        lastCollectedAt: Date,
        ttlSeconds: TimeInterval
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            workspaceId: workspaceId,
            version: version,
            updatedAt: lastCollectedAt,
            context: NormalizedWorkspaceContext(
                title: "API fix",
                selected: true,
                directory: "/tmp/api",
                listRevision: version,
                nativeOrder: 0,
                pinned: false,
                locked: false,
                customColor: nil,
                panelCount: 1,
                pullRequestCount: 1,
                stalePullRequestCount: 0
            ),
            derived: DerivedWorkspaceState(
                status: "waiting_user",
                priorityScore: 90,
                rankReason: "Agent is waiting for review",
                nextAction: "Review agent output",
                userAttentionNeeded: 0.9
            ),
            digest: WorkspaceDigest(
                summary: "Agent is waiting for review.",
                generatedAt: lastCollectedAt
            ),
            freshness: ContextFreshness(
                providers: [
                    ProviderFreshness(
                        providerId: providerId,
                        lastCollectedAt: lastCollectedAt,
                        ttlSeconds: ttlSeconds,
                        stale: false,
                        error: nil,
                        confidence: 1
                    ),
                ],
                overallConfidence: 1
            )
        )
    }

    private static func actionIntent(kind: CmuxActionKind) -> ActionIntent {
        ActionIntent(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            requestedBy: ActionRequester(id: "assistant-test", route: "remember_preference"),
            kind: kind,
            arguments: ["domain": "free_sort", "text": "Keep CI failures high priority"],
            evidence: ActionEvidence(snapshotVersions: [:], snapshotUpdatedAt: [:]),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

private struct FixtureContextReader: AssistantContextReadable {
    var context: AssistantWorkingContext

    static let empty = AssistantWorkingContext(
        activeWorkspaceId: nil,
        snapshots: [],
        freshness: ContextFreshness(providers: [], overallConfidence: 0),
        activeSuggestions: [],
        latestRanking: nil
    )

    func assistantWorkingContext() async -> AssistantWorkingContext {
        context
    }

    func workspaceSnapshot(_ id: UUID) async -> WorkspaceSnapshot? {
        context.snapshots.first { $0.workspaceId == id }
    }

    func activeSuggestions() async -> [ProactiveSuggestion] {
        context.activeSuggestions
    }

    func latestRanking() async -> RankingSnapshot? {
        context.latestRanking
    }
}

private actor RecordingActionExecutor: CmuxActionExecutor {
    private var executedIds: [UUID] = []

    func execute(_ intent: ActionIntent) async throws -> ActionExecutionResult {
        executedIds.append(intent.id)
        return ActionExecutionResult(payload: ["kind": intent.kind.rawValue])
    }

    func executedIntentIds() -> [UUID] {
        executedIds
    }
}

private actor RecordingActionAuditLog: ActionAuditLog {
    private var reviewedIds: [UUID] = []
    private var executedIds: [UUID] = []

    func recordReview(intent: ActionIntent, result _: SemanticReviewResult) async {
        reviewedIds.append(intent.id)
    }

    func recordExecuted(intent: ActionIntent, result _: ActionExecutionResult) async {
        executedIds.append(intent.id)
    }

    func reviewedIntentIds() -> [UUID] {
        reviewedIds
    }

    func executedIntentIds() -> [UUID] {
        executedIds
    }
}
