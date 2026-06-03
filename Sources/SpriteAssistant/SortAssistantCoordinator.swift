import AppKit
import CMUXActions
import CMUXWorkstream
import CmuxSocketControl
import Combine
import Foundation

/// Immutable, render-ready sidebar badge value resolved at the boundary from a
/// ProactiveSuggestion. Lives in the app module so the sidebar (ContentView) can
/// render it without importing the contracts/orchestration packages, and so row
/// subtrees receive a plain value (snapshot-boundary rule).
struct WorkspaceProactiveSuggestionBadge: Equatable, Sendable {
    let type: String
    let glyph: String
    let helpText: String
}

@MainActor
final class SortAssistantCoordinator: ObservableObject {
    static let shared = SortAssistantCoordinator()

    @Published private(set) var messages: [SortAssistantMessage] = []
    @Published private(set) var latestResult: SortAssistantSortResult? {
        didSet {
            if latestResult == nil {
                latestResultAnchorMessageId = nil
            }
            invalidateFloatingLayout(reason: "latestResult")
        }
    }
    @Published private(set) var latestResultAnchorMessageId: UUID?
    @Published private(set) var choicePromptSelections: [String: SortAssistantChoicePrompt.Option] = [:]
    @Published private(set) var choicePrompt: SortAssistantChoicePrompt? {
        didSet {
            if choicePrompt?.id != oldValue?.id {
                choicePromptSelections = [:]
            }
            invalidateFloatingLayout(reason: "choicePrompt")
        }
    }
    @Published private(set) var dimensionQuestion: SortAssistantDimensionQuestion? {
        didSet { invalidateFloatingLayout(reason: "dimensionQuestion") }
    }
    @Published private(set) var semanticActionConfirmation: SortAssistantSemanticActionConfirmation? {
        didSet { invalidateFloatingLayout(reason: "semanticActionConfirmation") }
    }
    @Published private(set) var memoryCandidate: SortAssistantMemoryCandidate? {
        didSet { invalidateFloatingLayout(reason: "memoryCandidate") }
    }
    @Published private(set) var memories: [SortAssistantMemory] = []
    @Published private(set) var spriteMemories: [SortAssistantMemory] = []
    @Published private(set) var visibleSuggestions: [ProactiveSuggestion] = []
    private var cachedActiveSuggestions: [ProactiveSuggestion] = []
    @Published private(set) var isSorting = false
    @Published private(set) var presentationSequence = 0
    @Published private(set) var presentationToggleSequence = 0
    @Published private(set) var isConversationBubblePresented = false
    @Published private(set) var conversationBubbleSide: SortAssistantFloatingConversationBubbleSide = .right
    @Published private(set) var externalGoalSequence = 0
    @Published private(set) var entryFocusSequence = 0
    @Published private(set) var floatingLayoutRevision = 0
    // Master visibility of the floating sprite (avatar). Toggle Sprite Assistant
    // flips this for a true on/off; the host hides the panel entirely when false.
    @Published private(set) var isFloatingSpriteVisible = false
    // Phase 2 Tier 2: when the auto-bubble surfaces a suggestion unprompted, the
    // bubble renders a compact suggestion card (not the full thread). Default off.
    @Published private(set) var isCompactAutoBubble = false
    @Published private(set) var compactAutoBubbleSuggestion: ProactiveSuggestion?

    private static let workstreamId = "cmux-sort-assistant"
    private static let memoryToolName = "cmux.sort_memory"
    private static let memorySchemaVersion = "cmux.sort_memory.v1"
    private static let iso8601Formatter = ISO8601DateFormatter()
    private let memoryFileURL = WorkstreamPersistence.defaultFileURL()
    private let intentRouter = SortAssistantIntentRouter()
    private let actionRouter = SortAssistantActionRouter()
    private let sortEventLog: SortAssistantSortEventLog
    private let sortEngine: SortEngine
    private let sortOperator: SortOperator
    private let contextProvider: SortContextProvider
    private let rankingEngine = RankingEngine()
    private let suggestionEngine = SuggestionEngine()
    private var dismissedSuggestionIds: Set<UUID> = []
    // Phase 1 closed-loop recompute (gated by ProactiveSpriteSuggestionsSettings):
    // coalesces bursts of ContextAgent batches into a single trailing recompute.
    private var proactiveSuggestionRecomputePending = false
    private var proactiveSuggestionRecomputeTask: Task<Void, Never>?
    private var proactiveSuggestionRecomputeDebounceNanos: UInt64 {
        #if DEBUG
        if let override = Self.debugProactiveSuggestionRecomputeDebounceOverrideNanos {
            return override
        }
        #endif
        return 250_000_000
    }
    #if DEBUG
    static var debugProactiveSuggestionRecomputeDebounceOverrideNanos: UInt64?
    #endif
    // Phase 2 surfacing thresholds (see suggestion-sprint-plan.md decision 5).
    // Badge shows all three actionable types (floor 0.85 == "the suggestion exists");
    // the auto bubble / notification only fire for high-attention items (0.90).
    static let proactiveBadgeConfidenceFloor = 0.85
    static let proactiveAutoSurfaceConfidenceFloor = 0.90
    private static let proactiveBadgeSuggestionTypes: Set<String> = [
        ProactiveSuggestionTypes.reviewAgentWaitingUser,
        ProactiveSuggestionTypes.fixCIFailure,
        ProactiveSuggestionTypes.mergeReady,
        ProactiveSuggestionTypes.workspaceNeedsAttention,
    ]
    // Phase 2 Tier 2 auto-bubble state (default-off sub-flag ProactiveAutoBubbleSettings).
    private var autoBubbleSeenSuggestionIds: Set<UUID> = []
    private var lastAutoBubbleSurfacedAt: Date?
    private var autoBubbleDismissTask: Task<Void, Never>?
    private static let autoBubbleMinInterval: TimeInterval = 90
    private static let autoBubbleAutoDismissNanos: UInt64 = 12_000_000_000
    // Phase 4: dedup-by-id for suggestion-driven OS notifications (default-off sub-flag).
    private var notifiedProactiveSuggestionIds: Set<UUID> = []
    private let mcpClient = SortAssistantMCPClient()
    private var pendingExternalGoal: (goal: String, forceApply: Bool)?
    private var pendingPreviewPatch: SortPatch?
    private var pendingPreviewSort: WorkspaceSidebarSummaryPrioritySort?
    private var pendingIntentRequestId: UUID?
    private var pendingSemanticActionConfirmation: PendingSemanticActionConfirmation?
    private weak var lastTabManager: TabManager?
    private weak var lastWorkspaceTabStore: WorkspaceTabStore?
    private var claudeConversationSessionId = UUID()
    private var claudeConversationSessionStarted = false
    private var claudeVisibleScopeSignature: String?
    // Workspace-color binding for the sprite assistant's recovery handle.
    // Published so SwiftUI can re-render the colored marker when the active
    // workspace's customColor changes (or when the selected workspace itself
    // changes). `lastResolvedColorHex` dedupes the published value because
    // `TabManager.objectWillChange` fires very frequently — without dedupe every
    // tab edit would invalidate the floating panel's SwiftUI tree.
    @Published private(set) var spriteColor: NSColor?
    private var spriteColorCancellables: Set<AnyCancellable> = []
    private var lastResolvedColorHex: String?
    // True when the floating sprite panel can no longer fit its natural rect
    // inside the visible screen frame and has been clamped by
    // `manualDragScreenRect` to keep just the recovery hotspot visible. The
    // floating SwiftUI content reads this to swap the full avatar for the
    // window-edge mini-sprite. Driven by `SortAssistantFloatingPanelHostView`
    // after each layout pass; deduped so we don't republish on no-op layouts.
    @Published private(set) var isPanelEdgeRecovery: Bool = false
    private var currentSpriteMemoryDirectory: String?
    private var currentSpriteMemoryFileURL: URL?
    private var spriteMemorySources: [UUID: SpriteMemorySource] = [:]
    private var pendingCreatedMemories: [UUID: SortAssistantMemory] = [:]
    private var pendingDeletedMemoryIds: Set<UUID> = []
#if DEBUG
    private var debugEphemeralFreeSortMemoryIds: Set<UUID> = []
#endif
    private var sessionGeneration = UUID()
    let workspaceSnapshotStore: WorkspaceSnapshotStore
    private let assistantRuntime: AssistantRuntime
    private let contextScheduler: ContextScheduler
    private let contextProviderRunStore: ProviderRunStore
    private let contextAgent: ContextAgent
    private let suggestionSnapshotStore: SuggestionSnapshotStore
    private let rankingSnapshotStore: RankingSnapshotStore
    private var contextAgentEventTask: Task<Void, Never>?
    private var contextAgentStartupTask: Task<Void, Never>?
    private var semanticActionAuditTrail: [SemanticActionAuditEntry] = []
    private static let contextFreshnessWarningTools: Set<String> = [
        "assistant_working_context_get",
        "workspace_snapshot_get",
        "workspace_digest_get",
        "context_freshness_get",
        "ranking_latest_get",
        "suggestions_active_get",
    ]

    private enum ContextAgentSnapshotProviderError: Error {
        case snapshotUnavailable(UUID)
    }

    private struct PendingSemanticActionConfirmation {
        let id: UUID
        let intent: ActionIntent
        let confirm: () -> Void
    }

    private struct SemanticActionReviewError: LocalizedError {
        let intent: ActionIntent
        let result: SemanticReviewResult

        var errorDescription: String? {
            let reasons = result.reasons.isEmpty
                ? String(localized: "sortAssistant.actionReview.noReason", defaultValue: "No review reason was provided.")
                : result.reasons.joined(separator: ", ")
            switch result.decision {
            case .allow:
                return nil
            case .requireConfirmation:
                return String(
                    format: String(
                        localized: "sortAssistant.actionReview.requiresConfirmation",
                        defaultValue: "Action review requires confirmation: %@"
                    ),
                    reasons
                )
            case .deny:
                return String(
                    format: String(
                        localized: "sortAssistant.actionReview.denied",
                        defaultValue: "Action review denied this change: %@"
                    ),
                    reasons
                )
            }
        }
    }

    /// Bridges a ``WorkspaceSnapshotProviding`` provider id to a coordinator
    /// method that builds the snapshot on the main actor. The `resolve` closure
    /// is the only thing that varies between provider families (list/git/github
    /// snapshots vs. event-payload-derived signals).
    private final class CoordinatorSnapshotProvider: @unchecked Sendable, WorkspaceSnapshotProviding {
        nonisolated let providerId: String
        private weak var coordinator: SortAssistantCoordinator?
        private let resolve: @Sendable @MainActor (SortAssistantCoordinator, String, ContextRefreshJob) -> WorkspaceSnapshot?

        init(
            providerId: String,
            coordinator: SortAssistantCoordinator,
            resolve: @escaping @Sendable @MainActor (SortAssistantCoordinator, String, ContextRefreshJob) -> WorkspaceSnapshot?
        ) {
            self.providerId = providerId
            self.coordinator = coordinator
            self.resolve = resolve
        }

        func snapshot(for job: ContextRefreshJob) async throws -> WorkspaceSnapshot {
            let providerId = providerId
            return try await MainActor.run {
                guard let coordinator,
                      let snapshot = resolve(coordinator, providerId, job) else {
                    throw ContextAgentSnapshotProviderError.snapshotUnavailable(job.workspaceId)
                }
                return snapshot
            }
        }
    }
#if DEBUG
    private struct SpriteGeometryDebugSnapshot {
        var source: String
        var frame: NSRect
        var avatarSprite: NSRect
        var avatarHotspot: NSRect
        var recoveryHotspot: NSRect
        var visibleFrames: [NSRect]
        var isAvatarSpriteVisibleOnScreen: Bool
        var edgeRecovery: Bool
    }

    private var latestSpriteGeometryDebugSnapshot: SpriteGeometryDebugSnapshot?
#endif

    private init() {
        let snapshotStore = WorkspaceSnapshotStore()
        let scheduler = ContextScheduler()
        let providerRunStore = ProviderRunStore()
        let eventLog = SortAssistantSortEventLog(fileURL: memoryFileURL)
        let engine = SortEngine()
        self.workspaceSnapshotStore = snapshotStore
        self.assistantRuntime = AssistantRuntime(contextReader: snapshotStore)
        self.contextScheduler = scheduler
        self.contextProviderRunStore = providerRunStore
        self.contextAgent = ContextAgent(
            snapshotStore: snapshotStore,
            scheduler: scheduler,
            providerRunStore: providerRunStore,
            providers: []
        )
        self.suggestionSnapshotStore = SuggestionSnapshotStore(snapshotStore: snapshotStore)
        self.rankingSnapshotStore = RankingSnapshotStore(snapshotStore: snapshotStore)
        self.sortEventLog = eventLog
        self.sortEngine = engine
        self.sortOperator = SortOperator(engine: engine, eventLog: eventLog)
        self.contextProvider = SortContextProvider(eventLog: eventLog, engine: engine)
        memories = Self.loadLegacyMemories(from: memoryFileURL)
        self.contextAgentStartupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for providerId in ["list_state", "git_context", "github_context", "summary_priority"] {
                await self.contextAgent.registerProvider(CoordinatorSnapshotProvider(
                    providerId: providerId,
                    coordinator: self
                ) { coordinator, providerId, job in
                    coordinator.workspaceSnapshotForContextAgent(
                        workspaceId: job.workspaceId,
                        now: job.enqueuedAt,
                        freshnessProviderIds: [providerId]
                    )
                })
            }
            for providerId in ["agent_session", "notification_context", "workspace_activity"] {
                await self.contextAgent.registerProvider(CoordinatorSnapshotProvider(
                    providerId: providerId,
                    coordinator: self
                ) { coordinator, providerId, job in
                    coordinator.workspaceSnapshotForContextAgentPayload(
                        providerId: providerId,
                        job: job
                    )
                })
            }
            self.contextAgentEventTask = self.contextAgent.startEventStream(
                afterSequence: 0,
                onBatch: { [weak self] result in
                    await self?.handleContextAgentBatch(result)
                }
            )
        }
    }

    /// Consumes a ContextAgent batch result produced by background snapshot
    /// refresh (off the user turn). Phase 0 records DEBUG telemetry only and makes
    /// no behavior change. Phase 1 will, gated by `ProactiveSpriteSuggestionsSettings`,
    /// debounce a `refreshVisibleSuggestions()` recompute here so suggestions track
    /// context changes without the panel being open. The snapshots are already
    /// merged into `workspaceSnapshotStore` by the agent; this is a notification hook.
    func handleContextAgentBatch(_ result: ContextAgentBatchResult) async {
        let shouldRecompute = ProactiveSpriteSuggestionsSettings.isEnabled()
            && !result.updatedWorkspaceIds.isEmpty
        #if DEBUG
        recordContextAgentBatchTelemetry(result, triggeredRecompute: shouldRecompute)
        #endif
        guard shouldRecompute else { return }
        scheduleProactiveSuggestionRecompute()
    }

    /// Coalesces a burst of batches into a single trailing recompute. The first
    /// batch arms the debounce window; later batches inside the window only flip
    /// `pending` (no reschedule, so a steady event stream can't starve the flush).
    private func scheduleProactiveSuggestionRecompute() {
        proactiveSuggestionRecomputePending = true
        guard proactiveSuggestionRecomputeTask == nil else { return }
        proactiveSuggestionRecomputeTask = Task { @MainActor [weak self] in
            let debounce = self?.proactiveSuggestionRecomputeDebounceNanos ?? 0
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: debounce)
            }
            guard let self else { return }
            self.proactiveSuggestionRecomputeTask = nil
            guard self.proactiveSuggestionRecomputePending else { return }
            self.proactiveSuggestionRecomputePending = false
            await self.runProactiveSuggestionRecompute()
        }
    }

    private func runProactiveSuggestionRecompute() async {
        // Re-check the gate: the user may have toggled it off during the debounce window.
        guard ProactiveSpriteSuggestionsSettings.isEnabled() else { return }
        // Read the snapshots the ContextAgent just merged so suggestions track
        // background context changes without the panel being open. The panel-open
        // path (attach()) keeps computing from live state for an immediate refresh;
        // the store catches up as the agent collects, and the two converge.
        let snapshots = await workspaceSnapshotStore.assistantWorkingContext().snapshots
        let start = CFAbsoluteTimeGetCurrent()
        let updated = activeSuggestions(now: Date(), snapshots: snapshots, updateVisible: true, publish: true)
        #if DEBUG
        let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lastContextAgentBatchTelemetry?.recomputeDurationMs = durationMs
        #endif
        maybeNotifyProactiveSuggestions(from: updated)
    }

    /// Phase 4: fire a deduped, rate-limited OS notification for a NEW high-confidence
    /// suggestion while the app is backgrounded. Gated by both the parent flag and the
    /// default-off ProactiveSuggestionNotificationsSettings sub-flag. Focus-safe:
    /// addNotification only posts a banner and never activates the app.
    private func maybeNotifyProactiveSuggestions(from suggestions: [ProactiveSuggestion]) {
        guard ProactiveSpriteSuggestionsSettings.isEnabled(),
              ProactiveSuggestionNotificationsSettings.isEnabled() else { return }
        guard !AppFocusState.isAppActive() else { return }
        // Bound the dedup set and let a genuinely re-appearing suggestion notify again.
        notifiedProactiveSuggestionIds.formIntersection(Set(suggestions.map(\.id)))
        for suggestion in suggestions
        where Self.proactiveBadgeSuggestionTypes.contains(suggestion.type)
            && suggestion.confidence >= Self.proactiveAutoSurfaceConfidenceFloor
            && !notifiedProactiveSuggestionIds.contains(suggestion.id) {
            notifiedProactiveSuggestionIds.insert(suggestion.id)
            let workspaceTitle = lastTabManager?.tabs
                .first(where: { $0.id == suggestion.workspaceId })?.displayTitle ?? ""
            TerminalNotificationStore.shared.addNotification(
                tabId: suggestion.workspaceId,
                surfaceId: nil,
                title: workspaceTitle.isEmpty ? suggestion.title : workspaceTitle,
                subtitle: workspaceTitle.isEmpty ? "" : suggestion.title,
                body: suggestion.reason ?? "",
                source: .monitor,
                cooldownKey: "sprite.proactive.\(suggestion.id.uuidString)",
                cooldownInterval: 300
            )
        }
    }

    var hasCurrentSessionState: Bool {
        !messages.isEmpty
            || latestResult != nil
            || choicePrompt != nil
            || dimensionQuestion != nil
            || semanticActionConfirmation != nil
            || memoryCandidate != nil
            || isSorting
    }

    /// Number of high-confidence, actionable proactive suggestions to surface as
    /// an attention badge on the collapsed mascot. Always 0 unless the feature
    /// flag is enabled, so the closed sprite stays silent when proactive mode is off.
    var proactiveAttentionCount: Int {
        guard ProactiveSpriteSuggestionsSettings.isEnabled() else { return 0 }
        return visibleSuggestions.reduce(into: 0) { count, suggestion in
            if Self.proactiveBadgeSuggestionTypes.contains(suggestion.type),
               suggestion.confidence >= Self.proactiveBadgeConfidenceFloor {
                count += 1
            }
        }
    }

    /// One actionable proactive suggestion badge per workspace, deduped by a fixed
    /// type priority (review > ci > merge, tie-break by confidence) and filtered to
    /// the badge confidence floor. Empty unless the feature flag is on. Resolved at
    /// the sidebar boundary so rows never read the coordinator (snapshot-boundary rule).
    func proactiveBadgeByWorkspaceId() -> [UUID: WorkspaceProactiveSuggestionBadge] {
        guard ProactiveSpriteSuggestionsSettings.isEnabled() else { return [:] }
        var best: [UUID: ProactiveSuggestion] = [:]
        for suggestion in visibleSuggestions
        where Self.proactiveBadgeSuggestionTypes.contains(suggestion.type)
            && suggestion.confidence >= Self.proactiveBadgeConfidenceFloor {
            if let existing = best[suggestion.workspaceId] {
                let candidatePriority = Self.proactiveBadgePriority(suggestion.type)
                let existingPriority = Self.proactiveBadgePriority(existing.type)
                if candidatePriority > existingPriority
                    || (candidatePriority == existingPriority && suggestion.confidence > existing.confidence) {
                    best[suggestion.workspaceId] = suggestion
                }
            } else {
                best[suggestion.workspaceId] = suggestion
            }
        }
        return best.mapValues(Self.makeProactiveBadge(from:))
    }

    private static func proactiveBadgePriority(_ type: String) -> Int {
        switch type {
        case ProactiveSuggestionTypes.reviewAgentWaitingUser: return 3
        case ProactiveSuggestionTypes.fixCIFailure: return 2
        case ProactiveSuggestionTypes.workspaceNeedsAttention: return 2
        case ProactiveSuggestionTypes.mergeReady: return 1
        default: return 0
        }
    }

    private static func makeProactiveBadge(from suggestion: ProactiveSuggestion) -> WorkspaceProactiveSuggestionBadge {
        let glyph: String
        switch suggestion.type {
        case ProactiveSuggestionTypes.reviewAgentWaitingUser:
            glyph = "exclamationmark.bubble.fill"
        case ProactiveSuggestionTypes.fixCIFailure:
            glyph = "xmark.octagon.fill"
        case ProactiveSuggestionTypes.mergeReady:
            glyph = "checkmark.seal.fill"
        case ProactiveSuggestionTypes.workspaceNeedsAttention:
            glyph = "bell.badge.fill"
        default:
            glyph = "sparkles"
        }
        let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkspaceProactiveSuggestionBadge(
            type: suggestion.type,
            glyph: glyph,
            helpText: title.isEmpty ? suggestion.type : title
        )
    }

    /// The next workspace to look at by attention ranking (skips locked/pinned,
    /// wraps past the active one). Nil unless the feature flag is on. Backs the
    /// "Go to Next Workspace (by Attention)" command-palette command.
    func nextWorkspaceByAttention() -> UUID? {
        guard ProactiveSpriteSuggestionsSettings.isEnabled() else { return nil }
        let context = buildAssistantWorkingContext(now: Date())
        return NextWorkspaceService.default.nextWorkspace(in: context)?.workspaceId
    }

    var mascotState: SortAssistantMascotState {
        if isSorting {
            return .running
        }
        if messages.last?.kind == .error {
            return .failed
        }
        if memoryCandidate != nil || dimensionQuestion != nil || choicePrompt != nil || semanticActionConfirmation != nil {
            return .waiting
        }
        if let latestResult {
            switch latestResult.mode {
            case .applied:
                return .jumping
            case .preview:
                return .review
            }
        }
        if messages.last?.kind == .progress {
            return .review
        }
        return .idle
    }

#if DEBUG
    private var lastContextAgentBatchTelemetry: ContextAgentBatchTelemetry?

    private func recordContextAgentBatchTelemetry(
        _ result: ContextAgentBatchResult,
        triggeredRecompute: Bool,
        now: Date = Date()
    ) {
        lastContextAgentBatchTelemetry = ContextAgentBatchTelemetry(
            occurredAt: now,
            updatedWorkspaceIds: result.updatedWorkspaceIds,
            failureCount: result.failures.count,
            triggeredRecompute: triggeredRecompute,
            recomputeDurationMs: nil
        )
    }

    /// Test seam: awaits the in-flight debounced recompute (if any) so tests can
    /// deterministically observe `visibleSuggestions` after a batch.
    func debugAwaitProactiveSuggestionRecompute() async {
        await proactiveSuggestionRecomputeTask?.value
    }

    /// Test seam: waits until the context agent's asynchronous startup has
    /// registered the event-payload providers used by real hook-triggered jobs.
    func debugAwaitContextAgentStartup() async -> Bool {
        await contextAgentStartupTask?.value
        let requiredProviderIds: Set<String> = [
            "agent_session",
            "notification_context",
            "workspace_activity",
        ]
        let providerIds = Set(await contextAgent.providerIds())
        return requiredProviderIds.isSubset(of: providerIds) && contextAgentEventTask != nil
    }

    func debugContextAgentInspectorSnapshot(now: Date = Date()) async -> ContextAgentInspectorSnapshot {
        let context = makeAssistantWorkingContext(now: now)
        await workspaceSnapshotStore.replace(context)
        return ContextAgentInspectorSnapshot(
            capturedAt: now,
            workingContext: await workspaceSnapshotStore.assistantWorkingContext(),
            agentDiagnostics: await contextAgent.diagnostics(),
            auditEntries: semanticActionAuditTrail,
            lastBatchTelemetry: lastContextAgentBatchTelemetry
        )
    }

    /// Debug-only: inject a confidence=1.0 proactive suggestion for the selected
    /// workspace and drive the real recompute path so the mascot/sidebar badge,
    /// auto-bubble, and notification surfaces fire (each still subject to its own
    /// feature flag). A delay lets you background the app to also exercise the
    /// backgrounded notification, or close the panel to see the auto-bubble.
    func debugInjectTestProactiveSuggestion(afterDelay delay: TimeInterval = 0) {
        guard let tabManager = lastTabManager,
              let workspaceId = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            cmuxDebugLog("sprite.debug inject skipped: no selected workspace (open the sprite once first)")
            return
        }
        let nativeOrder = tabManager.tabs.firstIndex(where: { $0.id == workspaceId }) ?? 0
        let snapshot = WorkspaceSnapshot(
            workspaceId: workspaceId,
            version: 9_999,
            updatedAt: Date(),
            context: NormalizedWorkspaceContext(
                title: workspace.title,
                selected: true,
                directory: nil,
                listRevision: 0,
                nativeOrder: nativeOrder,
                pinned: false,
                locked: false,
                customColor: nil,
                panelCount: 0,
                pullRequestCount: 0,
                stalePullRequestCount: 0
            ),
            derived: DerivedWorkspaceState(
                status: "waiting_user",
                priorityScore: 100,
                rankReason: "Debug-injected high-priority suggestion",
                nextAction: "Review the debug-injected suggestion",
                userAttentionNeeded: 1.0
            ),
            digest: nil,
            freshness: ContextFreshness(providers: [], overallConfidence: 1.0),
            contextHash: "debug-inject-\(UUID().uuidString)"
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self.workspaceSnapshotStore.write(snapshot)
            await self.handleContextAgentBatch(
                ContextAgentBatchResult(updatedWorkspaceIds: [workspaceId], failures: [])
            )
            if !ProactiveSpriteSuggestionsSettings.isEnabled() {
                cmuxDebugLog("sprite.debug inject: ProactiveSpriteSuggestions is OFF — enable it in Settings to see the surfaces")
            }
        }
    }

    func debugResetMemoryState() {
        currentSpriteMemoryDirectory = nil
        currentSpriteMemoryFileURL = nil
        spriteMemorySources = [:]
        debugEphemeralFreeSortMemoryIds = []
        pendingCreatedMemories = [:]
        pendingDeletedMemoryIds = []
        memories = []
        spriteMemories = []
    }

    func debugResetSpriteMemoryState() {
        debugResetMemoryState()
    }

    func debugSeedFreeSortMemories(_ seededMemories: [SortAssistantMemory]) {
        let sortedMemories = seededMemories.sorted { $0.createdAt > $1.createdAt }
        debugEphemeralFreeSortMemoryIds = Set(sortedMemories.map(\.id))
        pendingDeletedMemoryIds = []
        pendingCreatedMemories = Dictionary(uniqueKeysWithValues: sortedMemories.map { ($0.id, $0) })
        memories = sortedMemories
    }
