import XCTest
import AppKit
import CMUXActions
import Carbon.HIToolbox
import Darwin
import PDFKit
import Testing
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
@testable import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SortAssistantIntentRouterTests: XCTestCase {
    func testSortApplyPermissionGrantDoesNotUseImmediateKeywordRouting() {
        let router = SortAssistantIntentRouter()

        XCTAssertNil(
            router.immediateIntent(
                for: "I need sort_apply permission to complete the sort. Please grant write access to workspace sorting."
            )
        )
    }

    func testSortApplyPermissionDenialDoesNotRouteToApplySortImmediately() {
        let router = SortAssistantIntentRouter()

        XCTAssertNil(
            router.immediateIntent(
                for: "Do not grant sort_apply permission for workspace sorting."
            )
        )
    }

    func testSortApplyPermissionQuestionDoesNotRouteToApplySortImmediately() {
        let router = SortAssistantIntentRouter()

        XCTAssertNil(
            router.immediateIntent(
                for: "Do I need sort_apply permission before changing workspace sorting?"
            )
        )
    }

    func testWorkspaceColorCategoryAssignmentDoesNotUseImmediateKeywordRouting() {
        let router = SortAssistantIntentRouter()

        XCTAssertNil(
            router.immediateIntent(
                for: "blue for reviews, red for bugfixes, green for new features"
            )
        )
    }

    func testWorkspaceColorPluralReadDoesNotUseImmediateKeywordRouting() {
        let router = SortAssistantIntentRouter()

        XCTAssertNil(
            router.immediateIntent(
                for: "What colors are currently assigned to workspaces?"
            )
        )
    }

    func testWorkspaceColorRouteAllowsColorMutationTools() {
        let router = SortAssistantActionRouter()
        let route = router.route(for: .workspaceColor)

        XCTAssertEqual(route.mode, .applyAllowed)
        XCTAssertFalse(route.needsConfirmation)
        XCTAssertTrue(route.allowedTools.contains("workspace_color_set"))
        XCTAssertTrue(route.allowedTools.contains("workspace_color_clear"))
        XCTAssertTrue(route.allowedTools.contains("list_state"))
    }

    func testProductionRoutesUseSnapshotReadToolsWithoutDebugContextTools() {
        let router = SortAssistantActionRouter()
        let intents: [SortAssistantIntent] = [
            .askContext,
            .clearSession,
            .explainCurrentOrder,
            .proposeSort,
            .applySort,
            .manualReorderFeedback,
            .rememberPreference,
            .forgetPreference,
            .rememberSpriteMemory,
            .forgetSpriteMemory,
            .undoSort,
            .workspaceColor,
            .normalChat,
        ]

        for intent in intents {
            let tools = router.route(for: intent).allowedTools
            for tool in sortAssistantDebugOnlyContextTools {
                XCTAssertFalse(tools.contains(tool), "\(intent.rawValue) should not expose \(tool)")
            }
        }

        let askTools = router.route(for: .askContext).allowedTools
        XCTAssertTrue(askTools.contains("assistant_working_context_get"))
        XCTAssertTrue(askTools.contains("workspace_snapshot_get"))
        XCTAssertTrue(askTools.contains("context_freshness_get"))
        XCTAssertTrue(askTools.contains("ranking_latest_get"))
        XCTAssertTrue(askTools.contains("suggestions_active_get"))
        XCTAssertTrue(askTools.contains("workspace_digest_get"))
        XCTAssertFalse(askTools.contains("suggestion_accept"))
        XCTAssertFalse(askTools.contains("suggestion_dismiss"))
    }

    func testProductionAssistantToolSetExcludesDebugRefreshTools() {
        for tool in sortAssistantDebugOnlyContextTools {
            XCTAssertFalse(sortAssistantProductionAssistantTools.contains(tool))
        }
        XCTAssertTrue(sortAssistantProductionAssistantTools.contains("assistant_working_context_get"))
        XCTAssertTrue(sortAssistantProductionAssistantTools.contains("workspace_snapshot_get"))
        XCTAssertTrue(sortAssistantProductionAssistantTools.contains("workspace_digest_get"))
        XCTAssertTrue(sortAssistantProductionAssistantTools.contains("suggestion_accept"))
        XCTAssertTrue(sortAssistantProductionAssistantTools.contains("suggestion_dismiss"))
        XCTAssertTrue(sortAssistantProductionAssistantTools.contains("sprite_memory_write_candidate"))
    }

    func testProductionAssistantToolSetMatchesExposedSpriteMCPProductionCatalog() {
        XCTAssertEqual(sortAssistantProductionAssistantTools, [
            "assistant_working_context_get",
            "context_agent_collect",
            "context_freshness_get",
            "list_lock",
            "list_pin",
            "list_state",
            "memory_forget",
            "memory_query",
            "memory_write_candidate",
            "proactive_signal_report",
            "proactive_suggestions_refresh",
            "ranking_latest_get",
            "sort_apply",
            "sort_explain",
            "sort_preview",
            "sort_undo",
            "sprite_memory_forget",
            "sprite_memory_query",
            "sprite_memory_write",
            "sprite_memory_write_candidate",
            "suggestion_accept",
            "suggestion_dismiss",
            "suggestions_active_get",
            "workspace_color_clear",
            "workspace_color_get",
            "workspace_color_set",
            "workspace_digest_get",
            "workspace_snapshot_get",
        ])
    }

    func testDebugOnlyContextToolSetMatchesOptInSpriteMCPDebugCatalog() {
        XCTAssertEqual(sortAssistantDebugOnlyContextTools, [
            "context_collect",
            "ghpr_context",
            "ghpr_refresh",
            "ghpr_status",
            "github_context",
            "github_pr_context",
            "repository_context",
            "sort_context",
            "workspace_digest_progress",
            "workspace_digest_refresh",
        ])
    }

    func testProductionToolNormalizerRejectsDebugContextToolsEvenWhenQualified() {
        let requestedTools = Array(sortAssistantDebugOnlyContextTools)
            + sortAssistantDebugOnlyContextTools.map { "mcp__cmux_sprite__\($0)" }
            + [
                "mcp__cmux_sprite__assistant_working_context_get",
                "workspace_snapshot_get",
            ]

        let normalized = normalizedSortAssistantProductionInternalTools(requestedTools)

        for tool in sortAssistantDebugOnlyContextTools {
            XCTAssertFalse(normalized.contains(tool), "production normalizer should reject \(tool)")
        }
        XCTAssertEqual(normalized, [
            "assistant_working_context_get",
            "workspace_snapshot_get",
        ])
    }

    func testRouteAdjustmentCanExplicitlyExposeSuggestionMutationTools() {
        let route = SortAssistantActionRouter().route(for: .askContext)
        let adjustment = SortAssistantRouteAdjustment(
            allowedTools: ["suggestion_accept", "suggestion_dismiss"]
        )
        let adjustedTools = adjustment.applyingAllowedTools(to: route.allowedTools)

        XCTAssertFalse(route.allowedTools.contains("suggestion_accept"))
        XCTAssertFalse(route.allowedTools.contains("suggestion_dismiss"))
        XCTAssertTrue(adjustedTools.contains("suggestion_accept"))
        XCTAssertTrue(adjustedTools.contains("suggestion_dismiss"))
        XCTAssertTrue(adjustment.requestsMutatingTools(applyingTo: route.allowedTools))
    }

    func testMCPRuntimePlanKeepsSortAndMemoryRoutesSpriteOnly() {
        // Sort/color/memory routes never load external MCP servers, even when a
        // workspace has external servers configured, so mutation turns do not pay
        // the external-server spawn cost. Conversational routes are covered by
        // testMCPRuntimePlanLoadsExternalServersForConversationalRoutes.
        let intents: [SortAssistantIntent] = [
            .proposeSort,
            .applySort,
            .explainCurrentOrder,
            .rememberPreference,
            .forgetPreference,
            .rememberSpriteMemory,
            .forgetSpriteMemory,
            .undoSort,
            .workspaceColor,
            .manualReorderFeedback,
        ]

        for intent in intents {
            let request = makeSpriteMCPRequest(intent: intent)
            let summary = SortAssistantMCPClient.runtimePlanSummaryForTesting(request)

            XCTAssertEqual(summary.externalPolicy, "sprite_only_for_intent", "\(intent.rawValue)")
            XCTAssertEqual(summary.externalServerNames, [], "\(intent.rawValue)")
            XCTAssertEqual(summary.externalAllowedTools, [], "\(intent.rawValue)")
            XCTAssertFalse(summary.executionAllowedTools.contains { $0.contains("mock_external") }, "\(intent.rawValue)")
            XCTAssertEqual(
                summary.serverNames.contains("cmux_sprite"),
                !request.route.allowedTools.isEmpty,
                "\(intent.rawValue)"
            )
        }
    }

    func testMCPRuntimePlanLoadsExternalServersForConversationalRoutes() throws {
        // ask_context and normal_chat are the routes where the user asks about
        // external systems (Jira/Confluence), so they must expose the workspace's
        // configured external MCP servers and their qualified tool allowlist.
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-sprite-ext-\(UUID().uuidString)", isDirectory: true)
        let cmuxDir = tempDir.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: cmuxDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config: [String: Any] = [
            "mcpServers": [
                "mock_external": [
                    "command": "/bin/sh",
                    "args": ["-c", "exit 0"],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: config)
        try data.write(to: cmuxDir.appendingPathComponent("sprite.json"))

        for intent in [SortAssistantIntent.askContext, .normalChat] {
            let request = makeSpriteMCPRequest(intent: intent, workspaceDirectory: tempDir.path)
            let summary = SortAssistantMCPClient.runtimePlanSummaryForTesting(request)

            XCTAssertEqual(summary.externalPolicy, "loaded_for_intent", "\(intent.rawValue)")
            XCTAssertTrue(summary.externalServerNames.contains("mock_external"), "\(intent.rawValue)")
            XCTAssertTrue(summary.externalAllowedTools.contains("mcp__mock_external__*"), "\(intent.rawValue)")
            XCTAssertTrue(summary.serverNames.contains("mock_external"), "\(intent.rawValue)")
            XCTAssertTrue(
                summary.executionAllowedTools.contains { $0.hasPrefix("mcp__mock_external__") },
                "\(intent.rawValue)"
            )
        }
    }

    func testRouteAdjustmentCannotReintroduceRefreshTools() {
        let route = SortAssistantActionRouter().route(for: .askContext)
        let adjusted = route.applying(SortAssistantRouteAdjustment(
            allowedToolsMode: .append,
            allowedTools: Array(sortAssistantDebugOnlyContextTools) + ["assistant_working_context_get"]
        ))

        for tool in sortAssistantDebugOnlyContextTools {
            XCTAssertFalse(adjusted.allowedTools.contains(tool), "route adjustment should not expose \(tool)")
        }
        XCTAssertTrue(adjusted.allowedTools.contains("assistant_working_context_get"))
    }

    func testEmptyAllowedToolsFallbackCannotReintroduceRefreshTools() {
        let route = SortAssistantActionRouter().route(for: .workspaceColor)
        let adjusted = route.applying(
            SortAssistantRouteAdjustment(allowedToolsMode: .replace),
            emptyAllowedToolsFallback: Array(sortAssistantDebugOnlyContextTools) + ["workspace_color_get"]
        )

        for tool in sortAssistantDebugOnlyContextTools {
            XCTAssertFalse(adjusted.allowedTools.contains(tool), "empty fallback should not expose \(tool)")
        }
        XCTAssertTrue(adjusted.allowedTools.contains("workspace_color_get"))
    }

    func testContextPromptReadsSnapshotsInsteadOfCollectingContext() throws {
        let prompt = try XCTUnwrap(
            SortAssistantMCPClient.promptFragmentTextForTesting(named: "context")
        )

        XCTAssertFalse(prompt.contains("Gather relevant context"))
        XCTAssertFalse(prompt.contains("context_collect"))
        XCTAssertFalse(prompt.contains("repository_context"))
        XCTAssertFalse(prompt.contains("workspace_digest_refresh"))
        XCTAssertTrue(prompt.contains("assistant_working_context_get"))
        XCTAssertTrue(prompt.contains("ContextAgent"))
        XCTAssertTrue(prompt.contains("freshness"))
    }

    func testSortPromptsReadSnapshotBackedContextInsteadOfSortContext() throws {
        let sortPrompt = try XCTUnwrap(
            SortAssistantMCPClient.promptFragmentTextForTesting(named: "sort")
        )
        let explainPrompt = try XCTUnwrap(
            SortAssistantMCPClient.promptFragmentTextForTesting(named: "explain_order")
        )

        XCTAssertFalse(sortPrompt.contains("sort_context"))
        XCTAssertFalse(explainPrompt.contains("sort_context"))
        XCTAssertTrue(sortPrompt.contains("assistant_working_context_get"))
        XCTAssertTrue(sortPrompt.contains("ranking_latest_get"))
        XCTAssertTrue(explainPrompt.contains("assistant_working_context_get"))
        XCTAssertTrue(explainPrompt.contains("ranking_latest_get"))
    }

    func testDisableRealLLMSemanticRoutingUsesDeterministicContextRoute() async {
        let decision = await SortAssistantIntentRouter().semanticIntent(
            for: "summarize context",
            runtimeMode: noLLMRuntimeMode()
        )

        XCTAssertEqual(decision.intent, .askContext)
        XCTAssertEqual(decision.confidence, 1)
        XCTAssertEqual(decision.reason, "real_llm_disabled")
    }

    func testDisableRealLLMSemanticRoutingDoesNotTreatPlainChatAsSort() async {
        let decision = await SortAssistantIntentRouter().semanticIntent(
            for: "who are you?",
            runtimeMode: noLLMRuntimeMode()
        )

        XCTAssertEqual(decision.intent, .normalChat)
        XCTAssertEqual(decision.reason, "real_llm_disabled")
    }

    func testDisableRealLLMSemanticRoutingKeepsColorSortRoute() async {
        let decision = await SortAssistantIntentRouter().semanticIntent(
            for: "preview a sort by color",
            runtimeMode: noLLMRuntimeMode()
        )

        XCTAssertEqual(decision.intent, .proposeSort)
        XCTAssertEqual(decision.sortRoute, .colorGroup)
    }

    func testWorkspaceSnapshotContextHashIgnoresUpdatedAtButTracksSemanticChanges() {
        let workspaceId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let context = NormalizedWorkspaceContext(
            title: "API fix",
            selected: true,
            directory: "/tmp/cmux",
            listRevision: 7,
            nativeOrder: 0,
            pinned: false,
            locked: false,
            customColor: nil,
            panelCount: 1,
            pullRequestCount: 1,
            stalePullRequestCount: 0
        )
        let derived = DerivedWorkspaceState(
            status: "waiting_user",
            priorityScore: 91,
            rankReason: "Needs review",
            nextAction: "Review agent output",
            userAttentionNeeded: 0.91
        )
        let freshness = ContextFreshness(
            providers: [
                ProviderFreshness(
                    providerId: "summary_priority",
                    lastCollectedAt: Date(timeIntervalSince1970: 1_000),
                    ttlSeconds: 120,
                    stale: false,
                    error: nil,
                    confidence: 1
                ),
            ],
            overallConfidence: 1
        )

        let first = WorkspaceSnapshot(
            workspaceId: workspaceId,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            context: context,
            derived: derived,
            digest: WorkspaceDigest(summary: "Agent is waiting for user review.", generatedAt: nil),
            freshness: freshness
        )
        let later = WorkspaceSnapshot(
            workspaceId: workspaceId,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1_030),
            context: context,
            derived: derived,
            digest: WorkspaceDigest(summary: "Agent is waiting for user review.", generatedAt: nil),
            freshness: freshness
        )
        let changed = WorkspaceSnapshot(
            workspaceId: workspaceId,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1_030),
            context: context,
            derived: DerivedWorkspaceState(
                status: "running",
                priorityScore: 10,
                rankReason: "No user action needed",
                nextAction: nil,
                userAttentionNeeded: 0.1
            ),
            digest: WorkspaceDigest(summary: "Agent is running.", generatedAt: nil),
            freshness: freshness
        )

        XCTAssertEqual(first.contextHash, later.contextHash)
        XCTAssertNotEqual(first.contextHash, changed.contextHash)
    }

    func testDigestUpdatePolicySkipsTimestampOnlySnapshotChange() {
        let workspaceId = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let previous = makeWorkspaceSnapshot(
            workspaceId: workspaceId,
            title: "Running",
            nativeOrder: 0,
            confidence: 1,
            status: "running"
        )
        let next = WorkspaceSnapshot(
            workspaceId: previous.workspaceId,
            version: previous.version,
            updatedAt: previous.updatedAt.addingTimeInterval(30),
            context: previous.context,
            derived: previous.derived,
            digest: previous.digest,
            freshness: previous.freshness
        )

        XCTAssertFalse(WorkspaceDigestUpdatePolicy.semanticContextHash.shouldUpdate(
            previous: previous,
            next: next
        ))
    }

    func testDigestUpdatePolicyUpdatesWhenSemanticSnapshotChanges() {
        let workspaceId = UUID(uuidString: "13131313-1313-1313-1313-131313131313")!
        let previous = makeWorkspaceSnapshot(
            workspaceId: workspaceId,
            title: "Running",
            nativeOrder: 0,
            confidence: 1,
            status: "running"
        )
        let next = makeWorkspaceSnapshot(
            workspaceId: workspaceId,
            title: "Waiting",
            nativeOrder: 0,
            confidence: 1,
            status: "waiting_user",
            userAttentionNeeded: 0.9
        )

        XCTAssertTrue(WorkspaceDigestUpdatePolicy.semanticContextHash.shouldUpdate(
            previous: previous,
            next: next
        ))
    }

    func testProviderFreshnessMarksStaleAfterTTL() {
        let now = Date(timeIntervalSince1970: 1_000)
        let provider = ProviderFreshness(
            providerId: "summary_priority",
            lastCollectedAt: now.addingTimeInterval(-121),
            ttlSeconds: 120,
            stale: false,
            error: nil,
            confidence: 1
        )

        XCTAssertTrue(provider.evaluated(at: now).stale)
    }

    func testWorkspaceSnapshotStoreReturnsLatestWorkingContext() async throws {
        let store = WorkspaceSnapshotStore()
        let firstId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let secondId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let suggestionId = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let rankingId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let first = makeWorkspaceSnapshot(
            workspaceId: firstId,
            title: "First",
            nativeOrder: 1,
            confidence: 0.6
        )
        let second = makeWorkspaceSnapshot(
            workspaceId: secondId,
            title: "Second",
            nativeOrder: 0,
            confidence: 0.9
        )
        let suggestion = ProactiveSuggestion(
            id: suggestionId,
            workspaceId: secondId,
            type: "sort_preview_ready",
            title: "Sort preview ready",
            reason: "The sidebar has a proposed ranking.",
            confidence: 0.8,
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let ranking = RankingSnapshot(
            id: rankingId,
            updatedAt: Date(timeIntervalSince1970: 2_000),
            items: [
                RankingSnapshot.Item(workspaceId: secondId, rank: 1, score: 91, reason: "Waiting for review"),
            ]
        )

        await store.replace(AssistantWorkingContext(
            activeWorkspaceId: secondId,
            snapshots: [first, second],
            freshness: ContextFreshness(providers: [], overallConfidence: 0.75),
            activeSuggestions: [suggestion],
            latestRanking: ranking
        ))

        let context = await store.assistantWorkingContext()
        XCTAssertEqual(context.activeWorkspaceId, secondId)
        XCTAssertEqual(context.snapshots.map(\.workspaceId), [secondId, firstId])
        XCTAssertEqual(context.activeSuggestions.map(\.id), [suggestionId])
        XCTAssertEqual(context.latestRanking?.id, rankingId)
        assertEqual(await store.workspaceSnapshot(firstId)?.workspaceId, firstId)
    }

    func testSuggestionAndRankingStoresPublishThroughAssistantContextReader() async throws {
        let snapshotStore = WorkspaceSnapshotStore()
        let suggestionStore = SuggestionSnapshotStore(snapshotStore: snapshotStore)
        let rankingStore = RankingSnapshotStore(snapshotStore: snapshotStore)
        let workspaceId = UUID(uuidString: "56565656-5656-5656-5656-565656565656")!
        let suggestionId = UUID(uuidString: "57575757-5757-5757-5757-575757575757")!
        let rankingId = UUID(uuidString: "58585858-5858-5858-5858-585858585858")!
        let suggestion = ProactiveSuggestion(
            id: suggestionId,
            workspaceId: workspaceId,
            type: ProactiveSuggestionTypes.reviewAgentWaitingUser,
            title: "Review waiting agent",
            reason: "Agent needs review",
            confidence: 0.9,
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let ranking = RankingSnapshot(
            id: rankingId,
            updatedAt: Date(timeIntervalSince1970: 2_000),
            items: [
                RankingSnapshot.Item(workspaceId: workspaceId, rank: 1, score: 90, reason: "Agent needs review"),
            ]
        )

        await snapshotStore.write(makeWorkspaceSnapshot(
            workspaceId: workspaceId,
            title: "Waiting",
            nativeOrder: 0,
            confidence: 1,
            status: "waiting_user"
        ))
        await suggestionStore.setActiveSuggestions([suggestion])
        await rankingStore.setLatestRanking(ranking)

        let context = await snapshotStore.assistantWorkingContext()
        let storedSuggestionIds = await suggestionStore.activeSuggestions().map(\.id)
        let storedRanking = await rankingStore.latestRanking()
        XCTAssertEqual(context.activeSuggestions.map(\.id), [suggestionId])
        XCTAssertEqual(context.latestRanking?.id, rankingId)
        XCTAssertEqual(storedSuggestionIds, [suggestionId])
        XCTAssertEqual(storedRanking?.id, rankingId)
    }

    func testWorkspaceSnapshotStoreAggregatesFreshnessForIncrementalWrites() async {
        let store = WorkspaceSnapshotStore()
        let firstId = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let secondId = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

        await store.write(makeWorkspaceSnapshot(
            workspaceId: firstId,
            title: "First",
            nativeOrder: 0,
            confidence: 0.5
        ))
        await store.write(makeWorkspaceSnapshot(
            workspaceId: secondId,
            title: "Second",
            nativeOrder: 1,
            confidence: 1.0
        ), activeWorkspaceId: secondId)

        let context = await store.assistantWorkingContext()
        XCTAssertEqual(context.activeWorkspaceId, secondId)
        XCTAssertEqual(context.freshness.providers.count, 2)
        XCTAssertEqual(context.freshness.overallConfidence, 0.75, accuracy: 0.0001)
    }

    func testAssistantRuntimeReadsContextThroughSnapshotReader() async {
        let workspaceId = UUID(uuidString: "78787878-7878-7878-7878-787878787878")!
        var snapshot = makeWorkspaceSnapshot(
            workspaceId: workspaceId,
            title: "Stale PR",
            nativeOrder: 0,
            confidence: 1
        )
        snapshot.freshness = ContextFreshness(
            providers: [
                ProviderFreshness(
                    providerId: "github_context",
                    lastCollectedAt: Date(timeIntervalSince1970: 100),
                    ttlSeconds: 30,
                    stale: false,
                    error: nil,
                    confidence: 1
                ),
            ],
            overallConfidence: 1
        )
        let reader = StubAssistantContextReader(context: AssistantWorkingContext(
            activeWorkspaceId: workspaceId,
            snapshots: [snapshot],
            freshness: snapshot.freshness,
            activeSuggestions: [],
            latestRanking: nil
        ))
        let runtime = AssistantRuntime(contextReader: reader)

        let read = await runtime.readContextForAnswer(now: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(read.snapshotVersions, [workspaceId: 1])
        XCTAssertEqual(read.staleProviderIds, ["github_context"])
        XCTAssertFalse(read.missingSnapshot)
        assertEqual(await reader.workingContextReadCount(), 1)
    }

    func testAssistantRuntimeSubmitsActionsThroughGateway() async throws {
        let reader = StubAssistantContextReader(context: AssistantWorkingContext(
            activeWorkspaceId: nil,
            snapshots: [],
            freshness: ContextFreshness(providers: [], overallConfidence: 0),
            activeSuggestions: [],
            latestRanking: nil
        ))
        let executor = RecordingActionExecutor()
        let auditLog = RecordingActionAuditLog()
        let gateway = SemanticActionGateway(
            reviewers: [AllowingActionReviewer()],
            executor: executor,
            auditLog: auditLog
        )
        let runtime = AssistantRuntime(contextReader: reader, actionGateway: gateway)
        let intent = makeActionIntent(
            id: UUID(uuidString: "79797979-7979-7979-7979-797979797979")!,
            snapshotUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )

        let result = try await runtime.submitAction(intent)

        XCTAssertEqual(result.decision, .allow)
        XCTAssertTrue(result.executed)
        assertEqual(await executor.executedIntentIds(), [intent.id])
        assertEqual(await auditLog.reviewedIntentIds(), [intent.id])
    }

    func testContextSchedulerDeduplicatesByWorkspaceAndOrdersByPriority() async {
        let scheduler = ContextScheduler()
        let firstId = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let secondId = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

        await scheduler.enqueue(ContextRefreshJob(
            workspaceId: firstId,
            reason: "visible",
            priority: .visible,
            enqueuedAt: Date(timeIntervalSince1970: 10)
        ))
        await scheduler.enqueue(ContextRefreshJob(
            workspaceId: secondId,
            reason: "assistant_query_started",
            priority: .userInitiated,
            enqueuedAt: Date(timeIntervalSince1970: 20)
        ))
        await scheduler.enqueue(ContextRefreshJob(
            workspaceId: firstId,
            reason: "background_tick",
            priority: .background,
            enqueuedAt: Date(timeIntervalSince1970: 30)
        ))

        assertEqual(await scheduler.pendingJobCount(), 2)
        assertEqual(await scheduler.pendingJobs().map(\.workspaceId), [secondId, firstId])

        let firstBatch = await scheduler.nextBatch(maxJobs: 1)
        XCTAssertEqual(firstBatch.map(\.workspaceId), [secondId])
        assertEqual(await scheduler.pendingJobs().map(\.workspaceId), [firstId])
    }

    func testContextSchedulerAttentionLeasePromotesQueuedRefreshPriority() async {
        let scheduler = ContextScheduler()
        let workspaceId = UUID(uuidString: "87878787-8787-8787-8787-878787878787")!

        await scheduler.setLease(.hot, for: workspaceId)
        await scheduler.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "background_tick",
            priority: .background,
            enqueuedAt: Date(timeIntervalSince1970: 10)
        ), honoringAttentionLease: true)

        let job = await scheduler.pendingJobs().first

        assertEqual(await scheduler.lease(for: workspaceId), .hot)
        XCTAssertEqual(job?.workspaceId, workspaceId)
        XCTAssertEqual(job?.priority, .userInitiated)
    }

    func testContextSchedulerEnqueuesHotProviderRefreshBeforeColdWorkspace() async {
        let scheduler = ContextScheduler()
        let hotId = UUID(uuidString: "8C8C8C8C-8C8C-8C8C-8C8C-8C8C8C8C8C8C")!
        let coldId = UUID(uuidString: "8D8D8D8D-8D8D-8D8D-8D8D-8D8D8D8D8D8D")!
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
            now: Date(timeIntervalSince1970: 25),
            reason: "provider_due"
        )

        let jobs = await scheduler.pendingJobs()

        XCTAssertEqual(jobs.map(\.workspaceId), [hotId])
        XCTAssertEqual(jobs.map(\.providerId), ["git"])
        XCTAssertEqual(jobs.map(\.priority), [.userInitiated])
    }

    func testContextSchedulerDebouncesProviderSignalBurst() async {
        let scheduler = ContextScheduler()
        let workspaceId = UUID(uuidString: "8E8E8E8E-8E8E-8E8E-8E8E-8E8E8E8E8E8E")!
        let start = Date(timeIntervalSince1970: 100)

        for offset in 0..<20 {
            await scheduler.enqueueProviderSignal(
                providerId: "git",
                workspaceId: workspaceId,
                reason: "git_changed",
                enqueuedAt: start.addingTimeInterval(Double(offset) * 0.05),
                debounceSeconds: 2
            )
        }

        let jobs = await scheduler.pendingJobs()

        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.workspaceId, workspaceId)
        XCTAssertEqual(jobs.first?.providerId, "git")
        XCTAssertEqual(jobs.first?.reason, "git_changed")
    }

    func testContextSchedulerDiagnosticsExposeQueuedJobsLeasesAndProviderCadence() async throws {
        let scheduler = ContextScheduler()
        let workspaceId = UUID(uuidString: "8B8B8B8B-8B8B-8B8B-8B8B-8B8B8B8B8B8B")!
        let collectedAt = Date(timeIntervalSince1970: 90)
        let signaledAt = Date(timeIntervalSince1970: 100)

        await scheduler.setLease(.hot, for: workspaceId)
        await scheduler.markProviderCollected("git", workspace: workspaceId, at: collectedAt)
        await scheduler.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "assistant.query_started",
            priority: .background,
            enqueuedAt: Date(timeIntervalSince1970: 95)
        ), honoringAttentionLease: true)
        await scheduler.enqueueProviderSignal(
            providerId: "git",
            workspaceId: workspaceId,
            reason: "git_changed",
            enqueuedAt: signaledAt,
            debounceSeconds: 2
        )

        let diagnostics = await scheduler.diagnostics()
        let collection = try XCTUnwrap(diagnostics.providerCollections.first)

        XCTAssertEqual(diagnostics.workspaceLeases, [
            ContextWorkspaceLeaseDiagnostic(workspaceId: workspaceId, lease: .hot),
        ])
        XCTAssertEqual(diagnostics.pendingJobs.map(\.workspaceId), [workspaceId, workspaceId])
        XCTAssertEqual(diagnostics.pendingJobs.map(\.providerId), [nil, "git"])
        XCTAssertEqual(diagnostics.pendingJobs.map(\.priority), [.userInitiated, .userInitiated])
        XCTAssertEqual(collection.workspaceId, workspaceId)
        XCTAssertEqual(collection.providerId, "git")
        XCTAssertEqual(collection.lastCollectedAt, collectedAt)
        XCTAssertEqual(collection.lastSignaledAt, signaledAt)
    }

    func testProviderRegistryReturnsEnabledProvidersInRegistrationOrder() async {
        let recording = RecordingWorkspaceSnapshotProvider()
        let alternate = AlternateWorkspaceSnapshotProvider()
        let registry = ProviderRegistry(providers: [recording, alternate])

        assertEqual(await registry.providerIds(), ["recording", "alternate"])
        assertEqual(await registry.providers(matching: nil).map(\.providerId), ["recording", "alternate"])

        await registry.setEnabled(false, providerId: "recording")

        assertEqual(await registry.providerIds(), ["alternate"])
        assertEqual(await registry.providerIds(includeDisabled: true), ["recording", "alternate"])
        assertEqual(await registry.providers(matching: nil).map(\.providerId), ["alternate"])
        assertEqual(await registry.providers(matching: "recording").map(\.providerId), [])

        await registry.setEnabled(true, providerId: "recording")

        assertEqual(await registry.providers(matching: "recording").map(\.providerId), ["recording"])
    }

    func testContextAgentCanRegisterSnapshotProviderAfterInitialization() async {
        let store = WorkspaceSnapshotStore()
        let provider = RecordingWorkspaceSnapshotProvider()
        let agent = ContextAgent(snapshotStore: store, providers: [])
        let workspaceId = UUID(uuidString: "8C818181-8181-8181-8181-818181818181")!

        await agent.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "attention_before_provider",
            priority: .visible,
            enqueuedAt: Date(timeIntervalSince1970: 10)
        ))

        let emptyResult = await agent.runScheduledBatch()
        XCTAssertEqual(emptyResult.updatedWorkspaceIds, [])
        assertEqual(await agent.providerRunRecords(), [])
        assertEqual(await store.workspaceSnapshot(workspaceId), nil)

        await agent.registerProvider(provider)
        await agent.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "attention_after_provider",
            priority: .visible,
            enqueuedAt: Date(timeIntervalSince1970: 20)
        ))

        let result = await agent.runScheduledBatch()

        assertEqual(await agent.providerIds(), ["recording"])
        XCTAssertEqual(result.updatedWorkspaceIds, [workspaceId])
        assertEqual(await store.workspaceSnapshot(workspaceId)?.workspaceId, workspaceId)
        let records = await agent.providerRunRecords()
        XCTAssertEqual(records.map(\.providerId), ["recording"])
    }

    func testContextAgentRunsQueuedJobsThroughSnapshotProvider() async throws {
        let store = WorkspaceSnapshotStore()
        let provider = RecordingWorkspaceSnapshotProvider()
        let agent = ContextAgent(snapshotStore: store, providers: [provider])
        let firstId = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let secondId = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

        await agent.enqueue(ContextRefreshJob(
            workspaceId: firstId,
            reason: "workspace_visible",
            priority: .visible,
            enqueuedAt: Date(timeIntervalSince1970: 10)
        ))
        await agent.enqueue(ContextRefreshJob(
            workspaceId: secondId,
            reason: "assistant_query_started",
            priority: .userInitiated,
            enqueuedAt: Date(timeIntervalSince1970: 20)
        ))

        let result = await agent.runScheduledBatch()

        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.updatedWorkspaceIds, [secondId, firstId])
        assertEqual(await agent.queuedJobCount(), 0)
        assertEqual(await provider.requestedWorkspaceIds(), [secondId, firstId])
        assertEqual(await store.workspaceSnapshot(firstId)?.workspaceId, firstId)
        assertEqual(await store.workspaceSnapshot(secondId)?.context.title, "workspace-\(secondId.uuidString)")
    }

    func testContextAgentMergesProviderFreshnessForSameWorkspace() async throws {
        let store = WorkspaceSnapshotStore()
        let recording = RecordingWorkspaceSnapshotProvider()
        let alternate = AlternateWorkspaceSnapshotProvider()
        let agent = ContextAgent(snapshotStore: store, providers: [recording, alternate])
        let workspaceId = UUID(uuidString: "8D8E8F80-1111-2222-3333-444444444444")!

        await agent.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "provider_due",
            priority: .visible,
            enqueuedAt: Date(timeIntervalSince1970: 30)
        ))

        let result = await agent.runScheduledBatch()
        let storedSnapshot = await store.workspaceSnapshot(workspaceId)
        let snapshot = try XCTUnwrap(storedSnapshot)
        let records = await agent.providerRunRecords()

        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.updatedWorkspaceIds, [workspaceId])
        XCTAssertEqual(records.map(\.providerId).sorted(), ["alternate", "recording"])
        XCTAssertEqual(snapshot.freshness.providers.map(\.providerId).sorted(), ["alternate", "recording"])
        XCTAssertEqual(snapshot.freshness.overallConfidence, 1)
        XCTAssertEqual(snapshot.context.title, "workspace-\(workspaceId.uuidString)")
    }

    func testContextAgentKeepsHigherPriorityQueuedJobForWorkspace() async {
        let store = WorkspaceSnapshotStore()
        let provider = RecordingWorkspaceSnapshotProvider()
        let agent = ContextAgent(snapshotStore: store, providers: [provider])
        let workspaceId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        await agent.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "assistant_query_started",
            priority: .userInitiated,
            enqueuedAt: Date(timeIntervalSince1970: 20)
        ))
        await agent.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "background_tick",
            priority: .background,
            enqueuedAt: Date(timeIntervalSince1970: 30)
        ))

        let result = await agent.runScheduledBatch()

        XCTAssertEqual(result.updatedWorkspaceIds, [workspaceId])
        assertEqual(await provider.requestedReasons(), ["assistant_query_started"])
    }

    func testContextAgentUsesProviderRegistryEnablement() async {
        let store = WorkspaceSnapshotStore()
        let recording = RecordingWorkspaceSnapshotProvider()
        let alternate = AlternateWorkspaceSnapshotProvider()
        let registry = ProviderRegistry(providers: [recording, alternate])
        let agent = ContextAgent(
            snapshotStore: store,
            providerRegistry: registry,
            providers: []
        )
        let workspaceId = UUID(uuidString: "90909090-9090-9090-9090-909090909090")!

        await registry.setEnabled(false, providerId: "recording")
        await agent.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "provider_due",
            priority: .visible,
            enqueuedAt: Date(timeIntervalSince1970: 30)
        ))

        let result = await agent.runScheduledBatch()

        assertEqual(await agent.providerIds(), ["alternate"])
        XCTAssertEqual(result.updatedWorkspaceIds, [workspaceId])
        assertEqual(await recording.requestedWorkspaceIds(), [])
        assertEqual(await alternate.requestedWorkspaceIds(), [workspaceId])
    }

    func testContextAgentLimitsConcurrentProviderRuns() async {
        let store = WorkspaceSnapshotStore()
        let probe = ProviderConcurrencyProbe()
        let providers: [any WorkspaceSnapshotProviding] = [
            TrackingWorkspaceSnapshotProvider(providerId: "tracked_1", probe: probe),
            TrackingWorkspaceSnapshotProvider(providerId: "tracked_2", probe: probe),
            TrackingWorkspaceSnapshotProvider(providerId: "tracked_3", probe: probe),
        ]
        let agent = ContextAgent(
            snapshotStore: store,
            executionPolicy: ContextProviderExecutionPolicy(
                maxConcurrentProviderRuns: 2,
                providerTimeoutSeconds: nil
            ),
            providers: providers
        )
        let workspaceId = UUID(uuidString: "91919191-9191-9191-9191-919191919191")!

        await agent.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "provider_due",
            priority: .visible,
            enqueuedAt: Date(timeIntervalSince1970: 30)
        ))

        let result = await agent.runScheduledBatch()

        XCTAssertEqual(result.failures, [])
        assertEqual(await probe.maxActiveCount(), 2)
        assertEqual(await agent.providerRunRecords().count, 3)
    }

    func testContextAgentRecordsProviderTimeoutFailure() async {
        let store = WorkspaceSnapshotStore()
        let slow = SlowWorkspaceSnapshotProvider()
        let agent = ContextAgent(
            snapshotStore: store,
            executionPolicy: ContextProviderExecutionPolicy(
                maxConcurrentProviderRuns: 1,
                providerTimeoutSeconds: 0.01
            ),
            providers: [slow]
        )
        let workspaceId = UUID(uuidString: "92929292-9292-9292-9292-929292929292")!

        await agent.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "provider_due",
            priority: .visible,
            enqueuedAt: Date(timeIntervalSince1970: 30)
        ))

        let result = await agent.runScheduledBatch()
        let records = await agent.providerRunRecords()

        XCTAssertEqual(result.updatedWorkspaceIds, [])
        XCTAssertEqual(result.failures.map(\.providerId), ["slow"])
        XCTAssertTrue(result.failures.first?.message.contains("timeout") ?? false)
        XCTAssertEqual(records.map(\.providerId), ["slow"])
        XCTAssertFalse(records.first?.success ?? true)
        XCTAssertTrue(records.first?.errorMessage?.contains("timeout") ?? false)
    }

    func testContextAgentProviderSpecificJobRunsOnlyMatchingProvider() async {
        let store = WorkspaceSnapshotStore()
        let recording = RecordingWorkspaceSnapshotProvider()
        let alternate = AlternateWorkspaceSnapshotProvider()
        let agent = ContextAgent(snapshotStore: store, providers: [recording, alternate])
        let workspaceId = UUID(uuidString: "8F8F8F8F-8F8F-8F8F-8F8F-8F8F8F8F8F8F")!

        await agent.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "provider_due",
            priority: .visible,
            enqueuedAt: Date(timeIntervalSince1970: 25),
            providerId: "recording"
        ))

        let result = await agent.runScheduledBatch()

        XCTAssertEqual(result.updatedWorkspaceIds, [workspaceId])
        assertEqual(await recording.requestedWorkspaceIds(), [workspaceId])
        assertEqual(await alternate.requestedWorkspaceIds(), [])
    }

    func testContextAgentWorkspaceAttentionEnqueuesPromotedRefresh() async {
        let store = WorkspaceSnapshotStore()
        let scheduler = ContextScheduler()
        let provider = RecordingWorkspaceSnapshotProvider()
        let agent = ContextAgent(snapshotStore: store, scheduler: scheduler, providers: [provider])
        let workspaceId = UUID(uuidString: "89898989-8989-8989-8989-898989898989")!

        await agent.handleWorkspaceAttention(
            workspaceId: workspaceId,
            reason: "assistant_panel_opened",
            lease: .visible,
            now: Date(timeIntervalSince1970: 20)
        )

        let jobs = await scheduler.pendingJobs()

        assertEqual(await scheduler.lease(for: workspaceId), .visible)
        XCTAssertEqual(jobs.map(\.workspaceId), [workspaceId])
        XCTAssertEqual(jobs.map(\.reason), ["assistant_panel_opened"])
        XCTAssertEqual(jobs.map(\.priority), [.visible])
    }

    func testContextAgentMessageEventSchedulesAgentSessionProvider() async throws {
        let store = WorkspaceSnapshotStore()
        let scheduler = ContextScheduler()
        let provider = RecordingWorkspaceSnapshotProvider()
        let agent = ContextAgent(snapshotStore: store, scheduler: scheduler, providers: [provider])
        let workspaceId = UUID(uuidString: "8A8A8A8A-8A8A-8A8A-8A8A-8A8A8A8A8A8A")!
        let event = ContextAgentEvent(
            name: ContextAgentEvent.agentMessageAppendedName,
            workspaceId: workspaceId,
            occurredAt: Date(timeIntervalSince1970: 50),
            payload: ["status": "waiting_user"]
        )

        await agent.handle(event)

        let pendingJobs = await scheduler.pendingJobs()
        let job = try XCTUnwrap(pendingJobs.first)

        XCTAssertEqual(job.workspaceId, workspaceId)
        XCTAssertEqual(job.reason, ContextAgentEvent.agentMessageAppendedName)
        XCTAssertEqual(job.priority, .visible)
        XCTAssertNil(job.providerId)
        XCTAssertEqual(job.payload["status"], "waiting_user")
        assertEqual(await scheduler.lease(for: workspaceId), .visible)
    }

    func testContextAgentRoutesWorkspaceEventsToRegisteredProviderSlices() async {
        let store = WorkspaceSnapshotStore()
        let scheduler = ContextScheduler()
        let probe = ProviderConcurrencyProbe()
        let providers: [any WorkspaceSnapshotProviding] = [
            TrackingWorkspaceSnapshotProvider(providerId: "list_state", probe: probe),
            TrackingWorkspaceSnapshotProvider(providerId: "github_context", probe: probe),
            TrackingWorkspaceSnapshotProvider(providerId: "summary_priority", probe: probe),
        ]
        let agent = ContextAgent(snapshotStore: store, scheduler: scheduler, providers: providers)
        let workspaceId = UUID(uuidString: "8A8B8C8D-0000-1111-2222-333333333333")!
        let event = ContextAgentEvent(
            name: "workspace.selected",
            workspaceId: workspaceId,
            occurredAt: Date(timeIntervalSince1970: 60)
        )

        await agent.handle(event)

        let jobs = await scheduler.pendingJobs()

        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(Set(jobs.map(\.workspaceId)), Set([workspaceId]))
        XCTAssertEqual(Set(jobs.compactMap(\.providerId)), Set(["list_state", "summary_priority"]))
        XCTAssertEqual(Set(jobs.map(\.priority)), Set([ContextRefreshPriority.visible]))
        assertEqual(await scheduler.lease(for: workspaceId), .visible)
    }

    func testContextAgentRoutesAssistantQueryToAllRegisteredContextProviderSlices() async {
        let store = WorkspaceSnapshotStore()
        let scheduler = ContextScheduler()
        let probe = ProviderConcurrencyProbe()
        let providers: [any WorkspaceSnapshotProviding] = [
            TrackingWorkspaceSnapshotProvider(providerId: "list_state", probe: probe),
            TrackingWorkspaceSnapshotProvider(providerId: "agent_session", probe: probe),
            TrackingWorkspaceSnapshotProvider(providerId: "github_context", probe: probe),
            TrackingWorkspaceSnapshotProvider(providerId: "summary_priority", probe: probe),
        ]
        let agent = ContextAgent(snapshotStore: store, scheduler: scheduler, providers: providers)
        let workspaceId = UUID(uuidString: "8A8B8C8D-4444-5555-6666-777777777777")!
        let event = ContextAgentEvent(
            name: "assistant.query_started",
            workspaceId: workspaceId,
            occurredAt: Date(timeIntervalSince1970: 70)
        )

        await agent.handle(event)

        let jobs = await scheduler.pendingJobs()

        XCTAssertEqual(jobs.count, 4)
        XCTAssertEqual(Set(jobs.compactMap(\.providerId)), Set([
            "list_state",
            "agent_session",
            "github_context",
            "summary_priority",
        ]))
        XCTAssertEqual(Set(jobs.map(\.priority)), Set([ContextRefreshPriority.userInitiated]))
        assertEqual(await scheduler.lease(for: workspaceId), .hot)
    }

    func testContextAgentEventStreamDrainsPublishedWorkspaceEvents() async throws {
        let eventBus = CmuxEventBus(eventLogURL: nil)
        let store = WorkspaceSnapshotStore()
        let provider = RecordingWorkspaceSnapshotProvider()
        let agent = ContextAgent(snapshotStore: store, providers: [provider])
        let workspaceId = UUID(uuidString: "8D828282-8282-8282-8282-828282828282")!
        let streamTask = agent.startEventStream(
            from: eventBus,
            pollTimeout: 0.01,
            batchMaxJobs: 4
        )
        defer { streamTask.cancel() }

        eventBus.publish(
            name: "workspace.selected",
            category: "workspace",
            source: "test",
            workspaceId: workspaceId.uuidString,
            payload: ["title": "Selected"]
        )

        let records = await waitForProviderRunRecords(agent, minimumCount: 1)

        XCTAssertEqual(records.map(\.workspaceId), [workspaceId])
        XCTAssertEqual(records.map(\.providerId), ["recording"])
        XCTAssertEqual(records.map(\.reason), ["workspace.selected"])
        assertEqual(await store.workspaceSnapshot(workspaceId)?.workspaceId, workspaceId)
    }

    func testAssistantQueryEventStreamRefreshesContextAgentSnapshot() async throws {
        let eventBus = CmuxEventBus(eventLogURL: nil)
        let store = WorkspaceSnapshotStore()
        let provider = RecordingWorkspaceSnapshotProvider()
        let agent = ContextAgent(snapshotStore: store, providers: [provider])
        let workspaceId = UUID(uuidString: "8D828282-8282-8282-8282-828282828283")!
        let streamTask = agent.startEventStream(
            from: eventBus,
            pollTimeout: 0.01,
            batchMaxJobs: 4
        )
        defer { streamTask.cancel() }

        eventBus.publishAssistantQueryStarted(
            workspaceId: workspaceId,
            targetWorkspaceId: nil,
            source: "test",
            queryCharacterCount: 18,
            reason: "assistant.query_started"
        )

        let records = await waitForProviderRunRecords(agent, minimumCount: 1)

        XCTAssertEqual(records.map(\.workspaceId), [workspaceId])
        XCTAssertEqual(records.map(\.providerId), ["recording"])
        XCTAssertEqual(records.map(\.reason), ["assistant.query_started"])
        XCTAssertEqual(records.map(\.priority), [.userInitiated])
        assertEqual(await store.workspaceSnapshot(workspaceId)?.workspaceId, workspaceId)
    }

    func testContextAgentRecordsProviderRunMetadata() async throws {
        let store = WorkspaceSnapshotStore()
        let scheduler = ContextScheduler()
        let runStore = ProviderRunStore()
        let provider = RecordingWorkspaceSnapshotProvider()
        let agent = ContextAgent(
            snapshotStore: store,
            scheduler: scheduler,
            providerRunStore: runStore,
            providers: [provider]
        )
        let workspaceId = UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!

        await agent.enqueue(ContextRefreshJob(
            workspaceId: workspaceId,
            reason: "agent_message_appended",
            priority: .visible,
            enqueuedAt: Date(timeIntervalSince1970: 40)
        ))

        let result = await agent.runScheduledBatch()
        let records = await runStore.records(for: workspaceId)
        let record = try XCTUnwrap(records.first)

        XCTAssertEqual(result.updatedWorkspaceIds, [workspaceId])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.providerId, "recording")
        XCTAssertEqual(record.reason, "agent_message_appended")
        XCTAssertEqual(record.priority, .visible)
        XCTAssertTrue(record.success)
        XCTAssertEqual(record.snapshotVersion, 1)
        XCTAssertNil(record.errorMessage)
        XCTAssertLessThanOrEqual(record.startedAt, record.finishedAt)
        assertEqual(await agent.providerRunRecords(), records)
    }

    func testContextAgentDiagnosticsExposeSchedulerAndProviderRunMetadata() async throws {
        let store = WorkspaceSnapshotStore()
        let scheduler = ContextScheduler()
        let provider = RecordingWorkspaceSnapshotProvider()
        let agent = ContextAgent(
            snapshotStore: store,
            scheduler: scheduler,
            providers: [provider]
        )
        let workspaceId = UUID(uuidString: "BDBDBDBD-BDBD-BDBD-BDBD-BDBDBDBDBDBD")!

        await agent.handleWorkspaceAttention(
            workspaceId: workspaceId,
            reason: "assistant.query_started",
            lease: .hot,
            now: Date(timeIntervalSince1970: 200)
        )

        let queuedDiagnostics = await agent.diagnostics()
        XCTAssertEqual(queuedDiagnostics.providerIds, ["recording"])
        XCTAssertEqual(queuedDiagnostics.scheduler.workspaceLeases, [
            ContextWorkspaceLeaseDiagnostic(workspaceId: workspaceId, lease: .hot),
        ])
        XCTAssertEqual(queuedDiagnostics.scheduler.pendingJobs.map(\.workspaceId), [workspaceId])
        XCTAssertEqual(queuedDiagnostics.providerRuns, [])

        let result = await agent.runScheduledBatch()
        let drainedDiagnostics = await agent.diagnostics()
        let run = try XCTUnwrap(drainedDiagnostics.providerRuns.first)

        XCTAssertEqual(result.updatedWorkspaceIds, [workspaceId])
        XCTAssertEqual(drainedDiagnostics.scheduler.pendingJobs, [])
        XCTAssertEqual(drainedDiagnostics.scheduler.providerCollections.map(\.providerId), ["recording"])
        XCTAssertEqual(run.workspaceId, workspaceId)
        XCTAssertEqual(run.providerId, "recording")
        XCTAssertEqual(run.reason, "assistant.query_started")
        XCTAssertTrue(run.success)
        XCTAssertEqual(run.snapshotVersion, 1)
    }

    func testReplayProducesWaitingUserSnapshotAndSuggestion() async throws {
        let fixture = try loadContextAgentReplayFixture(named: "agent_waiting_user")
        let store = WorkspaceSnapshotStore()
        let provider = ReplayWorkspaceSnapshotProvider()
        let agent = ContextAgent(snapshotStore: store, providers: [provider])

        for event in fixture {
            await agent.handle(event)
        }
        let result = await agent.runScheduledBatch()
        let context = await store.assistantWorkingContext()
        let suggestions = SuggestionEngine.default.generate(from: context.snapshots)
        let snapshot = try XCTUnwrap(context.snapshots.first)

        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(result.updatedWorkspaceIds, [snapshot.workspaceId])
        XCTAssertEqual(snapshot.context.title, "API fix")
        XCTAssertEqual(snapshot.derived.status, "waiting_user")
        XCTAssertGreaterThan(snapshot.derived.userAttentionNeeded, 0.8)
        XCTAssertEqual(suggestions.map(\.type), [ProactiveSuggestionTypes.reviewAgentWaitingUser])
        XCTAssertEqual(suggestions.first?.workspaceId, snapshot.workspaceId)
    }

    func testReplayProducesCoreProactiveSuggestionAndRankingScenarios() async throws {
        let fixture = try loadContextAgentReplayFixture(named: "multi_status")
        let store = WorkspaceSnapshotStore()
        let provider = ReplayWorkspaceSnapshotProvider()
        let agent = ContextAgent(snapshotStore: store, providers: [provider])

        for event in fixture {
            await agent.handle(event)
        }
        let result = await agent.runScheduledBatch()
        let context = await store.assistantWorkingContext()
        let suggestions = SuggestionEngine.default.generate(from: context.snapshots)
        let ranking = RankingEngine.default.rank(context.snapshots)

        let waitingId = UUID(uuidString: "8B8B8B8B-8B8B-8B8B-8B8B-8B8B8B8B8B8B")!
        let ciFailedId = UUID(uuidString: "9C9C9C9C-9C9C-9C9C-9C9C-9C9C9C9C9C9C")!
        let readyToMergeId = UUID(uuidString: "ADADADAD-ADAD-ADAD-ADAD-ADADADADADAD")!

        XCTAssertEqual(result.failures, [])
        XCTAssertEqual(Set(result.updatedWorkspaceIds), Set([waitingId, ciFailedId, readyToMergeId]))
        XCTAssertEqual(
            context.snapshots.map { "\($0.context.title):\($0.derived.status)" },
            [
                "API fix:waiting_user",
                "CI failure:ci_failed",
                "Ready to merge:ready_to_merge",
            ]
        )
        XCTAssertEqual(
            suggestions.map(\.type),
            [
                ProactiveSuggestionTypes.reviewAgentWaitingUser,
                ProactiveSuggestionTypes.fixCIFailure,
                ProactiveSuggestionTypes.mergeReady,
            ]
        )
        XCTAssertEqual(
            ranking.items.map(\.workspaceId),
            [
                ciFailedId,
                waitingId,
                readyToMergeId,
            ]
        )
    }

    func testRankingEnginePrioritizesUserAttentionNeededDeterministically() {
        let runningId = UUID(uuidString: "BCBCBCBC-BCBC-BCBC-BCBC-BCBCBCBCBCBC")!
        let waitingId = UUID(uuidString: "CDCDCDCD-CDCD-CDCD-CDCD-CDCDCDCDCDCD")!
        let ciFailedId = UUID(uuidString: "DEDEDEDE-DEDE-DEDE-DEDE-DEDEDEDEDEDE")!
        let snapshots = [
            makeWorkspaceSnapshot(
                workspaceId: runningId,
                title: "Running",
                nativeOrder: 0,
                confidence: 1,
                status: "running",
                priorityScore: 90,
                userAttentionNeeded: 0.1
            ),
            makeWorkspaceSnapshot(
                workspaceId: waitingId,
                title: "Waiting",
                nativeOrder: 1,
                confidence: 1,
                status: "waiting_user",
                priorityScore: 50,
                userAttentionNeeded: 0.7
            ),
            makeWorkspaceSnapshot(
                workspaceId: ciFailedId,
                title: "CI failed",
                nativeOrder: 2,
                confidence: 1,
                status: "ci_failed",
                priorityScore: 10,
                userAttentionNeeded: 0.95
            ),
        ]

        let first = RankingEngine.default.rank(snapshots)
        let second = RankingEngine.default.rank(snapshots)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.items.map(\.workspaceId), [ciFailedId, waitingId, runningId])
        XCTAssertEqual(first.items.map(\.rank), [1, 2, 3])
    }

    func testSuggestionEngineCreatesSnapshotDrivenSuggestions() {
        let waitingId = UUID(uuidString: "EFEFEFEF-EFEF-EFEF-EFEF-EFEFEFEFEFEF")!
        let ciFailedId = UUID(uuidString: "F0F0F0F0-F0F0-F0F0-F0F0-F0F0F0F0F0F0")!
        let readyId = UUID(uuidString: "A1A1A1A1-A1A1-A1A1-A1A1-A1A1A1A1A1A1")!
        let runningId = UUID(uuidString: "B2B2B2B2-B2B2-B2B2-B2B2-B2B2B2B2B2B2")!

        let suggestions = SuggestionEngine.default.generate(from: [
            makeWorkspaceSnapshot(
                workspaceId: waitingId,
                title: "Waiting",
                nativeOrder: 0,
                confidence: 1,
                status: "waiting_user",
                rankReason: "Agent needs review",
                nextAction: "Review agent output",
                userAttentionNeeded: 0.9
            ),
            makeWorkspaceSnapshot(
                workspaceId: ciFailedId,
                title: "CI failed",
                nativeOrder: 1,
                confidence: 1,
                status: "ci_failed",
                rankReason: "CI failed",
                nextAction: "Fix CI failure",
                userAttentionNeeded: 0.8
            ),
            makeWorkspaceSnapshot(
                workspaceId: readyId,
                title: "Ready",
                nativeOrder: 2,
                confidence: 1,
                status: "ready_to_merge",
                rankReason: "PR is ready",
                nextAction: "Merge PR",
                userAttentionNeeded: 0.6
            ),
            makeWorkspaceSnapshot(
                workspaceId: runningId,
                title: "Running",
                nativeOrder: 3,
                confidence: 1,
                status: "running",
                userAttentionNeeded: 0.2
            ),
        ])

        XCTAssertEqual(suggestions.map(\.type), [
            ProactiveSuggestionTypes.reviewAgentWaitingUser,
            ProactiveSuggestionTypes.fixCIFailure,
            ProactiveSuggestionTypes.mergeReady,
        ])
        XCTAssertEqual(suggestions.map(\.workspaceId), [waitingId, ciFailedId, readyId])
        XCTAssertGreaterThan(suggestions[0].confidence, 0.8)
    }

    func testDismissedSuggestionDoesNotRepeatUntilStateChanges() async throws {
        let store = SuggestionStore()
        let engine = SuggestionEngine(store: store)
        let workspaceId = UUID(uuidString: "C3C3C3C3-C3C3-C3C3-C3C3-C3C3C3C3C3C3")!
        let snapshot = makeWorkspaceSnapshot(
            workspaceId: workspaceId,
            title: "Waiting",
            nativeOrder: 0,
            confidence: 1,
            status: "waiting_user",
            rankReason: "Agent needs review",
            nextAction: "Review agent output",
            userAttentionNeeded: 0.9
        )

        let firstSuggestions = await engine.generateAndStore(from: [snapshot])
        let first = try XCTUnwrap(firstSuggestions.first)
        await store.dismiss(first.id)

        let second = await engine.generateAndStore(from: [snapshot])
        XCTAssertTrue(second.isEmpty)

        let changed = makeWorkspaceSnapshot(
            workspaceId: workspaceId,
            title: "Waiting",
            nativeOrder: 0,
            confidence: 1,
            status: "waiting_user",
            rankReason: "Agent needs review",
            nextAction: "Review revised agent output",
            userAttentionNeeded: 0.9,
            contextHash: "fnv1a64:changed"
        )
        let third = await engine.generateAndStore(from: [changed])

        XCTAssertFalse(third.isEmpty)
        XCTAssertNotEqual(third.first?.id, first.id)
    }

    func testNextWorkspaceServiceReturnsNextRankedUnlockedWorkspace() {
        let activeId = UUID(uuidString: "D4D4D4D4-D4D4-D4D4-D4D4-D4D4D4D4D4D4")!
        let pinnedId = UUID(uuidString: "E5E5E5E5-E5E5-E5E5-E5E5-E5E5E5E5E5E5")!
        let nextId = UUID(uuidString: "F6F6F6F6-F6F6-F6F6-F6F6-F6F6F6F6F6F6")!
        let context = AssistantWorkingContext(
            activeWorkspaceId: activeId,
            snapshots: [
                makeWorkspaceSnapshot(workspaceId: activeId, title: "Active", nativeOrder: 0, confidence: 1),
                makeWorkspaceSnapshot(workspaceId: pinnedId, title: "Pinned", nativeOrder: 1, confidence: 1, pinned: true),
                makeWorkspaceSnapshot(workspaceId: nextId, title: "Next", nativeOrder: 2, confidence: 1),
            ],
            freshness: ContextFreshness(providers: [], overallConfidence: 1),
            activeSuggestions: [],
            latestRanking: RankingSnapshot(
                id: UUID(uuidString: "A7A7A7A7-A7A7-A7A7-A7A7-A7A7A7A7A7A7")!,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                items: [
                    RankingSnapshot.Item(workspaceId: activeId, rank: 1, score: 100, reason: nil),
                    RankingSnapshot.Item(workspaceId: pinnedId, rank: 2, score: 90, reason: nil),
                    RankingSnapshot.Item(workspaceId: nextId, rank: 3, score: 80, reason: nil),
                ]
            )
        )

        let next = NextWorkspaceService.default.nextWorkspace(in: context)

        XCTAssertEqual(next?.workspaceId, nextId)
    }

    func testNextWorkspaceServiceReturnsNilWhenAllRankedWorkspacesAreLockedOrPinned() {
        let pinnedId = UUID(uuidString: "B8B8B8B8-B8B8-B8B8-B8B8-B8B8B8B8B8B8")!
        let lockedId = UUID(uuidString: "C9C9C9C9-C9C9-C9C9-C9C9-C9C9C9C9C9C9")!
        let context = AssistantWorkingContext(
            activeWorkspaceId: nil,
            snapshots: [
                makeWorkspaceSnapshot(workspaceId: pinnedId, title: "Pinned", nativeOrder: 0, confidence: 1, pinned: true),
                makeWorkspaceSnapshot(workspaceId: lockedId, title: "Locked", nativeOrder: 1, confidence: 1, locked: true),
            ],
            freshness: ContextFreshness(providers: [], overallConfidence: 1),
            activeSuggestions: [],
            latestRanking: RankingSnapshot(
                id: UUID(uuidString: "D0D0D0D0-D0D0-D0D0-D0D0-D0D0D0D0D0D0")!,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                items: [
                    RankingSnapshot.Item(workspaceId: pinnedId, rank: 1, score: 100, reason: nil),
                    RankingSnapshot.Item(workspaceId: lockedId, rank: 2, score: 90, reason: nil),
                ]
            )
        )

        XCTAssertNil(NextWorkspaceService.default.nextWorkspace(in: context))
    }

    func testSemanticActionGatewayExecutesAllowedIntentAndAudits() async throws {
        let executor = RecordingActionExecutor()
        let auditLog = RecordingActionAuditLog()
        let gateway = SemanticActionGateway(
            reviewers: [AllowingActionReviewer()],
            executor: executor,
            auditLog: auditLog
        )
        let intent = makeActionIntent(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            snapshotUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )

        let result = try await gateway.submit(intent)

        XCTAssertEqual(result.decision, .allow)
        XCTAssertTrue(result.executed)
        assertEqual(await executor.executedIntentIds(), [intent.id])
        assertEqual(await auditLog.reviewedIntentIds(), [intent.id])
        assertEqual(await auditLog.executedIntentIds(), [intent.id])
    }

    func testSemanticActionGatewayRequiresConfirmationForStaleSnapshotEvidence() async throws {
        let executor = RecordingActionExecutor()
        let auditLog = RecordingActionAuditLog()
        let gateway = SemanticActionGateway(
            reviewers: [
                ActionFreshnessReviewer(
                    maxSnapshotAge: 120,
                    now: Date(timeIntervalSince1970: 1_300)
                ),
            ],
            executor: executor,
            auditLog: auditLog
        )
        let intent = makeActionIntent(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            snapshotUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )

        let result = try await gateway.submit(intent)

        XCTAssertEqual(result.decision, .requireConfirmation)
        XCTAssertFalse(result.executed)
        XCTAssertEqual(result.reasons, ["stale snapshot evidence"])
        assertEqual(await executor.executedIntentIds(), [])
        assertEqual(await auditLog.reviewedIntentIds(), [intent.id])
        assertEqual(await auditLog.executedIntentIds(), [])
    }

    func testSemanticActionGatewayDeniesDuplicateApplySortTargets() async throws {
        let executor = RecordingActionExecutor()
        let auditLog = RecordingActionAuditLog()
        let workspaceId = UUID(uuidString: "D1D1D1D1-D1D1-D1D1-D1D1-D1D1D1D1D1D1")!
        let intent = ActionIntent(
            id: UUID(uuidString: "D2D2D2D2-D2D2-D2D2-D2D2-D2D2D2D2D2D2")!,
            requestedBy: ActionRequester(id: "sprite", route: SortAssistantIntent.applySort.rawValue),
            kind: .applySort,
            arguments: [
                "patchId": UUID(uuidString: "D3D3D3D3-D3D3-D3D3-D3D3-D3D3D3D3D3D3")!.uuidString,
                "itemIds": "\(workspaceId.uuidString),\(workspaceId.uuidString)",
            ],
            reason: "Apply malformed order",
            evidence: ActionEvidence(
                snapshotVersions: [workspaceId: 1],
                snapshotUpdatedAt: [workspaceId: Date(timeIntervalSince1970: 1_000)],
                suggestionId: nil,
                rankingSnapshotId: nil
            ),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let gateway = SemanticActionGateway(
            reviewers: [ActionArgumentReviewer()],
            executor: executor,
            auditLog: auditLog
        )

        let result = try await gateway.submit(intent)

        XCTAssertEqual(result.decision, .deny)
        XCTAssertEqual(result.reasons, ["duplicate workspace target"])
        XCTAssertFalse(result.executed)
        assertEqual(await executor.executedIntentIds(), [])
        assertEqual(await auditLog.reviewedIntentIds(), [intent.id])
    }

    func testSemanticActionGatewayRequiresConfirmationWhenActionTargetHasNoSnapshotEvidence() async throws {
        let executor = RecordingActionExecutor()
        let auditLog = RecordingActionAuditLog()
        let workspaceId = UUID(uuidString: "D4D4D4D4-D4D4-D4D4-D4D4-D4D4D4D4D4D4")!
        let intent = ActionIntent(
            id: UUID(uuidString: "D5D5D5D5-D5D5-D5D5-D5D5-D5D5D5D5D5D5")!,
            requestedBy: ActionRequester(id: "sprite", route: nil),
            kind: .lockList,
            arguments: ["itemId": workspaceId.uuidString, "locked": "true"],
            reason: nil,
            evidence: ActionEvidence(
                snapshotVersions: [:],
                snapshotUpdatedAt: [:],
                suggestionId: nil,
                rankingSnapshotId: nil
            ),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let gateway = SemanticActionGateway(
            reviewers: [ActionArgumentReviewer()],
            executor: executor,
            auditLog: auditLog
        )

        let result = try await gateway.submit(intent)

        XCTAssertEqual(result.decision, .requireConfirmation)
        XCTAssertEqual(result.reasons, ["missing snapshot evidence for action target"])
        XCTAssertFalse(result.executed)
        assertEqual(await executor.executedIntentIds(), [])
        assertEqual(await auditLog.reviewedIntentIds(), [intent.id])
    }

    func testSemanticActionGatewayAllowsSuggestionActionsWithSnapshotEvidence() async throws {
        let executor = RecordingActionExecutor()
        let auditLog = RecordingActionAuditLog()
        let workspaceId = UUID(uuidString: "E1E1E1E1-E1E1-E1E1-E1E1-E1E1E1E1E1E1")!
        let suggestionId = UUID(uuidString: "E2E2E2E2-E2E2-E2E2-E2E2-E2E2E2E2E2E2")!
        let now = Date(timeIntervalSince1970: 2_000)
        let intents = [
            CmuxActionKind.acceptSuggestion,
            CmuxActionKind.dismissSuggestion,
        ].enumerated().map { index, kind in
            ActionIntent(
                id: UUID(uuidString: "E3E3E3E3-E3E3-E3E3-E3E3-E3E3E3E3E3E\(index)")!,
                requestedBy: ActionRequester(id: "sprite", route: nil),
                kind: kind,
                arguments: [
                    "suggestionId": suggestionId.uuidString,
                    "workspaceId": workspaceId.uuidString,
                ],
                reason: nil,
                evidence: ActionEvidence(
                    snapshotVersions: [workspaceId: 1],
                    snapshotUpdatedAt: [workspaceId: now],
                    suggestionId: suggestionId,
                    rankingSnapshotId: nil
                ),
                createdAt: now
            )
        }
        let gateway = SemanticActionGateway(
            reviewers: [
                ActionArgumentReviewer(),
                ActionFreshnessReviewer(maxSnapshotAge: 120, now: now),
            ],
            executor: executor,
            auditLog: auditLog
        )

        for intent in intents {
            let result = try await gateway.submit(intent)
            XCTAssertEqual(result.decision, .allow)
            XCTAssertTrue(result.executed)
        }

        assertEqual(await executor.executedIntentIds(), intents.map(\.id))
        assertEqual(await auditLog.reviewedIntentIds(), intents.map(\.id))
    }

    func testSemanticActionGatewayDeniesSuggestionActionWithoutValidSuggestionId() async throws {
        let executor = RecordingActionExecutor()
        let auditLog = RecordingActionAuditLog()
        let workspaceId = UUID(uuidString: "E4E4E4E4-E4E4-E4E4-E4E4-E4E4E4E4E4E4")!
        let intent = ActionIntent(
            id: UUID(uuidString: "E5E5E5E5-E5E5-E5E5-E5E5-E5E5E5E5E5E5")!,
            requestedBy: ActionRequester(id: "sprite", route: nil),
            kind: .dismissSuggestion,
            arguments: [
                "suggestionId": "not-a-uuid",
                "workspaceId": workspaceId.uuidString,
            ],
            reason: nil,
            evidence: ActionEvidence(
                snapshotVersions: [workspaceId: 1],
                snapshotUpdatedAt: [workspaceId: Date(timeIntervalSince1970: 2_000)],
                suggestionId: nil,
                rankingSnapshotId: nil
            ),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let gateway = SemanticActionGateway(
            reviewers: [ActionArgumentReviewer()],
            executor: executor,
            auditLog: auditLog
        )

        let result = try await gateway.submit(intent)

        XCTAssertEqual(result.decision, .deny)
        XCTAssertEqual(result.reasons, ["invalid suggestionId argument"])
        XCTAssertFalse(result.executed)
        assertEqual(await executor.executedIntentIds(), [])
        assertEqual(await auditLog.reviewedIntentIds(), [intent.id])
    }

    func testSemanticActionGatewayAllowsMemoryWriteWithoutSnapshotEvidence() async throws {
        let executor = RecordingActionExecutor()
        let auditLog = RecordingActionAuditLog()
        let intent = ActionIntent(
            id: UUID(uuidString: "D6D6D6D6-D6D6-D6D6-D6D6-D6D6D6D6D6D6")!,
            requestedBy: ActionRequester(id: "sprite", route: SortAssistantIntent.rememberPreference.rawValue),
            kind: .writeMemory,
            arguments: ["domain": "free_sort", "text": "Keep pinned workspaces first"],
            reason: nil,
            evidence: ActionEvidence(
                snapshotVersions: [:],
                snapshotUpdatedAt: [:],
                suggestionId: nil,
                rankingSnapshotId: nil
            ),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let gateway = SemanticActionGateway(
            reviewers: [
                ActionArgumentReviewer(),
                ActionFreshnessReviewer(
                    maxSnapshotAge: 120,
                    now: Date(timeIntervalSince1970: 1_300)
                ),
            ],
            executor: executor,
            auditLog: auditLog
        )

        let result = try await gateway.submit(intent)

        XCTAssertEqual(result.decision, .allow)
        XCTAssertTrue(result.executed)
        assertEqual(await executor.executedIntentIds(), [intent.id])
        assertEqual(await auditLog.reviewedIntentIds(), [intent.id])
    }

    func testSemanticActionGatewaySynchronousAdapterExecutesAndAudits() throws {
        let intent = makeActionIntent(
            id: UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!,
            snapshotUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )
        var reviewedIds: [UUID] = []
        var executedIds: [UUID] = []

        let result = try SemanticActionGateway.submitSynchronously(
            intent,
            recordReview: { intent, _, _ in reviewedIds.append(intent.id) },
            recordExecuted: { intent, _, _ in executedIds.append(intent.id) }
        ) {
            ActionExecutionResult(payload: ["applied": "true"])
        }

        XCTAssertEqual(result.decision, .allow)
        XCTAssertTrue(result.executed)
        XCTAssertEqual(result.executionResult?.payload["applied"], "true")
        XCTAssertEqual(reviewedIds, [intent.id])
        XCTAssertEqual(executedIds, [intent.id])
    }

    func testSemanticActionGatewaySynchronousAdapterSkipsExecutionWhenReviewRequiresConfirmation() throws {
        let intent = makeActionIntent(
            id: UUID(uuidString: "ACACACAC-ACAC-ACAC-ACAC-ACACACACACAC")!,
            snapshotUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )
        var executed = false

        let result = try SemanticActionGateway.submitSynchronously(
            intent,
            reviewSignals: [
                SemanticReviewSignal(
                    decision: .requireConfirmation,
                    reason: "stale snapshot evidence"
                ),
            ]
        ) {
            executed = true
            return ActionExecutionResult(payload: ["applied": "true"])
        }

        XCTAssertEqual(result.decision, .requireConfirmation)
        XCTAssertEqual(result.reasons, ["stale snapshot evidence"])
        XCTAssertFalse(result.executed)
        XCTAssertFalse(executed)
    }

    @MainActor
    func testSocketActionReviewPayloadPreservesConfirmationDecision() {
        let intent = makeActionIntent(
            id: UUID(uuidString: "BCBCBCBC-BCBC-BCBC-BCBC-BCBCBCBCBCBC")!,
            snapshotUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let result = SemanticReviewResult(
            intentId: intent.id,
            decision: .requireConfirmation,
            reasons: ["stale snapshot evidence"],
            executed: false,
            executionResult: nil
        )

        let payload = SortAssistantCoordinator.socketActionReviewPayload(
            intent: intent,
            result: result,
            base: ["accepted": false]
        )

        XCTAssertEqual(payload["accepted"] as? Bool, false)
        XCTAssertEqual(payload["intentId"] as? String, intent.id.uuidString)
        XCTAssertEqual(payload["actionKind"] as? String, CmuxActionKind.applySort.rawValue)
        XCTAssertEqual(payload["reviewDecision"] as? String, SemanticActionDecision.requireConfirmation.rawValue)
        XCTAssertEqual(payload["reviewReasons"] as? [String], ["stale snapshot evidence"])
        XCTAssertEqual(payload["requiresConfirmation"] as? Bool, true)
        XCTAssertNil(payload["reviewDenied"])
    }

#if DEBUG
    @MainActor
    func testSortAssistantSemanticConfirmationRunsPendingActionAndClearsState() {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        var confirmed = false

        coordinator.debugQueueSemanticActionConfirmation(
            actionName: "apply sort",
            reasons: ["stale snapshot evidence"],
            confirm: { confirmed = true }
        )

        XCTAssertEqual(coordinator.semanticActionConfirmation?.reasons, ["stale snapshot evidence"])
        coordinator.confirmSemanticAction()
        XCTAssertTrue(confirmed)
        XCTAssertNil(coordinator.semanticActionConfirmation)
        coordinator.clearCurrentSession()
    }

    @MainActor
    func testSortAssistantSemanticConfirmationCancelDoesNotRunPendingAction() {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        var confirmed = false

        coordinator.debugQueueSemanticActionConfirmation(
            actionName: "apply sort",
            reasons: ["missing snapshot evidence"],
            confirm: { confirmed = true }
        )

        coordinator.dismissSemanticActionConfirmation()

        XCTAssertFalse(confirmed)
        XCTAssertNil(coordinator.semanticActionConfirmation)
        coordinator.clearCurrentSession()
    }

    @MainActor
    func testAcceptVisibleSuggestionImmediatelySelectsWorkspace() throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        coordinator.debugResetProactiveSurfaceStateForTesting()
        defer {
            coordinator.debugResetProactiveSurfaceStateForTesting()
            coordinator.clearCurrentSession()
        }

        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()
        let initialWorkspace = try XCTUnwrap(tabManager.selectedWorkspace)
        let targetWorkspace = tabManager.addWorkspace(
            title: "Review Queue",
            select: false,
            autoWelcomeIfNeeded: false
        )
        coordinator.attach(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        let suggestion = ProactiveSuggestion(
            id: UUID(uuidString: "42424242-4242-4242-4242-424242424242")!,
            workspaceId: targetWorkspace.id,
            type: ProactiveSuggestionTypes.reviewAgentWaitingUser,
            title: "Review agent output",
            reason: "Agent is waiting for your decision.",
            confidence: 0.92,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        coordinator.debugSeedVisibleSuggestionsForTesting([suggestion])
        coordinator.openConversationBubble(reason: "testAcceptVisibleSuggestion")

        coordinator.acceptVisibleSuggestion(suggestion)

        XCTAssertEqual(tabManager.selectedWorkspace?.id, targetWorkspace.id)
        XCTAssertNotEqual(tabManager.selectedWorkspace?.id, initialWorkspace.id)
        XCTAssertFalse(coordinator.isConversationBubblePresented)
        XCTAssertNil(coordinator.semanticActionConfirmation)
        XCTAssertFalse(coordinator.visibleSuggestions.contains { $0.id == suggestion.id })
    }
#endif

    @MainActor
    func testSelectWorkspaceSlashCommandRequiresGatewayConfirmationBeforeChangingSelection() throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        defer { coordinator.clearCurrentSession() }

        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()
        let initialWorkspace = try XCTUnwrap(tabManager.selectedWorkspace)
        let targetWorkspace = tabManager.addWorkspace(
            title: "Review Queue",
            select: false,
            autoWelcomeIfNeeded: false
        )

        XCTAssertEqual(tabManager.selectedWorkspace?.id, initialWorkspace.id)

        coordinator.submit(
            "/select @{Review Queue}",
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )

        let confirmation = try XCTUnwrap(coordinator.semanticActionConfirmation)
        XCTAssertEqual(confirmation.actionName, "switch workspace")
        XCTAssertEqual(confirmation.reasons, ["stale snapshot evidence"])
        XCTAssertEqual(tabManager.selectedWorkspace?.id, initialWorkspace.id)

        coordinator.confirmSemanticAction()

        XCTAssertNil(coordinator.semanticActionConfirmation)
        XCTAssertEqual(tabManager.selectedWorkspace?.id, targetWorkspace.id)
    }

    @MainActor
    func testSocketWorkspaceColorSetAndClearReturnGatewayConfirmationBeforeMutatingStaleTarget() throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        defer { coordinator.clearCurrentSession() }

        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()
        let workspace = try XCTUnwrap(tabManager.selectedWorkspace)
        coordinator.submit(
            "/help",
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )

        let payload = try XCTUnwrap(coordinator.socketWorkspaceColorSet(
            workspaceId: workspace.id.uuidString,
            color: "#C0392B"
        ))

        XCTAssertEqual(payload["actionKind"] as? String, CmuxActionKind.setWorkspaceColor.rawValue)
        XCTAssertEqual(payload["reviewDecision"] as? String, SemanticActionDecision.requireConfirmation.rawValue)
        XCTAssertEqual(payload["reviewReasons"] as? [String], ["stale snapshot evidence"])
        XCTAssertEqual(payload["requiresConfirmation"] as? Bool, true)
        XCTAssertNil(workspace.customColor)

        tabManager.setTabColor(tabId: workspace.id, color: "#C0392B")
        let clearPayload = try XCTUnwrap(coordinator.socketWorkspaceColorClear(
            workspaceId: workspace.id.uuidString
        ))

        XCTAssertEqual(clearPayload["actionKind"] as? String, CmuxActionKind.clearWorkspaceColor.rawValue)
        XCTAssertEqual(clearPayload["reviewDecision"] as? String, SemanticActionDecision.requireConfirmation.rawValue)
        XCTAssertEqual(clearPayload["reviewReasons"] as? [String], ["stale snapshot evidence"])
        XCTAssertEqual(clearPayload["requiresConfirmation"] as? Bool, true)
        XCTAssertEqual(workspace.customColor, "#C0392B")
    }

    @MainActor
    func testSocketPinAndLockReturnGatewayConfirmationBeforeMutatingStaleTargets() throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        defer { coordinator.clearCurrentSession() }

        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()
        let workspace = try XCTUnwrap(tabManager.selectedWorkspace)
        coordinator.submit(
            "/help",
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )

        let pinPayload = try XCTUnwrap(coordinator.socketSetPinned(itemId: workspace.id, pinned: true))
        XCTAssertEqual(pinPayload["actionKind"] as? String, CmuxActionKind.pinWorkspace.rawValue)
        XCTAssertEqual(pinPayload["reviewDecision"] as? String, SemanticActionDecision.requireConfirmation.rawValue)
        XCTAssertEqual(pinPayload["reviewReasons"] as? [String], ["stale snapshot evidence"])
        XCTAssertEqual(pinPayload["requiresConfirmation"] as? Bool, true)
        XCTAssertFalse(workspace.isPinned)

        let lockPayload = coordinator.socketSetLocked(itemId: workspace.id, locked: true)
        XCTAssertEqual(lockPayload["actionKind"] as? String, CmuxActionKind.lockList.rawValue)
        XCTAssertEqual(lockPayload["reviewDecision"] as? String, SemanticActionDecision.requireConfirmation.rawValue)
        XCTAssertEqual(lockPayload["reviewReasons"] as? [String], ["stale snapshot evidence"])
        XCTAssertEqual(lockPayload["requiresConfirmation"] as? Bool, true)
        XCTAssertEqual(lockPayload["locked"] as? Bool, false)

        let listState = try XCTUnwrap(coordinator.socketListState())
        let items = try XCTUnwrap(listState["items"] as? [[String: Any]])
        let item = try XCTUnwrap(items.first { $0["id"] as? String == workspace.id.uuidString })
        XCTAssertEqual(item["pinned"] as? Bool, false)
        XCTAssertEqual(item["locked"] as? Bool, false)
    }

    @MainActor
    func testSocketSortApplyReturnsGatewayConfirmationBeforeReorderingStaleTargets() throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        defer { coordinator.clearCurrentSession() }

        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()
        _ = try XCTUnwrap(tabManager.selectedWorkspace)
        let targetWorkspace = tabManager.addWorkspace(
            title: "Review Queue",
            select: false,
            autoWelcomeIfNeeded: false
        )
        coordinator.submit(
            "/help",
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
        let orderBefore = tabManager.tabs.map(\.id)
        let requestedOrder = [targetWorkspace.id] + orderBefore.filter { $0 != targetWorkspace.id }

        let payload = try XCTUnwrap(coordinator.socketSortApply(
            patchId: nil,
            itemIds: requestedOrder
        ))

        XCTAssertEqual(payload["applied"] as? Bool, false)
        XCTAssertEqual(payload["actionKind"] as? String, CmuxActionKind.applySort.rawValue)
        XCTAssertEqual(payload["reviewDecision"] as? String, SemanticActionDecision.requireConfirmation.rawValue)
        XCTAssertEqual(payload["reviewReasons"] as? [String], ["stale snapshot evidence"])
        XCTAssertEqual(payload["requiresConfirmation"] as? Bool, true)
        XCTAssertEqual(tabManager.tabs.map(\.id), orderBefore)
    }

    @MainActor
    func testSocketSortApplyPendingColorPreviewUsesFreshListEvidence() throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        defer { coordinator.clearCurrentSession() }

        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()
        let firstUncolored = try XCTUnwrap(tabManager.selectedWorkspace)
        let redWorkspace = tabManager.addWorkspace(
            title: "Red Review",
            select: false,
            autoWelcomeIfNeeded: false
        )
        let secondUncolored = tabManager.addWorkspace(
            title: "No Color",
            select: false,
            autoWelcomeIfNeeded: false
        )
        let blueWorkspace = tabManager.addWorkspace(
            title: "Blue Build",
            select: false,
            autoWelcomeIfNeeded: false
        )
        tabManager.setTabColor(tabId: redWorkspace.id, color: "#C0392B")
        tabManager.setTabColor(tabId: blueWorkspace.id, color: "#1565C0")
        coordinator.attach(tabManager: tabManager, workspaceTabStore: workspaceTabStore)

        let groupedOrder = [
            redWorkspace.id,
            blueWorkspace.id,
            firstUncolored.id,
            secondUncolored.id,
        ]
        let previewPayload = try XCTUnwrap(coordinator.socketSortPreview(
            goal: "Group by color, place uncolored last",
            itemIds: groupedOrder
        ))
        let patchPayload = try XCTUnwrap(previewPayload["patch"] as? [String: Any])
        let patchId = try XCTUnwrap((patchPayload["id"] as? String).flatMap(UUID.init(uuidString:)))

        let applyPayload = try XCTUnwrap(coordinator.socketSortApply(
            patchId: patchId,
            itemIds: nil
        ))

        XCTAssertEqual(applyPayload["applied"] as? Bool, true)
        XCTAssertNil(applyPayload["reviewDecision"])
        XCTAssertEqual(tabManager.tabs.map(\.id), groupedOrder)
    }

    @MainActor
    func testSocketSortUndoReturnsGatewayConfirmationBeforeMutatingStaleTargets() throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        defer { coordinator.clearCurrentSession() }

        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()
        coordinator.submit(
            "/help",
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )

        let payload = try XCTUnwrap(coordinator.socketSortUndo())

        XCTAssertEqual(payload["undone"] as? Bool, false)
        XCTAssertEqual(payload["actionKind"] as? String, CmuxActionKind.undoSort.rawValue)
        XCTAssertEqual(payload["reviewDecision"] as? String, SemanticActionDecision.requireConfirmation.rawValue)
        XCTAssertEqual(payload["reviewReasons"] as? [String], ["stale snapshot evidence"])
        XCTAssertEqual(payload["requiresConfirmation"] as? Bool, true)
    }

#if DEBUG
    @MainActor
    func testSocketWriteMemoryCandidateRecordsGatewayReviewAndExecutionAudit() async throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        coordinator.debugResetMemoryState()
        defer { coordinator.clearCurrentSession() }

        let before = await coordinator.debugContextAgentInspectorSnapshot()
        let beforeAuditCount = before.auditEntries.count

        let payload = coordinator.socketWriteMemoryCandidate(
            text: "Keep review workspaces near the top",
            sourceSummary: "user preference"
        )

        XCTAssertEqual(payload["domain"] as? String, "free_sort")
        XCTAssertEqual(payload["created"] as? Bool, true)
        XCTAssertEqual(payload["text"] as? String, "Keep review workspaces near the top")
        XCTAssertNil(payload["reviewDecision"])
        XCTAssertEqual(coordinator.memoryCandidate?.text, "Keep review workspaces near the top")
        XCTAssertEqual(coordinator.memoryCandidate?.sourceSummary, "user preference")
        XCTAssertEqual(coordinator.memoryCandidate?.target, .freeSort)

        let after = await coordinator.debugContextAgentInspectorSnapshot()
        let auditEntries = Array(after.auditEntries.dropFirst(beforeAuditCount))
        XCTAssertEqual(auditEntries.map(\.kind), [.writeMemory, .writeMemory])
        XCTAssertEqual(auditEntries.map(\.decision), [.allow, .allow])
        XCTAssertEqual(auditEntries.map(\.executed), [false, true])
    }

    @MainActor
    func testSocketForgetMemoryRecordsGatewayReviewAndExecutionAudit() async throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        coordinator.debugResetMemoryState()
        defer {
            coordinator.clearCurrentSession()
            coordinator.debugResetMemoryState()
        }

        let memory = SortAssistantMemory(
            id: UUID(),
            text: "Keep review workspaces near the top",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        coordinator.debugSeedFreeSortMemories([memory])

        let before = await coordinator.debugContextAgentInspectorSnapshot()
        let beforeAuditCount = before.auditEntries.count

        let payload = coordinator.socketForgetMemory(id: memory.id.uuidString, text: nil)

        XCTAssertEqual(payload["domain"] as? String, "free_sort")
        XCTAssertEqual(payload["deleted"] as? Int, 1)
        XCTAssertNil(payload["reviewDecision"])
        XCTAssertFalse(coordinator.memories.contains { $0.id == memory.id })

        let queryPayload = coordinator.socketMemoryQuery()
        let memories = try XCTUnwrap(queryPayload["memories"] as? [[String: Any]])
        XCTAssertFalse(memories.contains { $0["id"] as? String == memory.id.uuidString })

        let after = await coordinator.debugContextAgentInspectorSnapshot()
        let auditEntries = Array(after.auditEntries.dropFirst(beforeAuditCount))
        XCTAssertEqual(auditEntries.map(\.kind), [.forgetMemory, .forgetMemory])
        XCTAssertEqual(auditEntries.map(\.decision), [.allow, .allow])
        XCTAssertEqual(auditEntries.map(\.executed), [false, true])
    }

    @MainActor
    func testAssistantDeleteMemoryRecordsGatewayReviewAndExecutionAudit() async throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        coordinator.debugResetMemoryState()
        defer {
            coordinator.clearCurrentSession()
            coordinator.debugResetMemoryState()
        }

        let memory = SortAssistantMemory(
            id: UUID(),
            text: "Keep review workspaces near the top",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        coordinator.debugSeedFreeSortMemories([memory])

        let before = await coordinator.debugContextAgentInspectorSnapshot()
        let beforeAuditCount = before.auditEntries.count

        coordinator.deleteMemory(memory)

        XCTAssertFalse(coordinator.memories.contains { $0.id == memory.id })

        let after = await coordinator.debugContextAgentInspectorSnapshot()
        let auditEntries = Array(after.auditEntries.dropFirst(beforeAuditCount))
        XCTAssertEqual(auditEntries.map(\.kind), [.forgetMemory, .forgetMemory])
        XCTAssertEqual(auditEntries.map(\.decision), [.allow, .allow])
        XCTAssertEqual(auditEntries.map(\.executed), [false, true])
    }

    @MainActor
    func testSocketWriteSpriteMemoryRecordsGatewayReviewAndExecutionAudit() async throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        coordinator.debugResetMemoryState()
        defer {
            coordinator.clearCurrentSession()
            coordinator.debugResetMemoryState()
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sprite-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let before = await coordinator.debugContextAgentInspectorSnapshot()
        let beforeAuditCount = before.auditEntries.count

        let payload = coordinator.socketWriteSpriteMemory(
            text: "Use bun for web commands",
            sourceSummary: "project convention",
            directory: directory.path
        )

        let memoryFile = try XCTUnwrap(SpriteWorkspaceMemoryDocument.fileURL(directory: directory.path))
        XCTAssertEqual(payload["domain"] as? String, "sprite")
        XCTAssertEqual(payload["created"] as? Bool, true)
        XCTAssertEqual(payload["text"] as? String, "Use bun for web commands")
        XCTAssertEqual(payload["sourceSummary"] as? String, "project convention")
        XCTAssertEqual(payload["memoryFile"] as? String, memoryFile.path)
        XCTAssertNil(payload["reviewDecision"])

        let memory = try XCTUnwrap(payload["memory"] as? [String: Any])
        XCTAssertEqual(memory["text"] as? String, "Use bun for web commands")

        let content = try String(contentsOf: memoryFile, encoding: .utf8)
        XCTAssertTrue(content.contains("Use bun for web commands"))
        XCTAssertTrue(content.contains("<!-- cmux-memory:id="))

        let queryPayload = coordinator.socketSpriteMemoryQuery(directory: directory.path)
        let memories = try XCTUnwrap(queryPayload["memories"] as? [[String: Any]])
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories.first?["text"] as? String, "Use bun for web commands")

        let after = await coordinator.debugContextAgentInspectorSnapshot()
        let auditEntries = Array(after.auditEntries.dropFirst(beforeAuditCount))
        XCTAssertEqual(auditEntries.map(\.kind), [.writeMemory, .writeMemory])
        XCTAssertEqual(auditEntries.map(\.decision), [.allow, .allow])
        XCTAssertEqual(auditEntries.map(\.executed), [false, true])
    }

    @MainActor
    func testSocketForgetSpriteMemoryRecordsGatewayReviewAndExecutionAudit() async throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        coordinator.debugResetMemoryState()
        defer {
            coordinator.clearCurrentSession()
            coordinator.debugResetMemoryState()
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sprite-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writePayload = coordinator.socketWriteSpriteMemory(
            text: "Use bun for web commands",
            sourceSummary: "project convention",
            directory: directory.path
        )
        XCTAssertEqual(writePayload["created"] as? Bool, true)

        let memoryFile = try XCTUnwrap(SpriteWorkspaceMemoryDocument.fileURL(directory: directory.path))
        let memory = try XCTUnwrap(writePayload["memory"] as? [String: Any])
        let memoryId = try XCTUnwrap(memory["id"] as? String)

        let before = await coordinator.debugContextAgentInspectorSnapshot()
        let beforeAuditCount = before.auditEntries.count

        let payload = coordinator.socketForgetSpriteMemory(
            id: memoryId,
            text: nil,
            directory: directory.path
        )

        XCTAssertEqual(payload["domain"] as? String, "sprite")
        XCTAssertEqual(payload["deleted"] as? Int, 1)
        XCTAssertEqual(payload["memoryFile"] as? String, memoryFile.path)
        XCTAssertNil(payload["reviewDecision"])

        let content = try String(contentsOf: memoryFile, encoding: .utf8)
        XCTAssertFalse(content.contains("Use bun for web commands"))

        let queryPayload = coordinator.socketSpriteMemoryQuery(directory: directory.path)
        let memories = try XCTUnwrap(queryPayload["memories"] as? [[String: Any]])
        XCTAssertFalse(memories.contains { $0["id"] as? String == memoryId })

        let after = await coordinator.debugContextAgentInspectorSnapshot()
        let auditEntries = Array(after.auditEntries.dropFirst(beforeAuditCount))
        XCTAssertEqual(auditEntries.map(\.kind), [.forgetMemory, .forgetMemory])
        XCTAssertEqual(auditEntries.map(\.decision), [.allow, .allow])
        XCTAssertEqual(auditEntries.map(\.executed), [false, true])
    }

    @MainActor
    func testAssistantDeleteSpriteMemoryRecordsGatewayReviewAndExecutionAudit() async throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        coordinator.debugResetMemoryState()
        defer {
            coordinator.clearCurrentSession()
            coordinator.debugResetMemoryState()
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sprite-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writePayload = coordinator.socketWriteSpriteMemory(
            text: "Use bun for web commands",
            sourceSummary: "project convention",
            directory: directory.path
        )
        XCTAssertEqual(writePayload["created"] as? Bool, true)

        let memoryFile = try XCTUnwrap(SpriteWorkspaceMemoryDocument.fileURL(directory: directory.path))
        let memory = try XCTUnwrap(coordinator.spriteMemories.first {
            $0.text == "Use bun for web commands"
        })

        let before = await coordinator.debugContextAgentInspectorSnapshot()
        let beforeAuditCount = before.auditEntries.count

        coordinator.deleteSpriteMemory(memory)

        XCTAssertFalse(coordinator.spriteMemories.contains { $0.id == memory.id })
        let content = try String(contentsOf: memoryFile, encoding: .utf8)
        XCTAssertFalse(content.contains("Use bun for web commands"))

        let after = await coordinator.debugContextAgentInspectorSnapshot()
        let auditEntries = Array(after.auditEntries.dropFirst(beforeAuditCount))
        XCTAssertEqual(auditEntries.map(\.kind), [.forgetMemory, .forgetMemory])
        XCTAssertEqual(auditEntries.map(\.decision), [.allow, .allow])
        XCTAssertEqual(auditEntries.map(\.executed), [false, true])
    }

    @MainActor
    func testSocketAcceptSuggestionRecordsGatewayReviewAndExecutionAudit() async throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        defer { coordinator.clearCurrentSession() }

        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()
        let initialWorkspace = try XCTUnwrap(tabManager.selectedWorkspace)
        let targetWorkspace = tabManager.addWorkspace(
            title: "Review Queue",
            select: false,
            autoWelcomeIfNeeded: false
        )
        workspaceTabStore.summaryPriority = makeSummaryPriorityState(items: [
            makeSummaryPriorityItem(
                workspace: initialWorkspace,
                nativeOrder: 0,
                status: "running",
                score: 10,
                nextAction: nil
            ),
            makeSummaryPriorityItem(
                workspace: targetWorkspace,
                nativeOrder: 1,
                status: "waiting_user",
                score: 96,
                nextAction: "Review agent output"
            ),
        ])
        coordinator.submit(
            "/help",
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )

        let before = await coordinator.debugContextAgentInspectorSnapshot()
        let suggestion = try XCTUnwrap(before.workingContext.activeSuggestions.first {
            $0.workspaceId == targetWorkspace.id && $0.type == ProactiveSuggestionTypes.reviewAgentWaitingUser
        })
        let beforeAuditCount = before.auditEntries.count

        let payload = try XCTUnwrap(coordinator.socketAcceptSuggestion(suggestionId: suggestion.id))

        XCTAssertEqual(payload["accepted"] as? Bool, true)
        XCTAssertEqual(payload["suggestionId"] as? String, suggestion.id.uuidString)
        XCTAssertEqual(tabManager.selectedWorkspace?.id, targetWorkspace.id)

        let after = await coordinator.debugContextAgentInspectorSnapshot()
        let auditEntries = Array(after.auditEntries.dropFirst(beforeAuditCount))
        XCTAssertEqual(auditEntries.map(\.kind), [.acceptSuggestion, .acceptSuggestion])
        XCTAssertEqual(auditEntries.map(\.decision), [.allow, .allow])
        XCTAssertEqual(auditEntries.map(\.executed), [false, true])
        XCTAssertFalse(after.workingContext.activeSuggestions.contains { $0.id == suggestion.id })
    }

    @MainActor
    func testSocketDismissSuggestionRecordsGatewayReviewAndExecutionAudit() async throws {
        let coordinator = SortAssistantCoordinator.shared
        coordinator.clearCurrentSession()
        defer { coordinator.clearCurrentSession() }

        let tabManager = TabManager()
        let workspaceTabStore = WorkspaceTabStore()
        let initialWorkspace = try XCTUnwrap(tabManager.selectedWorkspace)
        let targetWorkspace = tabManager.addWorkspace(
            title: "Review Queue",
            select: false,
            autoWelcomeIfNeeded: false
        )
        workspaceTabStore.summaryPriority = makeSummaryPriorityState(items: [
            makeSummaryPriorityItem(
                workspace: initialWorkspace,
                nativeOrder: 0,
                status: "running",
                score: 10,
                nextAction: nil
            ),
            makeSummaryPriorityItem(
                workspace: targetWorkspace,
                nativeOrder: 1,
                status: "waiting_user",
                score: 96,
                nextAction: "Review agent output"
            ),
        ])
        coordinator.submit(
            "/help",
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )

        let before = await coordinator.debugContextAgentInspectorSnapshot()
        let suggestion = try XCTUnwrap(before.workingContext.activeSuggestions.first {
            $0.workspaceId == targetWorkspace.id && $0.type == ProactiveSuggestionTypes.reviewAgentWaitingUser
        })
        let beforeAuditCount = before.auditEntries.count

        let payload = try XCTUnwrap(coordinator.socketDismissSuggestion(suggestionId: suggestion.id))

        XCTAssertEqual(payload["dismissed"] as? Bool, true)
        XCTAssertEqual(payload["suggestionId"] as? String, suggestion.id.uuidString)
        XCTAssertEqual(tabManager.selectedWorkspace?.id, initialWorkspace.id)

        let after = await coordinator.debugContextAgentInspectorSnapshot()
        let auditEntries = Array(after.auditEntries.dropFirst(beforeAuditCount))
        XCTAssertEqual(auditEntries.map(\.kind), [.dismissSuggestion, .dismissSuggestion])
        XCTAssertEqual(auditEntries.map(\.decision), [.allow, .allow])
        XCTAssertEqual(auditEntries.map(\.executed), [false, true])
        XCTAssertFalse(after.workingContext.activeSuggestions.contains { $0.id == suggestion.id })
    }
