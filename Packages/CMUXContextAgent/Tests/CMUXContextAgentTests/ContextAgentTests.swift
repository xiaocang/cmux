import CMUXContracts
import XCTest
@testable import CMUXContextAgent

final class ContextAgentTests: XCTestCase {
    func testSchedulerUsesAttentionLeaseSpecificRefreshIntervals() async throws {
        let hotId = UUID(uuidString: "31000000-0000-0000-0000-000000000001")!
        let visibleId = UUID(uuidString: "31000000-0000-0000-0000-000000000002")!
        let coldId = UUID(uuidString: "31000000-0000-0000-0000-000000000003")!
        let scheduler = ContextScheduler()
        let lastCollectedAt = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 1_025)
        let policy = ContextProviderRefreshPolicy(
            providerId: "github_context",
            hotIntervalSeconds: 20,
            visibleIntervalSeconds: 60,
            coldIntervalSeconds: 300,
            debounceSeconds: 2
        )

        await scheduler.setLease(.hot, for: hotId)
        await scheduler.setLease(.visible, for: visibleId)
        await scheduler.setLease(.cold, for: coldId)
        for workspaceId in [hotId, visibleId, coldId] {
            await scheduler.markProviderCollected(
                policy.providerId,
                workspace: workspaceId,
                at: lastCollectedAt
            )
        }

        await scheduler.enqueueDueProviderRefreshes(
            policy: policy,
            workspaceIds: [hotId, visibleId, coldId],
            now: now,
            reason: "scheduled_refresh"
        )