#endif

    private func prepareEntryMessageIfNeeded() {
        if messages.isEmpty {
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.entry.ready", defaultValue: "Tell me how to sort the workspace sidebar.")
            ))
        }
    }

    func attach(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        refreshVisibleSuggestions()
    }

    private func recordContextAgentAttention(
        tabManager: TabManager,
        workspaceTarget: SortAssistantWorkspaceTarget?,
        reason: String,
        queryCharacterCount: Int = 0
    ) {
        let workspaceIds = orderedUniqueSortAssistant([
            workspaceTarget?.id,
            tabManager.selectedTabId,
        ].compactMap { $0 })
        guard !workspaceIds.isEmpty else { return }
        // ContextAgent refresh scheduling is driven by the event stream. The
        // assistant turn only publishes attention so it can keep reading the
        // latest available snapshot without synchronously collecting context.
        for workspaceId in workspaceIds {
            CmuxEventBus.shared.publishAssistantQueryStarted(
                workspaceId: workspaceId,
                targetWorkspaceId: workspaceTarget?.id,
                source: "sprite.assistant",
                queryCharacterCount: queryCharacterCount,
                reason: reason
            )
        }
    }

    func clearCurrentSession(appendConfirmation: Bool = false) {
        sessionGeneration = UUID()
        claudeConversationSessionId = UUID()
        claudeConversationSessionStarted = false
        pendingIntentRequestId = nil
        pendingPreviewPatch = nil
        pendingPreviewSort = nil
        latestResult = nil
        latestResultAnchorMessageId = nil
        choicePrompt = nil
        dimensionQuestion = nil
        semanticActionConfirmation = nil
        pendingSemanticActionConfirmation = nil
        memoryCandidate = nil
        messages.removeAll()
        isSorting = false
        claudeVisibleScopeSignature = nil
        if appendConfirmation {
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.session.cleared", defaultValue: "Cleared the current session.")
            ))
        }
    }

    func activateEntry() {
        // True on/off: hide the whole floating sprite when it is showing; otherwise
        // show it (avatar + conversation) and focus the input.
        if isFloatingSpriteVisible {
            hideFloatingSprite()
            return
        }
        prepareEntryMessageIfNeeded()
        requestPresentation()
        openConversationBubble(reason: "activateEntry")
        entryFocusSequence += 1
    }

    func openEntry() {
        exitCompactAutoBubble()
        prepareEntryMessageIfNeeded()
        requestPresentation()
        openConversationBubble(reason: "openEntry")
        entryFocusSequence += 1
    }

    func submitExternalGoal(_ goal: String) {
        let trimmed = normalized(goal)
        guard !trimmed.isEmpty else { return }
        pendingExternalGoal = (trimmed, true)
        requestPresentation()
        openConversationBubble(reason: "externalGoal")
        externalGoalSequence += 1
    }

    func requestPresentation() {
        setFloatingSpriteVisible(true)
        presentationSequence += 1
    }

    /// Fully hide the floating sprite (avatar + conversation). Backs the on/off toggle.
    func hideFloatingSprite() {
        exitCompactAutoBubble()
        setConversationBubblePresented(false, reason: "hideSprite")
        setFloatingSpriteVisible(false)
    }

    private func setFloatingSpriteVisible(_ visible: Bool) {
        guard isFloatingSpriteVisible != visible else { return }
        isFloatingSpriteVisible = visible
        invalidateFloatingLayout(reason: "spriteVisible.\(visible ? "show" : "hide")")
    }

    @discardableResult
    func togglePresentation() -> Bool {
        presentationToggleSequence += 1
        return toggleConversationBubble(reason: "togglePresentation")
    }

    func openConversationBubble(reason: String) {
        setConversationBubblePresented(true, reason: reason)
    }

    @discardableResult
    func toggleConversationBubble(reason: String) -> Bool {
        setConversationBubblePresented(!isConversationBubblePresented, reason: reason)
        return isConversationBubblePresented
    }

    private func setConversationBubblePresented(_ presented: Bool, reason: String) {
        guard isConversationBubblePresented != presented else { return }
        isConversationBubblePresented = presented
        if !presented {
            // Any close clears compact auto-bubble state so the next open is the full panel.
            isCompactAutoBubble = false
            compactAutoBubbleSuggestion = nil
            autoBubbleDismissTask?.cancel()
            autoBubbleDismissTask = nil
        }
        invalidateFloatingLayout(reason: "conversationBubble.\(reason).\(presented ? "open" : "closed")")
#if DEBUG
        cmuxDebugLog("sprite.coordinator conversationBubble=\(presented ? 1 : 0) reason=\(reason)")
#endif
    }

    private func exitCompactAutoBubble() {
        autoBubbleDismissTask?.cancel()
        autoBubbleDismissTask = nil
        if isCompactAutoBubble { isCompactAutoBubble = false }
        compactAutoBubbleSuggestion = nil
    }

    private func isUserLikelyTyping() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView
    }

    /// Phase 2 Tier 2: surface a NEW high-confidence suggestion as a compact,
    /// non-activating speech bubble — at most once per suggestion id, rate-limited,
    /// never while the panel is already open or the user is typing. Gated by both
    /// the parent flag and the default-off ProactiveAutoBubbleSettings sub-flag.
    private func maybeSurfaceAutoBubble(from suggestions: [ProactiveSuggestion]) {
        guard ProactiveSpriteSuggestionsSettings.isEnabled(),
              ProactiveAutoBubbleSettings.isEnabled() else { return }
        // Bound the seen-set and allow a genuinely re-appearing suggestion to fire again.
        autoBubbleSeenSuggestionIds.formIntersection(Set(suggestions.map(\.id)))
        guard let candidate = suggestions.first(where: {
            Self.proactiveBadgeSuggestionTypes.contains($0.type)
                && $0.confidence >= Self.proactiveAutoSurfaceConfidenceFloor
                && !autoBubbleSeenSuggestionIds.contains($0.id)
        }) else { return }
        // Mark seen before the suppression guards so a suppressed suggestion is not
        // retried on every debounced recompute.
        autoBubbleSeenSuggestionIds.insert(candidate.id)
        guard !isConversationBubblePresented else { return }
        guard !isUserLikelyTyping() else { return }
        if let last = lastAutoBubbleSurfacedAt,
           Date().timeIntervalSince(last) < Self.autoBubbleMinInterval {
            return
        }
        presentAutoBubble(for: candidate)
    }

    private func presentAutoBubble(for suggestion: ProactiveSuggestion) {
        compactAutoBubbleSuggestion = suggestion
        isCompactAutoBubble = true
        setConversationBubblePresented(true, reason: "autoBubble")
        // Order the (possibly never-shown) panel front; deliberately NOT entryFocusSequence,
        // so the bubble appears without stealing key focus from the user.
        requestPresentation()
        lastAutoBubbleSurfacedAt = Date()
        autoBubbleDismissTask?.cancel()
        autoBubbleDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.autoBubbleAutoDismissNanos)
            guard let self, !Task.isCancelled, self.isCompactAutoBubble else { return }
            self.setConversationBubblePresented(false, reason: "autoBubbleTimeout")
        }
    }

    var isFloatingConversationBubbleVisible: Bool {
        isConversationBubblePresented && !isPanelEdgeRecovery
    }

    var effectiveConversationBubbleSide: SortAssistantFloatingConversationBubbleSide {
        isFloatingConversationBubbleVisible ? conversationBubbleSide : .right
    }

    func drainExternalGoal(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        guard let pending = pendingExternalGoal else { return }
        pendingExternalGoal = nil
        submit(
            pending.goal,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            externalGoal: true,
            forceApply: pending.forceApply
        )
    }

    func submit(
        _ text: String,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        submit(
            text,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            externalGoal: false,
            forceApply: false
        )
    }

    private func submit(
        _ text: String,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        externalGoal: Bool,
        forceApply: Bool
    ) {
        let trimmed = normalized(text)
        guard !trimmed.isEmpty else { return }
        let debugSession = SortAssistantDebugSession.start(
            source: externalGoal ? "externalGoal" : "entry",
            text: trimmed,
            externalGoal: externalGoal,
            forceApply: forceApply
        )
#if DEBUG
        debugLogSpriteGeometrySnapshot(
            "conversation.beforeSubmit debugSession=\(debugSession.shortId) externalGoal=\(externalGoal) forceApply=\(forceApply)"
        )
#endif
        choicePrompt = nil
        semanticActionConfirmation = nil
        pendingSemanticActionConfirmation = nil
        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        let preprocessStart = SortAssistantDebugSession.now()
        let workspaceMention = Self.workspaceMentionResolution(in: trimmed, tabManager: tabManager)
        let workspaceTarget = workspaceMention?.target
        recordContextAgentAttention(
            tabManager: tabManager,
            workspaceTarget: workspaceTarget,
            reason: "assistant.query_started",
            queryCharacterCount: trimmed.count
        )
        let routedText = effectiveRoutingText(
            from: workspaceMention?.cleanedText ?? trimmed,
            workspaceTarget: workspaceTarget
        )
        debugSession.log(
            "preprocess.end hasWorkspaceTarget=\(workspaceTarget != nil) routedChars=\(routedText.count)",
            phaseStartNanos: preprocessStart
        )
        if let command = SortAssistantSlashCommand.parse(routedText) {
            handleSlashCommand(
                command,
                originalText: trimmed,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                workspaceTarget: workspaceTarget,
                debugSession: debugSession
            )
            return
        }
        if routedText.hasPrefix("/") {
            append(.init(kind: .user, text: trimmed))
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.slash.unknown", defaultValue: "Unknown command. Try /help.")
            ))
            debugSession.finish(result: "unknownSlash")
            return
        }
        if intentRouter.immediateIntent(for: routedText, externalGoal: externalGoal) == .clearSession {
            clearCurrentSession()
            entryFocusSequence += 1
            debugSession.finish(result: "clearSession")
            return
        }
        append(.init(kind: .user, text: trimmed))

        if let intent = intentRouter.immediateIntent(for: routedText, externalGoal: externalGoal) {
            debugSession.log("router.immediate.submit intent=\(intent.rawValue)")
            handleSubmitIntent(
                intent,
                trimmed: routedText,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: forceApply,
                workspaceTarget: workspaceTarget,
                debugSession: debugSession
            )
            return
        }

        let requestId = UUID()
        pendingIntentRequestId = requestId
        let conversationContext = semanticConversationContext(workspaceTarget: workspaceTarget)
        let semanticWorkspaceDirectory = workspaceTarget?.directory ?? Self.workspaceDirectoryForMCP(tabManager: tabManager)
        let progressMessageId = append(.init(
            kind: .progress,
            text: String(localized: "sortAssistant.intent.running", defaultValue: "Understanding the request...")
        ))

        Task { [weak self, weak tabManager, weak workspaceTabStore] in
            let decision = await SortAssistantIntentRouter().semanticIntent(
                for: routedText,
                externalGoal: externalGoal,
                conversationContext: conversationContext,
                workspaceDirectory: semanticWorkspaceDirectory,
                debugSession: debugSession
            )
            guard let self else { return }
            guard self.pendingIntentRequestId == requestId else { return }
            self.pendingIntentRequestId = nil
            self.removeMessage(id: progressMessageId)
            self.appendSemanticRouterUnavailableReportIfNeeded(decision.semanticRouterUnavailableReport)
            guard let tabManager, let workspaceTabStore else { return }
            self.handleSubmitIntent(
                decision.intent,
                trimmed: routedText,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: forceApply,
                workspaceTarget: workspaceTarget,
                sortRoute: decision.sortRoute,
                routeSteps: decision.steps,
                routeAdjustment: decision.routeAdjustment,
                debugSession: debugSession
            )
        }
    }

    private func effectiveRoutingText(
        from text: String,
        workspaceTarget: SortAssistantWorkspaceTarget?
    ) -> String {
        let trimmed = normalized(text)
        if !trimmed.isEmpty {
            return trimmed
        }
        if workspaceTarget != nil {
            return String(
                localized: "sortAssistant.workspaceMention.defaultGoal",
                defaultValue: "Summarize the referenced workspace context."
            )
        }
        return trimmed
    }

    private struct WorkspaceMentionCandidate {
        let range: Range<String.Index>
        let query: String
    }

    private static func workspaceMentionResolution(
        in text: String,
        tabManager: TabManager
    ) -> SortAssistantWorkspaceMentionResolution? {
        for candidate in workspaceMentionCandidates(in: text) {
            guard let target = workspaceTarget(matching: candidate.query, tabManager: tabManager) else {
                continue
            }
            return SortAssistantWorkspaceMentionResolution(
                target: target,
                cleanedText: textRemovingWorkspaceMention(candidate.range, from: text)
            )
        }
        return nil
    }

    private static func workspaceMentionCandidates(in text: String) -> [WorkspaceMentionCandidate] {
        var candidates: [WorkspaceMentionCandidate] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "@" else {
                index = text.index(after: index)
                continue
            }

            let afterAt = text.index(after: index)
            guard afterAt < text.endIndex else { break }
            if text[afterAt] == "{" {
                let contentStart = text.index(after: afterAt)
                if let close = text[contentStart...].firstIndex(of: "}") {
                    let query = String(text[contentStart..<close])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !query.isEmpty {
                        candidates.append(WorkspaceMentionCandidate(
                            range: index..<text.index(after: close),
                            query: query
                        ))
                    }
                    index = text.index(after: close)
                    continue
                }
            }

            var end = afterAt
            while end < text.endIndex, !text[end].isWhitespace {
                end = text.index(after: end)
            }
            let query = String(text[afterAt..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !query.isEmpty {
                candidates.append(WorkspaceMentionCandidate(range: index..<end, query: query))
            }
            index = end
        }
        return candidates
    }

    private static func workspaceTarget(
        matching query: String,
        tabManager: TabManager
    ) -> SortAssistantWorkspaceTarget? {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return nil }
        let ranked = tabManager.tabs.enumerated().compactMap { index, workspace -> (Int, Workspace)? in
            guard let rank = workspaceMentionMatchRank(
                workspace: workspace,
                index: index,
                selectedWorkspaceId: tabManager.selectedTabId,
                query: normalizedQuery
            ) else {
                return nil
            }
            return (rank, workspace)
        }
        guard let workspace = ranked.sorted(by: { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1.displayTitle.localizedCaseInsensitiveCompare(rhs.1.displayTitle) == .orderedAscending
        }).first?.1 else {
            return nil
        }
        return SortAssistantWorkspaceTarget(
            id: workspace.id,
            title: workspace.displayTitle,
            directory: workspaceDirectoryForMCP(workspace: workspace)
        )
    }

    private static func selectedWorkspaceTarget(tabManager: TabManager) -> SortAssistantWorkspaceTarget? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        return SortAssistantWorkspaceTarget(
            id: workspace.id,
            title: workspace.displayTitle,
            directory: workspaceDirectoryForMCP(workspace: workspace)
        )
    }

    private static func workspaceMentionMatchRank(
        workspace: Workspace,
        index: Int,
        selectedWorkspaceId: UUID?,
        query: String
    ) -> Int? {
        let title = workspace.displayTitle.lowercased()
        let rawTitle = workspace.title.lowercased()
        let directoryName = workspaceDirectoryName(workspace)?.lowercased()
        let branch = workspace.gitBranch?.branch.lowercased()
        let id = workspace.id.uuidString.lowercased()

        if id.hasPrefix(query) { return 0 }
        if title == query || rawTitle == query { return workspace.id == selectedWorkspaceId ? 1 : 2 }
        if directoryName == query { return 3 }
        if branch == query { return 4 }
        if title.hasPrefix(query) || rawTitle.hasPrefix(query) { return 10 + index }
        if directoryName?.hasPrefix(query) == true { return 20 + index }
        if branch?.hasPrefix(query) == true { return 30 + index }
        if title.contains(query) || rawTitle.contains(query) { return 40 + index }
        if directoryName?.contains(query) == true { return 50 + index }
        if branch?.contains(query) == true { return 60 + index }
        return nil
    }

    private static func workspaceDirectoryName(_ workspace: Workspace) -> String? {
        guard let directory = workspaceDirectoryForMCP(workspace: workspace) else { return nil }
        let name = URL(fileURLWithPath: directory).lastPathComponent
        return name.isEmpty ? directory : name
    }

    private static func textRemovingWorkspaceMention(
        _ range: Range<String.Index>,
        from text: String
    ) -> String {
        var output = text
        output.replaceSubrange(range, with: " ")
        return output
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func handleSlashCommand(
        _ command: SortAssistantSlashCommand,
        originalText: String,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        workspaceTarget: SortAssistantWorkspaceTarget?,
        debugSession: SortAssistantDebugSession
    ) {
        var completesSynchronously = true
        defer {
            if completesSynchronously {
                debugSession.finish(result: "slashSync", details: "command=\(command.name)")
            }
        }
        debugSession.log("slash.begin command=\(command.name) argumentChars=\(command.argument.count)")
        switch command.operation {
        case .clearSession:
            clearCurrentSession()
            entryFocusSequence += 1
        case .help:
            append(.init(kind: .user, text: originalText))
            append(.init(kind: .assistant, text: Self.slashHelpText()))
        case .askContext(let goal):
            append(.init(kind: .user, text: originalText))
            handleSubmitIntent(
                .askContext,
                trimmed: goal,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget,
                debugSession: debugSession
            )
            completesSynchronously = false
        case .undoSort:
            append(.init(kind: .user, text: originalText))
            handleSubmitIntent(
                .undoSort,
                trimmed: String(localized: "sortAssistant.slash.undo.goal", defaultValue: "Undo the latest assistant sort."),
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget,
                debugSession: debugSession
            )
            completesSynchronously = false
        case .explainCurrentOrder(let goal):
            append(.init(kind: .user, text: originalText))
            handleSubmitIntent(
                .explainCurrentOrder,
                trimmed: goal,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget,
                debugSession: debugSession
            )
            completesSynchronously = false
        case .proposeSort(let goal):
            append(.init(kind: .user, text: originalText))
            if let sort = Self.fixedSortCommand(argument: goal) {
                runFixedSortCommand(
                    sort,
                    goal: goal,
                    mode: .preview,
                    tabManager: tabManager,
                    workspaceTabStore: workspaceTabStore
                )
                return
            }
            resolveSortRouteThenSubmit(
                .proposeSort,
                trimmed: goal,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget,
                explicitSlashCommand: true,
                debugSession: debugSession
            )
            completesSynchronously = false
        case .applySort(let goal):
            append(.init(kind: .user, text: originalText))
            if let sort = Self.fixedSortCommand(argument: goal) {
                runFixedSortCommand(
                    sort,
                    goal: goal,
                    mode: .apply,
                    tabManager: tabManager,
                    workspaceTabStore: workspaceTabStore
                )
                return
            }
            resolveSortRouteThenSubmit(
                .applySort,
                trimmed: goal,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: true,
                workspaceTarget: workspaceTarget,
                explicitSlashCommand: true,
                debugSession: debugSession
            )
            completesSynchronously = false
        case .listSortMemories:
            append(.init(kind: .user, text: originalText))
            startMCPAssistant(
                goal: String(localized: "sortAssistant.slash.memory.goal", defaultValue: "List saved free-sort memories."),
                intent: .normalChat,
                route: SortAssistantActionRoute(
                    mode: .readOnly,
                    needsConfirmation: false,
                    allowedTools: ["memory_query"],
                    memoryWritePolicy: .none
                ),
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                workspaceTarget: workspaceTarget,
                debugSession: debugSession
            )
            completesSynchronously = false
        case .listSpriteMemories:
            append(.init(kind: .user, text: originalText))
            startMCPAssistant(
                goal: String(localized: "sortAssistant.slash.memorySprite.goal", defaultValue: "List saved sprite workspace memories."),
                intent: .normalChat,
                route: SortAssistantActionRoute(
                    mode: .readOnly,
                    needsConfirmation: false,
                    allowedTools: ["sprite_memory_query"],
                    memoryWritePolicy: .none
                ),
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                workspaceTarget: workspaceTarget,
                debugSession: debugSession
            )
            completesSynchronously = false
        case .rememberSpriteMemory(let text):
            guard !text.isEmpty else {
                appendSlashUsage(originalText: originalText, usage: "/remember-sprite <memory>")
                return
            }
            append(.init(kind: .user, text: originalText))
            handleSubmitIntent(
                .rememberSpriteMemory,
                trimmed: text,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget,
                debugSession: debugSession
            )
            completesSynchronously = false
        case .forgetSpriteMemory(let text):
            guard !text.isEmpty else {
                appendSlashUsage(originalText: originalText, usage: "/forget-sprite <memory-id-or-text>")
                return
            }
            append(.init(kind: .user, text: originalText))
            handleSubmitIntent(
                .forgetSpriteMemory,
                trimmed: text,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget,
                debugSession: debugSession
            )
            completesSynchronously = false
        case .rememberFreeSortMemory(let text):
            guard !text.isEmpty else {
                appendSlashUsage(originalText: originalText, usage: "/remember <sorting preference>")
                return
            }
            append(.init(kind: .user, text: originalText))
            handleSubmitIntent(
                .rememberPreference,
                trimmed: text,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget,
                debugSession: debugSession
            )
            completesSynchronously = false
        case .forgetFreeSortMemory(let text):
            guard !text.isEmpty else {
                appendSlashUsage(originalText: originalText, usage: "/forget <memory-id-or-text>")
                return
            }
            append(.init(kind: .user, text: originalText))
            handleSubmitIntent(
                .forgetPreference,
                trimmed: text,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: false,
                workspaceTarget: workspaceTarget,
                debugSession: debugSession
            )
            completesSynchronously = false
        case .monitor(let monitorCommand):
            handleMonitorCommand(
                monitorCommand,
                originalText: originalText,
                tabManager: tabManager,
                workspaceTarget: workspaceTarget
            )
        case .setPinned(let pinned):
            append(.init(kind: .user, text: originalText))
            guard command.argument.isEmpty || workspaceTarget != nil else {
                appendWorkspaceCommandTargetError()
                return
            }
            guard let target = workspaceTarget ?? Self.selectedWorkspaceTarget(tabManager: tabManager),
                  let workspace = tabManager.tabs.first(where: { $0.id == target.id }) else {
                appendWorkspaceCommandUnavailable()
                return
            }
            applyPinnedSlashCommand(
                workspace,
                title: target.title,
                pinned: pinned,
                tabManager: tabManager
            )
        case .setLocked(let locked):
            append(.init(kind: .user, text: originalText))
            guard command.argument.isEmpty || workspaceTarget != nil else {
                appendWorkspaceCommandTargetError()
                return
            }
            guard let target = workspaceTarget ?? Self.selectedWorkspaceTarget(tabManager: tabManager) else {
                appendWorkspaceCommandUnavailable()
                return
            }
            applyLockedSlashCommand(
                itemId: target.id,
                title: target.title,
                locked: locked
            )
        case .selectWorkspace:
            append(.init(kind: .user, text: originalText))
            guard let target = workspaceTarget,
                  let workspace = tabManager.tabs.first(where: { $0.id == target.id }) else {
                append(.init(
                    kind: .error,
                    text: String(localized: "sortAssistant.slash.select.usage", defaultValue: "Usage: /select @workspace")
                ))
                return
            }
            applySelectSlashCommand(
                workspace,
                title: target.title,
                tabManager: tabManager
            )
        }
    }

    private func resolveSortRouteThenSubmit(
        _ intent: SortAssistantIntent,
        trimmed goal: String,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        forceApply: Bool,
        workspaceTarget: SortAssistantWorkspaceTarget?,
        explicitSlashCommand: Bool = false,
        debugSession: SortAssistantDebugSession
    ) {
        let routingText = Self.semanticSortRoutingText(goal: goal, intent: intent)
        let requestId = UUID()
        pendingIntentRequestId = requestId
        let conversationContext = semanticConversationContext(workspaceTarget: workspaceTarget)
        let semanticWorkspaceDirectory = workspaceTarget?.directory ?? Self.workspaceDirectoryForMCP(tabManager: tabManager)
        debugSession.log(
            "router.semantic.begin source=slashSort intent=\(intent.rawValue)"
        )
        let progressMessageId = append(.init(
            kind: .progress,
            text: String(localized: "sortAssistant.intent.running", defaultValue: "Understanding the request...")
        ))

        Task { [weak self, weak tabManager, weak workspaceTabStore] in
            let decision = await SortAssistantIntentRouter().semanticIntent(
                for: routingText,
                externalGoal: forceApply,
                conversationContext: conversationContext,
                workspaceDirectory: semanticWorkspaceDirectory,
                debugSession: debugSession
            )
            guard let self else { return }
            guard self.pendingIntentRequestId == requestId else { return }
            self.pendingIntentRequestId = nil
            self.removeMessage(id: progressMessageId)
            self.appendSemanticRouterUnavailableReportIfNeeded(decision.semanticRouterUnavailableReport)
            guard let tabManager, let workspaceTabStore else { return }
            let resolvedSortRoute = decision.steps.first { $0.intent.isSortRouted }?.sortRoute ?? decision.sortRoute
            self.handleSubmitIntent(
                intent,
                trimmed: goal,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                forceApply: forceApply,
                workspaceTarget: workspaceTarget,
                sortRoute: resolvedSortRoute,
                routeSteps: [SortAssistantRouteStep(intent: intent, sortRoute: resolvedSortRoute)],
                routeAdjustment: decision.routeAdjustment,
                explicitSlashCommand: explicitSlashCommand,
                debugSession: debugSession
            )
        }
    }

    private static func semanticSortRoutingText(
        goal: String,
        intent: SortAssistantIntent
    ) -> String {
        let action = intent == .applySort ? "Apply a workspace sort" : "Preview a workspace sort"
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return action }
        return "\(action): \(trimmed)"
    }

    private func handleMonitorCommand(
        _ command: SortAssistantMonitorCommand,
        originalText: String,
        tabManager: TabManager,
        workspaceTarget: SortAssistantWorkspaceTarget?
    ) {
        append(.init(kind: .user, text: originalText))
        let target = workspaceTarget ?? Self.selectedWorkspaceTarget(tabManager: tabManager)
        switch command.action {
        case .add(let condition, let interval):
            guard !condition.isEmpty else {
                append(.init(
                    kind: .error,
                    text: String(
                        localized: "sortAssistant.monitor.usage",
                        defaultValue: "Usage: /monitor [every 30s] <status text>"
                    )
                ))
                return
            }
            guard let target else {
                appendWorkspaceCommandUnavailable()
                return
            }
            let snapshot = SortAssistantWorkspaceMonitorCenter.shared.add(
                workspaceId: target.id,
                workspaceTitle: target.title,
                condition: condition,
                interval: interval
            )
            append(.init(
                kind: .assistant,
                text: String(
                    format: String(
                        localized: "sortAssistant.monitor.added",
                        defaultValue: "Monitoring %@ every %@ for: %@\nID: %@"
                    ),
                    target.title,
                    Self.monitorIntervalText(snapshot.interval),
                    snapshot.condition,
                    snapshot.shortId
                )
            ))
        case .list:
            guard let target else {
                appendWorkspaceCommandUnavailable()
                return
            }
            let monitors = SortAssistantWorkspaceMonitorCenter.shared.list(workspaceId: target.id)
            guard !monitors.isEmpty else {
                append(.init(
                    kind: .assistant,
                    text: String(
                        format: String(
                            localized: "sortAssistant.monitor.none",
                            defaultValue: "No active monitors for %@."
                        ),
                        target.title
                    )
                ))
                return
            }
            let rows = monitors.map { monitor in
                String(
                    format: String(
                        localized: "sortAssistant.monitor.list.row",
                        defaultValue: "- %@ %@: every %@, %@"
                    ),
                    monitor.shortId,
                    monitor.workspaceTitle,
                    Self.monitorIntervalText(monitor.interval),
                    monitor.condition
                )
            }
            append(.init(
                kind: .assistant,
                text: String(
                    format: String(
                        localized: "sortAssistant.monitor.list.header",
                        defaultValue: "Active monitors for %@:"
                    ),
                    target.title
                ) + "\n" + rows.joined(separator: "\n")
            ))
        case .stop(let selector):
            guard let target else {
                appendWorkspaceCommandUnavailable()
                return
            }
            let count = SortAssistantWorkspaceMonitorCenter.shared.stop(
                workspaceId: target.id,
                selector: selector
            )
            let message = count == 0
                ? String(localized: "sortAssistant.monitor.stop.none", defaultValue: "No matching monitors found.")
                : String(
                    format: String(
                        localized: "sortAssistant.monitor.stop.done",
                        defaultValue: "Stopped %d monitor(s)."
                    ),
                    count
                )
            append(.init(kind: .assistant, text: message))
        }
    }

    private static func monitorIntervalText(_ interval: TimeInterval) -> String {
        let seconds = max(1, Int(interval.rounded()))
        if seconds % 3600 == 0 {
            return String(
                format: String(localized: "sortAssistant.monitor.interval.hours", defaultValue: "%d h"),
                seconds / 3600
            )
        }
        if seconds % 60 == 0 {
            return String(
                format: String(localized: "sortAssistant.monitor.interval.minutes", defaultValue: "%d min"),
                seconds / 60
            )
        }
        return String(
            format: String(localized: "sortAssistant.monitor.interval.seconds", defaultValue: "%d s"),
            seconds
        )
    }

    private func appendSlashUsage(originalText: String, usage: String) {
        append(.init(kind: .user, text: originalText))
        append(.init(
            kind: .error,
            text: String(localized: "sortAssistant.slash.usage", defaultValue: "Usage: \(usage)")
        ))
    }

    private func appendWorkspaceCommandTargetError() {
        append(.init(
            kind: .error,
            text: String(
                localized: "sortAssistant.slash.workspaceTargetRequired",
                defaultValue: "Use @workspace to target a workspace, or omit the argument to use the current workspace."
            )
        ))
    }

    private func appendWorkspaceCommandUnavailable() {
        append(.init(
            kind: .error,
            text: String(
                localized: "sortAssistant.slash.workspaceUnavailable",
                defaultValue: "No matching workspace is available."
            )
        ))
    }

    private static func slashHelpText() -> String {
        let commandLines = SortAssistantSlashCommand.descriptors.map { descriptor in
            "- \(descriptor.displayText): \(descriptor.summary)"
        }
        let workspaceLine = String(
            localized: "sortAssistant.slash.workspaceMention.help",
            defaultValue: "Use @workspace with commands or questions to target a specific workspace."
        )
        return ([workspaceLine] + commandLines).joined(separator: "\n")
    }

    private static func fixedSortCommand(argument: String) -> WorkspaceSidebarSummaryPrioritySort? {
        let normalized = argument
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "recent", "recentactivity", "recentuse", "recentlyused", "lastused", "mru", "最近", "最近使用", "最近使用顺序":
            return .recent
        case "native", "nativeorder", "manual", "manualorder", "current", "currentorder", "default", "原始", "当前", "手动":
            return .native
        default:
            return nil
        }
    }

    private func runFixedSortCommand(
        _ sort: WorkspaceSidebarSummaryPrioritySort,
        goal: String,
        mode: SortAssistantRunMode,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        guard !isSorting else {
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.sort.busy", defaultValue: "A workspace sort is already running.")
            ))
            return
        }

        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        let orderedIds = Self.fixedSortWorkspaceOrder(
            sort,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
        guard !orderedIds.isEmpty else {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.sort.noOrder", defaultValue: "Digest returned no applicable workspace order.")
            ))
            return
        }

        let label = Self.dimensionLabel(sort)
        let patch = sortOperator.makeBatchPatch(
            orderedIds: orderedIds,
            tabs: tabManager.tabs,
            rationale: Self.fixedSortRationale(sort),
            confidence: nil,
            requiresConfirmation: mode == .preview
        )
        let itemSignals = contextProvider.itemSignals(tabManager: tabManager, workspaceTabStore: workspaceTabStore)

        do {
            switch mode {
            case .preview:
                let preview = try sortOperator.preview(
                    patch: patch,
                    tabs: tabManager.tabs,
                    itemSignals: itemSignals
                )
                pendingPreviewPatch = patch
                pendingPreviewSort = sort
                let result = SortAssistantSortResult(
                    title: String(localized: "sortAssistant.preview.title", defaultValue: "Preview sorted by \(label)"),
                    goal: goal,
                    dimensionLabel: label,
                    changes: preview.changes,
                    rationale: preview.rationale,
                    patchId: patch.id,
                    mode: .preview,
                    canUndo: false,
                    canApply: true,
                    canApplyPartially: true,
                    canIgnore: true,
                    actions: Self.allowedResultActions(for: .preview)
                )
                let anchorMessageId = append(.init(
                    kind: .assistant,
                    text: String(localized: "sortAssistant.preview.ready", defaultValue: "I prepared a sort preview.")
                ))
                setLatestResult(result, anchorMessageId: anchorMessageId)
            case .apply:
                let applied = try applySortPatchThroughGateway(
                    patch,
                    tabManager: tabManager,
                    itemSignals: itemSignals,
                    actor: "sort_assistant_fixed_sort"
                )
                finishAppliedSortResult(
                    applied,
                    label: label,
                    goal: goal,
                    patch: patch,
                    actions: Self.allowedResultActions(for: .apply),
                    workspaceTabStore: workspaceTabStore,
                    sortToSelect: sort
                )
            }
        } catch let reviewError as SemanticActionReviewError {
            if queueSemanticActionConfirmation(
                for: reviewError,
                actionName: Self.semanticActionDisplayName(.applySort),
                confirm: { [weak self, weak tabManager, weak workspaceTabStore] in
                    guard let self, let tabManager, let workspaceTabStore else { return }
                    do {
                        let applied = try self.executeConfirmedSortPatch(
                            patch,
                            tabManager: tabManager,
                            itemSignals: itemSignals,
                            actor: "sort_assistant_fixed_sort_confirmed",
                            intent: reviewError.intent
                        )
                        self.finishAppliedSortResult(
                            applied,
                            label: label,
                            goal: goal,
                            patch: patch,
                            actions: Self.allowedResultActions(for: .apply),
                            workspaceTabStore: workspaceTabStore,
                            sortToSelect: sort
                        )
                    } catch {
                        self.append(.init(
                            kind: .error,
                            text: String(localized: "sortAssistant.sort.failed", defaultValue: "Sort failed: ") + Self.displayMessage(for: error)
                        ))
                    }
                }
            ) {
                return
            }
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.sort.failed", defaultValue: "Sort failed: ") + Self.displayMessage(for: reviewError)
            ))
        } catch {
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.sort.failed", defaultValue: "Sort failed: ") + Self.displayMessage(for: error)
            ))
        }
    }

    private static func fixedSortWorkspaceOrder(
        _ sort: WorkspaceSidebarSummaryPrioritySort,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) -> [UUID] {
        let currentIds = tabManager.tabs.map(\.id)
        if sort.isRecent {
            return recentWorkspaceOrder(
                currentWorkspaceIds: currentIds,
                recentWorkspaceIds: workspaceTabStore.recentWorkspaceIds
            )
        }
        return currentIds
    }

    private static func recentWorkspaceOrder(
        currentWorkspaceIds: [UUID],
        recentWorkspaceIds: [UUID]
    ) -> [UUID] {
        let nativeOrderById = Dictionary(uniqueKeysWithValues: currentWorkspaceIds.enumerated().map { index, id in
            (id, index)
        })
        var recentOrderById: [UUID: Int] = [:]
        for (index, id) in recentWorkspaceIds.enumerated() where recentOrderById[id] == nil {
            recentOrderById[id] = index
        }
        return currentWorkspaceIds.sorted { lhs, rhs in
            switch (recentOrderById[lhs], recentOrderById[rhs]) {
            case let (lhsOrder?, rhsOrder?):
                return lhsOrder < rhsOrder
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return (nativeOrderById[lhs] ?? 0) < (nativeOrderById[rhs] ?? 0)
            }
        }
    }

    private static func fixedSortRationale(_ sort: WorkspaceSidebarSummaryPrioritySort) -> String {
        if sort.isRecent {
            return String(
                localized: "sortAssistant.sort.recentRationale",
                defaultValue: "Sort workspaces by most recent selection."
            )
        }
        return String(
            localized: "sortAssistant.sort.nativeRationale",
            defaultValue: "Keep the current native workspace order."
        )
    }

    private enum ColorGroupUncoloredPlacement {
        case first
        case last
    }

    private struct ColorGroupSortRequest {
        let colorOrder: [String]
        let uncoloredPlacement: ColorGroupUncoloredPlacement
        let hasResolvedUncoloredPlacement: Bool
    }

    private func handleColorGroupSortIfNeeded(
        goal: String,
        mode: SortAssistantRunMode,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        sortRoute: SortAssistantSortRoute? = nil,
        explicitSlashCommand: Bool = false,
        debugSession: SortAssistantDebugSession
    ) -> Bool {
        let phaseStart = SortAssistantDebugSession.now()
        let isSemanticColorGroup = sortRoute == .colorGroup
        guard isSemanticColorGroup else { return false }
        reloadFreeSortMemories(reason: "colorGroup")
        guard let request = Self.colorGroupSortRequest(
            from: goal,
            tabs: tabManager.tabs,
            memories: memories,
            allowSemanticColorGroup: isSemanticColorGroup
        ) else {
            return false
        }
#if DEBUG
        let debugColorOrder = request.colorOrder.joined(separator: ",")
        cmuxDebugLog(
            "sprite.memory colorGroup resolved colorOrder=\(debugColorOrder) uncolored=\(String(describing: request.uncoloredPlacement)) hasColorOrder=\(!request.colorOrder.isEmpty) hasUncolored=\(request.hasResolvedUncoloredPlacement) memoryCount=\(memories.count)"
        )
#endif
        guard !Self.observedWorkspaceColors(tabManager.tabs).isEmpty else {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.colorGroup.noColors", defaultValue: "No workspace colors are available to group.")
            ))
            debugSession.log("local.colorGroup.noColors", phaseStartNanos: phaseStart)
            return true
        }

        let prompt = Self.colorGroupChoicePrompt(
            request: request,
            goal: goal,
            mode: mode,
            tabs: tabManager.tabs,
            explicitSlashCommand: explicitSlashCommand
        )
        if let prompt {
            latestResult = nil
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            append(.init(
                kind: .assistant,
                text: String(
                    localized: "sortAssistant.choice.colorOrder.prompt",
                    defaultValue: "Group by color - choose the missing details."
                )
            ))
            choicePrompt = prompt
            debugSession.log(
                "local.colorGroup.choicePrompt questions=\(prompt.questions.count) options=\(prompt.options.count)",
                phaseStartNanos: phaseStart
            )
            return true
        }

        runColorGroupSortCommand(
            request,
            goal: goal,
            mode: mode,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            debugSession: debugSession,
            phaseStartNanos: phaseStart
        )
        return true
    }

    private func runColorGroupSortCommand(
        _ request: ColorGroupSortRequest,
        goal: String,
        mode: SortAssistantRunMode,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        debugSession: SortAssistantDebugSession,
        phaseStartNanos: UInt64
    ) {
        guard !isSorting else {
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.sort.busy", defaultValue: "A workspace sort is already running.")
            ))
            debugSession.log("local.colorGroup.busy", phaseStartNanos: phaseStartNanos)
            return
        }

        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        let orderedIds = Self.colorGroupedWorkspaceOrder(request: request, tabs: tabManager.tabs)
        guard !orderedIds.isEmpty else {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.colorGroup.noColors", defaultValue: "No workspace colors are available to group.")
            ))
            debugSession.log("local.colorGroup.noOrder", phaseStartNanos: phaseStartNanos)
            return
        }

        let label = String(localized: "sortAssistant.dimension.color", defaultValue: "Color")
        let patch = sortOperator.makeBatchPatch(
            orderedIds: orderedIds,
            tabs: tabManager.tabs,
            rationale: Self.colorGroupRationale(request),
            confidence: nil,
            requiresConfirmation: mode == .preview
        )
        let itemSignals = contextProvider.itemSignals(tabManager: tabManager, workspaceTabStore: workspaceTabStore)

        do {
            switch mode {
            case .preview:
                let preview = try sortOperator.preview(
                    patch: patch,
                    tabs: tabManager.tabs,
                    itemSignals: itemSignals
                )
                pendingPreviewPatch = patch
                pendingPreviewSort = .native
                let result = SortAssistantSortResult(
                    title: String(localized: "sortAssistant.preview.title", defaultValue: "Preview sorted by \(label)"),
                    goal: goal,
                    dimensionLabel: label,
                    changes: preview.changes,
                    rationale: preview.rationale,
                    patchId: patch.id,
                    mode: .preview,
                    canUndo: false,
                    canApply: true,
                    canApplyPartially: true,
                    canIgnore: true,
                    actions: Self.allowedResultActions(for: .preview)
                )
                let anchorMessageId = append(.init(
                    kind: .assistant,
                    text: String(localized: "sortAssistant.preview.ready", defaultValue: "I prepared a sort preview.")
                ))
                setLatestResult(result, anchorMessageId: anchorMessageId)
                debugSession.log(
                    "local.colorGroup.end mode=preview changes=\(preview.changes.count)",
                    phaseStartNanos: phaseStartNanos
                )
            case .apply:
                let applied = try applySortPatchThroughGateway(
                    patch,
                    tabManager: tabManager,
                    itemSignals: itemSignals,
                    actor: "sort_assistant_color_group"
                )
                finishAppliedSortResult(
                    applied,
                    label: label,
                    goal: goal,
                    patch: patch,
                    actions: Self.allowedResultActions(for: .apply),
                    workspaceTabStore: workspaceTabStore,
                    sortToSelect: .native
                )
                debugSession.log(
                    "local.colorGroup.end mode=apply changes=\(applied.preview.changes.count)",
                    phaseStartNanos: phaseStartNanos
                )
            }
        } catch let reviewError as SemanticActionReviewError {
            if queueSemanticActionConfirmation(
                for: reviewError,
                actionName: Self.semanticActionDisplayName(.applySort),
                confirm: { [weak self, weak tabManager, weak workspaceTabStore] in
                    guard let self, let tabManager, let workspaceTabStore else { return }
                    do {
                        let applied = try self.executeConfirmedSortPatch(
                            patch,
                            tabManager: tabManager,
                            itemSignals: itemSignals,
                            actor: "sort_assistant_color_group_confirmed",
                            intent: reviewError.intent
                        )
                        self.finishAppliedSortResult(
                            applied,
                            label: label,
                            goal: goal,
                            patch: patch,
                            actions: Self.allowedResultActions(for: .apply),
                            workspaceTabStore: workspaceTabStore,
                            sortToSelect: .native
                        )
                        debugSession.log(
                            "local.colorGroup.end mode=applyConfirmed changes=\(applied.preview.changes.count)",
                            phaseStartNanos: phaseStartNanos
                        )
                    } catch {
                        self.append(.init(
                            kind: .error,
                            text: String(localized: "sortAssistant.sort.failed", defaultValue: "Sort failed: ") + Self.displayMessage(for: error)
                        ))
                        debugSession.log(
                            "local.colorGroup.failed error=\(SortAssistantDebugSession.errorSummary(error))",
                            phaseStartNanos: phaseStartNanos
                        )
                    }
                }
            ) {
                return
            }
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.sort.failed", defaultValue: "Sort failed: ") + Self.displayMessage(for: reviewError)
            ))
            debugSession.log(
                "local.colorGroup.failed error=\(SortAssistantDebugSession.errorSummary(reviewError))",
                phaseStartNanos: phaseStartNanos
            )
        } catch {
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.sort.failed", defaultValue: "Sort failed: ") + Self.displayMessage(for: error)
            ))
            debugSession.log(
                "local.colorGroup.failed error=\(SortAssistantDebugSession.errorSummary(error))",
                phaseStartNanos: phaseStartNanos
            )
        }
    }

    private static func colorGroupSortRequest(
        from goal: String,
        tabs: [Workspace],
        memories: [SortAssistantMemory] = [],
        allowSemanticColorGroup: Bool = false
    ) -> ColorGroupSortRequest? {
        guard !tabs.isEmpty else { return nil }
        guard allowSemanticColorGroup || isColorGroupGoal(goal) else { return nil }
        let explicitColorOrder = mentionedColorOrder(in: goal)
        let explicitUncoloredPlacement = mentionedUncoloredPlacement(in: goal)
        let memoryDefaults = colorGroupMemoryDefaults(memories: memories, tabs: tabs)
        let colorOrder = explicitColorOrder.isEmpty ? memoryDefaults.colorOrder : explicitColorOrder
        let uncoloredPlacement = explicitUncoloredPlacement ?? memoryDefaults.uncoloredPlacement
        return ColorGroupSortRequest(
            colorOrder: colorOrder,
            uncoloredPlacement: uncoloredPlacement ?? .last,
            hasResolvedUncoloredPlacement: uncoloredPlacement != nil
        )
    }

    private static func colorGroupMemoryDefaults(
        memories: [SortAssistantMemory],
        tabs: [Workspace]
    ) -> (colorOrder: [String], uncoloredPlacement: ColorGroupUncoloredPlacement?) {
        let observedColors = Set(observedWorkspaceColors(tabs))
        var colorOrder: [String] = []
        var uncoloredPlacement: ColorGroupUncoloredPlacement?

        for memory in memories where isColorGroupGoal(memory.text) {
            if colorOrder.isEmpty {
                colorOrder = mentionedColorOrder(in: memory.text)
                    .filter { observedColors.contains($0) }
            }
            if uncoloredPlacement == nil {
                uncoloredPlacement = mentionedUncoloredPlacement(in: memory.text)
            }
            if !colorOrder.isEmpty, uncoloredPlacement != nil {
                break
            }
        }

        return (colorOrder, uncoloredPlacement)
    }

    private static func isColorGroupGoal(_ goal: String) -> Bool {
        let normalized = normalizedColorCommandText(goal)
        let mentionsColor = normalized.contains(" color ")
            || normalized.contains(" colour ")
            || normalized.contains(" 颜色 ")
            || normalized.contains(" 顏色 ")
        guard mentionsColor else { return false }
        return colorCommandTextContainsAny(normalized, [
            " group ", " grouped ", " cluster ", " sort ", " order ", " arrange ", " reorder ",
            " 分组 ", " 分組 ", " 归类 ", " 歸類 ", " 排序 ", " 重排 ", " 按 "
        ])
    }

    private static func mentionedColorOrder(in goal: String) -> [String] {
        var matches: [(offset: Int, hex: String)] = []
        let nsGoal = goal as NSString
        if let regex = try? NSRegularExpression(pattern: "#?[0-9A-Fa-f]{6}") {
            let range = NSRange(location: 0, length: nsGoal.length)
            for match in regex.matches(in: goal, options: [], range: range) {
                let raw = nsGoal.substring(with: match.range)
                if let hex = WorkspaceTabColorSettings.normalizedHex(raw) {
                    matches.append((match.range.location, hex))
                }
            }
        }

        let normalizedGoal = normalizedColorCommandText(goal)
        let normalizedNSString = normalizedGoal as NSString
        for entry in WorkspaceTabColorSettings.palette() {
            let token = normalizedColorCommandText(entry.name)
            let search = token
            let range = normalizedNSString.range(of: search)
            guard range.location != NSNotFound,
                  let hex = WorkspaceTabColorSettings.normalizedHex(entry.hex) else {
                continue
            }
            matches.append((range.location, hex))
        }

        var seen: Set<String> = []
        return matches
            .sorted { lhs, rhs in lhs.offset < rhs.offset }
            .map(\.hex)
            .filter { seen.insert($0).inserted }
    }

    private static func mentionedUncoloredPlacement(in goal: String) -> ColorGroupUncoloredPlacement? {
        let normalized = normalizedColorCommandText(goal)
        let uncoloredTokens = [
            " uncolored ", " uncoloured ", " no color ", " no colour ", " without color ", " without colour ",
            " unset color ", " no custom color ", " 无颜色 ", " 無顏色 ", " 没有颜色 ", " 沒有顏色 ", " 未设置颜色 ", " 未設定顏色 "
        ]
        guard colorCommandTextContainsAny(normalized, uncoloredTokens) else {
            return nil
        }
        if colorCommandTextContainsAny(normalized, [" first ", " top ", " before ", " above ", " 第一 ", " 顶部 ", " 頂部 ", " 前面 "]) {
            return .first
        }
        if colorCommandTextContainsAny(normalized, [" last ", " bottom ", " after ", " below ", " end ", " 最后 ", " 最後 ", " 底部 ", " 后面 ", " 後面 "]) {
            return .last
        }
        return nil
    }

    private static func colorGroupChoicePrompt(
        request: ColorGroupSortRequest,
        goal: String,
        mode: SortAssistantRunMode,
        tabs: [Workspace],
        explicitSlashCommand: Bool = false
    ) -> SortAssistantChoicePrompt? {
        let observedColors = observedWorkspaceColors(tabs)
        let hasUncolored = tabs.contains { normalizedWorkspaceColor($0.customColor) == nil }
        let baseGoal = colorGroupFollowUpGoal(request: request)
        var questions: [SortAssistantChoicePrompt.Question] = []

        if observedColors.count > 1, request.colorOrder.isEmpty {
            questions.append(SortAssistantChoicePrompt.Question(
                id: "color_order",
                title: String(localized: "sortAssistant.choice.colorOrder.title", defaultValue: "Which color should come first?"),
                message: String(localized: "sortAssistant.choice.colorOrder.message", defaultValue: "Remaining colors keep their current relative order."),
                options: observedColors.enumerated().map { index, hex in
                    let label = colorDisplayName(hex)
                    return SortAssistantChoicePrompt.Option(
                        id: "color-\(index + 1)-first",
                        title: String(
                            format: String(localized: "sortAssistant.choice.colorFirst.title", defaultValue: "%@ first"),
                            label
                        ),
                        subtitle: String(
                            format: String(localized: "sortAssistant.choice.colorFirst.subtitle", defaultValue: "%@ workspaces at the top."),
                            label
                        ),
                        goal: "Group by color with \(label) (\(hex)) first. Keep remaining color groups after it in their current relative order. \(uncoloredPlacementGoal(request.uncoloredPlacement))"
                    )
                }
            ))
        }

        if hasUncolored, !request.hasResolvedUncoloredPlacement {
            questions.append(SortAssistantChoicePrompt.Question(
                id: "uncolored_placement",
                title: String(localized: "sortAssistant.choice.uncolored.title", defaultValue: "Where should uncolored workspaces go?"),
                message: nil,
                options: [
                    SortAssistantChoicePrompt.Option(
                        id: "uncolored_last",
                        title: String(localized: "sortAssistant.choice.uncolored.last.title", defaultValue: "Uncolored last"),
                        subtitle: String(localized: "sortAssistant.choice.uncolored.last.subtitle", defaultValue: "Colored groups stay above uncolored workspaces."),
                        goal: "\(baseGoal) Place uncolored workspaces last."
                    ),
                    SortAssistantChoicePrompt.Option(
                        id: "uncolored_first",
                        title: String(localized: "sortAssistant.choice.uncolored.first.title", defaultValue: "Uncolored first"),
                        subtitle: String(localized: "sortAssistant.choice.uncolored.first.subtitle", defaultValue: "Uncolored workspaces stay above colored groups."),
                        goal: "\(baseGoal) Place uncolored workspaces first."
                    ),
                ]
            ))
        }

        guard !questions.isEmpty else { return nil }
        return SortAssistantChoicePrompt(
            title: String(localized: "sortAssistant.choice.colorDetails.title", defaultValue: "Sort by color"),
            message: colorGroupPromptMessage(colors: observedColors, hasUncolored: hasUncolored),
            options: questions.first?.options ?? [],
            questions: questions,
            followUpIntent: mode == .apply ? .applySort : .proposeSort,
            forceApply: mode == .apply,
            explicitSlashCommand: explicitSlashCommand
        )
    }

    private static func colorGroupFollowUpGoal(request: ColorGroupSortRequest) -> String {
        if let firstColor = request.colorOrder.first {
            let label = colorDisplayName(firstColor)
            return "Group by color with \(label) (\(firstColor)) first. Keep remaining color groups after it in their current relative order."
        }
        return "Group by color using the current relative color order."
    }

    private static func uncoloredPlacementGoal(_ placement: ColorGroupUncoloredPlacement) -> String {
        switch placement {
        case .first:
            return "Place uncolored workspaces first."
        case .last:
            return "Place uncolored workspaces last."
        }
    }

    private static func colorGroupPromptMessage(colors: [String], hasUncolored: Bool) -> String {
        var labels = colors.map(colorDisplayName)
        if hasUncolored {
            labels.append(String(localized: "sortAssistant.colorGroup.uncolored", defaultValue: "Uncolored"))
        }
        let summary = labels.isEmpty
            ? String(localized: "sortAssistant.colorGroup.noColorSummary", defaultValue: "No color groups found.")
            : labels.joined(separator: ", ")
        return String(
            format: String(localized: "sortAssistant.choice.colorDetails.message", defaultValue: "Current groups: %@."),
            summary
        )
    }

    private static func colorGroupedWorkspaceOrder(
        request: ColorGroupSortRequest,
        tabs: [Workspace]
    ) -> [UUID] {
        guard !tabs.isEmpty else { return [] }
        let observedColors = observedWorkspaceColors(tabs)
        let hasUncolored = tabs.contains { normalizedWorkspaceColor($0.customColor) == nil }

        var groupOrder: [String?] = []
        if request.uncoloredPlacement == .first, hasUncolored {
            groupOrder.append(nil)
        }

        var seenColors: Set<String> = []
        for color in request.colorOrder where observedColors.contains(color) && seenColors.insert(color).inserted {
            groupOrder.append(color)
        }
        for color in observedColors where seenColors.insert(color).inserted {
            groupOrder.append(color)
        }

        if request.uncoloredPlacement == .last, hasUncolored {
            groupOrder.append(nil)
        }

        let rankByKey = Dictionary(uniqueKeysWithValues: groupOrder.enumerated().map { index, color in
            (colorGroupKey(color), index)
        })
        let fallbackRank = groupOrder.count
        return tabs.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rankByKey[colorGroupKey(normalizedWorkspaceColor(lhs.element.customColor))] ?? fallbackRank
                let rhsRank = rankByKey[colorGroupKey(normalizedWorkspaceColor(rhs.element.customColor))] ?? fallbackRank
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map { $0.element.id }
    }

    private static func observedWorkspaceColors(_ tabs: [Workspace]) -> [String] {
        var seen: Set<String> = []
        return tabs.compactMap { normalizedWorkspaceColor($0.customColor) }
            .filter { seen.insert($0).inserted }
    }

    private static func normalizedWorkspaceColor(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return WorkspaceTabColorSettings.normalizedHex(raw)
    }

    private static func colorGroupKey(_ color: String?) -> String {
        color ?? "__cmux_uncolored__"
    }

    private static func colorDisplayName(_ hex: String) -> String {
        let normalizedHex = WorkspaceTabColorSettings.normalizedHex(hex) ?? hex
        if let entry = WorkspaceTabColorSettings.palette().first(where: {
            WorkspaceTabColorSettings.normalizedHex($0.hex) == normalizedHex
        }) {
            return entry.name
        }
        return normalizedHex
    }

    private static func colorGroupRationale(_ request: ColorGroupSortRequest) -> String {
        let colorLabels = request.colorOrder.map(colorDisplayName)
        let colorText = colorLabels.isEmpty
            ? String(localized: "sortAssistant.colorGroup.currentOrder", defaultValue: "current color order")
            : colorLabels.joined(separator: ", ")
        let uncoloredText: String
        switch request.uncoloredPlacement {
        case .first:
            uncoloredText = String(localized: "sortAssistant.colorGroup.uncoloredFirst", defaultValue: "uncolored first")
        case .last:
            uncoloredText = String(localized: "sortAssistant.colorGroup.uncoloredLast", defaultValue: "uncolored last")
        }
        return String(
            format: String(localized: "sortAssistant.colorGroup.rationale", defaultValue: "Group workspaces by color using %@, with %@."),
            colorText,
            uncoloredText
        )
    }

    private func handleSubmitIntent(
        _ intent: SortAssistantIntent,
        trimmed: String,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        forceApply: Bool,
        workspaceTarget: SortAssistantWorkspaceTarget? = nil,
        sortRoute: SortAssistantSortRoute? = nil,
        routeSteps: [SortAssistantRouteStep]? = nil,
        routeAdjustment: SortAssistantRouteAdjustment = .empty,
        explicitSlashCommand: Bool = false,
        debugSession: SortAssistantDebugSession? = nil
    ) {
        let steps = normalizedRouteSteps(
            routeSteps,
            fallbackIntent: intent,
            fallbackSortRoute: sortRoute
        )
        let firstSortStepRoute = steps.first { $0.intent.isSortRouted }?.sortRoute
        let effectiveSortRoute = sortRoute ?? firstSortStepRoute
        let debugSession = debugSession ?? SortAssistantDebugSession.start(
            source: "intent",
            text: trimmed,
            externalGoal: false,
            forceApply: forceApply
        )
        debugSession.log(
            "intent.begin intent=\(intent.rawValue) steps=\(steps.debugDescriptionJoined) forceApply=\(forceApply) explicitSlash=\(explicitSlashCommand) sortRoute=\(effectiveSortRoute?.rawValue ?? "nil") adjustment=\(routeAdjustment.debugDescription)"
        )
        if intent == .clearSession {
            clearCurrentSession()
            entryFocusSequence += 1
            debugSession.finish(result: "clearSession")
            return
        }

        if steps.count == 1, intent == .workspaceColor {
            let workspaceColorRoute = actionRouter.route(for: .workspaceColor)
            let adjustedAllowedTools = routeAdjustment.applyingAllowedTools(to: workspaceColorRoute.allowedTools)
            if !routeAdjustment.isEmpty, adjustedAllowedTools.isEmpty {
                debugSession.log(
                    "routeAdjustment.floor intent=workspace_color reason=emptyAllowedTools restoredAllowedTools=\(workspaceColorRoute.allowedTools.joined(separator: ","))"
                )
            }
            startMCPAssistant(
                goal: trimmed,
                intent: .workspaceColor,
                routeSteps: steps,
                route: workspaceColorRoute.applying(
                    routeAdjustment,
                    emptyAllowedToolsFallback: workspaceColorRoute.allowedTools
                ),
                routeAdjustment: routeAdjustment,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                workspaceTarget: workspaceTarget,
                explicitSlashCommand: explicitSlashCommand,
                debugSession: debugSession
            )
            return
        }

        if intent.isSortRouted {
            let mode: SortAssistantRunMode = (forceApply || intent == .applySort) ? .apply : .preview
            let shouldTryColorGroup = steps.count == 1 && effectiveSortRoute == .colorGroup
            if shouldTryColorGroup, handleColorGroupSortIfNeeded(
                goal: trimmed,
                mode: mode,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore,
                sortRoute: effectiveSortRoute,
                explicitSlashCommand: explicitSlashCommand,
                debugSession: debugSession
            ) {
                debugSession.finish(result: "localColorGroup", details: "intent=\(intent.rawValue)")
                return
            }
        }

        var route = actionRouter.route(
            for: steps,
            explicitSlashCommand: explicitSlashCommand
        )
        if forceApply, intent == .applySort {
            route = SortAssistantActionRoute(
                mode: .applyAllowed,
                needsConfirmation: false,
                allowedTools: route.allowedTools,
                memoryWritePolicy: route.memoryWritePolicy
            )
        }
        let emptyAllowedToolsFallback = steps.contains { $0.intent == .workspaceColor } ? route.allowedTools : []
        let adjustedAllowedTools = routeAdjustment.applyingAllowedTools(to: route.allowedTools)
        if !routeAdjustment.isEmpty, adjustedAllowedTools.isEmpty, !emptyAllowedToolsFallback.isEmpty {
            debugSession.log(
                "routeAdjustment.floor intent=\(intent.rawValue) steps=\(steps.debugDescriptionJoined) reason=emptyAllowedTools restoredAllowedTools=\(emptyAllowedToolsFallback.joined(separator: ","))"
            )
        }
        route = route.applying(
            routeAdjustment,
            emptyAllowedToolsFallback: emptyAllowedToolsFallback
        )

        startMCPAssistant(
            goal: trimmed,
            intent: intent,
            routeSteps: steps,
            route: route,
            routeAdjustment: routeAdjustment,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            workspaceTarget: workspaceTarget,
            explicitSlashCommand: explicitSlashCommand,
            debugSession: debugSession
        )
    }

    private func normalizedRouteSteps(
        _ steps: [SortAssistantRouteStep]?,
        fallbackIntent: SortAssistantIntent,
        fallbackSortRoute: SortAssistantSortRoute?
    ) -> [SortAssistantRouteStep] {
        SortAssistantRouteStep.normalizing(
            steps,
            fallback: SortAssistantRouteStep(intent: fallbackIntent, sortRoute: fallbackSortRoute)
        )
    }

    private static func colorCommandTextContainsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func normalizedColorCommandText(_ text: String) -> String {
        var lower = text.lowercased()
        for separator in [".", ",", "?", "!", ":", ";", "/", "\\", "-", "_", "(", ")", "[", "]", "{", "}", "\n", "\t", "\"", "'"] {
            lower = lower.replacingOccurrences(of: separator, with: " ")
        }
        return " " + lower.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") + " "
    }

    private func appendSemanticRouterUnavailableReportIfNeeded(
        _ report: SortAssistantSemanticRouterUnavailableReport?
    ) {
        guard let report else { return }
        append(.init(
            kind: .warning,
            text: Self.semanticRouterUnavailableMessage(report)
        ))
    }

    private static func semanticRouterUnavailableMessage(
        _ report: SortAssistantSemanticRouterUnavailableReport
    ) -> String {
        var lines = [
            String(
                format: String(
                    localized: "sortAssistant.semanticRouter.unavailable",
                    defaultValue: "Semantic router unavailable; falling back to %@."
                ),
                report.fallbackIntent.rawValue
            ),
        ]
        if let localIssue = report.localIssue {
            lines.append("- \(semanticRouterIssueMessage(localIssue))")
        }
        if let claudeIssue = report.claudeIssue {
            lines.append("- \(semanticRouterIssueMessage(claudeIssue))")
        }
        return lines.joined(separator: "\n")
    }

    private static func semanticRouterIssueMessage(_ issue: SortAssistantSemanticRouterIssue) -> String {
        switch (issue.stage, issue.code) {
        case (.local, "not_configured"):
            return String(
                localized: "sortAssistant.semanticRouter.local.notConfigured",
                defaultValue: "Local router: not configured (set a semantic router model in Sprite settings or semanticRouter.model)."
            )
        case (.local, "disabled"):
            return String(
                localized: "sortAssistant.semanticRouter.local.disabled",
                defaultValue: "Local router: disabled in Sprite semantic router settings."
            )
        case (.local, "missing_base_url"):
            return String(
                localized: "sortAssistant.semanticRouter.local.missingBaseURL",
                defaultValue: "Local router: base URL is empty."
            )
        case (.local, "invalid_base_url"):
            return String(
                localized: "sortAssistant.semanticRouter.local.invalidBaseURL",
                defaultValue: "Local router: base URL is invalid."
            )
        case (.local, "http_status"):
            return String(
                format: String(
                    localized: "sortAssistant.semanticRouter.local.httpStatus",
                    defaultValue: "Local router: endpoint returned HTTP %@."
                ),
                issue.status.map(String.init) ?? "unknown"
            )
        case (.local, "invalid_json"):
            return String(
                localized: "sortAssistant.semanticRouter.local.invalidJSON",
                defaultValue: "Local router: response was not a JSON object."
            )
        case (.local, "missing_content"):
            return String(
                localized: "sortAssistant.semanticRouter.local.missingContent",
                defaultValue: "Local router: response did not include model content."
            )
        case (.local, "invalid_decision"):
            return String(
                localized: "sortAssistant.semanticRouter.local.invalidDecision",
                defaultValue: "Local router: response did not match the route JSON schema."
            )
        case (.local, "low_confidence"):
            return String(
                localized: "sortAssistant.semanticRouter.local.lowConfidence",
                defaultValue: "Local router: returned low confidence."
            )
        case (.claude, "timed_out"):
            return String(
                format: String(
                    localized: "sortAssistant.semanticRouter.claude.timedOut",
                    defaultValue: "Claude fallback router: timed out after %@s."
                ),
                issue.timeoutSeconds.map(String.init) ?? "unknown"
            )
        case (.claude, "exited"):
            return String(
                format: String(
                    localized: "sortAssistant.semanticRouter.claude.exited",
                    defaultValue: "Claude fallback router: exited with status %@."
                ),
                issue.status.map(String.init) ?? "unknown"
            )
        case (.claude, "executable_missing"):
            return String(
                localized: "sortAssistant.semanticRouter.claude.executableMissing",
                defaultValue: "Claude fallback router: Claude Code executable was not found."
            )
        case (.claude, "invalid_decision"):
            return String(
                localized: "sortAssistant.semanticRouter.claude.invalidDecision",
                defaultValue: "Claude fallback router: response did not match the route JSON schema."
            )
        case (.claude, "low_confidence"):
            return String(
                localized: "sortAssistant.semanticRouter.claude.lowConfidence",
                defaultValue: "Claude fallback router: returned low confidence."
            )
        case (.claude, "clear_session_rejected"):
            return String(
                localized: "sortAssistant.semanticRouter.claude.clearSessionRejected",
                defaultValue: "Claude fallback router: rejected a clear-session route for this request."
            )
        case (.local, _):
            return String(
                format: String(
                    localized: "sortAssistant.semanticRouter.local.failed",
                    defaultValue: "Local router: %@."
                ),
                issue.detail ?? issue.code
            )
        case (.claude, _):
            return String(
                format: String(
                    localized: "sortAssistant.semanticRouter.claude.failed",
                    defaultValue: "Claude fallback router: %@."
                ),
                issue.detail ?? issue.code
            )
        }
    }

    private static func visibleScopeSignature(
        intent: SortAssistantIntent,
        steps: [SortAssistantRouteStep],
        route: SortAssistantActionRoute,
        routeAdjustment: SortAssistantRouteAdjustment,
        explicitSlashCommand: Bool,
        workspaceDirectory: String?
    ) -> String {
        [
            "intent=\(intent.rawValue)",
            "steps=\(steps.debugDescriptionJoined)",
            "mode=\(route.mode.rawValue)",
            "confirm=\(route.needsConfirmation ? 1 : 0)",
            "memory=\(route.memoryWritePolicy.rawValue)",
            "tools=\(route.allowedTools.joined(separator: ","))",
            "adjustment=\(routeAdjustment.debugDescription)",
            "slash=\(explicitSlashCommand ? 1 : 0)",
            "workspace=\(workspaceDirectory ?? "")",
        ].joined(separator: "|")
    }

    private func startMCPAssistant(
        goal: String,
        intent: SortAssistantIntent,
        routeSteps: [SortAssistantRouteStep]? = nil,
        route: SortAssistantActionRoute,
        routeAdjustment: SortAssistantRouteAdjustment = .empty,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        workspaceTarget: SortAssistantWorkspaceTarget? = nil,
        explicitSlashCommand: Bool = false,
        debugSession: SortAssistantDebugSession? = nil
    ) {
        let debugSession = debugSession ?? SortAssistantDebugSession.start(
            source: "mcp",
            text: goal,
            externalGoal: false,
            forceApply: route.mode == .applyAllowed
        )
        let steps = normalizedRouteSteps(
            routeSteps,
            fallbackIntent: intent,
            fallbackSortRoute: nil
        )
        debugSession.log(
            "mcp.start intent=\(intent.rawValue) steps=\(steps.debugDescriptionJoined) mode=\(route.mode.rawValue) explicitSlash=\(explicitSlashCommand) adjustment=\(routeAdjustment.debugDescription)"
        )
        guard !isSorting else {
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.sort.busy", defaultValue: "A workspace sort is already running.")
            ))
            debugSession.finish(result: "busy", details: "intent=\(intent.rawValue)")
            return
        }

        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        let runtimeMode = CmuxRuntimeMode.current()
        let contextNow = runtimeMode.fixedNow ?? Date()
        if route.allowedTools.contains(where: Self.contextFreshnessWarningTools.contains) {
            appendContextFreshnessWarningIfNeeded(now: contextNow)
        }
        choicePrompt = nil
        if runtimeMode.fakeAssistant {
            startFakeAssistant(
                intent: intent,
                debugSession: debugSession,
                now: contextNow
            )
            return
        }
        isSorting = true
        let conversationContext = semanticConversationContext(workspaceTarget: workspaceTarget)
        let resolvedWorkspaceId = workspaceTarget?.id ?? tabManager.selectedTabId
        let resolvedWorkspaceDirectory = workspaceTarget?.directory ?? Self.workspaceDirectoryForMCP(tabManager: tabManager)
        let claudeSessionId = claudeConversationSessionId
        let claudeSessionReused = claudeConversationSessionStarted
        let includeConversationContext = !claudeConversationSessionStarted
        let visibleScopeSignature = Self.visibleScopeSignature(
            intent: intent,
            steps: steps,
            route: route,
            routeAdjustment: routeAdjustment,
            explicitSlashCommand: explicitSlashCommand,
            workspaceDirectory: resolvedWorkspaceDirectory
        )
        let requiresMCPScopeRefresh = !claudeConversationSessionStarted
            || claudeVisibleScopeSignature != visibleScopeSignature
        debugSession.log(
            "mcp.scope.plan refresh=\(requiresMCPScopeRefresh ? 1 : 0) previous=\(claudeVisibleScopeSignature == nil ? "nil" : "set") signatureHash=\(visibleScopeSignature.hashValue)"
        )