#endif

    func testActionIntentCodableRoundTripPreservesEvidence() throws {
        let intent = makeActionIntent(
            id: UUID(uuidString: "ADADADAD-ADAD-ADAD-ADAD-ADADADADADAD")!,
            snapshotUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )

        let data = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(ActionIntent.self, from: data)

        XCTAssertEqual(decoded, intent)
    }

    func testActionIntentTrustDescriptorIncludesRouteArgumentsAndSnapshotContext() {
        let workspaceId = UUID(uuidString: "AEAEAEAE-AEAE-AEAE-AEAE-AEAEAEAEAEAE")!
        let intent = makeActionIntent(
            id: UUID(uuidString: "AFAFAFAF-AFAF-AFAF-AFAF-AFAFAFAFAFAF")!,
            workspaceId: workspaceId,
            snapshotUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )
        var reordered = intent
        reordered.arguments = Dictionary<String, String>(
            uniqueKeysWithValues: intent.arguments.map { ($0.key, $0.value) }.reversed()
        )

        let descriptor = intent.trustDescriptor
        let reorderedDescriptor = reordered.trustDescriptor

        XCTAssertEqual(descriptor.schemaVersion, 2)
        XCTAssertEqual(descriptor.actionID, "sprite.applySort")
        XCTAssertEqual(descriptor.kind, CmuxActionKind.applySort.rawValue)
        XCTAssertEqual(descriptor.workspaceId, workspaceId.uuidString)
        XCTAssertEqual(descriptor.assistantRoute, SortAssistantIntent.applySort.rawValue)
        XCTAssertNotNil(descriptor.normalizedArgumentsHash)
        XCTAssertNotNil(descriptor.contextSnapshotHash)
        XCTAssertEqual(descriptor.fingerprint, reorderedDescriptor.fingerprint)
    }

    func testActionIntentTrustDescriptorChangesWhenSnapshotVersionChanges() {
        let workspaceId = UUID(uuidString: "B0B0B0B0-B0B0-B0B0-B0B0-B0B0B0B0B0B0")!
        let first = makeActionIntent(
            id: UUID(uuidString: "B1B1B1B1-B1B1-B1B1-B1B1-B1B1B1B1B1B1")!,
            workspaceId: workspaceId,
            snapshotUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )
        var second = first
        second.evidence.snapshotVersions[workspaceId] = 2

        XCTAssertNotEqual(first.trustDescriptor.fingerprint, second.trustDescriptor.fingerprint)
    }

    func testSemanticRouterToolCatalogUsesMCPToolsListProtocol() async throws {
        let script = """
        import json
        import sys

        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "initialize":
                response = {
                    "jsonrpc": "2.0",
                    "id": request.get("id"),
                    "result": {
                        "protocolVersion": "2025-11-25",
                        "capabilities": {"tools": {"listChanged": False}},
                        "serverInfo": {"name": "mock", "version": "1"},
                    },
                }
            elif method == "tools/list":
                response = {
                    "jsonrpc": "2.0",
                    "id": request.get("id"),
                    "result": {
                        "tools": [{
                            "name": "external_probe",
                            "description": "External probe tool",
                            "inputSchema": {"type": "object"},
                        }],
                    },
                }
            else:
                continue
            print(json.dumps(response, separators=(",", ":")), flush=True)
        """

        let tools = await SortAssistantIntentRouter.semanticMCPToolCatalogForTesting(externalServers: [
            "mock_external": [
                "command": "/usr/bin/python3",
                "args": ["-c", script],
            ],
        ])
        let tool = try XCTUnwrap(tools.first { $0["name"] as? String == "external_probe" })

        XCTAssertEqual(tool["server"] as? String, "mock_external")
        XCTAssertEqual(tool["qualifiedName"] as? String, "mcp__mock_external__external_probe")
        XCTAssertEqual(tool["description"] as? String, "External probe tool")
        XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
    }

    func testSemanticRouterProductionToolCatalogDoesNotLoadExternalServers() {
        let serverNames = SortAssistantIntentRouter.semanticMCPServerNamesForTesting(externalServers: [
            "mock_external": [
                "command": "/bin/sh",
                "args": ["-c", "exit 1"],
            ],
        ])

        XCTAssertEqual(serverNames, ["cmux_sprite"])
    }

    private func makeSpriteMCPRequest(
        intent: SortAssistantIntent,
        route: SortAssistantActionRoute? = nil,
        routeSteps: [SortAssistantRouteStep]? = nil,
        workspaceDirectory: String? = nil
    ) -> SortAssistantMCPRequest {
        let actionRouter = SortAssistantActionRouter()
        let resolvedRoute = route ?? actionRouter.route(for: intent)
        return SortAssistantMCPRequest(
            goal: "fixture",
            intent: intent,
            routeSteps: routeSteps ?? [SortAssistantRouteStep(intent: intent)],
            route: resolvedRoute,
            routeAdjustment: .empty,
            visibleScopeSignature: "fixture",
            requiresMCPScopeRefresh: false,
            conversationContext: [],
            includeConversationContext: false,
            explicitSlashCommand: false,
            workspaceId: "11111111-1111-1111-1111-111111111111",
            workspaceDirectory: workspaceDirectory,
            socketPath: "/tmp/cmux-test.sock",
            cmuxCLIPath: "/tmp/cmux",
            claudeSessionId: nil,
            claudeSessionReused: false,
            debugSession: nil
        )
    }

    private func noLLMRuntimeMode() -> CmuxRuntimeMode {
        CmuxRuntimeMode(
            isUITest: true,
            fixtureName: "assistant-context-agent-basic",
            disableNetwork: true,
            disableSparkle: true,
            disableRealLLM: true,
            disableAutoUpdate: true,
            disableAnimations: true,
            resetTestState: true,
            fakeContextAgent: true,
            fakeAssistant: true,
            fixedNow: ISO8601DateFormatter().date(from: "2026-05-23T10:00:00Z"),
            appearanceMode: "light"
        )
    }

    private func assertEqual<T: Equatable>(
        _ expression1: T,
        _ expression2: T,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(expression1, expression2, message, file: file, line: line)
    }

    private func makeWorkspaceSnapshot(
        workspaceId: UUID,
        title: String,
        nativeOrder: Int,
        confidence: Double,
        status: String = "ready",
        priorityScore: Double? = nil,
        rankReason: String? = nil,
        nextAction: String? = nil,
        userAttentionNeeded: Double? = nil,
        pinned: Bool = false,
        locked: Bool = false,
        contextHash: String? = nil
    ) -> WorkspaceSnapshot {
        let freshness = ContextFreshness(
            providers: [
                ProviderFreshness(
                    providerId: "summary_priority",
                    lastCollectedAt: Date(timeIntervalSince1970: 1_000),
                    ttlSeconds: 120,
                    stale: false,
                    error: nil,
                    confidence: confidence
                ),
            ],
            overallConfidence: confidence
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
                pinned: pinned,
                locked: locked,
                customColor: nil,
                panelCount: 0,
                pullRequestCount: 0,
                stalePullRequestCount: 0
            ),
            derived: DerivedWorkspaceState(
                status: status,
                priorityScore: priorityScore,
                rankReason: rankReason,
                nextAction: nextAction,
                userAttentionNeeded: userAttentionNeeded ?? confidence
            ),
            digest: nil,
            freshness: freshness,
            contextHash: contextHash
        )
    }

    private func makeSummaryPriorityState(
        items: [WorkspaceSidebarSummaryPriorityItem]
    ) -> WorkspaceSidebarSummaryPriorityState {
        let topScore = items
            .flatMap { $0.scores.dimensions.values.map(\.rawScore) }
            .max() ?? 0
        return WorkspaceSidebarSummaryPriorityState(
            profileId: "test-profile",
            sort: .dimension(id: "urgency"),
            items: items,
            dimensions: WorkspaceSidebarDimensionDefinition.builtinDefaults,
            stats: WorkspaceSidebarSummaryPriorityStats(
                total: items.count,
                needsAttention: items.filter { $0.status == "waiting_user" || $0.status == "ci_failed" }.count,
                topScore: topScore,
                staleDigestCount: items.filter { $0.stale == true }.count
            ),
            generatedAt: "2026-05-23T10:00:00Z"
        )
    }

    @MainActor
    private func makeSummaryPriorityItem(
        workspace: Workspace,
        nativeOrder: Int,
        status: String,
        score: Double,
        nextAction: String?
    ) -> WorkspaceSidebarSummaryPriorityItem {
        WorkspaceSidebarSummaryPriorityItem(
            workspaceId: workspace.id.uuidString,
            nativeOrder: nativeOrder,
            title: workspace.displayTitle,
            subtitle: nil,
            generatedAt: "2026-05-23T10:00:00Z",
            inputHash: workspace.id.uuidString,
            topic: WorkspaceSidebarSummaryPriorityItem.Topic(
                text: workspace.displayTitle,
                emoji: nil,
                confidence: 1
            ),
            summary: WorkspaceSidebarSummaryPriorityItem.Summary(
                short: "Workspace summary",
                detailed: "Workspace summary"
            ),
            status: status,
            presentStatus: nil,
            scores: WorkspaceSidebarSummaryPriorityItem.Scores(
                dimensions: [
                    "urgency": WorkspaceSidebarDimensionScore(
                        rawScore: score,
                        confidence: 1,
                        reason: "test score"
                    ),
                ],
                rankReason: "test score"
            ),
            nextAction: nextAction.map {
                WorkspaceSidebarSummaryPriorityItem.NextAction(
                    label: $0,
                    detail: nil,
                    risk: nil
                )
            },
            pinned: workspace.isPinned,
            stale: false,
            evidence: nil
        )
    }

    private func loadContextAgentReplayFixture(named name: String) throws -> [ContextAgentEvent] {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let fixtureURL = testFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ContextAgent/\(name).eventlog.jsonl")
        return try ContextAgentEventLog.decodeJSONLines(Data(contentsOf: fixtureURL))
    }

    private func makeActionIntent(
        id: UUID,
        workspaceId: UUID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
        snapshotUpdatedAt: Date
    ) -> ActionIntent {
        return ActionIntent(
            id: id,
            requestedBy: ActionRequester(id: "sprite", route: SortAssistantIntent.applySort.rawValue),
            kind: .applySort,
            arguments: [
                "patchId": "patch-1",
                "workspaceId": workspaceId.uuidString,
            ],
            reason: "Apply proposed sidebar order",
            evidence: ActionEvidence(
                snapshotVersions: [workspaceId: 1],
                snapshotUpdatedAt: [workspaceId: snapshotUpdatedAt],
                suggestionId: nil,
                rankingSnapshotId: nil
            ),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func waitForProviderRunRecords(
        _ agent: ContextAgent,
        minimumCount: Int
    ) async -> [ProviderRunRecord] {
        for _ in 0..<50 {
            let records = await agent.providerRunRecords()
            if records.count >= minimumCount {
                return records
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await agent.providerRunRecords()
    }

    private actor StubAssistantContextReader: AssistantContextReadable {
        private let context: AssistantWorkingContext
        private var workingContextReads = 0

        init(context: AssistantWorkingContext) {
            self.context = context
        }

        func assistantWorkingContext() async -> AssistantWorkingContext {
            workingContextReads += 1
            return context
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

        func workingContextReadCount() -> Int {
            workingContextReads
        }
    }

    private actor RecordingWorkspaceSnapshotProvider: WorkspaceSnapshotProviding {
        nonisolated let providerId = "recording"

        private var jobs: [ContextRefreshJob] = []

        func snapshot(for job: ContextRefreshJob) async throws -> WorkspaceSnapshot {
            jobs.append(job)
            return makeSnapshot(for: job)
        }

        func requestedWorkspaceIds() -> [UUID] {
            jobs.map(\.workspaceId)
        }

        func requestedReasons() -> [String] {
            jobs.map(\.reason)
        }

        private func makeSnapshot(for job: ContextRefreshJob) -> WorkspaceSnapshot {
            WorkspaceSnapshot(
                workspaceId: job.workspaceId,
                version: 1,
                updatedAt: job.enqueuedAt,
                context: NormalizedWorkspaceContext(
                    title: "workspace-\(job.workspaceId.uuidString)",
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
                    status: "ready",
                    priorityScore: nil,
                    rankReason: job.reason,
                    nextAction: nil,
                    userAttentionNeeded: 0
                ),
                digest: nil,
                freshness: ContextFreshness(
                    providers: [
                        ProviderFreshness(
                            providerId: "recording",
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

    private actor AlternateWorkspaceSnapshotProvider: WorkspaceSnapshotProviding {
        nonisolated let providerId = "alternate"

        private var jobs: [ContextRefreshJob] = []

        func snapshot(for job: ContextRefreshJob) async throws -> WorkspaceSnapshot {
            jobs.append(job)
            return WorkspaceSnapshot(
                workspaceId: job.workspaceId,
                version: 1,
                updatedAt: job.enqueuedAt,
                context: NormalizedWorkspaceContext(
                    title: "alternate-\(job.workspaceId.uuidString)",
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
                    status: "ready",
                    priorityScore: nil,
                    rankReason: nil,
                    nextAction: nil,
                    userAttentionNeeded: 0
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

        func requestedWorkspaceIds() -> [UUID] {
            jobs.map(\.workspaceId)
        }
    }

    private actor ProviderConcurrencyProbe {
        private var activeCount = 0
        private var maxActive = 0

        func begin() {
            activeCount += 1
            maxActive = max(maxActive, activeCount)
        }

        func end() {
            activeCount -= 1
        }

        func maxActiveCount() -> Int {
            maxActive
        }
    }

    private actor TrackingWorkspaceSnapshotProvider: WorkspaceSnapshotProviding {
        nonisolated let providerId: String
        private let probe: ProviderConcurrencyProbe
        private let delayNanoseconds: UInt64

        init(
            providerId: String,
            probe: ProviderConcurrencyProbe,
            delayNanoseconds: UInt64 = 10_000_000
        ) {
            self.providerId = providerId
            self.probe = probe
            self.delayNanoseconds = delayNanoseconds
        }

        func snapshot(for job: ContextRefreshJob) async throws -> WorkspaceSnapshot {
            await probe.begin()
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                await probe.end()
                return Self.snapshot(providerId: providerId, job: job)
            } catch {
                await probe.end()
                throw error
            }
        }

        nonisolated static func snapshot(
            providerId: String,
            job: ContextRefreshJob
        ) -> WorkspaceSnapshot {
            WorkspaceSnapshot(
                workspaceId: job.workspaceId,
                version: 1,
                updatedAt: job.enqueuedAt,
                context: NormalizedWorkspaceContext(
                    title: providerId,
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
                    status: "ready",
                    priorityScore: nil,
                    rankReason: nil,
                    nextAction: nil,
                    userAttentionNeeded: 0
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

    private actor SlowWorkspaceSnapshotProvider: WorkspaceSnapshotProviding {
        nonisolated let providerId = "slow"

        func snapshot(for job: ContextRefreshJob) async throws -> WorkspaceSnapshot {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return TrackingWorkspaceSnapshotProvider.snapshot(providerId: providerId, job: job)
        }
    }

    private actor ReplayWorkspaceSnapshotProvider: WorkspaceSnapshotProviding {
        nonisolated let providerId = "agent_session"

        private var versionsByWorkspaceId: [UUID: Int] = [:]

        func snapshot(for job: ContextRefreshJob) async throws -> WorkspaceSnapshot {
            let version = (versionsByWorkspaceId[job.workspaceId] ?? 0) + 1
            versionsByWorkspaceId[job.workspaceId] = version
            let status = job.payload["status"] ?? "running"
            let priorityScore = Self.double(job.payload["priorityScore"])
            let userAttentionNeeded = Self.double(job.payload["userAttentionNeeded"])
                ?? min(max((priorityScore ?? 0) / 100, 0), 1)
            let nativeOrder = Self.int(job.payload["nativeOrder"]) ?? 0
            let title = job.payload["title"] ?? "workspace-\(job.workspaceId.uuidString)"
            let rankReason = Self.nonEmpty(job.payload["rankReason"])
            let nextAction = Self.nonEmpty(job.payload["nextAction"])
            let digestSummary = Self.nonEmpty(job.payload["summary"])

            return WorkspaceSnapshot(
                workspaceId: job.workspaceId,
                version: version,
                updatedAt: job.enqueuedAt,
                context: NormalizedWorkspaceContext(
                    title: title,
                    selected: false,
                    directory: Self.nonEmpty(job.payload["directory"]),
                    listRevision: version,
                    nativeOrder: nativeOrder,
                    pinned: false,
                    locked: false,
                    customColor: nil,
                    panelCount: Self.int(job.payload["panelCount"]) ?? 0,
                    pullRequestCount: Self.int(job.payload["pullRequestCount"]) ?? 0,
                    stalePullRequestCount: Self.int(job.payload["stalePullRequestCount"]) ?? 0
                ),
                derived: DerivedWorkspaceState(
                    status: status,
                    priorityScore: priorityScore,
                    rankReason: rankReason,
                    nextAction: nextAction,
                    userAttentionNeeded: userAttentionNeeded
                ),
                digest: digestSummary.map {
                    WorkspaceDigest(summary: $0, generatedAt: job.enqueuedAt)
                },
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

        private nonisolated static func double(_ value: String?) -> Double? {
            value.flatMap(Double.init)
        }

        private nonisolated static func int(_ value: String?) -> Int? {
            value.flatMap(Int.init)
        }

        private nonisolated static func nonEmpty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return nil
            }
            return value
        }
    }

    private actor RecordingActionExecutor: CmuxActionExecutor {
        private var intentIds: [UUID] = []

        func execute(_ intent: ActionIntent) async throws -> ActionExecutionResult {
            intentIds.append(intent.id)
            return ActionExecutionResult(payload: ["executed": intent.kind.rawValue])
        }

        func executedIntentIds() -> [UUID] {
            intentIds
        }
    }

    private actor RecordingActionAuditLog: ActionAuditLog {
        private var reviewedIds: [UUID] = []
        private var executedIds: [UUID] = []

        func recordReview(intent: ActionIntent, result: SemanticReviewResult) async {
            reviewedIds.append(intent.id)
        }

        func recordExecuted(intent: ActionIntent, result: ActionExecutionResult) async {
            executedIds.append(intent.id)
        }

        func reviewedIntentIds() -> [UUID] {
            reviewedIds
        }

        func executedIntentIds() -> [UUID] {
            executedIds
        }
    }

    func testSemanticRouterDefaultTimeoutIsTwelveSeconds() {
        let defaults = UserDefaults(suiteName: "SortAssistantIntentRouterTests.defaultTimeout")!
        defaults.removePersistentDomain(forName: "SortAssistantIntentRouterTests.defaultTimeout")

        XCTAssertEqual(
            SpriteAssistantSemanticRouterSettings.resolvedTimeoutSeconds(defaults: defaults),
            12
        )
    }

    func testRouteAdjustmentCanReplaceWorkspaceColorWriteToolsWithReadOnlyTools() {
        let route = SortAssistantActionRouter().route(for: .workspaceColor)
        let adjustment = SortAssistantRouteAdjustment(
            promptFragmentMode: .replace,
            promptFragments: ["context"],
            allowedToolsMode: .replace,
            allowedTools: ["workspace_color_get"]
        )
        let adjusted = route.applying(adjustment)
        let adjustedWithFallback = route.applying(
            adjustment,
            emptyAllowedToolsFallback: route.allowedTools
        )

        XCTAssertEqual(adjusted.mode, .readOnly)
        XCTAssertFalse(adjusted.needsConfirmation)
        XCTAssertEqual(adjusted.allowedTools, ["workspace_color_get"])
        XCTAssertEqual(adjustedWithFallback.mode, .readOnly)
        XCTAssertEqual(adjustedWithFallback.allowedTools, ["workspace_color_get"])
        XCTAssertEqual(
            adjustment.applyingPromptFragments(to: ["workspace_color"]),
            ["context"]
        )
    }

    func testWorkspaceColorRouteAdjustmentCannotCollapseToNoTools() {
        let route = SortAssistantActionRouter().route(for: .workspaceColor)
        let adjustment = SortAssistantRouteAdjustment(
            promptFragmentMode: .replace,
            promptFragments: ["workspace_color"],
            removedPromptFragments: ["normal_chat"],
            allowedToolsMode: .replace,
            allowedTools: [],
            removedAllowedTools: ["workspace_color_set"]
        )
        let adjusted = route.applying(
            adjustment,
            emptyAllowedToolsFallback: route.allowedTools
        )

        XCTAssertEqual(adjusted.mode, .applyAllowed)
        XCTAssertEqual(adjusted.allowedTools, route.allowedTools)
        XCTAssertTrue(adjusted.allowedTools.contains("workspace_color_set"))
    }

    func testRouteAdjustmentCanRemoveStaleSortWriteTools() {
        let route = SortAssistantActionRouter().route(for: .applySort)
        let adjusted = route.applying(
            SortAssistantRouteAdjustment(
                removedAllowedTools: ["sort_apply", "sort_undo"]
            )
        )

        XCTAssertEqual(adjusted.mode, .previewOnly)
        XCTAssertTrue(adjusted.allowedTools.contains("sort_preview"))
        XCTAssertFalse(adjusted.allowedTools.contains("sort_apply"))
        XCTAssertFalse(adjusted.allowedTools.contains("sort_undo"))
    }

    func testSemanticDecisionParsesDynamicRouteAdjustmentModes() throws {
        let decision = try SortAssistantIntentRouter.parseDecisionForTesting(
            """
            {
              "intent": "workspace_color",
              "steps": [{"intent": "workspace_color"}],
              "routeAdjustment": {
                "promptFragmentMode": "replace",
                "promptFragments": ["normal_chat", "context"],
                "removePromptFragments": ["normal_chat"],
                "allowedToolsMode": "replace",
                "allowedTools": [
                  "mcp__cmux_sprite__workspace_color_get",
                  "workspace_color_set"
                ],
                "removeAllowedTools": ["workspace_color_set"]
              },
              "confidence": 0.93,
              "reason": "read-only follow-up"
            }
            """
        )
        let adjustment = decision.routeAdjustment
        let route = SortAssistantActionRouter()
            .route(for: decision.steps)
            .applying(adjustment)

        XCTAssertEqual(adjustment.promptFragmentMode, .replace)
        XCTAssertEqual(adjustment.allowedToolsMode, .replace)
        XCTAssertEqual(route.allowedTools, ["workspace_color_get"])
        XCTAssertEqual(route.mode, .readOnly)
        XCTAssertEqual(
            SortAssistantMCPClient.promptFragmentNamesForTesting(
                steps: decision.steps,
                adjustment: adjustment
            ),
            ["context"]
        )
    }

    func testApplyAllowedWorkspaceColorChoicePromptKeepsWorkspaceColorIntent() {
        let prompt = SortAssistantChoicePrompt(
            title: "Choose color",
            message: nil,
            options: [
                SortAssistantChoicePrompt.Option(
                    id: "red",
                    title: "Red",
                    subtitle: nil,
                    goal: "Set the active workspace color to red."
                ),
            ],
            followUpIntent: .workspaceColor,
            forceApply: true
        )

        XCTAssertTrue(prompt.forceApplyOnSubmit)
        XCTAssertEqual(prompt.intentOnSubmit, .workspaceColor)
    }

    func testExplicitSlashSortBypassesPreOperationConfirmation() {
        let router = SortAssistantActionRouter()

        let route = router.route(
            for: .proposeSort,
            explicitSlashCommand: true
        )

        XCTAssertEqual(route.mode, .previewOnly)
        XCTAssertFalse(route.needsConfirmation)
        XCTAssertTrue(route.allowedTools.contains("sort_preview"))
        XCTAssertFalse(route.allowedTools.contains("sort_apply"))
    }

    func testNaturalLanguageSortPreviewStillRequiresConfirmation() {
        let router = SortAssistantActionRouter()

        let route = router.route(for: .proposeSort)

        XCTAssertEqual(route.mode, .previewOnly)
        XCTAssertTrue(route.needsConfirmation)
    }

    func testRememberSlashDefaultsToSortMemoryCandidate() {
        let command = SortAssistantSlashCommand.parse("/remember keep active PRs near the top")

        XCTAssertEqual(
            command?.operation,
            .rememberFreeSortMemory("keep active PRs near the top")
        )
    }

    func testSpriteMemoryUsesExplicitSpriteSlashCommand() {
        let command = SortAssistantSlashCommand.parse("/remember-sprite this repo uses bun")

        XCTAssertEqual(
            command?.operation,
            .rememberSpriteMemory("this repo uses bun")
        )
    }

    func testMemorySlashDefaultsToSortMemoryList() {
        XCTAssertEqual(
            SortAssistantSlashCommand.parse("/memory")?.operation,
            .listSortMemories
        )
        XCTAssertEqual(
            SortAssistantSlashCommand.parse("/memory-sprite")?.operation,
            .listSpriteMemories
        )
    }

    func testRememberPreferenceRouteRequiresCandidateReview() {
        let router = SortAssistantActionRouter()
        let route = router.route(for: .rememberPreference)

        XCTAssertTrue(route.needsConfirmation)
        XCTAssertEqual(route.memoryWritePolicy, .candidate)
        XCTAssertTrue(route.allowedTools.contains("memory_query"))
        XCTAssertTrue(route.allowedTools.contains("memory_write_candidate"))
        XCTAssertFalse(route.allowedTools.contains("sprite_memory_write"))
    }

    func testSpriteAssistantComponentSemanticSnapshotMatchesBaseline() throws {
        let baselineURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SpriteAssistant/component-semantic-snapshot.txt")
        let expected = try String(contentsOf: baselineURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(
            Self.spriteAssistantComponentSemanticSnapshot(),
            expected
        )
    }

    private static func spriteAssistantComponentSemanticSnapshot() -> String {
        let assistantMessage = SortAssistantMessage(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            kind: .assistant,
            text: """
            CI failed on the API workspace.
            The failing check is unit-tests.
            The agent has already produced a patch.
            Review the diff before applying.
            Provider freshness is stale for github_context.
            Use the snapshot age warning in the assistant panel.
            This final line keeps the bubble collapsed by default.
            """
        )
        let userMessage = SortAssistantMessage(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            kind: .user,
            text: "What needs attention?"
        )
        let suggestion = ProactiveSuggestion(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            workspaceId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            type: ProactiveSuggestionTypes.reviewAgentWaitingUser,
            title: "Review agent output",
            reason: "Agent is waiting for your decision.",
            confidence: 0.92,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let confirmation = SortAssistantSemanticActionConfirmation(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            title: "Review before accepting suggestion",
            message: "This changes the selected workspace.",
            reasons: [
                "Snapshot evidence is stale",
                "Action targets a different workspace",
            ],
            actionName: "Accept suggestion"
        )

        let lines = [
            "SortAssistant component semantic snapshot v1",
            "",
            "message-row assistant",
            "  identifier: \(SortAssistantAccessibility.messageRow(assistantMessage.id))",
            "  kind: assistant",
            "  collapsible: \(SortAssistantMessageCollapseRules.isCollapsible(assistantMessage))",
            "  collapsedLineLimit: \(SortAssistantMessageCollapseRules.lineLimit)",
            "  copyAction: true",
            "  expandAction: true",
            "  text: \(assistantMessage.text.replacingOccurrences(of: "\n", with: " | "))",
            "",
            "message-row user",
            "  identifier: \(SortAssistantAccessibility.messageRow(userMessage.id))",
            "  kind: user",
            "  collapsible: \(SortAssistantMessageCollapseRules.isCollapsible(userMessage))",
            "  copyAction: false",
            "  expandAction: false",
            "  text: \(userMessage.text)",
            "",
            "suggestion-card",
            "  listIdentifier: \(SortAssistantAccessibility.suggestionList)",
            "  cardIdentifier: \(SortAssistantAccessibility.suggestionCard(suggestion))",
            "  openIdentifier: \(SortAssistantAccessibility.suggestionOpenButton(suggestion))",
            "  dismissIdentifier: \(SortAssistantAccessibility.suggestionDismissButton(suggestion))",
            "  type: \(suggestion.type)",
            "  title: \(suggestion.title)",
            "  reason: \(suggestion.reason ?? "")",
            String(format: "  confidence: %.2f", suggestion.confidence),
            "",
            "semantic-confirmation",
            "  identifier: \(SortAssistantAccessibility.semanticActionConfirmation)",
            "  confirmIdentifier: \(SortAssistantAccessibility.semanticActionConfirmButton)",
            "  cancelIdentifier: \(SortAssistantAccessibility.semanticActionCancelButton)",
            "  title: \(confirmation.title)",
            "  message: \(confirmation.message)",
            "  actionName: \(confirmation.actionName)",
            "  reasons: \(confirmation.reasons.joined(separator: " | "))",
            "",
            "input",
            "  containerIdentifier: \(SortAssistantAccessibility.input)",
            "  fieldIdentifier: \(SortAssistantAccessibility.inputField)",
            "  sendIdentifier: \(SortAssistantAccessibility.sendButton)",
        ]
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class SortAssistantSuggestionWorkspaceMetadataTests: XCTestCase {
    func testDisplayTextTrimsTitleAndIncludesPaneCount() {
        let metadata = SortAssistantSuggestionWorkspaceMetadata(
            title: "  Review Queue\nFollow Up  ",
            paneCount: 3
        )

        XCTAssertEqual(metadata.displayText, "Review Queue Follow Up - 3 panes")
    }

    func testDisplayTextTruncatesLongTitleBeforePaneCount() {
        let metadata = SortAssistantSuggestionWorkspaceMetadata(
            title: "  \(String(repeating: "A", count: 40))  ",
            paneCount: 1
        )

        XCTAssertEqual(
            metadata.displayText,
            "\(String(repeating: "A", count: 36))... - 1 pane"
        )
    }
}

@MainActor
final class SortAssistantMascotBadgeLayoutTests: XCTestCase {
    func testFloatingMascotBadgeExpandsFittingSizeForBadgeBleed() {
        _ = NSApplication.shared

        let plainSize = fittingSize(attentionBadgeCount: 0)
        let badgedSize = fittingSize(attentionBadgeCount: 1)

        XCTAssertEqual(
            plainSize.width,
            SortAssistantFloatingPanelMetrics.avatarSize,
            accuracy: 0.5,
            "The unbadged floating mascot should keep the configured avatar width."
        )
        XCTAssertEqual(
            plainSize.height,
            SortAssistantFloatingPanelMetrics.avatarSize,
            accuracy: 0.5,
            "The unbadged floating mascot should keep the configured avatar height."
        )
        XCTAssertGreaterThanOrEqual(
            badgedSize.width,
            plainSize.width + 5,
            "The badge's rightward bleed must participate in NSHostingView fitting size."
        )
        XCTAssertGreaterThanOrEqual(
            badgedSize.height,
            plainSize.height + 3,
            "The badge's upward bleed must participate in NSHostingView fitting size."
        )
    }

    private func fittingSize(attentionBadgeCount: Int) -> NSSize {
        let hostingView = NSHostingView(rootView: SortAssistantMascotButton(
            presentation: .floating,
            state: .idle,
            attentionBadgeCount: attentionBadgeCount,
            action: {}
        ))
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize
    }
}

final class SortAssistantFloatingPanelScreenClampTests: XCTestCase {
    func testAutomaticPlacementShrinksAndClampsToVisibleScreenInsets() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let requested = NSRect(x: -80, y: -120, width: 900, height: 700)

        let resolved = SortAssistantFloatingPanelScreenClamp.resolvedRect(
            requested,
            visibleFrame: visibleFrame,
            edgePadding: 12,
            mode: .constrained
        )

        XCTAssertEqual(resolved.origin.x, 12, accuracy: 0.001)
        XCTAssertEqual(resolved.origin.y, 12, accuracy: 0.001)
        XCTAssertEqual(resolved.size.width, 776, accuracy: 0.001)
        XCTAssertEqual(resolved.size.height, 576, accuracy: 0.001)
        XCTAssertTrue(visibleFrame.insetBy(dx: 12, dy: 12).contains(resolved))
    }

    func testManualDragPlacementKeepsHotspotRecoverableWithoutResizing() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let requested = NSRect(x: 760, y: -120, width: 420, height: 280)
        let hotspot = SortAssistantFloatingPanelMetrics.avatarDragRecoveryHotspot
        let minVisible = SortAssistantFloatingPanelMetrics.minimumVisibleDragHotspotSize

        let resolved = SortAssistantFloatingPanelScreenClamp.resolvedRect(
            requested,
            visibleFrame: visibleFrame,
            edgePadding: 12,
            mode: .manualDrag(
                hotspot: hotspot,
                minimumVisibleSize: minVisible
            )
        )

        // Computed from the actual metrics so this test tracks the configured
        // mini-sprite and drag-hotspot diameter instead of hardcoding it.
        let expectedMaxOriginX = visibleFrame.maxX - minVisible.width - hotspot.minX
        let expectedMinOriginY = visibleFrame.minY + minVisible.height - hotspot.maxY
        XCTAssertEqual(resolved.origin.x, expectedMaxOriginX, accuracy: 0.001)
        XCTAssertEqual(resolved.origin.y, expectedMinOriginY, accuracy: 0.001)
        XCTAssertEqual(resolved.size.width, requested.size.width, accuracy: 0.001)
        XCTAssertEqual(resolved.size.height, requested.size.height, accuracy: 0.001)

        let visibleHotspot = SortAssistantFloatingPanelScreenClamp.hotspotRect(
            in: resolved,
            hotspot: hotspot
        ).intersection(visibleFrame)
        XCTAssertEqual(visibleHotspot.width, minVisible.width, accuracy: 0.001)
        XCTAssertEqual(visibleHotspot.height, minVisible.height, accuracy: 0.001)
    }

    func testManualDragPlacementDoesNotMoveWhenHotspotRecoveryAreaIsVisible() {
        // A rect comfortably inside the visible frame — recovery hotspot is
        // fully on-screen, so the manualDrag clamp must be a no-op regardless
        // of the configured `minimumVisibleDragHotspotSize`.
        let requested = NSRect(x: 300, y: 200, width: 420, height: 280)

        let resolved = SortAssistantFloatingPanelScreenClamp.resolvedRect(
            requested,
            visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
            edgePadding: 12,
            mode: .manualDrag(
                hotspot: SortAssistantFloatingPanelMetrics.avatarDragRecoveryHotspot,
                minimumVisibleSize: SortAssistantFloatingPanelMetrics.minimumVisibleDragHotspotSize
            )
        )

        XCTAssertEqual(resolved.origin.x, requested.origin.x, accuracy: 0.001)
        XCTAssertEqual(resolved.origin.y, requested.origin.y, accuracy: 0.001)
        XCTAssertEqual(resolved.size.width, requested.size.width, accuracy: 0.001)
        XCTAssertEqual(resolved.size.height, requested.size.height, accuracy: 0.001)
    }

    func testUnrestrictedModeLeavesRectUnchanged() {
        let requested = NSRect(x: 920, y: -180, width: 420, height: 280)

        let resolved = SortAssistantFloatingPanelScreenClamp.resolvedRect(
            requested,
            visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
            edgePadding: 12,
            mode: .unrestricted
        )

        XCTAssertEqual(resolved.origin.x, requested.origin.x, accuracy: 0.001)
        XCTAssertEqual(resolved.origin.y, requested.origin.y, accuracy: 0.001)
        XCTAssertEqual(resolved.size.width, requested.size.width, accuracy: 0.001)
        XCTAssertEqual(resolved.size.height, requested.size.height, accuracy: 0.001)
    }
}

final class SortAssistantConversationBubbleSideTests: XCTestCase {
    private let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let edgePadding: CGFloat = 12

    private func avatar(atMinX minX: CGFloat) -> NSRect {
        NSRect(x: minX, y: 100, width: SortAssistantFloatingPanelMetrics.avatarSize, height: SortAssistantFloatingPanelMetrics.avatarSize)
    }

    // The core regression: once the bubble is opening leftward, drifting the
    // sprite back toward the center (where the right side regains room) must NOT
    // snap it back to the right. Sticky mode keeps `.left` as long as the left
    // still fits.
    func testStickyKeepsLeftWhenBothSidesHaveRoom() {
        let side = SortAssistantFloatingPanelMetrics.resolvedConversationBubbleSide(
            currentSide: .left,
            avatarOnScreen: avatar(atMinX: 900),
            visibleFrame: visibleFrame,
            edgePadding: edgePadding,
            sticky: true
        )
        XCTAssertEqual(side, .left)
    }

    // Sticky `.left` must still flip to `.right` once the leftward bubble can no
    // longer fit — i.e. the sprite is dragged near the left screen edge.
    func testStickyFlipsLeftToRightWhenLeftNoLongerFits() {
        let side = SortAssistantFloatingPanelMetrics.resolvedConversationBubbleSide(
            currentSide: .left,
            avatarOnScreen: avatar(atMinX: 50),
            visibleFrame: visibleFrame,
            edgePadding: edgePadding,
            sticky: true
        )
        XCTAssertEqual(side, .right)
    }

    func testStickyKeepsRightWhenRightHasRoom() {
        let side = SortAssistantFloatingPanelMetrics.resolvedConversationBubbleSide(
            currentSide: .right,
            avatarOnScreen: avatar(atMinX: 200),
            visibleFrame: visibleFrame,
            edgePadding: edgePadding,
            sticky: true
        )
        XCTAssertEqual(side, .right)
    }

    // Sticky `.right` flips to `.left` when the sprite reaches the right edge and
    // the rightward bubble no longer fits (the original "切到了左边" behavior).
    func testStickyFlipsRightToLeftWhenRightNoLongerFits() {
        let side = SortAssistantFloatingPanelMetrics.resolvedConversationBubbleSide(
            currentSide: .right,
            avatarOnScreen: avatar(atMinX: 1380),
            visibleFrame: visibleFrame,
            edgePadding: edgePadding,
            sticky: true
        )
        XCTAssertEqual(side, .left)
    }

    // A fresh appearance re-picks the best-fitting side, preferring the default
    // rightward bubble whenever the right has room — even if the previous side
    // was `.left`.
    func testFreshAppearancePrefersRightWhenItFits() {
        let side = SortAssistantFloatingPanelMetrics.resolvedConversationBubbleSide(
            currentSide: .left,
            avatarOnScreen: avatar(atMinX: 900),
            visibleFrame: visibleFrame,
            edgePadding: edgePadding,
            sticky: false
        )
        XCTAssertEqual(side, .right)
    }

    func testFreshAppearancePicksLeftWhenRightDoesNotFit() {
        let side = SortAssistantFloatingPanelMetrics.resolvedConversationBubbleSide(
            currentSide: .right,
            avatarOnScreen: avatar(atMinX: 1380),
            visibleFrame: visibleFrame,
            edgePadding: edgePadding,
            sticky: false
        )
        XCTAssertEqual(side, .left)
    }
}

final class SortAssistantVisibleScreenRangeTests: XCTestCase {
    func testPointVisibleWhenInsideAnyVisibleScreenFrame() {
        let frames = [
            NSRect(x: 0, y: 0, width: 800, height: 600),
            NSRect(x: 800, y: 0, width: 800, height: 600),
        ]

        XCTAssertTrue(SortAssistantVisibleScreenRange.isVisible(CGPoint(x: 40, y: 40), visibleFrames: frames))
        XCTAssertTrue(SortAssistantVisibleScreenRange.isVisible(CGPoint(x: 900, y: 40), visibleFrames: frames))
        XCTAssertFalse(SortAssistantVisibleScreenRange.isVisible(CGPoint(x: -1, y: 40), visibleFrames: frames))
    }

    func testRectCanBeFullyVisibleAcrossAdjacentScreens() {
        let frames = [
            NSRect(x: 0, y: 0, width: 800, height: 600),
            NSRect(x: 800, y: 0, width: 800, height: 600),
        ]

        XCTAssertTrue(SortAssistantVisibleScreenRange.isFullyVisible(
            NSRect(x: 760, y: 40, width: 80, height: 80),
            visibleFrames: frames
        ))
    }

    func testRectNotFullyVisibleWhenAnyPartLeavesAllScreens() {
        let frames = [
            NSRect(x: 0, y: 0, width: 800, height: 600),
        ]

        XCTAssertFalse(SortAssistantVisibleScreenRange.isFullyVisible(
            NSRect(x: 760, y: 40, width: 80, height: 80),
            visibleFrames: frames
        ))
    }
}

private final class FakeBonsplitTabItemRegionView: NSView, BonsplitTabItemHitRegionProviding {
    nonisolated(unsafe) var tabFrames: [CGRect] = []

    deinit {}

    nonisolated func containsBonsplitTabItemHit(localPoint: NSPoint) -> Bool {
        tabFrames.contains { $0.contains(localPoint) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class WindowGlassEffectTests: XCTestCase {
    func testRemoveRestoresOriginalContentHierarchy() {
        _ = NSApplication.shared

        let originalContentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: originalContentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = originalContentView

        WindowGlassEffect.apply(to: window, tintColor: .systemBlue)

        if WindowGlassEffect.isAvailable {
            XCTAssertFalse(window.contentView === originalContentView)
            XCTAssertTrue(WindowGlassEffect.originalContentView(for: window) === originalContentView)
            XCTAssertTrue(originalContentView.superview === WindowGlassEffect.foregroundContainer(for: window))
            XCTAssertNotNil(WindowGlassEffect.portalInstallationTarget(for: window))
        } else {
            XCTAssertTrue(window.contentView === originalContentView)
            XCTAssertNil(WindowGlassEffect.originalContentView(for: window))
            XCTAssertNil(WindowGlassEffect.foregroundContainer(for: window))
            XCTAssertNil(WindowGlassEffect.portalInstallationTarget(for: window))
        }
        XCTAssertTrue(Self.windowContainsGlassBackground(window))

        WindowGlassEffect.remove(from: window)

        XCTAssertTrue(window.contentView === originalContentView)
        XCTAssertNil(WindowGlassEffect.foregroundContainer(for: window))
        XCTAssertNil(WindowGlassEffect.originalContentView(for: window))
        XCTAssertFalse(Self.windowContainsGlassBackground(window))
    }

    func testNativeGlassTintFollowsWindowKeyNotifications() throws {
        guard WindowGlassEffect.isAvailable else {
            throw XCTSkip("NSGlassEffectView is unavailable on this macOS version")
        }
        _ = NSApplication.shared

        let originalContentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let window = NSWindow(
            contentRect: originalContentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = originalContentView

        WindowGlassEffect.apply(to: window, tintColor: .black, style: .clear)

        guard let backgroundView = Self.glassBackgroundView(in: window.contentView),
              let tintOverlay = backgroundView.subviews.last else {
            XCTFail("Expected glass background tint overlay")
            return
        }

        XCTAssertGreaterThan(tintOverlay.alphaValue, 0)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(tintOverlay.alphaValue, 0, accuracy: 0.001)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertGreaterThan(tintOverlay.alphaValue, 0)
    }

    private static func windowContainsGlassBackground(_ window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        let root = contentView.superview ?? contentView
        return glassBackgroundView(in: root) != nil
    }

    private static func glassBackgroundView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier == WindowGlassEffect.backgroundViewIdentifier {
            return view
        }
        return view.subviews.lazy.compactMap(glassBackgroundView(in:)).first
    }
}

@MainActor
final class WindowAccessorTests: XCTestCase {
    func testSameWindowDedupeAllowsRefreshIDChanges() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowAccessor.Coordinator()

        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-off"))
        XCTAssertFalse(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-off"))
        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-clear"))
        XCTAssertFalse(coordinator.shouldInvoke(window: window, dedupeByWindow: true, refreshID: "glass-clear"))
    }

    func testDedupeDisabledAlwaysInvokesForSameWindow() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowAccessor.Coordinator()

        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: false, refreshID: "same"))
        XCTAssertTrue(coordinator.shouldInvoke(window: window, dedupeByWindow: false, refreshID: "same"))
    }
}

@MainActor
final class MainWindowFocusRedrawTests: XCTestCase {
    func testKeyRegainInvalidatesRootContentView() {
        _ = NSApplication.shared

        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
        }

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.isVertical = true
        splitView.autoresizingMask = [.width, .height]
        splitView.dividerStyle = .thin

        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 420))
        let main = NSView(frame: NSRect(x: 221, y: 0, width: 419, height: 420))
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(main)
        contentView.addSubview(splitView)
        splitView.setPosition(220, ofDividerAt: 0)

        let window = CmuxMainWindow(
            contentRect: contentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        window.contentView = contentView
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        contentView.layoutSubtreeIfNeeded()
        splitView.adjustSubviews()

        contentView.needsDisplay = false

        appDelegate.handleCmuxWindowResignedKey(
            Notification(name: NSWindow.didResignKeyNotification, object: window)
        )
        appDelegate.handleCmuxWindowBecameKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: window)
        )

        XCTAssertTrue(
            contentView.needsDisplay,
            "Regaining key focus must invalidate the root content view."
        )
    }
}

@MainActor
final class AppDelegateWindowContextRoutingTests: XCTestCase {
    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    func testSynchronizeActiveMainWindowContextPrefersProvidedWindowOverStaleActiveManager() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowAId = UUID()
        let windowBId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowB = makeMainWindow(id: windowBId)
        defer {
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }

        let managerA = TabManager()
        let managerB = TabManager()
        app.registerMainWindow(
            windowA,
            windowId: windowAId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            windowB,
            windowId: windowBId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        windowB.makeKeyAndOrderFront(nil)
        _ = app.synchronizeActiveMainWindowContext(preferredWindow: windowB)
        XCTAssertTrue(app.tabManager === managerB)

        windowA.makeKeyAndOrderFront(nil)
        let resolved = app.synchronizeActiveMainWindowContext(preferredWindow: windowA)
        XCTAssertTrue(resolved === managerA, "Expected provided active window to win over stale active manager")
        XCTAssertTrue(app.tabManager === managerA)
    }

    func testSynchronizeActiveMainWindowContextFallsBackToActiveManagerWithoutFocusedWindow() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowAId = UUID()
        let windowBId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowB = makeMainWindow(id: windowBId)
        defer {
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }

        let managerA = TabManager()
        let managerB = TabManager()
        app.registerMainWindow(
            windowA,
            windowId: windowAId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            windowB,
            windowId: windowBId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        // Seed active manager and clear focus windows to force fallback routing.
        windowA.makeKeyAndOrderFront(nil)
        _ = app.synchronizeActiveMainWindowContext(preferredWindow: windowA)
        XCTAssertTrue(app.tabManager === managerA)
        windowA.orderOut(nil)
        windowB.orderOut(nil)

        let resolved = app.synchronizeActiveMainWindowContext(preferredWindow: nil)
        XCTAssertTrue(resolved === managerA, "Expected fallback to preserve current active manager instead of arbitrary window")
        XCTAssertTrue(app.tabManager === managerA)
    }

    func testSynchronizeActiveMainWindowContextUsesRegisteredWindowEvenIfIdentifierMutates() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer { window.orderOut(nil) }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        // SwiftUI can replace the NSWindow identifier string at runtime.
        window.identifier = NSUserInterfaceItemIdentifier("SwiftUI.AppWindow.IdentifierChanged")

        let resolved = app.synchronizeActiveMainWindowContext(preferredWindow: window)
        XCTAssertTrue(resolved === manager, "Expected registered window object identity to win even if identifier string changed")
        XCTAssertTrue(app.tabManager === manager)
    }

    func testAddWorkspaceWithoutBringToFrontPreservesActiveWindowAndSelection() {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowAId = UUID()
        let windowBId = UUID()
        let windowA = makeMainWindow(id: windowAId)
        let windowB = makeMainWindow(id: windowBId)
        defer {
            windowA.orderOut(nil)
            windowB.orderOut(nil)
        }

        let managerA = TabManager()
        let managerB = TabManager()
        app.registerMainWindow(
            windowA,
            windowId: windowAId,
            tabManager: managerA,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        app.registerMainWindow(
            windowB,
            windowId: windowBId,
            tabManager: managerB,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        windowA.makeKeyAndOrderFront(nil)
        _ = app.synchronizeActiveMainWindowContext(preferredWindow: windowA)
        XCTAssertTrue(app.tabManager === managerA)

        let originalSelectedA = managerA.selectedTabId
        let originalSelectedB = managerB.selectedTabId
        let originalTabCountB = managerB.tabs.count

        let createdWorkspaceId = app.addWorkspace(windowId: windowBId, bringToFront: false)

        XCTAssertNotNil(createdWorkspaceId)
        XCTAssertTrue(app.tabManager === managerA, "Expected non-focus workspace creation to preserve active window routing")
        XCTAssertEqual(managerA.selectedTabId, originalSelectedA)
        XCTAssertEqual(managerB.selectedTabId, originalSelectedB, "Expected background workspace creation to preserve selected tab")
        XCTAssertEqual(managerB.tabs.count, originalTabCountB + 1)
        XCTAssertTrue(managerB.tabs.contains(where: { $0.id == createdWorkspaceId }))
    }

    func testApplicationOpenURLsAddsWorkspaceForDroppedFolderURL() throws {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer { window.orderOut(nil) }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        window.makeKeyAndOrderFront(nil)
        _ = app.synchronizeActiveMainWindowContext(preferredWindow: window)

        let defaults = UserDefaults.standard
        let previousWelcomeShown = defaults.object(forKey: WelcomeSettings.shownKey)
        defaults.set(true, forKey: WelcomeSettings.shownKey)
        defer {
            if let previousWelcomeShown {
                defaults.set(previousWelcomeShown, forKey: WelcomeSettings.shownKey)
            } else {
                defaults.removeObject(forKey: WelcomeSettings.shownKey)
            }
        }

        let rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let droppedDirectory = rootDirectory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: droppedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let existingWorkspaceIds = Set(manager.tabs.map(\.id))

        app.application(
            NSApplication.shared,
            open: [URL(fileURLWithPath: droppedDirectory.path)]
        )

        let createdWorkspace = manager.tabs.first { !existingWorkspaceIds.contains($0.id) }
        XCTAssertNotNil(createdWorkspace)
        XCTAssertEqual(createdWorkspace?.currentDirectory, droppedDirectory.path)
    }

    func testApplicationOpenURLsIgnoresBundleSelfPaths() throws {
        _ = NSApplication.shared
        let app = AppDelegate()

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer { window.orderOut(nil) }

        let manager = TabManager()
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )

        window.makeKeyAndOrderFront(nil)
        _ = app.synchronizeActiveMainWindowContext(preferredWindow: window)

        let existingWorkspaceIds = Set(manager.tabs.map(\.id))
        let embeddedExecutableURL = try XCTUnwrap(Bundle.main.executableURL?.standardizedFileURL)
        let executableValues = try embeddedExecutableURL.resourceValues(forKeys: [.isExecutableKey])
        XCTAssertEqual(executableValues.isExecutable, true)
        XCTAssertNotNil(
            TerminalDefaultFileOpenRequest(fileURL: embeddedExecutableURL)
        )

        app.application(
            NSApplication.shared,
            open: [embeddedExecutableURL]
        )

        let createdWorkspace = manager.tabs.first { !existingWorkspaceIds.contains($0.id) }
        XCTAssertNil(createdWorkspace)
    }
}


@MainActor
final class AppDelegateLaunchServicesRegistrationTests: XCTestCase {
    func testDefaultTerminalRegistrationKeepsAllAdvertisedTargets() {
        XCTAssertEqual(
            DefaultTerminalRegistration.targetCount,
            DefaultTerminalRegistration.urlSchemes.count + DefaultTerminalRegistration.contentTypeIdentifiers.count
        )
        XCTAssertEqual(
            DefaultTerminalRegistration.contentType(forIdentifier: "com.apple.terminal.shell-script").identifier,
            "com.apple.terminal.shell-script"
        )
    }

    func testScheduleLaunchServicesRegistrationDefersRegisterWork() {
        _ = NSApplication.shared
        let app = AppDelegate()

        var scheduledWork: (@Sendable () -> Void)?
        var registerCallCount = 0

        app.scheduleLaunchServicesBundleRegistrationForTesting(
            bundleURL: URL(fileURLWithPath: "/tmp/../tmp/cmux-launch-services-test.app"),
            scheduler: { work in
                scheduledWork = work
            },
            register: { _ in
                registerCallCount += 1
                return noErr
            }
        )

        XCTAssertEqual(registerCallCount, 0, "Registration should not run inline on the startup call path")
        XCTAssertNotNil(scheduledWork, "Registration work should be handed to the scheduler")

        scheduledWork?()

        XCTAssertEqual(registerCallCount, 1)
    }
}

final class TerminalDefaultFileOpenRequestTests: XCTestCase {
    func testBuildsQuotedLaunchInputForTerminalCommandFile() throws {
        let contentType = DefaultTerminalRegistration.contentType(forIdentifier: "com.apple.terminal.shell-script")
        let url = URL(fileURLWithPath: "/tmp/cmux default's/Run Me.command")

        let request = try XCTUnwrap(TerminalDefaultFileOpenRequest(fileURL: url, contentType: contentType))

        XCTAssertEqual(request.workingDirectory, "/tmp/cmux default's")
        XCTAssertEqual(request.initialInput, "'/tmp/cmux default'\\''s/Run Me.command'\n")
    }

    func testIgnoresPlainTextFiles() {
        let url = URL(fileURLWithPath: "/tmp/notes.txt")

        XCTAssertNil(TerminalDefaultFileOpenRequest(fileURL: url, contentType: .plainText))
    }

    func testBuildsLaunchInputForExtensionlessUnixExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-terminal-default-executable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let executable = directory.appendingPathComponent("runme", isDirectory: false)
        try "#!/bin/sh\necho cmux\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let request = try XCTUnwrap(TerminalDefaultFileOpenRequest(fileURL: executable))

        XCTAssertEqual(request.workingDirectory, directory.path)
        XCTAssertEqual(request.initialInput, "'\(executable.path)'\n")
    }

    func testIgnoresDirectoriesWithTerminalScriptExtension() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-terminal-default-directory-\(UUID().uuidString).command", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertNil(TerminalDefaultFileOpenRequest(fileURL: directory, contentType: .directory))
    }
}


final class FocusFlashPatternTests: XCTestCase {
    func testFocusFlashPatternMatchesTerminalDoublePulseShape() {
        XCTAssertEqual(FocusFlashPattern.values, [0, 1, 0, 1, 0])
        XCTAssertEqual(FocusFlashPattern.keyTimes, [0, 0.25, 0.5, 0.75, 1])
        XCTAssertEqual(FocusFlashPattern.duration, 0.9, accuracy: 0.0001)
        XCTAssertEqual(FocusFlashPattern.curves, [.easeOut, .easeIn, .easeOut, .easeIn])
        XCTAssertEqual(FocusFlashPattern.ringInset, Double(PanelOverlayRingMetrics.inset), accuracy: 0.0001)
        XCTAssertEqual(FocusFlashPattern.ringCornerRadius, Double(PanelOverlayRingMetrics.cornerRadius), accuracy: 0.0001)
    }

    func testFocusFlashPatternSegmentsCoverFullDoublePulseTimeline() {
        let segments = FocusFlashPattern.segments
        XCTAssertEqual(segments.count, 4)

        XCTAssertEqual(segments[0].delay, 0.0, accuracy: 0.0001)
        XCTAssertEqual(segments[0].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[0].targetOpacity, 1, accuracy: 0.0001)
        XCTAssertEqual(segments[0].curve, .easeOut)

        XCTAssertEqual(segments[1].delay, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[1].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[1].targetOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(segments[1].curve, .easeIn)

        XCTAssertEqual(segments[2].delay, 0.45, accuracy: 0.0001)
        XCTAssertEqual(segments[2].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[2].targetOpacity, 1, accuracy: 0.0001)
        XCTAssertEqual(segments[2].curve, .easeOut)

        XCTAssertEqual(segments[3].delay, 0.675, accuracy: 0.0001)
        XCTAssertEqual(segments[3].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(segments[3].targetOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(segments[3].curve, .easeIn)
    }
}


@available(macOS 26.0, *)
private struct DragConfigurationOperationsSnapshot: Equatable {
    let allowCopy: Bool
    let allowMove: Bool
    let allowDelete: Bool
    let allowAlias: Bool
}

@available(macOS 26.0, *)
private enum DragConfigurationSnapshotError: Error {
    case missingBoolField(primary: String, fallback: String?)
}

@available(macOS 26.0, *)
private func dragConfigurationOperationsSnapshot<T>(from operations: T) throws -> DragConfigurationOperationsSnapshot {
    let mirror = Mirror(reflecting: operations)

    func readBool(_ primary: String, fallback: String? = nil) throws -> Bool {
        if let value = mirror.descendant(primary) as? Bool {
            return value
        }
        if let fallback, let value = mirror.descendant(fallback) as? Bool {
            return value
        }
        throw DragConfigurationSnapshotError.missingBoolField(primary: primary, fallback: fallback)
    }

    return try DragConfigurationOperationsSnapshot(
        allowCopy: readBool("allowCopy", fallback: "_allowCopy"),
        allowMove: readBool("allowMove", fallback: "_allowMove"),
        allowDelete: readBool("allowDelete", fallback: "_allowDelete"),
        allowAlias: readBool("allowAlias", fallback: "_allowAlias")
    )
}

#if compiler(>=6.2)
@MainActor
final class InternalTabDragConfigurationTests: XCTestCase {
    func testDisablesExternalOperationsForInternalTabDrags() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Requires macOS 26 drag configuration APIs")
        }

        let configuration = InternalTabDragConfigurationProvider.value
        let withinApp = try dragConfigurationOperationsSnapshot(from: configuration.operationsWithinApp)
        let outsideApp = try dragConfigurationOperationsSnapshot(from: configuration.operationsOutsideApp)

        XCTAssertEqual(
            withinApp,
            DragConfigurationOperationsSnapshot(
                allowCopy: false,
                allowMove: true,
                allowDelete: false,
                allowAlias: false
            )
        )

        XCTAssertEqual(
            outsideApp,
            DragConfigurationOperationsSnapshot(
                allowCopy: false,
                allowMove: false,
                allowDelete: false,
                allowAlias: false
            )
        )
    }
}


@MainActor
final class InternalTabDragBundleDeclarationTests: XCTestCase {
    private func exportedTypeIdentifiers(bundle: Bundle) -> Set<String> {
        let declarations = (bundle.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]) ?? []
        return Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String })
    }

    func testAppBundleExportsInternalDragTypes() {
        let exported = exportedTypeIdentifiers(bundle: Bundle(for: AppDelegate.self))

        XCTAssertTrue(
            exported.contains("com.splittabbar.tabtransfer"),
            "Expected app bundle to export bonsplit tab-transfer type, got \(exported)"
        )
        XCTAssertTrue(
            exported.contains("com.cmux.sidebar-tab-reorder"),
            "Expected app bundle to export sidebar tab-reorder type, got \(exported)"
        )
    }
}
#endif


@MainActor
final class WindowDragHandleHitTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class HostContainerView: NSView {}
    private final class BlockingTopHitContainerView: NSView {
        var hitCount = 0

        override func hitTest(_ point: NSPoint) -> NSView? {
            hitCount += 1
            return bounds.contains(point) ? self : nil
        }
    }
    private final class PassThroughProbeView: NSView {
        var onHitTest: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            onHitTest?()
            return nil
        }
    }
    private final class PassiveHostContainerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            return super.hitTest(point) ?? self
        }
    }

    private final class SidebarActionRegionView: NSView, MinimalModeSidebarControlActionHitRegionProviding {
        nonisolated(unsafe) var config = TitlebarControlsStyle.classic.config

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        nonisolated func containsMinimalModeTitlebarControlHit(localPoint: NSPoint) -> Bool {
            minimalModeSidebarControlActionSlot(localPoint: localPoint) != nil
        }

        nonisolated func minimalModeSidebarControlActionSlot(localPoint: NSPoint) -> MinimalModeSidebarControlActionSlot? {
            let ranges = TitlebarControlsHitRegions.buttonXRanges(config: config)
            for (index, range) in ranges.enumerated() where range.contains(localPoint.x) {
                return MinimalModeSidebarControlActionSlot(rawValue: index)
            }
            return nil
        }
    }

    private final class MutatingSiblingView: NSView {
        weak var container: NSView?
        private var didMutate = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            guard !didMutate, let container else { return nil }
            didMutate = true
            let transient = NSView(frame: .zero)
            container.addSubview(transient)
            transient.removeFromSuperview()
            return nil
        }
    }

    private final class ReentrantDragHandleView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let shouldCapture = windowDragHandleShouldCaptureHit(point, in: self, eventType: .leftMouseDown, eventWindow: self.window)
            return shouldCapture ? self : nil
        }
    }

    private final class RecordingTitlebarActionWindow: NSWindow {
        var zoomCallCount = 0
        var miniaturizeCallCount = 0

        override func zoom(_ sender: Any?) {
            zoomCallCount += 1
        }

        override func miniaturize(_ sender: Any?) {
            miniaturizeCallCount += 1
        }
    }

    /// A sibling view whose hitTest re-enters windowDragHandleShouldCaptureHit,
    /// simulating the crash path where sibling.hitTest triggers a SwiftUI layout
    /// pass that calls back into the drag handle's hit resolution.
    private final class ReentrantSiblingView: NSView {
        weak var dragHandle: NSView?
        var reenteredResult: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point), let dragHandle else { return nil }
            // Simulate the re-entry: during sibling hit test, SwiftUI layout
            // calls windowDragHandleShouldCaptureHit on the drag handle again.
            reenteredResult = windowDragHandleShouldCaptureHit(
                point, in: dragHandle, eventType: .leftMouseDown, eventWindow: dragHandle.window
            )
            return nil
        }
    }

    private static func firstSubview(
        in view: NSView,
        matching predicate: (NSView) -> Bool
    ) -> NSView? {
        if predicate(view) {
            return view
        }

        for subview in view.subviews {
            if let match = firstSubview(in: subview, matching: predicate) {
                return match
            }
        }

        return nil
    }

    private static func firstCapturableTitlebarPoint(
        in dragHandle: NSView,
        window: NSWindow
    ) -> NSPoint? {
        let bounds = dragHandle.bounds.insetBy(dx: 4, dy: 4)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let yCandidates = [
            bounds.midY,
            bounds.minY + bounds.height * 0.25,
            bounds.minY + bounds.height * 0.75
        ]

        for y in yCandidates {
            var x = bounds.maxX
            while x >= bounds.minX {
                let point = NSPoint(x: x, y: y)
                if windowDragHandleShouldCaptureHit(
                    point,
                    in: dragHandle,
                    eventType: .leftMouseDown,
                    eventWindow: window
                ) {
                    return point
                }
                x -= 4
            }
        }

        return nil
    }

    func testDragHandleCapturesHitWhenNoSiblingClaimsPoint() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown),
            "Empty titlebar space should drag the window"
        )
    }

    func testDragHandleYieldsWhenSiblingClaimsPoint() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let folderIconHost = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        container.addSubview(folderIconHost)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle, eventType: .leftMouseDown),
            "Interactive titlebar controls should receive the mouse event"
        )
        XCTAssertTrue(windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown))
    }

    func testTitlebarControlGapsAreOutsideButtonHitColumns() {
        let config = TitlebarControlsStyle.classic.config
        let ranges = TitlebarControlsHitRegions.buttonXRanges(config: config)
        XCTAssertEqual(ranges.count, MinimalModeSidebarControlActionSlot.allCases.count)
        XCTAssertEqual(
            ranges[0].lowerBound,
            TitlebarControlsLayoutMetrics.hintLeadingPadding + config.groupPadding.leading,
            accuracy: 0.001,
            "Hidden titlebar hit regions should share the visible titlebar control leading position."
        )

        XCTAssertTrue(
            TitlebarControlsHitRegions.pointFallsInButtonColumn(
                NSPoint(x: ranges[0].lowerBound + 1, y: 14),
                config: config
            ),
            "Icon button columns should stay interactive"
        )

        let firstGapX = (ranges[0].upperBound + ranges[1].lowerBound) / 2
        let secondGapX = (ranges[1].upperBound + ranges[2].lowerBound) / 2

        XCTAssertFalse(
            TitlebarControlsHitRegions.pointFallsInButtonColumn(NSPoint(x: firstGapX, y: 14), config: config),
            "The gap between the sidebar and notification icons should remain available for window dragging"
        )
        XCTAssertFalse(
            TitlebarControlsHitRegions.pointFallsInButtonColumn(NSPoint(x: secondGapX, y: 14), config: config),
            "The gap between the notification and new-workspace icons should remain available for window dragging"
        )
    }

    func testDragHandleYieldsToRegisteredMinimalModeSidebarButtonColumns() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let dragHandle = NSView(frame: contentView.bounds)
        dragHandle.autoresizingMask = [.width, .height]
        contentView.addSubview(dragHandle)

        let controlRegion = SidebarActionRegionView(
            frame: NSRect(
                x: 72,
                y: 88,
                width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
            )
        )
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        let ranges = TitlebarControlsHitRegions.buttonXRanges(config: controlRegion.config)
        let backButtonPoint = NSPoint(
            x: controlRegion.frame.minX + ranges[MinimalModeSidebarControlActionSlot.focusHistoryBack.rawValue].lowerBound + 1,
            y: controlRegion.frame.midY
        )
        XCTAssertTrue(isMinimalModeTitlebarControlHit(window: window, locationInWindow: backButtonPoint))
        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(
                dragHandle.convert(backButtonPoint, from: nil),
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Registered minimal-mode titlebar buttons should not fall through to the window drag handle."
        )

        let emptyTitlebarPoint = NSPoint(x: contentView.bounds.maxX - 20, y: controlRegion.frame.midY)
        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(
                dragHandle.convert(emptyTitlebarPoint, from: nil),
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Empty titlebar space should still be draggable."
        )
    }

    func testMinimalModeSidebarFallbackHitUsesHardcodedLeadingInset() {
        let suiteName = "WindowDragHandleHitTests.leadingInset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(TitlebarControlsStyle.classic.rawValue, forKey: "titlebarControlsStyle")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.test")
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let firstButtonX = TitlebarControlsHitRegions.buttonXRanges(config: TitlebarControlsStyle.classic.config)[0].lowerBound + 1
        let titlebarY = contentView.bounds.maxY - 4
        XCTAssertEqual(
            minimalModeSidebarControlActionSlot(
                window: window,
                locationInWindow: NSPoint(
                    x: CGFloat(MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset) + firstButtonX,
                    y: titlebarY
                ),
                defaults: defaults
            ),
            .toggleSidebar
        )
    }

    func testMinimalModeSidebarTitlebarControlsAlignWithTrafficLightCenter() {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: WorkspacePresentationModeSettings.modeKey)
        // WindowDecorationsController.apply reads the production presentation-mode setting
        // from UserDefaults.standard, so this test saves and restores the shared key narrowly.
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defer {
            if let savedMode {
                defaults.set(savedMode, forKey: WorkspacePresentationModeSettings.modeKey)
            } else {
                defaults.removeObject(forKey: WorkspacePresentationModeSettings.modeKey)
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.test")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        defer { window.orderOut(nil) }

        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let closeButton = window.standardWindowButton(.closeButton),
              let closeButtonSuperview = closeButton.superview else {
            XCTFail("Expected close traffic-light button")
            return
        }

        let controller = WindowDecorationsController()
        controller.apply(to: window)

        guard let target = contentView.subviews.compactMap({ $0 as? MinimalModeSidebarControlActionView }).first else {
            XCTFail("Expected minimal sidebar titlebar click target")
            return
        }

        let trafficLightFrame = closeButtonSuperview.convert(closeButton.frame, to: contentView)
        XCTAssertEqual(
            target.frame.midY,
            trafficLightFrame.midY,
            accuracy: 0.25,
            "Minimal-mode sidebar controls should share the traffic-light center Y"
        )
    }

    func testTitlebarChromeSettingsUseDefaultsAndStoredOverrides() {
        let suiteName = "WindowDragHandleHitTests.titlebarChromeSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let snapshot = MinimalModeTitlebarDebugSettings.snapshot(defaults: defaults)
        XCTAssertEqual(
            snapshot.leftControlsLeadingInset,
            MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            snapshot.leftControlsTopInset,
            MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MinimalModeTitlebarDebugSettings.leftControlsLeadingInset(defaults: defaults),
            CGFloat(MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset),
            accuracy: 0.001
        )
        XCTAssertEqual(
            MinimalModeSidebarTitlebarControlsMetrics.topInset(defaults: defaults),
            CGFloat(MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset),
            accuracy: 0.001
        )

        defaults.set(44.5, forKey: MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey)
        defaults.set(6.5, forKey: MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey)
        defaults.set(12.0, forKey: "titlebarDebug.trafficLightsXOffset")
        defaults.set(-3.0, forKey: "titlebarDebug.trafficLightsYOffset")
        defaults.set(88.0, forKey: MinimalModeTitlebarDebugSettings.trafficLightTabBarInsetKey)
        defaults.set(92.0, forKey: MinimalModeTitlebarDebugSettings.trafficLightTitlebarLeadingInsetKey)

        let storedSnapshot = MinimalModeTitlebarDebugSettings.snapshot(defaults: defaults)
        XCTAssertEqual(storedSnapshot.leftControlsLeadingInset, 44.5, accuracy: 0.001)
        XCTAssertEqual(storedSnapshot.leftControlsTopInset, 6.5, accuracy: 0.001)
        XCTAssertEqual(storedSnapshot.trafficLightTabBarLeadingInset, 88.0, accuracy: 0.001)
        XCTAssertEqual(storedSnapshot.trafficLightTitlebarLeadingInset, 92.0, accuracy: 0.001)

        defaults.set(999.0, forKey: MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey)
        XCTAssertEqual(
            MinimalModeTitlebarDebugSettings.leftControlsLeadingInset(defaults: defaults),
            CGFloat(MinimalModeTitlebarDebugSettings.horizontalInsetRange.upperBound),
            accuracy: 0.001
        )
    }

    func testTitlebarChromeSettingsIgnoreLegacyNativeTrafficLightOffsets() {
        let suiteName = "WindowDragHandleHitTests.titlebarChromeLegacyTrafficLights.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(44.0, forKey: "titlebarDebug.trafficLightsXOffset")
        defaults.set(-12.0, forKey: "titlebarDebug.trafficLightsYOffset")

        let snapshot = MinimalModeTitlebarDebugSettings.snapshot(defaults: defaults)
        XCTAssertEqual(
            snapshot,
            MinimalModeTitlebarDebugSnapshot(
                leftControlsLeadingInset: MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset,
                leftControlsTopInset: MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset,
                trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset,
                trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset
            )
        )
    }

    func testDragHandleIgnoresHiddenSiblingWhenResolvingHit() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let hidden = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        hidden.isHidden = true
        container.addSubview(hidden)

        XCTAssertTrue(windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle, eventType: .leftMouseDown))
    }

    func testDragHandleDoesNotCaptureOutsideBounds() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        XCTAssertFalse(windowDragHandleShouldCaptureHit(NSPoint(x: 240, y: 18), in: dragHandle, eventType: .leftMouseDown))
    }

    func testDragHandleSkipsCaptureForPassivePointerEvents() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let point = NSPoint(x: 180, y: 18)
        XCTAssertFalse(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .mouseMoved))
        XCTAssertFalse(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .cursorUpdate))
        XCTAssertFalse(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: nil))
        XCTAssertTrue(windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .leftMouseDown))
    }

    func testDragHandleNeverCapturesRegisteredBonsplitPaneTab() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let container = NSView(frame: contentView.bounds)
        contentView.addSubview(container)

        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 20, y: 82, width: 220, height: 30))
        tabRegion.tabFrames = [CGRect(x: 8, y: 0, width: 96, height: 30)]
        container.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer { BonsplitTabItemHitRegionRegistry.unregister(tabRegion) }

        let tabWindowPoint = tabRegion.convert(NSPoint(x: 48, y: 15), to: nil)
        let tabDragHandlePoint = dragHandle.convert(tabWindowPoint, from: nil)
        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(
                tabDragHandlePoint,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "A visible pane tab must own its mouse-down; the titlebar drag handle must not turn it into a window drag"
        )

        let emptyWindowPoint = tabRegion.convert(NSPoint(x: 180, y: 15), to: nil)
        let emptyDragHandlePoint = dragHandle.convert(emptyWindowPoint, from: nil)
        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(
                emptyDragHandlePoint,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Empty tab-strip chrome should remain available for app-window dragging"
        )
    }

    func testTabBarEmptyChromeOverlayNeverCapturesRegisteredBonsplitPaneTabWhenFrameCacheIsEmpty() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let dragZone = TabBarDragZoneView.DragNSView(frame: NSRect(x: 0, y: 72, width: 320, height: 30))
        dragZone.hitRegion = .trailingEmptyChrome(tabFrames: [], reservedTrailingWidth: 48)
        dragZone.hitTestEventTypeOverride = .leftMouseDown
        contentView.addSubview(dragZone)

        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 10, y: 72, width: 90, height: 30))
        tabRegion.tabFrames = [tabRegion.bounds]
        contentView.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer { BonsplitTabItemHitRegionRegistry.unregister(tabRegion) }

        XCTAssertNil(
            dragZone.hitTest(NSPoint(x: 40, y: 15)),
            "The empty-chrome overlay must not turn a pane-tab mouse-down into an app-window drag while tab frames are still populating"
        )
        XCTAssertIdentical(
            dragZone.hitTest(NSPoint(x: 140, y: 15)),
            dragZone,
            "Empty tab-strip chrome after the registered tab should still be available for app-window dragging"
        )
    }

    func testDragHandleSkipsForeignLeftMouseDownDuringLaunch() {
        let point = NSPoint(x: 180, y: 18)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let container = NSView(frame: contentView.bounds)
        container.autoresizingMask = [.width, .height]
        contentView.addSubview(container)

        let dragHandle = NSView(frame: container.bounds)
        dragHandle.autoresizingMask = [.width, .height]
        container.addSubview(dragHandle)

        let foreignWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { foreignWindow.orderOut(nil) }

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(
                point,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: nil
            ),
            "Launch activation events without a matching window should not trigger drag-handle hierarchy walk"
        )

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(
                point,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: foreignWindow
            ),
            "Left mouse-down events for a different window should be treated as passive"
        )

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(
                point,
                in: dragHandle,
                eventType: .leftMouseDown,
                eventWindow: window
            ),
            "Left mouse-down events for this window should still capture empty titlebar space"
        )
    }

    func testPassiveHostingTopHitClassification() {
        XCTAssertTrue(windowDragHandleShouldTreatTopHitAsPassiveHost(HostContainerView(frame: .zero)))
        XCTAssertFalse(windowDragHandleShouldTreatTopHitAsPassiveHost(NSButton(frame: .zero)))
    }

    func testMinimalModeTitlebarControlRegionRegistryMatchesVisibleRegisteredView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let controlRegion = NSView(frame: NSRect(x: 72, y: 88, width: 124, height: 28))
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        XCTAssertTrue(isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 100, y: 100)))
        XCTAssertFalse(isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 20, y: 100)))

        controlRegion.isHidden = true
        XCTAssertFalse(isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 100, y: 100)))
    }

    func testMinimalModeTitlebarControlRegionCanLimitHitsInsideRegisteredView() {
        final class ButtonOnlyRegion: NSView, MinimalModeTitlebarControlHitRegionProviding {
            nonisolated func containsMinimalModeTitlebarControlHit(localPoint: NSPoint) -> Bool {
                localPoint.x >= 24 && localPoint.x <= 48
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let controlRegion = ButtonOnlyRegion(frame: NSRect(x: 72, y: 88, width: 124, height: 28))
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        XCTAssertTrue(
            isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 100, y: 100)),
            "Expected points inside the provider's button range to suppress titlebar double-click handling."
        )
        XCTAssertFalse(
            isMinimalModeTitlebarControlHit(window: window, locationInWindow: NSPoint(x: 136, y: 100)),
            "Expected gaps inside the registered view to keep behaving like titlebar chrome."
        )
    }

    func testMinimalModeSidebarActionSlotUsesRegisteredHostFrame() {
        let suiteName = "WindowDragHandleHitTests.sidebarHostFrame.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(TitlebarControlsStyle.classic.rawValue, forKey: "titlebarControlsStyle")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.test")
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let controlRegion = SidebarActionRegionView(frame: NSRect(x: 88, y: 88, width: 124, height: 28))
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        XCTAssertEqual(
            minimalModeSidebarControlActionSlot(
                window: window,
                locationInWindow: NSPoint(x: controlRegion.frame.minX + 50, y: controlRegion.frame.minY + 14),
                defaults: defaults
            ),
            .showNotifications,
            "Sidebar control actions should use the actual registered host frame instead of a fixed window x origin."
        )
    }

    func testMinimalModeSidebarActionSlotUsesRegisteredHostFrameBelowFallbackBand() {
        let suiteName = "WindowDragHandleHitTests.sidebarHostFrameBand.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(WorkspacePresentationModeSettings.Mode.minimal.rawValue, forKey: WorkspacePresentationModeSettings.modeKey)
        defaults.set(TitlebarControlsStyle.classic.rawValue, forKey: "titlebarControlsStyle")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.test")
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let controlRegion = SidebarActionRegionView(frame: NSRect(x: 88, y: 88, width: 124, height: 28))
        contentView.addSubview(controlRegion)
        MinimalModeTitlebarControlHitRegionRegistry.register(controlRegion)
        defer { MinimalModeTitlebarControlHitRegionRegistry.unregister(controlRegion) }

        let point = NSPoint(x: controlRegion.frame.minX + 14, y: controlRegion.frame.minY + 1)
        XCTAssertFalse(
            isPointInMinimalModeTitlebarBand(
                isEnabled: true,
                point: point,
                bounds: contentView.bounds,
                topStripHeight: MinimalModeChromeMetrics.titlebarHeight
            ),
            "The regression point should sit inside the visual control host but outside the hard-coded fallback band."
        )
        XCTAssertEqual(
            minimalModeSidebarControlActionSlot(window: window, locationInWindow: point, defaults: defaults),
            .toggleSidebar
        )
        XCTAssertTrue(
            isMinimalModeSidebarChromeHoverCandidate(window: window, locationInWindow: point, defaults: defaults),
            "Hover reveal should follow the real control host frame."
        )
    }

    func testSuppressedTitlebarDoubleClickConsumesWithoutWindowAction() {
        XCTAssertEqual(
            handleTitlebarDoubleClick(window: nil, behavior: .suppress),
            .suppressed
        )
        XCTAssertEqual(
            handleTitlebarDoubleClick(window: nil, behavior: .standardAction),
            .ignored
        )
        XCTAssertTrue(TitlebarDoubleClickHandlingResult.suppressed.consumesEvent)
        XCTAssertFalse(TitlebarDoubleClickHandlingResult.ignored.consumesEvent)
    }

    func testMinimalModeDoubleClickHandlerOnlyHandlesTopStripDoubleClicks() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertTrue(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: true,
                clickCount: 2,
                point: NSPoint(x: 200, y: 292),
                bounds: bounds,
                topStripHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: true,
                clickCount: 2,
                point: NSPoint(x: 200, y: 240),
                bounds: bounds,
                topStripHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: false,
                clickCount: 2,
                point: NSPoint(x: 200, y: 292),
                bounds: bounds,
                topStripHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeTitlebarDoubleClick(
                isEnabled: true,
                clickCount: 1,
                point: NSPoint(x: 200, y: 292),
                bounds: bounds,
                topStripHeight: 30
            )
        )
    }

    func testMinimalModeWindowDoubleClickRequiresMainTopStrip() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertTrue(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: false,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: false,
                isFullScreen: false,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: true,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: false,
                isMainWindow: false,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 292),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
        XCTAssertFalse(
            shouldHandleMinimalModeWindowTitlebarDoubleClick(
                isMinimalMode: true,
                isFullScreen: false,
                isMainWindow: true,
                clickCount: 2,
                locationInWindow: NSPoint(x: 200, y: 240),
                contentBounds: bounds,
                titlebarBandHeight: 30
            )
        )
    }

    func testMinimalModeTitlebarConsecutiveClicksCanFormDoubleClick() {
        let previous = MinimalModeTitlebarClickRecord(
            windowNumber: 42,
            timestamp: 10,
            locationInWindow: NSPoint(x: 200, y: 292)
        )

        XCTAssertTrue(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.2,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.65,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertTrue(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.62,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5,
                doubleClickIntervalTolerance: 0.15
            )
        )
        XCTAssertTrue(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 2,
                timestamp: 20,
                locationInWindow: NSPoint(x: 20, y: 20),
                windowNumber: 99,
                previous: nil,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.8,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.2,
                locationInWindow: NSPoint(x: 240, y: 292),
                windowNumber: 42,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
        XCTAssertFalse(
            minimalModeTitlebarClickFormsDoubleClick(
                clickCount: 1,
                timestamp: 10.2,
                locationInWindow: NSPoint(x: 201, y: 291),
                windowNumber: 43,
                previous: previous,
                doubleClickInterval: 0.5
            )
        )
    }

    func testDragHandleIgnoresPassiveHostSiblingHit() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let passiveHost = PassiveHostContainerView(frame: container.bounds)
        container.addSubview(passiveHost)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown),
            "Passive host wrappers should not block titlebar drag capture"
        )
    }

    func testDragHandleRespectsInteractiveChildInsidePassiveHost() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let passiveHost = PassiveHostContainerView(frame: container.bounds)
        let folderControl = CapturingView(frame: NSRect(x: 10, y: 10, width: 16, height: 16))
        passiveHost.addSubview(folderControl)
        container.addSubview(passiveHost)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(NSPoint(x: 14, y: 14), in: dragHandle, eventType: .leftMouseDown),
            "Interactive controls inside passive host wrappers should still receive hits"
        )
    }

    func testTopHitResolutionStateIsScopedPerWindow() {
        let point = NSPoint(x: 100, y: 18)

        let outerWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { outerWindow.orderOut(nil) }
        guard let outerContentView = outerWindow.contentView else {
            XCTFail("Expected outer content view")
            return
        }
        let outerContainer = NSView(frame: outerContentView.bounds)
        outerContainer.autoresizingMask = [.width, .height]
        outerContentView.addSubview(outerContainer)
        let outerDragHandle = NSView(frame: outerContainer.bounds)
        outerDragHandle.autoresizingMask = [.width, .height]
        outerContainer.addSubview(outerDragHandle)

        let nestedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { nestedWindow.orderOut(nil) }
        guard let nestedContentView = nestedWindow.contentView else {
            XCTFail("Expected nested content view")
            return
        }
        let nestedContainer = NSView(frame: nestedContentView.bounds)
        nestedContainer.autoresizingMask = [.width, .height]
        nestedContentView.addSubview(nestedContainer)
        let nestedDragHandle = NSView(frame: nestedContainer.bounds)
        nestedDragHandle.autoresizingMask = [.width, .height]
        nestedContainer.addSubview(nestedDragHandle)
        let nestedBlockingOverlay = BlockingTopHitContainerView(frame: nestedContainer.bounds)
        nestedBlockingOverlay.autoresizingMask = [.width, .height]
        nestedContainer.addSubview(nestedBlockingOverlay)

        XCTAssertFalse(
            windowDragHandleShouldCaptureHit(point, in: nestedDragHandle, eventType: .leftMouseDown, eventWindow: nestedWindow),
            "Nested window drag handle should be blocked by top-hit titlebar container"
        )
        XCTAssertEqual(nestedBlockingOverlay.hitCount, 1)

        var nestedCaptureResult: Bool?
        let probe = PassThroughProbeView(frame: outerContainer.bounds)
        probe.autoresizingMask = [.width, .height]
        probe.onHitTest = {
            nestedCaptureResult = windowDragHandleShouldCaptureHit(point, in: nestedDragHandle, eventType: .leftMouseDown, eventWindow: nestedWindow)
        }
        outerContainer.addSubview(probe)

        _ = windowDragHandleShouldCaptureHit(point, in: outerDragHandle, eventType: .leftMouseDown, eventWindow: outerWindow)

        XCTAssertEqual(
            nestedCaptureResult,
            false,
            "Top-hit recursion in one window must not disable top-hit resolution in another window"
        )
        XCTAssertEqual(
            nestedBlockingOverlay.hitCount,
            2,
            "Nested window should resolve its own blocking sibling while another window is resolving hits"
        )
    }

    func testDragHandleRemainsStableWhenSiblingMutatesSubviewsDuringHitTest() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let mutatingSibling = MutatingSiblingView(frame: container.bounds)
        mutatingSibling.container = container
        container.addSubview(mutatingSibling)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(NSPoint(x: 180, y: 18), in: dragHandle, eventType: .leftMouseDown),
            "Subview mutations during hit testing should not crash or break drag-handle capture"
        )
    }

    func testDragHandleSiblingHitTestReentrancyDoesNotCrash() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 36))
        let dragHandle = NSView(frame: container.bounds)
        container.addSubview(dragHandle)

        let reentrantSibling = ReentrantSiblingView(frame: container.bounds)
        reentrantSibling.dragHandle = dragHandle
        container.addSubview(reentrantSibling)

        // The outer call enters the sibling walk, which calls
        // reentrantSibling.hitTest(), which re-enters
        // windowDragHandleShouldCaptureHit. Without the re-entrancy guard
        // this would trigger a Swift exclusive-access violation (SIGABRT).
        let outerResult = windowDragHandleShouldCaptureHit(
            NSPoint(x: 110, y: 18), in: dragHandle, eventType: .leftMouseDown
        )
        XCTAssertTrue(outerResult, "Outer call should still capture when sibling returns nil")
        XCTAssertEqual(
            reentrantSibling.reenteredResult, false,
            "Re-entrant call should bail out (return false) instead of crashing"
        )
    }

    func testDragHandleTopHitResolutionSurvivesSameWindowReentrancy() {
        let point = NSPoint(x: 180, y: 18)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 36),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let container = NSView(frame: contentView.bounds)
        container.autoresizingMask = [.width, .height]
        contentView.addSubview(container)

        let dragHandle = ReentrantDragHandleView(frame: container.bounds)
        dragHandle.autoresizingMask = [.width, .height]
        container.addSubview(dragHandle)

        XCTAssertTrue(
            windowDragHandleShouldCaptureHit(point, in: dragHandle, eventType: .leftMouseDown, eventWindow: window),
            "Reentrant same-window top-hit resolution should not trigger exclusivity crashes"
        )
    }

    func testRightSidebarModeBarEmptySpaceDoubleClickPerformsTitlebarAction() {
        _ = NSApplication.shared

        let previousGlobalDefaults = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        var testGlobalDefaults = previousGlobalDefaults ?? [:]
        testGlobalDefaults["AppleActionOnDoubleClick"] = "Fill"
        testGlobalDefaults["AppleMiniaturizeOnDoubleClick"] = false
        UserDefaults.standard.setPersistentDomain(testGlobalDefaults, forName: UserDefaults.globalDomain)
        defer {
            if let previousGlobalDefaults {
                UserDefaults.standard.setPersistentDomain(previousGlobalDefaults, forName: UserDefaults.globalDomain)
            } else {
                UserDefaults.standard.removePersistentDomain(forName: UserDefaults.globalDomain)
            }
        }

        let window = RecordingTitlebarActionWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 260),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let rootView = RightSidebarPanelView(
            tabManager: TabManager(),
            fileExplorerStore: FileExplorerStore(),
            fileExplorerState: FileExplorerState(),
            sessionIndexStore: SessionIndexStore(),
            workspaceTabStore: WorkspaceTabStore(),
            titlebarHeight: 36,
            workspaceId: nil,
            onResumeSession: nil,
            onOpenFilePreview: { _ in },
            onOpenAsPane: { _ in },
            onClose: {}
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = window.contentRect(forFrameRect: window.frame)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        guard let dragHandle = Self.firstSubview(
            in: hostingView,
            matching: { $0.identifier == WindowDragHandleView.viewIdentifier }
        ) else {
            XCTFail("Expected right-sidebar mode bar to install a titlebar drag handle")
            return
        }

        guard let emptyModeBarLocalPoint = Self.firstCapturableTitlebarPoint(
            in: dragHandle,
            window: window
        ) else {
            XCTFail("Expected right-sidebar mode bar to expose at least one empty titlebar point")
            return
        }

        let emptyModeBarPoint = dragHandle.convert(emptyModeBarLocalPoint, to: nil as NSView?)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: emptyModeBarPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1.0
        ) else {
            XCTFail("Expected to create right-sidebar mode-bar double-click event")
            return
        }

        NSApp.sendEvent(event)

        XCTAssertEqual(window.zoomCallCount, 1)
        XCTAssertEqual(window.miniaturizeCallCount, 0)
    }
}

