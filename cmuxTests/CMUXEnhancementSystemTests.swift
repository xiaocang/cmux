import AppKit
import XCTest
import CMUXEnhancementAPI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

fileprivate func withSavedPullRequestDebounceSettings(_ body: () throws -> Void) throws {
    let defaults = UserDefaults.standard
    let keys = [
        SidebarPullRequestShellDebounceSettings.enabledKey,
        SidebarPullRequestShellDebounceSettings.delaySecondsKey,
    ]
    let savedValues = keys.map { ($0, defaults.object(forKey: $0)) }
    defer {
        for (key, value) in savedValues {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
    try body()
}

final class CMUXEnhancementHostTests: XCTestCase {
    func testActivatesInOrderAndDeactivatesInReverseOrder() throws {
        let context = TestEnhancementContext()
        let logger = TestEnhancementLogger()
        let host = CMUXEnhancementHost(context: context, logger: logger)
        let recorder = EnhancementEventRecorder()

        let first = RecordingEnhancement(id: "first", recorder: recorder)
        let second = RecordingEnhancement(id: "second", recorder: recorder)

        try host.activate([first, second])
        XCTAssertEqual(host.activatedEnhancementIds, ["first", "second"])

        host.deactivate()
        XCTAssertEqual(recorder.events, [
            "activate:first",
            "activate:second",
            "deactivate:second",
            "deactivate:first",
        ])
        XCTAssertEqual(host.activatedEnhancementIds, [])
    }

    func testActivationFailureDeactivatesPreviouslyActivatedEnhancements() {
        let context = TestEnhancementContext()
        let logger = TestEnhancementLogger()
        let host = CMUXEnhancementHost(context: context, logger: logger)
        let recorder = EnhancementEventRecorder()

        let first = RecordingEnhancement(id: "first", recorder: recorder)
        let failing = RecordingEnhancement(id: "failing", recorder: recorder, activationError: EnhancementTestError.activationFailed)
        let skipped = RecordingEnhancement(id: "skipped", recorder: recorder)

        XCTAssertThrowsError(try host.activate([first, failing, skipped]))
        XCTAssertEqual(recorder.events, [
            "activate:first",
            "activate:failing",
            "deactivate:first",
        ])
        XCTAssertEqual(host.activatedEnhancementIds, [])
    }

    func testUnsupportedPermissionFailsAndDeactivatesPreviouslyActivatedEnhancements() {
        let context = TestEnhancementContext()
        let logger = TestEnhancementLogger()
        let host = CMUXEnhancementHost(context: context, logger: logger)
        let recorder = EnhancementEventRecorder()

        let first = RecordingEnhancement(id: "first", recorder: recorder)
        let unsupported = RecordingEnhancement(
            id: "unsupported",
            recorder: recorder,
            permissions: ["screen:capture"]
        )

        XCTAssertThrowsError(try host.activate([first, unsupported])) { error in
            XCTAssertEqual(
                error as? CMUXEnhancementHost.HostError,
                .unsupportedPermissions(enhancementId: "unsupported", permissions: ["screen:capture"])
            )
        }
        XCTAssertEqual(recorder.events, [
            "activate:first",
            "deactivate:first",
        ])
        XCTAssertEqual(host.activatedEnhancementIds, [])
    }

    func testActivationHonorsManifestTrigger() throws {
        let context = TestEnhancementContext()
        let logger = TestEnhancementLogger()
        let host = CMUXEnhancementHost(context: context, logger: logger)
        let recorder = EnhancementEventRecorder()

        let defaultActivation = RecordingEnhancement(id: "default", recorder: recorder)
        let appStart = RecordingEnhancement(id: "app", recorder: recorder, activation: ["onAppStart"])
        let agentOnly = RecordingEnhancement(id: "agent", recorder: recorder, activation: ["onAgentEvent"])
        let unknownOnly = RecordingEnhancement(id: "unknown", recorder: recorder, activation: ["onSomethingElse"])

        try host.activate([defaultActivation, appStart, agentOnly, unknownOnly])

        XCTAssertEqual(host.activatedEnhancementIds, ["default", "app"])
        XCTAssertEqual(recorder.events, [
            "activate:default",
            "activate:app",
        ])

        try host.activate([defaultActivation, appStart, agentOnly, unknownOnly], trigger: .onAgentEvent)

        XCTAssertEqual(host.activatedEnhancementIds, ["default", "app", "agent"])
        XCTAssertEqual(recorder.events, [
            "activate:default",
            "activate:app",
            "activate:agent",
        ])
    }

    func testBuiltInEnhancementsRegisterInterceptorsAgainstRealAppContext() throws {
        try withSavedPullRequestDebounceSettings {
            UserDefaults.standard.set(true, forKey: SidebarPullRequestShellDebounceSettings.enabledKey)
            UserDefaults.standard.set(5, forKey: SidebarPullRequestShellDebounceSettings.delaySecondsKey)

            let logger = TestEnhancementLogger()
            let actions = CMUXAppEnhancementActionRegistry(logger: logger)
            let context = CMUXAppEnhancementContext(
                logger: logger,
                actions: actions,
                scheduler: CMUXDispatchEnhancementScheduler()
            )
            let githubService = CMUXGitHubEnhancementService()
            let host = CMUXEnhancementHost(context: context, logger: logger)
            defer {
                host.deactivate()
                githubService.resetQueuedRefreshes()
            }

            try host.activate(CMUXBuiltinEnhancements.make(
                githubService: githubService,
                tmuxPrefixService: CMUXTmuxPrefixService()
            ))

            XCTAssertEqual(host.activatedEnhancementIds, [
                "@cmux/enhancement-noop",
                "@cmux/enhancement-github",
                "@cmux/enhancement-tmux-leader",
            ])

            let request = CMUXGitHubPullRequestRefreshRequest(
                key: CMUXGitHubPullRequestRefreshKey(workspaceId: UUID(), panelId: UUID()),
                reason: "shellPrompt",
                target: CMUXGitHubPullRequestRefreshTarget(branch: "main", repoSlugs: ["owner/repo"]),
                bypassRepoCache: false
            )
            let handled = actions.dispatch(
                CMUXEnhancementAction(
                    id: CMUXGitHubEnhancementActionID.pullRequestRefresh,
                    source: "test",
                    payload: request
                )
            ) { _ in }

            XCTAssertTrue(handled)
            XCTAssertFalse(githubService.queuedRefreshesAreEmpty())

            host.deactivate()
            githubService.resetQueuedRefreshes()

            let handledAfterDeactivate = actions.dispatch(
                CMUXEnhancementAction(
                    id: CMUXGitHubEnhancementActionID.pullRequestRefresh,
                    source: "test",
                    payload: request
                )
            ) { _ in }

            XCTAssertFalse(handledAfterDeactivate)
            XCTAssertTrue(githubService.queuedRefreshesAreEmpty())
        }
    }

    func testDispatchEnhancementSchedulerCancelsAsyncAfterWork() {
        let queue = DispatchQueue(label: "com.cmux.tests.enhancement-scheduler")
        let scheduler = CMUXDispatchEnhancementScheduler(queue: queue)
        let cancelledWorkDidRun = expectation(description: "cancelled work should not run")
        cancelledWorkDidRun.isInverted = true

        let disposable = scheduler.asyncAfter(delay: 0.05) {
            cancelledWorkDidRun.fulfill()
        }
        disposable.dispose()

        wait(for: [cancelledWorkDidRun], timeout: 0.15)
    }
}

final class CMUXEnhancementActionRegistryTests: XCTestCase {
    func testActionRegistryOrdersInterceptorsByPriorityAndFallsBack() {
        let logger = TestEnhancementLogger()
        let registry = CMUXAppEnhancementActionRegistry(logger: logger)
        let recorder = ActionEventRecorder()

        registry.registerInterceptor(RecordingActionInterceptor(id: "low", priority: 10, recorder: recorder))
        registry.registerInterceptor(RecordingActionInterceptor(id: "high", priority: 90, recorder: recorder))

        let handled = registry.dispatch(
            CMUXEnhancementAction(id: "test.action", source: "test")
        ) { _ in
            recorder.events.append("fallback")
        }

        XCTAssertFalse(handled)
        XCTAssertEqual(recorder.events, ["intercept:high", "intercept:low", "fallback"])
    }

    func testActionRegistryStopsWhenInterceptorHandlesAction() {
        let logger = TestEnhancementLogger()
        let registry = CMUXAppEnhancementActionRegistry(logger: logger)
        let recorder = ActionEventRecorder()

        registry.registerInterceptor(RecordingActionInterceptor(id: "handled", priority: 90, disposition: .handled, recorder: recorder))
        registry.registerInterceptor(RecordingActionInterceptor(id: "skipped", priority: 10, recorder: recorder))

        let handled = registry.dispatch(
            CMUXEnhancementAction(id: "test.action", source: "test")
        ) { _ in
            recorder.events.append("fallback")
        }

        XCTAssertTrue(handled)
        XCTAssertEqual(recorder.events, ["intercept:handled"])
    }

    func testActionRegistryProceedChainsToLowerPriorityInterceptorsAndFallback() {
        let logger = TestEnhancementLogger()
        let registry = CMUXAppEnhancementActionRegistry(logger: logger)
        let recorder = ActionEventRecorder()

        registry.registerInterceptor(ProceedingActionInterceptor(recorder: recorder))
        registry.registerInterceptor(ParamRecordingActionInterceptor(id: "low", priority: 10, recorder: recorder))

        let handled = registry.dispatch(
            CMUXEnhancementAction(id: "test.action", source: "test", params: ["stage": "initial"])
        ) { action in
            recorder.events.append("fallback:\(action.params["stage"] as? String ?? "nil")")
        }

        XCTAssertTrue(handled)
        XCTAssertEqual(recorder.events, [
            "proceed:high",
            "intercept:low:proceeded",
            "fallback:proceeded",
        ])
    }

    func testActionRegistryFailOpenRunsFallbackWhenInterceptorThrows() {
        let logger = TestEnhancementLogger()
        let registry = CMUXAppEnhancementActionRegistry(logger: logger)
        var events: [String] = []

        registry.registerInterceptor(ThrowingActionInterceptor())

        let handled = registry.dispatch(
            CMUXEnhancementAction(id: "test.action", source: "test")
        ) { _ in
            events.append("fallback")
        }

        XCTAssertFalse(handled)
        XCTAssertEqual(events, ["fallback"])
        XCTAssertEqual(logger.errors.count, 1)
    }
}

final class CMUXGitHubEnhancementServiceTests: XCTestCase {
    func testQueuesSameTargetWithinFixedWindow() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: SidebarPullRequestShellDebounceSettings.enabledKey)
        defaults.set(5, forKey: SidebarPullRequestShellDebounceSettings.delaySecondsKey)

        let service = CMUXGitHubEnhancementService()
        let workspaceId = UUID()
        let first = CMUXGitHubPullRequestRefreshKey(workspaceId: workspaceId, panelId: UUID())
        let second = CMUXGitHubPullRequestRefreshKey(workspaceId: workspaceId, panelId: UUID())
        let target = CMUXGitHubPullRequestRefreshTarget(branch: "feature/work", repoSlugs: [])
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(service.queueRefreshIfNeeded(
            request: request(key: first, reason: "commandHint:merge", target: target),
            now: now,
            defaults: defaults
        ))
        XCTAssertTrue(service.queueRefreshIfNeeded(
            request: request(key: second, reason: "shellPrompt", target: target),
            now: now.addingTimeInterval(2),
            defaults: defaults
        ))

        let snapshot = service.queuedRefreshSnapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.target, target)
        XCTAssertEqual(snapshot.first?.probeKeyCount, 2)
        XCTAssertEqual(snapshot.first?.fireAt, now.addingTimeInterval(5))
    }

    func testFlushesDueEntriesAndDropsStaleTargets() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: SidebarPullRequestShellDebounceSettings.enabledKey)
        defaults.set(5, forKey: SidebarPullRequestShellDebounceSettings.delaySecondsKey)

        let service = CMUXGitHubEnhancementService()
        let workspaceId = UUID()
        let key = CMUXGitHubPullRequestRefreshKey(workspaceId: workspaceId, panelId: UUID())
        let oldTarget = CMUXGitHubPullRequestRefreshTarget(branch: "feature/old", repoSlugs: [])
        let newTarget = CMUXGitHubPullRequestRefreshTarget(branch: "feature/new", repoSlugs: [])
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(service.queueRefreshIfNeeded(
            request: request(key: key, reason: "commandHint:merge", target: oldTarget),
            now: now,
            defaults: defaults
        ))

        let flushed = service.flushDueQueuedRefreshes(
            now: now.addingTimeInterval(5),
            validKeys: [key],
            ownedWorkspaceIds: [workspaceId]
        ) { _ in
            newTarget
        }

        XCTAssertTrue(flushed.isEmpty)
        XCTAssertTrue(service.queuedRefreshSnapshot().isEmpty)
    }

    func testFlushesDueEntriesForOwnedWorkspaceOnly() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: SidebarPullRequestShellDebounceSettings.enabledKey)
        defaults.set(5, forKey: SidebarPullRequestShellDebounceSettings.delaySecondsKey)

        let service = CMUXGitHubEnhancementService()
        let ownedWorkspaceId = UUID()
        let otherWorkspaceId = UUID()
        let ownedKey = CMUXGitHubPullRequestRefreshKey(workspaceId: ownedWorkspaceId, panelId: UUID())
        let otherKey = CMUXGitHubPullRequestRefreshKey(workspaceId: otherWorkspaceId, panelId: UUID())
        let target = CMUXGitHubPullRequestRefreshTarget(branch: "feature/shared", repoSlugs: [])
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(service.queueRefreshIfNeeded(
            request: request(key: ownedKey, reason: "shellPrompt", target: target),
            now: now,
            defaults: defaults
        ))
        XCTAssertTrue(service.queueRefreshIfNeeded(
            request: request(key: otherKey, reason: "shellPrompt", target: target),
            now: now,
            defaults: defaults
        ))

        let flushed = service.flushDueQueuedRefreshes(
            now: now.addingTimeInterval(5),
            validKeys: [ownedKey],
            ownedWorkspaceIds: [ownedWorkspaceId]
        ) { _ in
            target
        }

        XCTAssertEqual(flushed.map(\.key), [ownedKey])
        XCTAssertEqual(service.queuedRefreshSnapshot().first?.probeKeyCount, 1)
    }

    func testRemoveQueuedRefreshesOnlyDropsMatchingWorkspace() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: SidebarPullRequestShellDebounceSettings.enabledKey)
        defaults.set(5, forKey: SidebarPullRequestShellDebounceSettings.delaySecondsKey)

        let service = CMUXGitHubEnhancementService()
        let removedWorkspaceId = UUID()
        let retainedWorkspaceId = UUID()
        let removedKey = CMUXGitHubPullRequestRefreshKey(workspaceId: removedWorkspaceId, panelId: UUID())
        let retainedKey = CMUXGitHubPullRequestRefreshKey(workspaceId: retainedWorkspaceId, panelId: UUID())
        let target = CMUXGitHubPullRequestRefreshTarget(branch: "feature/shared", repoSlugs: [])
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(service.queueRefreshIfNeeded(
            request: request(key: removedKey, reason: "shellPrompt", target: target),
            now: now,
            defaults: defaults
        ))
        XCTAssertTrue(service.queueRefreshIfNeeded(
            request: request(key: retainedKey, reason: "shellPrompt", target: target),
            now: now,
            defaults: defaults
        ))

        service.removeQueuedRefreshes(workspaceId: removedWorkspaceId)

        let snapshot = service.queuedRefreshSnapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.probeKeyCount, 1)

        let flushed = service.flushDueQueuedRefreshes(
            now: now.addingTimeInterval(5),
            validKeys: [retainedKey],
            ownedWorkspaceIds: [retainedWorkspaceId]
        ) { _ in
            target
        }

        XCTAssertEqual(flushed.map(\.key), [retainedKey])
        XCTAssertTrue(service.queuedRefreshSnapshot().isEmpty)
    }

    private func request(
        key: CMUXGitHubPullRequestRefreshKey,
        reason: String,
        target: CMUXGitHubPullRequestRefreshTarget?
    ) -> CMUXGitHubPullRequestRefreshRequest {
        CMUXGitHubPullRequestRefreshRequest(
            key: key,
            reason: reason,
            target: target,
            bypassRepoCache: reason.hasPrefix("commandHint:")
        )
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "cmux-enhancement-github-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

@MainActor
final class CMUXTmuxLeaderEnhancementTests: XCTestCase {
    func testLeaderArmAndSecondKeyDispatchThroughEnhancementActions() throws {
        try withSavedLeaderSettings {
            UserDefaults.standard.set(true, forKey: LeaderKeySettings.enabledKey)

            let service = CMUXTmuxPrefixService()
            configureLeaderService(service)

            var actionEvents: [String] = []
            service.registerLeaderAction(.newTab) { event in
                actionEvents.append(event.charactersIgnoringModifiers ?? "")
                return true
            }

            let context = TestEnhancementContext()
            let host = CMUXEnhancementHost(context: context, logger: context.logger)
            try host.activate(
                CMUXBuiltinEnhancements.make(
                    githubService: CMUXGitHubEnhancementService(),
                    tmuxPrefixService: service
                )
            )
            defer { host.deactivate() }

            let owner = TestLeaderModeOwner()
            let armRequest = CMUXTmuxLeaderArmRequest(
                event: keyEvent(chars: "b", keyCode: 11, modifierFlags: [.control]),
                owner: owner
            )
            let armHandled = context.actions.dispatch(
                CMUXEnhancementAction(
                    id: CMUXTmuxLeaderEnhancementActionID.arm,
                    source: "test",
                    payload: armRequest
                )
            ) { _ in
                XCTFail("tmux leader arm should be handled by the enhancement")
            }

            XCTAssertTrue(armHandled)
            XCTAssertTrue(armRequest.didArm)
            XCTAssertTrue(owner.isLeaderModeActive)

            let secondKeyRequest = CMUXTmuxLeaderSecondKeyRequest(
                event: keyEvent(chars: "c", keyCode: 8)
            )
            let secondKeyHandled = context.actions.dispatch(
                CMUXEnhancementAction(
                    id: CMUXTmuxLeaderEnhancementActionID.secondKey,
                    source: "test",
                    payload: secondKeyRequest
                )
            ) { _ in
                XCTFail("tmux leader second key should be handled by the enhancement")
            }

            XCTAssertTrue(secondKeyHandled)
            if case .dispatched = secondKeyRequest.outcome {
                // expected
            } else {
                XCTFail("Expected tmux leader second key to dispatch")
            }
            XCTAssertEqual(actionEvents, ["c"])
            XCTAssertFalse(owner.isLeaderModeActive)
        }
    }

    func testLeaderArmInterceptorProceedsWhenBuiltInHandlerDoesNotArm() throws {
        try withSavedLeaderSettings {
            UserDefaults.standard.set(false, forKey: LeaderKeySettings.enabledKey)

            let service = CMUXTmuxPrefixService()
            configureLeaderService(service)
            let context = TestEnhancementContext()
            let recorder = ActionEventRecorder()
            context.actions.registerInterceptor(
                ActionIdRecordingInterceptor(
                    id: "low.arm",
                    actionIds: [CMUXTmuxLeaderEnhancementActionID.arm],
                    priority: 0,
                    recorder: recorder
                )
            )
            let host = CMUXEnhancementHost(context: context, logger: context.logger)
            try host.activate(
                CMUXBuiltinEnhancements.make(
                    githubService: CMUXGitHubEnhancementService(),
                    tmuxPrefixService: service
                )
            )
            defer { host.deactivate() }

            let request = CMUXTmuxLeaderArmRequest(
                event: keyEvent(chars: "b", keyCode: 11, modifierFlags: [.control]),
                owner: TestLeaderModeOwner()
            )
            let handled = context.actions.dispatch(
                CMUXEnhancementAction(
                    id: CMUXTmuxLeaderEnhancementActionID.arm,
                    source: "test",
                    payload: request
                )
            ) { _ in
                recorder.events.append("fallback")
            }

            XCTAssertTrue(handled)
            XCTAssertFalse(request.didArm)
            XCTAssertEqual(recorder.events, [
                "intercept:low.arm",
                "fallback",
            ])
        }
    }

    func testBuiltInLeaderActionRegistryDispatchesRegisteredHandler() throws {
        try withSavedLeaderSettings {
            UserDefaults.standard.set(true, forKey: CMUXTmuxPrefixService.enabledSettingsKey)

            let service = CMUXTmuxPrefixService()
            configureLeaderService(service)

            var handledActions: [CMUXTmuxPrefixAction] = []
            let disposable = service.registerBuiltInLeaderActions { action, _ in
                handledActions.append(action)
                return true
            }
            defer { disposable.dispose() }

            let owner = TestLeaderModeOwner()
            XCTAssertTrue(
                service.handleLeaderArm(
                    event: keyEvent(chars: "b", keyCode: 11, modifierFlags: [.control]),
                    owner: owner
                )
            )

            let outcome = service.handleSecondKey(event: keyEvent(chars: "c", keyCode: 8))
            if case .dispatched = outcome {
                // expected
            } else {
                XCTFail("Expected built-in leader registry to dispatch the second key")
            }
            XCTAssertEqual(handledActions, [.newTab])
            XCTAssertFalse(owner.isLeaderModeActive)
        }
    }

    func testBuiltInLeaderEnhancementRegistersActionContributions() throws {
        try withSavedLeaderSettings {
            let service = CMUXTmuxPrefixService()
            let context = TestEnhancementContext()
            let host = CMUXEnhancementHost(context: context, logger: context.logger)

            try host.activate(
                CMUXBuiltinEnhancements.make(
                    githubService: CMUXGitHubEnhancementService(),
                    tmuxPrefixService: service
                )
            )

            XCTAssertEqual(
                service.registeredLeaderActionContributions().map(\.action),
                CMUXTmuxPrefixService.actions
            )
            XCTAssertEqual(
                service.configurableLeaderActions(),
                CMUXTmuxPrefixService.configurableActions
            )

            let statusActions = try XCTUnwrap(service.statusPayload()["actions"] as? [[String: Any]])
            let firstAction = try XCTUnwrap(statusActions.first)
            XCTAssertEqual(firstAction["id"] as? String, CMUXTmuxPrefixAction.splitRight.rawValue)
            XCTAssertEqual(firstAction["configurable"] as? Bool, true)

            host.deactivate()
            XCTAssertEqual(service.registeredLeaderActionContributions(), [])
        }
    }

    func testLeaderTimeoutCancelsArmedOwner() throws {
        try withSavedLeaderSettings {
            UserDefaults.standard.set(true, forKey: LeaderKeySettings.enabledKey)
            UserDefaults.standard.set(0.2, forKey: LeaderKeySettings.timeoutKey)
            var scheduledTimeout: TimeInterval?
            var scheduledWorkItem: DispatchWorkItem?
            let service = CMUXTmuxPrefixService { timeout, workItem in
                scheduledTimeout = timeout
                scheduledWorkItem = workItem
            }
            configureLeaderService(service)

            let owner = TestLeaderModeOwner()
            XCTAssertTrue(
                service.handleLeaderArm(
                    event: keyEvent(chars: "b", keyCode: 11, modifierFlags: [.control]),
                    owner: owner
                )
            )
            XCTAssertTrue(owner.isLeaderModeActive)
            XCTAssertEqual(scheduledTimeout, 0.2)

            scheduledWorkItem?.perform()
            XCTAssertFalse(owner.isLeaderModeActive)
            XCTAssertFalse(service.isArmed)
        }
    }

    func testLeaderTimeoutSchedulerCanBeReplacedAndRestored() throws {
        try withSavedLeaderSettings {
            UserDefaults.standard.set(true, forKey: LeaderKeySettings.enabledKey)
            var originalScheduled = 0
            var replacementScheduled = 0
            let service = CMUXTmuxPrefixService { _, _ in
                originalScheduled += 1
            }
            configureLeaderService(service)

            let restore = service.replaceTimeoutScheduler { _, _ in
                replacementScheduled += 1
            }
            let firstOwner = TestLeaderModeOwner()
            XCTAssertTrue(
                service.handleLeaderArm(
                    event: keyEvent(chars: "b", keyCode: 11, modifierFlags: [.control]),
                    owner: firstOwner
                )
            )
            XCTAssertEqual(replacementScheduled, 1)
            XCTAssertEqual(originalScheduled, 0)
            service.cancelLeaderMode()

            restore()
            let secondOwner = TestLeaderModeOwner()
            XCTAssertTrue(
                service.handleLeaderArm(
                    event: keyEvent(chars: "b", keyCode: 11, modifierFlags: [.control]),
                    owner: secondOwner
                )
            )
            XCTAssertEqual(replacementScheduled, 1)
            XCTAssertEqual(originalScheduled, 1)
            service.cancelLeaderMode()
        }
    }

    func testDisablingLeaderSettingCancelsArmedOwner() throws {
        try withSavedLeaderSettings {
            UserDefaults.standard.set(true, forKey: LeaderKeySettings.enabledKey)
            let service = CMUXTmuxPrefixService { _, _ in }
            configureLeaderService(service)

            let owner = TestLeaderModeOwner()
            XCTAssertTrue(
                service.handleLeaderArm(
                    event: keyEvent(chars: "b", keyCode: 11, modifierFlags: [.control]),
                    owner: owner
                )
            )
            XCTAssertTrue(owner.isLeaderModeActive)

            UserDefaults.standard.set(false, forKey: LeaderKeySettings.enabledKey)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)

            XCTAssertFalse(owner.isLeaderModeActive)
            XCTAssertFalse(service.isArmed)
        }
    }

    private func configureLeaderService(_ service: CMUXTmuxPrefixService) {
        service.configure(
            keyMatcher: { event, _, configuredKey in
                event.charactersIgnoringModifiers == configuredKey
            },
            leaderShortcutMatcher: { event in
                event.keyCode == 11 && event.modifierFlags.contains(.control)
            },
            routingContextSync: { _ in true }
        )
    }

    private func withSavedLeaderSettings(_ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let keys = [
            LeaderKeySettings.enabledKey,
            LeaderKeySettings.timeoutKey,
            LeaderKeySettings.workspaceTagsEnabledKey,
        ] + LeaderKeySettings.LeaderAction.allCases.map(\.defaultsKey)
        let savedValues = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in savedValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        LeaderKeySettings.resetAll()
        try body()
    }

    private func keyEvent(
        chars: String,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}

private enum EnhancementTestError: Error {
    case activationFailed
}

private final class TestLeaderModeOwner: CMUXLeaderModeOwner {
    @MainActor var isLeaderModeActive = false
}

private final class EnhancementEventRecorder {
    var events: [String] = []
}

private final class ActionEventRecorder {
    var events: [String] = []
}

private final class RecordingEnhancement: CMUXEnhancement {
    let manifest: CMUXEnhancementManifest
    private let recorder: EnhancementEventRecorder
    private let activationError: Error?

    init(
        id: String,
        recorder: EnhancementEventRecorder,
        activation: [String] = [],
        permissions: [String] = [],
        activationError: Error? = nil
    ) {
        self.manifest = CMUXEnhancementManifest(id: id, activation: activation, permissions: permissions)
        self.recorder = recorder
        self.activationError = activationError
    }

    func activate(context _: CMUXEnhancementContext) throws {
        recorder.events.append("activate:\(manifest.id)")
        if let activationError {
            throw activationError
        }
    }

    func deactivate() {
        recorder.events.append("deactivate:\(manifest.id)")
    }
}

private final class TestEnhancementContext: CMUXEnhancementContext {
    let logger: CMUXEnhancementLogger
    let actions: CMUXEnhancementActionRegistry
    let scheduler: CMUXEnhancementScheduler

    init() {
        let logger = TestEnhancementLogger()
        self.logger = logger
        self.actions = CMUXAppEnhancementActionRegistry(logger: logger)
        self.scheduler = CMUXDispatchEnhancementScheduler()
    }
}

private final class TestEnhancementLogger: CMUXEnhancementLogger {
    var errors: [String] = []

    func debug(_: String) {}
    func info(_: String) {}
    func warning(_: String) {}

    func error(_ message: String) {
        errors.append(message)
    }
}

private final class RecordingActionInterceptor: CMUXEnhancementActionInterceptor {
    let id: String
    let actionIds: Set<String> = ["test.action"]
    let priority: Int
    private let disposition: CMUXEnhancementActionDisposition
    private let record: (String) -> Void

    init(
        id: String,
        priority: Int,
        disposition: CMUXEnhancementActionDisposition = .continue,
        recorder: ActionEventRecorder
    ) {
        self.id = id
        self.priority = priority
        self.disposition = disposition
        self.record = { recorder.events.append($0) }
    }

    func intercept(
        action _: CMUXEnhancementAction,
        proceed _: @escaping (CMUXEnhancementAction) -> Void
    ) throws -> CMUXEnhancementActionDisposition {
        record("intercept:\(id)")
        return disposition
    }
}

private final class ActionIdRecordingInterceptor: CMUXEnhancementActionInterceptor {
    let id: String
    let actionIds: Set<String>
    let priority: Int
    private let record: (String) -> Void

    init(
        id: String,
        actionIds: Set<String>,
        priority: Int,
        recorder: ActionEventRecorder
    ) {
        self.id = id
        self.actionIds = actionIds
        self.priority = priority
        self.record = { recorder.events.append($0) }
    }

    func intercept(
        action _: CMUXEnhancementAction,
        proceed _: @escaping (CMUXEnhancementAction) -> Void
    ) throws -> CMUXEnhancementActionDisposition {
        record("intercept:\(id)")
        return .continue
    }
}

private final class ProceedingActionInterceptor: CMUXEnhancementActionInterceptor {
    let id = "high"
    let actionIds: Set<String> = ["test.action"]
    let priority = 90
    private let record: (String) -> Void

    init(recorder: ActionEventRecorder) {
        self.record = { recorder.events.append($0) }
    }

    func intercept(
        action: CMUXEnhancementAction,
        proceed: @escaping (CMUXEnhancementAction) -> Void
    ) throws -> CMUXEnhancementActionDisposition {
        record("proceed:high")
        proceed(
            CMUXEnhancementAction(
                id: action.id,
                source: action.source,
                params: ["stage": "proceeded"],
                payload: action.payload
            )
        )
        return .handled
    }
}

private final class ParamRecordingActionInterceptor: CMUXEnhancementActionInterceptor {
    let id: String
    let actionIds: Set<String> = ["test.action"]
    let priority: Int
    private let record: (String) -> Void

    init(id: String, priority: Int, recorder: ActionEventRecorder) {
        self.id = id
        self.priority = priority
        self.record = { recorder.events.append($0) }
    }

    func intercept(
        action: CMUXEnhancementAction,
        proceed _: @escaping (CMUXEnhancementAction) -> Void
    ) throws -> CMUXEnhancementActionDisposition {
        record("intercept:\(id):\(action.params["stage"] as? String ?? "nil")")
        return .continue
    }
}

private final class ThrowingActionInterceptor: CMUXEnhancementActionInterceptor {
    let id = "throwing"
    let actionIds: Set<String> = ["test.action"]
    let priority = 0

    func intercept(
        action _: CMUXEnhancementAction,
        proceed _: @escaping (CMUXEnhancementAction) -> Void
    ) throws -> CMUXEnhancementActionDisposition {
        throw EnhancementTestError.activationFailed
    }
}