#if DEBUG
        let debugRequestId = UUID()
        debugLogSpriteGeometrySnapshot(
            "conversation.mcp.before debugSession=\(debugSession.shortId) requestId=\(debugRequestId.uuidString) intent=\(intent)"
        )
#endif
        let progressMessageId = append(.init(
            kind: .progress,
            text: String(localized: "sortAssistant.mcp.running", defaultValue: "Preparing assistant tools...")
        ))
        let generation = sessionGeneration
        let progressHandler: SortAssistantMCPProgressHandler? = { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                self.updateMessage(id: progressMessageId, text: update.message)
            }
        }

        let request = SortAssistantMCPRequest(
            goal: goal,
            intent: intent,
            routeSteps: steps,
            route: route,
            routeAdjustment: routeAdjustment,
            visibleScopeSignature: visibleScopeSignature,
            requiresMCPScopeRefresh: requiresMCPScopeRefresh,
            conversationContext: conversationContext,
            includeConversationContext: includeConversationContext,
            explicitSlashCommand: explicitSlashCommand,
            workspaceId: resolvedWorkspaceId?.uuidString,
            workspaceDirectory: resolvedWorkspaceDirectory,
            socketPath: SocketControlSettings.socketPath(),
            cmuxCLIPath: Self.cmuxCLIPathForMCP(),
            claudeSessionId: claudeSessionId,
            claudeSessionReused: claudeSessionReused,
            debugSession: debugSession
        )
        Task { [weak self, weak tabManager, weak workspaceTabStore] in
            guard let self else { return }
            do {
                let runStart = SortAssistantDebugSession.now()
                let result = try await self.mcpClient.run(request, progressHandler: progressHandler)
                debugSession.log(
                    "mcp.run.end intent=\(intent.rawValue)",
                    phaseStartNanos: runStart
                )
                guard self.sessionGeneration == generation else {
                    debugSession.finish(result: "stale", details: "intent=\(intent.rawValue)")
                    return
                }
                self.claudeConversationSessionStarted = true
                self.claudeVisibleScopeSignature = request.visibleScopeSignature
                self.isSorting = false
                self.removeMessage(id: progressMessageId)
#if DEBUG
                self.debugLogSpriteGeometrySnapshot(
                    "conversation.mcp.afterRun debugSession=\(debugSession.shortId) requestId=\(debugRequestId.uuidString) result=success intent=\(intent)"
                )
#endif
                guard let tabManager, let workspaceTabStore else {
                    debugSession.finish(result: "dropped", details: "intent=\(intent.rawValue) reason=storesReleased")
                    return
                }
                let uiStart = SortAssistantDebugSession.now()
                self.handleMCPRunResult(
                    result,
                    goal: goal,
                    intent: intent,
                    routeSteps: steps,
                    route: route,
                    tabManager: tabManager,
                    workspaceTabStore: workspaceTabStore,
                    workspaceTarget: workspaceTarget,
                    explicitSlashCommand: explicitSlashCommand
                )
                debugSession.log(
                    "mcp.ui.end hasCard=\(result.card != nil) hasChoice=\((result.choicePrompt != nil) || (self.choicePrompt != nil)) messageChars=\(result.message.count)",
                    phaseStartNanos: uiStart
                )
                debugSession.finish(result: "success", details: "intent=\(intent.rawValue)")
            } catch {
                guard self.sessionGeneration == generation else {
                    debugSession.finish(result: "staleFailure", details: "intent=\(intent.rawValue)")
                    return
                }
                self.isSorting = false
                self.removeMessage(id: progressMessageId)
#if DEBUG
                self.debugLogSpriteGeometrySnapshot(
                    "conversation.mcp.afterRun debugSession=\(debugSession.shortId) requestId=\(debugRequestId.uuidString) result=failure intent=\(intent)"
                )
#endif
                self.append(.init(
                    kind: .error,
                    text: String(localized: "sortAssistant.mcp.failed", defaultValue: "Sprite MCP request failed: ") + Self.displayMessage(for: error)
                ))
                debugSession.finish(
                    result: "failure",
                    details: "intent=\(intent.rawValue) error=\(SortAssistantDebugSession.errorSummary(error))"
                )
            }
        }
    }

    private func startFakeAssistant(
        intent: SortAssistantIntent,
        debugSession: SortAssistantDebugSession,
        now: Date
    ) {
        isSorting = true
        let progressMessageId = append(.init(
            kind: .progress,
            text: String(
                localized: "sortAssistant.fakeAssistant.running",
                defaultValue: "Reading fixture assistant context..."
            )
        ))
        let generation = sessionGeneration
        Task { [weak self] in
            guard let self else { return }
            let readStart = SortAssistantDebugSession.now()
            await self.refreshAssistantWorkingContextStore(now: now)
            let read = await self.assistantRuntime.readContextForAnswer(now: now)
            debugSession.log(
                "fake.run.end intent=\(intent.rawValue) snapshots=\(read.workingContext.snapshots.count)",
                phaseStartNanos: readStart
            )
            guard self.sessionGeneration == generation else {
                debugSession.finish(result: "stale", details: "intent=\(intent.rawValue) mode=fake")
                return
            }
            self.isSorting = false
            self.removeMessage(id: progressMessageId)
            self.append(.init(
                kind: .assistant,
                text: Self.fakeAssistantResponse(for: read, now: now)
            ))
            debugSession.finish(
                result: "fake",
                details: "intent=\(intent.rawValue) snapshots=\(read.workingContext.snapshots.count)"
            )
        }
    }

    private static func fakeAssistantResponse(for read: AssistantRuntimeContextRead, now: Date) -> String {
        guard !read.missingSnapshot else {
            return String(
                localized: "sortAssistant.fakeAssistant.missingSnapshot",
                defaultValue: "Fixture assistant found no workspace snapshots in this test fixture."
            )
        }

        let snapshotCount = String(
            format: String(
                localized: "sortAssistant.fakeAssistant.snapshotCount",
                defaultValue: "Fixture assistant read %d workspace snapshots."
            ),
            read.workingContext.snapshots.count
        )
        let activeWorkspace = fakeAssistantActiveWorkspaceText(for: read)
        let staleProviders: String
        if read.staleProviderIds.isEmpty {
            staleProviders = String(
                localized: "sortAssistant.fakeAssistant.noStaleProviders",
                defaultValue: "No stale context providers."
            )
        } else {
            staleProviders = String(
                format: String(
                    localized: "sortAssistant.fakeAssistant.staleProviders",
                    defaultValue: "Stale context providers: %@."
                ),
                read.staleProviderIds.joined(separator: ", ")
            )
        }
        var parts = [snapshotCount, activeWorkspace, staleProviders]
        if let suggestions = fakeAssistantSuggestionsText(for: read, now: now) {
            parts.append(suggestions)
        }
        return parts.joined(separator: " ")
    }

    private static func fakeAssistantActiveWorkspaceText(for read: AssistantRuntimeContextRead) -> String {
        guard let activeWorkspaceId = read.workingContext.activeWorkspaceId,
              let snapshot = read.workingContext.snapshots.first(where: { $0.workspaceId == activeWorkspaceId }) else {
            return String(
                localized: "sortAssistant.fakeAssistant.noActiveWorkspace",
                defaultValue: "No active workspace is selected."
            )
        }
        return String(
            format: String(
                localized: "sortAssistant.fakeAssistant.activeWorkspace",
                defaultValue: "Active workspace: %@."
            ),
            snapshot.context.title
        )
    }

    private static func fakeAssistantSuggestionsText(
        for read: AssistantRuntimeContextRead,
        now: Date
    ) -> String? {
        let snapshotsById = Dictionary(uniqueKeysWithValues: read.workingContext.snapshots.map {
            ($0.workspaceId, $0)
        })
        let details = read.workingContext.activeSuggestions.prefix(3).map { suggestion -> String in
            let snapshot = snapshotsById[suggestion.workspaceId]
            let workspaceTitle = snapshot?.context.title ?? suggestion.title
            let staleProviderIds = snapshot?.freshness
                .evaluated(at: now)
                .providers
                .filter(\.stale)
                .map(\.providerId) ?? []
            let freshness = fakeAssistantSuggestionFreshnessText(staleProviderIds)
            return String(
                format: String(
                    localized: "sortAssistant.fakeAssistant.suggestionDetail",
                    defaultValue: "%@ - %@, status %@, %@"
                ),
                workspaceTitle,
                fakeAssistantSuggestionLabel(for: suggestion.type),
                snapshot?.derived.status ?? "unknown",
                freshness
            )
        }
        guard !details.isEmpty else { return nil }
        return String(
            format: String(
                localized: "sortAssistant.fakeAssistant.suggestions",
                defaultValue: "Active suggestions: %@."
            ),
            details.joined(separator: "; ")
        )
    }

    private static func fakeAssistantSuggestionFreshnessText(_ staleProviderIds: [String]) -> String {
        guard !staleProviderIds.isEmpty else {
            return String(
                localized: "sortAssistant.fakeAssistant.suggestionFresh",
                defaultValue: "fresh context"
            )
        }
        return String(
            format: String(
                localized: "sortAssistant.fakeAssistant.suggestionStaleProviders",
                defaultValue: "stale providers %@"
            ),
            orderedUniqueSortAssistant(staleProviderIds).joined(separator: ", ")
        )
    }

    private static func fakeAssistantSuggestionLabel(for type: String) -> String {
        switch type {
        case ProactiveSuggestionTypes.reviewAgentWaitingUser:
            return String(
                localized: "sortAssistant.fakeAssistant.suggestion.reviewAgentWaitingUser",
                defaultValue: "review agent waiting for user"
            )
        case ProactiveSuggestionTypes.fixCIFailure:
            return String(
                localized: "sortAssistant.fakeAssistant.suggestion.fixCIFailure",
                defaultValue: "fix CI failure"
            )
        case ProactiveSuggestionTypes.mergeReady:
            return String(
                localized: "sortAssistant.fakeAssistant.suggestion.mergeReady",
                defaultValue: "ready to merge"
            )
        case ProactiveSuggestionTypes.workspaceNeedsAttention:
            return String(
                localized: "sortAssistant.fakeAssistant.suggestion.workspaceNeedsAttention",
                defaultValue: "workspace needs attention"
            )
        default:
            return String(
                localized: "sortAssistant.fakeAssistant.suggestion.generic",
                defaultValue: "suggestion"
            )
        }
    }

    private func handleMCPRunResult(
        _ result: SortAssistantMCPRunResult,
        goal: String,
        intent: SortAssistantIntent,
        routeSteps: [SortAssistantRouteStep],
        route: SortAssistantActionRoute,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        workspaceTarget: SortAssistantWorkspaceTarget?,
        explicitSlashCommand: Bool
    ) {
        let result = localFallbackResult(
            replacingUnavailableToolMessageIfNeeded: result,
            goal: goal,
            intent: intent,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
        let inferredChoicePrompt = result.choicePrompt ?? Self.inferredChoicePrompt(
            from: result.message,
            goal: goal,
            intent: intent
        )
        let message = result.choicePrompt == nil && inferredChoicePrompt != nil ? "" : result.message
        let anchorMessageId: UUID?
        if !message.isEmpty {
            anchorMessageId = append(.init(kind: .assistant, text: message))
        } else if memoryCandidate != nil {
            anchorMessageId = append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.memory.reviewPrompt", defaultValue: "Review this memory before saving it.")
            ))
        } else {
            anchorMessageId = messages.last?.id
        }

        if let inferredChoicePrompt {
            latestResult = nil
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            choicePrompt = inferredChoicePrompt.preparedForFollowUp(
                intent: intent,
                routeSteps: routeSteps,
                forceApply: route.mode == .applyAllowed && !route.needsConfirmation,
                workspaceTarget: workspaceTarget,
                explicitSlashCommand: explicitSlashCommand
            )
            return
        }

        guard let card = result.card else { return }
        choicePrompt = nil
        let dimensionLabel = card.dimensionLabel ?? Self.dimensionLabel(workspaceTabStore.selectedSort)
        setLatestResult(SortAssistantSortResult(
            title: card.title,
            goal: goal,
            dimensionLabel: dimensionLabel,
            changes: card.changes,
            rationale: card.rationale,
            patchId: card.patchId,
            mode: card.mode,
            canUndo: card.mode == .applied,
            canApply: card.mode == .preview,
            canApplyPartially: card.mode == .preview,
            canIgnore: card.mode == .preview,
            actions: Self.availableResultActions(card.actions, resultMode: card.mode)
        ), anchorMessageId: anchorMessageId)

    }

    private struct LocalFallbackWorkspaceRow {
        let title: String
        let detail: String?
    }

    private func localFallbackResult(
        replacingUnavailableToolMessageIfNeeded result: SortAssistantMCPRunResult,
        goal: String,
        intent: SortAssistantIntent,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) -> SortAssistantMCPRunResult {
        guard result.card == nil,
              Self.isUnavailableToolMessage(result.message) else {
            return result
        }
        return SortAssistantMCPRunResult(
            message: localFallbackMessage(
                goal: goal,
                intent: intent,
                tabManager: tabManager,
                workspaceTabStore: workspaceTabStore
            ),
            card: nil
        )
    }

    private static func isUnavailableToolMessage(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        guard lowercased.contains("tool")
            || lowercased.contains("mcp")
            || lowercased.contains("sort context") else {
            return false
        }
        return lowercased.contains("not currently available")
            || lowercased.contains("aren't currently available")
            || lowercased.contains("need the sort context tools")
            || lowercased.contains("cannot access")
    }

    private static func inferredChoicePrompt(
        from message: String,
        goal: String,
        intent: SortAssistantIntent
    ) -> SortAssistantChoicePrompt? {
        guard intent.isSortRouted else { return nil }
        let lowercasedMessage = message.lowercased()
        let lowercasedGoal = goal.lowercased()
        guard lowercasedMessage.contains("unfinished work"),
              lowercasedMessage.contains("pr activity"),
              lowercasedMessage.contains("clarify"),
              lowercasedMessage.contains("urgent") || lowercasedGoal.contains("urgent") || lowercasedGoal.contains("urgency") else {
            return nil
        }
        return SortAssistantChoicePrompt(
            title: String(localized: "sortAssistant.choice.urgent.title", defaultValue: "Choose urgent signal"),
            message: String(
                localized: "sortAssistant.choice.urgent.message",
                defaultValue: "Pick the signal to use for this sort."
            ),
            options: [
                SortAssistantChoicePrompt.Option(
                    id: "unfinished_work",
                    title: String(localized: "sortAssistant.choice.urgent.unfinished.title", defaultValue: "Unfinished work"),
                    subtitle: String(
                        localized: "sortAssistant.choice.urgent.unfinished.subtitle",
                        defaultValue: "Prioritize local changes, active tasks, blockers, or other in-progress work."
                    ),
                    goal: String(
                        localized: "sortAssistant.choice.urgent.unfinished.goal",
                        defaultValue: "Sort by unfinished work: prioritize workspaces with uncommitted local changes, in-progress tasks, blockers, or other active work."
                    )
                ),
                SortAssistantChoicePrompt.Option(
                    id: "pr_activity",
                    title: String(localized: "sortAssistant.choice.urgent.pr.title", defaultValue: "PR activity"),
                    subtitle: String(
                        localized: "sortAssistant.choice.urgent.pr.subtitle",
                        defaultValue: "Prioritize linked PRs awaiting review, CI, or recent review activity."
                    ),
                    goal: String(
                        localized: "sortAssistant.choice.urgent.pr.goal",
                        defaultValue: "Sort by PR activity: prioritize workspaces with linked PRs awaiting review, failing or running CI, or recent review activity."
                    )
                ),
                SortAssistantChoicePrompt.Option(
                    id: "current_urgency",
                    title: String(localized: "sortAssistant.choice.urgent.current.title", defaultValue: "Current urgency signals"),
                    subtitle: String(
                        localized: "sortAssistant.choice.urgent.current.subtitle",
                        defaultValue: "Use digest, GitHub context, and saved sorting memory."
                    ),
                    goal: String(
                        localized: "sortAssistant.choice.urgent.current.goal",
                        defaultValue: "Sort by current urgency signals: use workspace digest status, GitHub context, and saved free-sort memories to rank urgency."
                    )
                ),
            ]
        )
    }

    private func localFallbackMessage(
        goal: String,
        intent: SortAssistantIntent,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) -> String {
        let rows = localFallbackWorkspaceRows(
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            limit: 5
        )
        guard !rows.isEmpty else {
            return String(
                localized: "sortAssistant.localFallback.empty",
                defaultValue: "I can read the local sidebar cache, but there are no workspace rows available yet."
            )
        }

        var lines: [String]
        switch intent {
        case .askContext, .explainCurrentOrder:
            lines = [
                String(
                    format: String(
                        localized: "sortAssistant.localFallback.contextIntro",
                        defaultValue: "Current sidebar has %d workspaces."
                    ),
                    tabManager.tabs.count
                ),
                "",
                String(
                    localized: "sortAssistant.localFallback.contextHeading",
                    defaultValue: "Top local sidebar signals:"
                ),
            ]
        default:
            let normalizedGoal = Self.nonEmpty(goal)
            lines = [
                normalizedGoal.map {
                    String(
                        format: String(
                            localized: "sortAssistant.localFallback.goalIntro",
                            defaultValue: "Using the local sidebar cache for: %@"
                        ),
                        $0
                    )
                } ?? String(
                    localized: "sortAssistant.localFallback.intro",
                    defaultValue: "I can use the local sidebar cache directly."
                ),
                "",
                String(
                    localized: "sortAssistant.localFallback.recommendationHeading",
                    defaultValue: "Suggested next focus:"
                ),
            ]
        }

        for (index, row) in rows.enumerated() {
            let detail = row.detail.map { " — \($0)" } ?? ""
            lines.append("\(index + 1). \(row.title)\(detail)")
        }
        return lines.joined(separator: "\n")
    }

    private func localFallbackWorkspaceRows(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        limit: Int
    ) -> [LocalFallbackWorkspaceRow] {
        let tabsById = Dictionary(uniqueKeysWithValues: tabManager.tabs.map { ($0.id, $0) })
        let summaryItemsById: [UUID: WorkspaceSidebarSummaryPriorityItem] = (workspaceTabStore.summaryPriority?.items ?? [])
            .reduce(into: [:]) { partial, item in
                guard let id = UUID(uuidString: item.workspaceId), partial[id] == nil else { return }
                partial[id] = item
            }
        let signalsById = contextProvider.itemSignals(
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )

        return localFallbackWorkspaceIds(
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
        .prefix(limit)
        .compactMap { workspaceId in
            guard let workspace = tabsById[workspaceId] else { return nil }
            let item = summaryItemsById[workspaceId]
            let context = workspaceTabStore.contextSummary(for: workspaceId)
            let signal = signalsById[workspaceId]
            let fallbackIndex = tabManager.tabs.firstIndex { $0.id == workspaceId }.map { $0 + 1 } ?? 1
            let title = Self.nonPlaceholder(item?.title)
                ?? Self.nonPlaceholder(context?.title)
                ?? Self.nonPlaceholder(signal?.title)
                ?? Self.nonPlaceholder(workspace.title)
                ?? String(
                    format: String(
                        localized: "sortAssistant.localFallback.workspaceTitle",
                        defaultValue: "Workspace %d"
                    ),
                    fallbackIndex
                )
            return LocalFallbackWorkspaceRow(
                title: title,
                detail: Self.localFallbackDetail(
                    item: item,
                    context: context,
                    signal: signal,
                    sort: workspaceTabStore.selectedSort
                )
            )
        }
    }

    private func localFallbackWorkspaceIds(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) -> [UUID] {
        var orderedIds: [UUID] = []
        if let summary = workspaceTabStore.summaryPriority {
            let sortedIds = WorkspaceTabStore.orderedWorkspaceIds(
                from: summary,
                tabs: tabManager.tabs,
                sort: workspaceTabStore.selectedSort,
                recentWorkspaceIds: workspaceTabStore.recentWorkspaceIds
            )
            if sortedIds.isEmpty {
                orderedIds.append(contentsOf: summary.items.compactMap { UUID(uuidString: $0.workspaceId) })
            } else {
                orderedIds.append(contentsOf: sortedIds)
            }
        }
        orderedIds.append(contentsOf: tabManager.tabs.map(\.id))

        let currentIds = Set(tabManager.tabs.map(\.id))
        var seen = Set<UUID>()
        return orderedIds.filter { id in
            currentIds.contains(id) && seen.insert(id).inserted
        }
    }

    private static func localFallbackDetail(
        item: WorkspaceSidebarSummaryPriorityItem?,
        context: WorkspaceTabContextSummary?,
        signal: SortAssistantSortContext.ItemSignals?,
        sort: WorkspaceSidebarSummaryPrioritySort
    ) -> String? {
        var parts: [String] = []
        if let priority = nonPlaceholder(signal?.priority) {
            parts.append(priority)
        } else if let score = localFallbackScore(item: item, sort: sort) {
            parts.append(
                String(
                    format: String(
                        localized: "sortAssistant.localFallback.score",
                        defaultValue: "score %d"
                    ),
                    Int(score.rounded())
                )
            )
        }
        if let status = nonPlaceholder(item?.presentStatus)
            ?? nonPlaceholder(item?.status)
            ?? nonPlaceholder(context?.status)
            ?? nonPlaceholder(signal?.status) {
            parts.append(status)
        }
        if let next = nonPlaceholder(item?.nextAction?.label)
            ?? nonPlaceholder(context?.next) {
            parts.append(
                String(localized: "sortAssistant.localFallback.nextPrefix", defaultValue: "next: ") + next
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    private static func localFallbackScore(
        item: WorkspaceSidebarSummaryPriorityItem?,
        sort: WorkspaceSidebarSummaryPrioritySort
    ) -> Double? {
        guard let item else { return nil }
        if sort.isDimension, let dimensionId = sort.dimensionId {
            return item.scores.dimensions[dimensionId]?.rawScore
        }
        return item.scores.dimensions["urgency"]?.rawScore
            ?? item.scores.dimensions.values.map(\.rawScore).max()
    }

    private static func nonPlaceholder(_ text: String?) -> String? {
        guard let value = nonEmpty(text) else { return nil }
        return value == "—" ? nil : value
    }

    private static func cmuxCLIPathForMCP() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["CMUX_DIGEST_CMUX"],
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("bin/cmux").path
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }
        if FileManager.default.isExecutableFile(atPath: "/tmp/cmux-cli") {
            return "/tmp/cmux-cli"
        }
        return "cmux"
    }

    private static func workspaceDirectoryForMCP(tabManager: TabManager) -> String? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        return workspaceDirectoryForMCP(workspace: workspace)
    }

    private static func workspaceDirectoryForMCP(workspace: Workspace) -> String? {
        if let focusedPanelId = workspace.focusedPanelId,
           let directory = normalizedDirectoryForMCP(workspace.panelDirectories[focusedPanelId]) {
            return directory
        }
        if let directory = normalizedDirectoryForMCP(workspace.surfaceTabBarDirectory) {
            return directory
        }
        return workspace.panelDirectories.values.lazy.compactMap(normalizedDirectoryForMCP).first
    }

    private static func normalizedDirectoryForMCP(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func answerDimensionQuestion(
        dimensionId: String,
        goal: String,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        dimensionQuestion = nil
        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        workspaceTabStore.setSort(.dimension(id: dimensionId))
        let intent: SortAssistantIntent = .applySort
        startMCPAssistant(
            goal: goal,
            intent: intent,
            route: actionRouter.route(for: intent),
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
    }

    func answerChoicePrompt(
        _ option: SortAssistantChoicePrompt.Option,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        guard let prompt = choicePrompt else { return }
        choicePrompt = nil
        append(.init(kind: .user, text: option.title))
        let debugSession = SortAssistantDebugSession.start(
            source: "choicePrompt",
            text: option.goal,
            externalGoal: false,
            forceApply: prompt.forceApplyOnSubmit
        )
        debugSession.log(
            "router.skipped source=choicePrompt steps=\((prompt.routeSteps ?? []).debugDescriptionJoined)"
        )
        handleSubmitIntent(
            prompt.intentOnSubmit,
            trimmed: option.goal,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            forceApply: prompt.forceApplyOnSubmit,
            workspaceTarget: prompt.workspaceTarget,
            routeSteps: prompt.routeSteps,
            explicitSlashCommand: prompt.explicitSlashCommand,
            debugSession: debugSession
        )
    }

    func selectChoicePromptOption(
        _ option: SortAssistantChoicePrompt.Option,
        questionId: String
    ) {
        guard let prompt = choicePrompt,
              prompt.questions.contains(where: { question in
                  question.id == questionId && question.options.contains(where: { $0.id == option.id })
              }) else {
            return
        }
        choicePromptSelections[questionId] = option
    }

    func isChoicePromptReady(_ prompt: SortAssistantChoicePrompt) -> Bool {
        prompt.questions.allSatisfy { question in
            choicePromptSelections[question.id] != nil
        }
    }

    func submitChoicePromptSelections(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        guard let prompt = choicePrompt,
              isChoicePromptReady(prompt) else {
            return
        }

        let selections = prompt.questions.compactMap { question -> (SortAssistantChoicePrompt.Question, SortAssistantChoicePrompt.Option)? in
            guard let option = choicePromptSelections[question.id] else { return nil }
            return (question, option)
        }
        choicePrompt = nil
        choicePromptSelections = [:]
        append(.init(
            kind: .user,
            text: selections
                .map { "\($0.0.title): \($0.1.title)" }
                .joined(separator: "\n")
        ))

        let combinedGoal = Self.combinedChoicePromptGoal(selections)
        let debugSession = SortAssistantDebugSession.start(
            source: "choicePrompt",
            text: combinedGoal,
            externalGoal: false,
            forceApply: prompt.forceApplyOnSubmit
        )
        debugSession.log(
            "router.skipped source=choicePrompt.multi steps=\((prompt.routeSteps ?? []).debugDescriptionJoined)"
        )
        handleSubmitIntent(
            prompt.intentOnSubmit,
            trimmed: combinedGoal,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            forceApply: prompt.forceApplyOnSubmit,
            workspaceTarget: prompt.workspaceTarget,
            routeSteps: prompt.routeSteps,
            explicitSlashCommand: prompt.explicitSlashCommand,
            debugSession: debugSession
        )
    }

    private static func combinedChoicePromptGoal(
        _ selections: [(SortAssistantChoicePrompt.Question, SortAssistantChoicePrompt.Option)]
    ) -> String {
        var lines = [
            "Use these clarification choices together:",
        ]
        for (question, option) in selections {
            lines.append("- \(question.title): \(option.title). \(option.goal)")
        }
        return lines.joined(separator: "\n")
    }

    func dismissChoicePrompt() {
        choicePrompt = nil
        choicePromptSelections = [:]
    }

    func confirmSemanticAction() {
        guard let pending = pendingSemanticActionConfirmation,
              semanticActionConfirmation?.id == pending.id else {
            return
        }
        semanticActionConfirmation = nil
        pendingSemanticActionConfirmation = nil
        pending.confirm()
    }

    func dismissSemanticActionConfirmation() {
        guard semanticActionConfirmation != nil else { return }
        semanticActionConfirmation = nil
        pendingSemanticActionConfirmation = nil
        append(.init(
            kind: .assistant,
            text: String(localized: "sortAssistant.actionReview.confirmCanceled", defaultValue: "Canceled the reviewed action.")
        ))
    }

    private func applyPinnedSlashCommand(
        _ workspace: Workspace,
        title: String,
        pinned: Bool,
        tabManager: TabManager
    ) {
        let intent = assistantActionIntent(
            kind: .pinWorkspace,
            route: nil,
            arguments: ["itemId": workspace.id.uuidString, "pinned": pinned ? "true" : "false"],
            workspaceIds: [workspace.id],
            reason: nil
        )
        do {
            let review = try submitReviewedAction(intent) {
                tabManager.setPinned(workspace, pinned: pinned)
                return ActionExecutionResult(payload: ["pinned": pinned ? "true" : "false"])
            }
            guard review.decision == .allow else {
                let reviewError = SemanticActionReviewError(intent: intent, result: review)
                if queueSemanticActionConfirmation(
                    for: reviewError,
                    actionName: Self.semanticActionDisplayName(.pinWorkspace),
                    confirm: { [weak self, weak workspace, weak tabManager] in
                        guard let self, let workspace, let tabManager else { return }
                        self.confirmPinnedSlashCommand(
                            workspace,
                            title: title,
                            pinned: pinned,
                            tabManager: tabManager,
                            intent: intent
                        )
                    }
                ) {
                    return
                }
                appendPinnedSlashFailure(error: reviewError)
                return
            }
            appendPinnedSlashMessage(title: title, pinned: pinned)
        } catch {
            appendPinnedSlashFailure(error: error)
        }
    }

    private func confirmPinnedSlashCommand(
        _ workspace: Workspace,
        title: String,
        pinned: Bool,
        tabManager: TabManager,
        intent: ActionIntent
    ) {
        do {
            try executeConfirmedSemanticAction(intent: intent) {
                tabManager.setPinned(workspace, pinned: pinned)
                return ActionExecutionResult(payload: ["pinned": pinned ? "true" : "false"])
            }
            appendPinnedSlashMessage(title: title, pinned: pinned)
        } catch {
            appendPinnedSlashFailure(error: error)
        }
    }

    private func applyLockedSlashCommand(
        itemId: UUID,
        title: String,
        locked: Bool
    ) {
        let intent = assistantActionIntent(
            kind: .lockList,
            route: nil,
            arguments: ["itemId": itemId.uuidString, "locked": locked ? "true" : "false"],
            workspaceIds: [itemId],
            reason: nil
        )
        do {
            let review = try submitReviewedAction(intent) {
                sortEngine.setLocked(locked, itemId: itemId)
                return ActionExecutionResult(payload: ["locked": locked ? "true" : "false"])
            }
            guard review.decision == .allow else {
                let reviewError = SemanticActionReviewError(intent: intent, result: review)
                if queueSemanticActionConfirmation(
                    for: reviewError,
                    actionName: Self.semanticActionDisplayName(.lockList),
                    confirm: { [weak self] in
                        self?.confirmLockedSlashCommand(
                            itemId: itemId,
                            title: title,
                            locked: locked,
                            intent: intent
                        )
                    }
                ) {
                    return
                }
                appendLockedSlashFailure(error: reviewError)
                return
            }
            appendLockedSlashMessage(title: title, locked: locked)
        } catch {
            appendLockedSlashFailure(error: error)
        }
    }

    private func confirmLockedSlashCommand(
        itemId: UUID,
        title: String,
        locked: Bool,
        intent: ActionIntent
    ) {
        do {
            try executeConfirmedSemanticAction(intent: intent) {
                sortEngine.setLocked(locked, itemId: itemId)
                return ActionExecutionResult(payload: ["locked": locked ? "true" : "false"])
            }
            appendLockedSlashMessage(title: title, locked: locked)
        } catch {
            appendLockedSlashFailure(error: error)
        }
    }

    private func applySelectSlashCommand(
        _ workspace: Workspace,
        title: String,
        tabManager: TabManager
    ) {
        let intent = assistantActionIntent(
            kind: .switchWorkspace,
            route: nil,
            arguments: ["workspaceId": workspace.id.uuidString],
            workspaceIds: [workspace.id],
            reason: nil
        )
        do {
            let review = try submitReviewedAction(intent) {
                tabManager.selectWorkspace(workspace)
                return ActionExecutionResult(payload: ["workspaceId": workspace.id.uuidString])
            }
            guard review.decision == .allow else {
                let reviewError = SemanticActionReviewError(intent: intent, result: review)
                if queueSemanticActionConfirmation(
                    for: reviewError,
                    actionName: Self.semanticActionDisplayName(.switchWorkspace),
                    confirm: { [weak self, weak workspace, weak tabManager] in
                        guard let self, let workspace, let tabManager else { return }
                        self.confirmSelectSlashCommand(
                            workspace,
                            title: title,
                            tabManager: tabManager,
                            intent: intent
                        )
                    }
                ) {
                    return
                }
                appendSelectSlashFailure(error: reviewError)
                return
            }
            appendSelectSlashMessage(title: title)
        } catch {
            appendSelectSlashFailure(error: error)
        }
    }

    private func confirmSelectSlashCommand(
        _ workspace: Workspace,
        title: String,
        tabManager: TabManager,
        intent: ActionIntent
    ) {
        do {
            try executeConfirmedSemanticAction(intent: intent) {
                tabManager.selectWorkspace(workspace)
                return ActionExecutionResult(payload: ["workspaceId": workspace.id.uuidString])
            }
            appendSelectSlashMessage(title: title)
        } catch {
            appendSelectSlashFailure(error: error)
        }
    }

    private func appendPinnedSlashMessage(title: String, pinned: Bool) {
        let message = pinned
            ? String(
                format: String(localized: "sortAssistant.slash.pin.done", defaultValue: "Pinned %@."),
                title
            )
            : String(
                format: String(localized: "sortAssistant.slash.unpin.done", defaultValue: "Unpinned %@."),
                title
            )
        append(.init(kind: .assistant, text: message))
    }

    private func appendLockedSlashMessage(title: String, locked: Bool) {
        let message = locked
            ? String(
                format: String(localized: "sortAssistant.slash.lock.done", defaultValue: "Locked %@ for sorting."),
                title
            )
            : String(
                format: String(localized: "sortAssistant.slash.unlock.done", defaultValue: "Unlocked %@ for sorting."),
                title
            )
        append(.init(kind: .assistant, text: message))
    }

    private func appendSelectSlashMessage(title: String) {
        append(.init(
            kind: .assistant,
            text: String(
                format: String(
                    localized: "sortAssistant.slash.select.done",
                    defaultValue: "Selected %@."
                ),
                title
            )
        ))
    }

    private func appendPinnedSlashFailure(error: Error) {
        append(.init(
            kind: .error,
            text: String(localized: "sortAssistant.slash.pin.failed", defaultValue: "Could not change the workspace pin: ") + Self.displayMessage(for: error)
        ))
    }

    private func appendLockedSlashFailure(error: Error) {
        append(.init(
            kind: .error,
            text: String(localized: "sortAssistant.slash.lock.failed", defaultValue: "Could not change the workspace lock: ") + Self.displayMessage(for: error)
        ))
    }

    private func appendSelectSlashFailure(error: Error) {
        append(.init(
            kind: .error,
            text: String(localized: "sortAssistant.slash.select.failed", defaultValue: "Could not select the workspace: ") + Self.displayMessage(for: error)
        ))
    }

    @discardableResult
    private func queueSemanticActionConfirmation(
        for error: SemanticActionReviewError,
        actionName: String? = nil,
        confirm: @escaping () -> Void
    ) -> Bool {
        guard error.result.decision == .requireConfirmation else {
            return false
        }
        let confirmationId = UUID()
        let reasons = error.result.reasons.isEmpty
            ? [String(localized: "sortAssistant.actionReview.noReason", defaultValue: "No review reason was provided.")]
            : error.result.reasons
        let displayName = actionName ?? Self.semanticActionDisplayName(error.intent.kind)
        let reasonSummary = reasons.joined(separator: ", ")
        semanticActionConfirmation = SortAssistantSemanticActionConfirmation(
            id: confirmationId,
            title: String(localized: "sortAssistant.actionReview.confirmTitle", defaultValue: "Confirm reviewed action"),
            message: String(
                format: String(
                    localized: "sortAssistant.actionReview.confirmMessage",
                    defaultValue: "cmux reviewed %@ and needs your confirmation before applying it: %@"
                ),
                displayName,
                reasonSummary
            ),
            reasons: reasons,
            actionName: displayName
        )
        pendingSemanticActionConfirmation = PendingSemanticActionConfirmation(
            id: confirmationId,
            intent: error.intent,
            confirm: confirm
        )
        return true
    }

#if DEBUG
    func debugQueueSemanticActionConfirmation(
        actionName: String,
        reasons: [String],
        confirm: @escaping () -> Void
    ) {
        let intent = ActionIntent(
            id: UUID(),
            requestedBy: ActionRequester(id: "cmux_sprite_debug", route: SortAssistantIntent.applySort.rawValue),
            kind: .applySort,
            arguments: [
                "patchId": UUID().uuidString,
                "itemIds": UUID().uuidString,
            ],
            reason: nil,
            evidence: ActionEvidence(
                snapshotVersions: [:],
                snapshotUpdatedAt: [:],
                suggestionId: nil,
                rankingSnapshotId: nil
            ),
            createdAt: Date()
        )
        let result = SemanticReviewResult(
            intentId: intent.id,
            decision: .requireConfirmation,
            reasons: reasons,
            executed: false,
            executionResult: nil
        )
        _ = queueSemanticActionConfirmation(
            for: SemanticActionReviewError(intent: intent, result: result),
            actionName: actionName,
            confirm: confirm
        )
    }
#endif

    func undo(tabManager: TabManager) {
        do {
            guard try undoSortThroughGateway(tabManager: tabManager) != nil else {
                append(.init(
                    kind: .assistant,
                    text: String(localized: "sortAssistant.undo.none", defaultValue: "There is no assistant sort to undo.")
                ))
                return
            }
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            latestResult?.canUndo = false
            latestResult?.canApply = false
            latestResult?.canApplyPartially = false
            latestResult?.canIgnore = false
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.undo.done", defaultValue: "Restored the previous workspace order.")
            ))
        } catch let reviewError as SemanticActionReviewError {
            if queueSemanticActionConfirmation(
                for: reviewError,
                actionName: Self.semanticActionDisplayName(.undoSort),
                confirm: { [weak self, weak tabManager] in
                    guard let self, let tabManager else { return }
                    self.confirmUndo(tabManager: tabManager, intent: reviewError.intent)
                }
            ) {
                return
            }
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.undo.failed", defaultValue: "Undo failed: ") + Self.displayMessage(for: reviewError)
            ))
        } catch {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.undo.failed", defaultValue: "Undo failed: ") + Self.displayMessage(for: error)
            ))
        }
    }

    private func confirmUndo(tabManager: TabManager, intent: ActionIntent) {
        do {
            guard try executeConfirmedUndo(tabManager: tabManager, intent: intent) != nil else {
                append(.init(
                    kind: .assistant,
                    text: String(localized: "sortAssistant.undo.none", defaultValue: "There is no assistant sort to undo.")
                ))
                return
            }
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            latestResult?.canUndo = false
            latestResult?.canApply = false
            latestResult?.canApplyPartially = false
            latestResult?.canIgnore = false
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.undo.done", defaultValue: "Restored the previous workspace order.")
            ))
        } catch {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.undo.failed", defaultValue: "Undo failed: ") + Self.displayMessage(for: error)
            ))
        }
    }

    func createMemoryCandidateFromResult() {
        guard let latestResult else { return }
        let text = String(
            localized: "sortAssistant.memory.fromResult",
            defaultValue: "When sorting workspaces, consider: \(latestResult.goal)"
        )
        memoryCandidate = SortAssistantMemoryCandidate(
            text: text,
            sourceSummary: latestResult.rationale
        )
    }

    func updateMemoryCandidate(text: String) {
        guard var candidate = memoryCandidate else { return }
        candidate.text = text
        memoryCandidate = candidate
    }

    func confirmMemoryCandidate() {
        guard let candidate = memoryCandidate else { return }
        let text = normalized(candidate.text)
        guard !text.isEmpty else { return }
        let memory = SortAssistantMemory(id: UUID(), text: text, createdAt: Date())
        let domain = candidate.target == .sprite ? "sprite" : "free_sort"
        let route: SortAssistantIntent = candidate.target == .sprite ? .rememberSpriteMemory : .rememberPreference
        let directory = candidate.target == .sprite
            ? (currentSpriteMemoryDirectory ?? lastTabManager.flatMap(Self.workspaceDirectoryForMCP))
            : nil
        let intent = assistantActionIntent(
            kind: .writeMemory,
            route: route,
            arguments: [
                "domain": domain,
                "text": text,
                "directory": directory ?? "",
            ],
            workspaceIds: [],
            reason: candidate.sourceSummary
        )
        do {
            var missingSpriteDirectory = false
            let review = try submitReviewedAction(intent) {
                if candidate.target == .sprite {
                    guard let fileURL = try SpriteWorkspaceMemoryDocument.append(memory, directory: directory) else {
                        missingSpriteDirectory = true
                        return ActionExecutionResult(payload: ["created": "false"])
                    }
                    spriteMemories.insert(memory, at: 0)
                    spriteMemorySources[memory.id] = .workspace(fileURL)
                    currentSpriteMemoryFileURL = fileURL
                    memoryCandidate = nil
                    return ActionExecutionResult(payload: ["created": "true", "memoryFile": fileURL.path])
                }

                pendingCreatedMemories[memory.id] = memory
                memories.insert(memory, at: 0)
                persistCreatedMemory(memory)
                memoryCandidate = nil
                return ActionExecutionResult(payload: ["created": "true"])
            }
            guard review.decision == .allow else {
                throw SemanticActionReviewError(intent: intent, result: review)
            }
            if missingSpriteDirectory {
                append(.init(
                    kind: .error,
                    text: String(localized: "sortAssistant.spriteMemory.noWorkspaceDirectory", defaultValue: "No workspace directory is available for memory.md.")
                ))
                return
            }
            append(.init(
                kind: .assistant,
                text: candidate.target == .sprite
                    ? String(localized: "sortAssistant.spriteMemory.savedToFileReply", defaultValue: "Saved that sprite memory to memory.md.")
                    : String(localized: "sortAssistant.memory.savedReply", defaultValue: "Saved that sorting memory.")
            ))
        } catch {
            append(.init(
                kind: .error,
                text: (candidate.target == .sprite
                    ? String(localized: "sortAssistant.spriteMemory.saveFileFailed", defaultValue: "Could not write memory.md: ")
                    : String(localized: "sortAssistant.memory.saveFailed", defaultValue: "Could not save sorting memory: "))
                    + Self.displayMessage(for: error)
            ))
        }
    }

    private func deleteMemoryWithoutReview(_ memory: SortAssistantMemory) {
        pendingCreatedMemories.removeValue(forKey: memory.id)
        pendingDeletedMemoryIds.insert(memory.id)
        memories.removeAll { $0.id == memory.id }
#if DEBUG
        if debugEphemeralFreeSortMemoryIds.remove(memory.id) != nil {
            pendingDeletedMemoryIds.remove(memory.id)
            return
        }
#endif
        Task { @MainActor [weak self] in
            do {
                try await SortAssistantWorkstreamPersistence.shared.rewriteDroppingToolResults(
                    toolName: Self.memoryToolName,
                    containing: memory.id.uuidString
                )
                self?.pendingDeletedMemoryIds.remove(memory.id)
                self?.reloadFreeSortMemories(reason: "deleteMemory")
            } catch {
                self?.pendingDeletedMemoryIds.remove(memory.id)
#if DEBUG
                cmuxDebugLog("sprite.memory freeSort.deleteFailed id=\(memory.id.uuidString) error=\(Self.displayMessage(for: error))")
#endif
            }
        }
    }

    private func deleteSpriteMemoryWithoutReview(_ memory: SortAssistantMemory) {
        spriteMemories.removeAll { $0.id == memory.id }
        guard case .some(.workspace(let fileURL)) = spriteMemorySources.removeValue(forKey: memory.id) else {
            return
        }
        try? SpriteWorkspaceMemoryDocument.delete(
            memoryId: memory.id,
            containing: nil,
            from: fileURL
        )
    }

    func deleteMemory(_ memory: SortAssistantMemory) {
        let intent = assistantActionIntent(
            kind: .forgetMemory,
            route: .forgetPreference,
            arguments: [
                "domain": "free_sort",
                "id": memory.id.uuidString,
                "text": memory.text,
            ],
            workspaceIds: [],
            reason: nil
        )
        do {
            let review = try submitReviewedAction(intent) {
                deleteMemoryWithoutReview(memory)
                return ActionExecutionResult(payload: ["deleted": "1"])
            }
            guard review.decision == .allow else {
                throw SemanticActionReviewError(intent: intent, result: review)
            }
        } catch {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.memory.deleteFailed", defaultValue: "Could not delete sorting memory: ") + Self.displayMessage(for: error)
            ))
        }
    }

    func deleteSpriteMemory(_ memory: SortAssistantMemory) {
        let intent = assistantActionIntent(
            kind: .forgetMemory,
            route: .forgetSpriteMemory,
            arguments: [
                "domain": "sprite",
                "id": memory.id.uuidString,
                "text": memory.text,
                "directory": currentSpriteMemoryDirectory ?? "",
            ],
            workspaceIds: [],
            reason: nil
        )
        do {
            let review = try submitReviewedAction(intent) {
                deleteSpriteMemoryWithoutReview(memory)
                return ActionExecutionResult(payload: ["deleted": "1"])
            }
            guard review.decision == .allow else {
                throw SemanticActionReviewError(intent: intent, result: review)
            }
        } catch {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.spriteMemory.deleteFailed", defaultValue: "Could not delete sprite memory: ") + Self.displayMessage(for: error)
            ))
        }
    }

    func discardMemoryCandidate() {
        memoryCandidate = nil
        append(.init(
            kind: .assistant,
            text: String(localized: "sortAssistant.memory.discardedReply", defaultValue: "Discarded the memory candidate.")
        ))
    }

    func applyLatestPreview(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        applyPendingPreview(
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            partialLimit: nil
        )
    }

    func applyLatestPreviewPartially(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        applyPendingPreview(
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            partialLimit: 5
        )
    }

    func rejectLatestPreview() {
        guard let patch = pendingPreviewPatch else { return }
        sortOperator.reject(
            patch: patch,
            reason: String(localized: "sortAssistant.preview.rejectedReason", defaultValue: "Rejected from sprite preview")
        )
        pendingPreviewPatch = nil
        pendingPreviewSort = nil
        latestResult?.canApply = false
        latestResult?.canApplyPartially = false
        latestResult?.canIgnore = false
        append(.init(
            kind: .assistant,
            text: String(localized: "sortAssistant.preview.ignored", defaultValue: "Ignored that sort proposal.")
        ))
    }

    func explainLatestPreview() {
        if let rationale = latestResult?.rationale, !rationale.isEmpty {
            append(.init(kind: .assistant, text: rationale))
            return
        }
        if let changes = latestResult?.changes, !changes.isEmpty {
            append(.init(
                kind: .assistant,
                text: changes.joined(separator: "\n")
            ))
            return
        }
        append(.init(
            kind: .assistant,
            text: String(localized: "sortAssistant.preview.noExplanation", defaultValue: "This proposal follows the selected priority dimension, saved memories, pinned workspace rules, and locked workspace rules.")
        ))
    }

    func recordUserDragMove(
        itemId: UUID,
        fromIndex: Int,
        toIndex: Int,
        revision: Int,
        reason: String? = nil
    ) {
        sortOperator.recordUserDragMove(
            itemId: itemId,
            fromIndex: fromIndex,
            toIndex: toIndex,
            revision: revision,
            reason: reason
        )
    }

    @discardableResult
    func applySummaryPriorityWorkspaceOrder(
        _ summaryPriority: WorkspaceSidebarSummaryPriorityState,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) -> Bool {
        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        guard !workspaceTabStore.selectedSort.isNative else { return false }
        let orderedWorkspaceIds = WorkspaceTabStore.orderedWorkspaceIds(
            from: summaryPriority,
            tabs: tabManager.tabs,
            sort: workspaceTabStore.selectedSort,
            recentWorkspaceIds: workspaceTabStore.recentWorkspaceIds
        )
        guard !orderedWorkspaceIds.isEmpty else { return false }
        let patch = sortOperator.makeBatchPatch(
            orderedIds: orderedWorkspaceIds,
            tabs: tabManager.tabs,
            rationale: String(localized: "sortAssistant.summaryPriority.rationale", defaultValue: "Apply summary priority order."),
            confidence: nil,
            requiresConfirmation: false
        )
        do {
            let signals = contextProvider.itemSignals(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
            _ = try applySortPatchThroughGateway(
                patch,
                tabManager: tabManager,
                itemSignals: signals,
                actor: "summary_priority_sidebar",
                requesterId: "cmux_summary_priority"
            )
            return true
        } catch {
#if DEBUG
            cmuxDebugLog("summaryPriority.sidebar.reorder.failed \(Self.displayMessage(for: error))")
#endif
            return false
        }
    }

    private func startSort(
        goal: String,
        mode: SortAssistantRunMode,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        guard !isSorting else {
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.sort.busy", defaultValue: "A workspace sort is already running.")
            ))
            return
        }

        let selectedSort = workspaceTabStore.selectedSort
        guard selectedSort.isDimension else {
            dimensionQuestion = SortAssistantDimensionQuestion(goal: goal, mode: mode)
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.dimension.needChoice", defaultValue: "The current sort is not a priority dimension, so I need one choice first.")
            ))
            return
        }

        pendingPreviewPatch = nil
        pendingPreviewSort = nil
        latestResult = nil
        isSorting = true
        append(.init(
            kind: .progress,
            text: String(localized: "sortAssistant.sort.running", defaultValue: "Scoring workspaces with the current priority dimension...")
        ))

        let assistantContext = WorkspaceSidebarAssistantContext(
            requestId: UUID().uuidString,
            goal: goal,
            memorySnippets: memories.prefix(8).map(\.text),
            resultMode: mode.assistantContextValue,
            allowedResultActions: Self.allowedResultActions(for: mode).map(\.rawValue)
        )
        workspaceTabStore.refreshSummaryPriority(
            force: true,
            sort: selectedSort,
            assistantContext: assistantContext
        ) { [weak self, weak tabManager, weak workspaceTabStore] result in
            guard let self else { return }
            self.isSorting = false
            guard let tabManager, let workspaceTabStore else { return }
            switch result {
            case .failure(let error):
                self.latestResult = nil
                self.append(.init(
                    kind: .error,
                    text: String(localized: "sortAssistant.sort.failed", defaultValue: "Sort failed: ") + Self.displayMessage(for: error)
                ))
            case .success(let state):
                self.handleSortState(
                    state,
                    sort: selectedSort,
                    goal: goal,
                    mode: mode,
                    tabManager: tabManager,
                    workspaceTabStore: workspaceTabStore
                )
            }
        }
    }

    private func handleSortState(
        _ state: WorkspaceSidebarSummaryPriorityState,
        sort: WorkspaceSidebarSummaryPrioritySort,
        goal: String,
        mode: SortAssistantRunMode,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        let ordered = WorkspaceTabStore.orderedWorkspaceIds(
            from: state,
            tabs: tabManager.tabs,
            sort: sort,
            recentWorkspaceIds: workspaceTabStore.recentWorkspaceIds
        )
        guard !ordered.isEmpty else {
            latestResult = nil
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.sort.noOrder", defaultValue: "Digest returned no applicable workspace order.")
            ))
            return
        }
        let presentation = Self.topPresentation(from: state, sort: sort)
        let patch = sortOperator.makeBatchPatch(
            orderedIds: ordered,
            tabs: tabManager.tabs,
            rationale: presentation.markdown,
            confidence: nil,
            requiresConfirmation: mode == .preview
        )
        let dimensionLabel = Self.dimensionLabel(sort)
        do {
            let preview = try sortOperator.preview(patch: patch, tabs: tabManager.tabs)
            switch mode {
            case .preview:
                pendingPreviewPatch = patch
                pendingPreviewSort = sort
                let sortResult = SortAssistantSortResult(
                    title: String(localized: "sortAssistant.preview.title", defaultValue: "Preview sorted by \(dimensionLabel)"),
                    goal: goal,
                    dimensionLabel: dimensionLabel,
                    changes: preview.changes,
                    rationale: preview.rationale,
                    patchId: patch.id,
                    mode: .preview,
                    canUndo: false,
                    canApply: true,
                    canApplyPartially: true,
                    canIgnore: true,
                    actions: Self.availableResultActions(presentation.actions, resultMode: .preview)
                )
                let anchorMessageId = append(.init(
                    kind: .assistant,
                    text: String(localized: "sortAssistant.preview.ready", defaultValue: "I prepared a sort preview.")
                ))
                setLatestResult(sortResult, anchorMessageId: anchorMessageId)
            case .apply:
                let result = try applySortPatchThroughGateway(
                    patch,
                    tabManager: tabManager,
                    actor: "sort_assistant"
                )
                finishAppliedSortResult(
                    result,
                    label: dimensionLabel,
                    goal: goal,
                    patch: patch,
                    actions: Self.availableResultActions(presentation.actions, resultMode: .applied),
                    workspaceTabStore: workspaceTabStore,
                    sortToSelect: nil
                )
            }
        } catch let reviewError as SemanticActionReviewError {
            if queueSemanticActionConfirmation(
                for: reviewError,
                actionName: Self.semanticActionDisplayName(.applySort),
                confirm: { [weak self, weak tabManager, weak workspaceTabStore] in
                    guard let self, let tabManager, let workspaceTabStore else { return }
                    do {
                        let result = try self.executeConfirmedSortPatch(
                            patch,
                            tabManager: tabManager,
                            actor: "sort_assistant_confirmed",
                            intent: reviewError.intent
                        )
                        self.finishAppliedSortResult(
                            result,
                            label: dimensionLabel,
                            goal: goal,
                            patch: patch,
                            actions: Self.availableResultActions(presentation.actions, resultMode: .applied),
                            workspaceTabStore: workspaceTabStore,
                            sortToSelect: nil
                        )
                    } catch {
                        self.latestResult = nil
                        self.pendingPreviewPatch = nil
                        self.pendingPreviewSort = nil
                        self.append(.init(
                            kind: .error,
                            text: String(localized: "sortAssistant.sort.failed", defaultValue: "Sort failed: ") + Self.displayMessage(for: error)
                        ))
                    }
                }
            ) {
                return
            }
            latestResult = nil
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.sort.failed", defaultValue: "Sort failed: ") + Self.displayMessage(for: reviewError)
            ))
        } catch {
            latestResult = nil
            pendingPreviewPatch = nil
            pendingPreviewSort = nil
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.sort.failed", defaultValue: "Sort failed: ") + Self.displayMessage(for: error)
            ))
        }
    }

    private func explainCurrentOrder(workspaceTabStore: WorkspaceTabStore) {
        guard let summary = workspaceTabStore.summaryPriority,
              let first = summary.items.first else {
            append(.init(
                kind: .assistant,
                text: String(localized: "sortAssistant.explain.empty", defaultValue: "Refresh summary priority first so I can explain the current order.")
            ))
            return
        }
        append(.init(
            kind: .assistant,
            text: first.scores.rankReason.isEmpty
                ? String(localized: "sortAssistant.explain.noReason", defaultValue: "The current order follows the selected priority dimension and pinned workspace rules.")
                : first.scores.rankReason
        ))
    }

    private func persistCreatedMemory(_ memory: SortAssistantMemory) {
        let event = SortAssistantMemoryEvent(
            schemaVersion: Self.memorySchemaVersion,
            eventType: .created,
            memoryId: memory.id.uuidString,
            text: memory.text,
            createdAt: Self.iso8601Formatter.string(from: memory.createdAt)
        )
        guard let data = try? JSONEncoder().encode(event),
              let resultJSON = String(data: data, encoding: .utf8) else {
            return
        }
        let item = WorkstreamItem(
            workstreamId: Self.workstreamId,
            source: .cmux,
            kind: .toolResult,
            title: String(localized: "sortAssistant.memory.eventTitle", defaultValue: "Sort memory"),
            payload: .toolResult(
                toolName: Self.memoryToolName,
                resultJSON: resultJSON,
                isError: false
            )
        )
        Task { @MainActor [weak self] in
            do {
                try await SortAssistantWorkstreamPersistence.shared.append(item)
                self?.pendingCreatedMemories.removeValue(forKey: memory.id)
                self?.reloadFreeSortMemories(reason: "persistCreatedMemory")
            } catch {
                self?.pendingCreatedMemories.removeValue(forKey: memory.id)
#if DEBUG
                cmuxDebugLog("sprite.memory freeSort.persistFailed id=\(memory.id.uuidString) error=\(Self.displayMessage(for: error))")
#endif
            }
        }
    }

    private func applyPendingPreview(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        partialLimit: Int?
    ) {
        rememberStores(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        guard let patch = pendingPreviewPatch else { return }
        let sortToSelect = pendingPreviewSort
        let itemSignals = contextProvider.itemSignals(
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore
        )
        let previousResult = latestResult
        var patchToApply: SortPatch?
        do {
            if let partialLimit {
                let preview = try sortOperator.preview(
                    patch: patch,
                    tabs: tabManager.tabs,
                    itemSignals: itemSignals
                )
                let selectedIds = Array(preview.affectedItemIds.prefix(partialLimit))
                patchToApply = sortOperator.makeBatchPatch(
                    orderedIds: selectedIds,
                    tabs: tabManager.tabs,
                    rationale: String(localized: "sortAssistant.preview.partialRationale", defaultValue: "Apply the highest-impact moves from the assistant proposal."),
                    confidence: patch.confidence,
                    requiresConfirmation: false
                )
            } else {
                patchToApply = SortPatch(
                    id: patch.id,
                    listId: patch.listId,
                    baseRevision: SortEngine.revision(for: tabManager.tabs),
                    operations: patch.operations,
                    rationale: patch.rationale,
                    confidence: patch.confidence,
                    requiresConfirmation: false
                )
            }
            guard let patchToApply else { return }
            let result = try applySortPatchThroughGateway(
                patchToApply,
                tabManager: tabManager,
                itemSignals: itemSignals,
                actor: partialLimit == nil ? "sort_assistant_preview_apply" : "sort_assistant_preview_partial_apply"
            )
            finishAppliedPreview(
                result,
                patch: patchToApply,
                goalFallback: patch.rationale,
                previousResult: previousResult,
                sortToSelect: sortToSelect,
                workspaceTabStore: workspaceTabStore,
                partialLimit: partialLimit
            )
        } catch let reviewError as SemanticActionReviewError {
            guard let patchToApply else {
                append(.init(
                    kind: .error,
                    text: String(localized: "sortAssistant.preview.applyFailed", defaultValue: "Could not apply the preview: ") + Self.displayMessage(for: reviewError)
                ))
                return
            }
            if queueSemanticActionConfirmation(
                for: reviewError,
                actionName: Self.semanticActionDisplayName(.applySort),
                confirm: { [weak self, weak tabManager, weak workspaceTabStore] in
                    guard let self, let tabManager, let workspaceTabStore else { return }
                    self.confirmApplyPreview(
                        patch: patchToApply,
                        goalFallback: patch.rationale,
                        previousResult: previousResult,
                        sortToSelect: sortToSelect,
                        itemSignals: itemSignals,
                        tabManager: tabManager,
                        workspaceTabStore: workspaceTabStore,
                        partialLimit: partialLimit,
                        intent: reviewError.intent
                    )
                }
            ) {
                return
            }
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.preview.applyFailed", defaultValue: "Could not apply the preview: ") + Self.displayMessage(for: reviewError)
            ))
        } catch {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.preview.applyFailed", defaultValue: "Could not apply the preview: ") + Self.displayMessage(for: error)
            ))
        }
    }

    private func confirmApplyPreview(
        patch: SortPatch,
        goalFallback: String?,
        previousResult: SortAssistantSortResult?,
        sortToSelect: WorkspaceSidebarSummaryPrioritySort?,
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals],
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        partialLimit: Int?,
        intent: ActionIntent
    ) {
        do {
            let result = try executeConfirmedSortPatch(
                patch,
                tabManager: tabManager,
                itemSignals: itemSignals,
                actor: partialLimit == nil ? "sort_assistant_preview_apply_confirmed" : "sort_assistant_preview_partial_apply_confirmed",
                intent: intent
            )
            finishAppliedPreview(
                result,
                patch: patch,
                goalFallback: goalFallback,
                previousResult: previousResult,
                sortToSelect: sortToSelect,
                workspaceTabStore: workspaceTabStore,
                partialLimit: partialLimit
            )
        } catch {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.preview.applyFailed", defaultValue: "Could not apply the preview: ") + Self.displayMessage(for: error)
            ))
        }
    }

    private func finishAppliedPreview(
        _ result: SortEngineApplyResult,
        patch: SortPatch,
        goalFallback: String?,
        previousResult: SortAssistantSortResult?,
        sortToSelect: WorkspaceSidebarSummaryPrioritySort?,
        workspaceTabStore: WorkspaceTabStore,
        partialLimit: Int?
    ) {
        pendingPreviewPatch = nil
        pendingPreviewSort = nil
        if let sortToSelect {
            workspaceTabStore.setSort(sortToSelect)
        }
        let sortResult = SortAssistantSortResult(
            title: String(localized: "sortAssistant.result.title", defaultValue: "Sorted by \(previousResult?.dimensionLabel ?? Self.dimensionLabel(workspaceTabStore.selectedSort))"),
            goal: previousResult?.goal ?? goalFallback ?? "",
            dimensionLabel: previousResult?.dimensionLabel ?? Self.dimensionLabel(workspaceTabStore.selectedSort),
            changes: result.preview.changes,
            rationale: result.preview.rationale,
            patchId: patch.id,
            mode: .applied,
            canUndo: true,
            canApply: false,
            canApplyPartially: false,
            canIgnore: false,
            actions: Self.availableResultActions(previousResult?.actions ?? [], resultMode: .applied)
        )
        let anchorMessageId = append(.init(
            kind: .assistant,
            text: partialLimit == nil
                ? String(localized: "sortAssistant.preview.applied", defaultValue: "Applied the sort proposal.")
                : String(localized: "sortAssistant.preview.partialApplied", defaultValue: "Applied the highest-impact moves from the proposal.")
        ))
        setLatestResult(sortResult, anchorMessageId: anchorMessageId)
    }

    private func finishAppliedSortResult(
        _ applied: SortEngineApplyResult,
        label: String,
        goal: String,
        patch: SortPatch,
        actions: [SortAssistantResultAction],
        workspaceTabStore: WorkspaceTabStore,
        sortToSelect: WorkspaceSidebarSummaryPrioritySort?
    ) {
        pendingPreviewPatch = nil
        pendingPreviewSort = nil
        if let sortToSelect {
            workspaceTabStore.setSort(sortToSelect)
        }
        let result = SortAssistantSortResult(
            title: String(localized: "sortAssistant.result.title", defaultValue: "Sorted by \(label)"),
            goal: goal,
            dimensionLabel: label,
            changes: applied.preview.changes,
            rationale: applied.preview.rationale,
            patchId: patch.id,
            mode: .applied,
            canUndo: true,
            canApply: false,
            canApplyPartially: false,
            canIgnore: false,
            actions: actions
        )
        let anchorMessageId = append(.init(
            kind: .assistant,
            text: String(localized: "sortAssistant.sort.done", defaultValue: "Applied the workspace sort.")
        ))
        setLatestResult(result, anchorMessageId: anchorMessageId)
    }

    private func setLatestResult(
        _ result: SortAssistantSortResult,
        anchorMessageId: UUID? = nil
    ) {
        choicePrompt = nil
        latestResultAnchorMessageId = anchorMessageId ?? messages.last?.id
        latestResult = result
    }

    private func semanticConversationContext(
        limit: Int = 10,
        workspaceTarget: SortAssistantWorkspaceTarget? = nil
    ) -> [String] {
        var context = messages.suffix(limit).map { message in
            "\(Self.semanticRole(for: message.kind)): \(message.text)"
        }
        if let workspaceTarget {
            let directory = workspaceTarget.directory ?? "unknown"
            context.append("target_workspace: \(workspaceTarget.title) id=\(workspaceTarget.id.uuidString) directory=\(directory)")
        }
        return context
    }

    private static func semanticRole(for kind: SortAssistantMessage.Kind) -> String {
        switch kind {
        case .user:
            return "user"
        case .assistant:
            return "assistant"
        case .progress:
            return "assistant_status"
        case .warning:
            return "assistant_warning"
        case .error:
            return "assistant_error"
        }
    }

    @discardableResult
    private func append(_ message: SortAssistantMessage) -> UUID {
        let debugKind = String(describing: message.kind)
#if DEBUG
        let previousCount = messages.count
        debugLogSpriteGeometrySnapshot(
            "conversation.message.beforeAppend kind=\(debugKind) count=\(previousCount)"
        )
#endif
        messages.append(message)
        if messages.count > 40 {
            messages.removeFirst(messages.count - 40)
            if let anchorId = latestResultAnchorMessageId,
               !messages.contains(where: { $0.id == anchorId }) {
                latestResultAnchorMessageId = messages.first?.id
            }
        }
        invalidateFloatingLayout(reason: "message.\(debugKind)")
#if DEBUG
        let currentCount = messages.count
        debugLogSpriteGeometrySnapshot(
            "conversation.message.afterAppend kind=\(debugKind) count=\(currentCount)"
        )
        DispatchQueue.main.async { [weak self] in
            self?.debugLogSpriteGeometrySnapshot(
                "conversation.message.afterAppendLayout kind=\(debugKind) count=\(currentCount)"
            )
        }
#endif
        return message.id
    }

    private func updateMessage(id: UUID, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].text != text else {
            return
        }
        let kind = messages[index].kind
        messages[index] = SortAssistantMessage(id: id, kind: kind, text: text)
        invalidateFloatingLayout(reason: "message.update.\(kind)")