#if DEBUG


@MainActor
final class DraggableFolderHitTests: XCTestCase {
    func testFolderHitTestReturnsContainerWhenInsideBounds() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 0, y: 0, width: 16, height: 16)

        guard let hit = folderView.hitTest(NSPoint(x: 8, y: 8)) else {
            XCTFail("Expected folder icon to capture inside hit")
            return
        }
        XCTAssertTrue(hit === folderView)
    }

    func testFolderHitTestReturnsNilOutsideBounds() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 0, y: 0, width: 16, height: 16)

        XCTAssertNil(folderView.hitTest(NSPoint(x: 20, y: 8)))
    }

    func testFolderIconDisablesWindowMoveBehavior() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        XCTAssertFalse(folderView.mouseDownCanMoveWindow)
    }
}


@MainActor
final class TitlebarLeadingInsetPassthroughViewTests: XCTestCase {
    func testLeadingInsetViewDoesNotParticipateInHitTesting() {
        let view = TitlebarLeadingInsetPassthroughView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertNil(view.hitTest(NSPoint(x: 20, y: 10)))
    }

    func testLeadingInsetViewCannotMoveWindowViaMouseDown() {
        let view = TitlebarLeadingInsetPassthroughView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }

    func testMainWindowHostingViewCannotMoveWindowViaMouseDown() {
        let view = MainWindowHostingView(rootView: Color.clear)
        XCTAssertFalse(
            view.mouseDownCanMoveWindow,
            "Main content must never become an implicit AppKit window-drag region; explicit titlebar chrome owns app-window dragging"
        )
    }

