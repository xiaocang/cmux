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
    private let autoBubbleKey = ProactiveAutoBubbleSettings.key

    override func setUp() {
        super.setUp()
        // Remove the debounce delay so the recompute Task is awaitable deterministically.
        SortAssistantCoordinator.debugProactiveSuggestionRecomputeDebounceOverrideNanos = 0
        SortAssistantCoordinator.debugProactiveSuggestionDigestDebounceOverrideNanos = 0
        SortAssistantCoordinator.debugProactiveNotificationDigestDebounceOverrideNanos = nil
        SortAssistantCoordinator.debugProactiveNotificationDigestMinIntervalOverrideNanos = nil
        SortAssistantCoordinator.debugProactiveDigestDelayOverrideNanos = nil
        SortAssistantCoordinator.debugUseDeterministicProactiveDigestForTesting = true
        SortAssistantCoordinator.shared.debugResetProactiveSurfaceStateForTesting()
    }

    override func tearDown() {
        SortAssistantCoordinator.shared.debugResetProactiveSurfaceStateForTesting()
        UserDefaults.standard.removeObject(forKey: flagKey)
        UserDefaults.standard.removeObject(forKey: autoBubbleKey)
        UserDefaults.standard.removeObject(forKey: ProactiveSuggestionNotificationsSettings.key)
        SortAssistantCoordinator.debugProactiveSuggestionRecomputeDebounceOverrideNanos = nil
        SortAssistantCoordinator.debugProactiveSuggestionDigestDebounceOverrideNanos = nil
        SortAssistantCoordinator.debugProactiveNotificationDigestDebounceOverrideNanos = nil
        SortAssistantCoordinator.debugProactiveNotificationDigestMinIntervalOverrideNanos = nil
        SortAssistantCoordinator.debugProactiveDigestDelayOverrideNanos = nil
        SortAssistantCoordinator.debugUseDeterministicProactiveDigestForTesting = false
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

    func testContextAgentBatchRecomputesGenericAttentionSignalWhenEnabled() async throws {
        let coordinator = SortAssistantCoordinator.shared
        UserDefaults.standard.set(true, forKey: flagKey)

        let workspaceId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        await coordinator.workspaceSnapshotStore.write(
            Self.attentionSnapshot(
                workspaceId: workspaceId,
                status: "agent_completed",
                contextHash: "phase2-agent-completed"
            )
        )

        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [workspaceId], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()

        XCTAssertTrue(
            coordinator.visibleSuggestions.contains {
                $0.type == ProactiveSuggestionTypes.workspaceNeedsAttention
                    && $0.workspaceId == workspaceId
            },
            "A high-attention agent-completed snapshot should surface a generic proactive suggestion."
        )
        XCTAssertEqual(
            coordinator.proactiveBadgeByWorkspaceId()[workspaceId]?.type,
            ProactiveSuggestionTypes.workspaceNeedsAttention,
            "Generic attention suggestions should drive the sidebar proactive badge."
        )
    }

    func testContextAgentBatchSuppressesLowAttentionGenericSignal() async throws {
        let coordinator = SortAssistantCoordinator.shared
        UserDefaults.standard.set(true, forKey: flagKey)

        let workspaceId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        await coordinator.workspaceSnapshotStore.write(
            Self.attentionSnapshot(
                workspaceId: workspaceId,
                status: "agent_completed",
                attention: 0.4,
                contextHash: "phase2-agent-low"
            )
        )

        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [workspaceId], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()

        XCTAssertFalse(
            coordinator.visibleSuggestions.contains { $0.workspaceId == workspaceId },
            "A low-attention generic snapshot should not create a proactive suggestion."
        )
    }

    func testAutoBubbleDoesNotRepeatForSameWorkspaceSignalWhenContextHashChanges() async throws {
        let coordinator = SortAssistantCoordinator.shared
        UserDefaults.standard.set(true, forKey: flagKey)
        UserDefaults.standard.set(true, forKey: autoBubbleKey)

        let workspaceId = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        await coordinator.workspaceSnapshotStore.write(
            Self.waitingUserSnapshot(workspaceId: workspaceId, contextHash: "repeat-signal-first")
        )

        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [workspaceId], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()

        let firstBubbleSuggestion = try XCTUnwrap(coordinator.compactAutoBubbleSuggestion)
        XCTAssertEqual(firstBubbleSuggestion.workspaceId, workspaceId)
        XCTAssertEqual(firstBubbleSuggestion.type, ProactiveSuggestionTypes.reviewAgentWaitingUser)
        XCTAssertTrue(coordinator.isCompactAutoBubble)
        XCTAssertTrue(coordinator.isConversationBubblePresented)

        if coordinator.isConversationBubblePresented {
            _ = coordinator.toggleConversationBubble(reason: "testCloseAutoBubble")
        }
        coordinator.debugExpireAutoBubbleRateLimitForTesting()

        await coordinator.workspaceSnapshotStore.write(
            Self.waitingUserSnapshot(workspaceId: workspaceId, contextHash: "repeat-signal-second")
        )
        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [workspaceId], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()

        let currentSuggestion = try XCTUnwrap(coordinator.visibleSuggestions.first {
            $0.workspaceId == workspaceId && $0.type == ProactiveSuggestionTypes.reviewAgentWaitingUser
        })
        XCTAssertNotEqual(
            currentSuggestion.id,
            firstBubbleSuggestion.id,
            "Test precondition: the same workspace signal can receive a new suggestion id when contextHash changes."
        )
        XCTAssertFalse(
            coordinator.isConversationBubblePresented,
            "A contextHash-only suggestion id change must not re-open the proactive auto-bubble for the same workspace signal."
        )
        XCTAssertFalse(coordinator.isCompactAutoBubble)
        XCTAssertNil(coordinator.compactAutoBubbleSuggestion)
    }

    func testOpeningAutoBubbleKeepsStoreBackedSuggestionAfterAttach() async throws {
        let coordinator = SortAssistantCoordinator.shared
        UserDefaults.standard.set(true, forKey: flagKey)

        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()
        let targetWorkspace = tabManager.addWorkspace(
            title: "Review Queue",
            select: false,
            autoWelcomeIfNeeded: false
        )
        coordinator.attach(tabManager: tabManager, workspaceTabStore: workspaceTabStore)

        await coordinator.workspaceSnapshotStore.write(
            Self.waitingUserSnapshot(workspaceId: targetWorkspace.id, contextHash: "open-bubble-store")
        )
        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [targetWorkspace.id], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()

        let suggestion = try XCTUnwrap(coordinator.visibleSuggestions.first {
            $0.workspaceId == targetWorkspace.id && $0.type == ProactiveSuggestionTypes.reviewAgentWaitingUser
        })

        coordinator.openEntry()
        coordinator.attach(tabManager: tabManager, workspaceTabStore: workspaceTabStore)

        XCTAssertTrue(
            coordinator.visibleSuggestions.contains { $0.id == suggestion.id },
            "Opening the full sprite dialog must not clear the store-backed proactive suggestion before the user can click Open."
        )
    }

    func testOpenButtonAcceptsSameWorkspaceSignalAfterContextHashChanges() async throws {
        let coordinator = SortAssistantCoordinator.shared
        UserDefaults.standard.set(true, forKey: flagKey)

        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()
        let initialWorkspace = try XCTUnwrap(tabManager.selectedWorkspace)
        let targetWorkspace = tabManager.addWorkspace(
            title: "Review Queue",
            select: false,
            autoWelcomeIfNeeded: false
        )
        coordinator.attach(tabManager: tabManager, workspaceTabStore: workspaceTabStore)

        await coordinator.workspaceSnapshotStore.write(
            Self.waitingUserSnapshot(workspaceId: targetWorkspace.id, contextHash: "open-button-first")
        )
        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [targetWorkspace.id], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()
        let firstSuggestion = try XCTUnwrap(coordinator.visibleSuggestions.first {
            $0.workspaceId == targetWorkspace.id && $0.type == ProactiveSuggestionTypes.reviewAgentWaitingUser
        })

        await coordinator.workspaceSnapshotStore.write(
            Self.waitingUserSnapshot(workspaceId: targetWorkspace.id, contextHash: "open-button-second")
        )
        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [targetWorkspace.id], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()
        let currentSuggestion = try XCTUnwrap(coordinator.visibleSuggestions.first {
            $0.workspaceId == targetWorkspace.id && $0.type == ProactiveSuggestionTypes.reviewAgentWaitingUser
        })
        XCTAssertNotEqual(firstSuggestion.id, currentSuggestion.id)

        coordinator.openConversationBubble(reason: "testOpenButton")
        coordinator.acceptVisibleSuggestion(firstSuggestion)

        XCTAssertEqual(tabManager.selectedWorkspace?.id, targetWorkspace.id)
        XCTAssertNotEqual(tabManager.selectedWorkspace?.id, initialWorkspace.id)
        XCTAssertFalse(coordinator.isConversationBubblePresented)
        XCTAssertFalse(coordinator.visibleSuggestions.contains {
            $0.workspaceId == targetWorkspace.id && $0.type == ProactiveSuggestionTypes.reviewAgentWaitingUser
        })
    }

    func testDigestMergesMultipleNotificationSuggestionsAndKeepsOnlyPrimaryVisible() async throws {
        let coordinator = SortAssistantCoordinator.shared
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        var deliveredNotifications: [TerminalNotification] = []

        UserDefaults.standard.set(true, forKey: flagKey)
        UserDefaults.standard.set(true, forKey: ProactiveSuggestionNotificationsSettings.key)
        await coordinator.workspaceSnapshotStore.replace(AssistantWorkingContext(
            activeWorkspaceId: nil,
            snapshots: [],
            freshness: ContextFreshness(providers: [], overallConfidence: 1),
            activeSuggestions: [],
            latestRanking: nil
        ))
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredNotifications.append(notification)
        }
        appDelegate.tabManager = tabManager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false
        defer {
            coordinator.debugResetProactiveSurfaceStateForTesting()
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let reviewWorkspace = tabManager.addWorkspace(
            title: "Review Queue",
            select: false,
            autoWelcomeIfNeeded: false
        )
        let releaseWorkspace = tabManager.addWorkspace(
            title: "Release",
            select: false,
            autoWelcomeIfNeeded: false
        )
        coordinator.attach(tabManager: tabManager, workspaceTabStore: workspaceTabStore)

        await coordinator.workspaceSnapshotStore.write(
            Self.waitingUserSnapshot(
                workspaceId: reviewWorkspace.id,
                title: "Review Queue",
                contextHash: "digest-review"
            )
        )
        await coordinator.workspaceSnapshotStore.write(
            Self.attentionSnapshot(
                workspaceId: releaseWorkspace.id,
                title: "Release",
                status: "ready_to_merge",
                attention: 0.95,
                nextAction: "Merge the release PR",
                contextHash: "digest-release",
                nativeOrder: 1
            )
        )

        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(
                updatedWorkspaceIds: [reviewWorkspace.id, releaseWorkspace.id],
                failures: []
            )
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()
        await coordinator.debugAwaitProactiveSuggestionDigestForTesting()

        let digest = try XCTUnwrap(coordinator.proactiveSuggestionDigest)
        let foldedSuggestion = try XCTUnwrap(coordinator.visibleSuggestions.first {
            $0.workspaceId == releaseWorkspace.id && $0.type == ProactiveSuggestionTypes.mergeReady
        })
        XCTAssertTrue(digest.text.contains("Review Queue"))
        XCTAssertTrue(digest.text.contains("Release"))
        XCTAssertTrue(
            digest.foldedSuggestionIds.contains(foldedSuggestion.id),
            "The lower-priority merge-ready card should be folded by the digest."
        )
        XCTAssertEqual(
            digest.foldedSuggestionIds,
            Set(digest.suggestionIds.dropFirst()),
            "The Sprite notification digest should keep only the most important suggestion visible."
        )
        XCTAssertTrue(coordinator.visibleSuggestions.contains { $0.id == foldedSuggestion.id })
        XCTAssertEqual(deliveredNotifications.count, 1)
        XCTAssertEqual(deliveredNotifications.first?.body, digest.text)
        XCTAssertEqual(store.notifications.count, 1)

        coordinator.openConversationBubble(reason: "testFoldedSuggestionOpen")
        coordinator.acceptVisibleSuggestion(foldedSuggestion)

        XCTAssertEqual(tabManager.selectedWorkspace?.id, releaseWorkspace.id)
    }

    func testDigestParserAcceptsFencedJSONWithoutRenderingRawJSON() throws {
        let itemId = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let workspaceId = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let result = try XCTUnwrap(SortAssistantMCPClient.proactiveNotificationDigestResultForTesting(
            from: """
            ```json
            {"sentence":"Review a debug-injected suggestion in the livesh workspace.","folded_ids":["77777777-7777-7777-7777-777777777777"]}
            ```
            """,
            items: [
                SortAssistantProactiveNotificationDigestItem(
                    id: itemId,
                    workspaceId: workspaceId,
                    workspaceTitle: "livesh",
                    type: ProactiveSuggestionTypes.reviewAgentWaitingUser,
                    title: "Review the debug-injected suggestion",
                    reason: "Debug-injected high-priority suggestion",
                    confidence: 1
                ),
            ]
        ))

        XCTAssertEqual(result.sentence, "Review a debug-injected suggestion in the livesh workspace.")
        XCTAssertFalse(result.sentence.contains("json"))
        XCTAssertTrue(
            result.foldedSuggestionIds.isEmpty,
            "A single digest item is the primary item and must remain visible even if Claude asks to fold it."
        )
    }

    func testDigestParserFoldsEveryNonPrimaryNotification() throws {
        let primaryId = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let secondaryId = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let workspaceId = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let result = try XCTUnwrap(SortAssistantMCPClient.proactiveNotificationDigestResultForTesting(
            from: #"{"sentence":"Review Queue needs your decision; Release is ready to merge.","folded_ids":[]}"#,
            items: [
                SortAssistantProactiveNotificationDigestItem(
                    id: primaryId,
                    workspaceId: workspaceId,
                    workspaceTitle: "Review Queue",
                    type: ProactiveSuggestionTypes.reviewAgentWaitingUser,
                    title: "Review the agent's question",
                    reason: "Agent is waiting for your decision.",
                    confidence: 0.96
                ),
                SortAssistantProactiveNotificationDigestItem(
                    id: secondaryId,
                    workspaceId: workspaceId,
                    workspaceTitle: "Release",
                    type: ProactiveSuggestionTypes.mergeReady,
                    title: "Merge the release PR",
                    reason: "Release is ready to merge.",
                    confidence: 0.95
                ),
            ]
        ))

        XCTAssertEqual(result.foldedSuggestionIds, Set([secondaryId]))
    }

    func testNotificationDigestBatchesBurstAndThrottlesUpdates() async throws {
        let coordinator = SortAssistantCoordinator.shared
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        var deliveredNotifications: [TerminalNotification] = []

        SortAssistantCoordinator.debugProactiveNotificationDigestDebounceOverrideNanos = 80_000_000
        SortAssistantCoordinator.debugProactiveNotificationDigestMinIntervalOverrideNanos = 500_000_000
        UserDefaults.standard.set(true, forKey: flagKey)
        UserDefaults.standard.set(true, forKey: ProactiveSuggestionNotificationsSettings.key)
        await coordinator.workspaceSnapshotStore.replace(AssistantWorkingContext(
            activeWorkspaceId: nil,
            snapshots: [],
            freshness: ContextFreshness(providers: [], overallConfidence: 1),
            activeSuggestions: [],
            latestRanking: nil
        ))
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredNotifications.append(notification)
        }
        appDelegate.tabManager = tabManager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false
        defer {
            coordinator.debugResetProactiveSurfaceStateForTesting()
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let reviewWorkspace = tabManager.addWorkspace(
            title: "Review Queue",
            select: false,
            autoWelcomeIfNeeded: false
        )
        let ciWorkspace = tabManager.addWorkspace(
            title: "CI",
            select: false,
            autoWelcomeIfNeeded: false
        )
        let releaseWorkspace = tabManager.addWorkspace(
            title: "Release",
            select: false,
            autoWelcomeIfNeeded: false
        )
        coordinator.attach(tabManager: tabManager, workspaceTabStore: workspaceTabStore)

        await coordinator.workspaceSnapshotStore.write(
            Self.waitingUserSnapshot(
                workspaceId: reviewWorkspace.id,
                title: "Review Queue",
                contextHash: "digest-burst-review"
            )
        )
        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [reviewWorkspace.id], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()

        try await Task.sleep(nanoseconds: 20_000_000)
        await coordinator.workspaceSnapshotStore.write(
            Self.attentionSnapshot(
                workspaceId: ciWorkspace.id,
                title: "CI",
                status: "ci_failed",
                attention: 0.95,
                nextAction: "Fix the failed CI job",
                contextHash: "digest-burst-ci",
                nativeOrder: 1
            )
        )
        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [ciWorkspace.id], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()

        XCTAssertTrue(
            deliveredNotifications.isEmpty,
            "Notifications arriving during the digest delay window should be summarized together, not delivered immediately."
        )

        await coordinator.debugAwaitProactiveSuggestionDigestForTesting()
        XCTAssertEqual(deliveredNotifications.count, 1)
        XCTAssertTrue(deliveredNotifications[0].body.contains("Review Queue"))
        XCTAssertTrue(deliveredNotifications[0].body.contains("CI"))

        await coordinator.workspaceSnapshotStore.write(
            Self.attentionSnapshot(
                workspaceId: releaseWorkspace.id,
                title: "Release",
                status: "ready_to_merge",
                attention: 0.95,
                nextAction: "Merge the release PR",
                contextHash: "digest-throttle-release",
                nativeOrder: 2
            )
        )
        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [releaseWorkspace.id], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(
            deliveredNotifications.count,
            1,
            "A second notification digest should wait for the minimum update interval, even after its debounce elapsed."
        )

        await coordinator.debugAwaitProactiveSuggestionDigestForTesting()
        XCTAssertEqual(deliveredNotifications.count, 2)
        XCTAssertTrue(deliveredNotifications[1].body.contains("Release"))
    }

    func testDelayedNotificationDigestDoesNotDeliverAfterAppRegainsFocus() async throws {
        try await assertDelayedNotificationDigestDoesNotDeliverAfterGateChange(contextHash: "digest-focus-cancel") {
            AppFocusState.overrideIsFocused = true
        }
    }

    func testDelayedNotificationDigestDoesNotDeliverAfterNotificationSettingDisabled() async throws {
        try await assertDelayedNotificationDigestDoesNotDeliverAfterGateChange(contextHash: "digest-setting-cancel") {
            UserDefaults.standard.set(false, forKey: ProactiveSuggestionNotificationsSettings.key)
        }
    }

    func testNotificationDigestWaitsForInFlightSummaryBeforeThrottledUpdate() async throws {
        let coordinator = SortAssistantCoordinator.shared
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        var deliveredNotifications: [TerminalNotification] = []

        SortAssistantCoordinator.debugProactiveNotificationDigestDebounceOverrideNanos = 40_000_000
        SortAssistantCoordinator.debugProactiveNotificationDigestMinIntervalOverrideNanos = 220_000_000
        SortAssistantCoordinator.debugProactiveDigestDelayOverrideNanos = 180_000_000
        UserDefaults.standard.set(true, forKey: flagKey)
        UserDefaults.standard.set(true, forKey: ProactiveSuggestionNotificationsSettings.key)
        await coordinator.workspaceSnapshotStore.replace(AssistantWorkingContext(
            activeWorkspaceId: nil,
            snapshots: [],
            freshness: ContextFreshness(providers: [], overallConfidence: 1),
            activeSuggestions: [],
            latestRanking: nil
        ))
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredNotifications.append(notification)
        }
        appDelegate.tabManager = tabManager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false
        defer {
            coordinator.debugResetProactiveSurfaceStateForTesting()
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let firstWorkspace = tabManager.addWorkspace(
            title: "Review Queue",
            select: false,
            autoWelcomeIfNeeded: false
        )
        let secondWorkspace = tabManager.addWorkspace(
            title: "CI",
            select: false,
            autoWelcomeIfNeeded: false
        )
        coordinator.attach(tabManager: tabManager, workspaceTabStore: workspaceTabStore)

        await coordinator.workspaceSnapshotStore.write(
            Self.waitingUserSnapshot(
                workspaceId: firstWorkspace.id,
                title: "Review Queue",
                contextHash: "digest-inflight-review"
            )
        )
        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [firstWorkspace.id], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()

        try await Task.sleep(nanoseconds: 90_000_000)
        await coordinator.workspaceSnapshotStore.write(
            Self.attentionSnapshot(
                workspaceId: secondWorkspace.id,
                title: "CI",
                status: "ci_failed",
                attention: 0.95,
                nextAction: "Fix the failed CI job",
                contextHash: "digest-inflight-ci",
                nativeOrder: 1
            )
        )
        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [secondWorkspace.id], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()

        await waitForDeliveredNotificationCount(1, in: { deliveredNotifications.count })
        XCTAssertEqual(deliveredNotifications.count, 1)
        XCTAssertTrue(deliveredNotifications[0].body.contains("Review Queue"))

        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(
            deliveredNotifications.count,
            1,
            "A notification arriving while Claude is summarizing should wait for the first update and the minimum interval."
        )

        await coordinator.debugAwaitProactiveSuggestionDigestForTesting()
        XCTAssertEqual(deliveredNotifications.count, 2)
        XCTAssertTrue(deliveredNotifications[1].body.contains("CI"))
    }

    func testActiveDigestCancellationPreventsStaleSummaryOverwrite() async throws {
        let coordinator = SortAssistantCoordinator.shared
        UserDefaults.standard.set(true, forKey: flagKey)
        SortAssistantCoordinator.debugProactiveDigestDelayOverrideNanos = 180_000_000

        let staleWorkspaceId = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let currentWorkspaceId = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!

        await coordinator.workspaceSnapshotStore.replace(Self.workingContext(snapshots: [
            Self.attentionSnapshot(
                workspaceId: staleWorkspaceId,
                title: "Stale Queue",
                status: "waiting_user",
                attention: 0.95,
                nextAction: "Review the stale queue",
                contextHash: "digest-race-stale"
            ),
        ]))
        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [staleWorkspaceId], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()

        try await Task.sleep(nanoseconds: 40_000_000)

        await coordinator.workspaceSnapshotStore.replace(Self.workingContext(snapshots: [
            Self.attentionSnapshot(
                workspaceId: currentWorkspaceId,
                title: "Current Queue",
                status: "waiting_user",
                attention: 0.95,
                nextAction: "Review the current queue",
                contextHash: "digest-race-current"
            ),
        ]))
        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [currentWorkspaceId], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()
        await coordinator.debugAwaitProactiveSuggestionDigestForTesting()

        let digest = try XCTUnwrap(coordinator.proactiveSuggestionDigest)
        XCTAssertTrue(digest.text.contains("Review the current queue"))
        XCTAssertFalse(
            digest.text.contains("Review the stale queue"),
            "A canceled active-suggestions digest must not publish after a newer digest has been scheduled."
        )
        XCTAssertEqual(coordinator.visibleSuggestions.map(\.workspaceId), [currentWorkspaceId])
        await coordinator.workspaceSnapshotStore.replace(Self.workingContext(snapshots: []))
    }

    func testRealAgentHookEventTriggersProactiveSuggestionWhenDefaultEnabled() async throws {
        let coordinator = SortAssistantCoordinator.shared
        UserDefaults.standard.removeObject(forKey: flagKey)
        XCTAssertTrue(
            ProactiveSpriteSuggestionsSettings.isEnabled(),
            "Proactive sprite suggestions should be on by default so real hooks can trigger without hidden setup."
        )
        let contextAgentStarted = await coordinator.debugAwaitContextAgentStartup()
        XCTAssertTrue(
            contextAgentStarted,
            "The context agent must be subscribed with event-payload providers before publishing the hook event."
        )

        let workspaceId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        CmuxEventBus.shared.publish(
            name: "agent.hook.Stop",
            category: "agent",
            source: "proactive-sprite-test",
            workspaceId: workspaceId.uuidString,
            payload: [
                "hook_event_name": "Stop",
                "_source": "proactive-sprite-test",
                "title": "Agent finished",
                "summary": "The agent completed a turn.",
                "nativeOrder": "0",
            ]
        )

        let suggestion = await waitForSuggestion(workspaceId: workspaceId)
        XCTAssertEqual(suggestion?.type, ProactiveSuggestionTypes.workspaceNeedsAttention)
        XCTAssertEqual(
            coordinator.proactiveBadgeByWorkspaceId()[workspaceId]?.type,
            ProactiveSuggestionTypes.workspaceNeedsAttention
        )
    }

    private static func workingContext(snapshots: [WorkspaceSnapshot]) -> AssistantWorkingContext {
        AssistantWorkingContext(
            activeWorkspaceId: nil,
            snapshots: snapshots,
            freshness: ContextFreshness(providers: [], overallConfidence: snapshots.isEmpty ? 0 : 1),
            activeSuggestions: [],
            latestRanking: nil
        )
    }

    private static func waitingUserSnapshot(
        workspaceId: UUID,
        title: String = "API fix",
        contextHash: String
    ) -> WorkspaceSnapshot {
        attentionSnapshot(
            workspaceId: workspaceId,
            title: title,
            status: "waiting_user",
            attention: 0.95,
            nextAction: "Review the agent's question",
            contextHash: contextHash
        )
    }

    private static func attentionSnapshot(
        workspaceId: UUID,
        title: String = "API fix",
        status: String,
        attention: Double = 0.92,
        nextAction: String = "Review completed agent work",
        contextHash: String,
        nativeOrder: Int = 0
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
                title: title,
                selected: false,
                directory: nil,
                listRevision: 1,
                nativeOrder: nativeOrder,
                pinned: false,
                locked: false,
                customColor: nil,
                panelCount: 0,
                pullRequestCount: 0,
                stalePullRequestCount: 0
            ),
            derived: DerivedWorkspaceState(
                status: status,
                priorityScore: nil,
                rankReason: nil,
                nextAction: nextAction,
                userAttentionNeeded: attention
            ),
            digest: nil,
            freshness: freshness,
            contextHash: contextHash
        )
    }

    private func waitForDeliveredNotificationCount(
        _ expectedCount: Int,
        in count: @escaping () -> Int
    ) async {
        for _ in 0..<50 {
            if count() >= expectedCount {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func assertDelayedNotificationDigestDoesNotDeliverAfterGateChange(
        contextHash: String,
        changeGate: () -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let coordinator = SortAssistantCoordinator.shared
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        var deliveredNotifications: [TerminalNotification] = []

        SortAssistantCoordinator.debugProactiveNotificationDigestDebounceOverrideNanos = 120_000_000
        SortAssistantCoordinator.debugProactiveNotificationDigestMinIntervalOverrideNanos = 0
        UserDefaults.standard.set(true, forKey: flagKey)
        UserDefaults.standard.set(true, forKey: ProactiveSuggestionNotificationsSettings.key)
        await coordinator.workspaceSnapshotStore.replace(AssistantWorkingContext(
            activeWorkspaceId: nil,
            snapshots: [],
            freshness: ContextFreshness(providers: [], overallConfidence: 1),
            activeSuggestions: [],
            latestRanking: nil
        ))
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredNotifications.append(notification)
        }
        appDelegate.tabManager = tabManager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false
        defer {
            coordinator.debugResetProactiveSurfaceStateForTesting()
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let reviewWorkspace = tabManager.addWorkspace(
            title: "Review Queue",
            select: false,
            autoWelcomeIfNeeded: false
        )
        coordinator.attach(tabManager: tabManager, workspaceTabStore: workspaceTabStore)

        await coordinator.workspaceSnapshotStore.write(
            Self.waitingUserSnapshot(
                workspaceId: reviewWorkspace.id,
                title: "Review Queue",
                contextHash: contextHash
            )
        )
        await coordinator.handleContextAgentBatch(
            ContextAgentBatchResult(updatedWorkspaceIds: [reviewWorkspace.id], failures: [])
        )
        await coordinator.debugAwaitProactiveSuggestionRecompute()
        XCTAssertTrue(deliveredNotifications.isEmpty, file: file, line: line)

        changeGate()
        await coordinator.debugAwaitProactiveSuggestionDigestForTesting()

        XCTAssertTrue(deliveredNotifications.isEmpty, file: file, line: line)
        XCTAssertEqual(store.notifications.count, 0, file: file, line: line)
    }

    private func waitForSuggestion(workspaceId: UUID) async -> ProactiveSuggestion? {
        let coordinator = SortAssistantCoordinator.shared
        for _ in 0..<50 {
            if let suggestion = coordinator.visibleSuggestions.first(where: { $0.workspaceId == workspaceId }) {
                return suggestion
            }
            await coordinator.debugAwaitProactiveSuggestionRecompute()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return coordinator.visibleSuggestions.first(where: { $0.workspaceId == workspaceId })
    }
}
