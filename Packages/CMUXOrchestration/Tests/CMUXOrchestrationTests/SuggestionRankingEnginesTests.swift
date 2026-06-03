import CMUXContracts
import XCTest
@testable import CMUXOrchestration

final class SuggestionRankingEnginesTests: XCTestCase {
    func testRankingPrioritizesAttentionBeforeNativeOrder() {
        let low = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000001",
            status: "running",
            nativeOrder: 0,
            attention: 0.1
        )
        let high = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000002",
            status: "waiting_user",
            nativeOrder: 1,
            attention: 0.9
        )

        let ranking = RankingEngine.default.rank([low, high])

        XCTAssertEqual(ranking.items.first?.workspaceId, high.workspaceId)
    }

    func testSuggestionEngineCreatesSnapshotDrivenSuggestions() {
        let waiting = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000001",
            status: "waiting_user",
            nativeOrder: 0,
            attention: 0.9
        )

        let suggestions = SuggestionEngine.default.generate(from: [waiting])

        XCTAssertEqual(suggestions.map(\.type), [ProactiveSuggestionTypes.reviewAgentWaitingUser])
        XCTAssertEqual(suggestions.first?.workspaceId, waiting.workspaceId)
    }

    func testSuggestionEngineCreatesAllSnapshotDrivenSuggestionTypes() {
        let waiting = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000001",
            status: "waiting_user",
            nativeOrder: 0,
            attention: 0.9
        )
        let ciFailed = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000002",
            status: "ci_failed",
            nativeOrder: 1,
            attention: 0.95
        )
        let mergeReady = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000003",
            status: "ready_to_merge",
            nativeOrder: 2,
            attention: 0.8
        )

        let suggestions = SuggestionEngine.default.generate(from: [mergeReady, ciFailed, waiting])

        XCTAssertEqual(suggestions.map(\.type), [
            ProactiveSuggestionTypes.reviewAgentWaitingUser,
            ProactiveSuggestionTypes.fixCIFailure,
            ProactiveSuggestionTypes.mergeReady,
        ])
        XCTAssertEqual(suggestions.map(\.workspaceId), [
            waiting.workspaceId,
            ciFailed.workspaceId,
            mergeReady.workspaceId,
        ])
    }

    func testSuggestionEngineCreatesGenericHighAttentionSuggestion() {
        let completed = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000004",
            status: "agent_completed",
            nativeOrder: 0,
            attention: 0.92
        )

        let suggestions = SuggestionEngine.default.generate(from: [completed])

        XCTAssertEqual(suggestions.map(\.type), [ProactiveSuggestionTypes.workspaceNeedsAttention])
        XCTAssertEqual(suggestions.first?.workspaceId, completed.workspaceId)
    }

    func testSuggestionEngineSuppressesGenericLowAttentionSnapshot() {
        let completed = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000005",
            status: "agent_completed",
            nativeOrder: 0,
            attention: 0.4
        )

        let suggestions = SuggestionEngine.default.generate(from: [completed])

        XCTAssertEqual(suggestions, [])
    }

    func testSuggestionStoreHidesDismissedSuggestionUntilSnapshotChanges() async throws {
        let store = SuggestionStore()
        let engine = SuggestionEngine(store: store)
        let waiting = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000001",
            status: "waiting_user",
            nativeOrder: 0,
            attention: 0.9
        )

        let firstSuggestions = await engine.generateAndStore(from: [waiting])
        let first = try XCTUnwrap(firstSuggestions.first)

        await store.dismiss(first.id)

        let hiddenSuggestions = await engine.generateAndStore(from: [waiting])
        XCTAssertEqual(hiddenSuggestions, [])

        let changed = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000001",
            status: "waiting_user",
            nativeOrder: 0,
            attention: 0.95
        )
        let changedSuggestions = await engine.generateAndStore(from: [changed])

        XCTAssertEqual(changedSuggestions.count, 1)
        XCTAssertNotEqual(changedSuggestions.first?.id, first.id)
    }

    func testNextWorkspaceSkipsPinnedAndLockedRankedItems() {
        let active = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000001",
            status: "running",
            nativeOrder: 0,
            attention: 0.2
        )
        let pinned = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000002",
            status: "waiting_user",
            nativeOrder: 1,
            attention: 0.9,
            pinned: true
        )
        let locked = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000003",
            status: "ci_failed",
            nativeOrder: 2,
            attention: 0.8,
            locked: true
        )
        let next = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000004",
            status: "ready_to_merge",
            nativeOrder: 3,
            attention: 0.7
        )
        let context = AssistantWorkingContext(
            activeWorkspaceId: active.workspaceId,
            snapshots: [active, pinned, locked, next],
            freshness: ContextFreshness(providers: [], overallConfidence: 1),
            activeSuggestions: [],
            latestRanking: RankingSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                items: [
                    RankingSnapshot.Item(workspaceId: active.workspaceId, rank: 1, score: 100, reason: nil),
                    RankingSnapshot.Item(workspaceId: pinned.workspaceId, rank: 2, score: 90, reason: nil),
                    RankingSnapshot.Item(workspaceId: locked.workspaceId, rank: 3, score: 80, reason: nil),
                    RankingSnapshot.Item(workspaceId: next.workspaceId, rank: 4, score: 70, reason: nil),
                ]
            )
        )

        let result = NextWorkspaceService.default.nextWorkspace(in: context)

        XCTAssertEqual(result?.workspaceId, next.workspaceId)
    }

    func testNextWorkspaceReturnsNilWhenAllRankedItemsArePinnedOrLocked() {
        let pinned = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000001",
            status: "waiting_user",
            nativeOrder: 0,
            attention: 0.9,
            pinned: true
        )
        let locked = Self.snapshot(
            id: "00000000-0000-0000-0000-000000000002",
            status: "ci_failed",
            nativeOrder: 1,
            attention: 0.8,
            locked: true
        )
        let context = AssistantWorkingContext(
            activeWorkspaceId: nil,
            snapshots: [pinned, locked],
            freshness: ContextFreshness(providers: [], overallConfidence: 1),
            activeSuggestions: [],
            latestRanking: RankingSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                items: [
                    RankingSnapshot.Item(workspaceId: pinned.workspaceId, rank: 1, score: 100, reason: nil),
                    RankingSnapshot.Item(workspaceId: locked.workspaceId, rank: 2, score: 90, reason: nil),
                ]
            )
        )

        XCTAssertNil(NextWorkspaceService.default.nextWorkspace(in: context))
    }

    private static func snapshot(
        id: String,
        status: String,
        nativeOrder: Int,
        attention: Double,
        pinned: Bool = false,
        locked: Bool = false
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            workspaceId: UUID(uuidString: id)!,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 100 + TimeInterval(nativeOrder)),
            context: NormalizedWorkspaceContext(
                title: "Workspace \(nativeOrder)",
                selected: nativeOrder == 0,
                directory: nil,
                listRevision: 1,
                nativeOrder: nativeOrder,
                pinned: pinned,
                locked: locked,
                customColor: nil,
                panelCount: 1,
                pullRequestCount: 0,
                stalePullRequestCount: 0
            ),
            derived: DerivedWorkspaceState(
                status: status,
                priorityScore: nil,
                rankReason: "Status \(status)",
                nextAction: "Open workspace",
                userAttentionNeeded: attention
            ),
            digest: nil,
            freshness: ContextFreshness(providers: [], overallConfidence: 1)
        )
    }
}