    func testMainWindowDragBehaviorRequiresExplicitDragZones() {
        let window = CmuxMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.isMovable = true
        window.isMovableByWindowBackground = true

        configureCmuxMainWindowDragBehavior(window)

        XCTAssertFalse(
            window.isMovable,
            "Main windows must not use native AppKit titlebar dragging because pane tabs live in the titlebar band"
        )
        XCTAssertFalse(window.isMovableByWindowBackground)

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, false)
        XCTAssertFalse(
            window.isMovable,
            "Explicit chrome drag zones may temporarily enable movement, but the main window must return to pane-tab-safe immovable state"
        )
    }
}


@Suite("Custom titlebar leading padding")
struct CustomTitlebarLeadingPaddingTests {
    @Test func hiddenSidebarUsesMinimumSidebarTitleInset() {
        #expect(
            ContentView.customTitlebarLeadingPadding(
                isFullScreen: false,
                isSidebarVisible: false,
                sidebarWidth: 216,
                minimumSidebarWidth: 216,
                titlebarLeadingInset: 82
            ) == 228
        )
    }

    @Test func minimumWidthVisibleSidebarMatchesHiddenSidebarTitleInset() {
        let hidden = ContentView.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: false,
            sidebarWidth: 216,
            minimumSidebarWidth: 216,
            titlebarLeadingInset: 82
        )
        let visible = ContentView.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: true,
            sidebarWidth: 216,
            minimumSidebarWidth: 216,
            titlebarLeadingInset: 82
        )

        #expect(visible == hidden)
    }

    @Test func widerSidebarPushesTitlebarContentRight() {
        let hidden = ContentView.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: false,
            sidebarWidth: 216,
            minimumSidebarWidth: 216,
            titlebarLeadingInset: 82
        )
        let visible = ContentView.customTitlebarLeadingPadding(
            isFullScreen: false,
            isSidebarVisible: true,
            sidebarWidth: 320,
            minimumSidebarWidth: 216,
            titlebarLeadingInset: 82
        )

        #expect(visible > hidden)
        #expect(visible == 332)
    }

    @Test func fullscreenHiddenSidebarKeepsCompactInset() {
        #expect(
            ContentView.customTitlebarLeadingPadding(
                isFullScreen: true,
                isSidebarVisible: false,
                sidebarWidth: 216,
                minimumSidebarWidth: 216,
                titlebarLeadingInset: 82
            ) == 8
        )
    }
}