        let jobs = await scheduler.pendingJobs()
        XCTAssertEqual(jobs.map(\.workspaceId), [hotId])
        XCTAssertEqual(jobs.first?.priority, .userInitiated)
        XCTAssertEqual(jobs.first?.providerId, "github_context")
    }

    func testSchedulerDebouncesProviderSignalsPerWorkspaceAndProvider() async throws {
        let workspaceId = UUID(uuidString: "32000000-0000-0000-0000-000000000001")!
        let scheduler = ContextScheduler()

        await scheduler.enqueueProviderSignal(
            providerId: "github_context",
            workspaceId: workspaceId,
            reason: "first",
            enqueuedAt: Date(timeIntervalSince1970: 2_000),
            debounceSeconds: 5
        )
        await scheduler.enqueueProviderSignal(
            providerId: "github_context",
            workspaceId: workspaceId,
            reason: "debounced",
            enqueuedAt: Date(timeIntervalSince1970: 2_002),
            debounceSeconds: 5
        )

        var jobs = await scheduler.pendingJobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.reason, "first")

        await scheduler.enqueueProviderSignal(
            providerId: "github_context",
            workspaceId: workspaceId,
            reason: "after_debounce",
            enqueuedAt: Date(timeIntervalSince1970: 2_006),
            debounceSeconds: 5
        )

        jobs = await scheduler.pendingJobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.reason, "after_debounce")
        XCTAssertEqual(jobs.first?.enqueuedAt, Date(timeIntervalSince1970: 2_006))
    }

    func testSchedulerKeepsHighestPriorityForDuplicateProviderJob() async throws {
        let workspaceId = UUID(uuidString: "33000000-0000-0000-0000-000000000001")!
        let scheduler = ContextScheduler()

        await scheduler.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "background",
            priority: .background,
            enqueuedAt: Date(timeIntervalSince1970: 3_000),
            providerId: "summary_priority"
        ))
        await scheduler.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "user_initiated",
            priority: .userInitiated,
            enqueuedAt: Date(timeIntervalSince1970: 3_001),
            providerId: "summary_priority"
        ))
        await scheduler.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "later_background",
            priority: .background,
            enqueuedAt: Date(timeIntervalSince1970: 3_002),
            providerId: "summary_priority"
        ))

        let jobs = await scheduler.pendingJobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.reason, "user_initiated")
        XCTAssertEqual(jobs.first?.priority, .userInitiated)
    }

    func testAssistantQueryEventRunsAvailableProvidersAndMergesSnapshots() async throws {
        let workspaceId = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let now = Date(timeIntervalSince1970: 2_000)
        let store = RecordingSnapshotStore()
        let scheduler = ContextScheduler()
        let providerRunStore = ProviderRunStore()
        let agent = ContextAgent(
            snapshotStore: store,
            scheduler: scheduler,
            providerRunStore: providerRunStore,
            providers: [
                FixtureProvider(providerId: "list_state", version: 1, status: "visible"),
                FixtureProvider(providerId: "github_context", version: 2, status: "waiting_user"),
            ]
        )

        await agent.handle(ContextAgentEvent(
            name: "assistant.query_started",
            workspaceId: workspaceId,
            occurredAt: now,
            payload: ["reason": "test"]
        ))
        let lease = await scheduler.lease(for: workspaceId)
        XCTAssertEqual(lease, .hot)

        let result = await agent.runScheduledBatch()
        let storedSnapshot = await store.snapshot(workspaceId)
        let snapshot = try XCTUnwrap(storedSnapshot)
        let records = await providerRunStore.allRecords()
        let queuedJobCount = await agent.queuedJobCount()

        XCTAssertEqual(Set(result.updatedWorkspaceIds), [workspaceId])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(snapshot.workspaceId, workspaceId)
        XCTAssertEqual(snapshot.version, 2)
        XCTAssertEqual(snapshot.derived.status, "waiting_user")
        XCTAssertEqual(snapshot.freshness.providers.map(\.providerId).sorted(), [
            "github_context",
            "list_state",
        ])
        XCTAssertEqual(records.map(\.providerId).sorted(), [
            "github_context",
            "list_state",
        ])
        XCTAssertTrue(records.allSatisfy(\.success))
        XCTAssertEqual(queuedJobCount, 0)
    }

    func testAssistantQueryEventPromotesRelatedWorkspacesToHotAttentionLease() async throws {
        let activeWorkspaceId = UUID(uuidString: "30000000-0000-0000-0000-000000000011")!
        let relatedWorkspaceId = UUID(uuidString: "30000000-0000-0000-0000-000000000012")!
        let now = Date(timeIntervalSince1970: 2_050)
        let scheduler = ContextScheduler()
        let agent = ContextAgent(
            snapshotStore: RecordingSnapshotStore(),
            scheduler: scheduler,
            providers: [
                FixtureProvider(providerId: "list_state", version: 1, status: "visible"),
                FixtureProvider(providerId: "summary_priority", version: 2, status: "ranked"),
                FixtureProvider(providerId: "git_context", version: 3, status: "git"),
            ]
        )

        await agent.handle(ContextAgentEvent(
            name: "assistant.query_started",
            workspaceId: activeWorkspaceId,
            relatedWorkspaceIds: [relatedWorkspaceId, activeWorkspaceId, relatedWorkspaceId],
            occurredAt: now,
            payload: ["reason": "ask"]
        ))

        let jobs = await scheduler.pendingJobs()
        let activeLease = await scheduler.lease(for: activeWorkspaceId)
        let relatedLease = await scheduler.lease(for: relatedWorkspaceId)
        XCTAssertEqual(activeLease, .hot)
        XCTAssertEqual(relatedLease, .hot)
        XCTAssertEqual(Set(jobs.map(\.workspaceId)), Set([activeWorkspaceId, relatedWorkspaceId]))
        XCTAssertEqual(Set(jobs.map(\.providerId)), Set([
            Optional.some("list_state"),
            Optional.some("summary_priority"),
        ]))
        XCTAssertTrue(jobs.allSatisfy { $0.priority == .userInitiated })
        XCTAssertTrue(jobs.allSatisfy { $0.reason == "assistant.query_started" })
        XCTAssertFalse(jobs.map(\.providerId).contains("git_context"))
    }

    func testGitChangedEventRoutesToGitContextProviderSlice() async throws {
        let workspaceId = UUID(uuidString: "30000000-0000-0000-0000-000000000004")!
        let now = Date(timeIntervalSince1970: 2_100)
        let store = RecordingSnapshotStore()
        let scheduler = ContextScheduler()
        let providerRunStore = ProviderRunStore()
        let agent = ContextAgent(
            snapshotStore: store,
            scheduler: scheduler,
            providerRunStore: providerRunStore,
            providers: [
                FixtureProvider(providerId: "git_context", version: 3, status: "git_changed"),
                FixtureProvider(providerId: "summary_priority", version: 4, status: "ranked"),
                FixtureProvider(providerId: "github_context", version: 5, status: "github"),
            ]
        )

        await agent.handle(ContextAgentEvent(
            name: "git.changed",
            workspaceId: workspaceId,
            occurredAt: now,
            payload: ["branch": "feature/context-agent"]
        ))

        let queuedJobs = await scheduler.pendingJobs()
        XCTAssertEqual(queuedJobs.map(\.providerId), [
            Optional.some("git_context"),
            Optional.some("summary_priority"),
        ])

        let result = await agent.runScheduledBatch()
        let records = await providerRunStore.allRecords()
        let storedSnapshot = await store.snapshot(workspaceId)
        let snapshot = try XCTUnwrap(storedSnapshot)

        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(Set(result.updatedWorkspaceIds), Set([workspaceId]))
        XCTAssertEqual(records.map(\.providerId).sorted(), [
            "git_context",
            "summary_priority",
        ])
        XCTAssertEqual(snapshot.freshness.providers.map(\.providerId).sorted(), [
            "git_context",
            "summary_priority",
        ])
        XCTAssertFalse(records.map(\.providerId).contains("github_context"))
    }

    func testAgentStopEventRoutesToAgentSessionProviderOnly() async throws {
        let workspaceId = UUID(uuidString: "30000000-0000-0000-0000-000000000005")!
        let now = Date(timeIntervalSince1970: 2_150)
        let scheduler = ContextScheduler()
        let agent = ContextAgent(
            snapshotStore: RecordingSnapshotStore(),
            scheduler: scheduler,
            providers: [
                FixtureProvider(providerId: "agent_session", version: 6, status: "agent_completed"),
                FixtureProvider(providerId: "summary_priority", version: 7, status: "ranked"),
            ]
        )

        await agent.handle(ContextAgentEvent(
            name: "agent.hook.Stop",
            workspaceId: workspaceId,
            occurredAt: now,
            payload: ["hook_event_name": "Stop"]
        ))

        let queuedJobs = await scheduler.pendingJobs()
        XCTAssertEqual(queuedJobs.map(\.providerId), [
            Optional.some("agent_session"),
        ])
        XCTAssertEqual(queuedJobs.first?.priority, .visible)
        let lease = await scheduler.lease(for: workspaceId)
        XCTAssertEqual(lease, .visible)
    }

    func testProactiveSignalReportedEventRoutesToAgentSessionProviderOnly() async throws {
        let workspaceId = UUID(uuidString: "30000000-0000-0000-0000-000000000007")!
        let now = Date(timeIntervalSince1970: 2_170)
        let scheduler = ContextScheduler()
        let agent = ContextAgent(
            snapshotStore: RecordingSnapshotStore(),
            scheduler: scheduler,
            providers: [
                FixtureProvider(providerId: "agent_session", version: 6, status: "needs_attention"),
                FixtureProvider(providerId: "summary_priority", version: 7, status: "ranked"),
            ]
        )

        await agent.handle(ContextAgentEvent(
            name: ContextAgentEvent.proactiveSignalReportedName,
            workspaceId: workspaceId,
            occurredAt: now,
            payload: ["status": "needs_attention"]
        ))

        let queuedJobs = await scheduler.pendingJobs()
        XCTAssertEqual(queuedJobs.map(\.providerId), [
            Optional.some("agent_session"),
        ])
        XCTAssertEqual(queuedJobs.first?.priority, .visible)
        let lease = await scheduler.lease(for: workspaceId)
        XCTAssertEqual(lease, .visible)
    }

    func testManualContextCollectRoutesRequestedProviderAngles() async throws {
        let workspaceId = UUID(uuidString: "30000000-0000-0000-0000-000000000006")!
        let scheduler = ContextScheduler()
        let agent = ContextAgent(
            snapshotStore: RecordingSnapshotStore(),
            scheduler: scheduler,
            providers: [
                FixtureProvider(providerId: "agent_session", version: 6, status: "agent_completed"),
                FixtureProvider(providerId: "notification_context", version: 7, status: "notification"),
                FixtureProvider(providerId: "summary_priority", version: 8, status: "ranked"),
            ]
        )

        await agent.handle(ContextAgentEvent(
            name: "assistant.context_collect.requested",
            workspaceId: workspaceId,
            occurredAt: Date(timeIntervalSince1970: 2_160),
            payload: ["providerIds": "agent_session notification_context"]
        ))

        let queuedJobs = await scheduler.pendingJobs()
        XCTAssertEqual(queuedJobs.map(\.providerId), [
            Optional.some("agent_session"),
            Optional.some("notification_context"),
        ])
    }

    func testEventLogDecodesJSONLinesForReplay() throws {
        let data = Data("""
        {"name":"assistant.query_started","workspaceId":"30000000-0000-0000-0000-000000000002","relatedWorkspaceIds":["30000000-0000-0000-0000-000000000003"],"occurredAt":"2026-05-23T10:00:00Z","payload":{"reason":"ask"}}
        {"name":"sidebar.metadata.updated","workspaceId":"30000000-0000-0000-0000-000000000003","occurredAt":"2026-05-23T10:00:01.000Z","payload":{"providerId":"github_context"}}
        """.utf8)

        let events = try ContextAgentEventLog.decodeJSONLines(data)

        XCTAssertEqual(events.map(\.name), [
            "assistant.query_started",
            "sidebar.metadata.updated",
        ])
        XCTAssertEqual(events.first?.affectedWorkspaceIds, [
            UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
        ])
        XCTAssertEqual(events.last?.payload["providerId"], "github_context")
    }

    func testReplayEventLogPayloadProducesWaitingUserSnapshot() async throws {
        let data = Data("""
        {"name":"dev.cmux.agent.message_appended.v1","workspaceId":"8B8B8B8B-8B8B-8B8B-8B8B-8B8B8B8B8B8B","occurredAt":"2026-05-23T10:00:00Z","payload":{"title":"API fix","status":"waiting_user","priorityScore":"91","userAttentionNeeded":"0.91","rankReason":"Agent is waiting for review","nextAction":"Review agent output","summary":"Agent is waiting for user review.","nativeOrder":"0","pullRequestCount":"1","stalePullRequestCount":"0"}}
        """.utf8)
        let events = try ContextAgentEventLog.decodeJSONLines(data)
        let store = RecordingSnapshotStore()
        let providerRunStore = ProviderRunStore()
        let agent = ContextAgent(
            snapshotStore: store,
            providerRunStore: providerRunStore,
            providers: [EventPayloadProvider()]
        )

        for event in events {
            await agent.handle(event)
        }
        let result = await agent.runScheduledBatch()

        let workspaceId = try XCTUnwrap(events.first?.workspaceId)
        let storedSnapshot = await store.snapshot(workspaceId)
        let snapshot = try XCTUnwrap(storedSnapshot)
        let records = await providerRunStore.records(for: workspaceId)

        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.updatedWorkspaceIds, [workspaceId])
        XCTAssertEqual(snapshot.context.title, "API fix")
        XCTAssertEqual(snapshot.context.nativeOrder, 0)
        XCTAssertEqual(snapshot.context.pullRequestCount, 1)
        XCTAssertEqual(snapshot.derived.status, "waiting_user")
        XCTAssertEqual(snapshot.derived.priorityScore, 91)
        XCTAssertEqual(snapshot.derived.nextAction, "Review agent output")
        XCTAssertGreaterThan(snapshot.derived.userAttentionNeeded, 0.8)
        XCTAssertEqual(records.map(\.providerId), ["agent_session"])
        XCTAssertTrue(records.first?.success ?? false)
        XCTAssertEqual(records.first?.snapshotVersion, snapshot.version)
    }

    func testProviderFailureRecordsRunMetadataAndDoesNotWriteSnapshot() async throws {
        let workspaceId = UUID(uuidString: "34000000-0000-0000-0000-000000000001")!
        let store = RecordingSnapshotStore()
        let providerRunStore = ProviderRunStore()
        let agent = ContextAgent(
            snapshotStore: store,
            providerRunStore: providerRunStore,
            providers: [FailingProvider()]
        )

        await agent.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "provider_due",
            priority: .visible,
            enqueuedAt: Date(timeIntervalSince1970: 3_000),
            providerId: "failing_provider"
        ))

        let result = await agent.runScheduledBatch()
        let records = await providerRunStore.records(for: workspaceId)
        let record = try XCTUnwrap(records.first)
        let storedSnapshot = await store.snapshot(workspaceId)

        XCTAssertEqual(result.updatedWorkspaceIds, [])
        XCTAssertEqual(result.failures.map(\.providerId), ["failing_provider"])
        XCTAssertTrue(result.failures.first?.message.contains("fixture provider failed") ?? false)
        XCTAssertNil(storedSnapshot)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.providerId, "failing_provider")
        XCTAssertEqual(record.reason, "provider_due")
        XCTAssertFalse(record.success)
        XCTAssertNil(record.snapshotVersion)
        XCTAssertTrue(record.errorMessage?.contains("fixture provider failed") ?? false)
    }
}

