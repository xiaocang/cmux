import Foundation
import XCTest
@testable import CMUXActions

final class SemanticActionGatewayTests: XCTestCase {
    func testGatewayExecutesAllowedIntentAndAudits() async throws {
        let workspaceId = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let now = Date(timeIntervalSince1970: 2_000)
        let intent = makeApplySortIntent(
            workspaceIds: [workspaceId],
            snapshotUpdatedAt: now,
            createdAt: now
        )
        let executor = RecordingActionExecutor()
        let auditLog = RecordingActionAuditLog()
        let gateway = SemanticActionGateway(
            reviewers: [
                ActionArgumentReviewer(),
                ActionFreshnessReviewer(maxSnapshotAge: 120, now: now),
            ],
            executor: executor,
            auditLog: auditLog
        )

        let result = try await gateway.submit(intent)

        XCTAssertEqual(result.decision, .allow)
        XCTAssertTrue(result.executed)
        XCTAssertEqual(result.executionResult?.payload["kind"], CmuxActionKind.applySort.rawValue)
        let executedIntentIds = await executor.executedIntentIds()
        let reviewedIntentIds = await auditLog.reviewedIntentIds()
        let auditExecutedIntentIds = await auditLog.executedIntentIds()
        XCTAssertEqual(executedIntentIds, [intent.id])
        XCTAssertEqual(reviewedIntentIds, [intent.id])
        XCTAssertEqual(auditExecutedIntentIds, [intent.id])
    }