@MainActor
final class FolderWindowMoveSuppressionTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    func testSuppressionTracksMovableWindowWithoutChangingMovability() {
        let window = makeWindow()
        window.isMovable = true

        let depth = beginWindowDragSuppression(window: window)

        XCTAssertEqual(depth, 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))
        XCTAssertTrue(window.isMovable)
    }

    func testSuppressionTracksImmovableWindowWithoutChangingMovability() {
        let window = makeWindow()
        window.isMovable = false

        let depth = beginWindowDragSuppression(window: window)

        XCTAssertEqual(depth, 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))
        XCTAssertFalse(window.isMovable)
    }

    func testEndingSuppressionDoesNotRestoreStaleMovability() {
        let window = makeWindow()
        window.isMovable = false

        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertFalse(window.isMovable)

        window.isMovable = true

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
        XCTAssertTrue(window.isMovable)
    }

    func testClearWindowDragSuppressionRemovesAllDepth() {
        let window = makeWindow()
        window.isMovable = false

        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(beginWindowDragSuppression(window: window), 2)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 2)

        XCTAssertEqual(clearWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(window.isMovable)
    }

    func testClearWindowDragSuppressionFinishesActiveMoveSequence() {
        let window = makeWindow()
        window.isMovable = true

        XCTAssertEqual(
            beginWindowMoveSuppressionSequence(window: window, reason: .bonsplitPaneTabDrag),
            .bonsplitPaneTabDrag
        )
        XCTAssertFalse(window.isMovable)
        XCTAssertEqual(activeWindowMoveSuppressionSequenceReason(window: window), .bonsplitPaneTabDrag)

        XCTAssertEqual(clearWindowDragSuppression(window: window), 0)

        XCTAssertNil(activeWindowMoveSuppressionSequenceReason(window: window))
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
        XCTAssertTrue(window.isMovable)
    }

    func testWindowDragSuppressionDepthLifecycle() {
        let window = makeWindow()
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))

        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
    }

    func testWindowDragSuppressionIsReferenceCounted() {
        let window = makeWindow()
        XCTAssertEqual(beginWindowDragSuppression(window: window), 1)
        XCTAssertEqual(beginWindowDragSuppression(window: window), 2)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 2)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 1)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 1)
        XCTAssertTrue(isWindowDragSuppressed(window: window))

        XCTAssertEqual(endWindowDragSuppression(window: window), 0)
        XCTAssertEqual(windowDragSuppressionDepth(window: window), 0)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
    }

    func testTemporaryWindowMovableEnableRestoresImmovableWindow() {
        let window = makeWindow()
        window.isMovable = false

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, false)
        XCTAssertFalse(window.isMovable)
    }

    func testTemporaryWindowMovableEnablePreservesMovableWindow() {
        let window = makeWindow()
        window.isMovable = true

        let previous = withTemporaryWindowMovableEnabled(window: window) {
            XCTAssertTrue(window.isMovable)
        }

        XCTAssertEqual(previous, true)
        XCTAssertTrue(window.isMovable)
    }
}