#if DEBUG
        debugLogSpriteGeometrySnapshot(
            "conversation.message.update kind=\(kind) count=\(messages.count) chars=\(text.count)"
        )
#endif
    }

    private func removeMessage(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let kind = messages[index].kind
        messages.remove(at: index)
        if latestResultAnchorMessageId == id {
            latestResultAnchorMessageId = messages.last?.id
        }
        invalidateFloatingLayout(reason: "message.remove.\(kind)")
#if DEBUG
        debugLogSpriteGeometrySnapshot(
            "conversation.message.remove kind=\(kind) count=\(messages.count)"
        )
#endif
    }

    private func invalidateFloatingLayout(reason: String) {
        floatingLayoutRevision += 1
#if DEBUG
        cmuxDebugLog("sprite.coordinator floatingLayoutRevision=\(floatingLayoutRevision) reason=\(reason)")
#endif
    }

    private func reloadFreeSortMemories(reason: String = "unspecified") {
        let loaded = Self.loadLegacyMemories(from: memoryFileURL)
            .filter { !pendingDeletedMemoryIds.contains($0.id) }
        let loadedIds = Set(loaded.map(\.id))
        let pending = pendingCreatedMemories.values
            .filter { !loadedIds.contains($0.id) && !pendingDeletedMemoryIds.contains($0.id) }
        let next = (loaded + pending).sorted { $0.createdAt > $1.createdAt }
        if next != memories {
            memories = next
        }
#if DEBUG
        cmuxDebugLog(
            "sprite.memory freeSort.reload reason=\(reason) count=\(memories.count) pendingCreated=\(pendingCreatedMemories.count) pendingDeleted=\(pendingDeletedMemoryIds.count)"
        )
#endif
    }

    private func reloadSpriteMemories(directory: String?) {
        currentSpriteMemoryDirectory = directory
        currentSpriteMemoryFileURL = SpriteWorkspaceMemoryDocument.fileURL(directory: directory)
        let loaded = SpriteWorkspaceMemoryDocument.load(directory: directory)
        spriteMemories = loaded.memories
        spriteMemorySources = loaded.sources
    }

    private static func loadLegacyMemories(from fileURL: URL) -> [SortAssistantMemory] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let itemDecoder = JSONDecoder()
        itemDecoder.dateDecodingStrategy = .iso8601
        let eventDecoder = JSONDecoder()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var memoriesById: [UUID: SortAssistantMemory] = [:]
        for line in lines {
            let lineData = Data(line)
            guard let item = try? itemDecoder.decode(WorkstreamItem.self, from: lineData),
                  case .toolResult(let toolName, let resultJSON, false) = item.payload,
                  toolName == memoryToolName,
                  let eventData = resultJSON.data(using: .utf8),
                  let event = try? eventDecoder.decode(SortAssistantMemoryEvent.self, from: eventData),
                  event.schemaVersion == memorySchemaVersion,
                  let memoryId = UUID(uuidString: event.memoryId) else {
                continue
            }
            switch event.eventType {
            case .created:
                let createdAt = iso8601Formatter.date(from: event.createdAt) ?? item.createdAt
                memoriesById[memoryId] = SortAssistantMemory(
                    id: memoryId,
                    text: event.text,
                    createdAt: createdAt
                )
            }
        }
        return memoriesById.values.sorted { $0.createdAt > $1.createdAt }
    }

    private static func topChanges(
        before: [UUID],
        after: [UUID],
        titleById: [UUID: String]
    ) -> [String] {
        SortEngine.topChanges(before: before, after: after, titleById: titleById)
    }

    private static func topRationale(
        from state: WorkspaceSidebarSummaryPriorityState,
        sort: WorkspaceSidebarSummaryPrioritySort
    ) -> String? {
        let dimensionId = sort.dimensionId ?? "urgency"
        return nonEmpty(state.items.first?.scores.dimensions[dimensionId]?.reason)
            ?? nonEmpty(state.items.first?.scores.rankReason)
    }

    private static func topPresentation(
        from state: WorkspaceSidebarSummaryPriorityState,
        sort: WorkspaceSidebarSummaryPrioritySort
    ) -> SortAssistantResultPresentation {
        SortAssistantResultPresentation.parse(topRationale(from: state, sort: sort))
    }

    private static func allowedResultActions(for mode: SortAssistantRunMode) -> [SortAssistantResultAction] {
        switch mode {
        case .preview:
            return [.apply, .partialApply, .ignore, .explain]
        case .apply:
            return [.undo, .remember, .explain]
        }
    }

    private static func availableResultActions(
        _ actions: [SortAssistantResultAction],
        resultMode: SortAssistantResultMode
    ) -> [SortAssistantResultAction] {
        let allowed: Set<SortAssistantResultAction>
        switch resultMode {
        case .preview:
            allowed = [.apply, .partialApply, .ignore, .explain]
        case .applied:
            allowed = [.undo, .remember, .explain]
        }
        return actions.filter { allowed.contains($0) }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func dimensionLabel(_ sort: WorkspaceSidebarSummaryPrioritySort) -> String {
        if sort.isRecent {
            return String(localized: "sortAssistant.dimension.recent", defaultValue: "Recent")
        }
        if sort.isNative {
            return String(localized: "sortAssistant.dimension.native", defaultValue: "Native")
        }
        switch sort.dimensionId ?? "urgency" {
        case "importance":
            return String(localized: "sortAssistant.dimension.importance", defaultValue: "Importance")
        case "progress":
            return String(localized: "sortAssistant.dimension.progress", defaultValue: "Progress")
        default:
            return String(localized: "sortAssistant.dimension.urgency", defaultValue: "Urgency")
        }
    }

    private static func semanticActionDisplayName(_ kind: CmuxActionKind) -> String {
        switch kind {
        case .switchWorkspace:
            return String(localized: "sortAssistant.actionReview.action.switchWorkspace", defaultValue: "switch workspace")
        case .applySort:
            return String(localized: "sortAssistant.actionReview.action.applySort", defaultValue: "apply sort")
        case .undoSort:
            return String(localized: "sortAssistant.actionReview.action.undoSort", defaultValue: "undo sort")
        case .setWorkspaceColor:
            return String(localized: "sortAssistant.actionReview.action.setWorkspaceColor", defaultValue: "set workspace color")
        case .clearWorkspaceColor:
            return String(localized: "sortAssistant.actionReview.action.clearWorkspaceColor", defaultValue: "clear workspace color")
        case .pinWorkspace:
            return String(localized: "sortAssistant.actionReview.action.pinWorkspace", defaultValue: "pin workspace")
        case .lockList:
            return String(localized: "sortAssistant.actionReview.action.lockList", defaultValue: "lock workspace")
        case .acceptSuggestion:
            return String(localized: "sortAssistant.actionReview.action.acceptSuggestion", defaultValue: "accept suggestion")
        case .dismissSuggestion:
            return String(localized: "sortAssistant.actionReview.action.dismissSuggestion", defaultValue: "dismiss suggestion")
        case .writeMemory:
            return String(localized: "sortAssistant.actionReview.action.writeMemory", defaultValue: "write memory")
        case .forgetMemory:
            return String(localized: "sortAssistant.actionReview.action.forgetMemory", defaultValue: "forget memory")
        }
    }

    private static func displayMessage(for error: Error) -> String {
        if let socketError = error as? CmuxSocketError {
            return socketError.message
        }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private func memoryText(from text: String) -> String {
        var output = text
        for marker in ["remember", "Remember", "from now on", "以后都", "以后", "记住", "下次"] {
            output = output.replacingOccurrences(of: marker, with: "")
        }
        return normalized(output).isEmpty ? text : normalized(output)
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func socketActionIntent(
        kind: CmuxActionKind,
        route: SortAssistantIntent?,
        arguments: [String: String],
        workspaceIds: [UUID],
        suggestionId: UUID? = nil,
        reason: String?,
        now: Date = Date()
    ) -> ActionIntent {
        reviewedActionIntent(
            requesterId: "cmux_sprite_socket",
            kind: kind,
            route: route,
            arguments: arguments,
            workspaceIds: workspaceIds,
            suggestionId: suggestionId,
            reason: reason,
            now: now
        )
    }

    private func assistantActionIntent(
        kind: CmuxActionKind,
        route: SortAssistantIntent?,
        arguments: [String: String],
        workspaceIds: [UUID],
        suggestionId: UUID? = nil,
        reason: String?,
        now: Date = Date()
    ) -> ActionIntent {
        reviewedActionIntent(
            requesterId: "cmux_sprite_assistant",
            kind: kind,
            route: route,
            arguments: arguments,
            workspaceIds: workspaceIds,
            suggestionId: suggestionId,
            reason: reason,
            now: now
        )
    }

    private func reviewedActionIntent(
        requesterId: String,
        kind: CmuxActionKind,
        route: SortAssistantIntent?,
        arguments: [String: String],
        workspaceIds: [UUID],
        suggestionId: UUID? = nil,
        reason: String?,
        now: Date
    ) -> ActionIntent {
        ActionIntent(
            id: UUID(),
            requestedBy: ActionRequester(id: requesterId, route: route?.rawValue),
            kind: kind,
            arguments: arguments,
            reason: reason,
            evidence: actionEvidence(workspaceIds: workspaceIds, suggestionId: suggestionId, now: now),
            createdAt: now
        )
    }

    private func actionEvidence(
        workspaceIds: [UUID],
        suggestionId: UUID? = nil,
        now: Date
    ) -> ActionEvidence {
        let uniqueWorkspaceIds = orderedUniqueSortAssistant(workspaceIds)
        let snapshots = uniqueWorkspaceIds.compactMap { workspaceId -> WorkspaceSnapshot? in
            guard let workspace = lastTabManager?.tabs.first(where: { $0.id == workspaceId }) else {
                return nil
            }
            return makeWorkspaceSnapshot(workspace: workspace, now: now)
        }
        return ActionEvidence(
            snapshotVersions: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.workspaceId, $0.version) }),
            snapshotUpdatedAt: Dictionary(uniqueKeysWithValues: snapshots.map {
                ($0.workspaceId, actionEvidenceUpdatedAt(for: $0, now: now))
            }),
            suggestionId: suggestionId ?? latestResult?.id,
            rankingSnapshotId: nil
        )
    }

    private func actionEvidenceUpdatedAt(for snapshot: WorkspaceSnapshot, now: Date) -> Date {
        let staleProviders = snapshot.freshness.evaluated(at: now).providers.filter(\.stale)
        guard !staleProviders.isEmpty else {
            return snapshot.updatedAt
        }
        return .distantPast
    }

    private func actionReviewSignals(for intent: ActionIntent, now: Date) -> [SemanticReviewSignal] {
        [
            ActionArgumentReviewer.review(intent),
            ActionFreshnessReviewer.review(intent, maxSnapshotAge: 120, now: now),
        ].compactMap { $0 }
    }

    private func submitSocketAction(
        _ intent: ActionIntent,
        now: Date = Date(),
        execute: () throws -> ActionExecutionResult
    ) throws -> SemanticReviewResult {
        try submitReviewedAction(intent, now: now, execute: execute)
    }

    private func submitReviewedAction(
        _ intent: ActionIntent,
        now: Date = Date(),
        execute: () throws -> ActionExecutionResult
    ) throws -> SemanticReviewResult {
        try SemanticActionGateway.submitSynchronously(
            intent,
            reviewSignals: actionReviewSignals(for: intent, now: now),
            recordedAt: now,
            recordReview: { [weak self] intent, result, recordedAt in
                self?.semanticActionAuditTrail.append(SemanticActionAuditEntry(
                    intentId: intent.id,
                    kind: intent.kind,
                    trustFingerprint: intent.trustDescriptor.fingerprint,
                    decision: result.decision,
                    executed: false,
                    reasons: result.reasons,
                    recordedAt: recordedAt
                ))
            },
            recordExecuted: { [weak self] intent, _, recordedAt in
                self?.semanticActionAuditTrail.append(SemanticActionAuditEntry(
                    intentId: intent.id,
                    kind: intent.kind,
                    trustFingerprint: intent.trustDescriptor.fingerprint,
                    decision: .allow,
                    executed: true,
                    reasons: [],
                    recordedAt: recordedAt
                ))
            },
            execute: execute
        )
    }

    static func socketActionReviewPayload(
        intent: ActionIntent,
        result: SemanticReviewResult,
        base: [String: Any] = [:]
    ) -> [String: Any] {
        var payload = base
        payload["intentId"] = intent.id.uuidString
        payload["actionKind"] = intent.kind.rawValue
        payload["reviewDecision"] = result.decision.rawValue
        payload["reviewReasons"] = result.reasons
        payload["reviewExecuted"] = result.executed
        if result.decision == .requireConfirmation {
            payload["requiresConfirmation"] = true
        }
        if result.decision == .deny {
            payload["reviewDenied"] = true
        }
        return payload
    }

    @discardableResult
    private func executeConfirmedSemanticAction(
        intent: ActionIntent,
        recordedAt: Date = Date(),
        execute: () throws -> ActionExecutionResult
    ) throws -> ActionExecutionResult {
        let result = try execute()
        semanticActionAuditTrail.append(SemanticActionAuditEntry(
            intentId: intent.id,
            kind: intent.kind,
            trustFingerprint: intent.trustDescriptor.fingerprint,
            decision: .allow,
            executed: true,
            reasons: [],
            recordedAt: recordedAt
        ))
        return result
    }

    private func executeConfirmedSortPatch(
        _ patch: SortPatch,
        tabManager: TabManager,
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals] = [:],
        actor: String,
        intent: ActionIntent
    ) throws -> SortEngineApplyResult {
        var appliedResult: SortEngineApplyResult?
        try executeConfirmedSemanticAction(intent: intent) {
            let result = try sortOperator.apply(
                patch: patch,
                tabManager: tabManager,
                itemSignals: itemSignals,
                actor: actor
            )
            appliedResult = result
            return ActionExecutionResult(payload: [
                "applied": "true",
                "patchId": patch.id.uuidString,
            ])
        }
        guard let appliedResult else {
            throw SortEngineError.emptyPatch
        }
        return appliedResult
    }

    private func executeConfirmedUndo(
        tabManager: TabManager,
        intent: ActionIntent
    ) throws -> SortEngineApplyResult? {
        var undoResult: SortEngineApplyResult?
        try executeConfirmedSemanticAction(intent: intent) {
            let result = try sortOperator.undo(tabManager: tabManager)
            undoResult = result
            return ActionExecutionResult(payload: [
                "undone": result == nil ? "false" : "true",
            ])
        }
        return undoResult
    }

    private func applySortPatchThroughGateway(
        _ patch: SortPatch,
        tabManager: TabManager,
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals] = [:],
        actor: String,
        requesterId: String = "cmux_sprite_assistant"
    ) throws -> SortEngineApplyResult {
        let affectedWorkspaceIds = orderedUniqueSortAssistant(patch.operations.flatMap(\.itemIds))
        let intent = reviewedActionIntent(
            requesterId: requesterId,
            kind: .applySort,
            route: .applySort,
            arguments: [
                "patchId": patch.id.uuidString,
                "itemIds": affectedWorkspaceIds.map(\.uuidString).joined(separator: ","),
            ],
            workspaceIds: affectedWorkspaceIds,
            reason: patch.rationale,
            now: Date()
        )
        var appliedResult: SortEngineApplyResult?
        let review = try submitReviewedAction(intent) {
            let result = try sortOperator.apply(
                patch: patch,
                tabManager: tabManager,
                itemSignals: itemSignals,
                actor: actor
            )
            appliedResult = result
            return ActionExecutionResult(payload: [
                "applied": "true",
                "patchId": patch.id.uuidString,
            ])
        }
        guard review.decision == .allow, let appliedResult else {
            throw SemanticActionReviewError(intent: intent, result: review)
        }
        return appliedResult
    }

    private func undoSortThroughGateway(
        tabManager: TabManager,
        requesterId: String = "cmux_sprite_assistant"
    ) throws -> SortEngineApplyResult? {
        let intent = reviewedActionIntent(
            requesterId: requesterId,
            kind: .undoSort,
            route: .undoSort,
            arguments: ["listId": SortEngine.workspaceListId],
            workspaceIds: tabManager.tabs.map(\.id),
            reason: nil,
            now: Date()
        )
        var undoResult: SortEngineApplyResult?
        let review = try submitReviewedAction(intent) {
            let result = try sortOperator.undo(tabManager: tabManager)
            undoResult = result
            return ActionExecutionResult(payload: [
                "undone": result == nil ? "false" : "true",
            ])
        }
        guard review.decision == .allow else {
            throw SemanticActionReviewError(intent: intent, result: review)
        }
        return undoResult
    }

    private func rememberStores(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) {
        lastTabManager = tabManager
        lastWorkspaceTabStore = workspaceTabStore
        rebuildSpriteColorSubscription(for: tabManager)
        let directory = Self.workspaceDirectoryForMCP(tabManager: tabManager)
        if directory != currentSpriteMemoryDirectory {
            reloadSpriteMemories(directory: directory)
        }
    }

    private func appendContextFreshnessWarningIfNeeded(now: Date = Date()) {
        let context = makeAssistantWorkingContext(now: now)
        let warningText: String?
        if context.snapshots.isEmpty {
            warningText = String(
                localized: "sortAssistant.contextFreshness.missing",
                defaultValue: "Context snapshots are not available yet. I'll answer from visible workspace state only."
            )
        } else {
            let staleProviderIds = orderedUniqueSortAssistant(context.snapshots.flatMap { snapshot in
                snapshot.freshness.evaluated(at: now).providers
                    .filter(\.stale)
                    .map(\.providerId)
            })
            guard !staleProviderIds.isEmpty else { return }
            warningText = String(
                format: String(
                    localized: "sortAssistant.contextFreshness.stale",
                    defaultValue: "Some context providers are stale: %@. I'll use the latest snapshot without refreshing context."
                ),
                staleProviderIds.joined(separator: ", ")
            )
        }

        guard let warningText, messages.last?.text != warningText else { return }
        append(.init(
            kind: .warning,
            text: warningText,
            accessibilityIdentifier: SortAssistantAccessibility.contextFreshnessWarning
        ))
    }

    private func rebuildSpriteColorSubscription(for tabManager: TabManager) {
        spriteColorCancellables.removeAll()
        tabManager.$selectedTabId
            .sink { [weak self] _ in self?.refreshSpriteColor() }
            .store(in: &spriteColorCancellables)
        // TabManager forwards each workspace's `$customColor` through its own
        // `objectWillChange`, so subscribing to objectWillChange covers color
        // edits on the active workspace too.
        tabManager.objectWillChange
            .sink { [weak self] _ in self?.refreshSpriteColor() }
            .store(in: &spriteColorCancellables)
        refreshSpriteColor()
    }

    func setPanelEdgeRecovery(_ active: Bool) {
        guard isPanelEdgeRecovery != active else { return }
#if DEBUG
        cmuxDebugLog("sprite.coordinator isPanelEdgeRecovery: \(isPanelEdgeRecovery) → \(active)")
#endif
        isPanelEdgeRecovery = active
    }

    func setConversationBubbleSide(_ side: SortAssistantFloatingConversationBubbleSide, reason: String) {
        guard conversationBubbleSide != side else { return }
#if DEBUG
        cmuxDebugLog("sprite.coordinator conversationBubbleSide: \(conversationBubbleSide.rawValue) → \(side.rawValue) reason=\(reason)")
#endif
        conversationBubbleSide = side
        invalidateFloatingLayout(reason: "conversationBubbleSide.\(reason).\(side.rawValue)")
    }

