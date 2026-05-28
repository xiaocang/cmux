import Foundation
import XCTest
@testable import CMUXContracts

final class WorkspaceContextContractsTests: XCTestCase {
    func testContextHashIgnoresUpdatedAt() {
        let first = Self.snapshot(updatedAt: Date(timeIntervalSince1970: 100))
        let second = Self.snapshot(updatedAt: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(first.contextHash, second.contextHash)
    }

    func testContextHashChangesWhenDerivedStateChanges() {
        let first = Self.snapshot(status: "running")
        let second = Self.snapshot(status: "waiting_user")

        XCTAssertNotEqual(first.contextHash, second.contextHash)
    }

    func testDigestUpdatePolicyUsesSemanticContextHash() {
        let previous = Self.snapshot(updatedAt: Date(timeIntervalSince1970: 100))
        let timestampOnlyChange = Self.snapshot(updatedAt: Date(timeIntervalSince1970: 200))
        let semanticChange = Self.snapshot(
            status: "waiting_user",
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let policy = WorkspaceDigestUpdatePolicy.semanticContextHash

        XCTAssertFalse(policy.shouldUpdate(previous: previous, next: timestampOnlyChange))
        XCTAssertTrue(policy.shouldUpdate(previous: previous, next: semanticChange))
    }

    func testProviderFreshnessMarksStaleAfterTTL() {
        let now = Date(timeIntervalSince1970: 1_000)
        let provider = ProviderFreshness(
            providerId: "agent_session",
            lastCollectedAt: now.addingTimeInterval(-61),
            ttlSeconds: 60,
            stale: false,
            error: nil,
            confidence: 1
        )

        let evaluated = provider.evaluated(at: now)

        XCTAssertTrue(evaluated.stale)
        XCTAssertEqual(evaluated.confidence, 0.5)
    }

    func testWorkspaceSnapshotCodableRoundTripPreservesContextHash() throws {
        let snapshot = Self.snapshot()

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.contextHash, snapshot.contextHash)
    }

    func testAssistantWorkingContextCodableRoundTripPreservesNestedSnapshots() throws {
        let snapshot = Self.snapshot()
        let suggestionId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let rankingId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let context = AssistantWorkingContext(
            activeWorkspaceId: snapshot.workspaceId,
            snapshots: [snapshot],
            freshness: snapshot.freshness,
            activeSuggestions: [
                ProactiveSuggestion(
                    id: suggestionId,
                    workspaceId: snapshot.workspaceId,
                    type: "review_agent_waiting_user",
                    title: "Review agent output",
                    reason: "Agent is waiting for review.",
                    confidence: 0.9,
                    createdAt: Date(timeIntervalSince1970: 110)
                ),
            ],
            latestRanking: RankingSnapshot(
                id: rankingId,
                updatedAt: Date(timeIntervalSince1970: 120),
                items: [
                    RankingSnapshot.Item(
                        workspaceId: snapshot.workspaceId,
                        rank: 1,
                        score: 80,
                        reason: "Needs review"
                    ),
                ]
            )
        )

        let data = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(AssistantWorkingContext.self, from: data)

        XCTAssertEqual(decoded, context)
    }

    private static func snapshot(
        status: String = "running",
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            workspaceId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            version: 1,
            updatedAt: updatedAt,
            context: NormalizedWorkspaceContext(
                title: "API fix",
                selected: true,
                directory: "/tmp/api",
                listRevision: 1,
                nativeOrder: 0,
                pinned: false,
                locked: false,
                customColor: nil,
                panelCount: 1,
                pullRequestCount: 1,
                stalePullRequestCount: 0
            ),
            derived: DerivedWorkspaceState(
                status: status,
                priorityScore: 80,
                rankReason: "Needs review",
                nextAction: "Review agent output",
                userAttentionNeeded: 0.9
            ),
            digest: WorkspaceDigest(
                summary: "Agent is waiting for review.",
                generatedAt: Date(timeIntervalSince1970: 90)
            ),
            freshness: ContextFreshness(
                providers: [],
                overallConfidence: 1
            )
        )
    }
}