@MainActor
final class WindowMoveSuppressionHitPathTests: XCTestCase {
    private func makeWindowWithContentView() -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView
        return (window, contentView)
    }

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    func testSuppressionHitPathRecognizesFolderView() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(hitView: folderView))
    }

    func testSuppressionHitPathRecognizesDescendantOfFolderView() {
        let folderView = DraggableFolderNSView(directory: "/tmp")
        let child = NSView(frame: .zero)
        folderView.addSubview(child)
        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(hitView: child))
    }

    func testSuppressionHitPathIgnoresUnrelatedViews() {
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(hitView: NSView(frame: .zero)))
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(hitView: nil))
    }

    func testSuppressionEventPathRecognizesFolderHitInsideWindow() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let folderView = DraggableFolderNSView(directory: "/tmp")
        folderView.frame = NSRect(x: 10, y: 10, width: 16, height: 16)
        contentView.addSubview(folderView)

        let event = makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 14, y: 14), window: window)

        XCTAssertTrue(shouldSuppressWindowMoveForFolderDrag(window: window, event: event))
    }

    func testSuppressionEventPathRejectsNonFolderAndNonMouseDownEvents() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let plainView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        contentView.addSubview(plainView)

        let down = makeMouseEvent(type: .leftMouseDown, location: NSPoint(x: 20, y: 20), window: window)
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(window: window, event: down))

        let dragged = makeMouseEvent(type: .leftMouseDragged, location: NSPoint(x: 20, y: 20), window: window)
        XCTAssertFalse(shouldSuppressWindowMoveForFolderDrag(window: window, event: dragged))
    }

    func testBonsplitPaneTabMouseDownSuppressesWindowMove() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 20, y: 132, width: 240, height: 30))
        tabRegion.tabFrames = [CGRect(x: 8, y: 0, width: 96, height: 30)]
        contentView.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer { BonsplitTabItemHitRegionRegistry.unregister(tabRegion) }

        let tabPoint = tabRegion.convert(NSPoint(x: 28, y: 15), to: nil)
        let event = makeMouseEvent(type: .leftMouseDown, location: tabPoint, window: window)

        XCTAssertTrue(shouldSuppressWindowMoveForBonsplitPaneTabDrag(window: window, event: event))
        XCTAssertEqual(windowMoveSuppressionReason(window: window, event: event), .bonsplitPaneTabDrag)
    }

    func testBonsplitPaneTabDragSequenceKeepsWindowImmovableUntilMouseUp() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 20, y: 132, width: 240, height: 30))
        tabRegion.tabFrames = [CGRect(x: 8, y: 0, width: 96, height: 30)]
        contentView.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer {
            _ = finishWindowMoveSuppressionSequence(window: window)
            BonsplitTabItemHitRegionRegistry.unregister(tabRegion)
        }

        let tabPoint = tabRegion.convert(NSPoint(x: 28, y: 15), to: nil)
        let down = makeMouseEvent(type: .leftMouseDown, location: tabPoint, window: window)

        XCTAssertEqual(beginOrContinueWindowMoveSuppressionSequenceForEvent(window: window, event: down), .bonsplitPaneTabDrag)
        XCTAssertFalse(window.isMovable)
        XCTAssertTrue(isWindowDragSuppressed(window: window))
        XCTAssertEqual(activeWindowMoveSuppressionSequenceReason(window: window), .bonsplitPaneTabDrag)

        let draggedOutsideTab = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY),
            window: window
        )
        XCTAssertEqual(
            beginOrContinueWindowMoveSuppressionSequenceForEvent(window: window, event: draggedOutsideTab),
            .bonsplitPaneTabDrag
        )
        XCTAssertFalse(window.isMovable, "Window must remain immovable for the whole tab-drag mouse sequence")
        XCTAssertFalse(shouldFinishWindowMoveSuppressionSequenceAfterDispatch(window: window, event: draggedOutsideTab))

        let up = makeMouseEvent(type: .leftMouseUp, location: tabPoint, window: window)
        XCTAssertEqual(beginOrContinueWindowMoveSuppressionSequenceForEvent(window: window, event: up), .bonsplitPaneTabDrag)
        XCTAssertTrue(shouldFinishWindowMoveSuppressionSequenceAfterDispatch(window: window, event: up))
        XCTAssertEqual(finishWindowMoveSuppressionSequence(window: window), .bonsplitPaneTabDrag)
        XCTAssertTrue(window.isMovable)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
        XCTAssertNil(activeWindowMoveSuppressionSequenceReason(window: window))
    }

    func testBonsplitPaneTabSuppressionRestoresImmovableMainWindow() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = false
        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 20, y: 132, width: 240, height: 30))
        tabRegion.tabFrames = [CGRect(x: 8, y: 0, width: 96, height: 30)]
        contentView.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer {
            _ = finishWindowMoveSuppressionSequence(window: window)
            BonsplitTabItemHitRegionRegistry.unregister(tabRegion)
        }

        let tabPoint = tabRegion.convert(NSPoint(x: 28, y: 15), to: nil)
        let down = makeMouseEvent(type: .leftMouseDown, location: tabPoint, window: window)

        XCTAssertEqual(beginOrContinueWindowMoveSuppressionSequenceForEvent(window: window, event: down), .bonsplitPaneTabDrag)
        XCTAssertFalse(window.isMovable)
        XCTAssertEqual(finishWindowMoveSuppressionSequence(window: window), .bonsplitPaneTabDrag)
        XCTAssertFalse(
            window.isMovable,
            "Tab-drag suppression must not restore native AppKit window dragging when the main window baseline is immovable"
        )
    }

    func testNewMouseDownReevaluatesAfterStaleBonsplitPaneTabSuppression() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 20, y: 132, width: 240, height: 30))
        tabRegion.tabFrames = [CGRect(x: 8, y: 0, width: 96, height: 30)]
        contentView.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer {
            _ = finishWindowMoveSuppressionSequence(window: window)
            BonsplitTabItemHitRegionRegistry.unregister(tabRegion)
        }

        let tabPoint = tabRegion.convert(NSPoint(x: 28, y: 15), to: nil)
        let down = makeMouseEvent(type: .leftMouseDown, location: tabPoint, window: window)
        XCTAssertEqual(beginOrContinueWindowMoveSuppressionSequenceForEvent(window: window, event: down), .bonsplitPaneTabDrag)
        XCTAssertFalse(window.isMovable)

        let emptyChromePoint = tabRegion.convert(NSPoint(x: 180, y: 15), to: nil)
        let nextDown = makeMouseEvent(type: .leftMouseDown, location: emptyChromePoint, window: window)
        XCTAssertNil(
            beginOrContinueWindowMoveSuppressionSequenceForEvent(
                window: window,
                event: nextDown,
                pressedMouseButtons: 1
            ),
            "A fresh mouse-down must end stale tab suppression and re-check the actual hit target"
        )
        XCTAssertTrue(window.isMovable)
        XCTAssertFalse(isWindowDragSuppressed(window: window))
        XCTAssertNil(activeWindowMoveSuppressionSequenceReason(window: window))
    }

    func testBonsplitPaneTabSuppressionLeavesEmptyTabChromeDraggable() {
        let (window, contentView) = makeWindowWithContentView()
        window.isMovable = true
        let tabRegion = FakeBonsplitTabItemRegionView(frame: NSRect(x: 20, y: 132, width: 240, height: 30))
        tabRegion.tabFrames = [CGRect(x: 8, y: 0, width: 96, height: 30)]
        contentView.addSubview(tabRegion)
        BonsplitTabItemHitRegionRegistry.register(tabRegion)
        defer { BonsplitTabItemHitRegionRegistry.unregister(tabRegion) }

        let emptyChromePoint = tabRegion.convert(NSPoint(x: 180, y: 15), to: nil)
        let event = makeMouseEvent(type: .leftMouseDown, location: emptyChromePoint, window: window)

        XCTAssertFalse(shouldSuppressWindowMoveForBonsplitPaneTabDrag(window: window, event: event))
        XCTAssertNil(windowMoveSuppressionReason(window: window, event: event))
    }
}

private final class FilePreviewPDFChromeNotificationFlag: @unchecked Sendable {
    var didNotify = false
}


@MainActor
final class FilePreviewPDFChromeTests: XCTestCase {
    func testChromeHostsAcceptFirstMouse() {
        let host = FilePreviewPDFChromeHostingView(rootView: AnyView(EmptyView()))

        XCTAssertTrue(host.acceptsFirstMouse(for: nil))
    }

    #if DEBUG
    func testPDFChromeStyleVariantPersistsForDebugWindow() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.string(forKey: FilePreviewPDFChromeStyleVariant.defaultsKey)
        let notificationFlag = FilePreviewPDFChromeNotificationFlag()
        let observer = NotificationCenter.default.addObserver(
            forName: .filePreviewPDFChromeStyleDidChange,
            object: nil,
            queue: nil
        ) { _ in
            notificationFlag.didNotify = true
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            if let previousValue {
                defaults.set(previousValue, forKey: FilePreviewPDFChromeStyleVariant.defaultsKey)
            } else {
                defaults.removeObject(forKey: FilePreviewPDFChromeStyleVariant.defaultsKey)
            }
        }

        defaults.removeObject(forKey: FilePreviewPDFChromeStyleVariant.defaultsKey)
        XCTAssertEqual(FilePreviewPDFChromeStyleVariant.current(), .liquidGlass)