#if DEBUG
    func recordSpriteGeometryDebugSnapshot(
        source: String,
        frame: NSRect,
        avatarSprite: NSRect,
        avatarHotspot: NSRect,
        recoveryHotspot: NSRect,
        visibleFrames: [NSRect],
        isAvatarSpriteVisibleOnScreen: Bool,
        edgeRecovery: Bool
    ) {
        latestSpriteGeometryDebugSnapshot = SpriteGeometryDebugSnapshot(
            source: source,
            frame: frame,
            avatarSprite: avatarSprite,
            avatarHotspot: avatarHotspot,
            recoveryHotspot: recoveryHotspot,
            visibleFrames: visibleFrames,
            isAvatarSpriteVisibleOnScreen: isAvatarSpriteVisibleOnScreen,
            edgeRecovery: edgeRecovery
        )
    }

    private func debugLogSpriteGeometrySnapshot(_ event: String) {
        guard let snapshot = latestSpriteGeometryDebugSnapshot else {
            cmuxDebugLog(
                "sprite.conversation \(event) frame=nil edgeRecovery=\(isPanelEdgeRecovery)"
            )
            return
        }
        cmuxDebugLog(
            "sprite.conversation \(event) source=\(snapshot.source) frame=\(snapshot.frame) avatarSprite=\(snapshot.avatarSprite) avatarHotspot=\(snapshot.avatarHotspot) recoveryHotspot=\(snapshot.recoveryHotspot) visibleFrames=\(SortAssistantVisibleScreenRange.debugDescription(for: snapshot.visibleFrames)) spriteVisibleOnScreen=\(snapshot.isAvatarSpriteVisibleOnScreen) edgeRecovery=\(snapshot.edgeRecovery) coordinatorEdgeRecovery=\(isPanelEdgeRecovery)"
        )
    }