private actor RecordingSnapshotStore: WorkspaceSnapshotStoring {
    private var snapshotsByWorkspaceId: [UUID: WorkspaceSnapshot] = [:]

    func mergeProviderSnapshot(
        _ snapshot: WorkspaceSnapshot,
        activeWorkspaceId _: UUID?
    ) async -> WorkspaceSnapshot {
        let merged = snapshotsByWorkspaceId[snapshot.workspaceId]
            .map { $0.mergingProviderOutput(snapshot) }
            ?? snapshot
        snapshotsByWorkspaceId[snapshot.workspaceId] = merged
        return merged
    }

    func snapshot(_ workspaceId: UUID) -> WorkspaceSnapshot? {
        snapshotsByWorkspaceId[workspaceId]
    }
}

private struct FixtureProvider: WorkspaceSnapshotProviding {
    let providerId: String
    let version: Int
    let status: String

    func snapshot(for job: ContextRefreshJob) async throws -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            workspaceId: job.workspaceId,
            version: version,
            updatedAt: job.enqueuedAt,
            context: NormalizedWorkspaceContext(
                title: "Workspace \(version)",
                selected: true,
                directory: "/tmp/workspace-\(version)",
                listRevision: version,
                nativeOrder: version,
                pinned: false,
                locked: false,
                customColor: nil,
                panelCount: version,
                pullRequestCount: version,
                stalePullRequestCount: 0
            ),
            derived: DerivedWorkspaceState(
                status: status,
                priorityScore: Double(version * 10),
                rankReason: providerId,
                nextAction: nil,
                userAttentionNeeded: min(Double(version) / 10, 1)
            ),
            digest: nil,
            freshness: ContextFreshness(
                providers: [
                    ProviderFreshness(
                        providerId: providerId,
                        lastCollectedAt: job.enqueuedAt,
                        ttlSeconds: 120,
                        stale: false,
                        error: nil,
                        confidence: 1
                    ),
                ],
                overallConfidence: 1
            )
        )
    }
}

