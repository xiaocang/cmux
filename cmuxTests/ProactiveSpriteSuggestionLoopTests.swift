import XCTest
import CMUXContracts

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Phase 1 closed-loop coverage: a ContextAgent batch must drive a proactive
/// suggestion recompute (into `visibleSuggestions`) WITHOUT the assistant panel
/// being open — but only when `ProactiveSpriteSuggestionsSettings` is enabled.
///
/// Pre-fix (Phase 0) `handleContextAgentBatch` only records DEBUG telemetry and
/// never recomputes, so `testContextAgentBatchRecomputesWhenEnabled` fails (red).
/// The Phase 1 gated/debounced recompute makes it pass (green).
@MainActor
final class ProactiveSpriteSuggestionLoopTests: XCTestCase {
    private let flagKey = ProactiveSpriteSuggestionsSettings.key

    override func setUp() {
        super.setUp()
        // Remove the debounce delay so the recompute Task is awaitable deterministically.
        SortAssistantCoordinator.debugProactiveSuggestionRecomputeDebounceOverrideNanos = 0
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: flagKey)
        SortAssistantCoordinator.debugProactiveSuggestionRecomputeDebounceOverrideNanos = nil
        super.tearDown()
    }

    func testContextAgentBatchRecomputesWhenEnabled() async throws {
        let coordinator = SortAssistantCoordinator.shared
        UserDefaults.standard.set(true, forKey: flagKey)

        let workspaceId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        await coordinator.workspaceSnapshotStore.write(
            Self.waitingUserSnapshot(workspaceId: workspaceId, contextHash: "phase1-enabled")
        )

        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [workspaceId], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()

        XCTAssertTrue(
            coordinator.visibleSuggestions.contains {
                $0.type == ProactiveSuggestionTypes.reviewAgentWaitingUser
                    && $0.workspaceId == workspaceId
            },
            "An enabled flag must recompute proactive suggestions from the merged store after a batch, even with the panel closed."
        )
        XCTAssertGreaterThanOrEqual(
            coordinator.proactiveAttentionCount, 1,
            "A high-confidence waiting_user suggestion should drive the collapsed-mascot attention badge when enabled."
        )
        XCTAssertEqual(
            coordinator.proactiveBadgeByWorkspaceId()[workspaceId]?.type,
            ProactiveSuggestionTypes.reviewAgentWaitingUser,
            "Enabled flag should expose a per-workspace sidebar badge resolved at the boundary."
        )
    }

    func testContextAgentBatchDoesNotRecomputeWhenDisabled() async throws {
        let coordinator = SortAssistantCoordinator.shared
        UserDefaults.standard.set(false, forKey: flagKey)

        let workspaceId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        await coordinator.workspaceSnapshotStore.write(
            Self.waitingUserSnapshot(workspaceId: workspaceId, contextHash: "phase1-disabled")
        )

        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [workspaceId], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()

        XCTAssertFalse(
            coordinator.visibleSuggestions.contains { $0.workspaceId == workspaceId },
            "A disabled flag must not recompute or surface proactive suggestions for the batch."
        )
        XCTAssertEqual(
            coordinator.proactiveAttentionCount, 0,
            "A disabled flag must report a zero mascot attention badge count."
        )
        XCTAssertTrue(
            coordinator.proactiveBadgeByWorkspaceId().isEmpty,
            "A disabled flag must expose no sidebar proactive badges."
        )
    }

    private static func waitingUserSnapshot(
        workspaceId: UUID,
        contextHash: String
    ) -> WorkspaceSnapshot {
        let freshness = ContextFreshness(
            providers: [
                ProviderFreshness(
                    providerId: "summary_priority",
                    lastCollectedAt: Date(timeIntervalSince1970: 1_000),
                    ttlSeconds: 120,
                    stale: false,
                    error: nil,
                    confidence: 0.95
                ),
            ],
            overallConfidence: 0.95
        )
        return WorkspaceSnapshot(
            workspaceId: workspaceId,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            context: NormalizedWorkspaceContext(
                title: "API fix",
                selected: false,
                directory: nil,
                listRevision: 1,
                nativeOrder: 0,
                pinned: false,
                locked: false,
                customColor: nil,
                panelCount: 0,
                pullRequestCount: 0,
                stalePullRequestCount: 0
            ),
            derived: DerivedWorkspaceState(
                status: "waiting_user",
                priorityScore: nil,
                rankReason: nil,
                nextAction: "Review the agent's question",
                userAttentionNeeded: 0.95
            ),
            digest: nil,
            freshness: freshness,
            contextHash: contextHash
        )
    }
}
