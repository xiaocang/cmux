import XCTest
@testable import CMUXContextAgent

final class ContextSchedulerTests: XCTestCase {
    func testSchedulerDeduplicatesByWorkspaceAndOrdersByPriority() async {
        let scheduler = ContextScheduler()
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        await scheduler.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "background",
            priority: .background,
            enqueuedAt: Date(timeIntervalSince1970: 10)
        ))
        await scheduler.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "visible",
            priority: .visible,
            enqueuedAt: Date(timeIntervalSince1970: 20)
        ))

        let jobs = await scheduler.nextBatch()

        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.reason, "visible")
    }

    func testDueProviderRefreshUsesAttentionLeaseCadence() async {
        let scheduler = ContextScheduler()
        let hotId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let coldId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let policy = ContextProviderRefreshPolicy(
            providerId: "git",
            hotIntervalSeconds: 20,
            visibleIntervalSeconds: 60,
            coldIntervalSeconds: 300
        )

        await scheduler.setLease(.hot, for: hotId)
        await scheduler.setLease(.cold, for: coldId)
        await scheduler.markProviderCollected("git", workspace: hotId, at: Date(timeIntervalSince1970: 0))
        await scheduler.markProviderCollected("git", workspace: coldId, at: Date(timeIntervalSince1970: 0))

        await scheduler.enqueueDueProviderRefreshes(
            policy: policy,
            workspaceIds: [hotId, coldId],
            now: Date(timeIntervalSince1970: 21),
            reason: "cadence"
        )

        let jobs = await scheduler.nextBatch()

        XCTAssertEqual(jobs.map(\.workspaceId), [hotId])
        XCTAssertEqual(jobs.map(\.providerId), ["git"])
        XCTAssertEqual(jobs.map(\.priority), [.userInitiated])
    }

    func testProviderSignalDebouncesBurst() async {
        let scheduler = ContextScheduler()
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

        for offset in [0.0, 0.2, 0.4, 0.8] {
            await scheduler.enqueueProviderSignal(
                providerId: "git",
                workspaceId: workspaceId,
                reason: "git.changed",
                enqueuedAt: Date(timeIntervalSince1970: offset),
                debounceSeconds: 2
            )
        }

        let jobs = await scheduler.nextBatch()

        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.workspaceId, workspaceId)
        XCTAssertEqual(jobs.first?.providerId, "git")
        XCTAssertEqual(jobs.first?.reason, "git.changed")
    }
}