        FilePreviewPDFChromeStyleVariant.thinOutline.persist()
        XCTAssertEqual(FilePreviewPDFChromeStyleVariant.current(), .thinOutline)
        XCTAssertTrue(notificationFlag.didNotify)
    }
    #endif

    func testPDFChromeControlsUseSwiftUILiquidGlassHosts() throws {
        let container = FilePreviewPDFContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let mirror = Mirror(reflecting: container)
        let sidebarChromeHost = try XCTUnwrap(
            mirror.descendant("sidebarChromeHost") as? FilePreviewPDFChromeHostingView
        )
        let zoomChromeHost = try XCTUnwrap(
            mirror.descendant("zoomChromeHost") as? FilePreviewPDFChromeHostingView
        )
        let chromeHost = try XCTUnwrap(
            mirror.descendant("chromeHost") as? FilePreviewPDFChromeHostView
        )

        XCTAssertFalse(sidebarChromeHost.isHidden)
        XCTAssertFalse(zoomChromeHost.isHidden)
        XCTAssertEqual(chromeHost.interactiveOverlayViews.count, 2)
        XCTAssertTrue(chromeHost.interactiveOverlayViews.contains { $0 === sidebarChromeHost })
        XCTAssertTrue(chromeHost.interactiveOverlayViews.contains { $0 === zoomChromeHost })
    }

    func testPDFChromeControlsAreHitTestedAbovePDFContent() throws {
        let container = FilePreviewPDFContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let hostView = NSView(frame: container.frame)
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        hostView.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: hostView.topAnchor),
            container.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])
        window.layoutIfNeeded()
        hostView.needsLayout = true
        hostView.layoutSubtreeIfNeeded()
        container.needsLayout = true
        container.layout()
        container.layoutSubtreeIfNeeded()

        let mirror = Mirror(reflecting: container)
        let chromeHost = try XCTUnwrap(mirror.descendant("chromeHost") as? NSView)
        let sidebarChromeHost = try XCTUnwrap(mirror.descendant("sidebarChromeHost") as? NSView)
        let zoomChromeHost = try XCTUnwrap(mirror.descendant("zoomChromeHost") as? NSView)
        let contentHost = mirror.descendant("contentHost") as? NSView
        chromeHost.needsLayout = true
        chromeHost.layoutSubtreeIfNeeded()
        sidebarChromeHost.layoutSubtreeIfNeeded()
        zoomChromeHost.layoutSubtreeIfNeeded()

        let leftProbe = chromeHost.convert(
            NSPoint(x: sidebarChromeHost.frame.midX, y: sidebarChromeHost.frame.midY),
            to: container
        )
        let rightProbe = chromeHost.convert(
            NSPoint(x: zoomChromeHost.frame.midX, y: zoomChromeHost.frame.midY),
            to: container
        )
        let shareProbe = chromeHost.convert(
            NSPoint(x: zoomChromeHost.frame.maxX - 20, y: zoomChromeHost.frame.midY),
            to: container
        )
        let leftChromeHit = container.hitTest(leftProbe)
        let rightChromeHit = container.hitTest(rightProbe)
        let shareChromeHit = container.hitTest(shareProbe)
        let debugFrames = "container=\(container.frame) content=\(String(describing: contentHost?.frame)) chromeHost=\(chromeHost.frame) left=\(sidebarChromeHost.frame) right=\(zoomChromeHost.frame) leftProbe=\(leftProbe) rightProbe=\(rightProbe) shareProbe=\(shareProbe) leftHit=\(String(describing: leftChromeHit)) rightHit=\(String(describing: rightChromeHit)) shareHit=\(String(describing: shareChromeHit))"

        XCTAssertTrue(isView(leftChromeHit, inside: sidebarChromeHost), debugFrames)
        XCTAssertTrue(isView(rightChromeHit, inside: zoomChromeHost), debugFrames)
        XCTAssertTrue(isView(shareChromeHit, inside: zoomChromeHost), debugFrames)
    }

    func testThumbnailSidebarUsesFullWidthSingleColumnLayout() throws {
        let sidebar = FilePreviewPDFThumbnailSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))

        sidebar.layoutSubtreeIfNeeded()

        let mirror = Mirror(reflecting: sidebar)
        let collectionView = try XCTUnwrap(
            mirror.descendant("collectionView") as? NSCollectionView
        )
        let flowLayout = try XCTUnwrap(
            mirror.descendant("flowLayout") as? NSCollectionViewFlowLayout
        )
        let itemSize = sidebar.collectionView(
            collectionView,
            layout: flowLayout,
            sizeForItemAt: IndexPath(item: 0, section: 0)
        )

        XCTAssertGreaterThanOrEqual(itemSize.width, sidebar.bounds.width)
        XCTAssertGreaterThan(itemSize.width, sidebar.bounds.width / 2)
    }

    func testThumbnailSidebarPreferredWidthShrinksToPortraitContent() throws {
        let document = try makePDFDocument(pageSizes: [NSSize(width: 80, height: 160)])

        let width = FilePreviewPDFSizing.preferredThumbnailSidebarWidth(for: document)

        XCTAssertEqual(width, FilePreviewPDFSizing.minimumThumbnailSidebarWidth, accuracy: 0.001)
    }

    func testThumbnailSidebarPreferredWidthUsesThumbnailMinimumWithoutDocument() {
        let width = FilePreviewPDFSizing.preferredThumbnailSidebarWidth(for: nil)

        XCTAssertEqual(width, FilePreviewPDFSizing.minimumThumbnailSidebarWidth, accuracy: 0.001)
    }

    func testThumbnailSidebarPreferredWidthExpandsForLandscapeContent() throws {
        let document = try makePDFDocument(pageSizes: [NSSize(width: 160, height: 90)])

        let width = FilePreviewPDFSizing.preferredThumbnailSidebarWidth(for: document)

        XCTAssertGreaterThan(width, 200)
        XCTAssertLessThan(width, FilePreviewPDFSizing.maximumSidebarWidth)
    }

    func testSidebarWidthClampReservesMinimumContentWidth() {
        let width = FilePreviewPDFSizing.clampedSidebarWidth(
            240,
            containerWidth: FilePreviewPDFSizing.minimumSidebarWidth
                + FilePreviewPDFSizing.minimumContentWidth
                - 40,
            dividerThickness: 1
        )

        XCTAssertEqual(width, FilePreviewPDFSizing.minimumSidebarWidth, accuracy: 0.001)
    }

    func testThumbnailSidebarKeepsSingleSelectionWhenProgrammaticallyChangingPage() throws {
        let sidebar = FilePreviewPDFThumbnailSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let document = try makePDFDocument(pageCount: 5)

        sidebar.setDocument(document)
        sidebar.selectPage(at: 1, scrollToVisible: false)
        sidebar.selectPage(at: 3, scrollToVisible: false)

        let mirror = Mirror(reflecting: sidebar)
        let collectionView = try XCTUnwrap(
            mirror.descendant("collectionView") as? NSCollectionView
        )

        let previousItem = sidebar.collectionView(
            collectionView,
            itemForRepresentedObjectAt: IndexPath(item: 1, section: 0)
        )
        let currentItem = sidebar.collectionView(
            collectionView,
            itemForRepresentedObjectAt: IndexPath(item: 3, section: 0)
        )

        XCTAssertFalse(try thumbnailItemSelectedState(previousItem))
        XCTAssertTrue(try thumbnailItemSelectedState(currentItem))
    }

    func testPDFViewportOriginUsesVisibleClipWidth() {
        let origin = FilePreviewViewport.clampedClipOrigin(
            documentPoint: CGPoint(x: 500, y: 700),
            anchorOffsetInClip: CGPoint(x: 200, y: 300),
            documentBounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_400),
            clipSize: CGSize(width: 400, height: 600)
        )

        XCTAssertEqual(origin.x, 300, accuracy: 0.001)
        XCTAssertEqual(origin.y, 400, accuracy: 0.001)
    }

    func testPDFViewportOriginCentersSmallerDocuments() {
        let origin = FilePreviewViewport.clampedClipOrigin(
            documentPoint: CGPoint(x: 54, y: 224.5),
            anchorOffsetInClip: CGPoint(x: 300, y: 400),
            documentBounds: CGRect(x: 0, y: 0, width: 108, height: 449),
            clipSize: CGSize(width: 600, height: 800)
        )

        XCTAssertEqual(origin.x, -246, accuracy: 0.001)
        XCTAssertEqual(origin.y, -175.5, accuracy: 0.001)
    }

    private func isView(_ view: NSView?, inside container: NSView) -> Bool {
        var current = view
        while let next = current {
            if next === container {
                return true
            }
            current = next.superview
        }
        return false
    }

    private func makePDFDocument(pageCount: Int) throws -> PDFDocument {
        try makePDFDocument(pageSizes: Array(repeating: NSSize(width: 80, height: 80), count: pageCount))
    }

    private func makePDFDocument(pageSizes: [NSSize]) throws -> PDFDocument {
        let document = PDFDocument()
        for (pageIndex, pageSize) in pageSizes.enumerated() {
            let image = NSImage(size: pageSize)
            image.lockFocus()
            NSColor(
                calibratedHue: CGFloat(pageIndex) / CGFloat(max(pageSizes.count, 1)),
                saturation: 0.5,
                brightness: 0.8,
                alpha: 1
            ).setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: pageSize)).fill()
            image.unlockFocus()
            let page = try XCTUnwrap(PDFPage(image: image))
            document.insert(page, at: pageIndex)
        }
        return document
    }

    private func thumbnailItemSelectedState(_ item: NSCollectionViewItem) throws -> Bool {
        try XCTUnwrap(Mirror(reflecting: item.view).descendant("isSelectedForPreview") as? Bool)
    }
}

private final class FilePreviewFocusTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}

@MainActor
final class FilePreviewFocusCoordinatorTests: XCTestCase {
    func testPDFKeyboardRoutingUsesFocusedRegion() {
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_UpArrow),
                modifiers: [],
                region: .pdfThumbnails
            ),
            .navigatePage(-1)
        )
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_DownArrow),
                modifiers: [],
                region: .pdfThumbnails
            ),
            .navigatePage(1)
        )
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_UpArrow),
                modifiers: [],
                region: .pdfCanvas
            ),
            .native
        )
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_DownArrow),
                modifiers: [],
                region: .pdfOutline
            ),
            .native
        )
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_PageDown),
                modifiers: .command,
                region: .pdfThumbnails
            ),
            .native
        )
    }

    func testCoordinatorResolvesMostSpecificRegisteredSubregion() {
        let root = FilePreviewFocusTestView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let thumbnailHost = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 240))
        let thumbnailResponder = FilePreviewFocusTestView(frame: thumbnailHost.bounds)
        thumbnailHost.addSubview(thumbnailResponder)
        root.addSubview(thumbnailHost)

        let coordinator = FilePreviewFocusCoordinator(preferredIntent: .pdfCanvas)
        coordinator.register(root: root, primaryResponder: root, intent: .pdfCanvas)
        coordinator.register(
            root: thumbnailHost,
            primaryResponder: thumbnailResponder,
            intent: .pdfThumbnails
        )

        XCTAssertEqual(coordinator.ownedIntent(for: root), .pdfCanvas)
        XCTAssertEqual(coordinator.ownedIntent(for: thumbnailResponder), .pdfThumbnails)
        XCTAssertTrue(coordinator.endpoint(for: .pdfThumbnails) === thumbnailResponder)
        coordinator.notePreferredIntent(.pdfThumbnails)
        XCTAssertEqual(coordinator.preferredIntent, .pdfThumbnails)
    }
}


final class FilePreviewDragPasteboardWriterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FilePreviewDragRegistry.shared.discardAll()
        NSPasteboard(name: .drag).clearContents()
    }

    override func tearDown() {
        NSPasteboard(name: .drag).clearContents()
        FilePreviewDragRegistry.shared.discardAll()
        super.tearDown()
    }

    func testRegistrationIsPreparedWhenDragTypesAreRequested() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/example.txt").standardizedFileURL
        let writer = FilePreviewDragPasteboardWriter(
            filePath: fileURL.path,
            displayTitle: "example.txt"
        )
        let dragPasteboard = NSPasteboard(name: .drag)

        XCTAssertNil(FilePreviewDragPasteboardWriter.dragID(from: dragPasteboard))
        let writableTypes = writer.writableTypes(for: dragPasteboard)
        XCTAssertTrue(writableTypes.contains(.fileURL))
        let preparedDragID = try XCTUnwrap(FilePreviewDragPasteboardWriter.dragID(from: dragPasteboard))
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: preparedDragID))
        XCTAssertEqual(
            writer.pasteboardPropertyList(forType: .fileURL) as? String,
            fileURL.absoluteString
        )

        let filePreviewData = try XCTUnwrap(
            writer.pasteboardPropertyList(forType: DragOverlayRoutingPolicy.filePreviewTransferType) as? Data
        )
        let dragID = try XCTUnwrap(FilePreviewDragPasteboardWriter.dragID(from: filePreviewData))
        XCTAssertEqual(dragID, preparedDragID)
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: dragID))

        let bonsplitData = try XCTUnwrap(
            writer.pasteboardPropertyList(forType: FilePreviewDragPasteboardWriter.bonsplitTransferType) as? Data
        )
        XCTAssertEqual(FilePreviewDragPasteboardWriter.dragID(from: bonsplitData), dragID)
        XCTAssertEqual(dragPasteboard.data(forType: DragOverlayRoutingPolicy.filePreviewTransferType), filePreviewData)
        XCTAssertEqual(dragPasteboard.data(forType: FilePreviewDragPasteboardWriter.bonsplitTransferType), filePreviewData)
        XCTAssertEqual(dragPasteboard.string(forType: .fileURL), fileURL.absoluteString)

        FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: dragPasteboard)

        XCTAssertFalse(FilePreviewDragRegistry.shared.contains(id: dragID))
    }

    func testRegistrySweepsExpiredDragEntries() {
        let start = Date(timeIntervalSince1970: 1_000)
        let oldID = FilePreviewDragRegistry.shared.register(
            FilePreviewDragEntry(filePath: "/tmp/old.txt", displayTitle: "old.txt"),
            now: start
        )
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: oldID, now: start.addingTimeInterval(30)))

        let newID = FilePreviewDragRegistry.shared.register(
            FilePreviewDragEntry(filePath: "/tmp/new.txt", displayTitle: "new.txt"),
            now: start.addingTimeInterval(61)
        )

        XCTAssertFalse(FilePreviewDragRegistry.shared.contains(id: oldID, now: start.addingTimeInterval(61)))
        XCTAssertTrue(FilePreviewDragRegistry.shared.contains(id: newID, now: start.addingTimeInterval(61)))
    }
}


@MainActor
final class FilePreviewPanelTextSavingTests: XCTestCase {
    func testNativePreviewSessionsDetachAndManageViewsAcrossRecreation() throws {
        let url = try temporaryTextFile(contents: "preview", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        let sessions = panel.nativeViewSessions

        let pdfView = sessions.pdf.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )
        let imageView = sessions.image.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )
        let mediaView = sessions.media.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )
        let quickLookView = sessions.quickLook.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )

        let host = NSView()
        host.addSubview(pdfView)
        host.addSubview(imageView)
        host.addSubview(mediaView)
        host.addSubview(quickLookView)

        XCTAssertTrue(pdfView === sessions.pdf.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        ))
        XCTAssertNil(pdfView.superview)

        XCTAssertTrue(imageView === sessions.image.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        ))
        XCTAssertNil(imageView.superview)

        XCTAssertTrue(mediaView === sessions.media.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        ))
        XCTAssertNil(mediaView.superview)

        let remountedQuickLookView = sessions.quickLook.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: NSColor.textBackgroundColor,
            drawsBackground: true
        )
        XCTAssertFalse(quickLookView === remountedQuickLookView)
        XCTAssertTrue(quickLookView.superview === host)
        sessions.quickLook.dismantle(quickLookView)
        XCTAssertNil(quickLookView.superview)
    }

    func testSaveTextContentWritesLiveTextViewContent() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        let textView = NSTextView()
        textView.string = "edited from text view"
        panel.attachTextView(textView)

        let task = try XCTUnwrap(panel.saveTextContent())
        XCTAssertTrue(panel.isSaving)
        await task.value

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "edited from text view")
        XCTAssertEqual(panel.textContent, "edited from text view")
        XCTAssertFalse(panel.isDirty)
        XCTAssertFalse(panel.isSaving)
    }

    func testSaveTextContentIgnoresConcurrentSaveRequest() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("first save")

        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)

        let firstSave = try XCTUnwrap(panel.saveTextContent())
        XCTAssertTrue(panel.isSaving)

        panel.updateTextContent("second save")
        XCTAssertNil(panel.saveTextContent())

        let pipeRead = Task.detached { () throws -> String in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return String(data: handle.availableData, encoding: .utf8) ?? ""
        }

        let savedContent = try await pipeRead.value
        XCTAssertEqual(savedContent, "first save")
        await firstSave.value

        XCTAssertEqual(panel.textContent, "second save")
        XCTAssertTrue(panel.isDirty)
        XCTAssertFalse(panel.isSaving)
    }

    func testCleanSaveDoesNotCancelPendingTextLoad() async throws {
        let url = try temporaryTextFile(contents: "", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        try "loaded after clean save".write(to: url, atomically: true, encoding: .utf8)

        let loadTask = panel.loadTextContent()
        XCTAssertNil(panel.saveTextContent())
        await loadTask.value

        XCTAssertEqual(panel.textContent, "loaded after clean save")
        XCTAssertFalse(panel.isDirty)
        XCTAssertFalse(panel.isFileUnavailable)
    }

    func testSavingTextViewUsesConfiguredSaveShortcut() async throws {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "u", command: true, shift: false, option: true, control: false),
            for: .saveFilePreview
        )

        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        let textView = SavingTextView()
        textView.string = "saved by configured shortcut"
        textView.panel = panel
        panel.attachTextView(textView)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "u",
            charactersIgnoringModifiers: "u",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_U)
        ))

        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        await waitForPanelSave(panel)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved by configured shortcut")
    }

    func testSavingTextViewDoesNotUseDefaultSaveShortcutAfterRemap() async throws {
        KeyboardShortcutSettings.resetAll()
        defer { KeyboardShortcutSettings.resetAll() }

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "u", command: true, shift: false, option: true, control: false),
            for: .saveFilePreview
        )

        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value

        let textView = SavingTextView()
        textView.string = "should not save through command s"
        textView.panel = panel
        panel.attachTextView(textView)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "s",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_S)
        ))

        XCTAssertFalse(textView.performKeyEquivalent(with: event))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }

    func testSaveTextContentPreservesLoadedEncoding() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf16)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("edited")
        if let task = panel.saveTextContent() {
            await task.value
        }

        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data, encoding: .utf16), "edited")
        XCTAssertFalse(panel.isDirty)
    }

    func testSaveTextContentWritesThroughSymlink() async throws {
        let targetURL = try temporaryTextFile(contents: "original", encoding: .utf8)
        let linkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: linkURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: linkURL.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("edited through link")
        if let task = panel.saveTextContent() {
            await task.value
        }

        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "edited through link")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), targetURL.path)
        XCTAssertFalse(panel.isDirty)
    }

    func testCleanSaveDoesNotWriteReadOnlyTextFile() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        if let task = panel.saveTextContent() {
            await task.value
        }

        XCTAssertFalse(panel.isDirty)
        XCTAssertFalse(panel.isFileUnavailable)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }

    func testLoadTextContentClearsDirtyStateWhenFileVanishes() async throws {
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("edited")
        try FileManager.default.removeItem(at: url)

        await panel.loadTextContent().value

        XCTAssertEqual(panel.textContent, "")
        XCTAssertFalse(panel.isDirty)
        XCTAssertTrue(panel.isFileUnavailable)
    }

    func testTextEditorInsetsReapplyWhenMovedBetweenWindows() {
        _ = NSApplication.shared
        let textView = SavingTextView()
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5

        let firstWindow = windowHosting(textView)
        defer { closeWindow(firstWindow) }
        XCTAssertEqual(textView.textContainerInset.width, FilePreviewTextEditorLayout.textContainerInset.width)
        XCTAssertEqual(textView.textContainerInset.height, FilePreviewTextEditorLayout.textContainerInset.height)
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, FilePreviewTextEditorLayout.lineFragmentPadding)

        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5

        let secondWindow = windowHosting(textView)
        defer { closeWindow(secondWindow) }
        XCTAssertEqual(textView.textContainerInset.width, FilePreviewTextEditorLayout.textContainerInset.width)
        XCTAssertEqual(textView.textContainerInset.height, FilePreviewTextEditorLayout.textContainerInset.height)
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, FilePreviewTextEditorLayout.lineFragmentPadding)

        withExtendedLifetime([firstWindow, secondWindow]) {}
    }

    func testTextEditorClearThemeDoesNotDrawAppKitBackgrounds() {
        _ = NSApplication.shared
        let scrollView = NSScrollView()
        let textView = SavingTextView()
        scrollView.documentView = textView

        FilePreviewTextEditor<FilePreviewPanel>.applyTheme(
            to: scrollView,
            backgroundColor: .clear,
            foregroundColor: .white,
            drawsBackground: false
        )

        XCTAssertFalse(scrollView.drawsBackground)
        XCTAssertFalse(scrollView.contentView.drawsBackground)
        XCTAssertFalse(textView.drawsBackground)
        XCTAssertEqual(scrollView.backgroundColor.alphaComponent, 0)
        XCTAssertEqual(scrollView.contentView.backgroundColor.alphaComponent, 0)
        XCTAssertEqual(textView.backgroundColor.alphaComponent, 0)
        XCTAssertEqual(textView.textColor, .white)
        XCTAssertEqual(textView.insertionPointColor, .white)
    }

    func testTextEditorOpaqueThemeDrawsAppKitBackgrounds() {
        _ = NSApplication.shared
        let scrollView = NSScrollView()
        let textView = SavingTextView()
        let backgroundColor = NSColor(srgbRed: 0.12, green: 0.14, blue: 0.16, alpha: 1)
        scrollView.documentView = textView

        FilePreviewTextEditor<FilePreviewPanel>.applyTheme(
            to: scrollView,
            backgroundColor: backgroundColor,
            foregroundColor: .white,
            drawsBackground: true
        )

        XCTAssertTrue(scrollView.drawsBackground)
        XCTAssertTrue(scrollView.contentView.drawsBackground)
        XCTAssertTrue(textView.drawsBackground)
        XCTAssertEqual(scrollView.backgroundColor, backgroundColor)
        XCTAssertEqual(scrollView.contentView.backgroundColor, backgroundColor)
        XCTAssertEqual(textView.backgroundColor, backgroundColor)
        XCTAssertEqual(scrollView.backgroundColor.alphaComponent, 1)
        XCTAssertEqual(scrollView.contentView.backgroundColor.alphaComponent, 1)
        XCTAssertEqual(textView.backgroundColor.alphaComponent, 1)
    }

    func testPendingTextFocusAppliesWhenTextViewAttaches() throws {
        _ = NSApplication.shared
        let url = try temporaryTextFile(contents: "original", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        panel.focus()

        let textView = SavingTextView()
        let window = windowHosting(textView)
        defer { closeWindow(window) }
        panel.attachTextView(textView)

        XCTAssertTrue(window.firstResponder === textView)
        withExtendedLifetime(window) {}
    }

    func testPDFExtensionWinsOverLooseTextSniff() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n".utf8).write(to: url)

        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .pdf)
        XCTAssertEqual(FilePreviewKindResolver.tabIconName(for: url), "doc.richtext")
    }

    func testUTF16TextWithBOMStillResolvesAsText() throws {
        let url = try temporaryTextFile(contents: "hello", encoding: .utf16)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .text)
        XCTAssertEqual(FilePreviewKindResolver.tabIconName(for: url), "doc.text")
    }

    func testExtensionlessTextFileResolvesToTextAfterFastInitialClassification() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try "extensionless text".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .quickLook)
        XCTAssertEqual(FilePreviewKindResolver.mode(for: url), .text)

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: url.path)
        defer { panel.close() }
        await waitForPanelPreviewMode(panel, .text)
        await waitForPanelTextContent(panel, "extensionless text")

        XCTAssertEqual(panel.displayIcon, "doc.text")
    }

    func testBinaryPlistDoesNotOpenAsEditableText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("bplist00".utf8).write(to: url)

        XCTAssertEqual(FilePreviewKindResolver.initialMode(for: url), .quickLook)
        XCTAssertNotEqual(FilePreviewKindResolver.mode(for: url), .text)
    }

    func testExternalOpenApplicationResolverOrdersDefaultAppFirstAndDeduplicates() {
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-sample.mov")
        let quickTimeURL = URL(fileURLWithPath: "/Applications/QuickTime Player.app")
        let vlcURL = URL(fileURLWithPath: "/Applications/VLC.app")
        let names = [
            quickTimeURL.path: "QuickTime Player",
            vlcURL.path: "VLC",
        ]
        let resolver = FileExternalOpenApplicationResolver(
            defaultApplicationURL: { _ in quickTimeURL },
            applicationURLs: { _ in [vlcURL, quickTimeURL, vlcURL] },
            displayName: { names[$0.path] ?? $0.lastPathComponent },
            shouldIncludeApplication: { _ in true }
        )

        let applications = resolver.applications(for: fileURL)

        XCTAssertEqual(applications.map(\.displayName), ["QuickTime Player", "VLC"])
        XCTAssertEqual(applications.map(\.isDefault), [true, false])
    }

    func testExternalOpenApplicationResolverFallsBackWhenDefaultAppIsFiltered() {
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-sample.pdf")
        let cmuxURL = URL(fileURLWithPath: "/Applications/cmux.app")
        let previewURL = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let resolver = FileExternalOpenApplicationResolver(
            defaultApplicationURL: { _ in cmuxURL },
            applicationURLs: { _ in [cmuxURL, previewURL] },
            displayName: { $0.deletingPathExtension().lastPathComponent },
            shouldIncludeApplication: { $0 != cmuxURL }
        )

        let applications = resolver.applications(for: fileURL)

        XCTAssertEqual(applications.map(\.displayName), ["Preview"])
        XCTAssertEqual(applications.map(\.isDefault), [false])
    }

    func testExternalOpenMenuKeepsFinderTopLevelAndOpenWithItemsSearchableByAppName() throws {
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-sample.png")
        let previewURL = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let pixelmatorURL = URL(fileURLWithPath: "/Applications/Pixelmator Pro.app")
        let primaryApplication = FileExternalOpenApplication(
            url: previewURL,
            displayName: "Preview",
            isDefault: true
        )
        let otherApplication = FileExternalOpenApplication(
            url: pixelmatorURL,
            displayName: "Pixelmator Pro",
            isDefault: false
        )

        let menu = FileExternalOpenMenuFactory.makeMenu(
            fileURL: fileURL,
            primaryApplication: primaryApplication,
            otherApplications: [otherApplication]
        )

        let topLevelTitles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(topLevelTitles, [
            FileExternalOpenText.openInApplication("Preview"),
            FileExternalOpenText.revealInFinder,
            FileExternalOpenText.openWithMenu,
        ])

        let openWithItem = try XCTUnwrap(menu.items.first { $0.title == FileExternalOpenText.openWithMenu })
        let openWithTitles = try XCTUnwrap(openWithItem.submenu?.items.map(\.title))
        XCTAssertEqual(openWithTitles, ["Pixelmator Pro"])
    }

    func testExternalOpenMenuKeepsFinderTopLevelWithoutResolvedApplications() {
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-sample.bin")

        let menu = FileExternalOpenMenuFactory.makeMenu(
            fileURL: fileURL,
            primaryApplication: nil,
            otherApplications: []
        )

        let topLevelTitles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(topLevelTitles, [
            FileExternalOpenText.openExternally,
            FileExternalOpenText.revealInFinder,
        ])
    }

    func testCmdClickSupportedFileRoutingDefaultsToReadableRegularFilesOnly() throws {
        let suiteName = "cmux.file-preview-routing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = try temporaryTextFile(contents: "preview me", encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        XCTAssertTrue(CmdClickSupportedFileRouteSettings.isEnabled(defaults: defaults))
        XCTAssertTrue(CmdClickSupportedFileRouteSettings.shouldRoute(path: fileURL.path, defaults: defaults))
        XCTAssertFalse(CmdClickSupportedFileRouteSettings.shouldRoute(path: directoryURL.path, defaults: defaults))

        defaults.set(false, forKey: CmdClickSupportedFileRouteSettings.key)
        XCTAssertFalse(CmdClickSupportedFileRouteSettings.shouldRoute(path: fileURL.path, defaults: defaults))
    }

    func testCmdClickMarkdownRoutingDoesNotRequireSupportedFileRoutingSetting() throws {
        let suiteName = "cmux.markdown-preview-routing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = try temporaryTextFile(contents: "# preview me", encoding: .utf8, pathExtension: "md")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        defaults.set(true, forKey: CmdClickMarkdownRouteSettings.key)
        defaults.set(false, forKey: CmdClickSupportedFileRouteSettings.key)

        XCTAssertTrue(CmdClickMarkdownRouteSettings.shouldRoute(path: fileURL.path, defaults: defaults))
        XCTAssertFalse(CmdClickSupportedFileRouteSettings.shouldRoute(path: fileURL.path, defaults: defaults))
    }

    func testCmdClickMarkdownRoutingDefaultsToReadableMarkdownFiles() throws {
        let suiteName = "cmux.markdown-preview-default-routing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileURL = try temporaryTextFile(contents: "# preview me", encoding: .utf8, pathExtension: "md")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertTrue(CmdClickMarkdownRouteSettings.isEnabled(defaults: defaults))
        XCTAssertTrue(CmdClickMarkdownRouteSettings.shouldRoute(path: fileURL.path, defaults: defaults))
    }

    func testCmdClickFilePreviewRoutingReusesRightSidePane() throws {
        let sourceURL = try temporaryTextFile(contents: "source", encoding: .utf8)
        let firstURL = try temporaryTextFile(contents: "first", encoding: .utf8)
        let secondURL = try temporaryTextFile(contents: "second", encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }

        let sourcePane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let sourcePanel = try XCTUnwrap(workspace.newFilePreviewSurface(
            inPane: sourcePane,
            filePath: sourceURL.path,
            focus: true
        ))

        let firstPanel = try XCTUnwrap(workspace.openOrFocusFilePreviewSplit(
            from: sourcePanel.id,
            filePath: firstURL.path
        ))
        let rightPane = try XCTUnwrap(workspace.paneId(forPanelId: firstPanel.id))
        let paneCountAfterFirstOpen = workspace.bonsplitController.allPaneIds.count
        let rightTabsAfterFirstOpen = workspace.bonsplitController.tabs(inPane: rightPane).count

        let secondPanel = try XCTUnwrap(workspace.openOrFocusFilePreviewSplit(
            from: sourcePanel.id,
            filePath: secondURL.path
        ))

        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, paneCountAfterFirstOpen)
        XCTAssertEqual(workspace.paneId(forPanelId: secondPanel.id)?.id, rightPane.id)
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: rightPane).count, rightTabsAfterFirstOpen + 1)
    }

    func testCmdClickMarkdownRoutingReusesRightSidePane() throws {
        let sourceURL = try temporaryTextFile(contents: "source", encoding: .utf8)
        let firstURL = try temporaryTextFile(contents: "# first", encoding: .utf8, pathExtension: "md")
        let secondURL = try temporaryTextFile(contents: "# second", encoding: .utf8, pathExtension: "md")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }

        let sourcePane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let sourcePanel = try XCTUnwrap(workspace.newFilePreviewSurface(
            inPane: sourcePane,
            filePath: sourceURL.path,
            focus: true
        ))

        let firstPanel = try XCTUnwrap(workspace.openOrFocusMarkdownSplit(
            from: sourcePanel.id,
            filePath: firstURL.path
        ))
        let rightPane = try XCTUnwrap(workspace.paneId(forPanelId: firstPanel.id))
        let paneCountAfterFirstOpen = workspace.bonsplitController.allPaneIds.count
        let rightTabsAfterFirstOpen = workspace.bonsplitController.tabs(inPane: rightPane).count

        let secondPanel = try XCTUnwrap(workspace.openOrFocusMarkdownSplit(
            from: sourcePanel.id,
            filePath: secondURL.path
        ))

        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, paneCountAfterFirstOpen)
        XCTAssertEqual(workspace.paneId(forPanelId: secondPanel.id)?.id, rightPane.id)
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: rightPane).count, rightTabsAfterFirstOpen + 1)
    }

    private func temporaryTextFile(
        contents: String,
        encoding: String.Encoding,
        pathExtension: String = "txt"
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        try contents.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    private func waitForPanelSave(
        _ panel: FilePreviewPanel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if !panel.isSaving {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for file preview save", file: file, line: line)
    }

    private func waitForPanelPreviewMode(
        _ panel: FilePreviewPanel,
        _ mode: FilePreviewMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if panel.previewMode == mode {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for file preview mode", file: file, line: line)
    }

    private func waitForPanelTextContent(
        _ panel: FilePreviewPanel,
        _ content: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1000 {
            if panel.textContent == content {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for file preview text content", file: file, line: line)
    }

    private func closeWindow(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func windowHosting(_ textView: NSTextView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(scrollView)
        scrollView.documentView = textView
        return window
    }
}


final class BonsplitTabDragPayloadTests: XCTestCase {
    func testRejectsFilePreviewCompatibilityPayload() throws {
        let pasteboard = try makeBonsplitPayloadPasteboard(kind: "filePreview", includesFilePreviewTransferType: true)

        XCTAssertNil(
            BonsplitTabDragPayload.transfer(from: pasteboard),
            "Sidebar workspace drop targets should ignore file-preview drags instead of treating them as movable tabs"
        )
    }

    func testAcceptsRealFilePreviewTabPayload() throws {
        let pasteboard = try makeBonsplitPayloadPasteboard(kind: "filePreview")

        XCTAssertNotNil(
            BonsplitTabDragPayload.transfer(from: pasteboard),
            "Existing file-preview tabs should still move through normal Bonsplit tab drag paths"
        )
    }

    func testAcceptsRegularCurrentProcessTabPayload() throws {
        let pasteboard = try makeBonsplitPayloadPasteboard(kind: nil)

        XCTAssertNotNil(BonsplitTabDragPayload.transfer(from: pasteboard))
    }

    func testWorkspaceDropRoutingAcceptsTabTransferTypeOnly() {
        XCTAssertTrue(
            BonsplitTabDragPayload.canRouteWorkspaceDrop(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType]
            )
        )
    }

    func testWorkspaceDropRoutingRejectsFilePreviewCompatibilityTransfer() {
        XCTAssertFalse(
            BonsplitTabDragPayload.canRouteWorkspaceDrop(
                pasteboardTypes: [
                    DragOverlayRoutingPolicy.filePreviewTransferType,
                    DragOverlayRoutingPolicy.bonsplitTabTransferType,
                ]
            )
        )
    }

    private func makeBonsplitPayloadPasteboard(
        kind: String?,
        includesFilePreviewTransferType: Bool = false
    ) throws -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.bonsplit.\(UUID().uuidString)"))
        pasteboard.clearContents()

        var tab: [String: Any] = ["id": UUID().uuidString]
        if let kind {
            tab["kind"] = kind
        }
        let payload: [String: Any] = [
            "tab": tab,
            "sourcePaneId": UUID().uuidString,
            "sourceProcessId": Int(ProcessInfo.processInfo.processIdentifier)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(BonsplitTabDragPayload.typeIdentifier))
        if includesFilePreviewTransferType {
            pasteboard.setData(data, forType: DragOverlayRoutingPolicy.filePreviewTransferType)
        }
        return pasteboard
    }
}

@MainActor
final class TmuxWorkspacePaneOverlayTests: XCTestCase {
    func testTmuxWorkspacePaneOverlayModelTracksFlashReason() {
        let model = TmuxWorkspacePaneOverlayModel()
        let initialState = TmuxWorkspacePaneOverlayRenderState(
            workspaceId: UUID(),
            unreadRects: [],
            flashRect: CGRect(x: 10, y: 20, width: 300, height: 200),
            flashToken: 1,
            flashReason: .notificationArrival
        )
        let laterState = TmuxWorkspacePaneOverlayRenderState(
            workspaceId: initialState.workspaceId,
            unreadRects: [],
            flashRect: CGRect(x: 10, y: 20, width: 300, height: 200),
            flashToken: 2,
            flashReason: .navigation
        )

        model.apply(initialState)
        model.apply(laterState)

        XCTAssertEqual(model.flashReason, .navigation)
    }

    func testTmuxWorkspacePaneOverlayModelAnimatesFlashAfterWorkspaceSwitchBackWhenTokenChanges() {
        let model = TmuxWorkspacePaneOverlayModel()
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()
        let firstFlashRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let flashDate = Date(timeIntervalSince1970: 42)

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: firstWorkspaceId,
            unreadRects: [firstFlashRect],
            flashRect: firstFlashRect,
            flashToken: 0,
            flashReason: nil
        ))
        XCTAssertNil(model.flashStartedAt)

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: secondWorkspaceId,
            unreadRects: [],
            flashRect: nil,
            flashToken: 0,
            flashReason: nil
        ))
        XCTAssertNil(model.flashStartedAt)

        model.apply(
            TmuxWorkspacePaneOverlayRenderState(
                workspaceId: firstWorkspaceId,
                unreadRects: [],
                flashRect: firstFlashRect,
                flashToken: 1,
                flashReason: .unreadIndicatorDismiss
            ),
            now: { flashDate }
        )

        XCTAssertEqual(model.flashStartedAt, flashDate)
        XCTAssertEqual(model.flashReason, .unreadIndicatorDismiss)
    }

    func testTmuxWorkspacePaneOverlayModelWaitsForFlashRectBeforeConsumingToken() {
        let model = TmuxWorkspacePaneOverlayModel()
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()
        let firstFlashRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let flashDate = Date(timeIntervalSince1970: 42)

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: firstWorkspaceId,
            unreadRects: [],
            flashRect: firstFlashRect,
            flashToken: 0,
            flashReason: nil
        ))
        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: secondWorkspaceId,
            unreadRects: [],
            flashRect: nil,
            flashToken: 0,
            flashReason: nil
        ))

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: firstWorkspaceId,
            unreadRects: [],
            flashRect: nil,
            flashToken: 1,
            flashReason: .unreadIndicatorDismiss
        ))
        XCTAssertNil(model.flashStartedAt)

        model.apply(
            TmuxWorkspacePaneOverlayRenderState(
                workspaceId: firstWorkspaceId,
                unreadRects: [],
                flashRect: firstFlashRect,
                flashToken: 1,
                flashReason: .unreadIndicatorDismiss
            ),
            now: { flashDate }
        )

        XCTAssertEqual(model.flashStartedAt, flashDate)
        XCTAssertEqual(model.flashReason, .unreadIndicatorDismiss)
    }

    func testTmuxWorkspacePaneOverlayModelAnimatesFirstObservedFlashToken() {
        let model = TmuxWorkspacePaneOverlayModel()
        let workspaceId = UUID()
        let flashRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let flashDate = Date(timeIntervalSince1970: 42)

        model.apply(
            TmuxWorkspacePaneOverlayRenderState(
                workspaceId: workspaceId,
                unreadRects: [],
                flashRect: flashRect,
                flashToken: 1,
                flashReason: .unreadIndicatorDismiss
            ),
            now: { flashDate }
        )

        XCTAssertEqual(model.flashStartedAt, flashDate)
        XCTAssertEqual(model.flashReason, .unreadIndicatorDismiss)
    }

    func testTmuxWorkspacePaneOverlayModelWaitsForRectBeforeFirstObservedFlashToken() {
        let model = TmuxWorkspacePaneOverlayModel()
        let workspaceId = UUID()
        let flashRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        let flashDate = Date(timeIntervalSince1970: 42)

        model.apply(TmuxWorkspacePaneOverlayRenderState(
            workspaceId: workspaceId,
            unreadRects: [],
            flashRect: nil,
            flashToken: 1,
            flashReason: .unreadIndicatorDismiss
        ))
        XCTAssertNil(model.flashStartedAt)

        model.apply(
            TmuxWorkspacePaneOverlayRenderState(
                workspaceId: workspaceId,
                unreadRects: [],
                flashRect: flashRect,
                flashToken: 1,
                flashReason: .unreadIndicatorDismiss
            ),
            now: { flashDate }
        )

        XCTAssertEqual(model.flashStartedAt, flashDate)
        XCTAssertEqual(model.flashReason, .unreadIndicatorDismiss)
    }

    func testAllFlashReasonsUseNotificationRingAccent() {
        let reasons: [WorkspaceAttentionFlashReason] = [
            .navigation,
            .notificationArrival,
            .notificationDismiss,
            .unreadIndicatorDismiss,
            .debug,
        ]

        for reason in reasons {
            XCTAssertEqual(
                WorkspaceAttentionCoordinator.flashStyle(for: reason).accent,
                WorkspaceAttentionCoordinator.notificationRingStyle.accent
            )
        }
    }

    func testFocusFlashUsesNotificationRingColor() {
        XCTAssertEqual(
            WorkspaceAttentionCoordinator.flashStyle(for: .navigation).accent.strokeColor.hexString(),
            WorkspaceAttentionCoordinator.notificationRingStyle.accent.strokeColor.hexString()
        )
    }

    func testTmuxWorkspacePaneExactRectReturnsContentRelativeFrameForDescendantView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected contentView")
            return
        }

        let targetView = NSView(frame: NSRect(x: 120, y: 48, width: 300, height: 200))
        contentView.addSubview(targetView)

        XCTAssertEqual(
            ContentView.tmuxWorkspacePaneExactRect(for: targetView, in: contentView),
            CGRect(x: 120, y: 48, width: 300, height: 200)
        )
    }
}