private struct EventPayloadProvider: WorkspaceSnapshotProviding {
    let providerId = "agent_session"

    func snapshot(for job: ContextRefreshJob) async throws -> WorkspaceSnapshot {
        let nativeOrder = Int(job.payload["nativeOrder"] ?? "") ?? 0
        let priorityScore = Double(job.payload["priorityScore"] ?? "")
        let attention = Double(job.payload["userAttentionNeeded"] ?? "") ?? 0
        return WorkspaceSnapshot(
            workspaceId: job.workspaceId,
            version: 1,
            updatedAt: job.enqueuedAt,
            context: NormalizedWorkspaceContext(
                title: job.payload["title"] ?? "Workspace",
                selected: true,
                directory: nil,
                listRevision: nativeOrder + 1,
                nativeOrder: nativeOrder,
                pinned: false,
                locked: false,
                customColor: nil,
                panelCount: 1,
                pullRequestCount: Int(job.payload["pullRequestCount"] ?? "") ?? 0,
                stalePullRequestCount: Int(job.payload["stalePullRequestCount"] ?? "") ?? 0
            ),
            derived: DerivedWorkspaceState(
                status: job.payload["status"] ?? "unknown",
                priorityScore: priorityScore,
                rankReason: job.payload["rankReason"],
                nextAction: job.payload["nextAction"],
                userAttentionNeeded: attention
            ),
            digest: WorkspaceDigest(
                summary: job.payload["summary"] ?? "",
                generatedAt: job.enqueuedAt
            ),
            freshness: ContextFreshness(
                providers: [
                    ProviderFreshness(
                        providerId: providerId,
                        lastCollectedAt: job.enqueuedAt,
                        ttlSeconds: 120,
                        stale: false,
                        error: nil,
                        confidence: 1
                    ),
                ],
                overallConfidence: 1
            )
        )
    }
}

private struct FailingProvider: WorkspaceSnapshotProviding {
    let providerId = "failing_provider"

    func snapshot(for _: ContextRefreshJob) async throws -> WorkspaceSnapshot {
        throw FailingProviderError.fixtureFailure
    }
}

private enum FailingProviderError: Error, CustomStringConvertible {
    case fixtureFailure

    var description: String {
        "fixture provider failed"
    }
}