#endif

    private func refreshSpriteColor() {
        let hex = lastTabManager?.selectedTab?.customColor
        guard hex != lastResolvedColorHex else { return }
        lastResolvedColorHex = hex
        guard let hex else {
            spriteColor = nil
            return
        }
        spriteColor = WorkspaceTabColorSettings.displayNSColor(
            hex: hex,
            colorScheme: .dark,
            forceBright: true
        )
    }

    func socketMemoryQuery() -> [String: Any] {
        reloadFreeSortMemories(reason: "socket.memoryQuery")
        return [
            "domain": "free_sort",
            "memories": SortAssistantPayload.array(memories),
        ]
    }

    func socketWriteMemoryCandidate(text: String, sourceSummary: String?) -> [String: Any] {
        let trimmed = normalized(text)
        guard !trimmed.isEmpty else { return ["created": false] }
        let intent = socketActionIntent(
            kind: .writeMemory,
            route: .rememberPreference,
            arguments: ["domain": "free_sort", "text": trimmed],
            workspaceIds: [],
            reason: sourceSummary
        )
        var payload: [String: Any]?
        do {
            let review = try submitSocketAction(intent) {
                memoryCandidate = SortAssistantMemoryCandidate(text: trimmed, sourceSummary: sourceSummary, target: .freeSort)
                payload = [
                    "domain": "free_sort",
                    "created": true,
                    "text": trimmed,
                ]
                return ActionExecutionResult(payload: ["created": "true"])
            }
            guard review.decision == .allow else {
                return Self.socketActionReviewPayload(intent: intent, result: review, base: [
                    "domain": "free_sort",
                    "created": false,
                    "text": trimmed,
                ])
            }
            return payload ?? ["domain": "free_sort", "created": false]
        } catch {
            return [
                "domain": "free_sort",
                "created": false,
                "text": trimmed,
                "error": Self.displayMessage(for: error),
            ]
        }
    }

    func socketForgetMemory(id: String?, text: String?) -> [String: Any] {
        reloadFreeSortMemories(reason: "socket.memoryForget")
        let intent = socketActionIntent(
            kind: .forgetMemory,
            route: .forgetPreference,
            arguments: [
                "domain": "free_sort",
                "id": id ?? "",
                "text": text ?? "",
            ],
            workspaceIds: [],
            reason: nil
        )
        var payload: [String: Any]?
        do {
            let review = try submitSocketAction(intent) {
                let before = memories.count
                if let id, let uuid = UUID(uuidString: id), let memory = memories.first(where: { $0.id == uuid }) {
                    deleteMemoryWithoutReview(memory)
                } else if let text {
                    let targets = memories.filter { $0.text.localizedCaseInsensitiveContains(text) }
                    for memory in targets {
                        deleteMemoryWithoutReview(memory)
                    }
                }
                payload = [
                    "domain": "free_sort",
                    "deleted": before - memories.count,
                ]
                return ActionExecutionResult(payload: ["deleted": "\(before - memories.count)"])
            }
            guard review.decision == .allow else {
                return Self.socketActionReviewPayload(intent: intent, result: review, base: [
                    "domain": "free_sort",
                    "deleted": 0,
                ])
            }
            return payload ?? ["domain": "free_sort", "deleted": 0]
        } catch {
            return [
                "domain": "free_sort",
                "deleted": 0,
                "error": Self.displayMessage(for: error),
            ]
        }
    }

    func socketSpriteMemoryQuery(directory: String?) -> [String: Any] {
        reloadSpriteMemories(directory: directory ?? currentSpriteMemoryDirectory)
        var payload: [String: Any] = [
            "domain": "sprite",
            "memories": SortAssistantPayload.array(spriteMemories),
            "memoryFile": currentSpriteMemoryFileURL.map { $0.path as Any } ?? NSNull(),
        ]
        if let fileURL = currentSpriteMemoryFileURL {
            payload["memoryFileExists"] = FileManager.default.fileExists(atPath: fileURL.path)
        }
        return payload
    }

    func socketWriteSpriteMemory(text: String, sourceSummary: String?, directory: String?) -> [String: Any] {
        if let directory {
            reloadSpriteMemories(directory: directory)
        } else if currentSpriteMemoryDirectory == nil, let lastTabManager {
            reloadSpriteMemories(directory: Self.workspaceDirectoryForMCP(tabManager: lastTabManager))
        }
        let trimmed = normalized(text)
        guard !trimmed.isEmpty else {
            return [
                "domain": "sprite",
                "created": false,
                "memoryFile": currentSpriteMemoryFileURL.map { $0.path as Any } ?? NSNull(),
            ]
        }

        let targetDirectory = directory
            ?? currentSpriteMemoryDirectory
            ?? lastTabManager.flatMap(Self.workspaceDirectoryForMCP)
        let intent = socketActionIntent(
            kind: .writeMemory,
            route: .rememberSpriteMemory,
            arguments: [
                "domain": "sprite",
                "text": trimmed,
                "directory": targetDirectory ?? "",
            ],
            workspaceIds: [],
            reason: sourceSummary
        )
        var payload: [String: Any]?
        do {
            let review = try submitSocketAction(intent) {
                let memory = SortAssistantMemory(id: UUID(), text: trimmed, createdAt: Date())
                guard let fileURL = try SpriteWorkspaceMemoryDocument.append(memory, directory: targetDirectory) else {
                    payload = [
                        "domain": "sprite",
                        "created": false,
                        "error": String(localized: "sortAssistant.spriteMemory.noWorkspaceDirectory", defaultValue: "No workspace directory is available for memory.md."),
                        "memoryFile": NSNull(),
                    ]
                    return ActionExecutionResult(payload: ["created": "false"])
                }
                currentSpriteMemoryDirectory = targetDirectory
                currentSpriteMemoryFileURL = fileURL
                spriteMemories.insert(memory, at: 0)
                spriteMemorySources[memory.id] = .workspace(fileURL)
                var writePayload: [String: Any] = [
                    "domain": "sprite",
                    "created": true,
                    "memory": SortAssistantPayload.dictionary(memory),
                    "text": trimmed,
                    "memoryFile": fileURL.path,
                ]
                if let sourceSummary = sourceSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !sourceSummary.isEmpty {
                    writePayload["sourceSummary"] = sourceSummary
                }
                payload = writePayload
                return ActionExecutionResult(payload: ["created": "true", "memoryFile": fileURL.path])
            }
            guard review.decision == .allow else {
                return Self.socketActionReviewPayload(intent: intent, result: review, base: [
                    "domain": "sprite",
                    "created": false,
                    "memoryFile": currentSpriteMemoryFileURL.map { $0.path as Any } ?? NSNull(),
                ])
            }
            return payload ?? [
                "domain": "sprite",
                "created": false,
                "memoryFile": currentSpriteMemoryFileURL.map { $0.path as Any } ?? NSNull(),
            ]
        } catch {
            return [
                "domain": "sprite",
                "created": false,
                "error": Self.displayMessage(for: error),
                "memoryFile": currentSpriteMemoryFileURL.map { $0.path as Any } ?? NSNull(),
            ]
        }
    }

    func socketWriteSpriteMemoryCandidate(text: String, sourceSummary: String?, directory: String?) -> [String: Any] {
        socketWriteSpriteMemory(text: text, sourceSummary: sourceSummary, directory: directory)
    }

    func socketForgetSpriteMemory(id: String?, text: String?, directory: String?) -> [String: Any] {
        if let directory {
            reloadSpriteMemories(directory: directory)
        }
        let intent = socketActionIntent(
            kind: .forgetMemory,
            route: .forgetSpriteMemory,
            arguments: [
                "domain": "sprite",
                "id": id ?? "",
                "text": text ?? "",
                "directory": directory ?? "",
            ],
            workspaceIds: [],
            reason: nil
        )
        var payload: [String: Any]?
        do {
            let review = try submitSocketAction(intent) {
                let before = spriteMemories.count
                if let id, let uuid = UUID(uuidString: id), let memory = spriteMemories.first(where: { $0.id == uuid }) {
                    deleteSpriteMemoryWithoutReview(memory)
                } else if let text {
                    let targets = spriteMemories.filter { $0.text.localizedCaseInsensitiveContains(text) }
                    for memory in targets {
                        deleteSpriteMemoryWithoutReview(memory)
                    }
                }
                payload = [
                    "domain": "sprite",
                    "deleted": before - spriteMemories.count,
                    "memoryFile": currentSpriteMemoryFileURL.map { $0.path as Any } ?? NSNull(),
                ]
                return ActionExecutionResult(payload: ["deleted": "\(before - spriteMemories.count)"])
            }
            guard review.decision == .allow else {
                return Self.socketActionReviewPayload(intent: intent, result: review, base: [
                    "domain": "sprite",
                    "deleted": 0,
                    "memoryFile": currentSpriteMemoryFileURL.map { $0.path as Any } ?? NSNull(),
                ])
            }
            return payload ?? [
                "domain": "sprite",
                "deleted": 0,
                "memoryFile": currentSpriteMemoryFileURL.map { $0.path as Any } ?? NSNull(),
            ]
        } catch {
            return [
                "domain": "sprite",
                "deleted": 0,
                "error": Self.displayMessage(for: error),
                "memoryFile": currentSpriteMemoryFileURL.map { $0.path as Any } ?? NSNull(),
            ]
        }
    }

    func socketListState() -> [String: Any]? {
        guard let tabManager = lastTabManager else { return nil }
        return [
            "listId": SortEngine.workspaceListId,
            "revision": SortEngine.revision(for: tabManager.tabs),
            "items": tabManager.tabs.map { tab in
                [
                    "id": tab.id.uuidString,
                    "title": tab.title,
                    "pinned": tab.isPinned,
                    "locked": sortEngine.lockedItemIds().contains(tab.id),
                    "customColor": tab.customColor ?? NSNull(),
                    "custom_color": tab.customColor ?? NSNull(),
                ] as [String: Any]
            },
        ]
    }

    func socketGitHubContext(workspaceId: String?, includeAllWorkspaces: Bool) -> [String: Any]? {
        guard let tabManager = lastTabManager else { return nil }
        let selectedWorkspaceId = tabManager.selectedTabId
        let requestedWorkspaceId = workspaceId.flatMap(UUID.init(uuidString:))
        let workspaces: [Workspace]

        if includeAllWorkspaces {
            workspaces = tabManager.tabs
        } else if let requestedWorkspaceId,
                  let workspace = tabManager.tabs.first(where: { $0.id == requestedWorkspaceId }) {
            workspaces = [workspace]
        } else if let selectedWorkspace = tabManager.selectedWorkspace {
            workspaces = [selectedWorkspace]
        } else {
            workspaces = []
        }

        return [
            "selectedWorkspaceId": selectedWorkspaceId.map { $0.uuidString as Any } ?? NSNull(),
            "workspaceCount": tabManager.tabs.count,
            "workspaces": workspaces.map { workspace in
                Self.githubContextPayload(
                    for: workspace,
                    selectedWorkspaceId: selectedWorkspaceId
                )
            },
        ]
    }

    func socketAssistantWorkingContext() -> [String: Any]? {
        guard lastTabManager != nil else { return nil }
        return SortAssistantPayload.dictionary(makeAssistantWorkingContext())
    }

    func socketWorkspaceSnapshot(workspaceId: String?) -> [String: Any]? {
        guard let snapshot = workspaceSnapshot(workspaceId: workspaceId, now: Date()) else {
            return nil
        }
        return SortAssistantPayload.dictionary(snapshot)
    }

    func socketContextFreshness(workspaceId: String?) -> [String: Any]? {
        guard let freshness = workspaceSnapshot(workspaceId: workspaceId, now: Date())?.freshness
            ?? makeAssistantWorkingContext().snapshots.first?.freshness else {
            return nil
        }
        return SortAssistantPayload.dictionary(freshness)
    }

    func socketActiveSuggestions() -> [String: Any]? {
        guard lastTabManager != nil else { return nil }
        return [
            "suggestions": SortAssistantPayload.array(activeSuggestions(now: Date(), publish: false)),
        ]
    }

    func socketContextAgentCollect(
        workspaceId: String?,
        providerIds: [String],
        reason: String?
    ) -> [String: Any]? {
        guard let tabManager = lastTabManager else { return nil }
        let targetWorkspaceIds = resolvedSocketWorkspaceIds(workspaceId: workspaceId, tabManager: tabManager)
        guard !targetWorkspaceIds.isEmpty else { return nil }
        let requestedProviders = normalizedContextProviderIds(providerIds)
        for workspaceId in targetWorkspaceIds {
            var payload: [String: Any] = [
                "reason": Self.nonEmpty(reason) ?? "mcp.context_agent_collect",
            ]
            if !requestedProviders.isEmpty {
                payload["providerIds"] = requestedProviders.joined(separator: " ")
            }
            CmuxEventBus.shared.publish(
                name: "assistant.context_collect.requested",
                category: "assistant",
                source: "sprite.mcp",
                workspaceId: workspaceId.uuidString,
                payload: payload
            )
        }
        return [
            "scheduled": true,
            "workspaceIds": targetWorkspaceIds.map(\.uuidString),
            "providerIds": requestedProviders,
            "reason": Self.nonEmpty(reason) ?? "mcp.context_agent_collect",
            "suggestions": SortAssistantPayload.array(activeSuggestions(now: Date(), publish: false)),
        ]
    }

    func socketProactiveSuggestionsRefresh() -> [String: Any]? {
        guard lastTabManager != nil else { return nil }
        let suggestions = activeSuggestions(now: Date(), updateVisible: true, publish: true)
        maybeNotifyProactiveSuggestions(from: suggestions)
        return [
            "refreshed": true,
            "attentionCount": proactiveAttentionCount,
            "suggestions": SortAssistantPayload.array(suggestions),
            "badges": Dictionary(uniqueKeysWithValues: proactiveBadgeByWorkspaceId().map { workspaceId, badge in
                (
                    workspaceId.uuidString,
                    [
                        "type": badge.type,
                        "glyph": badge.glyph,
                        "helpText": badge.helpText,
                    ] as [String: Any]
                )
            }),
        ]
    }

    func socketReportProactiveSignal(
        workspaceId: String?,
        status: String?,
        title: String?,
        rankReason: String?,
        nextAction: String?,
        summary: String?,
        priorityScore: Double?,
        userAttentionNeeded: Double?,
        source: String?
    ) -> [String: Any]? {
        guard let tabManager = lastTabManager,
              let targetWorkspaceId = resolvedSocketWorkspaceIds(workspaceId: workspaceId, tabManager: tabManager).first else {
            return nil
        }
        var payload: [String: Any] = [
            "status": Self.normalizedSuggestionStatus(status ?? "") ?? "needs_attention",
            "source": Self.nonEmpty(source) ?? "sprite.mcp",
        ]
        if let title = Self.nonEmpty(title) {
            payload["title"] = title
        }
        if let rankReason = Self.nonEmpty(rankReason) {
            payload["rankReason"] = rankReason
        }
        if let nextAction = Self.nonEmpty(nextAction) {
            payload["nextAction"] = nextAction
        }
        if let summary = Self.nonEmpty(summary) {
            payload["summary"] = summary
        }
        if let priorityScore {
            payload["priorityScore"] = "\(priorityScore)"
        }
        if let userAttentionNeeded {
            payload["userAttentionNeeded"] = "\(userAttentionNeeded)"
        }
        CmuxEventBus.shared.publish(
            name: ContextAgentEvent.proactiveSignalReportedName,
            category: "agent",
            source: Self.nonEmpty(source) ?? "sprite.mcp",
            workspaceId: targetWorkspaceId.uuidString,
            payload: payload
        )
        return [
            "accepted": true,
            "workspaceId": targetWorkspaceId.uuidString,
            "workspace_id": targetWorkspaceId.uuidString,
            "payload": payload,
        ]
    }

    private func activeSuggestionForAction(suggestionId: UUID) -> ProactiveSuggestion? {
        guard !dismissedSuggestionIds.contains(suggestionId) else { return nil }
        if let suggestion = cachedActiveSuggestions.first(where: { $0.id == suggestionId }) {
            return suggestion
        }
        return activeSuggestions(now: Date(), publish: false).first { $0.id == suggestionId }
    }

    func socketAcceptSuggestion(suggestionId: UUID) -> [String: Any]? {
        guard let tabManager = lastTabManager,
              let suggestion = activeSuggestionForAction(suggestionId: suggestionId),
              let workspace = tabManager.tabs.first(where: { $0.id == suggestion.workspaceId }) else {
            return nil
        }
        let intent = socketActionIntent(
            kind: .acceptSuggestion,
            route: nil,
            arguments: [
                "suggestionId": suggestion.id.uuidString,
                "workspaceId": workspace.id.uuidString,
                "type": suggestion.type,
            ],
            workspaceIds: [workspace.id],
            suggestionId: suggestion.id,
            reason: suggestion.reason
        )
        var payload: [String: Any]?
        do {
            let review = try submitSocketAction(intent) {
                tabManager.selectWorkspace(workspace)
                dismissedSuggestionIds.insert(suggestion.id)
                let remainingSuggestions = activeSuggestions(now: Date(), updateVisible: true, publish: true)
                payload = [
                    "accepted": true,
                    "suggestionId": suggestion.id.uuidString,
                    "suggestion": SortAssistantPayload.dictionary(suggestion),
                    "workspaceId": workspace.id.uuidString,
                    "workspace_id": workspace.id.uuidString,
                    "suggestions": SortAssistantPayload.array(remainingSuggestions),
                ]
                return ActionExecutionResult(payload: [
                    "accepted": "true",
                    "suggestionId": suggestion.id.uuidString,
                ])
            }
            guard review.decision == .allow else {
                return Self.socketActionReviewPayload(intent: intent, result: review, base: [
                    "accepted": false,
                    "suggestionId": suggestion.id.uuidString,
                    "suggestion": SortAssistantPayload.dictionary(suggestion),
                    "workspaceId": workspace.id.uuidString,
                    "workspace_id": workspace.id.uuidString,
                    "suggestions": SortAssistantPayload.array(activeSuggestions(now: Date(), publish: false)),
                ])
            }
            return payload
        } catch {
            return [
                "accepted": false,
                "suggestionId": suggestion.id.uuidString,
                "error": Self.displayMessage(for: error),
            ]
        }
    }

    func socketDismissSuggestion(suggestionId: UUID) -> [String: Any]? {
        guard let suggestion = activeSuggestionForAction(suggestionId: suggestionId) else {
            return [
                "dismissed": false,
                "suggestionId": suggestionId.uuidString,
                "suggestions": SortAssistantPayload.array(activeSuggestions(now: Date(), publish: false)),
            ]
        }
        let intent = socketActionIntent(
            kind: .dismissSuggestion,
            route: nil,
            arguments: [
                "suggestionId": suggestion.id.uuidString,
                "workspaceId": suggestion.workspaceId.uuidString,
                "type": suggestion.type,
            ],
            workspaceIds: [suggestion.workspaceId],
            suggestionId: suggestion.id,
            reason: suggestion.reason
        )
        var payload: [String: Any]?
        do {
            let review = try submitSocketAction(intent) {
                dismissedSuggestionIds.insert(suggestion.id)
                let remainingSuggestions = activeSuggestions(now: Date(), updateVisible: true, publish: true)
                payload = [
                    "dismissed": true,
                    "suggestionId": suggestion.id.uuidString,
                    "suggestions": SortAssistantPayload.array(remainingSuggestions),
                ]
                return ActionExecutionResult(payload: [
                    "dismissed": "true",
                    "suggestionId": suggestion.id.uuidString,
                ])
            }
            guard review.decision == .allow else {
                return Self.socketActionReviewPayload(intent: intent, result: review, base: [
                    "dismissed": false,
                    "suggestionId": suggestion.id.uuidString,
                    "suggestions": SortAssistantPayload.array(activeSuggestions(now: Date(), publish: false)),
                ])
            }
            return payload
        } catch {
            return [
                "dismissed": false,
                "suggestionId": suggestion.id.uuidString,
                "error": Self.displayMessage(for: error),
            ]
        }
    }

    func acceptVisibleSuggestion(_ suggestion: ProactiveSuggestion) {
        guard let tabManager = lastTabManager,
              let suggestion = activeSuggestions(now: Date(), publish: false).first(where: { $0.id == suggestion.id }),
              let workspace = tabManager.tabs.first(where: { $0.id == suggestion.workspaceId }) else {
            return
        }
        let intent = assistantActionIntent(
            kind: .acceptSuggestion,
            route: nil,
            arguments: [
                "suggestionId": suggestion.id.uuidString,
                "workspaceId": workspace.id.uuidString,
                "type": suggestion.type,
            ],
            workspaceIds: [workspace.id],
            suggestionId: suggestion.id,
            reason: suggestion.reason
        )
        do {
            let review = try submitReviewedAction(intent) {
                acceptSuggestionWithoutReview(suggestion, workspace: workspace, tabManager: tabManager)
                return ActionExecutionResult(payload: [
                    "accepted": "true",
                    "suggestionId": suggestion.id.uuidString,
                ])
            }
            guard review.decision == .allow else {
                let reviewError = SemanticActionReviewError(intent: intent, result: review)
                _ = queueSemanticActionConfirmation(
                    for: reviewError,
                    actionName: Self.semanticActionDisplayName(.acceptSuggestion),
                    confirm: { [weak self, weak tabManager] in
                        guard let self, let tabManager else { return }
                        self.confirmAcceptSuggestion(suggestion, workspace: workspace, tabManager: tabManager, intent: intent)
                    }
                )
                return
            }
        } catch {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.suggestions.acceptFailed", defaultValue: "Could not accept suggestion: ") + Self.displayMessage(for: error)
            ))
        }
    }

    func dismissVisibleSuggestion(_ suggestion: ProactiveSuggestion) {
        guard let suggestion = activeSuggestions(now: Date(), publish: false).first(where: { $0.id == suggestion.id }) else {
            return
        }
        let intent = assistantActionIntent(
            kind: .dismissSuggestion,
            route: nil,
            arguments: [
                "suggestionId": suggestion.id.uuidString,
                "workspaceId": suggestion.workspaceId.uuidString,
                "type": suggestion.type,
            ],
            workspaceIds: [suggestion.workspaceId],
            suggestionId: suggestion.id,
            reason: suggestion.reason
        )
        do {
            let review = try submitReviewedAction(intent) {
                dismissSuggestionWithoutReview(suggestion)
                return ActionExecutionResult(payload: [
                    "dismissed": "true",
                    "suggestionId": suggestion.id.uuidString,
                ])
            }
            guard review.decision == .allow else {
                let reviewError = SemanticActionReviewError(intent: intent, result: review)
                _ = queueSemanticActionConfirmation(
                    for: reviewError,
                    actionName: Self.semanticActionDisplayName(.dismissSuggestion),
                    confirm: { [weak self] in
                        self?.confirmDismissSuggestion(suggestion, intent: intent)
                    }
                )
                return
            }
        } catch {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.suggestions.dismissFailed", defaultValue: "Could not dismiss suggestion: ") + Self.displayMessage(for: error)
            ))
        }
    }

    private func acceptSuggestionWithoutReview(
        _ suggestion: ProactiveSuggestion,
        workspace: Workspace,
        tabManager: TabManager
    ) {
        tabManager.selectWorkspace(workspace)
        dismissedSuggestionIds.insert(suggestion.id)
        _ = activeSuggestions(now: Date(), updateVisible: true, publish: true)
    }

    private func dismissSuggestionWithoutReview(_ suggestion: ProactiveSuggestion) {
        dismissedSuggestionIds.insert(suggestion.id)
        _ = activeSuggestions(now: Date(), updateVisible: true, publish: true)
    }

    private func confirmAcceptSuggestion(
        _ suggestion: ProactiveSuggestion,
        workspace: Workspace,
        tabManager: TabManager,
        intent: ActionIntent
    ) {
        do {
            try executeConfirmedSemanticAction(intent: intent) {
                acceptSuggestionWithoutReview(suggestion, workspace: workspace, tabManager: tabManager)
                return ActionExecutionResult(payload: [
                    "accepted": "true",
                    "suggestionId": suggestion.id.uuidString,
                ])
            }
        } catch {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.suggestions.acceptFailed", defaultValue: "Could not accept suggestion: ") + Self.displayMessage(for: error)
            ))
        }
    }

    private func confirmDismissSuggestion(_ suggestion: ProactiveSuggestion, intent: ActionIntent) {
        do {
            try executeConfirmedSemanticAction(intent: intent) {
                dismissSuggestionWithoutReview(suggestion)
                return ActionExecutionResult(payload: [
                    "dismissed": "true",
                    "suggestionId": suggestion.id.uuidString,
                ])
            }
        } catch {
            append(.init(
                kind: .error,
                text: String(localized: "sortAssistant.suggestions.dismissFailed", defaultValue: "Could not dismiss suggestion: ") + Self.displayMessage(for: error)
            ))
        }
    }

    func socketLatestRanking() -> [String: Any]? {
        guard let ranking = latestRanking(now: Date(), publish: false) else { return nil }
        return SortAssistantPayload.dictionary(ranking)
    }

    func socketSortContext(goal: String) -> [String: Any]? {
        guard let tabManager = lastTabManager,
              let workspaceTabStore = lastWorkspaceTabStore else {
            return nil
        }
        reloadFreeSortMemories(reason: "socket.sortContext")
        let context = contextProvider.context(
            userIntent: goal,
            tabManager: tabManager,
            workspaceTabStore: workspaceTabStore,
            memories: memories,
            lastAssistantProposal: pendingPreviewPatch?.operations.flatMap(\.itemIds)
        )
        return SortAssistantPayload.dictionary(context)
    }

    private func buildAssistantWorkingContext(now: Date = Date()) -> AssistantWorkingContext {
        let snapshots = currentWorkspaceSnapshots(now: now)
        return AssistantWorkingContext(
            activeWorkspaceId: lastTabManager?.selectedTabId,
            snapshots: snapshots,
            freshness: aggregateFreshness(from: snapshots.map(\.freshness)),
            activeSuggestions: activeSuggestions(now: now, snapshots: snapshots, updateVisible: false, publish: false),
            latestRanking: latestRanking(now: now, snapshots: snapshots, publish: false)
        )
    }

    private func makeAssistantWorkingContext(now: Date = Date()) -> AssistantWorkingContext {
        buildAssistantWorkingContext(now: now)
    }

    @discardableResult
    private func refreshAssistantWorkingContextStore(now: Date = Date()) async -> AssistantWorkingContext {
        let context = buildAssistantWorkingContext(now: now)
        await workspaceSnapshotStore.replace(context)
        return context
    }

    private func currentWorkspaceSnapshots(now: Date) -> [WorkspaceSnapshot] {
        lastTabManager?.tabs.compactMap { workspace in
            makeWorkspaceSnapshot(workspace: workspace, now: now)
        } ?? []
    }

    private func workspaceSnapshotForContextAgent(
        workspaceId: UUID,
        now: Date,
        freshnessProviderIds: Set<String>? = nil
    ) -> WorkspaceSnapshot? {
        guard let tabManager = lastTabManager,
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            return nil
        }
        return makeWorkspaceSnapshot(
            workspace: workspace,
            now: now,
            freshnessProviderIds: freshnessProviderIds
        )
    }

    private func workspaceSnapshotForContextAgentPayload(
        providerId: String,
        job: ContextRefreshJob
    ) -> WorkspaceSnapshot? {
        guard let signal = contextAgentSignal(providerId: providerId, job: job) else {
            return nil
        }
        let existingWorkspace = lastTabManager?.tabs.first { $0.id == job.workspaceId }
        let existingSnapshot = existingWorkspace.flatMap {
            makeWorkspaceSnapshot(
                workspace: $0,
                now: job.enqueuedAt,
                freshnessProviderIds: [providerId]
            )
        }
        let nativeOrder = intPayload(job.payload, "nativeOrder", "native_order")
            ?? existingSnapshot?.context.nativeOrder
            ?? 0
        let pullRequestCount = intPayload(job.payload, "pullRequestCount", "pull_request_count")
            ?? existingSnapshot?.context.pullRequestCount
            ?? 0
        let stalePullRequestCount = intPayload(job.payload, "stalePullRequestCount", "stale_pull_request_count")
            ?? existingSnapshot?.context.stalePullRequestCount
            ?? 0
        let title = Self.nonEmpty(payloadString(job.payload, "title", "workspaceTitle", "workspace_title"))
            ?? existingSnapshot?.context.title
            ?? signal.title
        let attention = doublePayload(job.payload, "userAttentionNeeded", "user_attention_needed", "attention")
            ?? signal.defaultAttention
        let priorityScore = doublePayload(job.payload, "priorityScore", "priority_score")
            ?? (attention * 100)
        let summary = Self.nonEmpty(payloadString(job.payload, "summary"))
            ?? signal.summary
        return WorkspaceSnapshot(
            workspaceId: job.workspaceId,
            version: max(existingSnapshot?.version ?? 0, nativeOrder + 1),
            updatedAt: job.enqueuedAt,
            context: NormalizedWorkspaceContext(
                title: title,
                selected: existingSnapshot?.context.selected
                    ?? (lastTabManager?.selectedTabId == job.workspaceId),
                directory: existingSnapshot?.context.directory
                    ?? Self.nonEmpty(payloadString(job.payload, "directory", "cwd")),
                listRevision: existingSnapshot?.context.listRevision ?? nativeOrder + 1,
                nativeOrder: nativeOrder,
                pinned: existingSnapshot?.context.pinned ?? false,
                locked: existingSnapshot?.context.locked ?? false,
                customColor: existingSnapshot?.context.customColor,
                panelCount: existingSnapshot?.context.panelCount ?? 0,
                pullRequestCount: pullRequestCount,
                stalePullRequestCount: stalePullRequestCount
            ),
            derived: DerivedWorkspaceState(
                status: signal.status,
                priorityScore: priorityScore,
                rankReason: Self.nonEmpty(payloadString(job.payload, "rankReason", "rank_reason"))
                    ?? signal.rankReason,
                nextAction: Self.nonEmpty(payloadString(job.payload, "nextAction", "next_action"))
                    ?? signal.nextAction,
                userAttentionNeeded: min(max(attention, 0), 1)
            ),
            digest: summary.map {
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
                        confidence: signal.confidence
                    ),
                ],
                overallConfidence: signal.confidence
            )
        )
    }

    private struct ContextAgentSignal {
        var status: String
        var title: String
        var rankReason: String?
        var nextAction: String?
        var summary: String?
        var defaultAttention: Double
        var confidence: Double
    }

    private func contextAgentSignal(providerId: String, job: ContextRefreshJob) -> ContextAgentSignal? {
        if let rawStatus = payloadString(job.payload, "status", "state"),
           let status = Self.normalizedSuggestionStatus(rawStatus) {
            return ContextAgentSignal(
                status: status,
                title: Self.nonEmpty(payloadString(job.payload, "title")) ?? defaultSignalTitle(for: job),
                rankReason: Self.nonEmpty(payloadString(job.payload, "rankReason", "rank_reason")),
                nextAction: Self.nonEmpty(payloadString(job.payload, "nextAction", "next_action")),
                summary: Self.nonEmpty(payloadString(job.payload, "summary")),
                defaultAttention: defaultAttention(forStatus: status),
                confidence: 1
            )
        }

        switch providerId {
        case "agent_session":
            return agentSessionSignal(for: job)
        case "notification_context":
            return ContextAgentSignal(
                status: "notification",
                title: defaultSignalTitle(for: job),
                rankReason: String(localized: "sortAssistant.contextAgent.notification.reason", defaultValue: "A new workspace notification arrived."),
                nextAction: String(localized: "sortAssistant.contextAgent.notification.nextAction", defaultValue: "Review the workspace notification"),
                summary: nil,
                defaultAttention: 0.9,
                confidence: 0.9
            )
        case "workspace_activity":
            return ContextAgentSignal(
                status: "workspace_activity",
                title: defaultSignalTitle(for: job),
                rankReason: String(localized: "sortAssistant.contextAgent.workspaceActivity.reason", defaultValue: "Recent workspace activity may need follow-up."),
                nextAction: String(localized: "sortAssistant.contextAgent.workspaceActivity.nextAction", defaultValue: "Review recent workspace activity"),
                summary: nil,
                defaultAttention: 0.9,
                confidence: 0.85
            )
        default:
            return nil
        }
    }

    private func agentSessionSignal(for job: ContextRefreshJob) -> ContextAgentSignal? {
        let hook = payloadString(job.payload, "hook_event_name", "hookEventName")
            ?? job.reason.replacingOccurrences(of: "agent.hook.", with: "")
        let source = payloadString(job.payload, "_source", "source")
            ?? String(localized: "sortAssistant.contextAgent.agent.defaultSource", defaultValue: "agent")
        switch hook {
        case "PermissionRequest":
            return ContextAgentSignal(
                status: "permission_requested",
                title: defaultSignalTitle(for: job),
                rankReason: String(format: String(localized: "sortAssistant.contextAgent.permission.reason", defaultValue: "%@ needs permission."), source),
                nextAction: String(localized: "sortAssistant.contextAgent.permission.nextAction", defaultValue: "Review the permission request"),
                summary: nil,
                defaultAttention: 0.98,
                confidence: 1
            )
        case "AskUserQuestion":
            return ContextAgentSignal(
                status: "question_requested",
                title: defaultSignalTitle(for: job),
                rankReason: String(format: String(localized: "sortAssistant.contextAgent.question.reason", defaultValue: "%@ asked a question."), source),
                nextAction: String(localized: "sortAssistant.contextAgent.question.nextAction", defaultValue: "Answer the agent question"),
                summary: nil,
                defaultAttention: 0.98,
                confidence: 1
            )
        case "ExitPlanMode":
            return ContextAgentSignal(
                status: "exit_plan_ready",
                title: defaultSignalTitle(for: job),
                rankReason: String(format: String(localized: "sortAssistant.contextAgent.exitPlan.reason", defaultValue: "%@ is waiting for plan approval."), source),
                nextAction: String(localized: "sortAssistant.contextAgent.exitPlan.nextAction", defaultValue: "Review the plan"),
                summary: nil,
                defaultAttention: 0.98,
                confidence: 1
            )
        case "Notification":
            return ContextAgentSignal(
                status: "notification",
                title: defaultSignalTitle(for: job),
                rankReason: String(format: String(localized: "sortAssistant.contextAgent.agentNotification.reason", defaultValue: "%@ sent a notification."), source),
                nextAction: String(localized: "sortAssistant.contextAgent.agentNotification.nextAction", defaultValue: "Review the agent notification"),
                summary: nil,
                defaultAttention: 0.92,
                confidence: 0.9
            )
        case "Stop", "SubagentStop":
            return ContextAgentSignal(
                status: "agent_completed",
                title: defaultSignalTitle(for: job),
                rankReason: String(format: String(localized: "sortAssistant.contextAgent.agentCompleted.reason", defaultValue: "%@ finished a turn."), source),
                nextAction: String(localized: "sortAssistant.contextAgent.agentCompleted.nextAction", defaultValue: "Review completed agent work"),
                summary: nil,
                defaultAttention: 0.9,
                confidence: 0.85
            )
        default:
            return nil
        }
    }

    private func workspaceSnapshot(workspaceId: String?, now: Date) -> WorkspaceSnapshot? {
        guard let tabManager = lastTabManager else { return nil }
        let requestedWorkspaceId = workspaceId.flatMap(UUID.init(uuidString:))
        let workspace: Workspace?
        if let requestedWorkspaceId {
            workspace = tabManager.tabs.first { $0.id == requestedWorkspaceId }
        } else if let selectedWorkspace = tabManager.selectedWorkspace {
            workspace = selectedWorkspace
        } else {
            workspace = tabManager.tabs.first
        }
        guard let snapshot = workspace.flatMap({ makeWorkspaceSnapshot(workspace: $0, now: now) }) else {
            return nil
        }
        return snapshot
    }

    private func makeWorkspaceSnapshot(
        workspace: Workspace,
        now: Date,
        freshnessProviderIds: Set<String>? = nil
    ) -> WorkspaceSnapshot? {
        guard let tabManager = lastTabManager else { return nil }
        let summaryItem = summaryPriorityItem(for: workspace, workspaceTabStore: lastWorkspaceTabStore)
        let score = priorityScore(for: summaryItem, workspaceTabStore: lastWorkspaceTabStore)
        let pullRequests = workspace.sidebarPullRequestsInDisplayOrder()
        let stalePullRequestCount = pullRequests.filter(\.isStale).count
        let panelIds = Set(workspace.panelGitBranches.keys)
            .union(workspace.panelPullRequests.keys)
            .union(workspace.panelDirectories.keys)
        let context = NormalizedWorkspaceContext(
            title: workspace.title,
            selected: workspace.id == tabManager.selectedTabId,
            directory: workspace.surfaceTabBarDirectory,
            listRevision: SortEngine.revision(for: tabManager.tabs),
            nativeOrder: tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) ?? 0,
            pinned: workspace.isPinned,
            locked: sortEngine.lockedItemIds().contains(workspace.id),
            customColor: workspace.customColor,
            panelCount: panelIds.count,
            pullRequestCount: pullRequests.count,
            stalePullRequestCount: stalePullRequestCount
        )
        let derived = DerivedWorkspaceState(
            status: summaryItem?.status ?? fallbackWorkspaceStatus(for: workspace) ?? "unknown",
            priorityScore: score,
            rankReason: Self.nonEmpty(summaryItem?.scores.rankReason),
            nextAction: Self.nonEmpty(summaryItem?.nextAction?.label),
            userAttentionNeeded: min(max((score ?? 0) / 100, 0), 1)
        )
        let digest = summaryItem.map { item in
            WorkspaceDigest(
                summary: item.summary.short,
                generatedAt: Self.iso8601Formatter.date(from: item.generatedAt)
            )
        }
        var freshness = contextFreshness(
            summaryItem: summaryItem,
            stalePullRequestCount: stalePullRequestCount,
            now: now
        )
        if let freshnessProviderIds {
            freshness = freshness.filteringProviders(freshnessProviderIds)
        }
        return WorkspaceSnapshot(
            workspaceId: workspace.id,
            version: context.listRevision,
            updatedAt: now,
            context: context,
            derived: derived,
            digest: digest,
            freshness: freshness
        )
    }

    private func summaryPriorityItem(
        for workspace: Workspace,
        workspaceTabStore: WorkspaceTabStore?
    ) -> WorkspaceSidebarSummaryPriorityItem? {
        workspaceTabStore?.summaryPriority?.items.first { item in
            UUID(uuidString: item.workspaceId) == workspace.id
        }
    }

    private func priorityScore(
        for item: WorkspaceSidebarSummaryPriorityItem?,
        workspaceTabStore: WorkspaceTabStore?
    ) -> Double? {
        guard let item else { return nil }
        if let dimensionId = workspaceTabStore?.selectedSort.dimensionId,
           let score = item.scores.dimensions[dimensionId]?.rawScore {
            return score
        }
        return item.scores.dimensions["urgency"]?.rawScore
            ?? item.scores.dimensions.values.map(\.rawScore).max()
    }

    private func contextFreshness(
        summaryItem: WorkspaceSidebarSummaryPriorityItem?,
        stalePullRequestCount: Int,
        now: Date
    ) -> ContextFreshness {
        let providers = [
            ProviderFreshness(
                providerId: "list_state",
                lastCollectedAt: now,
                ttlSeconds: 30,
                stale: false,
                error: nil,
                confidence: 1
            ),
            ProviderFreshness(
                providerId: "git_context",
                lastCollectedAt: now,
                ttlSeconds: 60,
                stale: false,
                error: nil,
                confidence: 1
            ),
            ProviderFreshness(
                providerId: "github_context",
                lastCollectedAt: now,
                ttlSeconds: 120,
                stale: stalePullRequestCount > 0,
                error: stalePullRequestCount > 0 ? "cached pull request data is stale" : nil,
                confidence: stalePullRequestCount > 0 ? 0.5 : 1
            ),
            ProviderFreshness(
                providerId: "summary_priority",
                lastCollectedAt: summaryItem == nil ? nil : now,
                ttlSeconds: 120,
                stale: summaryItem == nil,
                error: summaryItem == nil ? "summary priority snapshot is missing" : nil,
                confidence: summaryItem == nil ? 0 : 1
            ),
        ]
        let confidence = providers.map(\.confidence).reduce(0, +) / Double(providers.count)
        return ContextFreshness(providers: providers, overallConfidence: confidence)
    }

    private func fallbackWorkspaceStatus(for workspace: Workspace) -> String? {
        workspace.sidebarStatusEntriesInDisplayOrder()
            .map(\.value)
            .compactMap(Self.normalizedSuggestionStatus)
            .first
    }

    private static func normalizedSuggestionStatus(_ rawValue: String) -> String? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "waiting_user",
             "ci_failed",
             "ready_to_merge",
             "permission_requested",
             "question_requested",
             "exit_plan_ready",
             "agent_completed",
             "notification",
             "workspace_activity",
             "needs_attention":
            return normalized
        default:
            return nil
        }
    }

    private func payloadString(_ payload: [String: String], _ keys: String...) -> String? {
        payloadString(payload, keys)
    }

    private func intPayload(_ payload: [String: String], _ keys: String...) -> Int? {
        payloadString(payload, keys).flatMap(Int.init)
    }

    private func doublePayload(_ payload: [String: String], _ keys: String...) -> Double? {
        payloadString(payload, keys).flatMap(Double.init)
    }

    private func payloadString(_ payload: [String: String], _ keys: [String]) -> String? {
        for key in keys {
            guard let value = Self.nonEmpty(payload[key]) else { continue }
            return value
        }
        return nil
    }

    private func defaultAttention(forStatus status: String) -> Double {
        switch status {
        case "permission_requested", "question_requested", "exit_plan_ready":
            return 0.98
        case "waiting_user", "ci_failed":
            return 0.95
        case "agent_completed", "notification", "workspace_activity", "needs_attention":
            return 0.9
        case "ready_to_merge":
            return 0.85
        default:
            return 0
        }
    }

    private func defaultSignalTitle(for job: ContextRefreshJob) -> String {
        if let title = payloadString(job.payload, "title", "workspaceTitle", "workspace_title") {
            return title
        }
        if let workspace = lastTabManager?.tabs.first(where: { $0.id == job.workspaceId }) {
            return workspace.title
        }
        return String(localized: "sortAssistant.contextAgent.signal.defaultTitle", defaultValue: "Workspace")
    }

    private func resolvedSocketWorkspaceIds(workspaceId: String?, tabManager: TabManager) -> [UUID] {
        if let raw = Self.nonEmpty(workspaceId) {
            if raw == "*" || raw.lowercased() == "all" {
                return tabManager.tabs.map(\.id)
            }
            if let id = UUID(uuidString: raw),
               tabManager.tabs.contains(where: { $0.id == id }) {
                return [id]
            }
            return []
        }
        if let selectedTabId = tabManager.selectedTabId {
            return [selectedTabId]
        }
        return tabManager.tabs.first.map { [$0.id] } ?? []
    }

    private func normalizedContextProviderIds(_ providerIds: [String]) -> [String] {
        let allowed: Set<String> = [
            "list_state",
            "git_context",
            "github_context",
            "summary_priority",
            "agent_session",
            "notification_context",
            "workspace_activity",
        ]
        var seen = Set<String>()
        var output: [String] = []
        for providerId in providerIds {
            let normalized = providerId
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            guard allowed.contains(normalized), seen.insert(normalized).inserted else {
                continue
            }
            output.append(normalized)
        }
        return output
    }

    private func aggregateFreshness(from values: [ContextFreshness]) -> ContextFreshness {
        guard !values.isEmpty else {
            return ContextFreshness(providers: [], overallConfidence: 0)
        }
        return ContextFreshness(
            providers: values.flatMap(\.providers),
            overallConfidence: values.map(\.overallConfidence).reduce(0, +) / Double(values.count)
        )
    }

    private func latestRanking(
        now: Date,
        snapshots: [WorkspaceSnapshot]? = nil,
        publish: Bool = true
    ) -> RankingSnapshot? {
        let source = snapshots ?? currentWorkspaceSnapshots(now: now)
        guard !source.isEmpty else { return nil }
        let ranking = rankingEngine.rank(source)
        if publish {
            Task { await rankingSnapshotStore.setLatestRanking(ranking) }
        }
        return ranking
    }

    private func activeSuggestions(
        now: Date,
        snapshots: [WorkspaceSnapshot]? = nil,
        updateVisible: Bool = true,
        publish: Bool = true
    ) -> [ProactiveSuggestion] {
        let source = snapshots ?? currentWorkspaceSnapshots(now: now)
        var suggestions = suggestionEngine.generate(from: source, now: now)
        if let latestResult,
           let selectedWorkspaceId = lastTabManager?.selectedTabId {
            suggestions.append(ProactiveSuggestion(
                id: latestResult.id,
                workspaceId: selectedWorkspaceId,
                type: latestResult.mode == .preview ? "sort_preview_ready" : "sort_applied",
                title: latestResult.title,
                reason: latestResult.rationale,
                confidence: 1,
                createdAt: now
            ))
        }
        suggestions.removeAll { dismissedSuggestionIds.contains($0.id) }
        cachedActiveSuggestions = suggestions
        if updateVisible, visibleSuggestions != suggestions {
            visibleSuggestions = suggestions
        }
        if updateVisible {
            maybeSurfaceAutoBubble(from: suggestions)
        }
        if publish {
            Task { await suggestionSnapshotStore.setActiveSuggestions(suggestions) }
        }
        return suggestions
    }

    private func refreshVisibleSuggestions(now: Date = Date()) {
        _ = activeSuggestions(now: now, updateVisible: true, publish: true)
    }

    private static func githubContextPayload(
        for workspace: Workspace,
        selectedWorkspaceId: UUID?
    ) -> [String: Any] {
        let panelIds = Set(workspace.panelGitBranches.keys)
            .union(workspace.panelPullRequests.keys)
            .union(workspace.panelDirectories.keys)
        let panels = panelIds
            .sorted { $0.uuidString < $1.uuidString }
            .map { panelId -> [String: Any] in
                var payload: [String: Any] = [
                    "panelId": panelId.uuidString,
                ]
                if let directory = workspace.panelDirectories[panelId] {
                    payload["directory"] = directory
                }
                if let branch = workspace.panelGitBranches[panelId] {
                    payload["branch"] = branch.branch
                    payload["dirty"] = branch.isDirty
                }
                if let pullRequest = workspace.panelPullRequests[panelId] {
                    payload["pullRequest"] = pullRequestPayload(pullRequest)
                }
                return payload
            }

        return [
            "workspaceId": workspace.id.uuidString,
            "title": workspace.title,
            "selected": workspace.id == selectedWorkspaceId,
            "surfaceDirectory": workspace.surfaceTabBarDirectory.map { $0 as Any } ?? NSNull(),
            "panels": panels,
            "pullRequests": workspace.sidebarPullRequestsInDisplayOrder().map(pullRequestPayload),
        ]
    }

    private static func pullRequestPayload(_ pullRequest: SidebarPullRequestState) -> [String: Any] {
        [
            "number": pullRequest.number,
            "label": pullRequest.label,
            "url": pullRequest.url.absoluteString,
            "status": pullRequest.status.rawValue,
            "branch": pullRequest.branch.map { $0 as Any } ?? NSNull(),
            "stale": pullRequest.isStale,
        ]
    }

    func socketWorkspaceColorGet(workspaceId: String?, includePalette: Bool) -> [String: Any]? {
        guard let tabManager = lastTabManager,
              let workspace = workspaceForColorCommand(workspaceId: workspaceId, tabManager: tabManager) else {
            return nil
        }
        return workspaceColorPayload(workspace: workspace, includePalette: includePalette)
    }

    func socketWorkspaceColorSet(workspaceId: String?, color: String) -> [String: Any]? {
        guard let tabManager = lastTabManager,
              let workspace = workspaceForColorCommand(workspaceId: workspaceId, tabManager: tabManager) else {
            return nil
        }
        guard let hex = Self.workspaceColorHex(color) else {
            return [
                "workspaceId": workspace.id.uuidString,
                "workspace_id": workspace.id.uuidString,
                "color": workspace.customColor ?? NSNull(),
                "custom_color": workspace.customColor ?? NSNull(),
                "error": "invalid_color",
                "palette": Self.workspaceColorPalettePayload(),
            ]
        }
        let intent = socketActionIntent(
            kind: .setWorkspaceColor,
            route: .workspaceColor,
            arguments: ["workspaceId": workspace.id.uuidString, "color": hex],
            workspaceIds: [workspace.id],
            reason: nil
        )
        var payload: [String: Any]?
        do {
            let review = try submitSocketAction(intent) {
                tabManager.setTabColor(tabId: workspace.id, color: hex)
                payload = workspaceColorPayload(workspace: workspace, includePalette: false)
                return ActionExecutionResult(payload: ["color": hex])
            }
            guard review.decision == .allow else {
                return Self.socketActionReviewPayload(
                    intent: intent,
                    result: review,
                    base: workspaceColorPayload(workspace: workspace, includePalette: false)
                )
            }
            return payload
        } catch {
            var errorPayload = workspaceColorPayload(workspace: workspace, includePalette: false)
            errorPayload["error"] = Self.displayMessage(for: error)
            return errorPayload
        }
    }

    func socketWorkspaceColorClear(workspaceId: String?) -> [String: Any]? {
        guard let tabManager = lastTabManager,
              let workspace = workspaceForColorCommand(workspaceId: workspaceId, tabManager: tabManager) else {
            return nil
        }
        let intent = socketActionIntent(
            kind: .clearWorkspaceColor,
            route: .workspaceColor,
            arguments: ["workspaceId": workspace.id.uuidString],
            workspaceIds: [workspace.id],
            reason: nil
        )
        var payload: [String: Any]?
        do {
            let review = try submitSocketAction(intent) {
                tabManager.setTabColor(tabId: workspace.id, color: nil)
                payload = workspaceColorPayload(workspace: workspace, includePalette: false)
                return ActionExecutionResult(payload: ["cleared": "true"])
            }
            guard review.decision == .allow else {
                return Self.socketActionReviewPayload(
                    intent: intent,
                    result: review,
                    base: workspaceColorPayload(workspace: workspace, includePalette: false)
                )
            }
            return payload
        } catch {
            var errorPayload = workspaceColorPayload(workspace: workspace, includePalette: false)
            errorPayload["error"] = Self.displayMessage(for: error)
            return errorPayload
        }
    }

    private func workspaceForColorCommand(workspaceId: String?, tabManager: TabManager) -> Workspace? {
        if let workspaceId,
           let uuid = UUID(uuidString: workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return tabManager.tabs.first { $0.id == uuid }
        }
        if let selectedWorkspace = tabManager.selectedWorkspace {
            return selectedWorkspace
        }
        return tabManager.tabs.first
    }

    private func workspaceColorPayload(workspace: Workspace, includePalette: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "workspaceId": workspace.id.uuidString,
            "workspace_id": workspace.id.uuidString,
            "color": workspace.customColor ?? NSNull(),
            "customColor": workspace.customColor ?? NSNull(),
            "custom_color": workspace.customColor ?? NSNull(),
        ]
        if includePalette {
            payload["palette"] = Self.workspaceColorPalettePayload()
        }
        return payload
    }

    private static func workspaceColorHex(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let entry = WorkspaceTabColorSettings.palette().first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return WorkspaceTabColorSettings.normalizedHex(entry.hex)
        }
        return WorkspaceTabColorSettings.normalizedHex(trimmed)
    }

    private static func workspaceColorPalettePayload() -> [[String: Any]] {
        WorkspaceTabColorSettings.palette().map { entry in
            [
                "name": entry.name,
                "hex": entry.hex,
            ]
        }
    }

    func socketSortPreview(goal: String, itemIds: [UUID]?) -> [String: Any]? {
        guard let tabManager = lastTabManager,
              let workspaceTabStore = lastWorkspaceTabStore else {
            return nil
        }
        let orderedIds: [UUID]
        if let itemIds, !itemIds.isEmpty {
            orderedIds = itemIds
        } else if let summary = workspaceTabStore.summaryPriority {
            orderedIds = WorkspaceTabStore.orderedWorkspaceIds(
                from: summary,
                tabs: tabManager.tabs,
                sort: workspaceTabStore.selectedSort,
                recentWorkspaceIds: workspaceTabStore.recentWorkspaceIds
            )
        } else {
            orderedIds = tabManager.tabs.map(\.id)
        }
        let patch = sortOperator.makeBatchPatch(
            orderedIds: orderedIds,
            tabs: tabManager.tabs,
            rationale: normalized(goal).isEmpty ? nil : goal,
            requiresConfirmation: true
        )
        guard let preview = try? sortOperator.preview(
            patch: patch,
            tabs: tabManager.tabs,
            itemSignals: contextProvider.itemSignals(tabManager: tabManager, workspaceTabStore: workspaceTabStore)
        ) else {
            return nil
        }
        pendingPreviewPatch = patch
        pendingPreviewSort = workspaceTabStore.selectedSort
        return [
            "patch": SortAssistantPayload.dictionary(patch),
            "preview": Self.previewPayload(preview),
        ]
    }

    func socketSortApply(patchId: UUID?, itemIds: [UUID]?) -> [String: Any]? {
        guard let tabManager = lastTabManager,
              let workspaceTabStore = lastWorkspaceTabStore else {
            return nil
        }
        let patch: SortPatch
        if let pendingPreviewPatch,
           patchId == nil || pendingPreviewPatch.id == patchId {
            patch = SortPatch(
                id: pendingPreviewPatch.id,
                listId: pendingPreviewPatch.listId,
                baseRevision: SortEngine.revision(for: tabManager.tabs),
                operations: pendingPreviewPatch.operations,
                rationale: pendingPreviewPatch.rationale,
                confidence: pendingPreviewPatch.confidence,
                requiresConfirmation: false
            )
        } else if let itemIds, !itemIds.isEmpty {
            patch = sortOperator.makeBatchPatch(
                orderedIds: itemIds,
                tabs: tabManager.tabs,
                rationale: nil,
                requiresConfirmation: false
            )
        } else {
            return nil
        }
        let affectedWorkspaceIds = patch.operations.flatMap(\.itemIds)
        let intent = socketActionIntent(
            kind: .applySort,
            route: .applySort,
            arguments: [
                "patchId": patch.id.uuidString,
                "itemIds": affectedWorkspaceIds.map(\.uuidString).joined(separator: ","),
            ],
            workspaceIds: affectedWorkspaceIds,
            reason: patch.rationale
        )
        var payload: [String: Any]?
        do {
            let review = try submitSocketAction(intent) {
                let result = try sortOperator.apply(
                    patch: patch,
                    tabManager: tabManager,
                    itemSignals: contextProvider.itemSignals(tabManager: tabManager, workspaceTabStore: workspaceTabStore),
                    actor: "sprite_tool_sort_apply"
                )
                pendingPreviewPatch = nil
                pendingPreviewSort = nil
                payload = [
                    "applied": true,
                    "patchId": patch.id.uuidString,
                    "preview": Self.previewPayload(result.preview),
                    "undoPatch": SortAssistantPayload.dictionary(result.undoPatch),
                ]
                return ActionExecutionResult(payload: ["applied": "true", "patchId": patch.id.uuidString])
            }
            guard review.decision == .allow else {
                return Self.socketActionReviewPayload(intent: intent, result: review, base: [
                    "applied": false,
                    "patchId": patch.id.uuidString,
                ])
            }
            return payload
        } catch {
            return [
                "applied": false,
                "patchId": patch.id.uuidString,
                "error": Self.displayMessage(for: error),
            ]
        }
    }

    func socketSortUndo() -> [String: Any]? {
        guard let tabManager = lastTabManager else {
            return nil
        }
        let intent = socketActionIntent(
            kind: .undoSort,
            route: .undoSort,
            arguments: ["listId": SortEngine.workspaceListId],
            workspaceIds: tabManager.tabs.map(\.id),
            reason: nil
        )
        var payload: [String: Any]?
        do {
            let review = try submitSocketAction(intent) {
                guard let result = try sortOperator.undo(tabManager: tabManager) else {
                    throw SortEngineError.emptyPatch
                }
                payload = [
                    "undone": true,
                    "preview": Self.previewPayload(result.preview),
                    "undoPatch": SortAssistantPayload.dictionary(result.undoPatch),
                ]
                return ActionExecutionResult(payload: ["undone": "true"])
            }
            guard review.decision == .allow else {
                return Self.socketActionReviewPayload(intent: intent, result: review, base: [
                    "undone": false,
                ])
            }
            return payload
        } catch {
            return [
                "undone": false,
                "error": Self.displayMessage(for: error),
            ]
        }
    }

    func socketSortExplain() -> [String: Any] {
        [
            "rationale": latestResult?.rationale ?? "",
            "changes": latestResult?.changes ?? [],
        ]
    }

    func socketSetLocked(itemId: UUID, locked: Bool) -> [String: Any] {
        let intent = socketActionIntent(
            kind: .lockList,
            route: nil,
            arguments: ["itemId": itemId.uuidString, "locked": locked ? "true" : "false"],
            workspaceIds: [itemId],
            reason: nil
        )
        var payload: [String: Any] = [
            "itemId": itemId.uuidString,
            "locked": sortEngine.lockedItemIds().contains(itemId),
        ]
        do {
            let review = try submitSocketAction(intent) {
                sortEngine.setLocked(locked, itemId: itemId)
                payload = [
                    "itemId": itemId.uuidString,
                    "locked": locked,
                ]
                return ActionExecutionResult(payload: ["locked": locked ? "true" : "false"])
            }
            if review.decision != .allow {
                payload = Self.socketActionReviewPayload(intent: intent, result: review, base: payload)
            }
        } catch {
            payload["error"] = Self.displayMessage(for: error)
        }
        return payload
    }

    func socketSetPinned(itemId: UUID, pinned: Bool) -> [String: Any]? {
        guard let tabManager = lastTabManager,
              let workspace = tabManager.tabs.first(where: { $0.id == itemId }) else {
            return nil
        }
        let intent = socketActionIntent(
            kind: .pinWorkspace,
            route: nil,
            arguments: ["itemId": itemId.uuidString, "pinned": pinned ? "true" : "false"],
            workspaceIds: [itemId],
            reason: nil
        )
        var payload: [String: Any]?
        do {
            let review = try submitSocketAction(intent) {
                tabManager.setPinned(workspace, pinned: pinned)
                payload = [
                    "itemId": itemId.uuidString,
                    "pinned": pinned,
                    "revision": SortEngine.revision(for: tabManager.tabs),
                ]
                return ActionExecutionResult(payload: ["pinned": pinned ? "true" : "false"])
            }
            guard review.decision == .allow else {
                return Self.socketActionReviewPayload(intent: intent, result: review, base: [
                    "itemId": itemId.uuidString,
                    "pinned": workspace.isPinned,
                    "revision": SortEngine.revision(for: tabManager.tabs),
                ])
            }
            return payload
        } catch {
            return [
                "itemId": itemId.uuidString,
                "pinned": workspace.isPinned,
                "revision": SortEngine.revision(for: tabManager.tabs),
                "error": Self.displayMessage(for: error),
            ]
        }
    }

    private static func previewPayload(_ preview: SortEnginePreview) -> [String: Any] {
        [
            "orderBefore": preview.orderBefore.map(\.uuidString),
            "orderAfter": preview.orderAfter.map(\.uuidString),
            "changes": preview.changes,
            "affectedItemIds": preview.affectedItemIds.map(\.uuidString),
            "rationale": preview.rationale ?? NSNull(),
            "requiresConfirmation": preview.requiresConfirmation,
        ]
    }
}