@MainActor
final class ApplicationAccessibilityHierarchyCacheTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        return window
    }

    private func assertWindowsEqual(_ actual: Any?, _ expected: [NSWindow], file: StaticString = #filePath, line: UInt = #line) {
        guard let actualWindows = actual as? [NSWindow] else {
            XCTFail("Expected NSWindow array", file: file, line: line)
            return
        }
        guard actualWindows.count == expected.count else {
            XCTFail("Expected \(expected.count) windows, got \(actualWindows.count)", file: file, line: line)
            return
        }
        for (lhs, rhs) in zip(actualWindows, expected) {
            XCTAssertTrue(lhs === rhs, file: file, line: line)
        }
    }

    func testRepeatedWindowsQueriesReuseSingleHierarchyBuildUntilStateChanges() {
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        defer {
            firstWindow.orderOut(nil)
            secondWindow.orderOut(nil)
        }

        let cache = CmuxApplicationAccessibilityHierarchyCache()
        let state = CmuxApplicationAccessibilityHierarchyCache.StateToken(windows: [firstWindow, secondWindow])
        var buildCount = 0

        let firstValue = cache.value(for: .windows, stateToken: state) {
            buildCount += 1
            return .init(windows: [firstWindow, secondWindow])
        }
        let secondValue = cache.value(for: .windows, stateToken: state) {
            XCTFail("Expected cached snapshot for repeated state")
            return .init(windows: [])
        }

        assertWindowsEqual(firstValue, [firstWindow, secondWindow])
        assertWindowsEqual(secondValue, [firstWindow, secondWindow])
        XCTAssertEqual(buildCount, 1, "Expected a single hierarchy build for repeated AX queries with no invalidation")
    }

    func testChangedStateTokenInvalidatesCachedHierarchySnapshot() {
        let window = makeWindow()
        let otherWindow = makeWindow()
        defer {
            window.orderOut(nil)
            otherWindow.orderOut(nil)
        }

        let cache = CmuxApplicationAccessibilityHierarchyCache()
        let initialState = CmuxApplicationAccessibilityHierarchyCache.StateToken(windows: [window])
        let updatedState = CmuxApplicationAccessibilityHierarchyCache.StateToken(windows: [window, otherWindow])
        var buildCount = 0

        _ = cache.value(for: .windows, stateToken: initialState) {
            buildCount += 1
            return .init(windows: [window])
        }
        let updatedWindowsValue = cache.value(for: .windows, stateToken: updatedState) {
            buildCount += 1
            return .init(windows: [window, otherWindow])
        }

        assertWindowsEqual(updatedWindowsValue, [window, otherWindow])
        XCTAssertEqual(buildCount, 2, "Expected the cache to rebuild once after the hierarchy token changes")
    }

    func testNonWindowsAttributesStayPassthrough() {
        let cache = CmuxApplicationAccessibilityHierarchyCache()

        for attribute: NSAccessibility.Attribute in [.children, .visibleChildren, .mainWindow, .focusedWindow] {
            switch cache.resolve(attribute: attribute, application: NSApp) {
            case .passthrough:
                break
            case .handled:
                XCTFail("Expected \(attribute.rawValue) to fall back to AppKit")
            }
        }
    }

    func testWindowCloseNotificationInvalidatesCache() {
        let window = makeWindow()
        defer { window.orderOut(nil) }

        let center = NotificationCenter()
        let cache = CmuxApplicationAccessibilityHierarchyCache(notificationCenter: center)
        let state = CmuxApplicationAccessibilityHierarchyCache.StateToken(windows: [window])
        var buildCount = 0

        _ = cache.value(for: .windows, stateToken: state) {
            buildCount += 1
            return .init(windows: [window])
        }
        center.post(name: NSWindow.willCloseNotification, object: window)
        _ = cache.value(for: .windows, stateToken: state) {
            buildCount += 1
            return .init(windows: [window])
        }

        XCTAssertEqual(buildCount, 2, "Expected NSWindow.willCloseNotification to invalidate the cache")
    }
}

// Regression for the sprite assistant floating panel drag.
//
// The panel is a child NSPanel of the active terminal window. Two paths converge
// at the panel's screen frame: `updateDrag` (driven by every mouse-drag event)
// and `syncChildFrame` (driven by every SwiftUI re-render, which fires
// continuously while the mascot's TimelineView animates).
//
// If `syncChildFrame` applies a screen clamp while a drag is in progress, the
// panel gets repeatedly pulled back inside the visible screen between drag
// events and the cursor detaches from the avatar. The fix is to gate that
// clamp by `dragSession == nil`. These tests pin both halves of the contract:
//
//   - `testPanelOriginTracksCursorDeltaExactly`: the panel's screen origin
//     follows the cursor delta point-for-point (no offsets, no rounding drift).
//   - `testSyncChildFrameDuringDragDoesNotPullPanelBackFromOffscreenEdge`:
//     re-running `update(...)` (which is exactly the SwiftUI updateNSView path)
//     mid-drag with the panel pushed off the visible screen leaves the panel
//     at the dragged position. Without the fix this test fails by hundreds of
//     pixels because clampedScreenRect pulls the panel back to maxX-padding.
@MainActor
final class SortAssistantFloatingPanelDragTrackingTests: XCTestCase {
    private var parentWindow: NSWindow!
    private var hostView: SortAssistantFloatingPanelHostView!
    private var tabManager: TabManager!
    private var workspaceTabStore: WorkspaceTabStore!
    private var layoutRevision = 0

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        guard let mainVisible = NSScreen.main?.visibleFrame else {
            return
        }
        // Integer-align the parent frame so NSWindow.setFrame doesn't snap to a
        // backing-pixel boundary and silently absorb a pixel of cursor motion.
        let parentSize = NSSize(width: 900, height: 700)
        let parentFrame = NSRect(
            x: floor(mainVisible.midX - parentSize.width * 0.5),
            y: floor(mainVisible.midY - parentSize.height * 0.5),
            width: parentSize.width,
            height: parentSize.height
        )
        parentWindow = NSWindow(
            contentRect: parentFrame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        parentWindow.isReleasedWhenClosed = false
        parentWindow.setFrame(parentFrame, display: false)
        SortAssistantCoordinator.shared.setPanelEdgeRecovery(false)
        SortAssistantCoordinator.shared.setConversationBubbleSide(.right, reason: "testSetup")
        tabManager = TabManager()
        workspaceTabStore = WorkspaceTabStore()
        hostView = SortAssistantFloatingPanelHostView()
        parentWindow.contentView?.addSubview(hostView)
        parentWindow.orderFront(nil)
        present()
    }

    override func tearDown() {
        if hostView != nil {
            hostView.endDrag()
            layoutRevision += 1
            hostView.update(
                isPresented: false,
                layoutRevision: layoutRevision,
                focusRevision: 0,
                coordinator: SortAssistantCoordinator.shared,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore
            )
            hostView.tearDown()
            hostView.removeFromSuperview()
        }
        parentWindow?.orderOut(nil)
        parentWindow = nil
        hostView = nil
        tabManager = nil
        workspaceTabStore = nil
        super.tearDown()
    }

    private func present() {
        layoutRevision += 1
        hostView.update(
            isPresented: true,
            layoutRevision: layoutRevision,
            focusRevision: 0,
            coordinator: SortAssistantCoordinator.shared,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
    }

    private func drainFloatingPanelLayout() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func restoreSpriteBubbleState(presented: Bool, side: SortAssistantFloatingConversationBubbleSide) {
        let coordinator = SortAssistantCoordinator.shared
        if coordinator.conversationBubbleSide != side {
            coordinator.setConversationBubbleSide(side, reason: "testRestore")
        }
        if coordinator.isConversationBubblePresented != presented {
            _ = coordinator.toggleConversationBubble(reason: "testRestore")
        }
    }

    func testPanelOriginTracksCursorDeltaExactly() throws {
        try XCTSkipIf(NSScreen.main == nil, "Requires a screen for child panel layout")
        guard let initial = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after presenting the sprite assistant")
            return
        }

        // Anchor the drag to an integer-aligned screen point so the cursor
        // delta itself does not introduce sub-pixel arithmetic into the panel
        // position math. We're asserting "the panel moves by the cursor delta",
        // not "the panel snaps to specific absolute screen coordinates".
        let start = NSPoint(x: floor(initial.midX), y: floor(initial.midY))
        hostView.beginDrag(screenPoint: start)
        hostView.updateDrag(screenPoint: start)

        guard let atStart = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after beginDrag")
            return
        }
        XCTAssertEqual(atStart.origin.x, initial.origin.x, accuracy: 0.5,
                       "Panel must not jump on the first drag frame")
        XCTAssertEqual(atStart.origin.y, initial.origin.y, accuracy: 0.5,
                       "Panel must not jump on the first drag frame")

        // Drive a sequence of cursor deltas measured from `start` and assert
        // that, for each one, the panel's screen origin has moved exactly that
        // delta from `atStart`. This is the user-visible "follow the cursor"
        // contract — any pixel drift here means the cursor and the avatar are
        // pulling apart.
        let deltas: [NSPoint] = [
            NSPoint(x: 17, y: -23),
            NSPoint(x: 134, y: 88),
            NSPoint(x: -55, y: 41),
            NSPoint(x: 240, y: -160),
        ]
        for delta in deltas {
            let target = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
            hostView.updateDrag(screenPoint: target)
            guard let current = hostView.debugChildPanelScreenFrame else {
                XCTFail("Expected child panel after updateDrag")
                return
            }
            let actualXDelta = current.origin.x - atStart.origin.x
            let actualYDelta = current.origin.y - atStart.origin.y
            XCTAssertEqual(actualXDelta, delta.x, accuracy: 0.5,
                           "Panel X must move by the exact cursor delta (\(delta))")
            XCTAssertEqual(actualYDelta, delta.y, accuracy: 0.5,
                           "Panel Y must move by the exact cursor delta (\(delta))")
            XCTAssertEqual(current.size.width, atStart.size.width, accuracy: 0.5,
                           "Drag must not resize the panel width")
            XCTAssertEqual(current.size.height, atStart.size.height, accuracy: 0.5,
                           "Drag must not resize the panel height")
        }
        hostView.endDrag()
    }

    func testSyncChildFrameDuringDragDoesNotPullPanelBackFromOffscreenEdge() throws {
        guard let mainVisible = NSScreen.main?.visibleFrame else {
            throw XCTSkip("Requires a screen for off-screen clamp validation")
        }
        guard let initial = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after presenting the sprite assistant")
            return
        }

        let start = NSPoint(x: initial.midX, y: initial.midY)
        hostView.beginDrag(screenPoint: start)
        XCTAssertTrue(hostView.debugHasActiveDragSession, "Drag session should be active")

        // Drag the cursor far past the visible screen's right edge so the panel
        // rect ends up fully off-screen. Without the fix, `syncChildFrame` would
        // pull the panel back to the visibleFrame boundary.
        let offscreenDelta = NSPoint(x: mainVisible.maxX - initial.midX + 800, y: 0)
        let offscreenPoint = NSPoint(x: start.x + offscreenDelta.x, y: start.y + offscreenDelta.y)
        hostView.updateDrag(screenPoint: offscreenPoint)

        guard let draggedOffscreen = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after off-screen drag")
            return
        }
        let expectedOriginX = initial.origin.x + offscreenDelta.x
        let expectedOriginY = initial.origin.y + offscreenDelta.y
        XCTAssertEqual(draggedOffscreen.origin.x, expectedOriginX, accuracy: 0.5,
                       "Drag must follow the cursor even past the screen edge")
        XCTAssertEqual(draggedOffscreen.origin.y, expectedOriginY, accuracy: 0.5,
                       "Drag must follow the cursor Y exactly")
        XCTAssertGreaterThan(draggedOffscreen.origin.x, mainVisible.maxX,
                             "Test precondition: panel must actually be off-screen-right")

        // Simulate the SwiftUI re-render path. This is the exact code path the
        // mascot TimelineView triggers many times per second while dragging.
        present()
        present()
        present()

        guard let afterReLayout = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after re-layout")
            return
        }
        XCTAssertEqual(afterReLayout.origin.x, draggedOffscreen.origin.x, accuracy: 0.5,
                       "Re-layout during an active drag must not clamp the panel back from off-screen")
        XCTAssertEqual(afterReLayout.origin.y, draggedOffscreen.origin.y, accuracy: 0.5,
                       "Re-layout during an active drag must not shift the panel Y")
        XCTAssertEqual(afterReLayout.size.width, draggedOffscreen.size.width, accuracy: 0.5,
                       "Re-layout during an active drag must not resize the panel width")
        XCTAssertEqual(afterReLayout.size.height, draggedOffscreen.size.height, accuracy: 0.5,
                       "Re-layout during an active drag must not resize the panel height")

        hostView.endDrag()
        XCTAssertFalse(hostView.debugHasActiveDragSession, "Drag session should clear on endDrag")
    }

    // The production cmux main window uses `NSHostingView` as its `contentView`,
    // whose `isFlipped == true`. `screenRect(...)` (forward) anchors a positioning-
    // sized rect (height = panelH - topReserve) but returns a rect with the full
    // panelSize; reversing that full-panelSize rect via `contentView.convert(_:from:)`
    // loses `topReserve` (~162 px) of Y because the flip is anchored to the rect's
    // height. Without the inverse fix, the very first updateDrag after beginDrag
    // shoots the panel up by ~162 px on any tiny cursor motion. This test only
    // catches the bug in the flipped configuration — the default NSWindow contentView
    // is non-flipped and `convert` is identity there.
    func testDragOnFlippedContentViewDoesNotJumpByTopReserve() throws {
        try XCTSkipIf(NSScreen.main == nil, "Requires a screen")

        // Replace the parent window's contentView with a flipped wrapper that
        // mirrors the real cmux main window's NSHostingView setup.
        hostView.endDrag()
        layoutRevision += 1
        hostView.update(
            isPresented: false,
            layoutRevision: layoutRevision,
            focusRevision: 0,
            coordinator: SortAssistantCoordinator.shared,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
        hostView.tearDown()
        hostView.removeFromSuperview()

        guard let originalBounds = parentWindow.contentView?.bounds else {
            XCTFail("Parent window must have a contentView")
            return
        }
        let flipped = FlippedHostContentView(frame: originalBounds)
        flipped.autoresizingMask = [.width, .height]
        parentWindow.contentView = flipped
        flipped.addSubview(hostView)
        parentWindow.layoutIfNeeded()
        present()

        guard let initial = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after presenting on flipped contentView")
            return
        }

        let start = NSPoint(x: floor(initial.midX), y: floor(initial.midY))
        hostView.beginDrag(screenPoint: start)
        hostView.updateDrag(screenPoint: start)

        guard let atStart = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after beginDrag")
            return
        }
        XCTAssertEqual(atStart.origin.y, initial.origin.y, accuracy: 0.5,
                       "First drag frame must not shift screen Y on a flipped contentView")
        XCTAssertEqual(atStart.origin.x, initial.origin.x, accuracy: 0.5,
                       "First drag frame must not shift screen X on a flipped contentView")

        // Force the syncChildFrame content-change branch (the SwiftUI re-render path
        // that fires continuously while the mascot's TimelineView animates).
        present()
        present()

        // The minimal cursor motion the user described: 1 pixel to the left.
        hostView.updateDrag(screenPoint: NSPoint(x: start.x - 1, y: start.y))

        guard let after = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after 1-pixel updateDrag")
            return
        }
        XCTAssertEqual(after.origin.y, atStart.origin.y, accuracy: 0.5,
                       "1-pixel horizontal cursor motion must not shift screen Y by topReserve")
        XCTAssertEqual(after.origin.x, atStart.origin.x - 1, accuracy: 0.5,
                       "Panel X must follow the cursor delta exactly")
        hostView.endDrag()
    }

    // 窗边小精灵: when the user has positioned the panel and a subsequent
    // content-driven re-layout would push it entirely off the right edge of the
    // visible screen, the panel must instead be clamped so the configured avatar
    // recovery hotspot stays on-screen as a draggable handle. Without the
    // re-wired `manualDragScreenRect` path, the panel would either be hard-fit
    // (shrunken) by `clampedScreenRect` or float entirely off-screen.
    func testRecoveryHotspotStaysVisibleAfterUserPositionedPanelGoesOffscreen() throws {
        guard let mainVisible = NSScreen.main?.visibleFrame else {
            throw XCTSkip("Requires a screen")
        }
        guard let initial = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after presenting")
            return
        }

        hostView.debugSetUserPositioned(true)

        // Drive a drag-and-release that lands the panel completely past the
        // right edge of the visible screen, then trigger a syncChildFrame via
        // present(). This is the path autocomplete / mascot animation re-renders
        // take after the user has dragged the sprite to the edge.
        let start = NSPoint(x: floor(initial.midX), y: floor(initial.midY))
        hostView.beginDrag(screenPoint: start)
        let offscreenTarget = NSPoint(x: mainVisible.maxX + 600, y: start.y)
        hostView.updateDrag(screenPoint: offscreenTarget)
        hostView.endDrag()

        present()

        guard let after = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after re-layout")
            return
        }

        // The recovery hotspot in panel-local coordinates is centered on the
        // avatar drag hotspot. Its on-screen position is panel.origin +
        // recoveryHotspot.origin.
        let recovery = SortAssistantFloatingPanelMetrics.avatarDragRecoveryHotspot
        let recoveryOnScreen = NSRect(
            x: after.origin.x + recovery.origin.x,
            y: after.origin.y + recovery.origin.y,
            width: recovery.width,
            height: recovery.height
        )
        let visiblePiece = recoveryOnScreen.intersection(mainVisible)
        XCTAssertEqual(visiblePiece.width,
                       SortAssistantFloatingPanelMetrics.minimumVisibleDragHotspotSize.width,
                       accuracy: 0.5,
                       "Recovery hotspot must keep its full minimumVisibleDragHotspotSize.width on-screen")
        XCTAssertEqual(visiblePiece.height,
                       SortAssistantFloatingPanelMetrics.minimumVisibleDragHotspotSize.height,
                       accuracy: 0.5,
                       "Recovery hotspot must keep its full minimumVisibleDragHotspotSize.height on-screen")
    }

    // When the panel naturally fits inside the screen's visible frame, no
    // edge-recovery should be active. (The default setUp places a 900×700
    // parent at screen center; the 404×280 panel sits comfortably inside.)
    func testAutoPositionedPanelDoesNotActivateEdgeRecoveryWhenItFits() throws {
        try XCTSkipIf(NSScreen.main == nil, "Requires a screen")

        hostView.debugSetUserPositioned(false)
        present()

        XCTAssertFalse(
            SortAssistantCoordinator.shared.isPanelEdgeRecovery,
            "An auto-positioned panel that fits naturally must not activate the window-edge mini-sprite"
        )
    }

    // Leaving the parent content area is not enough to activate edge recovery.
    // The mini-sprite is a screen-edge recovery affordance; users can drag the
    // assistant outside the cmux window while it remains fully visible on the
    // display.
    func testConversationBubbleOutsideParentDoesNotActivateEdgeRecoveryWhileScreenVisible() throws {
        guard let mainVisible = NSScreen.main?.visibleFrame else {
            throw XCTSkip("Requires a screen")
        }

        // Re-anchor parent so the panel's right-side conversation card extends
        // past the parent content frame while the full panel remains
        // screen-visible.
        let smallFrame = NSRect(
            x: floor(mainVisible.midX - 110),
            y: floor(mainVisible.midY - 100),
            width: 220,
            height: 220
        )
        parentWindow.setFrame(smallFrame, display: false)

        hostView.debugSetUserPositioned(false)
        present()

        XCTAssertFalse(
            SortAssistantCoordinator.shared.isPanelEdgeRecovery,
            "Parent-window clipping alone must not activate the screen-edge mini-sprite"
        )
    }

    func testConversationBubbleSwitchesToLeftNearRightScreenEdge() throws {
        guard let mainVisible = NSScreen.main?.visibleFrame else {
            throw XCTSkip("Requires a screen")
        }
        let coordinator = SortAssistantCoordinator.shared
        let previousPresented = coordinator.isConversationBubblePresented
        let previousSide = coordinator.conversationBubbleSide
        defer {
            restoreSpriteBubbleState(presented: previousPresented, side: previousSide)
        }

        coordinator.setPanelEdgeRecovery(false)
        coordinator.setConversationBubbleSide(.right, reason: "testSetup")
        if !coordinator.isConversationBubblePresented {
            coordinator.openConversationBubble(reason: "testSetup")
        }

        present()
        drainFloatingPanelLayout()
        guard let initial = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel before right-edge drag")
            return
        }

        let initialAvatar = SortAssistantFloatingPanelScreenClamp.hotspotRect(
            in: initial,
            hotspot: SortAssistantFloatingPanelMetrics.avatarVisualFrame(side: .right)
        )
        let start = NSPoint(x: floor(initialAvatar.midX), y: floor(initialAvatar.midY))
        hostView.beginDrag(screenPoint: start)
        hostView.updateDrag(screenPoint: NSPoint(x: mainVisible.maxX - 100, y: start.y))
        hostView.endDrag()

        XCTAssertEqual(
            coordinator.conversationBubbleSide,
            .left,
            "The sprite bubble should move to the left when a right-side bubble would cross the visible screen edge"
        )
        XCTAssertFalse(
            coordinator.isPanelEdgeRecovery,
            "Flipping the bubble side should keep the full sprite visible instead of entering edge recovery"
        )

        guard let after = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after right-edge layout")
            return
        }
        let avatar = SortAssistantFloatingPanelScreenClamp.hotspotRect(
            in: after,
            hotspot: SortAssistantFloatingPanelMetrics.avatarVisualFrame(side: .left)
        )
        let bubble = NSRect(
            x: after.minX,
            y: after.minY,
            width: SortAssistantFloatingPanelMetrics.conversationWidth,
            height: after.height
        )

        XCTAssertTrue(mainVisible.contains(avatar),
                      "The sprite itself should remain visible after the bubble flips left")
        XCTAssertLessThanOrEqual(
            bubble.maxX,
            avatar.minX - SortAssistantFloatingPanelMetrics.widgetSpacing + 0.5,
            "Left-side conversation bubble should sit to the left of the sprite"
        )
        XCTAssertLessThanOrEqual(after.maxX, mainVisible.maxX + 0.5,
                                 "The left-side layout should not push the sprite edge past the screen")
    }

    // The cmux parent content viewport is not a sprite boundary. The user can
    // drag the floating assistant outside the app window while it remains
    // visible on the physical display; that must not activate mini mode.
    func testAvatarSpriteOutsideParentContentDoesNotActivateEdgeRecovery() throws {
        guard let mainVisible = NSScreen.main?.visibleFrame else {
            throw XCTSkip("Requires a screen")
        }
        drainFloatingPanelLayout()
        guard let initial = hostView.debugChildPanelScreenFrame,
              let parentContentFrame = parentContentFrameOnScreen() else {
            XCTFail("Expected child panel and parent content frame after presenting")
            return
        }

        let avatarFrame = SortAssistantFloatingPanelMetrics.avatarVisualFrame
        let desiredY = parentContentFrame.minY - avatarFrame.minY - 10
        let start = NSPoint(x: floor(initial.midX), y: floor(initial.midY))
        hostView.beginDrag(screenPoint: start)
        hostView.updateDrag(
            screenPoint: NSPoint(
                x: start.x,
                y: start.y + desiredY - initial.minY
            )
        )

        guard let after = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after drag")
            hostView.endDrag()
            return
        }
        let avatarSprite = SortAssistantFloatingPanelScreenClamp.hotspotRect(
            in: after,
            hotspot: avatarFrame
        )
        XCTAssertTrue(mainVisible.contains(avatarSprite),
                      "Test setup keeps the avatar sprite inside the physical display")
        XCTAssertGreaterThan(parentContentFrame.minY - avatarSprite.minY, 0.5,
                             "Test setup must put the avatar sprite below the parent content viewport")
        XCTAssertFalse(
            SortAssistantCoordinator.shared.isPanelEdgeRecovery,
            "Avatar sprite overflow outside the parent content viewport must not activate mini mode"
        )
        hostView.endDrag()
    }

    // The panel includes the conversation bubble to the right of the avatar.
    // The bubble can cross the screen edge while the avatar is still fully
    // visible; that must not switch to mini mode because the sprite itself is
    // not at the recovery edge yet.
    func testPanelOverflowDoesNotActivateEdgeRecoveryWhenAvatarHotspotVisible() throws {
        guard let mainVisible = NSScreen.main?.visibleFrame else {
            throw XCTSkip("Requires a screen")
        }
        guard let initial = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after presenting")
            return
        }

        // Overflow the conversation side substantially while keeping the
        // avatar-side sprite inside the physical screen. This specifically
        // guards against using whole-panel overflow as the mini-sprite trigger.
        let desiredX = mainVisible.maxX - initial.width + 120
        let start = NSPoint(x: floor(initial.midX), y: floor(initial.midY))
        hostView.beginDrag(screenPoint: start)
        hostView.updateDrag(
            screenPoint: NSPoint(
                x: start.x + desiredX - initial.minX,
                y: start.y
            )
        )

        guard let after = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after drag")
            hostView.endDrag()
            return
        }

        XCTAssertGreaterThan(after.maxX, mainVisible.maxX,
                             "Test setup must place the conversation side of the panel past the screen edge")
        let avatarSprite = SortAssistantFloatingPanelScreenClamp.hotspotRect(
            in: after,
            hotspot: SortAssistantFloatingPanelMetrics.avatarVisualFrame
        )
        XCTAssertTrue(mainVisible.contains(avatarSprite),
                      "Test setup must keep the avatar sprite fully visible")
        XCTAssertFalse(
            SortAssistantCoordinator.shared.isPanelEdgeRecovery,
            "Panel overflow alone must not activate mini mode while the avatar sprite is fully visible"
        )
        hostView.endDrag()
    }

    func testAvatarHotspotOffscreenActivatesEdgeRecovery() throws {
        guard let mainVisible = NSScreen.main?.visibleFrame else {
            throw XCTSkip("Requires a screen")
        }

        // Push the auto-positioned panel far enough right that the avatar
        // sprite itself is no longer fully visible. The recovery clamp
        // keeps the mini-sprite-sized hotspot visible as the drag handle.
        let smallFrame = NSRect(
            x: floor(mainVisible.maxX - 20),
            y: floor(mainVisible.midY - 100),
            width: 220,
            height: 220
        )
        parentWindow.setFrame(smallFrame, display: false)

        hostView.debugSetUserPositioned(false)
        present()
        drainFloatingPanelLayout()

        XCTAssertTrue(
            SortAssistantCoordinator.shared.isPanelEdgeRecovery,
            "When the avatar sprite extends past the screen edge, the window-edge mini-sprite must activate"
        )

        guard let after = hostView.debugChildPanelScreenFrame else {
            XCTFail("Expected child panel after re-layout")
            return
        }
        // And the recovery hotspot must still be fully inside the visible
        // frame; the smaller mini-sprite is centered inside it.
        let recovery = SortAssistantFloatingPanelMetrics.avatarDragRecoveryHotspot
        let recoveryOnScreen = NSRect(
            x: after.origin.x + recovery.origin.x,
            y: after.origin.y + recovery.origin.y,
            width: recovery.width,
            height: recovery.height
        )
        let visiblePiece = recoveryOnScreen.intersection(mainVisible)
        XCTAssertEqual(visiblePiece.width, recovery.width, accuracy: 0.5,
                       "Recovery hotspot must remain fully horizontally visible")
        XCTAssertEqual(visiblePiece.height, recovery.height, accuracy: 0.5,
                       "Recovery hotspot must remain fully vertically visible")
    }

    private func parentContentFrameOnScreen() -> NSRect? {
        guard let contentView = parentWindow.contentView else { return nil }
        let contentRectInWindow = contentView.convert(contentView.bounds, to: nil)
        return parentWindow.convertToScreen(contentRectInWindow)
    }
}

private final class FlippedHostContentView: NSView {
    override var isFlipped: Bool { true }
}
#endif