    func testGatewayRequiresConfirmationForStaleSnapshotAndSkipsExecution() async throws {
        let workspaceId = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let intent = makeApplySortIntent(
            workspaceIds: [workspaceId],
            snapshotUpdatedAt: Date(timeIntervalSince1970: 2_000),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let executor = RecordingActionExecutor()
        let auditLog = RecordingActionAuditLog()
        let gateway = SemanticActionGateway(
            reviewers: [
                ActionArgumentReviewer(),
                ActionFreshnessReviewer(
                    maxSnapshotAge: 120,
                    now: Date(timeIntervalSince1970: 2_300)
                ),
            ],
            executor: executor,
            auditLog: auditLog
        )

        let result = try await gateway.submit(intent)

        XCTAssertEqual(result.decision, .requireConfirmation)
        XCTAssertEqual(result.reasons, ["stale snapshot evidence"])
        XCTAssertFalse(result.executed)
        let executedIntentIds = await executor.executedIntentIds()
        let reviewedIntentIds = await auditLog.reviewedIntentIds()
        let auditExecutedIntentIds = await auditLog.executedIntentIds()
        XCTAssertEqual(executedIntentIds, [])
        XCTAssertEqual(reviewedIntentIds, [intent.id])
        XCTAssertEqual(auditExecutedIntentIds, [])
    }

    func testGatewayDeniesInvalidActionArgumentsAndSkipsExecution() async throws {
        let workspaceId = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
        let now = Date(timeIntervalSince1970: 2_000)
        let intent = makeApplySortIntent(
            workspaceIds: [workspaceId, workspaceId],
            snapshotUpdatedAt: now,
            createdAt: now
        )
        let executor = RecordingActionExecutor()
        let auditLog = RecordingActionAuditLog()
        let gateway = SemanticActionGateway(
            reviewers: [ActionArgumentReviewer()],
            executor: executor,
            auditLog: auditLog
        )

        let result = try await gateway.submit(intent)

        XCTAssertEqual(result.decision, .deny)
        XCTAssertEqual(result.reasons, ["duplicate workspace target"])
        XCTAssertFalse(result.executed)
        let executedIntentIds = await executor.executedIntentIds()
        let reviewedIntentIds = await auditLog.reviewedIntentIds()
        let auditExecutedIntentIds = await auditLog.executedIntentIds()
        XCTAssertEqual(executedIntentIds, [])
        XCTAssertEqual(reviewedIntentIds, [intent.id])
        XCTAssertEqual(auditExecutedIntentIds, [])
    }

    func testMemoryWriteDoesNotRequireSnapshotEvidence() {
        let intent = ActionIntent(
            id: UUID(),
            requestedBy: ActionRequester(id: "test", route: "remember_preference"),
            kind: .writeMemory,
            arguments: ["domain": "free_sort", "text": "Keep CI failures high priority"],
            evidence: ActionEvidence(snapshotVersions: [:], snapshotUpdatedAt: [:]),
            createdAt: Date()
        )

        XCTAssertNil(ActionArgumentReviewer.review(intent))
        XCTAssertNil(ActionFreshnessReviewer.review(intent, maxSnapshotAge: 120, now: Date()))
    }

    func testSuggestionActionsRequireSuggestionIdAndSnapshotEvidence() {
        let workspaceId = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let suggestionId = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let now = Date(timeIntervalSince1970: 1_000)
        let intent = ActionIntent(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            requestedBy: ActionRequester(id: "test"),
            kind: .acceptSuggestion,
            arguments: [
                "suggestionId": suggestionId.uuidString,
                "workspaceId": workspaceId.uuidString,
            ],
            evidence: ActionEvidence(
                snapshotVersions: [workspaceId: 1],
                snapshotUpdatedAt: [workspaceId: now],
                suggestionId: suggestionId
            ),
            createdAt: now
        )

        XCTAssertNil(ActionArgumentReviewer.review(intent))
        XCTAssertNil(ActionFreshnessReviewer.review(intent, maxSnapshotAge: 120, now: now))

        var missingEvidence = intent
        missingEvidence.evidence = ActionEvidence(
            snapshotVersions: [:],
            snapshotUpdatedAt: [:],
            suggestionId: suggestionId
        )
        XCTAssertEqual(
            ActionArgumentReviewer.review(missingEvidence),
            SemanticReviewSignal(
                decision: .requireConfirmation,
                reason: "missing snapshot evidence for action target"
            )
        )
    }

    func testSuggestionActionDeniesInvalidSuggestionId() {
        let workspaceId = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let intent = ActionIntent(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
            requestedBy: ActionRequester(id: "test"),
            kind: .dismissSuggestion,
            arguments: [
                "suggestionId": "not-a-uuid",
                "workspaceId": workspaceId.uuidString,
            ],
            evidence: ActionEvidence(
                snapshotVersions: [workspaceId: 1],
                snapshotUpdatedAt: [workspaceId: Date(timeIntervalSince1970: 1_000)]
            ),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(
            ActionArgumentReviewer.review(intent),
            SemanticReviewSignal(decision: .deny, reason: "invalid suggestionId argument")
        )
    }

    func testPinAndLockActionsRequireBooleanArgumentsAndSnapshotEvidence() {
        let workspaceId = UUID(uuidString: "10000000-0000-0000-0000-000000000006")!
        let now = Date(timeIntervalSince1970: 1_000)
        let evidence = ActionEvidence(
            snapshotVersions: [workspaceId: 1],
            snapshotUpdatedAt: [workspaceId: now]
        )
        let pin = ActionIntent(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000007")!,
            requestedBy: ActionRequester(id: "test"),
            kind: .pinWorkspace,
            arguments: ["itemId": workspaceId.uuidString, "pinned": "true"],
            evidence: evidence,
            createdAt: now
        )
        let lock = ActionIntent(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000008")!,
            requestedBy: ActionRequester(id: "test"),
            kind: .lockList,
            arguments: ["itemId": workspaceId.uuidString, "locked": "false"],
            evidence: evidence,
            createdAt: now
        )

        XCTAssertNil(ActionArgumentReviewer.review(pin))
        XCTAssertNil(ActionArgumentReviewer.review(lock))

        var missingEvidence = pin
        missingEvidence.evidence = ActionEvidence(snapshotVersions: [:], snapshotUpdatedAt: [:])
        XCTAssertEqual(
            ActionArgumentReviewer.review(missingEvidence),
            SemanticReviewSignal(
                decision: .requireConfirmation,
                reason: "missing snapshot evidence for action target"
            )
        )

        var invalidBoolean = lock
        invalidBoolean.arguments["locked"] = "sometimes"
        XCTAssertEqual(
            ActionArgumentReviewer.review(invalidBoolean),
            SemanticReviewSignal(decision: .deny, reason: "invalid locked argument")
        )
    }

    func testSwitchWorkspaceRequiresWorkspaceIdAndSnapshotEvidence() {
        let workspaceId = UUID(uuidString: "10000000-0000-0000-0000-000000000009")!
        let now = Date(timeIntervalSince1970: 1_000)
        let intent = ActionIntent(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000010")!,
            requestedBy: ActionRequester(id: "test"),
            kind: .switchWorkspace,
            arguments: ["workspaceId": workspaceId.uuidString],
            evidence: ActionEvidence(
                snapshotVersions: [workspaceId: 1],
                snapshotUpdatedAt: [workspaceId: now]
            ),
            createdAt: now
        )

        XCTAssertNil(ActionArgumentReviewer.review(intent))
        XCTAssertNil(ActionFreshnessReviewer.review(intent, maxSnapshotAge: 120, now: now))

        var missingEvidence = intent
        missingEvidence.evidence = ActionEvidence(snapshotVersions: [:], snapshotUpdatedAt: [:])
        XCTAssertEqual(
            ActionArgumentReviewer.review(missingEvidence),
            SemanticReviewSignal(
                decision: .requireConfirmation,
                reason: "missing snapshot evidence for action target"
            )
        )

        var invalidTarget = intent
        invalidTarget.arguments["workspaceId"] = "not-a-uuid"
        XCTAssertEqual(
            ActionArgumentReviewer.review(invalidTarget),
            SemanticReviewSignal(decision: .deny, reason: "invalid workspace target")
        )
    }

    private func makeApplySortIntent(
        workspaceIds: [UUID],
        snapshotUpdatedAt: Date,
        createdAt: Date
    ) -> ActionIntent {
        var snapshotVersions: [UUID: Int] = [:]
        var snapshotUpdatedAtByWorkspace: [UUID: Date] = [:]
        for workspaceId in workspaceIds {
            snapshotVersions[workspaceId] = 1
            snapshotUpdatedAtByWorkspace[workspaceId] = snapshotUpdatedAt
        }

        return ActionIntent(
            id: UUID(),
            requestedBy: ActionRequester(id: "test", route: "apply_sort"),
            kind: .applySort,
            arguments: [
                "patchId": UUID().uuidString,
                "itemIds": workspaceIds.map(\.uuidString).joined(separator: ","),
            ],
            evidence: ActionEvidence(
                snapshotVersions: snapshotVersions,
                snapshotUpdatedAt: snapshotUpdatedAtByWorkspace
            ),
            createdAt: createdAt
        )
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
}
