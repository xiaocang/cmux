import AppKit
import CmuxFoundation
import CmuxTerminalCore
import SwiftUI
import Foundation
import Bonsplit
import CmuxBrowser
import CmuxFileWatch
import CmuxGit
import CmuxNotifications
import CmuxPanes
import CmuxProcess
import CmuxSettings
import CmuxSidebar
import CmuxSidebarGit
import CmuxWorkspaceNavigation
import CmuxWorkspaces
import CoreVideo
import Combine
import CMUXEnhancementAPI
import CoreServices
import Darwin
import OSLog
import CmuxTerminal
import CmuxWorkspaceCore

// MARK: - Tab Type Alias for Backwards Compatibility
// The old Tab class is replaced by Workspace
typealias Tab = Workspace

// KVO-observable accessor for workspace tags toggle
extension UserDefaults {
    @objc dynamic var workspaceTagsEnabled: Bool {
        bool(forKey: CMUXTmuxPrefixService.workspaceTagsEnabledSettingsKey)
    }
}

private let tabManagerLogger = Logger(subsystem: "com.cmuxterm.app", category: "TabManager")

enum NewWorkspacePlacement: String, CaseIterable, Identifiable {
    case top
    case afterCurrent
    case end

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top:
            return String(localized: "workspace.placement.top", defaultValue: "Top")
        case .afterCurrent:
            return String(localized: "workspace.placement.afterCurrent", defaultValue: "After current")
        case .end:
            return String(localized: "workspace.placement.end", defaultValue: "End")
        }
    }

    var description: String {
        switch self {
        case .top:
            return String(
                localized: "workspace.placement.top.description",
                defaultValue: "Insert new workspaces at the top of the list."
            )
        case .afterCurrent:
            return String(
                localized: "workspace.placement.afterCurrent.description",
                defaultValue: "Insert new workspaces directly after the active workspace."
            )
        case .end:
            return String(
                localized: "workspace.placement.end.description",
                defaultValue: "Append new workspaces to the bottom of the list."
            )
        }
    }
}

enum WorkspaceAutoReorderSettings {
    static let key = "workspaceAutoReorderOnNotification"
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

// Gate for the proactive sprite suggestion surfaces (mascot badge, sidebar
// suggestion badge, and opt-in auto bubble / notifications). Default ON so
// closed-loop agent hook signals surface without hidden setup; disabling keeps
// the sprite reactive only.
enum ProactiveSpriteSuggestionsSettings {
    static let key = "sprite.proactiveSuggestions"
    static let defaultValue = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

// Tier 2 opt-in: when on (and the parent flag is on), a NEW high-confidence
// suggestion auto-presents a compact, non-activating speech bubble on the sprite.
// Default OFF — the badge (Tier 1) is the non-intrusive default surface.
enum ProactiveAutoBubbleSettings {
    static let key = "sprite.proactiveAutoBubble"
    static let defaultValue = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

// Phase 4 opt-in: when on (and the parent flag is on), post a desktop notification
// for new high-confidence suggestions while cmux is backgrounded. Default OFF.
enum ProactiveSuggestionNotificationsSettings {
    static let key = "sprite.proactiveSuggestions.notifications"
    static let defaultValue = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}

enum WorkspaceSummaryPrioritySettings {
    static let enabledKey = "workspaceTab.summaryPriority.enabled"
    static let defaultEnabled = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }
}

enum WorkspaceOrderChangeNotificationKey {
    static let movedWorkspaceIds = "movedWorkspaceIds"
}

/// Coalesces repeated main-thread signals into one callback after a short delay.
/// Useful for notification storms where only the latest update matters.
final class NotificationBurstCoalescer {
    private let delay: TimeInterval
    private var isFlushScheduled = false
    private var pendingAction: (() -> Void)?

    init(delay: TimeInterval = 1.0 / 30.0) {
        self.delay = max(0, delay)
    }

    func signal(_ action: @escaping () -> Void) {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        pendingAction = action
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        isFlushScheduled = false
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }
}

#if DEBUG
// Sample the actual IOSurface-backed terminal layer at vsync cadence so UI tests can reliably
// catch a single compositor-frame blank flash and any transient compositor scaling (stretched text).
//
// This is DEBUG-only and used only for UI tests; no polling or display-link loops exist in normal app runtime.
fileprivate final class VsyncIOSurfaceTimelineState {
    struct Target {
        let label: String
        let sample: @MainActor () -> GhosttySurfaceScrollView.DebugFrameSample?
    }

    let frameCount: Int
    let closeFrame: Int
    let lock = NSLock()

    var framesWritten = 0
    var inFlight = false
    var finished = false

    var scheduledActions: [(frame: Int, action: () -> Void)] = []
    var nextActionIndex: Int = 0

    var targets: [Target] = []

    // Results
    var firstBlank: (label: String, frame: Int)?
    var firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?
    var trace: [String] = []

    var link: CVDisplayLink?
    var continuation: CheckedContinuation<Void, Never>?

    init(frameCount: Int, closeFrame: Int) {
        self.frameCount = frameCount
        self.closeFrame = closeFrame
    }

    func tryBeginCapture() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        if inFlight { return false }
        inFlight = true
        return true
    }

    func endCapture() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }

    func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

fileprivate func cmuxVsyncIOSurfaceTimelineCallback(
    _ displayLink: CVDisplayLink,
    _ inNow: UnsafePointer<CVTimeStamp>,
    _ inOutputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ ctx: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let ctx else { return kCVReturnSuccess }
    let st = Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).takeUnretainedValue()
    if !st.tryBeginCapture() { return kCVReturnSuccess }

    // Sample on the main thread synchronously so we don't "miss" a single compositor frame.
    // (The previous Task/@MainActor hop could be delayed long enough to skip the blank frame.)
    DispatchQueue.main.sync {
        defer { st.endCapture() }
        guard st.framesWritten < st.frameCount else { return }

        while st.nextActionIndex < st.scheduledActions.count {
            let next = st.scheduledActions[st.nextActionIndex]
            if next.frame != st.framesWritten { break }
            st.nextActionIndex += 1
            next.action()
        }

        for t in st.targets {
            guard let s = t.sample() else { continue }

            let iosW = s.iosurfaceWidthPx
            let iosH = s.iosurfaceHeightPx
            let expW = s.expectedWidthPx
            let expH = s.expectedHeightPx
            let gravity = s.layerContentsGravity
            let hasDimensions = iosW > 0 && iosH > 0 && expW > 0 && expH > 0
            let dw = hasDimensions ? abs(iosW - expW) : 0
            let dh = hasDimensions ? abs(iosH - expH) : 0
            let hasSizeMismatch = hasDimensions && (dw > 2 || dh > 2)
            let stretchRisk = (gravity == CALayerContentsGravity.resize.rawValue)

            // Ignore setup/warmup frames before the close action. We only care about
            // regressions that happen at/after the close mutation.
            if st.firstBlank == nil, st.framesWritten >= st.closeFrame, s.isProbablyBlank {
                st.firstBlank = (label: t.label, frame: st.framesWritten)
            }

            if st.firstSizeMismatch == nil,
               st.framesWritten >= st.closeFrame,
               stretchRisk,
               hasSizeMismatch {
                st.firstSizeMismatch = (
                    label: t.label,
                    frame: st.framesWritten,
                    ios: "\(iosW)x\(iosH)",
                    expected: "\(expW)x\(expH)"
                )
            }

            if st.trace.count < 200 {
                st.trace.append("\(st.framesWritten):\(t.label):blank=\(s.isProbablyBlank ? 1 : 0):ios=\(iosW)x\(iosH):exp=\(expW)x\(expH):gravity=\(gravity):key=\(s.layerContentsKey)")
            }
        }

        st.framesWritten += 1
    }

    // Stop/resume outside the main-thread sync block to avoid reentrancy issues.
    if st.framesWritten >= st.frameCount, let link = st.link {
        CVDisplayLinkStop(link)
        st.finish()
        Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).release()
    }

    return kCVReturnSuccess
}
#endif

// WorkspaceGroup, WorkspaceReorderPlanItem, WorkspaceBatchReorderError, and
// the pure batch-reorder planning live in CmuxWorkspaces.

// @unchecked Sendable: every mutable field is guarded by `lock`. This is
// DEBUG-only test scaffolding, touched synchronously from the FSEvents callback,
// the synthetic-event producer thread, and the measuring helper — a synchronous
// compare-and-set guard, not ongoing domain state, so a lock is the right shape.
@MainActor
class TabManager: ObservableObject {
    private enum WorkspacePullRequestSnapshot: Equatable, Sendable {
        case deferred
        case unsupportedRepository
        case notFound
        case resolved(SidebarPullRequestState)
        case transientFailure
    }

    private struct InitialWorkspaceGitMetadataSnapshot: Equatable, Sendable {
        let isRepository: Bool
        let branch: String?
        let isDirty: Bool
        let indexSignature: String?
        let indexContentSignature: String?
        let headSignature: String?
        let pullRequest: WorkspacePullRequestSnapshot
    }

    private struct WorkspaceGitMetadataWatcherDescriptorRequest: Equatable, Sendable {
        let generation: UInt64
        let directory: String
    }

    private struct WorkspaceGitProbeKey: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }

    private struct WorkspaceGitSnapshotProbeRequest: Sendable {
        let probeKey: WorkspaceGitProbeKey
        let isLastAttempt: Bool
    }

    private enum WorkspaceGitProbeState: Equatable {
        case idle
        case inFlight(rerunPending: Bool)
    }

    private struct ResolvedGitRepository: Equatable, Sendable {
        let workTreeRoot: String
        let gitDirectory: String
        let commonDirectory: String
    }

    private struct GitIndexEntryStat: Sendable {
        let path: String
        let mode: UInt32
        let objectID: String
        let mtimeSeconds: UInt32
        let mtimeNanoseconds: UInt32
        let size: UInt32
    }

    private struct GitIndexSnapshot: Sendable {
        let entries: [GitIndexEntryStat]
        let signature: String
        let contentSignature: String
    }

    typealias WorkspacePullRequestShellRefreshTarget = CMUXGitHubPullRequestRefreshTarget

    /// The window that owns this TabManager. Set by AppDelegate.registerMainWindow().
    /// Used to apply title updates to the correct window instead of NSApp.keyWindow.
    weak var window: NSWindow?
    /// Stable identifier of the owning macOS window. Used only for opt-in title
    /// templates that expose a WM-matchable per-window token.
    var windowId: UUID?

    @Published var isLeaderModeActive: Bool = false
    // Wave-4 sub-model (TabManager decomposition): the workspace list, the
    // sidebar group sections, and the selected-workspace id storage live in
    // WorkspacesModel (CmuxWorkspaces). TabManager stays the per-window
    // composition point: it owns the model, forwards the legacy accessors
    // below, and implements WorkspacesHosting (bottom of this file) to run
    // the legacy @Published property-observer side effects at identical
    // timing (objectWillChange + bridge publishers in willSet, selection
    // side effects in didSet).
    let workspaces = WorkspacesModel<Workspace>()

    var tabs: [Workspace] {
        get { workspaces.tabs }
        set { workspaces.tabs = newValue }
    }
    /// Named groupings of workspaces shown as collapsible sections in the sidebar.
    /// Group order in this array defines section order in the sidebar.
    /// Each member workspace stores its `groupId` on the `Workspace` model.
    var workspaceGroups: [WorkspaceGroup] {
        get { workspaces.workspaceGroups }
        set { workspaces.workspaceGroups = newValue }
    }

    /// Legacy Combine bridge for the remaining `tabManager.$tabs`
    /// subscribers. Driven exclusively from `workspaceTabsWillChange(to:)`,
    /// so it emits the new value during willSet and replays the current
    /// value on subscribe — the exact `Published.Publisher` semantics those
    /// call sites were written against. Single seam; delete when the
    /// subscribers move to @Observable observation.
    let tabsPublisher = CurrentValueSubject<[Workspace], Never>([])
    /// Legacy Combine bridge for the remaining `tabManager.$selectedTabId`
    /// subscribers; same contract as `tabsPublisher`.
    let selectedTabIdPublisher = CurrentValueSubject<UUID?, Never>(nil)
    /// Legacy Combine bridge for the remaining `tabManager.$workspaceGroups`
    /// subscribers (e.g. MobileWorkspaceListObserver); same contract as
    /// `tabsPublisher`. Emits during willSet and replays the current value
    /// on subscribe — the `Published.Publisher` semantics those call sites
    /// were written against.
    let workspaceGroupsPublisher = CurrentValueSubject<[WorkspaceGroup], Never>([])
    /// Set by `restoreSessionSnapshot` to suppress side-effects (like auto-
    /// expanding a group on focus) that would mutate restored state mid-restore.
    private var isRestoringSessionSnapshot: Bool = false
    @Published private(set) var isWorkspaceCycleHot: Bool = false
    @Published private(set) var notificationAutoReorderAllowedBySort =
        !WorkspaceSummaryPrioritySettings.isEnabled() || WorkspaceSidebarSummaryPrioritySort.defaultSort.isNative
    @Published private(set) var pendingBackgroundWorkspaceLoadIds: Set<UUID> = []
    @Published private(set) var mountedBackgroundWorkspaceLoadIds: Set<UUID> = []
    @Published private(set) var debugPinnedWorkspaceLoadIds: Set<UUID> = []

    /// Global monotonically increasing counter for CMUX_PORT ordinal assignment.
    /// Static so port ranges don't overlap across multiple windows (each window has its own TabManager).
    static var nextPortOrdinal: Int = 0
    private nonisolated static let initialWorkspaceGitProbeDelays: [TimeInterval] = [0, 0.5, 1.5, 3.0, 6.0, 10.0]
    private nonisolated static let workspaceGitMetadataFallbackRefreshInterval: TimeInterval = 5 * 60
    private nonisolated static let backgroundPollInterval: TimeInterval = 60
    private nonisolated static let selectedPollInterval: TimeInterval = 10
    private nonisolated static let workspacePullRequestRepoCacheLifetime: TimeInterval = 15
    private nonisolated static let workspaceGHPRMetadataRefreshInterval: TimeInterval = 60
    private nonisolated static let workspacePullRequestRepoCachePruneLifetime: TimeInterval = 60
    private nonisolated static let workspacePullRequestPollJitterFraction = 0.10
    private nonisolated static let workspacePullRequestProbeTimeout: TimeInterval = 5.0
    private nonisolated static let mergedPullRequestBadgeStaleAfter: TimeInterval = 14 * 24 * 60 * 60
    private nonisolated static let workspacePullRequestFailureBackoffMaxInterval: TimeInterval = 5 * 60
    private nonisolated static let workspacePullRequestRateLimitFallbackCooldown: TimeInterval = 5 * 60
    private nonisolated static let workspacePullRequestStaleThreshold = 3
    private nonisolated static let workspacePullRequestTerminalStateSweepInterval: TimeInterval = 15 * 60
    nonisolated static let workspacePullRequestQueuedShellTriggerReason = "queuedShellTrigger"
    private nonisolated static let workspacePullRequestRefreshBatchLimit = 3
    private nonisolated static let mobileHostBackgroundWorkDeferralInterval: TimeInterval = 2.0
    private nonisolated static let mobileHostBackgroundWorkQuietInterval: TimeInterval = 60.0
    var selectedTabId: UUID? {
        get { workspaces.selectedTabId }
        set { workspaces.selectedTabId = newValue }
    }

    // MARK: - WorkspacesHosting hooks (legacy @Published property observers)

    /// Legacy `@Published tabs` willSet: objectWillChange plus the Combine
    /// bridge fire before storage changes, matching @Published timing.
    func workspaceTabsWillChange(to newValue: [Workspace]) {
        objectWillChange.send()
        tabsPublisher.send(newValue)
    }

    /// Legacy `@Published workspaceGroups` willSet.
    func workspaceGroupsWillChange(to newValue: [WorkspaceGroup]) {
        objectWillChange.send()
        workspaceGroupsPublisher.send(newValue)
    }

    /// Legacy `@Published selectedTabId` willSet; `selectedTabId` still
    /// reads the old value here, exactly like the original property observer.
    func selectedWorkspaceIdWillChange(to newValue: UUID?) {
        objectWillChange.send()
        selectedTabIdPublisher.send(newValue)
#if DEBUG
            guard newValue != selectedTabId else {
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
                debugPreparedWorkspaceSwitchTarget = nil
                return
            }

            if debugPreparedWorkspaceSwitchTarget == newValue {
                debugPreparedWorkspaceSwitchTarget = nil
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
            } else {
                let trigger = (debugPendingWorkspaceSwitchTarget == newValue
                    ? debugPendingWorkspaceSwitchTrigger
                    : nil) ?? "direct"
                debugPendingWorkspaceSwitchTrigger = nil
                debugPendingWorkspaceSwitchTarget = nil
                debugBeginWorkspaceSwitch(
                    trigger: trigger,
                    from: selectedTabId,
                    to: newValue
                )
            }
#endif
    }

    /// Legacy `@Published selectedTabId` didSet: the selection side-effect
    /// chain, run synchronously after storage changed.
    func selectedWorkspaceIdDidChange(from oldValue: UUID?) {
            guard selectedTabId != oldValue else { return }
            if !isRestoringSessionSnapshot {
                workspaces.expandWorkspaceGroupForSelectionIfNeeded()
            }
            sentryBreadcrumb("workspace.switch", data: [
                "tabCount": tabs.count
            ])
            let previousTabId = oldValue
            if let previousTabId,
               let previousPanelId = focusedPanelId(for: previousTabId) {
                lastFocusedPanelByTab[previousTabId] = previousPanelId
            }
            if shouldRecordFocusHistory {
                if let previousTabId {
                    focusHistoryNavigation.recordFocusInHistory(
                        workspaceId: previousTabId,
                        panelId: focusedPanelId(for: previousTabId),
                        preservingForwardBranch: false
                    )
                }
                if let selectedTabId,
                   tabs.contains(where: { $0.id == selectedTabId }) {
                    let selectedEntry = FocusHistoryEntry(
                        workspaceId: selectedTabId,
                        panelId: lastFocusedPanelByTab[selectedTabId]
                    )
                    focusHistoryNavigation.recordFocusInHistory(
                        workspaceId: selectedTabId,
                        panelId: focusHistoryNavigation.resolvedFocusHistoryPanelId(for: selectedEntry),
                        preservingForwardBranch: false
                    )
                }
            }
            publishCmuxWorkspaceSelectedChange(from: previousTabId)
            let notificationDismissalContext = notificationDismissal.takePendingSelectionContext() ?? .activeFocus
#if DEBUG
            let switchId = debugWorkspaceSwitchId
            let switchDtMs = debugWorkspaceSwitchStartTime > 0
                ? (CACurrentMediaTime() - debugWorkspaceSwitchStartTime) * 1000
                : 0
            cmuxDebugLog(
                "ws.select.didSet id=\(switchId) from=\(Self.debugShortWorkspaceId(previousTabId)) " +
                "to=\(Self.debugShortWorkspaceId(selectedTabId)) dt=\(Self.debugMsText(switchDtMs))"
            )
#endif
            selectionSideEffectsGeneration &+= 1
            let generation = selectionSideEffectsGeneration
            if !shouldRecordFocusHistory {
                focusHistoryNavigation.markSuppressedSelectionSideEffectGeneration(generation)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let suppressFocusHistory = self.focusHistoryNavigation.consumeSuppressedSelectionSideEffectGeneration(generation)
                guard self.selectionSideEffectsGeneration == generation else { return }
                let applySelectionSideEffects = {
                    self.focusSelectedTabPanel(previousTabId: previousTabId)
                    self.updateWindowTitleForSelectedTab()
                    if let selectedTabId = self.selectedTabId {
                        self.dismissFocusedPanelNotificationIfActive(
                            tabId: selectedTabId,
                            context: notificationDismissalContext
                        )
                    }
                }
                if suppressFocusHistory {
                    self.focusHistoryNavigation.withFocusHistoryRecordingSuppressed(applySelectionSideEffects)
                } else {
                    applySelectionSideEffects()
                }
#if DEBUG
                let dtMs = self.debugWorkspaceSwitchStartTime > 0
                    ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                    : 0
                cmuxDebugLog(
                    "ws.select.asyncDone id=\(self.debugWorkspaceSwitchId) dt=\(Self.debugMsText(dtMs)) " +
                    "selected=\(Self.debugShortWorkspaceId(self.selectedTabId))"
                )
#endif
            }
    }
    private var observers: [NSObjectProtocol] = []
    private var workspaceTagsObservation: NSKeyValueObservation?
    private var suppressFocusFlash = false
    private var pendingSelectedTabNotificationDismissContext: NotificationDismissalContext?
    private var lastFocusedPanelByTab: [UUID: UUID] = [:]
    private struct PanelTitleUpdateKey: Hashable {
        let tabId: UUID
        let panelId: UUID
    }
    private var pendingPanelTitleUpdates: [PanelTitleUpdateKey: String] = [:]
    private let panelTitleUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)

    // Inline sidebar git/PR subsystem state (plus). The decomposed
    // CmuxSidebarGit services keep their own copies; these dictionaries back
    // the plus-specific inline probe/poll/PR-tracking implementation that
    // layers extra GitHub PR behavior on top.
    private var workspaceGitProbeStateByKey: [WorkspaceGitProbeKey: WorkspaceGitProbeState] = [:]
    private var workspaceGitProbeTasksByKey: [WorkspaceGitProbeKey: Task<Void, Never>] = [:]
    private var workspaceGitTrackedDirectoryByKey: [WorkspaceGitProbeKey: String] = [:]
    private var workspaceGitCleanIndexSignatureByKey: [WorkspaceGitProbeKey: String] = [:]
    private var workspaceGitCleanIndexContentSignatureByKey: [WorkspaceGitProbeKey: String] = [:]
    private var workspaceGitHeadSignatureByKey: [WorkspaceGitProbeKey: String] = [:]
    private var workspaceGitMetadataWatchersByKey: [WorkspaceGitProbeKey: RecursivePathWatcher] = [:]
    private var workspaceGitMetadataWatcherRefreshTasksByKey: [WorkspaceGitProbeKey: Task<Void, Never>] = [:]
    private var workspaceGitMetadataWatcherSourceDirectoryByKey: [WorkspaceGitProbeKey: String] = [:]
    private var workspaceGitMetadataWatcherDescriptorRequestsByKey: [WorkspaceGitProbeKey: WorkspaceGitMetadataWatcherDescriptorRequest] = [:]
    private var workspaceGitMetadataWatcherDescriptorGeneration: UInt64 = 0
    private var workspaceGitSnapshotRequestsByDirectory: [String: [WorkspaceGitSnapshotProbeRequest]] = [:]
    private var workspaceGitSnapshotTasksByDirectory: [String: Task<Void, Never>] = [:]
    private var workspaceGitSnapshotDirectoryByProbeKey: [WorkspaceGitProbeKey: String] = [:]
    private var workspaceGitMetadataFallbackTask: Task<Void, Never>?
    private var lastSidebarGitMetadataWatchEnabled = SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard)
    private var lastSidebarPullRequestPollingEnabled = SidebarWorkspaceDetailDefaults.pullRequestPollingEnabled(defaults: .standard)
    private var workspacePullRequestProbeStateByKey: [WorkspaceGitProbeKey: WorkspaceGitProbeState] = [:]
    private var workspacePullRequestNextPollAtByKey: [WorkspaceGitProbeKey: Date] = [:]
    private var workspacePullRequestLastTerminalStateRefreshAtByKey: [WorkspaceGitProbeKey: Date] = [:]
    private var workspacePullRequestTransientFailureCountByKey: [WorkspaceGitProbeKey: Int] = [:]
    private var workspacePullRequestRepoCacheBySlug: [String: WorkspacePullRequestRepoCacheEntry] = [:]
    private var workspacePullRequestPollTask: Task<Void, Never>?
    private var workspacePullRequestRefreshTask: Task<Void, Never>?
    private var workspacePullRequestFollowUpShouldBypassRepoCache = false

    // Wave-3 sub-models (TabManager decomposition): TabManager is the
    // per-window composition point. It owns the concrete sub-models, hosts
    // their seams, and forwards its legacy entry points.
    /// Per-panel notification-dismissal flow (CmuxNotifications).
    let notificationDismissal: any NotificationDismissing = NotificationDismissalModel()
    /// Recently-closed browser panel history (CmuxBrowser).
    let browserModel = BrowserModel<ClosedBrowserPanelRestoreSnapshot>()
    /// Sidebar multi-selection state + sync events (CmuxSidebar).
    let sidebarMultiSelection = SidebarMultiSelectionModel()
    /// Typed synchronous settings access (CmuxSettings).
    private let settings: any SettingsWriting
    private let settingsCatalog = SettingCatalog()

    @Published private(set) var focusHistoryRevision: UInt64 = 0 {
        didSet {
            guard focusHistoryRevision != oldValue else { return }
            NotificationCenter.default.post(name: .tabManagerFocusHistoryRevisionDidChange, object: self)
        }
    }
    // The focus-history back/forward stack lives in FocusHistoryModel
    // (CmuxWorkspaceNavigation); this window is its host via
    // FocusHistoryHosting and republishes its revision bumps through
    // `focusHistoryRevision` above.
    let focusHistoryNavigation: any FocusHistoryNavigating = FocusHistoryModel()
    // Stateless split-geometry application (equalize/resize divider moves);
    // the pure planning lives in CmuxPanes' ExternalTreeNode extensions.
    let paneLayout = PaneLayoutService()
    // Reorder/pin flows over the workspaces model (CmuxWorkspaces); owns
    // the pure batch-reorder planner.
    let workspaceReordering: WorkspaceReorderCoordinator<Workspace>
    // Workspace-group lifecycle flows over the workspaces model
    // (CmuxWorkspaces); creation/teardown/selection invert through
    // WorkspaceGroupHosting.
    let workspaceGrouping: WorkspaceGroupCoordinator<Workspace>
    private var shouldRecordFocusHistory: Bool {
        focusHistoryNavigation.shouldRecordFocusHistory
    }
    private var selectionSideEffectsGeneration: UInt64 = 0
    private var workspaceCycleGeneration: UInt64 = 0
    private var workspaceCycleCooldownTask: Task<Void, Never>?
    private var pendingWorkspaceUnfocusTarget: (tabId: UUID, panelId: UUID)?
    var sidebarSelectedWorkspaceIds: Set<UUID> { sidebarMultiSelection.selectedWorkspaceIds }
    private var currentWindowTabBarLeadingInset: CGFloat?
    private var closeConfirmationInFlight = false
    var confirmCloseHandler: ((String, String, Bool) -> Bool)?
    private var agentPIDSweepTimer: DispatchSourceTimer?
    private var workspaceGHPRMetadataRefreshTimer: DispatchSourceTimer?
    private let requestGHPRMetadataRefresh: (String) -> Void
    private let enhancementSystem: CMUXEnhancementAppProviding
#if DEBUG
    private var debugWorkspaceSwitchCounter: UInt64 = 0
    private var debugWorkspaceSwitchId: UInt64 = 0
    private var debugWorkspaceSwitchStartTime: CFTimeInterval = 0
    private var debugPendingWorkspaceSwitchTrigger: String?
    private var debugPendingWorkspaceSwitchTarget: UUID?
    private var debugPreparedWorkspaceSwitchTarget: UUID?
#endif

#if DEBUG
    private var didSetupSplitCloseRightUITest = false
    private var didSetupUITestFocusShortcuts = false
    private var didSetupChildExitSplitUITest = false
    private var didSetupChildExitKeyboardUITest = false
    private var uiTestCancellables = Set<AnyCancellable>()
#endif

    private static func uiTestFixtureForInitialState(
        initialWorkspaceTitle: String?,
        initialWorkingDirectory: String?,
        initialTerminalInput: String?
    ) -> CmuxUITestWorkspaceFixture? {
        guard initialWorkspaceTitle == nil,
              initialWorkingDirectory == nil,
              initialTerminalInput == nil else {
            return nil
        }
        return CmuxUITestWorkspaceFixture.current()
    }

    private func applyUITestWorkspaceFixture(_ fixture: CmuxUITestWorkspaceFixture) {
        guard !fixture.entries.isEmpty else { return }

        if let firstWorkspace = tabs.first,
           let firstEntry = fixture.entries.first {
            applyUITestWorkspaceFixtureEntry(firstEntry, to: firstWorkspace)
        }

        for entry in fixture.entries.dropFirst() {
            let workspace = addWorkspace(
                title: entry.title,
                workingDirectory: entry.workingDirectory,
                inheritWorkingDirectory: false,
                select: false,
                eagerLoadTerminal: false,
                placementOverride: .end,
                autoWelcomeIfNeeded: false
            )
            applyUITestWorkspaceFixtureEntry(entry, to: workspace)
        }
    }

    private func applyUITestWorkspaceFixtureEntry(
        _ entry: CmuxUITestWorkspaceFixture.Entry,
        to workspace: Workspace
    ) {
        workspace.setCustomTitle(entry.title)
        workspace.setCustomDescription(entry.description)
        workspace.setCustomColor(entry.color)
        if let status = entry.status {
            let timestamp = CmuxRuntimeMode.current().fixedNow ?? Date()
            workspace.statusEntries["ui_test.fixture.status"] = SidebarStatusEntry(
                key: "ui_test.fixture.status",
                value: status,
                icon: "sparkles",
                color: entry.color,
                priority: 100,
                timestamp: timestamp
            )
        }
        if let pullRequest = entry.pullRequest,
           let panelId = workspace.focusedPanelId,
           let url = URL(string: pullRequest.url) {
            workspace.updatePanelPullRequest(
                panelId: panelId,
                number: pullRequest.number,
                label: pullRequest.label,
                url: url,
                status: Self.uiTestPullRequestStatus(pullRequest.status),
                branch: pullRequest.branch,
                isStale: pullRequest.isStale
            )
        }
    }

    private static func uiTestPullRequestStatus(_ rawValue: String) -> SidebarPullRequestStatus {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case SidebarPullRequestStatus.merged.rawValue:
            return .merged
        case SidebarPullRequestStatus.closed.rawValue:
            return .closed
        default:
            return .open
        }
    }

    // Runs external commands (currently the `gh auth token` probe). Injected so
    // tests can supply a fake without spawning a real process.
    private let commandRunner: any CommandRunning

    // Reads on-disk git metadata (branch, dirty state, watched paths, remote
    // slugs) off the main actor. Stateless; the reads are pure functions of the
    // directory argument.
    private let gitMetadataService: GitMetadataService
    private let workspaceGitMetadataReader: any WorkspaceGitMetadataReading

    // Resolves GitHub PR badges (slug resolution, REST fetch, candidate
    // matching). Stateless; the repo cache stays here in
    // workspacePullRequestRepoCacheBySlug and is passed per refresh.
    private let pullRequestProbeService: PullRequestProbeService

    // Drives the git/PR polling delays (probe retry gaps, fallback loop, PR
    // poll deadline). Injected so tests can use virtual time.
    private let gitPollClock: any GitPollClock

    // Process-wide cap on concurrent sidebar git snapshot probes, shared by
    // every window's SidebarGitMetadataService. A static (not a per-instance
    // default) on purpose: the cap is per process, not per window, matching
    // the legacy shared limiter; tests inject their own instance.
    private static let sharedWorkspaceGitProbeLimiter = WorkspaceGitMetadataProbeLimiter(limit: 2)

    // The sidebar git/PR subsystem (extracted to CmuxSidebarGit). TabManager
    // is the per-window composition point: it constructs the concrete
    // services, stores only the seams, implements SidebarGitHosting
    // (see TabManager+SidebarGitHosting.swift), and forwards its legacy
    // entry points.
    let sidebarGitMetadataService: any SidebarGitMetadataServing
    let pullRequestProbing: any PullRequestProbing

    init(
        initialWorkspaceTitle: String? = nil,
        initialWorkingDirectory: String? = nil,
        initialTerminalInput: String? = nil,
        autoWelcomeIfNeeded: Bool = true,
        ghprContextRefresher: CMUXGHPRContextRefreshProviding = CMUXPluginSystem.shared,
        requestGHPRMetadataRefresh: ((String) -> Void)? = nil,
        enhancementSystem: CMUXEnhancementAppProviding = CMUXEnhancementSystem.shared,
        commandRunner: any CommandRunning = CommandRunner(),
        gitMetadataService: GitMetadataService = GitMetadataService(),
        workspaceGitMetadataReader: (any WorkspaceGitMetadataReading)? = nil,
        gitPollClock: any GitPollClock = SystemGitPollClock(),
        gitProbeLimiter: WorkspaceGitMetadataProbeLimiter? = nil,
        settings: any SettingsWriting = UserDefaultsSettingsClient(defaults: .standard)
    ) {
        self.commandRunner = commandRunner
        self.requestGHPRMetadataRefresh = requestGHPRMetadataRefresh ?? { workspaceId in
            ghprContextRefresher.requestGHPRContextRefresh(workspaceId: workspaceId)
        }
        self.enhancementSystem = enhancementSystem
        self.gitMetadataService = gitMetadataService
        self.workspaceGitMetadataReader = workspaceGitMetadataReader ?? gitMetadataService
        self.gitPollClock = gitPollClock
        self.settings = settings
        workspaceReordering = WorkspaceReorderCoordinator(model: workspaces)
        workspaceGrouping = WorkspaceGroupCoordinator(model: workspaces)
#if DEBUG
        let sidebarGitDebugLog: @Sendable (String) -> Void = { cmuxDebugLog($0) }
#else
        let sidebarGitDebugLog: @Sendable (String) -> Void = { _ in }
#endif
        let pullRequestProbeService = PullRequestProbeService(
            commandRunner: commandRunner,
            debugLog: sidebarGitDebugLog
        )
        self.pullRequestProbeService = pullRequestProbeService
        let pullRequestPollService = PullRequestPollService(
            gitMetadataService: gitMetadataService,
            probeService: pullRequestProbeService,
            clock: gitPollClock,
            debugLog: sidebarGitDebugLog
        )
        self.pullRequestProbing = pullRequestPollService
        self.sidebarGitMetadataService = SidebarGitMetadataService(
            workspaceGitMetadataReader: workspaceGitMetadataReader ?? gitMetadataService,
            gitMetadataService: gitMetadataService,
            pullRequestProbing: pullRequestPollService,
            probeLimiter: gitProbeLimiter ?? Self.sharedWorkspaceGitProbeLimiter,
            clock: gitPollClock,
            debugLog: sidebarGitDebugLog
        )
        // Wire the host seam before the first workspace is added so the
        // initial git probe scheduling (addWorkspace below) reaches the
        // services, matching the legacy in-class scheduling timing.
        pullRequestProbing.attach(host: self)
        sidebarGitMetadataService.attach(host: self)
        notificationDismissal.attach(host: self)
        focusHistoryNavigation.attach(host: self)
        // Workspace-list/group/selection storage (CmuxWorkspaces). Attached
        // before the first addWorkspace so the property-observer hooks fire
        // from the very first insertion, matching the legacy @Published
        // observer timing.
        workspaces.attach(host: self)
        workspaceReordering.attach(host: self)
        workspaceGrouping.attach(host: self)
        let uiTestFixture = Self.uiTestFixtureForInitialState(
            initialWorkspaceTitle: initialWorkspaceTitle,
            initialWorkingDirectory: initialWorkingDirectory,
            initialTerminalInput: initialTerminalInput
        )
        let initialFixtureEntry = uiTestFixture?.entries.first
        addWorkspace(
            title: initialWorkspaceTitle ?? initialFixtureEntry?.title,
            workingDirectory: initialWorkingDirectory ?? initialFixtureEntry?.workingDirectory,
            initialTerminalInput: initialTerminalInput,
            autoWelcomeIfNeeded: autoWelcomeIfNeeded && uiTestFixture == nil
        )
        if let uiTestFixture {
            applyUITestWorkspaceFixture(uiTestFixture)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                guard let change = GhosttyTitleChange(notification: notification) else { return }
                enqueuePanelTitleUpdate(tabId: change.tabId, panelId: change.surfaceId, title: change.title)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
                guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
                let explicitFocusIntent = notification.userInfo?[GhosttyNotificationKey.explicitFocusIntent] as? Bool ?? false
                let panelId = panelIdForFocusHistorySurface(surfaceId, workspaceId: tabId)
                if selectedTabId == tabId {
                    if explicitFocusIntent {
                        focusHistoryNavigation.recordFocusInHistory(
                            workspaceId: tabId,
                            panelId: panelId,
                            preservingForwardBranch: false
                        )
                    } else {
                        focusHistoryNavigation.recordImplicitFocusInHistory(workspaceId: tabId, panelId: panelId)
                    }
                }
                dismissPanelNotificationOnFocus(tabId: tabId, panelId: panelId, explicitFocusIntent: explicitFocusIntent)
                focusedSurfaceTitleDidChange(tabId: tabId)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .workspaceCurrentDirectoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                let workspaceId = notification.userInfo?["workspaceId"] as? UUID
                    ?? (notification.object as? Workspace)?.id
                guard let workspaceId else { return }
                workspaceCurrentDirectoryDidChange(workspaceId: workspaceId)
            }
        })

        workspaceTagsObservation = UserDefaults.standard.observe(
            \.workspaceTagsEnabled,
            options: [.old, .new]
        ) { [weak self] _, change in
            guard change.oldValue != change.newValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for workspace in tabs {
                    workspace.objectWillChange.send()
                }
            }
        }

        startAgentPIDSweepTimer()
        startWorkspaceGHPRMetadataRefreshTimer()
        updateWorkspacePullRequestPollTimer()
        updateWorkspaceGitMetadataFallbackTimer()
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.sidebarMetadataSettingsDidChange()
                self?.refreshTabCloseButtonVisibility()
                self?.refreshWindowTitle()
            }
        })
#if DEBUG
        setupUITestFocusShortcutsIfNeeded()
        setupSplitCloseRightUITestIfNeeded()
        setupChildExitSplitUITestIfNeeded()
        setupChildExitKeyboardUITestIfNeeded()
#endif
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        workspaceCycleCooldownTask?.cancel()
        agentPIDSweepTimer?.cancel()
        workspaceGHPRMetadataRefreshTimer?.cancel()
        workspacePullRequestPollTask?.cancel()
        workspaceGitMetadataFallbackTask?.cancel()
        for task in workspaceGitProbeTasksByKey.values {
            task.cancel()
        }
        for task in workspaceGitSnapshotTasksByDirectory.values {
            task.cancel()
        }
        workspacePullRequestRefreshTask?.cancel()
        // The sidebar git/PR services cancel their own poll, probe, snapshot,
        // and refresh tasks in their deinits; they deallocate with this
        // TabManager (the host back-references are weak).
    }

    // MARK: - Agent PID Sweep

    /// Periodically checks agent PIDs associated with status entries.
    /// If a process has exited (SIGKILL, crash, etc.), clears the stale status entry.
    /// This is the safety net for cases where no hook fires (e.g. SIGKILL).
    private func startAgentPIDSweepTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sweepStaleAgentPIDs()
            }
        }
        timer.resume()
        agentPIDSweepTimer = timer
    }

    // MARK: - Sidebar git/PR (inline plus implementation)

    private func startWorkspaceGHPRMetadataRefreshTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let interval = Self.workspaceGHPRMetadataRefreshInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                self?.refreshGHPRMetadataForSidebarPullRequests()
            }
        }
        timer.resume()
        workspaceGHPRMetadataRefreshTimer = timer
    }

    @discardableResult
    func refreshGHPRMetadataForSidebarPullRequests() -> [UUID] {
        let workspaceIds = tabs.compactMap { workspace -> UUID? in
            workspace.sidebarPullRequestsInDisplayOrder().isEmpty ? nil : workspace.id
        }
        for workspaceId in workspaceIds {
            requestGHPRMetadataRefresh(workspaceId.uuidString)
        }
        return workspaceIds
    }

    private func updateWorkspacePullRequestPollTimer() {
        workspacePullRequestPollTask?.cancel()
        workspacePullRequestPollTask = nil

        guard sidebarPullRequestPollingEnabled,
              workspacePullRequestRefreshTask == nil else {
            return
        }

        let nextQueuedShellRefreshAt = enhancementSystem.github.nextQueuedRefreshAt()
        guard let nextPollAt = [
            workspacePullRequestNextPollAtByKey.values.min(),
            nextQueuedShellRefreshAt,
        ].compactMap({ $0 }).min() else {
            return
        }

        let delay = max(0.25, nextPollAt.timeIntervalSinceNow)
        let clock = gitPollClock
        workspacePullRequestPollTask = Task { @MainActor [weak self] in
            // Bounded, cancellable poll deadline on the injected clock;
            // re-arming cancels the previous task.
            do {
                try await clock.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            if !self.flushQueuedWorkspacePullRequestShellRefreshesIfNeeded(now: Date()) {
                self.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "timer")
            }
        }
    }

    /// Reschedules the workspace pull-request refresh after the paired mobile
    /// host goes quiet, so background polling does not contend with active
    /// mobile-host request traffic. Re-arming cancels the previous deadline.
    private func deferWorkspacePullRequestRefreshForMobileHost() {
        workspacePullRequestPollTask?.cancel()
        workspacePullRequestPollTask = nil

        let quietDelay = MobileHostRequestActivity.quietDelay(
            for: Self.mobileHostBackgroundWorkQuietInterval
        )
        let delay = max(Self.mobileHostBackgroundWorkDeferralInterval, quietDelay)
        let clock = gitPollClock
        workspacePullRequestPollTask = Task { @MainActor [weak self] in
            // Bounded, cancellable mobile-host deferral on the injected clock;
            // re-arming cancels the previous task.
            do {
                try await clock.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.refreshTrackedWorkspacePullRequestsIfNeeded(reason: "mobileHostDeferred")
        }
    }

    private func updateWorkspaceGitMetadataFallbackTimer() {
        guard sidebarGitMetadataWatchEnabled,
              !workspaceGitTrackedDirectoryByKey.isEmpty else {
            workspaceGitMetadataFallbackTask?.cancel()
            workspaceGitMetadataFallbackTask = nil
            return
        }

        guard workspaceGitMetadataFallbackTask == nil else {
            return
        }

        let clock = gitPollClock
        let interval = Self.workspaceGitMetadataFallbackRefreshInterval
        workspaceGitMetadataFallbackTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Bounded, cancellable fallback interval on the injected clock
                // (replaces the repeating DispatchSource timer).
                do {
                    try await clock.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.refreshTrackedWorkspaceGitMetadata(reason: "fallbackTimer")
            }
        }
    }

    private func refreshTrackedWorkspaceGitMetadata(reason: String) {
        let activeProbeKeys = activeWorkspaceGitProbeKeys

        for workspace in tabs {
            for panelId in trackedWorkspaceGitMetadataPollCandidatePanelIds(
                in: workspace,
                activeProbeKeys: activeProbeKeys
            ) {
                scheduleWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    reason: reason
                )
            }
        }
    }

    private var sidebarGitMetadataWatchEnabled: Bool {
        SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard)
    }

    private var sidebarPullRequestPollingEnabled: Bool {
        SidebarWorkspaceDetailDefaults.pullRequestPollingEnabled(defaults: .standard)
    }

    // MARK: - Sidebar git/PR forwarders (subsystem extracted to CmuxSidebarGit)

    private func sidebarMetadataSettingsDidChange() {
        sidebarGitMetadataService.sidebarGitMetadataWatchSettingsDidChange()
        pullRequestProbing.sidebarPullRequestPollingSettingsDidChange()
        refreshRemotePortScanningEnablement()
    }

    /// Last ports-visibility enablement fanned out to remote sessions; gates
    /// the `UserDefaults.didChangeNotification` firehose to actual transitions.
    private var lastRemotePortScanningEnabled: Bool?

    /// Propagates the sidebar ports-visibility settings to every live remote
    /// session so that disabling `sidebar.showPorts` (or enabling
    /// `sidebar.hideAllDetails`) actually stops the backend ssh port-scan loop,
    /// not just the sidebar display (issue #6123). New remote workspaces pick
    /// up the current value at creation, so this only needs to react to a
    /// change for already-connected sessions.
    private func refreshRemotePortScanningEnablement() {
        let enabled = Workspace.remotePortScanningEnabledFromSettings()
        guard enabled != lastRemotePortScanningEnabled else { return }
        lastRemotePortScanningEnabled = enabled
        for tab in tabs where tab.isRemoteWorkspace {
            tab.applyRemotePortScanningEnabled(enabled)
        }
    }

    private func sidebarGitMetadataWatchSettingsDidChange() {
        let isEnabled = sidebarGitMetadataWatchEnabled
        guard isEnabled != lastSidebarGitMetadataWatchEnabled else {
            return
        }
        lastSidebarGitMetadataWatchEnabled = isEnabled

        guard isEnabled else {
            stopAllWorkspaceGitMetadataWatchers()
            workspaceGitMetadataFallbackTask?.cancel()
            workspaceGitMetadataFallbackTask = nil
            workspaceGitProbeStateByKey.removeAll()
            for task in workspaceGitProbeTasksByKey.values {
                task.cancel()
            }
            workspaceGitProbeTasksByKey.removeAll()
            cancelAllWorkspaceGitSnapshotTasks()
            workspaceGitTrackedDirectoryByKey.removeAll()
            workspaceGitCleanIndexSignatureByKey.removeAll()
            workspaceGitCleanIndexContentSignatureByKey.removeAll()
            workspaceGitHeadSignatureByKey.removeAll()
            resetWorkspacePullRequestRefreshState()
            clearAllWorkspaceSidebarGitMetadata()
            return
        }

        restartWorkspaceGitMetadataWatching(reason: "gitWatchSettingEnabled")
        updateWorkspaceGitMetadataFallbackTimer()
    }

    private func sidebarPullRequestPollingSettingsDidChange() {
        let isEnabled = sidebarPullRequestPollingEnabled
        guard isEnabled != lastSidebarPullRequestPollingEnabled else {
            return
        }
        lastSidebarPullRequestPollingEnabled = isEnabled

        guard isEnabled else {
            resetWorkspacePullRequestRefreshState()
            clearAllWorkspaceSidebarPullRequestMetadata()
            return
        }

        refreshTrackedWorkspacePullRequestsIfNeeded(reason: "pullRequestVisibilityEnabled")
    }

    private func restartWorkspaceGitMetadataWatching(reason: String) {
        for workspace in tabs where !workspace.isRemoteWorkspace {
            for panelId in workspace.panels.keys {
                guard workspace.terminalPanel(for: panelId) != nil else {
                    continue
                }
                if let directory = gitProbeDirectory(for: workspace, panelId: panelId) {
                    let key = WorkspaceGitProbeKey(workspaceId: workspace.id, panelId: panelId)
                    workspaceGitTrackedDirectoryByKey[key] = directory
                    updateWorkspaceGitMetadataWatcher(for: key, directory: directory)
                }
                scheduleWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    reason: reason
                )
            }
        }
        updateWorkspaceGitMetadataFallbackTimer()
    }

    private func updateWorkspaceGitMetadataWatcher(
        for key: WorkspaceGitProbeKey,
        directory: String
    ) {
        guard sidebarGitMetadataWatchEnabled else {
            stopWorkspaceGitMetadataWatcher(for: key)
            return
        }

        if workspaceGitMetadataWatcherSourceDirectoryByKey[key] == directory,
           workspaceGitMetadataWatchersByKey[key] != nil {
            if workspaceGitMetadataWatcherDescriptorRequestsByKey[key]?.directory != directory {
                workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
            }
            return
        }

        if workspaceGitMetadataWatcherDescriptorRequestsByKey[key]?.directory == directory {
            return
        }

        workspaceGitMetadataWatcherDescriptorGeneration &+= 1
        let request = WorkspaceGitMetadataWatcherDescriptorRequest(
            generation: workspaceGitMetadataWatcherDescriptorGeneration,
            directory: directory
        )
        workspaceGitMetadataWatcherDescriptorRequestsByKey[key] = request

        Task { [weak self] in
            guard let gitMetadataService = self?.gitMetadataService else { return }
            let watchedPaths = await gitMetadataService.watchedPaths(for: directory)
            await MainActor.run { [weak self] in
                self?.applyWorkspaceGitMetadataWatcherDescriptor(
                    watchedPaths,
                    for: key,
                    request: request
                )
            }
        }
    }

    private func applyWorkspaceGitMetadataWatcherDescriptor(
        _ watchedPaths: [String]?,
        for key: WorkspaceGitProbeKey,
        request: WorkspaceGitMetadataWatcherDescriptorRequest
    ) {
        guard workspaceGitMetadataWatcherDescriptorRequestsByKey[key] == request else {
            return
        }
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)

        guard sidebarGitMetadataWatchEnabled,
              workspaceGitTrackedDirectoryByKey[key] == request.directory,
              let watchedPaths else {
            stopWorkspaceGitMetadataWatcher(for: key)
            return
        }

        if workspaceGitMetadataWatchersByKey[key]?.watchedPaths == watchedPaths {
            workspaceGitMetadataWatcherSourceDirectoryByKey[key] = request.directory
            return
        }

        stopWorkspaceGitMetadataWatcher(for: key)
        if let watcher = RecursivePathWatcher(paths: watchedPaths) {
            workspaceGitMetadataWatchersByKey[key] = watcher
            let events = watcher.events
            workspaceGitMetadataWatcherRefreshTasksByKey[key] = Task { @MainActor [weak self] in
                for await _ in events {
                    guard let self else { break }
                    self.scheduleWorkspaceGitMetadataRefreshIfPossible(
                        workspaceId: key.workspaceId,
                        panelId: key.panelId,
                        reason: "filesystemEvent"
                    )
                }
            }
        }
        workspaceGitMetadataWatcherSourceDirectoryByKey[key] = request.directory
    }

    private func stopWorkspaceGitMetadataWatcher(for key: WorkspaceGitProbeKey) {
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
        workspaceGitMetadataWatcherSourceDirectoryByKey.removeValue(forKey: key)
        workspaceGitMetadataWatcherRefreshTasksByKey.removeValue(forKey: key)?.cancel()
        // Dropping the last reference runs the watcher's deinit synchronously,
        // which invalidates the FSEventStream on its shared queue before this
        // returns. The consumer task captures the events stream (not the watcher),
        // so removal here is the last reference.
        workspaceGitMetadataWatchersByKey.removeValue(forKey: key)
    }

    private func stopWorkspaceGitMetadataWatchers(workspaceId: UUID) {
        let keys = workspaceGitMetadataWatchersByKey.keys.filter { $0.workspaceId == workspaceId }
        for key in keys {
            stopWorkspaceGitMetadataWatcher(for: key)
        }
    }

    private func stopAllWorkspaceGitMetadataWatchers() {
        for task in workspaceGitMetadataWatcherRefreshTasksByKey.values {
            task.cancel()
        }
        workspaceGitMetadataWatcherRefreshTasksByKey.removeAll()
        // Dropping the references runs each watcher's deinit synchronously,
        // invalidating its FSEventStream.
        workspaceGitMetadataWatchersByKey.removeAll()
        workspaceGitMetadataWatcherSourceDirectoryByKey.removeAll()
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeAll()
    }

    private func refreshTrackedWorkspacePullRequestsIfNeeded(
        reason: String,
        allowCachedResultsOverride: Bool? = nil
    ) {
        guard !MobileHostRequestActivity.hasRecentActivity(within: Self.mobileHostBackgroundWorkQuietInterval) else {
            deferWorkspacePullRequestRefreshForMobileHost()
            return
        }
        guard sidebarPullRequestPollingEnabled else {
            resetWorkspacePullRequestRefreshState()
            clearAllWorkspaceSidebarPullRequestMetadata()
            return
        }

        let now = Date()
        var candidateSeeds: [WorkspacePullRequestCandidateSeed] = []
        var requestedKeys: [WorkspaceGitProbeKey] = []
        var validKeys: Set<WorkspaceGitProbeKey> = []

        for workspace in tabs {
            for panelId in Set(workspace.panelGitBranches.keys).union(workspace.panelPullRequests.keys) {
                let key = WorkspaceGitProbeKey(workspaceId: workspace.id, panelId: panelId)
                validKeys.insert(key)
                let branch = GitMetadataService.normalizedBranchName(
                    workspace.panelGitBranches[panelId]?.branch
                        ?? workspace.panelPullRequests[panelId]?.branch
                )
                guard let branch else {
                    clearWorkspacePullRequestTracking(for: key)
                    continue
                }

                if PullRequestProbeService.shouldSkipLookup(branch: branch) {
                    workspace.clearPanelPullRequest(panelId: panelId)
                    clearWorkspacePullRequestTracking(for: key)
                    continue
                }

                guard shouldRefreshWorkspacePullRequest(
                    key: key,
                    now: now,
                    currentPullRequest: workspace.panelPullRequests[panelId]
                ) else {
                    continue
                }

                if case .inFlight = workspacePullRequestProbeStateByKey[key] {
                    markWorkspacePullRequestProbeRerunPending(
                        for: key,
                        bypassRepoCache: !PullRequestProbeService.refreshAllowsRepoCache(reason: reason)
                    )
                    continue
                }

                let candidateSeed = workspacePullRequestCandidateSeed(
                    workspace: workspace,
                    panelId: panelId,
                    branch: branch
                )
                candidateSeeds.append(candidateSeed)
                requestedKeys.append(key)
            }
        }

        pruneWorkspacePullRequestTracking(validKeys: validKeys)
        if candidateSeeds.count > Self.workspacePullRequestRefreshBatchLimit {
            candidateSeeds = Array(candidateSeeds.prefix(Self.workspacePullRequestRefreshBatchLimit))
            requestedKeys = Array(requestedKeys.prefix(Self.workspacePullRequestRefreshBatchLimit))
        }
        guard workspacePullRequestRefreshTask == nil else {
            updateWorkspacePullRequestPollTimer()
            return
        }
        guard !candidateSeeds.isEmpty else {
            updateWorkspacePullRequestPollTimer()
            return
        }
        workspacePullRequestPollTask?.cancel()
        workspacePullRequestPollTask = nil
        for key in requestedKeys {
            workspacePullRequestProbeStateByKey[key] = .inFlight(rerunPending: false)
        }

        let cacheBySlug = workspacePullRequestRepoCacheBySlug
        let allowCachedResults = allowCachedResultsOverride
            ?? PullRequestProbeService.refreshAllowsRepoCache(reason: reason)
        let gitMetadataService = gitMetadataService
        let pullRequestProbeService = pullRequestProbeService
        workspacePullRequestRefreshTask = Task.detached(priority: .utility) { [weak self] in
            let candidateResolution = await pullRequestProbeService.resolveCandidateSeeds(
                candidateSeeds,
                gitMetadata: gitMetadataService
            )
            guard !Task.isCancelled else { return }
            let repoResults = await pullRequestProbeService.fetchRepoResults(
                repoDirectoriesBySlug: candidateResolution.repoDirectoriesBySlug,
                candidateBranchesByRepo: candidateResolution.candidateBranchesByRepo,
                cacheBySlug: cacheBySlug,
                now: now,
                allowCachedResults: allowCachedResults
            )
            let results = PullRequestProbeService.resolveRefreshResults(
                candidates: candidateResolution.candidates,
                repoResults: repoResults
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.workspacePullRequestRefreshTask = nil
                self.applyWorkspacePullRequestRefreshResults(
                    results,
                    repoResults: repoResults,
                    requestedKeys: requestedKeys,
                    now: Date(),
                    reason: reason
                )
            }
        }
    }

    private func shouldRefreshWorkspacePullRequest(
        key: WorkspaceGitProbeKey,
        now: Date,
        currentPullRequest: SidebarPullRequestState?
    ) -> Bool {
        PullRequestProbeService.shouldRefresh(
            now: now,
            nextPollAt: workspacePullRequestNextPollAtByKey[key],
            lastTerminalStateRefreshAt: workspacePullRequestLastTerminalStateRefreshAtByKey[key],
            // Raw values are shared between the app and package status enums.
            currentStatus: currentPullRequest.flatMap { PullRequestStatus(rawValue: $0.status.rawValue) }
        )
    }

    private func workspacePullRequestCandidateSeed(
        workspace: Workspace,
        panelId: UUID,
        branch: String
    ) -> WorkspacePullRequestCandidateSeed {
        let directory = gitProbeDirectory(for: workspace, panelId: panelId)
        return WorkspacePullRequestCandidateSeed(
            workspaceId: workspace.id,
            panelId: panelId,
            branch: branch,
            directory: directory
        )
    }

    nonisolated static func workspacePullRequestShellRefreshTarget(
        branch: String,
        repoSlugs: [String]
    ) -> WorkspacePullRequestShellRefreshTarget? {
        guard let normalizedBranch = normalizedBranchName(branch) else {
            return nil
        }
        return WorkspacePullRequestShellRefreshTarget(
            branch: normalizedBranch,
            repoSlugs: repoSlugs
        )
    }

    private static func enhancementKey(_ key: WorkspaceGitProbeKey) -> CMUXGitHubPullRequestRefreshKey {
        CMUXGitHubPullRequestRefreshKey(workspaceId: key.workspaceId, panelId: key.panelId)
    }

    private static func probeKey(_ key: CMUXGitHubPullRequestRefreshKey) -> WorkspaceGitProbeKey {
        WorkspaceGitProbeKey(workspaceId: key.workspaceId, panelId: key.panelId)
    }

    private static func enhancementKeys(_ keys: Set<WorkspaceGitProbeKey>) -> Set<CMUXGitHubPullRequestRefreshKey> {
        Set(keys.map(enhancementKey))
    }

    private func workspacePullRequestShellRefreshTarget(
        workspace: Workspace,
        panelId: UUID
    ) -> WorkspacePullRequestShellRefreshTarget? {
        let branch = workspace.panelGitBranches[panelId]?.branch
            ?? workspace.panelPullRequests[panelId]?.branch
        guard let branch else { return nil }
        return Self.workspacePullRequestShellRefreshTarget(
            branch: branch,
            repoSlugs: []
        )
    }

    private func workspacePullRequestShellRefreshTarget(
        for key: WorkspaceGitProbeKey
    ) -> WorkspacePullRequestShellRefreshTarget? {
        guard let workspace = tabs.first(where: { $0.id == key.workspaceId }),
              workspace.panels[key.panelId] != nil else {
            return nil
        }
        return workspacePullRequestShellRefreshTarget(
            workspace: workspace,
            panelId: key.panelId
        )
    }

    private func removeWorkspacePullRequestShellRefreshProbeKey(_ key: WorkspaceGitProbeKey) {
        enhancementSystem.github.removeQueuedRefresh(key: Self.enhancementKey(key))
    }

    @discardableResult
    private func queueWorkspacePullRequestShellRefreshIfNeeded(
        workspaceId: UUID,
        panelId: UUID,
        reason: String,
        now: Date = Date()
    ) -> Bool {
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        guard sidebarPullRequestPollingEnabled else {
            clearWorkspacePullRequestMetadata(for: key)
            return false
        }
        guard reason == "shellPrompt" || reason.hasPrefix("commandHint:"),
              let workspace = tabs.first(where: { $0.id == workspaceId }),
              let target = workspacePullRequestShellRefreshTarget(
                workspace: workspace,
                panelId: panelId
              ) else {
            return false
        }

        let bypassRepoCache = !Self.workspacePullRequestRefreshAllowsRepoCache(reason: reason)
        let queued = enhancementSystem.github.queueRefreshIfNeeded(
            request: CMUXGitHubPullRequestRefreshRequest(
                key: Self.enhancementKey(key),
                reason: reason,
                target: target,
                bypassRepoCache: bypassRepoCache,
                triggerImmediateRefresh: false
            ),
            now: now
        )
        if queued {
            updateWorkspacePullRequestPollTimer()
        }
        return queued
    }

    private func requestWorkspacePullRequestRefresh(
        key: WorkspaceGitProbeKey,
        reason: String,
        bypassRepoCache: Bool,
        triggerImmediateRefresh: Bool = true
    ) {
        if bypassRepoCache, workspacePullRequestRefreshTask != nil {
            workspacePullRequestFollowUpShouldBypassRepoCache = true
        }
        if case .inFlight = workspacePullRequestProbeStateByKey[key] {
            markWorkspacePullRequestProbeRerunPending(
                for: key,
                bypassRepoCache: bypassRepoCache
            )
        } else {
            workspacePullRequestNextPollAtByKey[key] = .distantPast
        }
#if DEBUG
        cmuxDebugLog(
            "workspace.prRefresh.schedule workspace=\(key.workspaceId.uuidString.prefix(5)) " +
            "panel=\(key.panelId.uuidString.prefix(5)) reason=\(reason)"
        )
#endif
        guard triggerImmediateRefresh else { return }
        let allowCachedResultsOverride = bypassRepoCache ? false : nil
        refreshTrackedWorkspacePullRequestsIfNeeded(
            reason: reason,
            allowCachedResultsOverride: allowCachedResultsOverride
        )
    }

    private func scheduleWorkspacePullRequestRefresh(
        workspaceId: UUID,
        panelId: UUID,
        reason: String
    ) {
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let target = workspacePullRequestShellRefreshTarget(for: key)
        let request = CMUXGitHubPullRequestRefreshRequest(
            key: Self.enhancementKey(key),
            reason: reason,
            target: target,
            bypassRepoCache: !Self.workspacePullRequestRefreshAllowsRepoCache(reason: reason)
        )
        let action = CMUXEnhancementAction(
            id: CMUXGitHubEnhancementActionID.pullRequestRefresh,
            source: "TabManager",
            params: [
                "workspace_id": workspaceId.uuidString,
                "panel_id": panelId.uuidString,
                "reason": reason,
            ],
            payload: request
        )

        let handled = enhancementSystem.actions.dispatch(action) { [weak self] action in
            guard let self,
                  let request = action.payload as? CMUXGitHubPullRequestRefreshRequest else {
                return
            }
            self.requestWorkspacePullRequestRefresh(
                key: Self.probeKey(request.key),
                reason: request.reason,
                bypassRepoCache: request.bypassRepoCache,
                triggerImmediateRefresh: request.triggerImmediateRefresh
            )
        }
        if handled {
            updateWorkspacePullRequestPollTimer()
        }
    }

    private func applyWorkspacePullRequestRefreshResults(
        _ results: [WorkspacePullRequestRefreshResult],
        repoResults: [String: WorkspacePullRequestRepoFetchResult],
        requestedKeys: [WorkspaceGitProbeKey],
        now: Date,
        reason: String
    ) {
        guard !MobileHostRequestActivity.hasRecentActivity(within: Self.mobileHostBackgroundWorkQuietInterval) else {
            workspacePullRequestRefreshTask = nil
            for key in requestedKeys {
                workspacePullRequestProbeStateByKey[key] = .idle
                workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(Self.mobileHostBackgroundWorkQuietInterval)
            }
            deferWorkspacePullRequestRefreshForMobileHost()
            return
        }
        guard sidebarPullRequestPollingEnabled else {
            resetWorkspacePullRequestRefreshState()
            clearAllWorkspaceSidebarPullRequestMetadata()
            return
        }

        for (repoSlug, repoResult) in repoResults {
            guard case .success(let cacheEntry, let usedCache, _) = repoResult,
                  !usedCache else {
                continue
            }
            workspacePullRequestRepoCacheBySlug[repoSlug] = cacheEntry
        }

        let requestedKeySet = Set(requestedKeys)
        let resultsByKey = Dictionary(
            uniqueKeysWithValues: results.map {
                (WorkspaceGitProbeKey(workspaceId: $0.workspaceId, panelId: $0.panelId), $0)
            }
        )
        var needsFollowUpPass = false

        defer {
            if needsFollowUpPass {
                let shouldBypassRepoCache = workspacePullRequestFollowUpShouldBypassRepoCache
                workspacePullRequestFollowUpShouldBypassRepoCache = false
                refreshTrackedWorkspacePullRequestsIfNeeded(
                    reason: "\(reason).followUp",
                    allowCachedResultsOverride: shouldBypassRepoCache ? false : nil
                )
            }
        }

        for key in requestedKeys {
            let rerunPending = workspacePullRequestProbeRerunPending(for: key)
            workspacePullRequestProbeStateByKey[key] = .idle
            if rerunPending {
                workspacePullRequestNextPollAtByKey[key] = .distantPast
                needsFollowUpPass = true
            }

            guard requestedKeySet.contains(key),
                  let result = resultsByKey[key] else {
                continue
            }

            if rerunPending,
               workspacePullRequestFollowUpShouldBypassRepoCache,
               result.usedCachedRepoData {
                continue
            }

            guard let workspace = tabs.first(where: { $0.id == result.workspaceId }),
                  workspace.panels[result.panelId] != nil else {
                clearWorkspacePullRequestTracking(for: key)
                continue
            }

            let priorPullRequest = workspace.panelPullRequests[result.panelId]
            let countsAsTerminalSweep = priorPullRequest.map { $0.status != .open } ?? false

            switch result.resolution {
            case .resolved(let resolvedPullRequest):
                workspacePullRequestTransientFailureCountByKey[key] = 0
                guard let status = SidebarPullRequestStatus(rawValue: resolvedPullRequest.statusRawValue),
                      let url = URL(string: resolvedPullRequest.urlString) else {
                    continue
                }
                workspace.updatePanelPullRequest(
                    panelId: result.panelId,
                    number: resolvedPullRequest.number,
                    label: "PR",
                    url: url,
                    status: status,
                    branch: resolvedPullRequest.branch,
                    isStale: false
                )
                requestGHPRMetadataRefresh(workspace.id.uuidString)
            case .notFound:
                workspacePullRequestTransientFailureCountByKey[key] = 0
                workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
                if workspace.panelPullRequests[result.panelId] != nil {
                    workspace.clearPanelPullRequest(panelId: result.panelId)
                }
            case .unsupportedRepository:
                workspacePullRequestTransientFailureCountByKey[key] = 0
                workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
                if workspace.panelPullRequests[result.panelId] != nil {
                    workspace.clearPanelPullRequest(panelId: result.panelId)
                }
            case .transientFailure:
                let nextFailureCount = (workspacePullRequestTransientFailureCountByKey[key] ?? 0) + 1
                workspacePullRequestTransientFailureCountByKey[key] = nextFailureCount
                if nextFailureCount >= 3,
                   let currentPullRequest = workspace.panelPullRequests[result.panelId] {
                    workspace.updatePanelPullRequest(
                        panelId: result.panelId,
                        number: currentPullRequest.number,
                        label: currentPullRequest.label,
                        url: currentPullRequest.url,
                        status: currentPullRequest.status,
                        branch: currentPullRequest.branch,
                        isStale: true
                    )
                }
            }

            scheduleNextWorkspacePullRequestPoll(
                key: key,
                workspace: workspace,
                panelId: result.panelId,
                now: now,
                resolution: result.resolution,
                countsAsTerminalSweep: countsAsTerminalSweep
            )
            if rerunPending {
                workspacePullRequestNextPollAtByKey[key] = .distantPast
            }

#if DEBUG
            let label: String = {
                switch result.resolution {
                case .unsupportedRepository:
                    return "unsupported"
                case .notFound:
                    return "none"
                case .transientFailure:
                    return "transientFailure"
                case .resolved(let resolvedPullRequest):
                    return "#\(resolvedPullRequest.number):\(resolvedPullRequest.statusRawValue)"
                }
            }()
            cmuxDebugLog(
                "workspace.prRefresh.apply workspace=\(result.workspaceId.uuidString.prefix(5)) " +
                "panel=\(result.panelId.uuidString.prefix(5)) result=\(label) reason=\(reason)"
            )
#endif
        }

        updateWorkspacePullRequestPollTimer()
    }

    private func scheduleNextWorkspacePullRequestPoll(
        key: WorkspaceGitProbeKey,
        workspace: Workspace,
        panelId: UUID,
        now: Date,
        resolution: WorkspacePullRequestRefreshResult.Resolution,
        countsAsTerminalSweep: Bool
    ) {
        if countsAsTerminalSweep {
            workspacePullRequestLastTerminalStateRefreshAtByKey[key] = now
        }

        if case .resolved(let resolvedPullRequest) = resolution,
           let status = SidebarPullRequestStatus(rawValue: resolvedPullRequest.statusRawValue),
           status != .open {
            workspacePullRequestLastTerminalStateRefreshAtByKey[key] = now
            workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(PullRequestProbeService.terminalStateSweepInterval)
            return
        }

        if case .transientFailure = resolution,
           workspacePullRequestLastTerminalStateRefreshAtByKey[key] != nil {
            workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(PullRequestProbeService.terminalStateSweepInterval)
            return
        }

        if case .unsupportedRepository = resolution {
            workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
            workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(Self.jitteredPollInterval(base: Self.backgroundPollInterval))
            return
        }

        workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
        let baseInterval = isSelectedFocusedPanel(workspace: workspace, panelId: panelId)
            ? Self.selectedPollInterval
            : Self.backgroundPollInterval
        workspacePullRequestNextPollAtByKey[key] = now.addingTimeInterval(Self.jitteredPollInterval(base: baseInterval))
    }

    @discardableResult
    private func flushQueuedWorkspacePullRequestShellRefreshesIfNeeded(
        now: Date = Date()
    ) -> Bool {
        let githubEnhancement = enhancementSystem.github
        if githubEnhancement.queuedRefreshesAreEmpty() {
            return false
        }
        guard SidebarPullRequestShellDebounceSettings.isEnabled() else {
            githubEnhancement.resetQueuedRefreshes()
            return false
        }

        var validKeys = Set(workspacePullRequestNextPollAtByKey.keys)
        validKeys.formUnion(workspacePullRequestProbeStateByKey.keys)
        for workspace in tabs {
            for panelId in Set(workspace.panelGitBranches.keys).union(workspace.panelPullRequests.keys) {
                validKeys.insert(WorkspaceGitProbeKey(workspaceId: workspace.id, panelId: panelId))
            }
        }
        pruneWorkspacePullRequestShellRefreshQueue(validKeys: validKeys)

        let requests = githubEnhancement.flushDueQueuedRefreshes(
            now: now,
            validKeys: Self.enhancementKeys(validKeys),
            ownedWorkspaceIds: Set(tabs.map(\.id))
        ) { [weak self] key in
            self?.workspacePullRequestShellRefreshTarget(for: Self.probeKey(key))
        }
        guard !requests.isEmpty else { return false }
        for request in requests {
            requestWorkspacePullRequestRefresh(
                key: Self.probeKey(request.key),
                reason: request.reason,
                bypassRepoCache: request.bypassRepoCache,
                triggerImmediateRefresh: false
            )
        }
        refreshTrackedWorkspacePullRequestsIfNeeded(
            reason: Self.workspacePullRequestQueuedShellTriggerReason,
            allowCachedResultsOverride: false
        )
        return true
    }

    private func pruneWorkspacePullRequestShellRefreshQueue(validKeys: Set<WorkspaceGitProbeKey>) {
        enhancementSystem.github.pruneQueuedRefreshes(
            validKeys: Self.enhancementKeys(validKeys),
            ownedWorkspaceIds: Set(tabs.map(\.id))
        ) { [weak self] key in
            self?.workspacePullRequestShellRefreshTarget(for: Self.probeKey(key))
        }
    }

    private func pruneWorkspacePullRequestTracking(validKeys: Set<WorkspaceGitProbeKey>) {
        workspacePullRequestNextPollAtByKey = workspacePullRequestNextPollAtByKey.filter { validKeys.contains($0.key) }
        workspacePullRequestProbeStateByKey = workspacePullRequestProbeStateByKey.filter { validKeys.contains($0.key) }
        workspacePullRequestLastTerminalStateRefreshAtByKey = workspacePullRequestLastTerminalStateRefreshAtByKey.filter { validKeys.contains($0.key) }
        workspacePullRequestTransientFailureCountByKey = workspacePullRequestTransientFailureCountByKey.filter { validKeys.contains($0.key) }
        let pruneNow = Date()
        let repoCacheCutoff = pruneNow.addingTimeInterval(-Self.workspacePullRequestRepoCachePruneLifetime)
        workspacePullRequestRepoCacheBySlug = workspacePullRequestRepoCacheBySlug.filter {
            $0.value.fetchedAt >= repoCacheCutoff
        }
        pruneWorkspacePullRequestShellRefreshQueue(validKeys: validKeys)
        updateWorkspacePullRequestPollTimer()
    }

    private func clearWorkspacePullRequestTracking(for key: WorkspaceGitProbeKey) {
        workspacePullRequestNextPollAtByKey.removeValue(forKey: key)
        workspacePullRequestProbeStateByKey.removeValue(forKey: key)
        workspacePullRequestLastTerminalStateRefreshAtByKey.removeValue(forKey: key)
        workspacePullRequestTransientFailureCountByKey.removeValue(forKey: key)
        removeWorkspacePullRequestShellRefreshProbeKey(key)
        updateWorkspacePullRequestPollTimer()
    }

    private func clearWorkspacePullRequestTracking(workspaceId: UUID) {
        workspacePullRequestNextPollAtByKey = workspacePullRequestNextPollAtByKey.filter { $0.key.workspaceId != workspaceId }
        workspacePullRequestProbeStateByKey = workspacePullRequestProbeStateByKey.filter { $0.key.workspaceId != workspaceId }
        workspacePullRequestLastTerminalStateRefreshAtByKey = workspacePullRequestLastTerminalStateRefreshAtByKey.filter { $0.key.workspaceId != workspaceId }
        workspacePullRequestTransientFailureCountByKey = workspacePullRequestTransientFailureCountByKey.filter { $0.key.workspaceId != workspaceId }
        enhancementSystem.github.removeQueuedRefreshes(workspaceId: workspaceId)
        updateWorkspacePullRequestPollTimer()
    }

    private func clearWorkspacePullRequestMetadata(for key: WorkspaceGitProbeKey) {
        clearWorkspacePullRequestTracking(for: key)
        guard let workspace = tabs.first(where: { $0.id == key.workspaceId }) else {
            return
        }
        workspace.clearPanelPullRequest(panelId: key.panelId)
    }

    private func resetWorkspacePullRequestRefreshState() {
        workspacePullRequestRefreshTask?.cancel()
        workspacePullRequestRefreshTask = nil
        workspacePullRequestProbeStateByKey.removeAll()
        workspacePullRequestNextPollAtByKey.removeAll()
        workspacePullRequestLastTerminalStateRefreshAtByKey.removeAll()
        workspacePullRequestTransientFailureCountByKey.removeAll()
        workspacePullRequestRepoCacheBySlug.removeAll()
        let githubEnhancement = enhancementSystem.github
        for workspaceId in Set(tabs.map(\.id)) {
            githubEnhancement.removeQueuedRefreshes(workspaceId: workspaceId)
        }
        workspacePullRequestFollowUpShouldBypassRepoCache = false
        updateWorkspacePullRequestPollTimer()
    }

    private var activeWorkspaceGitProbeKeys: Set<WorkspaceGitProbeKey> {
        Set(workspaceGitProbeStateByKey.compactMap { key, state in
            guard case .inFlight = state else { return nil }
            return key
        })
    }

    private func markWorkspaceGitProbeRerunPending(for key: WorkspaceGitProbeKey) {
        guard case .inFlight(let rerunPending) = workspaceGitProbeStateByKey[key],
              !rerunPending else {
            return
        }
        workspaceGitProbeStateByKey[key] = .inFlight(rerunPending: true)
    }

    private func workspaceGitProbeRerunPending(for key: WorkspaceGitProbeKey) -> Bool {
        guard case .inFlight(let rerunPending) = workspaceGitProbeStateByKey[key] else {
            return false
        }
        return rerunPending
    }

    private func markWorkspacePullRequestProbeRerunPending(
        for key: WorkspaceGitProbeKey,
        bypassRepoCache: Bool
    ) {
        guard case .inFlight(let rerunPending) = workspacePullRequestProbeStateByKey[key],
              !rerunPending else {
            if bypassRepoCache {
                workspacePullRequestFollowUpShouldBypassRepoCache = true
            }
            return
        }
        workspacePullRequestProbeStateByKey[key] = .inFlight(rerunPending: true)
        if bypassRepoCache {
            workspacePullRequestFollowUpShouldBypassRepoCache = true
        }
    }

    private func workspacePullRequestProbeRerunPending(for key: WorkspaceGitProbeKey) -> Bool {
        guard case .inFlight(let rerunPending) = workspacePullRequestProbeStateByKey[key] else {
            return false
        }
        return rerunPending
    }

    private func isSelectedFocusedPanel(workspace: Workspace, panelId: UUID) -> Bool {
        selectedWorkspace?.id == workspace.id && selectedWorkspace?.focusedPanelId == panelId
    }

    private nonisolated static func jitteredPollInterval(base: TimeInterval) -> TimeInterval {
        let jitter = base * Self.workspacePullRequestPollJitterFraction
        return base + Double.random(in: -jitter...jitter)
    }

    nonisolated static func workspacePullRequestRefreshAllowsRepoCache(reason: String) -> Bool {
        let periodicPrefixes = [
            "periodicPoll",
            "selectedPeriodicPoll",
            "timer",
            "shellPrompt",
        ]
        return periodicPrefixes.contains { prefix in
            reason == prefix || reason.hasPrefix("\(prefix).")
        }
    }

    /// User-triggered force refresh of all tracked workspace pull requests.
    /// Bypasses the per-key cooldown and repo-level cache so the next poll
    /// fetches fresh data from GitHub. Triggered by the sidebar refresh button.
    func forceRefreshAllWorkspacePullRequests() {
        for key in workspacePullRequestNextPollAtByKey.keys {
            workspacePullRequestNextPollAtByKey[key] = .distantPast
        }
        workspacePullRequestFollowUpShouldBypassRepoCache = true
        refreshTrackedWorkspacePullRequestsIfNeeded(
            reason: "userForce",
            allowCachedResultsOverride: false
        )
    }

    func refreshTrackedWorkspaceGitMetadataForTesting() {
        sidebarGitMetadataService.refreshTrackedWorkspaceGitMetadata(reason: "test")
    }

    func sidebarGitMetadataWatchSettingsDidChangeForTesting() {
        sidebarMetadataSettingsDidChange()
    }

    func trackedWorkspaceGitMetadataPollCandidatePanelIdsForTesting(workspaceId: UUID) -> Set<UUID> {
        sidebarGitMetadataService.trackedWorkspaceGitMetadataPollCandidatePanelIds(workspaceId: workspaceId)
    }

    func activeWorkspaceGitProbePanelIdsForTesting(workspaceId: UUID) -> Set<UUID> {
        sidebarGitMetadataService.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId)
    }

    @discardableResult
    func queueWorkspacePullRequestShellRefreshIfNeededForTesting(
        workspaceId: UUID,
        panelId: UUID,
        reason: String,
        now: Date
    ) -> Bool {
        queueWorkspacePullRequestShellRefreshIfNeeded(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason,
            now: now
        )
    }

    @discardableResult
    func flushQueuedWorkspacePullRequestShellRefreshesIfNeededForTesting(now: Date) -> Bool {
        flushQueuedWorkspacePullRequestShellRefreshesIfNeeded(now: now)
    }

    func scheduleWorkspacePullRequestRefreshForTesting(
        workspaceId: UUID,
        panelId: UUID,
        reason: String
    ) {
        scheduleWorkspacePullRequestRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason
        )
    }

    func workspacePullRequestShellRefreshQueueTargetsForTesting() -> [WorkspacePullRequestShellRefreshTarget] {
        enhancementSystem.github.queuedRefreshTargets()
    }

    func workspacePullRequestShellRefreshQueueSnapshotForTesting() -> [(target: WorkspacePullRequestShellRefreshTarget, fireAt: Date, probeKeyCount: Int)] {
        enhancementSystem.github.queuedRefreshSnapshot()
    }

    func workspacePullRequestNextPollAtForTesting(
        workspaceId: UUID,
        panelId: UUID
    ) -> Date? {
        workspacePullRequestNextPollAtByKey[
            WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        ]
    }

    func workspacePullRequestTrackedPanelIdsForTesting(workspaceId: UUID) -> Set<UUID> {
        pullRequestProbing.workspacePullRequestTrackedPanelIds(workspaceId: workspaceId)
    }


    private func sweepStaleAgentPIDs() {
        for tab in tabs {
            var keysToRemove: [String] = []
            for (key, pid) in tab.agentPIDs {
                guard pid > 0 else {
                    keysToRemove.append(key)
                    continue
                }
                // kill(pid, 0) probes process liveness without sending a signal.
                // ESRCH = process doesn't exist (stale). EPERM = process exists
                // but we lack permission (not stale, keep tracking).
                errno = 0
                if kill(pid, 0) == -1, POSIXErrorCode(rawValue: errno) == .ESRCH {
                    keysToRemove.append(key)
                }
            }
            if !keysToRemove.isEmpty {
                for key in keysToRemove {
                    tab.clearAgentPID(key: key, clearStatus: true, refreshPorts: false)
                }
                let remainingAgentPIDs = Set(tab.agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
                PortScanner.shared.refreshAgentPorts(workspaceId: tab.id, agentPIDs: remainingAgentPIDs)
                // Also clear stale notifications (e.g. "Doing well, thanks!")
                // left behind when Claude was killed without SessionEnd firing.
                AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id)
            }
        }
    }

    func gitProbeDirectory(for workspace: Workspace, panelId: UUID) -> String? {
        // Match the sidebar directory fallback chain so hidden/background panels can
        // still probe git metadata before OSC 7 has reported a live cwd.
        let rawDirectory = workspace.panelDirectories[panelId]
            ?? workspace.terminalPanel(for: panelId)?.requestedWorkingDirectory
            ?? (workspace.focusedPanelId == panelId ? workspace.currentDirectory : nil)
        return rawDirectory.flatMap(normalizedWorkingDirectory)
    }

    func scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
        workspaceId: UUID,
        panelId: UUID,
        reason: String = "initial"
    ) {
#if DEBUG
        didScheduleInitialWorkspaceGitMetadataRefreshForTesting(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason
        )
#endif
        sidebarGitMetadataService.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason
        )
    }

    private func scheduleWorkspaceGitMetadataRefreshIfPossible(
        workspaceId: UUID,
        panelId: UUID,
        reason: String,
        delays: [TimeInterval] = [0]
    ) {
        if Self.shouldPreserveUITestFixtureMetadata() {
            return
        }
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        guard sidebarGitMetadataWatchEnabled else {
            clearWorkspaceGitMetadata(for: key)
            return
        }
        guard let workspace = tabs.first(where: { $0.id == workspaceId }),
              workspace.panels[panelId] != nil,
              let directory = gitProbeDirectory(for: workspace, panelId: panelId) else {
            return
        }

        scheduleWorkspaceGitMetadataRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            delays: delays,
            reason: reason
        )
    }

    private static func shouldPreserveUITestFixtureMetadata(
        mode: CmuxRuntimeMode = CmuxRuntimeMode.current()
    ) -> Bool {
        mode.isUITest && mode.fixtureName != nil
    }

    func wireClosedBrowserTracking(for workspace: Workspace) {
        workspace.onClosedBrowserPanel = { [weak self] snapshot in
            self?.browserModel.recordClosedBrowserPanel(snapshot)
        }
    }

    private func unwireClosedBrowserTracking(for workspace: Workspace) {
        workspace.onClosedBrowserPanel = nil
    }

    var selectedWorkspace: Workspace? {
        guard let selectedTabId else { return nil }
        return tabs.first(where: { $0.id == selectedTabId })
    }

    // Keep selectedTab as convenience alias
    var selectedTab: Workspace? { selectedWorkspace }

    // MARK: - Surface/Panel Compatibility Layer

    /// Returns the focused terminal surface for the selected workspace
    var selectedSurface: TerminalSurface? {
        selectedWorkspace?.focusedTerminalPanel?.surface
    }

    /// Returns the focused panel's terminal panel (if it is a terminal)
    var selectedTerminalPanel: TerminalPanel? {
        selectedWorkspace?.focusedTerminalPanel
    }

    private var selectedWorkspaceTerminalPanels: [TerminalPanel] {
        selectedWorkspace?.panels.values.compactMap { $0 as? TerminalPanel } ?? []
    }

    var isFindVisible: Bool {
        selectedTerminalPanel?.searchState != nil || focusedBrowserPanel?.searchState != nil
    }

    var canUseSelectionForFind: Bool {
        selectedTerminalPanel?.hasSelection() == true
    }

    @discardableResult
    func startSearch() -> Bool {
        if let panel = selectedTerminalPanel {
            let hadExistingSearch = panel.searchState != nil
            panel.hostedView.preparePanelFocusIntentForActivation(.findField)
            let recoveredNeedle = hadExistingSearch ? "" : panel.surface.lastSearchNeedle
            let handled = startOrFocusTerminalSearch(panel.surface, initialNeedle: recoveredNeedle) { surface in
                NotificationCenter.default.post(
                    name: .ghosttySearchFocus,
                    object: surface,
                    userInfo: [FindFocusNotificationKey.selectAll: !hadExistingSearch && !recoveredNeedle.isEmpty]
                )
            }
#if DEBUG
            cmuxDebugLog(
                "find.startSearch workspace=\(panel.workspaceId.uuidString.prefix(5)) " +
                "panel=\(panel.id.uuidString.prefix(5)) existing=\(hadExistingSearch ? "yes" : "no") " +
                "handled=\(handled ? 1 : 0) " +
                "firstResponder=\(String(describing: panel.surface.uiWindow?.firstResponder))"
            )
#endif
            return handled
        }
        guard let browserPanel = focusedBrowserPanel else { return false }
        browserPanel.startFind()
        return browserPanel.searchState != nil
    }

    func searchSelection() {
        guard let panel = selectedTerminalPanel else { return }
        if panel.searchState == nil {
            panel.searchState = TerminalSurface.SearchState()
        }
#if DEBUG
        cmuxDebugLog(
            "find.searchSelection workspace=\(panel.workspaceId.uuidString.prefix(5)) " +
            "panel=\(panel.id.uuidString.prefix(5))"
        )
#endif
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: panel.surface)
        _ = panel.performBindingAction("search_selection")
    }

    func findNext() {
        if let panel = selectedTerminalPanel {
            _ = panel.performBindingAction("search:next")
            return
        }

        focusedBrowserPanel?.findNext()
    }

    func findPrevious() {
        if let panel = selectedTerminalPanel {
            _ = panel.performBindingAction("search:previous")
            return
        }

        focusedBrowserPanel?.findPrevious()
    }

    @discardableResult
    func toggleFocusedTerminalCopyMode() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.surface.toggleKeyboardCopyMode()
    }

    /// Forwards a single Ctrl-F (`^F`) key press to the focused terminal surface,
    /// faithfully encoded through Ghostty so it matches whatever the running TUI
    /// would receive from a real keystroke.
    ///
    /// This is the non-keyboard escape hatch for control chords that a focused TUI
    /// reads off the raw tty. The motivating case is Claude Code's force-stop, which
    /// is only exposed as "press Ctrl-F twice"; invoke this action twice to deliver
    /// it. Delivery bypasses cmux's shortcut/menu/responder layers entirely.
    ///
    /// - Returns: `true` when the chord was sent or queued for the focused terminal,
    ///   `false` when no terminal panel is focused.
    @discardableResult
    func sendCtrlFToFocusedTerminal() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        let result = panel.sendNamedKeyResult("ctrl-f")
        if result == .sent {
            panel.surface.forceRefresh(reason: "tabManager.sendCtrlFToFocusedTerminal")
        }
#if DEBUG
        cmuxDebugLog(
            "terminal.sendCtrlF workspace=\(panel.workspaceId.uuidString.prefix(5)) " +
            "panel=\(panel.id.uuidString.prefix(5)) result=\(result)"
        )
#endif
        return result.accepted
    }

    @discardableResult
    func toggleFocusedTerminalTextBox() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.toggleTextBoxInput()
    }

    /// Clears the focused terminal's visible screen while preserving scrollback.
    ///
    /// See `TerminalSurface.clearScreenKeepingScrollback()`. The shared model path
    /// behind the Cmd+Shift+K shortcut and the "Clear Screen (Keep Scrollback)"
    /// command palette entry.
    ///
    /// - Returns: `true` when a focused terminal performed the clear, `false` when
    ///   no terminal panel is focused.
    @discardableResult
    func clearFocusedTerminalKeepingScrollback() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        let cleared = panel.clearScreenKeepingScrollback()
        if cleared {
            panel.surface.forceRefresh(reason: "tabManager.clearFocusedTerminalKeepingScrollback")
        }
        return cleared
    }

    @discardableResult
    func focusFocusedTerminalTextBoxInputOrTerminal() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.focusTextBoxInputOrTerminal()
    }

    @discardableResult
    func attachFileToFocusedTerminalTextBoxInput() -> Bool {
        guard let panel = selectedTerminalPanel else { return false }
        return panel.attachFileToTextBoxInput()
    }

    @discardableResult
    func consumeFocusedTerminalTextBoxHideEscapeIfArmed(in window: NSWindow?) -> Bool {
        guard let focusedPanel = selectedTerminalPanel else {
            clearFocusedTerminalTextBoxHideEscapeArm()
            return false
        }
        let consumed = focusedPanel.consumeTextBoxHideEscapeIfArmed(in: window)
        guard !consumed else { return true }
        for panel in selectedWorkspaceTerminalPanels {
            if panel === focusedPanel { continue }
            panel.clearTextBoxHideEscapeArm()
        }
        return false
    }

    func clearFocusedTerminalTextBoxHideEscapeArm() {
        for panel in selectedWorkspaceTerminalPanels {
            panel.clearTextBoxHideEscapeArm()
        }
    }

    func hideFind() {
        if let panel = selectedTerminalPanel {
            panel.searchState = nil
            return
        }

        focusedBrowserPanel?.hideFind()
    }

    func makeWorkspaceForCreation(
        title: String,
        workingDirectory: String?,
        portOrdinal: Int,
        configTemplate: CmuxSurfaceConfigTemplate?,
        initialSurface: NewWorkspaceInitialSurface = .terminal,
        initialTerminalCommand: String?,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String],
        workspaceEnvironment: [String: String] = [:]
    ) -> Workspace {
        Workspace(
            title: title,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            configTemplate: configTemplate,
            initialSurface: initialSurface,
            initialTerminalCommand: initialTerminalCommand,
            initialTerminalInput: initialTerminalInput,
            initialTerminalEnvironment: initialTerminalEnvironment,
            workspaceEnvironment: workspaceEnvironment
        )
    }

    func applyCreationChromeInheritance(
        to newWorkspace: Workspace,
        from sourceWorkspace: Workspace?
    ) {
        // Sidebar-toggle relayout updates the live Bonsplit leading inset so minimal-mode
        // workspaces reserve traffic-light space. New workspaces need that same inset
        // copied immediately because creation itself does not trigger the resync path.
        let inheritedLeadingInset = currentWindowTabBarLeadingInset
            ?? sourceWorkspace?.bonsplitController.configuration.appearance.tabBarLeadingInset
        guard let inheritedLeadingInset else { return }
        applyTabBarLeadingInset(inheritedLeadingInset, to: newWorkspace)
    }

    func syncWorkspaceTabBarLeadingInset(_ inset: CGFloat) {
        let normalizedInset = max(0, inset)
        currentWindowTabBarLeadingInset = normalizedInset
        for tab in tabs {
            applyTabBarLeadingInset(normalizedInset, to: tab)
        }
    }

    private func applyTabBarLeadingInset(_ inset: CGFloat, to workspace: Workspace) {
        if workspace.bonsplitController.configuration.appearance.tabBarLeadingInset != inset {
            workspace.bonsplitController.configuration.appearance.tabBarLeadingInset = inset
        }
    }

    /// Test seam for mutating live workspace state after the creation snapshot is captured.
    func didCaptureWorkspaceCreationSnapshot() {}

#if DEBUG
    /// Test seam: invoked when an initial workspace git-metadata refresh is
    /// scheduled, so tests can observe scheduling without the network probe.
    func didScheduleInitialWorkspaceGitMetadataRefreshForTesting(
        workspaceId: UUID,
        panelId: UUID,
        reason: String
    ) {}
#endif

#if DEBUG
    func maybeMutateSelectionDuringWorkspaceCreationForDev(
        snapshot: WorkspaceCreationSnapshot
    ) {
        let env = ProcessInfo.processInfo.environment
        let isEnabled: Bool = {
            if let raw = env["CMUX_DEV_MUTATE_WORKSPACE_SELECTION_DURING_CREATION"] {
                return raw == "1" || raw.caseInsensitiveCompare("true") == .orderedSame
            }
            return UserDefaults.standard.bool(forKey: "cmuxDevMutateWorkspaceSelectionDuringCreation")
        }()
        guard isEnabled,
              let selectedTabId = snapshot.selectedTabId,
              let targetId = snapshot.tabs.lazy.map(\.id).first(where: { $0 != selectedTabId }),
              tabs.contains(where: { $0.id == targetId }) else {
            return
        }
        cmuxDebugLog(
            "workspace.create.devSelectionMutation from=\(selectedTabId.uuidString.prefix(5)) " +
            "to=\(targetId.uuidString.prefix(5))"
        )
        self.selectedTabId = targetId
    }
#endif

    @discardableResult
    func addWorkspace(
        title: String? = nil,
        workingDirectory overrideWorkingDirectory: String? = nil,
        initialSurface: NewWorkspaceInitialSurface = .terminal,
        initialTerminalCommand: String? = nil,
        initialTerminalInput: String? = nil,
        initialTerminalEnvironment: [String: String] = [:],
        workspaceEnvironment: [String: String] = [:],
        inheritWorkingDirectory: Bool = true,
        select: Bool = true,
        eagerLoadTerminal: Bool = false,
        placementOverride: WorkspacePlacement? = nil,
        autoWelcomeIfNeeded: Bool = true,
        autoRefreshMetadata: Bool = true,
        normalizeWorkspaceGroupsAfterInsert: Bool = true
    ) -> Workspace {
        let sourceWorkspace = selectedWorkspace
        let capturedTabs = tabs
        // Snapshot the selected tab from the pinned workspace instead of rereading the
        // @Published selectedTabId storage after the inheritance helpers. The arm64 Nightly
        // Cmd+N crash is in PublishedSubject.value.getter on that second getter read.
        let capturedSelectedTabId = sourceWorkspace?.id
        // Keep both the source workspace and the pre-creation workspace array alive for the
        // entire creation path. Release ARC can otherwise drop retains early across the
        // helper/insertion chain, which reintroduces use-after-free crashes in optimized builds.
        return withExtendedLifetime((capturedTabs, sourceWorkspace)) {
            let dir = inheritWorkingDirectory
                ? implicitWorkingDirectoryForNewWorkspace(from: sourceWorkspace)
                : nil
            let font = inheritedTerminalFontPointsForNewWorkspace(workspace: sourceWorkspace)
            let snapshot = workspaceCreationSnapshotLite(
                currentTabs: capturedTabs,
                currentSelectedTabId: capturedSelectedTabId,
                preferredWorkingDirectory: dir,
                inheritedTerminalFontPoints: font
            )
            didCaptureWorkspaceCreationSnapshot()
#if DEBUG
            maybeMutateSelectionDuringWorkspaceCreationForDev(snapshot: snapshot)
#endif
            let nextTabCount = snapshot.tabs.count + 1
            sentryBreadcrumb("workspace.create", data: ["tabCount": nextTabCount])
            let explicitWorkingDirectory = normalizedWorkingDirectory(overrideWorkingDirectory)
            let workingDirectory = explicitWorkingDirectory ?? snapshot.preferredWorkingDirectory
            let inheritedConfig = workspaceCreationConfigTemplate(
                inheritedTerminalFontPoints: snapshot.inheritedTerminalFontPoints
            )
            // Resolve placement against the pre-creation snapshot before Workspace init
            // boots terminal state. The ssh/new-workspace path can otherwise crash while
            // reading @Published placement state from existing workspaces mid-creation.
            let insertIndex = newTabInsertIndex(snapshot: snapshot, placementOverride: placementOverride)
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let defaultTitle: String
            switch initialSurface {
            case .terminal:
                defaultTitle = "Terminal \(nextTabCount)"
            case .browser:
                // Match the browser surface's blank new-tab title; the
                // single-panel title sync keeps the workspace title following
                // the page title once the user navigates.
                defaultTitle = String(localized: "browser.newTab", defaultValue: "New tab")
            }
            let newWorkspace = makeWorkspaceForCreation(
                title: title ?? defaultTitle,
                workingDirectory: workingDirectory,
                portOrdinal: ordinal,
                configTemplate: inheritedConfig,
                initialSurface: initialSurface,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalInput: initialTerminalInput,
                initialTerminalEnvironment: initialTerminalEnvironment,
                workspaceEnvironment: workspaceEnvironment
            )
            applyCreationChromeInheritance(
                to: newWorkspace,
                from: sourceWorkspace ?? capturedTabs.first
            )
            newWorkspace.owningTabManager = self
            if title != nil {
                newWorkspace.setCustomTitle(title)
            }
            wireClosedBrowserTracking(for: newWorkspace)
            if eagerLoadTerminal && !select {
                requestBackgroundWorkspaceLoad(for: newWorkspace.id)
            }
            // Apply insertion to the current live array so post-snapshot closes/reorders
            // are preserved instead of reintroducing stale workspace instances.
            var updatedTabs = tabs
            if insertIndex >= 0 && insertIndex <= updatedTabs.count {
                updatedTabs.insert(newWorkspace, at: insertIndex)
            } else {
                updatedTabs.append(newWorkspace)
            }
            tabs = updatedTabs
            // The global insertion-index rules don't know about group sections.
            // Re-run the group-aware normalize so a freshly-added workspace
            // can't land inside another group's contiguous section.
            if normalizeWorkspaceGroupsAfterInsert, !workspaceGroups.isEmpty {
                workspaces.normalizeWorkspaceGroupContiguity()
            }
            if autoRefreshMetadata, let terminalPanel = newWorkspace.focusedTerminalPanel {
                scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: newWorkspace.id,
                    panelId: terminalPanel.id
                )
            }
            if eagerLoadTerminal {
                if select {
                    newWorkspace.focusedTerminalPanel?.surface.requestBackgroundSurfaceStartIfNeeded()
                }
            }
            publishCmuxWorkspaceCreated(newWorkspace, selected: select)
            publishCmuxInitialSurfaceCreated(newWorkspace, selected: select)
            if select {
#if DEBUG
                debugPrimeWorkspaceSwitchTrigger("create", to: newWorkspace.id)
#endif
                selectedTabId = newWorkspace.id
                NotificationCenter.default.post(
                    name: .ghosttyDidFocusTab,
                    object: nil,
                    userInfo: [GhosttyNotificationKey.tabId: newWorkspace.id]
                )
            }
#if DEBUG
            UITestRecorder.incrementInt("addTabInvocations")
            UITestRecorder.record([
                "tabCount": String(updatedTabs.count),
                "selectedTabId": select ? newWorkspace.id.uuidString : (snapshot.selectedTabId?.uuidString ?? "")
            ])
#endif
            if autoWelcomeIfNeeded && select && initialSurface == .terminal
                && !UserDefaults.standard.bool(forKey: AccountCatalogSection().welcomeShown.userDefaultsKey) {
                if let appDelegate = AppDelegate.shared {
                    appDelegate.sendWelcomeCommandWhenReady(to: newWorkspace, markShownOnSend: true)
                } else {
                    sendWelcomeWhenReady(to: newWorkspace)
                }
            }
            return newWorkspace
        }
    }

    @MainActor
    private func sendWelcomeWhenReady(to workspace: Workspace) {
        if let terminalPanel = workspace.focusedTerminalPanel,
           terminalPanel.surface.surface != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UserDefaults.standard.set(true, forKey: AccountCatalogSection().welcomeShown.userDefaultsKey)
                terminalPanel.sendText("cmux welcome\n")
            }
            return
        }

        var resolved = false
        var readyObserver: NSObjectProtocol?
        var panelsCancellable: AnyCancellable?

        func finishIfReady() {
            guard !resolved,
                  let terminalPanel = workspace.focusedTerminalPanel,
                  terminalPanel.surface.surface != nil else { return }
            resolved = true
            if let readyObserver {
                NotificationCenter.default.removeObserver(readyObserver)
            }
            panelsCancellable?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UserDefaults.standard.set(true, forKey: AccountCatalogSection().welcomeShown.userDefaultsKey)
                terminalPanel.sendText("cmux welcome\n")
            }
        }

        panelsCancellable = workspace.panelsPublisher
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in
                    finishIfReady()
                }
            }
        readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                  workspaceId == workspace.id else { return }
            Task { @MainActor in
                finishIfReady()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            Task { @MainActor in
                if let readyObserver, !resolved {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if !resolved {
                    panelsCancellable?.cancel()
                }
            }
        }
    }

    private func scheduleInitialWorkspaceGitMetadataRefresh(
        workspaceId: UUID,
        panelId: UUID,
        directory: String
    ) {
        scheduleWorkspaceGitMetadataRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            delays: Self.initialWorkspaceGitProbeDelays,
            reason: "initial"
        )
    }

    private func scheduleWorkspaceGitMetadataRefresh(
        workspaceId: UUID,
        panelId: UUID,
        directory: String,
        delays: [TimeInterval],
        reason: String
    ) {
        let normalizedDirectory = normalizeDirectory(directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        cancelWorkspaceGitProbeTask(for: key)
        if workspaceGitProbeStateByKey[key] == nil {
            workspaceGitProbeStateByKey[key] = .idle
        }

#if DEBUG
        cmuxDebugLog(
            "workspace.gitProbe.schedule workspace=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) dir=\(normalizedDirectory) reason=\(reason)"
        )
#endif

        let clock = gitPollClock
        workspaceGitProbeTasksByKey[key] = Task { @MainActor [weak self] in
            // The retry delays are absolute offsets from scheduling time; walk
            // them as sequential gaps on the injected clock (bounded,
            // cancellable; cancellation replaces the old timer cancels).
            var previousDelay: TimeInterval = 0
            for (index, delay) in delays.enumerated() {
                let isLastAttempt = index == delays.count - 1
                do {
                    try await clock.sleep(for: .seconds(delay - previousDelay))
                } catch {
                    return
                }
                previousDelay = delay
                guard let self, !Task.isCancelled else { return }
                self.beginWorkspaceGitMetadataProbeAttempt(
                    probeKey: key,
                    expectedDirectory: normalizedDirectory,
                    isLastAttempt: isLastAttempt
                )
            }
        }
    }

    private func beginWorkspaceGitMetadataProbeAttempt(
        probeKey: WorkspaceGitProbeKey,
        expectedDirectory: String,
        isLastAttempt: Bool
    ) {
        guard !MobileHostRequestActivity.hasRecentActivity(within: Self.mobileHostBackgroundWorkQuietInterval) else {
            workspaceGitProbeStateByKey[probeKey] = .idle
            scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: probeKey.workspaceId,
                panelId: probeKey.panelId,
                reason: "mobileHostDeferred",
                delays: [max(
                    Self.mobileHostBackgroundWorkDeferralInterval,
                    MobileHostRequestActivity.quietDelay(for: Self.mobileHostBackgroundWorkQuietInterval)
                )]
            )
            return
        }

        switch workspaceGitProbeStateByKey[probeKey] ?? .idle {
        case .idle:
            workspaceGitProbeStateByKey[probeKey] = .inFlight(rerunPending: false)
        case .inFlight:
            markWorkspaceGitProbeRerunPending(for: probeKey)
            return
        }

        enqueueWorkspaceGitMetadataSnapshotRequest(
            probeKey: probeKey,
            expectedDirectory: expectedDirectory,
            isLastAttempt: isLastAttempt
        )
    }

    private func enqueueWorkspaceGitMetadataSnapshotRequest(
        probeKey: WorkspaceGitProbeKey,
        expectedDirectory: String,
        isLastAttempt: Bool
    ) {
        let request = WorkspaceGitSnapshotProbeRequest(
            probeKey: probeKey,
            isLastAttempt: isLastAttempt
        )
        if let currentDirectory = workspaceGitSnapshotDirectoryByProbeKey[probeKey],
           currentDirectory != expectedDirectory {
            removeWorkspaceGitSnapshotRequest(for: probeKey)
        }
        workspaceGitSnapshotDirectoryByProbeKey[probeKey] = expectedDirectory
        if var requests = workspaceGitSnapshotRequestsByDirectory[expectedDirectory],
           let existingRequestIndex = requests.firstIndex(where: { $0.probeKey == probeKey }) {
            requests[existingRequestIndex] = request
            workspaceGitSnapshotRequestsByDirectory[expectedDirectory] = requests
        } else {
            workspaceGitSnapshotRequestsByDirectory[expectedDirectory, default: []].append(request)
        }
        guard workspaceGitSnapshotTasksByDirectory[expectedDirectory] == nil else {
#if DEBUG
            cmuxDebugLog(
                "workspace.gitProbe.joinSnapshot dir=\(expectedDirectory) " +
                "queued=\(workspaceGitSnapshotRequestsByDirectory[expectedDirectory]?.count ?? 0)"
            )
#endif
            return
        }

        let reader = workspaceGitMetadataReader
        workspaceGitSnapshotTasksByDirectory[expectedDirectory] = Task.detached(priority: .utility) { [weak self] in
            let didAcquirePermit = await WorkspaceGitMetadataProbeLimiter.shared.acquire()
            guard didAcquirePermit else { return }
            defer {
                Task {
                    await WorkspaceGitMetadataProbeLimiter.shared.release()
                }
            }

            guard !Task.isCancelled else { return }
            let snapshot = await Self.initialWorkspaceGitMetadataSnapshot(
                for: expectedDirectory,
                reader: reader
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }
                self?.applyWorkspaceGitMetadataSnapshotBatch(
                    snapshot,
                    expectedDirectory: expectedDirectory
                )
            }
        }
    }

    private func applyWorkspaceGitMetadataSnapshotBatch(
        _ snapshot: InitialWorkspaceGitMetadataSnapshot,
        expectedDirectory: String
    ) {
        workspaceGitSnapshotTasksByDirectory.removeValue(forKey: expectedDirectory)
        let requests = workspaceGitSnapshotRequestsByDirectory.removeValue(forKey: expectedDirectory) ?? []
        for request in requests {
            workspaceGitSnapshotDirectoryByProbeKey.removeValue(forKey: request.probeKey)
            applyWorkspaceGitMetadataSnapshot(
                snapshot,
                probeKey: request.probeKey,
                expectedDirectory: expectedDirectory,
                isLastAttempt: request.isLastAttempt
            )
        }
    }

    private func removeWorkspaceGitSnapshotRequest(for key: WorkspaceGitProbeKey) {
        guard let directory = workspaceGitSnapshotDirectoryByProbeKey.removeValue(forKey: key),
              var requests = workspaceGitSnapshotRequestsByDirectory[directory] else {
            return
        }
        requests.removeAll { $0.probeKey == key }
        if requests.isEmpty {
            workspaceGitSnapshotRequestsByDirectory.removeValue(forKey: directory)
            workspaceGitSnapshotTasksByDirectory.removeValue(forKey: directory)?.cancel()
        } else {
            workspaceGitSnapshotRequestsByDirectory[directory] = requests
        }
    }

    private func cancelAllWorkspaceGitSnapshotTasks() {
        for task in workspaceGitSnapshotTasksByDirectory.values {
            task.cancel()
        }
        workspaceGitSnapshotTasksByDirectory.removeAll()
        workspaceGitSnapshotRequestsByDirectory.removeAll()
        workspaceGitSnapshotDirectoryByProbeKey.removeAll()
    }

    private func cancelWorkspaceGitProbeTask(for key: WorkspaceGitProbeKey) {
        workspaceGitProbeTasksByKey.removeValue(forKey: key)?.cancel()
    }

    private func clearWorkspaceGitProbe(_ key: WorkspaceGitProbeKey) {
        removeWorkspaceGitSnapshotRequest(for: key)
        workspaceGitProbeStateByKey.removeValue(forKey: key)
        workspaceGitCleanIndexSignatureByKey.removeValue(forKey: key)
        workspaceGitCleanIndexContentSignatureByKey.removeValue(forKey: key)
        workspaceGitHeadSignatureByKey.removeValue(forKey: key)
        cancelWorkspaceGitProbeTask(for: key)
        stopWorkspaceGitMetadataWatcher(for: key)
        updateWorkspaceGitMetadataFallbackTimer()
    }

    private func finishWorkspaceGitProbeAttempt(_ key: WorkspaceGitProbeKey) {
        workspaceGitProbeStateByKey.removeValue(forKey: key)
        cancelWorkspaceGitProbeTask(for: key)
    }

    private func clearWorkspaceGitMetadata(for key: WorkspaceGitProbeKey) {
        clearWorkspaceGitProbe(key)
        workspaceGitTrackedDirectoryByKey.removeValue(forKey: key)
        updateWorkspaceGitMetadataFallbackTimer()
        clearWorkspacePullRequestTracking(for: key)
        guard let workspace = tabs.first(where: { $0.id == key.workspaceId }) else {
            return
        }
        workspace.clearPanelGitBranch(panelId: key.panelId)
        workspace.clearPanelPullRequest(panelId: key.panelId)
    }

    private func clearAllWorkspaceSidebarGitMetadata() {
        for workspace in tabs {
            workspace.clearSidebarGitMetadata()
        }
    }

    private func clearAllWorkspaceSidebarPullRequestMetadata() {
        for workspace in tabs {
            workspace.clearSidebarPullRequestMetadata()
        }
    }

    private func clearWorkspaceGitProbes(workspaceId: UUID) {
        let keys = Set(workspaceGitProbeStateByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitProbeTasksByKey.keys.filter { $0.workspaceId == workspaceId })
        for key in keys {
            clearWorkspaceGitProbe(key)
        }
        workspaceGitTrackedDirectoryByKey = workspaceGitTrackedDirectoryByKey.filter { key, _ in
            key.workspaceId != workspaceId
        }
        workspaceGitCleanIndexSignatureByKey = workspaceGitCleanIndexSignatureByKey.filter { key, _ in
            key.workspaceId != workspaceId
        }
        workspaceGitCleanIndexContentSignatureByKey = workspaceGitCleanIndexContentSignatureByKey.filter { key, _ in
            key.workspaceId != workspaceId
        }
        workspaceGitHeadSignatureByKey = workspaceGitHeadSignatureByKey.filter { key, _ in
            key.workspaceId != workspaceId
        }
        stopWorkspaceGitMetadataWatchers(workspaceId: workspaceId)
        updateWorkspaceGitMetadataFallbackTimer()
        clearWorkspacePullRequestTracking(workspaceId: workspaceId)
    }

    private func applyWorkspaceGitMetadataSnapshot(
        _ snapshot: InitialWorkspaceGitMetadataSnapshot,
        probeKey: WorkspaceGitProbeKey,
        expectedDirectory: String,
        isLastAttempt: Bool
    ) {
        let wasInFlight: Bool = {
            if case .inFlight = workspaceGitProbeStateByKey[probeKey] { return true }
            return false
        }()
        guard !MobileHostRequestActivity.hasRecentActivity(within: Self.mobileHostBackgroundWorkQuietInterval) else {
            workspaceGitProbeStateByKey[probeKey] = .idle
            scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: probeKey.workspaceId,
                panelId: probeKey.panelId,
                reason: "mobileHostDeferred",
                delays: [max(
                    Self.mobileHostBackgroundWorkDeferralInterval,
                    MobileHostRequestActivity.quietDelay(for: Self.mobileHostBackgroundWorkQuietInterval)
                )]
            )
            return
        }
        let shouldTrackPullRequests = sidebarPullRequestPollingEnabled
        let resolvedPullRequest: SidebarPullRequestState? = {
            guard shouldTrackPullRequests else { return nil }
            guard case .resolved(let pullRequest) = snapshot.pullRequest else { return nil }
            return pullRequest
        }()
        let shouldTrackGitDirectory = snapshot.isRepository || resolvedPullRequest != nil
        let shouldFinishProbe = shouldStopWorkspaceGitMetadataRefresh(snapshot) || isLastAttempt
        let shouldStopTrackingGitDirectory = shouldFinishProbe && !shouldTrackGitDirectory
        var didClearProbe = false
        defer {
            if wasInFlight, !didClearProbe {
                let rerunPending = workspaceGitProbeRerunPending(for: probeKey)
                if rerunPending {
                    workspaceGitProbeStateByKey[probeKey] = .idle
                    if shouldFinishProbe {
                        cancelWorkspaceGitProbeTask(for: probeKey)
                    }
                    scheduleWorkspaceGitMetadataRefreshIfPossible(
                        workspaceId: probeKey.workspaceId,
                        panelId: probeKey.panelId,
                        reason: "rerunPending"
                    )
                } else if shouldStopTrackingGitDirectory {
                    clearWorkspaceGitProbe(probeKey)
                } else if shouldFinishProbe {
                    finishWorkspaceGitProbeAttempt(probeKey)
                } else {
                    workspaceGitProbeStateByKey[probeKey] = .idle
                }
            }
        }

        guard wasInFlight else { return }
        guard let workspace = tabs.first(where: { $0.id == probeKey.workspaceId }) else {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
            return
        }
        guard workspace.panels[probeKey.panelId] != nil else {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
            return
        }

        guard let currentDirectory = gitProbeDirectory(for: workspace, panelId: probeKey.panelId) else {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
            return
        }
        if currentDirectory != expectedDirectory {
            clearWorkspaceGitProbe(probeKey)
            didClearProbe = true
#if DEBUG
            cmuxDebugLog(
                "workspace.gitProbe.skip workspace=\(probeKey.workspaceId.uuidString.prefix(5)) " +
                "panel=\(probeKey.panelId.uuidString.prefix(5)) reason=directoryChanged " +
                "expected=\(expectedDirectory) current=\(currentDirectory)"
            )
#endif
            return
        }

        workspace.updatePanelDirectory(panelId: probeKey.panelId, directory: expectedDirectory)

        if shouldTrackGitDirectory {
            workspaceGitTrackedDirectoryByKey[probeKey] = expectedDirectory
            updateWorkspaceGitMetadataWatcher(for: probeKey, directory: expectedDirectory)
        } else {
            workspaceGitTrackedDirectoryByKey.removeValue(forKey: probeKey)
            stopWorkspaceGitMetadataWatcher(for: probeKey)
        }
        updateWorkspaceGitMetadataFallbackTimer()

        let nextBranch = snapshot.branch
        if let nextBranch {
            if let headSignature = snapshot.headSignature {
                if let previousHeadSignature = workspaceGitHeadSignatureByKey[probeKey],
                   previousHeadSignature != headSignature {
                    workspaceGitCleanIndexSignatureByKey.removeValue(forKey: probeKey)
                    workspaceGitCleanIndexContentSignatureByKey.removeValue(forKey: probeKey)
                }
                workspaceGitHeadSignatureByKey[probeKey] = headSignature
            } else {
                workspaceGitHeadSignatureByKey.removeValue(forKey: probeKey)
            }
            var isDirty = snapshot.isDirty
            if !isDirty,
               let indexSignature = snapshot.indexSignature,
               let cleanIndexSignature = workspaceGitCleanIndexSignatureByKey[probeKey],
               cleanIndexSignature != indexSignature {
                if let indexContentSignature = snapshot.indexContentSignature,
                   let cleanIndexContentSignature = workspaceGitCleanIndexContentSignatureByKey[probeKey],
                   cleanIndexContentSignature == indexContentSignature {
                    workspaceGitCleanIndexSignatureByKey[probeKey] = indexSignature
                } else {
                    isDirty = true
                }
            }
            workspace.updatePanelGitBranch(
                panelId: probeKey.panelId,
                branch: nextBranch,
                isDirty: isDirty
            )
            if !isDirty {
                if let indexSignature = snapshot.indexSignature {
                    workspaceGitCleanIndexSignatureByKey[probeKey] = indexSignature
                } else {
                    workspaceGitCleanIndexSignatureByKey.removeValue(forKey: probeKey)
                }
                if let indexContentSignature = snapshot.indexContentSignature {
                    workspaceGitCleanIndexContentSignatureByKey[probeKey] = indexContentSignature
                } else {
                    workspaceGitCleanIndexContentSignatureByKey.removeValue(forKey: probeKey)
                }
            }
        } else {
            workspaceGitCleanIndexSignatureByKey.removeValue(forKey: probeKey)
            workspaceGitCleanIndexContentSignatureByKey.removeValue(forKey: probeKey)
            workspaceGitHeadSignatureByKey.removeValue(forKey: probeKey)
            workspace.clearPanelGitBranch(panelId: probeKey.panelId)
        }

        switch snapshot.pullRequest {
        case .resolved(let pullRequest):
            if shouldTrackPullRequests {
                workspace.updatePanelPullRequest(
                    panelId: probeKey.panelId,
                    number: pullRequest.number,
                    label: pullRequest.label,
                    url: pullRequest.url,
                    status: pullRequest.status,
                    branch: pullRequest.branch,
                    isStale: false
                )
            } else if workspace.panelPullRequests[probeKey.panelId] != nil {
                workspace.clearPanelPullRequest(panelId: probeKey.panelId)
            }
        case .notFound:
            if workspace.panelPullRequests[probeKey.panelId] != nil {
                workspace.clearPanelPullRequest(panelId: probeKey.panelId)
            }
        case .deferred, .unsupportedRepository, .transientFailure:
            if !shouldTrackPullRequests, workspace.panelPullRequests[probeKey.panelId] != nil {
                workspace.clearPanelPullRequest(panelId: probeKey.panelId)
            }
            break
        }

        if snapshot.branch != nil, shouldTrackPullRequests {
            scheduleWorkspacePullRequestRefresh(
                workspaceId: probeKey.workspaceId,
                panelId: probeKey.panelId,
                reason: "localGitProbe"
            )
        }

#if DEBUG
        let branchLabel = snapshot.branch ?? "none"
        let prLabel: String = {
            switch snapshot.pullRequest {
            case .deferred:
                return "deferred"
            case .unsupportedRepository:
                return "unsupported"
            case .notFound:
                return "none"
            case .transientFailure:
                return "transientFailure"
            case .resolved(let pullRequest):
                return "#\(pullRequest.number):\(pullRequest.status.rawValue)"
            }
        }()
        cmuxDebugLog(
            "workspace.gitProbe.apply workspace=\(probeKey.workspaceId.uuidString.prefix(5)) " +
            "panel=\(probeKey.panelId.uuidString.prefix(5)) branch=\(branchLabel) dirty=\(snapshot.isDirty ? 1 : 0) " +
            "pr=\(prLabel)"
        )
#endif
    }

    private func shouldStopWorkspaceGitMetadataRefresh(
        _ snapshot: InitialWorkspaceGitMetadataSnapshot
    ) -> Bool {
        if snapshot.isRepository {
            return false
        }
        switch snapshot.pullRequest {
        case .deferred, .transientFailure:
            return false
        case .unsupportedRepository, .notFound, .resolved:
            return true
        }
    }

    private nonisolated static func initialWorkspaceGitMetadataSnapshot(
        for directory: String,
        reader: any WorkspaceGitMetadataReading
    ) async -> InitialWorkspaceGitMetadataSnapshot {
        let metadata = await reader.workspaceMetadata(for: directory)
        guard metadata.isRepository else {
            return InitialWorkspaceGitMetadataSnapshot(
                isRepository: false,
                branch: nil,
                isDirty: false,
                indexSignature: nil,
                indexContentSignature: nil,
                headSignature: nil,
                pullRequest: .notFound
            )
        }

        let branch = GitMetadataService.normalizedBranchName(metadata.branch)
        return InitialWorkspaceGitMetadataSnapshot(
            isRepository: true,
            branch: branch,
            isDirty: metadata.isDirty,
            indexSignature: metadata.indexSignature,
            indexContentSignature: metadata.indexContentSignature,
            headSignature: metadata.headSignature,
            pullRequest: branch == nil ? .notFound : .deferred
        )
    }

    private nonisolated static func resolveGitRepository(containing directory: String) -> ResolvedGitRepository? {
        let startURL = URL(fileURLWithPath: directory).standardizedFileURL
        let fileManager = FileManager.default
        var currentURL = startURL
        var isDirectory: ObjCBool = false

        if !fileManager.fileExists(atPath: currentURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            currentURL.deleteLastPathComponent()
        }

        while true {
            let dotGitURL = currentURL.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory) {
                let gitDirectory: String?
                if isDirectory.boolValue {
                    gitDirectory = dotGitURL.standardizedFileURL.path
                } else {
                    gitDirectory = gitDirectoryFromDotGitFile(dotGitURL, relativeTo: currentURL)
                }

                if let gitDirectory {
                    let commonDirectory = gitCommonDirectory(gitDirectory: gitDirectory)
                    return ResolvedGitRepository(
                        workTreeRoot: currentURL.standardizedFileURL.path,
                        gitDirectory: gitDirectory,
                        commonDirectory: commonDirectory
                    )
                }
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if Self.shouldStopGitRepositorySearch(currentURL: currentURL, parentURL: parentURL) {
                return nil
            }
            currentURL = parentURL
        }
    }

    nonisolated static func shouldStopGitRepositorySearch(currentURL: URL, parentURL: URL) -> Bool {
        if parentURL.path == currentURL.path {
            return true
        }

        let standardizedCurrentPath = currentURL.standardizedFileURL.path
        if standardizedCurrentPath == "/" {
            return true
        }

        return parentURL.standardizedFileURL.path == standardizedCurrentPath
    }

    private nonisolated static func gitDirectoryFromDotGitFile(
        _ dotGitURL: URL,
        relativeTo workTreeRootURL: URL
    ) -> String? {
        guard let contents = try? String(contentsOf: dotGitURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir:"
        guard trimmed.lowercased().hasPrefix(prefix) else {
            return nil
        }

        let rawPath = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return nil }
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: String(rawPath)).standardizedFileURL.path
        }
        return workTreeRootURL
            .appendingPathComponent(String(rawPath))
            .standardizedFileURL
            .path
    }

    private nonisolated static func gitCommonDirectory(gitDirectory: String) -> String {
        let gitDirectoryURL = URL(fileURLWithPath: gitDirectory)
        let commonDirURL = gitDirectoryURL.appendingPathComponent("commondir")
        guard let contents = try? String(contentsOf: commonDirURL, encoding: .utf8) else {
            return gitDirectory
        }

        let rawPath = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else { return gitDirectory }
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath).standardizedFileURL.path
        }
        return gitDirectoryURL
            .appendingPathComponent(rawPath)
            .standardizedFileURL
            .path
    }

    private nonisolated static func gitRepositoryMetadataWatchPaths(
        repository: ResolvedGitRepository
    ) -> [String] {
        [
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD").path,
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index").path,
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("refs").path,
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("refs").path,
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("packed-refs").path,
        ] + gitConfigURLs(repository: repository).map(\.path)
    }

    private nonisolated static func gitlinkMetadataWatchPaths(
        repository: ResolvedGitRepository
    ) -> [String] {
        let indexURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index")
        guard let indexSnapshot = gitIndexSnapshot(indexURL: indexURL) else {
            return []
        }

        let gitlinkMode: UInt32 = 0o160000
        var paths: [String] = []
        for entry in indexSnapshot.entries where (entry.mode & 0o170000) == gitlinkMode {
            let gitlinkURL = URL(fileURLWithPath: repository.workTreeRoot)
                .appendingPathComponent(entry.path)
                .standardizedFileURL
            guard let submoduleRepository = resolveGitRepository(containing: gitlinkURL.path),
                  submoduleRepository.workTreeRoot == gitlinkURL.path else {
                continue
            }
            paths.append(contentsOf: gitRepositoryMetadataWatchPaths(repository: submoduleRepository))
        }
        return paths
    }

    private nonisolated static func gitBranchName(repository: ResolvedGitRepository) -> String? {
        let headURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchPrefix = "ref: refs/heads/"
        guard trimmed.hasPrefix(branchPrefix) else {
            return nil
        }
        let branch = String(trimmed.dropFirst(branchPrefix.count))
        return branch.isEmpty ? nil : branch
    }

    private nonisolated static func gitHeadSignature(repository: ResolvedGitRepository) -> String? {
        let headURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref: "
        guard trimmed.hasPrefix(refPrefix) else {
            return trimmed.isEmpty ? nil : trimmed
        }

        let refName = String(trimmed.dropFirst(refPrefix.count))
        guard !refName.isEmpty else { return trimmed }
        let refValue = gitRefValue(repository: repository, refName: refName) ?? ""
        return "\(trimmed)\n\(refValue)"
    }

    private nonisolated static func gitRefValue(repository: ResolvedGitRepository, refName: String) -> String? {
        let refURLs = [
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent(refName),
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent(refName),
        ]
        var seenPaths: Set<String> = []
        for refURL in refURLs {
            let path = refURL.standardizedFileURL.path
            guard seenPaths.insert(path).inserted,
                  let contents = try? String(contentsOf: refURL, encoding: .utf8) else {
                continue
            }
            let value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }

        let packedRefsURL = URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("packed-refs")
        guard let packedRefs = try? String(contentsOf: packedRefsURL, encoding: .utf8) else {
            return nil
        }
        for rawLine in packedRefs.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, String(parts[1]) == refName else { continue }
            return String(parts[0])
        }
        return nil
    }

    private nonisolated static func gitRemoteVOutput(repository: ResolvedGitRepository) -> String? {
        var lines: [String] = []
        var seenConfigPaths: Set<String> = []
        for configURL in gitRootConfigURLs(repository: repository) {
            appendGitRemoteVLines(
                fromConfigURL: configURL,
                repository: repository,
                seenConfigPaths: &seenConfigPaths,
                lines: &lines
            )
        }
        return lines.isEmpty ? nil : lines.joined()
    }

    private nonisolated static func gitRootConfigURLs(repository: ResolvedGitRepository) -> [URL] {
        [
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("config"),
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("config"),
        ]
    }

    private nonisolated static func gitConfigURLs(repository: ResolvedGitRepository) -> [URL] {
        var urls: [URL] = []
        var pendingURLs = gitRootConfigURLs(repository: repository)
        var seenConfigPaths: Set<String> = []

        while !pendingURLs.isEmpty {
            let configURL = pendingURLs.removeFirst().standardizedFileURL
            let path = configURL.path
            guard seenConfigPaths.insert(path).inserted else { continue }
            urls.append(configURL)
            guard let config = try? String(contentsOf: configURL, encoding: .utf8) else {
                continue
            }
            pendingURLs.append(
                contentsOf: gitIncludedConfigURLs(
                    fromConfig: config,
                    configURL: configURL,
                    repository: repository
                )
            )
        }

        return urls
    }

    private nonisolated static func gitRemoteVLines(fromConfig config: String) -> [String] {
        var currentRemoteName: String?
        var lines: [String] = []

        for rawLine in config.components(separatedBy: .newlines) {
            let line = gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentRemoteName = gitConfigRemoteName(fromSectionHeader: line)
                continue
            }

            guard let currentRemoteName else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[0] == "url" else {
                continue
            }
            let remoteURL = gitConfigUnquotedValue(parts[1])
            guard !remoteURL.isEmpty else {
                continue
            }
            lines.append("\(currentRemoteName)\t\(remoteURL) (fetch)\n")
        }

        return lines
    }

    private nonisolated static func appendGitRemoteVLines(
        fromConfigURL configURL: URL,
        repository: ResolvedGitRepository,
        seenConfigPaths: inout Set<String>,
        lines: inout [String]
    ) {
        let configURL = configURL.standardizedFileURL
        guard seenConfigPaths.insert(configURL.path).inserted,
              let config = try? String(contentsOf: configURL, encoding: .utf8) else {
            return
        }

        var currentRemoteName: String?
        var currentSectionAllowsIncludePath = false

        for rawLine in config.components(separatedBy: .newlines) {
            let line = gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentRemoteName = gitConfigRemoteName(fromSectionHeader: line)
                if line == "[include]" {
                    currentSectionAllowsIncludePath = true
                } else if let condition = gitConfigIncludeIfCondition(fromSectionHeader: line) {
                    currentSectionAllowsIncludePath = gitConfigIncludeIfConditionMatches(
                        condition,
                        repository: repository
                    )
                } else {
                    currentSectionAllowsIncludePath = false
                }
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }

            if let currentRemoteName,
               parts.count == 2,
               parts[0] == "url" {
                let remoteURL = gitConfigUnquotedValue(parts[1])
                guard !remoteURL.isEmpty else {
                    continue
                }
                lines.append("\(currentRemoteName)\t\(remoteURL) (fetch)\n")
                continue
            }

            guard currentSectionAllowsIncludePath,
                  parts.count == 2,
                  parts[0] == "path",
                  let includeURL = gitConfigIncludeURL(
                      fromPathValue: parts[1],
                      relativeTo: configURL
                  ) else {
                continue
            }
            appendGitRemoteVLines(
                fromConfigURL: includeURL,
                repository: repository,
                seenConfigPaths: &seenConfigPaths,
                lines: &lines
            )
        }
    }

    private nonisolated static func gitIncludedConfigURLs(
        fromConfig config: String,
        configURL: URL,
        repository: ResolvedGitRepository
    ) -> [URL] {
        var currentSectionAllowsPath = false
        var urls: [URL] = []

        for rawLine in config.components(separatedBy: .newlines) {
            let line = gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if line == "[include]" {
                    currentSectionAllowsPath = true
                } else if let condition = gitConfigIncludeIfCondition(fromSectionHeader: line) {
                    currentSectionAllowsPath = gitConfigIncludeIfConditionMatches(
                        condition,
                        repository: repository
                    )
                } else {
                    currentSectionAllowsPath = false
                }
                continue
            }

            guard currentSectionAllowsPath else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2,
                  parts[0].lowercased() == "path",
                  let includeURL = gitConfigIncludeURL(
                    fromPathValue: parts[1],
                    relativeTo: configURL
                  ) else {
                continue
            }
            urls.append(includeURL)
        }

        return urls
    }

    private nonisolated static func gitConfigUnquotedValue(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespaces)
        guard trimmedValue.first == "\"",
              trimmedValue.last == "\"",
              trimmedValue.count >= 2 else {
            return trimmedValue
        }

        var result = ""
        var isEscaped = false
        for character in trimmedValue.dropFirst().dropLast() {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            result.append(character)
        }

        if isEscaped {
            result.append("\\")
        }
        return result
    }

    private nonisolated static func gitConfigLineRemovingInlineComment(_ line: String) -> String {
        var result = ""
        var isInsideDoubleQuotedString = false
        var isEscaped = false
        var previousWasWhitespace = true

        for character in line {
            if isEscaped {
                result.append(character)
                isEscaped = false
                previousWasWhitespace = character.isWhitespace
                continue
            }

            if isInsideDoubleQuotedString && character == "\\" {
                result.append(character)
                isEscaped = true
                previousWasWhitespace = false
                continue
            }

            if character == "\"" {
                result.append(character)
                isInsideDoubleQuotedString.toggle()
                previousWasWhitespace = false
                continue
            }

            if !isInsideDoubleQuotedString,
               previousWasWhitespace,
               (character == "#" || character == ";") {
                break
            }

            result.append(character)
            previousWasWhitespace = character.isWhitespace
        }

        return result
    }

    private nonisolated static func gitConfigRemoteName(fromSectionHeader header: String) -> String? {
        let prefix = "[remote \""
        let suffix = "\"]"
        guard header.hasPrefix(prefix), header.hasSuffix(suffix) else {
            return nil
        }
        let name = header.dropFirst(prefix.count).dropLast(suffix.count)
        return name.isEmpty ? nil : String(name)
    }

    private nonisolated static func gitConfigIncludeIfCondition(fromSectionHeader header: String) -> String? {
        let prefix = "[includeIf \""
        let suffix = "\"]"
        guard header.hasPrefix(prefix), header.hasSuffix(suffix) else {
            return nil
        }
        let condition = header.dropFirst(prefix.count).dropLast(suffix.count)
        return condition.isEmpty ? nil : String(condition)
    }

    private nonisolated static func gitConfigIncludeURL(
        fromPathValue pathValue: String,
        relativeTo configURL: URL
    ) -> URL? {
        let path = gitConfigUnquotedValue(pathValue)
        guard !path.isEmpty else { return nil }
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        }
        if path.hasPrefix("~/") {
            let relativePath = String(path.dropFirst(2))
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(relativePath)
                .standardizedFileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return configURL
            .deletingLastPathComponent()
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    private nonisolated static func gitConfigIncludeIfConditionMatches(
        _ condition: String,
        repository: ResolvedGitRepository
    ) -> Bool {
        let lowercasedCondition = condition.lowercased()
        if lowercasedCondition.hasPrefix("gitdir/i:") {
            let pattern = String(condition.dropFirst("gitdir/i:".count))
            return gitConfigGitdirPatternMatches(pattern, repository: repository, caseInsensitive: true)
        }
        if lowercasedCondition.hasPrefix("gitdir:") {
            let pattern = String(condition.dropFirst("gitdir:".count))
            return gitConfigGitdirPatternMatches(pattern, repository: repository, caseInsensitive: false)
        }
        if lowercasedCondition.hasPrefix("onbranch:") {
            let pattern = String(condition.dropFirst("onbranch:".count))
            guard let branch = gitBranchName(repository: repository) else { return false }
            return gitConfigGlobMatches(branch, pattern: pattern, caseInsensitive: false)
        }
        return false
    }

    private nonisolated static func gitConfigGitdirPatternMatches(
        _ pattern: String,
        repository: ResolvedGitRepository,
        caseInsensitive: Bool
    ) -> Bool {
        let isRecursiveDirectoryPattern = pattern.hasSuffix("/")
        var expandedPattern = gitConfigExpandedPattern(pattern)
        if isRecursiveDirectoryPattern, !expandedPattern.hasSuffix("/") {
            expandedPattern.append("/")
        }
        if isRecursiveDirectoryPattern {
            expandedPattern.append("**")
        }
        let candidates = [
            repository.gitDirectory,
            repository.commonDirectory,
            repository.workTreeRoot,
        ].map { URL(fileURLWithPath: $0).standardizedFileURL.path }

        for candidate in candidates {
            if gitConfigGlobMatches(candidate, pattern: expandedPattern, caseInsensitive: caseInsensitive) ||
                gitConfigGlobMatches(candidate + "/", pattern: expandedPattern, caseInsensitive: caseInsensitive) {
                return true
            }
        }
        return false
    }

    private nonisolated static func gitConfigExpandedPattern(_ pattern: String) -> String {
        if pattern == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        }
        if pattern.hasPrefix("~/") {
            let relativePath = String(pattern.dropFirst(2))
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(relativePath)
                .standardizedFileURL
                .path
        }
        return URL(fileURLWithPath: pattern).standardizedFileURL.path
    }

    private nonisolated static func gitConfigGlobMatches(
        _ value: String,
        pattern: String,
        caseInsensitive: Bool
    ) -> Bool {
        let candidateValue = caseInsensitive ? value.lowercased() : value
        let candidatePattern = caseInsensitive ? pattern.lowercased() : pattern
        guard let regex = try? NSRegularExpression(
            pattern: gitConfigGlobRegexPattern(candidatePattern)
        ) else {
            return fnmatch(candidatePattern, candidateValue, 0) == 0
        }
        let range = NSRange(candidateValue.startIndex..<candidateValue.endIndex, in: candidateValue)
        return regex.firstMatch(in: candidateValue, range: range) != nil
    }

    private nonisolated static func gitConfigGlobRegexPattern(_ pattern: String) -> String {
        let characters = Array(pattern)
        var regex = "^"
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "*" {
                var starCount = 1
                while index + starCount < characters.count,
                      characters[index + starCount] == "*" {
                    starCount += 1
                }
                index += starCount

                if starCount >= 2 {
                    if index < characters.count, characters[index] == "/" {
                        index += 1
                        regex += "(?:.*/)?"
                    } else {
                        regex += ".*"
                    }
                } else {
                    regex += "[^/]*"
                }
                continue
            }

            if character == "?" {
                regex += "[^/]"
                index += 1
                continue
            }

            if character == "[" {
                let parsedClass = gitConfigGlobCharacterClass(characters, startIndex: index)
                if let parsedClass {
                    regex += parsedClass.regex
                    index = parsedClass.endIndex
                    continue
                }
            }

            regex += NSRegularExpression.escapedPattern(for: String(character))
            index += 1
        }

        regex += "$"
        return regex
    }

    private nonisolated static func gitConfigGlobCharacterClass(
        _ characters: [Character],
        startIndex: Int
    ) -> (regex: String, endIndex: Int)? {
        guard startIndex < characters.count, characters[startIndex] == "[" else {
            return nil
        }

        var index = startIndex + 1
        guard index < characters.count else { return nil }

        var regex = "["
        if characters[index] == "!" {
            regex += "^"
            index += 1
        } else if characters[index] == "^" {
            regex += "\\^"
            index += 1
        }

        if index < characters.count, characters[index] == "]" {
            regex += "\\]"
            index += 1
        }

        var hasTerminator = false
        while index < characters.count {
            let character = characters[index]
            if character == "]" {
                hasTerminator = true
                index += 1
                break
            }
            switch character {
            case "\\":
                regex += "\\\\"
            case "[":
                regex += "\\["
            default:
                regex += String(character)
            }
            index += 1
        }

        guard hasTerminator else { return nil }
        regex += "]"
        return (regex, index)
    }

    private nonisolated static func gitTrackedChangesSnapshot(
        repository: ResolvedGitRepository
    ) -> (isDirty: Bool, indexSignature: String?, indexContentSignature: String?) {
        let indexURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("index")
        guard let indexSnapshot = gitIndexSnapshot(indexURL: indexURL) else {
            return (false, gitIndexFileSignature(indexURL: indexURL), nil)
        }

        for entry in indexSnapshot.entries {
            let fileURL = URL(fileURLWithPath: repository.workTreeRoot).appendingPathComponent(entry.path)
            let gitlinkMode: UInt32 = 0o160000
            if (entry.mode & 0o170000) == gitlinkMode {
                guard let submoduleCommit = gitlinkWorktreeCommit(
                    parentRepository: repository,
                    gitlinkPath: entry.path
                ) else {
                    return (true, indexSnapshot.signature, indexSnapshot.contentSignature)
                }
                if submoduleCommit.caseInsensitiveCompare(entry.objectID) != .orderedSame {
                    return (true, indexSnapshot.signature, indexSnapshot.contentSignature)
                }
                continue
            }

            var statValue = stat()
            guard lstat(fileURL.path, &statValue) == 0 else {
                return (true, indexSnapshot.signature, indexSnapshot.contentSignature)
            }
            let size = gitIndexUInt32Field(statValue.st_size)
            let mtimeSeconds = gitIndexUInt32Field(statValue.st_mtimespec.tv_sec)
            let mtimeNanoseconds = gitIndexUInt32Field(statValue.st_mtimespec.tv_nsec)
            guard let mode = gitIndexComparableMode(for: statValue.st_mode) else {
                return (true, indexSnapshot.signature, indexSnapshot.contentSignature)
            }
            if size != entry.size ||
                mode != entry.mode ||
                mtimeSeconds != entry.mtimeSeconds ||
                mtimeNanoseconds != entry.mtimeNanoseconds {
                return (true, indexSnapshot.signature, indexSnapshot.contentSignature)
            }
        }

        return (false, indexSnapshot.signature, indexSnapshot.contentSignature)
    }

    private nonisolated static func gitIndexSnapshot(indexURL: URL) -> GitIndexSnapshot? {
        guard let data = try? Data(contentsOf: indexURL), data.count >= 32 else {
            return nil
        }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x44, bytes[1] == 0x49, bytes[2] == 0x52, bytes[3] == 0x43 else {
            return nil
        }
        let version = readBigEndianUInt32(bytes, at: 4)
        guard version == 2 || version == 3 || version == 4 else {
            return nil
        }
        let entryCount = Int(readBigEndianUInt32(bytes, at: 8))
        let contentEnd = bytes.count - 20
        var offset = 12
        var entries: [GitIndexEntryStat] = []
        var contentEntries: [GitIndexEntryStat] = []
        entries.reserveCapacity(min(entryCount, 1024))
        contentEntries.reserveCapacity(min(entryCount, 1024))
        var previousPathBytes: [UInt8] = []

        for _ in 0..<entryCount {
            guard offset + 62 <= contentEnd else { return nil }
            let entryStart = offset
            let mtimeSeconds = readBigEndianUInt32(bytes, at: offset + 8)
            let mtimeNanoseconds = readBigEndianUInt32(bytes, at: offset + 12)
            let mode = readBigEndianUInt32(bytes, at: offset + 24)
            let size = readBigEndianUInt32(bytes, at: offset + 36)
            let objectID = bytes[(offset + 40)..<(offset + 60)].map {
                String(format: "%02x", $0)
            }.joined()
            let flags = readBigEndianUInt16(bytes, at: offset + 60)
            let pathLength = Int(flags & 0x0fff)
            let hasExtendedFlags = version >= 3 && (flags & 0x4000) != 0
            var extendedFlags: UInt16 = 0
            offset += 62
            if hasExtendedFlags {
                guard offset + 2 <= contentEnd else { return nil }
                extendedFlags = readBigEndianUInt16(bytes, at: offset)
                offset += 2
            }

            let pathBytes: [UInt8]
            if version == 4 {
                guard let stripLength = readGitIndexV4PathStripLength(bytes, offset: &offset),
                      stripLength <= previousPathBytes.count else {
                    return nil
                }
                let suffixStart = offset
                while offset < contentEnd, bytes[offset] != 0 {
                    offset += 1
                }
                guard offset < contentEnd else { return nil }
                pathBytes = Array(previousPathBytes.dropLast(stripLength)) + Array(bytes[suffixStart..<offset])
            } else {
                let pathStart = offset
                if pathLength < 0x0fff {
                    offset += pathLength
                    guard offset < contentEnd else { return nil }
                } else {
                    while offset < contentEnd, bytes[offset] != 0 {
                        offset += 1
                    }
                    guard offset < contentEnd else { return nil }
                }
                pathBytes = Array(bytes[pathStart..<offset])
            }

            let pathData = Data(pathBytes)
            guard let path = String(data: pathData, encoding: .utf8), !path.isEmpty else {
                return nil
            }
            previousPathBytes = pathBytes
            let entryStat = GitIndexEntryStat(
                path: path,
                mode: mode,
                objectID: objectID,
                mtimeSeconds: mtimeSeconds,
                mtimeNanoseconds: mtimeNanoseconds,
                size: size
            )
            contentEntries.append(entryStat)

            let assumeUnchangedFlag: UInt16 = 0x8000
            let skipWorktreeExtendedFlag: UInt16 = 0x4000
            if (flags & assumeUnchangedFlag) == 0,
               (extendedFlags & skipWorktreeExtendedFlag) == 0 {
                entries.append(entryStat)
            }

            offset += 1
            if version != 4 {
                let entryLength = offset - entryStart
                let padding = (8 - (entryLength % 8)) % 8
                offset += padding
            }
        }

        let checksum = bytes[(bytes.count - 20)..<bytes.count].map { String(format: "%02x", $0) }.joined()
        return GitIndexSnapshot(
            entries: entries,
            signature: checksum,
            contentSignature: gitIndexContentSignature(entries: contentEntries)
        )
    }

    private nonisolated static func gitIndexContentSignature(entries: [GitIndexEntryStat]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037

        func appendByte(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }

        func appendUInt32(_ value: UInt32) {
            appendByte(UInt8((value >> 24) & 0xff))
            appendByte(UInt8((value >> 16) & 0xff))
            appendByte(UInt8((value >> 8) & 0xff))
            appendByte(UInt8(value & 0xff))
        }

        func appendString(_ value: String) {
            for byte in value.utf8 {
                appendByte(byte)
            }
        }

        appendUInt32(UInt32(truncatingIfNeeded: entries.count))
        for entry in entries {
            appendString(entry.path)
            appendByte(0)
            appendUInt32(entry.mode)
            appendByte(0)
            appendString(entry.objectID)
            appendByte(0)
        }
        return String(format: "%016llx", CUnsignedLongLong(hash))
    }

    private nonisolated static func gitlinkWorktreeCommit(
        parentRepository: ResolvedGitRepository,
        gitlinkPath: String
    ) -> String? {
        let gitlinkURL = URL(fileURLWithPath: parentRepository.workTreeRoot)
            .appendingPathComponent(gitlinkPath)
            .standardizedFileURL
        guard let submoduleRepository = resolveGitRepository(containing: gitlinkURL.path),
              submoduleRepository.workTreeRoot == gitlinkURL.path else {
            return nil
        }
        return gitCurrentCommit(repository: submoduleRepository)
    }

    private nonisolated static func gitCurrentCommit(repository: ResolvedGitRepository) -> String? {
        let headURL = URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref: "
        let value: String
        if trimmed.hasPrefix(refPrefix) {
            let refName = String(trimmed.dropFirst(refPrefix.count))
            guard !refName.isEmpty, let refValue = gitRefValue(repository: repository, refName: refName) else {
                return nil
            }
            value = refValue
        } else {
            value = trimmed
        }

        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 40,
              normalized.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return normalized
    }

    private nonisolated static func gitIndexComparableMode(for statMode: mode_t) -> UInt32? {
        let type = statMode & mode_t(S_IFMT)
        switch type {
        case mode_t(S_IFREG):
            return (statMode & 0o111) == 0 ? 0o100644 : 0o100755
        case mode_t(S_IFLNK):
            return 0o120000
        default:
            return nil
        }
    }

    private nonisolated static func gitIndexUInt32Field<T: BinaryInteger>(_ value: T) -> UInt32 {
        UInt32(truncatingIfNeeded: UInt64(truncatingIfNeeded: value))
    }

    private nonisolated static func gitIndexFileSignature(indexURL: URL) -> String? {
        guard let data = try? Data(contentsOf: indexURL), data.count >= 20 else {
            return nil
        }
        return data.suffix(20).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func readGitIndexV4PathStripLength(
        _ bytes: [UInt8],
        offset: inout Int
    ) -> Int? {
        guard offset < bytes.count else { return nil }
        var byte = bytes[offset]
        offset += 1
        var value = Int(byte & 0x7f)
        while (byte & 0x80) != 0 {
            guard offset < bytes.count else { return nil }
            // Git's index v4 path compression uses varint.c's encode/decode pair.
            // Continuation bytes increment the accumulated value before shifting.
            value += 1
            byte = bytes[offset]
            offset += 1
            value = (value << 7) + Int(byte & 0x7f)
        }
        return value
    }

    private nonisolated static func readBigEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private nonisolated static func readBigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) |
            (UInt32(bytes[offset + 1]) << 16) |
            (UInt32(bytes[offset + 2]) << 8) |
            UInt32(bytes[offset + 3])
    }

    private nonisolated static func sidebarPullRequestState(
        from pullRequest: GitHubPullRequestProbeItem,
        branch: String?
    ) -> SidebarPullRequestState? {
        guard let status = pullRequestStatus(from: pullRequest.state),
              let url = URL(string: pullRequest.url),
              isSidebarPullRequestCandidate(pullRequest, now: Date()) else {
            return nil
        }
        return SidebarPullRequestState(
            number: pullRequest.number,
            label: "PR",
            url: url,
            status: status,
            branch: branch,
            isStale: false
        )
    }

    nonisolated static func preferredPullRequest(
        from pullRequests: [GitHubPullRequestProbeItem],
        now: Date = Date()
    ) -> GitHubPullRequestProbeItem? {
        var best: GitHubPullRequestProbeItem?
        for pullRequest in pullRequests {
            guard isSidebarPullRequestCandidate(pullRequest, now: now) else {
                continue
            }
            guard let currentBest = best else {
                best = pullRequest
                continue
            }
            if isPreferredCandidate(candidate: pullRequest, over: currentBest) {
                best = pullRequest
            }
        }
        return best
    }

    private nonisolated static func pullRequestStatusPriority(_ status: SidebarPullRequestStatus) -> Int {
        switch status {
        case .open: return 3
        case .merged: return 2
        case .closed: return 1
        }
    }

    private nonisolated static func isPreferredCandidate(
        candidate: GitHubPullRequestProbeItem,
        over current: GitHubPullRequestProbeItem
    ) -> Bool {
        guard let candidateStatus = pullRequestStatus(from: candidate.state),
              let currentStatus = pullRequestStatus(from: current.state) else {
            return false
        }

        let candidatePriority = pullRequestStatusPriority(candidateStatus)
        let currentPriority = pullRequestStatusPriority(currentStatus)
        if candidatePriority != currentPriority {
            return candidatePriority > currentPriority
        }

        let candidateUpdatedAt = candidate.updatedAt ?? ""
        let currentUpdatedAt = current.updatedAt ?? ""
        if candidateUpdatedAt != currentUpdatedAt {
            return candidateUpdatedAt > currentUpdatedAt
        }

        return candidate.number > current.number
    }

    private nonisolated static func isSidebarPullRequestCandidate(
        _ pullRequest: GitHubPullRequestProbeItem,
        now: Date
    ) -> Bool {
        guard pullRequestStatus(from: pullRequest.state) != nil,
              isValidPullRequestURL(pullRequest.url) else {
            return false
        }
        return !isStaleMergedPullRequest(pullRequest, now: now)
    }

    private nonisolated static func isValidPullRequestURL(_ raw: String) -> Bool {
        // GitHub PR URLs always start with https://. Cheaper than full RFC 3986 parse.
        return raw.hasPrefix("https://") || raw.hasPrefix("http://")
    }

    private nonisolated static func isStaleMergedPullRequest(
        _ pullRequest: GitHubPullRequestProbeItem,
        now: Date
    ) -> Bool {
        guard pullRequestStatus(from: pullRequest.state) == .merged,
              let mergedAt = githubTimestampDate(from: pullRequest.mergedAt) else {
            return false
        }
        return now.timeIntervalSince(mergedAt) > mergedPullRequestBadgeStaleAfter
    }

    private nonisolated static func githubTimestampDate(from rawTimestamp: String?) -> Date? {
        guard let raw = rawTimestamp else { return nil }
        return parseGitHubISO8601(raw)
    }

    // GitHub returns timestamps like `2024-12-30T15:04:05Z` or `2024-12-30T15:04:05.123Z`.
    // Hand-rolled parser avoids ICU/SimpleDateFormat allocation+clone per call.
    private nonisolated static func parseGitHubISO8601(_ raw: String) -> Date? {
        let bytes = Array(raw.utf8)
        var i = 0
        let n = bytes.count

        func skipWhitespace() {
            while i < n {
                switch bytes[i] {
                case 0x20, 0x09, 0x0A, 0x0D: i += 1
                default: return
                }
            }
        }
        func digit(_ b: UInt8) -> Int? { (b >= 0x30 && b <= 0x39) ? Int(b - 0x30) : nil }
        func readInt(_ count: Int) -> Int? {
            guard i + count <= n else { return nil }
            var v = 0
            for _ in 0..<count {
                guard let d = digit(bytes[i]) else { return nil }
                v = v * 10 + d
                i += 1
            }
            return v
        }

        skipWhitespace()
        guard let year = readInt(4) else { return nil }
        guard i < n, bytes[i] == 0x2D else { return nil }; i += 1
        guard let month = readInt(2) else { return nil }
        guard i < n, bytes[i] == 0x2D else { return nil }; i += 1
        guard let day = readInt(2) else { return nil }
        guard i < n, (bytes[i] == 0x54 || bytes[i] == 0x74 || bytes[i] == 0x20) else { return nil }
        i += 1
        guard let hour = readInt(2) else { return nil }
        guard i < n, bytes[i] == 0x3A else { return nil }; i += 1
        guard let minute = readInt(2) else { return nil }
        guard i < n, bytes[i] == 0x3A else { return nil }; i += 1
        guard let second = readInt(2) else { return nil }

        var fractional: Double = 0
        if i < n, bytes[i] == 0x2E {
            i += 1
            var scale = 0.1
            var consumed = 0
            while i < n, let d = digit(bytes[i]) {
                fractional += Double(d) * scale
                scale *= 0.1
                i += 1
                consumed += 1
            }
            if consumed == 0 { return nil }
        }

        // Timezone: Z or ±HH:MM / ±HHMM
        var tzOffsetSeconds = 0
        guard i < n else { return nil }
        switch bytes[i] {
        case 0x5A, 0x7A: // 'Z' or 'z'
            i += 1
        case 0x2B, 0x2D: // '+' or '-'
            let sign = bytes[i] == 0x2B ? 1 : -1
            i += 1
            guard let offHour = readInt(2) else { return nil }
            if i < n, bytes[i] == 0x3A { i += 1 }
            guard let offMin = readInt(2) else { return nil }
            tzOffsetSeconds = sign * (offHour * 3600 + offMin * 60)
        default:
            return nil
        }

        skipWhitespace()
        guard i == n else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: 0)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let base = calendar.date(from: components) else { return nil }
        return base.addingTimeInterval(fractional - Double(tzOffsetSeconds))
    }

    private nonisolated static func pullRequestStatus(
        from rawState: String
    ) -> SidebarPullRequestStatus? {
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "OPEN":
            return .open
        case "MERGED":
            return .merged
        case "CLOSED":
            return .closed
        default:
            return nil
        }
    }

    private nonisolated static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(T.self, from: data)
    }

    nonisolated static func githubRepositorySlugs(fromGitRemoteVOutput output: String) -> [String] {
        var slugByRemoteName: [String: String] = [:]

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3 else { continue }

            let remoteName = String(parts[0])
            let remoteURL = String(parts[1])
            let remoteKind = String(parts[2])
            guard remoteKind == "(fetch)",
                  let repoSlug = githubRepositorySlug(fromRemoteURL: remoteURL) else {
                continue
            }

            slugByRemoteName[remoteName] = repoSlug
        }

        let orderedRemoteNames = slugByRemoteName.keys.sorted { lhs, rhs in
            let lhsPriority = githubRemotePriority(lhs)
            let rhsPriority = githubRemotePriority(rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs < rhs
        }

        var orderedSlugs: [String] = []
        var seen: Set<String> = []
        for remoteName in orderedRemoteNames {
            guard let repoSlug = slugByRemoteName[remoteName],
                  seen.insert(repoSlug).inserted else {
                continue
            }
            orderedSlugs.append(repoSlug)
        }
        return orderedSlugs
    }


    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func githubRepositorySlugs(directory: String) async -> [String] {
        guard let repository = resolveGitRepository(containing: directory),
              let output = gitRemoteVOutput(repository: repository) else {
            return []
        }
        return githubRepositorySlugs(fromGitRemoteVOutput: output)
    }

    private nonisolated static func githubRemotePriority(_ remoteName: String) -> Int {
        switch remoteName.lowercased() {
        case "upstream":
            return 0
        case "origin":
            return 1
        default:
            return 2
        }
    }

    private nonisolated static func githubRepositorySlug(fromRemoteURL remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let githubPrefixes = [
            "git@github.com:",
            "ssh://git@github.com/",
            "https://github.com/",
            "http://github.com/",
            "git://github.com/",
        ]
        for prefix in githubPrefixes where trimmed.hasPrefix(prefix) {
            let path = String(trimmed.dropFirst(prefix.count))
            return normalizedGitHubRepositorySlug(path)
        }

        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              host == "github.com" else {
            return nil
        }

        return normalizedGitHubRepositorySlug(url.path)
    }

    private nonisolated static func githubRepositorySlug(fromPullRequestURL url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host == "github.com" else {
            return nil
        }
        return normalizedGitHubRepositorySlug(url.path)
    }

    private nonisolated static func normalizedGitHubRepositorySlug(_ rawPath: String) -> String? {
        let trimmedPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else { return nil }
        let components = trimmedPath.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let owner = components[0]
        var repo = components[1]
        if repo.hasSuffix(".git") {
            repo.removeLast(4)
        }
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return "\(owner)/\(repo)"
    }

    private nonisolated static func debugLogSnippet(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(180))
    }

    private nonisolated static func normalizedBranchName(_ branch: String?) -> String? {
        let trimmed = branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    private nonisolated static func normalizedCommitSHA(_ rawSHA: String?) -> String? {
        let trimmed = rawSHA?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ hexCharacterSet.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    nonisolated static func shouldSkipWorkspacePullRequestLookup(branch: String) -> Bool {
        switch normalizedBranchName(branch) {
        case "main", "master":
            return true
        default:
            return false
        }
    }

    func requestBackgroundWorkspaceLoad(for workspaceId: UUID) {
        guard !pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = pendingBackgroundWorkspaceLoadIds
        updated.insert(workspaceId)
        pendingBackgroundWorkspaceLoadIds = updated
    }

    func completeBackgroundWorkspaceLoad(for workspaceId: UUID) {
        guard pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = pendingBackgroundWorkspaceLoadIds
        updated.remove(workspaceId)
        pendingBackgroundWorkspaceLoadIds = updated
        releaseBackgroundWorkspaceMount(for: workspaceId)
    }

    func retainBackgroundWorkspaceMount(for workspaceId: UUID) {
        guard !mountedBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = mountedBackgroundWorkspaceLoadIds
        updated.insert(workspaceId)
        mountedBackgroundWorkspaceLoadIds = updated
    }

    func releaseBackgroundWorkspaceMount(for workspaceId: UUID) {
        guard mountedBackgroundWorkspaceLoadIds.contains(workspaceId) else { return }
        var updated = mountedBackgroundWorkspaceLoadIds
        updated.remove(workspaceId)
        mountedBackgroundWorkspaceLoadIds = updated
    }

    func retainDebugWorkspaceLoads(for workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        var updated = debugPinnedWorkspaceLoadIds
        updated.formUnion(workspaceIds)
        guard updated != debugPinnedWorkspaceLoadIds else { return }
        debugPinnedWorkspaceLoadIds = updated
    }

    func releaseDebugWorkspaceLoads(for workspaceIds: Set<UUID>) {
        guard !workspaceIds.isEmpty else { return }
        var updated = debugPinnedWorkspaceLoadIds
        updated.subtract(workspaceIds)
        guard updated != debugPinnedWorkspaceLoadIds else { return }
        debugPinnedWorkspaceLoadIds = updated
    }

    func pruneBackgroundWorkspaceLoads(existingIds: Set<UUID>) {
        let pruned = pendingBackgroundWorkspaceLoadIds.intersection(existingIds)
        if pruned != pendingBackgroundWorkspaceLoadIds {
            pendingBackgroundWorkspaceLoadIds = pruned
        }
        let mounted = mountedBackgroundWorkspaceLoadIds.intersection(existingIds)
        if mounted != mountedBackgroundWorkspaceLoadIds {
            mountedBackgroundWorkspaceLoadIds = mounted
        }
        let retained = debugPinnedWorkspaceLoadIds.intersection(existingIds)
        if retained != debugPinnedWorkspaceLoadIds {
            debugPinnedWorkspaceLoadIds = retained
        }
    }

    // Keep addTab as convenience alias
    @discardableResult
    func addTab(select: Bool = true, eagerLoadTerminal: Bool = false) -> Workspace {
        addWorkspace(select: select, eagerLoadTerminal: eagerLoadTerminal)
    }

    func terminalPanelForWorkspaceConfigInheritanceSource() -> TerminalPanel? {
        terminalPanelForWorkspaceConfigInheritanceSource(workspace: selectedWorkspace)
    }

    /// Build a snapshot using pre-extracted value-type data. The caller is responsible
    /// for obtaining `preferredWorkingDirectory` and `inheritedTerminalFontPoints` through
    /// `self` (where `self.tabs` keeps all Workspace objects alive) so that no local
    /// Workspace references are needed here.
    func workspaceCreationSnapshotLite(
        currentTabs: [Workspace],
        currentSelectedTabId: UUID?,
        preferredWorkingDirectory: String?,
        inheritedTerminalFontPoints: Float?
    ) -> WorkspaceCreationSnapshot {
        var tabSnapshots: [WorkspaceCreationTabSnapshot] = []
        tabSnapshots.reserveCapacity(currentTabs.count)
        for workspace in currentTabs {
            // Keep each Workspace alive while copying the tiny value snapshot out of it.
            // The optimized arm64 Nightly build can otherwise over-release during
            // Collection.map, crashing here in swift_release / snapshot creation.
            let snapshot = withExtendedLifetime(workspace) {
                WorkspaceCreationTabSnapshot(workspace: workspace)
            }
            tabSnapshots.append(snapshot)
        }
        let selectedTabSnapshot = currentSelectedTabId.flatMap { selectedTabId in
            tabSnapshots.first(where: { $0.id == selectedTabId })
        }

        return WorkspaceCreationSnapshot(
            tabs: tabSnapshots,
            selectedTabId: currentSelectedTabId,
            selectedTabWasPinned: selectedTabSnapshot?.isPinned ?? false,
            preferredWorkingDirectory: preferredWorkingDirectory,
            inheritedTerminalFontPoints: inheritedTerminalFontPoints
        )
    }

    private func workspaceCreationSnapshot() -> WorkspaceCreationSnapshot {
        workspaceCreationSnapshotLite(
            currentTabs: tabs,
            currentSelectedTabId: selectedTabId,
            preferredWorkingDirectory: preferredWorkingDirectoryForNewTab(),
            inheritedTerminalFontPoints: inheritedTerminalFontPointsForNewWorkspace()
        )
    }

    private func orderedLiveWorkspaceCreationTabs(
        from snapshot: WorkspaceCreationSnapshot
    ) -> [WorkspaceCreationTabSnapshot]? {
        let currentTabs = tabs
        let snapshotTabsById = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.id, $0) })
        var orderedTabs: [WorkspaceCreationTabSnapshot] = []
        orderedTabs.reserveCapacity(currentTabs.count)

        for workspace in currentTabs {
            guard let tabSnapshot = snapshotTabsById[workspace.id] else {
#if DEBUG
                cmuxDebugLog(
                    "workspace.create.reentrantSnapshotFallback " +
                    "snapshotCount=\(snapshot.tabs.count) liveCount=\(currentTabs.count)"
                )
#endif
                return nil
            }
            orderedTabs.append(tabSnapshot)
        }

        return orderedTabs
    }

    private func terminalPanelForWorkspaceConfigInheritanceSource(
        workspace: Workspace?
    ) -> TerminalPanel? {
        guard let workspace else { return nil }
        // Prefer cached/published panel state here instead of walking live Bonsplit focus
        // during Cmd+N; rapid workspace creation can observe transient pane/tab selection.
        let panels = workspace.panels
        var candidates: [TerminalPanel] = []
        var seen: Set<UUID> = []

        func appendCandidate(_ panel: TerminalPanel?) {
            guard let panel, seen.insert(panel.id).inserted else { return }
            candidates.append(panel)
        }

        appendCandidate(workspace.lastRememberedTerminalPanelForConfigInheritance())
        for terminalPanel in panels.values
            .compactMap({ $0 as? TerminalPanel })
            .sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            appendCandidate(terminalPanel)
        }

        if let livePanel = candidates.first(where: { $0.surface.hasLiveSurface && $0.surface.surface != nil }) {
            return livePanel
        }
        return candidates.first
    }

    private func inheritedTerminalConfigForNewWorkspace() -> CmuxSurfaceConfigTemplate? {
        inheritedTerminalConfigForNewWorkspace(workspace: selectedWorkspace)
    }

    private func cachedInheritedTerminalFontPointsForNewWorkspace(
        workspace: Workspace?
    ) -> Float? {
        guard let workspace else { return nil }
        // New workspace creation only seeds font size into a fresh Swift-owned template.
        // Avoid reading live panel/surface state here; the arm64 Nightly Cmd+N crash path
        // was repeatedly dereferencing pointer-backed terminal objects while preparing the
        // new workspace. The workspace already caches the rooted font lineage we need.
        return withExtendedLifetime(workspace) {
            guard let fontPoints = workspace.lastRememberedTerminalFontPointsForConfigInheritance(),
                  fontPoints > 0 else {
                return nil
            }
            return fontPoints
        }
    }

    func inheritedTerminalConfigForNewWorkspace(
        workspace: Workspace?
    ) -> CmuxSurfaceConfigTemplate? {
        guard let fontPoints = cachedInheritedTerminalFontPointsForNewWorkspace(workspace: workspace) else {
            return nil
        }
        var config = CmuxSurfaceConfigTemplate()
        config.fontSize = fontPoints
        return config
    }

    private func inheritedTerminalFontPointsForNewWorkspace() -> Float? {
        inheritedTerminalFontPointsForNewWorkspace(workspace: selectedWorkspace)
    }

    func inheritedTerminalFontPointsForNewWorkspace(
        workspace: Workspace?
    ) -> Float? {
        cachedInheritedTerminalFontPointsForNewWorkspace(workspace: workspace)
    }

    func workspaceCreationConfigTemplate(
        inheritedTerminalFontPoints: Float?
    ) -> CmuxSurfaceConfigTemplate? {
        guard let inheritedTerminalFontPoints, inheritedTerminalFontPoints > 0 else {
            return nil
        }
        // Rebuild a clean Swift-owned template instead of carrying over any pointer-backed
        // inherited config state from the source workspace.
        var config = CmuxSurfaceConfigTemplate()
        config.fontSize = inheritedTerminalFontPoints
        return config
    }

    func normalizedWorkingDirectory(_ directory: String?) -> String? {
        // Single source of truth: the normalization moved to CmuxSidebarGit
        // with the git subsystem; non-git callers (workspace creation) keep
        // this forwarder.
        directory?.nonEmptyNormalizedGitProbeDirectory
    }

    private func newTabInsertIndex(placementOverride: WorkspacePlacement? = nil) -> Int {
        newTabInsertIndex(snapshot: workspaceCreationSnapshot(), placementOverride: placementOverride)
    }

    func newTabInsertIndex(
        snapshot: WorkspaceCreationSnapshot,
        placementOverride: WorkspacePlacement? = nil
    ) -> Int {
        let placement = WorkspacePlacement.effectivePlacement(
            placementOverride: placementOverride,
            settings: settings,
            catalog: settingsCatalog
        )
        let liveTabs = orderedLiveWorkspaceCreationTabs(from: snapshot) ?? snapshot.tabs
        let pinnedCount = liveTabs.reduce(into: 0) { partial, tab in
            if tab.isPinned {
                partial += 1
            }
        }

        switch placement {
        case .top:
            return pinnedCount
        case .end:
            return liveTabs.count
        case .afterCurrent:
            if let selectedTabId = snapshot.selectedTabId,
               let selectedIndex = liveTabs.firstIndex(where: { $0.id == selectedTabId }) {
                return placement.insertionIndex(
                    selectedIndex: selectedIndex,
                    selectedIsPinned: snapshot.selectedTabWasPinned,
                    pinnedCount: pinnedCount,
                    totalCount: liveTabs.count
                )
            }
            return snapshot.selectedTabWasPinned ? pinnedCount : liveTabs.count
        }
    }

    private func preferredWorkingDirectoryForNewTab() -> String? {
        preferredWorkingDirectoryForNewTab(workspace: selectedWorkspace)
    }

    func preferredWorkingDirectoryForNewTab(
        workspace: Workspace?
    ) -> String? {
        guard let workspace else {
            return nil
        }
        // Use cached directory state only; avoiding live focus traversal keeps workspace
        // creation resilient when Bonsplit is in the middle of a rapid Cmd+N churn.
        if let currentDirectory = normalizedWorkingDirectory(workspace.currentDirectory) {
            return currentDirectory
        }

        return workspace.panelDirectories.values.lazy.compactMap { directory in
            self.normalizedWorkingDirectory(directory)
        }.first
    }

    func implicitWorkingDirectoryForNewWorkspace(from sourceWorkspace: Workspace?) -> String? {
        guard settings.value(for: settingsCatalog.app.workspaceInheritWorkingDirectory) else {
            return nil
        }
        return preferredWorkingDirectoryForNewTab(workspace: sourceWorkspace)
    }

    // MARK: - Reordering (WorkspaceReorderCoordinator, CmuxWorkspaces)

    func moveTabToTop(_ tabId: UUID) {
        workspaceReordering.moveTabToTop(tabId)
    }

    func moveTabsToTop(_ tabIds: Set<UUID>) {
        workspaceReordering.moveTabsToTop(tabIds)
    }

    func setNotificationAutoReorderPolicy(
        summaryPriorityEnabled: Bool,
        selectedSort: WorkspaceSidebarSummaryPrioritySort
    ) {
        let nextAllowed = !summaryPriorityEnabled || selectedSort.isNative
        guard notificationAutoReorderAllowedBySort != nextAllowed else { return }
        notificationAutoReorderAllowedBySort = nextAllowed
    }

    func moveTabToTopForNotification(_ tabId: UUID) {
        guard notificationAutoReorderAllowedBySort else { return }
        workspaceReordering.moveTabToTopForNotification(tabId)
    }

    @discardableResult
    func reorderWorkspace(tabId: UUID, toIndex targetIndex: Int, isDragOperation: Bool = false) -> Bool {
        // Capture the plan before the coordinator mutates the model so the
        // plus sort-assistant integration can record the actual move.
        let plan = workspaceReorderPlan(tabId: tabId, toIndex: targetIndex)
        let didReorder = workspaceReordering.reorderWorkspace(
            tabId: tabId,
            toIndex: targetIndex,
            isDragOperation: isDragOperation
        )
        if didReorder, let plan, plan.fromIndex != plan.toIndex {
            Task { @MainActor in
                SortAssistantCoordinator.shared.recordUserDragMove(
                    itemId: tabId,
                    fromIndex: plan.fromIndex,
                    toIndex: plan.toIndex,
                    revision: 0,
                    reason: "workspace_reorder"
                )
            }
        }
        return didReorder
    }

    func sidebarReorderWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> [UUID] {
        workspaceReordering.sidebarReorderWorkspaceIds(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    func sidebarReorderPinnedWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> Set<UUID> {
        workspaceReordering.sidebarReorderPinnedWorkspaceIds(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    func sidebarReorderLegalInsertionRange(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID? = nil,
        usesTopLevelRows: Bool = false
    ) -> ClosedRange<Int>? {
        workspaceReordering.sidebarReorderLegalInsertionRange(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    @discardableResult
    func reorderSidebarWorkspace(
        tabId: UUID,
        toIndex targetIndex: Int,
        isDragOperation: Bool = false,
        usesTopLevelRows: Bool = false
    ) -> Bool {
        workspaceReordering.reorderSidebarWorkspace(
            tabId: tabId,
            toIndex: targetIndex,
            isDragOperation: isDragOperation,
            usesTopLevelRows: usesTopLevelRows
        )
    }

    func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?
    ) -> Bool {
        workspaceReordering.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId
        )
    }

    func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    ) -> Bool {
        workspaceReordering.sidebarReorderUsesTopLevelRows(
            forDraggedWorkspaceId: draggedWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            workspaceGroupIdByWorkspaceId: workspaceGroupIdByWorkspaceId
        )
    }

    func workspaceReorderPlan(tabId: UUID, toIndex targetIndex: Int) -> WorkspaceReorderPlanItem? {
        workspaceReordering.workspaceReorderPlan(tabId: tabId, toIndex: targetIndex)
    }

    /// Legacy `postWorkspaceOrderDidChange`: NotificationCenter + app event
    /// bus publication (WorkspaceOrderHosting; the reorder/group
    /// coordinators invert observable order-change publication through
    /// this hook).
    func workspaceOrderDidChange(movedWorkspaceIds: [UUID]) {
        guard !movedWorkspaceIds.isEmpty else { return }
        NotificationCenter.default.post(
            name: .workspaceOrderDidChange,
            object: self,
            userInfo: [WorkspaceOrderChangeNotificationKey.movedWorkspaceIds: movedWorkspaceIds]
        )
        CmuxEventBus.shared.publishWorkspaceReordered(
            workspaceIds: tabs.map(\.id),
            movedWorkspaceIds: movedWorkspaceIds,
            pinnedWorkspaceIds: tabs.filter(\.isPinned).map(\.id),
            source: "workspace.lifecycle"
        )
    }

    @discardableResult
    func reorderWorkspace(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil, isDragOperation: Bool = false) -> Bool {
        workspaceReordering.reorderWorkspace(tabId: tabId, before: beforeId, after: afterId, isDragOperation: isDragOperation)
    }

    func workspaceReorderPlan(tabId: UUID, before beforeId: UUID? = nil, after afterId: UUID? = nil) -> WorkspaceReorderPlanItem? {
        workspaceReordering.workspaceReorderPlan(tabId: tabId, before: beforeId, after: afterId)
    }

    func workspaceBatchReorderPlan(
        orderedWorkspaceIds: [UUID]
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        workspaceReordering.workspaceBatchReorderPlan(orderedWorkspaceIds: orderedWorkspaceIds)
    }

    @discardableResult
    func reorderWorkspaces(
        orderedWorkspaceIds: [UUID],
        dryRun: Bool = false
    ) -> Result<[WorkspaceReorderPlanItem], WorkspaceBatchReorderError> {
        workspaceReordering.reorderWorkspaces(orderedWorkspaceIds: orderedWorkspaceIds, dryRun: dryRun)
    }

    private func batchWorkspaceReorderFinalIds(orderedWorkspaceIds: [UUID]) -> [UUID] {
        let orderedSet = Set(orderedWorkspaceIds)
        let workspacesById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let orderedPinnedIds = orderedWorkspaceIds.filter { workspacesById[$0]?.isPinned == true }
        let orderedUnpinnedIds = orderedWorkspaceIds.filter { workspacesById[$0]?.isPinned == false }
        let remainingPinnedIds = tabs
            .map(\.id)
            .filter { !orderedSet.contains($0) && workspacesById[$0]?.isPinned == true }
        let remainingUnpinnedIds = tabs
            .map(\.id)
            .filter { !orderedSet.contains($0) && workspacesById[$0]?.isPinned == false }
        return orderedPinnedIds + remainingPinnedIds + orderedUnpinnedIds + remainingUnpinnedIds
    }

    @discardableResult
    func reorderWorkspaces(to prioritizedWorkspaceIds: [UUID]) -> Bool {
        guard tabs.count > 1 else { return true }

        var rankByWorkspaceId: [UUID: Int] = [:]
        for workspaceId in prioritizedWorkspaceIds where rankByWorkspaceId[workspaceId] == nil {
            rankByWorkspaceId[workspaceId] = rankByWorkspaceId.count
        }
        guard !rankByWorkspaceId.isEmpty else { return false }

        let nextTabs = Self.summaryPriorityOrderedWorkspaces(
            tabs,
            rankByWorkspaceId: rankByWorkspaceId
        )
        guard nextTabs.map(\.id) != tabs.map(\.id) else { return true }

        tabs = nextTabs
        return true
    }

    private static func summaryPriorityOrderedWorkspaces(
        _ workspaces: [Workspace],
        rankByWorkspaceId: [UUID: Int]
    ) -> [Workspace] {
        let indexed = workspaces.enumerated().map { index, workspace in
            (index: index, workspace: workspace)
        }

        func ordered(_ entries: [(index: Int, workspace: Workspace)]) -> [Workspace] {
            entries.sorted { lhs, rhs in
                let lhsRank = rankByWorkspaceId[lhs.workspace.id]
                let rhsRank = rankByWorkspaceId[rhs.workspace.id]
                switch (lhsRank, rhsRank) {
                case let (lhsRank?, rhsRank?):
                    if lhsRank != rhsRank { return lhsRank < rhsRank }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                return lhs.index < rhs.index
            }
            .map(\.workspace)
        }

        let pinned = indexed.filter { $0.workspace.isPinned }
        let unpinned = indexed.filter { !$0.workspace.isPinned }
        return ordered(pinned) + ordered(unpinned)
    }

    /// Sets, replaces, or clears a workspace custom title. Returns whether the
    /// write landed (`.auto` writes are rejected over user-set titles; see
    /// ``Workspace/setCustomTitle(_:source:)``).
    @discardableResult
    func setCustomTitle(tabId: UUID, title: String?, source: Workspace.CustomTitleSource = .user) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
        let applied = tabs[index].setCustomTitle(title, source: source)
        if applied, selectedTabId == tabId {
            updateWindowTitle(for: tabs[index])
        }
        // A remote tmux mirror workspace rename propagates to `rename-session`,
        // but only when the write landed (an `.auto` write rejected over a
        // user-set title must not desync the remote session name).
        if applied, tabs[index].isRemoteTmuxMirror {
            AppDelegate.shared?.remoteTmuxController.handleMirrorWorkspaceRenamed(
                workspaceId: tabId, title: title
            )
        }
        return applied
    }

    func clearCustomTitle(tabId: UUID) {
        setCustomTitle(tabId: tabId, title: nil)
    }

    func setCustomDescription(tabId: UUID, description: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[index].setCustomDescription(description)
    }

    func clearCustomDescription(tabId: UUID) {
        setCustomDescription(tabId: tabId, description: nil)
    }

    func setTabColor(tabId: UUID, color: String?) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.setCustomColor(color)
    }

    func applyWorkspaceColor(_ color: String?, toWorkspaceIds workspaceIds: [UUID]) {
        guard !workspaceIds.isEmpty else { return }
        if workspaceIds.count == 1, let workspaceId = workspaceIds.first {
            setTabColor(tabId: workspaceId, color: color)
            return
        }

        let targetIds = Set(workspaceIds)
        for tab in tabs where targetIds.contains(tab.id) {
            tab.setCustomColor(color)
        }
    }

    func clearWorkspaceColors() {
        let ids = tabs.compactMap { $0.customColor != nil ? $0.id : nil }
        applyWorkspaceColor(nil, toWorkspaceIds: ids)
    }

    func applyWorkspacePaletteColor(named name: String, toWorkspaceIds workspaceIds: [UUID]) {
        guard let color = WorkspaceTabColorSettings.currentColorHex(named: name) else { return }
        applyWorkspaceColor(color, toWorkspaceIds: workspaceIds)
    }

    func setWorkspaceTerminalScrollBarHidden(tabId: UUID, hidden: Bool) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.setTerminalScrollBarHidden(hidden)
    }

    func setWorkspaceTerminalScrollBarHidden(hidden: Bool, forWorkspaceIds workspaceIds: [UUID]) {
        guard !workspaceIds.isEmpty else { return }
        if workspaceIds.count == 1, let workspaceId = workspaceIds.first {
            setWorkspaceTerminalScrollBarHidden(tabId: workspaceId, hidden: hidden)
            return
        }

        let targetIds = Set(workspaceIds)
        for tab in tabs where targetIds.contains(tab.id) {
            tab.setTerminalScrollBarHidden(hidden)
        }
    }

    func togglePin(tabId: UUID) {
        workspaceReordering.togglePin(tabId: tabId)
    }

    func setPinned(_ tab: Workspace, pinned: Bool) {
        workspaceReordering.setPinned(tab, pinned: pinned)
    }

    @discardableResult
    func setPinned(workspaceIds: [UUID], pinned: Bool) -> [UUID] {
        workspaceReordering.setPinned(workspaceIds: workspaceIds, pinned: pinned)
    }

    // MARK: - Workspace Groups (WorkspaceGroupCoordinator, CmuxWorkspaces)

    @discardableResult
    func createWorkspaceGroup(
        name: String,
        childWorkspaceIds: [UUID] = [],
        anchorWorkingDirectory: String? = nil,
        selectAnchor: Bool = true,
        collapseSidebarSelection: Bool = true
    ) -> UUID? {
        workspaceGrouping.createWorkspaceGroup(
            name: name,
            childWorkspaceIds: childWorkspaceIds,
            anchorWorkingDirectory: anchorWorkingDirectory,
            selectAnchor: selectAnchor,
            collapseSidebarSelection: collapseSidebarSelection
        )
    }

    @discardableResult
    func createWorkspaceInGroup(
        groupId: UUID,
        placement explicitPlacement: WorkspaceGroupNewPlacement? = nil,
        referenceWorkspaceId: UUID? = nil,
        select: Bool = true,
        initialSurface: NewWorkspaceInitialSurface = .terminal
    ) -> Workspace? {
        workspaceGrouping.createWorkspaceInGroup(
            groupId: groupId,
            placement: explicitPlacement,
            referenceWorkspaceId: referenceWorkspaceId,
            select: select,
            initialSurface: initialSurface
        )
    }

    func addWorkspaceToGroup(
        workspaceId: UUID,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement? = nil,
        referenceWorkspaceId: UUID? = nil
    ) {
        workspaceGrouping.addWorkspaceToGroup(
            workspaceId: workspaceId,
            groupId: groupId,
            placement: placement,
            referenceWorkspaceId: referenceWorkspaceId
        )
    }

    func removeWorkspaceFromGroup(workspaceId: UUID) {
        workspaceGrouping.removeWorkspaceFromGroup(workspaceId: workspaceId)
    }

    func ungroupWorkspaceGroup(groupId: UUID) {
        workspaceGrouping.ungroupWorkspaceGroup(groupId: groupId)
    }

    @discardableResult
    func deleteWorkspaceGroup(groupId: UUID, recordHistory: Bool = true) -> Int {
        workspaceGrouping.deleteWorkspaceGroup(groupId: groupId, recordHistory: recordHistory)
    }

    func renameWorkspaceGroup(groupId: UUID, name: String) {
        workspaceGrouping.renameWorkspaceGroup(groupId: groupId, name: name)
    }

    func toggleWorkspaceGroupCollapsed(groupId: UUID) {
        workspaceGrouping.toggleWorkspaceGroupCollapsed(groupId: groupId)
    }

    func setWorkspaceGroupCollapsed(groupId: UUID, isCollapsed: Bool) {
        workspaceGrouping.setWorkspaceGroupCollapsed(groupId: groupId, isCollapsed: isCollapsed)
    }

    func toggleWorkspaceGroupPinned(groupId: UUID) {
        workspaceGrouping.toggleWorkspaceGroupPinned(groupId: groupId)
    }

    func setWorkspaceGroupPinned(groupId: UUID, isPinned: Bool) {
        workspaceGrouping.setWorkspaceGroupPinned(groupId: groupId, isPinned: isPinned)
    }

    func setWorkspaceGroupColor(groupId: UUID, hex: String?) {
        workspaceGrouping.setWorkspaceGroupColor(groupId: groupId, hex: hex)
    }

    @discardableResult
    func setWorkspaceGroupIcon(groupId: UUID, symbol: String?) -> String? {
        workspaceGrouping.setWorkspaceGroupIcon(groupId: groupId, symbol: symbol)
    }

    func setWorkspaceGroupAnchor(groupId: UUID, workspaceId: UUID) {
        workspaceGrouping.setWorkspaceGroupAnchor(groupId: groupId, workspaceId: workspaceId)
    }

    func moveWorkspaceGroup(groupId: UUID, toIndex targetIndex: Int) {
        workspaceGrouping.moveWorkspaceGroup(groupId: groupId, toIndex: targetIndex)
    }

    /// Compatibility shim. With anchor-bound group lifecycle, "empty" groups
    /// are no longer possible — a group exists iff its anchor exists in
    /// `tabs[]`.
    func pruneEmptyWorkspaceGroups() {}

    // MARK: - WorkspaceGroupHosting (effects the group coordinator inverts)

    func createGroupAnchorWorkspace(
        title: String,
        workingDirectory: String?,
        inheritWorkingDirectory: Bool,
        select: Bool
    ) -> Workspace {
        addWorkspace(
            title: title,
            workingDirectory: workingDirectory,
            inheritWorkingDirectory: inheritWorkingDirectory,
            select: select,
            placementOverride: .top,
            autoWelcomeIfNeeded: false,
            normalizeWorkspaceGroupsAfterInsert: false
        )
    }

    func createWorkspaceForGroup(
        workingDirectory: String?,
        initialSurface: NewWorkspaceInitialSurface,
        inheritWorkingDirectory: Bool,
        select: Bool
    ) -> Workspace {
        addWorkspace(
            workingDirectory: workingDirectory,
            initialSurface: initialSurface,
            inheritWorkingDirectory: inheritWorkingDirectory,
            select: select,
            autoWelcomeIfNeeded: false
        )
    }

    func closeWorkspaceForGroupDeletion(_ tab: Workspace, recordHistory: Bool) {
        closeWorkspace(tab, recordHistory: recordHistory)
    }

    func collapseSidebarSelectionForGroupCreation(
        hiddenWorkspaceIds: Set<UUID>,
        anchorId: UUID
    ) {
        sidebarMultiSelection.replaceSelection(with: [anchorId])
        sidebarMultiSelection.postDidHide(hiddenWorkspaceIds: hiddenWorkspaceIds, focusedWorkspaceId: anchorId)
    }

    func subtractSidebarSelection(
        hiddenWorkspaceIds: Set<UUID>,
        focusedWorkspaceId: UUID?
    ) {
        sidebarMultiSelection.subtractSelection(hiddenWorkspaceIds)
        sidebarMultiSelection.postDidHide(
            hiddenWorkspaceIds: hiddenWorkspaceIds,
            focusedWorkspaceId: focusedWorkspaceId
        )
    }

    var localizedAutoGroupNameFormat: String {
        String(
            localized: "workspaceGroup.autoName.numbered",
            defaultValue: "Group %lld"
        )
    }

    var defaultNewWorkspacePlacementInGroup: WorkspaceGroupNewPlacement {
        settings.value(for: settingsCatalog.workspaceGroups.newWorkspacePlacement)
    }

    func normalizedGroupIconSymbol(_ symbol: String?) -> String? {
        RenderableSystemSymbol.normalized(symbol)
    }

    func workspaceGroupNameDidChange() {
        updateWindowTitleForSelectedTab()
        NotificationCenter.default.post(name: .workspaceGroupNameDidChange, object: self)
    }

    // MARK: - Surface Directory Updates (Backwards Compatibility)

    func updateSurfaceDirectory(tabId: UUID, surfaceId: UUID, directory: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let previousDirectory = gitProbeDirectory(for: tab, panelId: surfaceId)
        let normalized = normalizeDirectory(directory)
        guard tab.updatePanelDirectory(panelId: surfaceId, directory: normalized) else { return }
        let nextDirectory = normalizedWorkingDirectory(normalized)
        if previousDirectory != nextDirectory {
            let probeKey = WorkspaceGitProbeKey(workspaceId: tabId, panelId: surfaceId)
            removeWorkspacePullRequestShellRefreshProbeKey(probeKey)
            guard sidebarGitMetadataWatchEnabled else {
                clearWorkspaceGitMetadata(for: probeKey)
                return
            }
            scheduleWorkspacePullRequestRefresh(
                workspaceId: tabId,
                panelId: surfaceId,
                reason: "directoryChange"
            )
            scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: tabId,
                panelId: surfaceId,
                reason: "directoryChange"
            )
        }
    }

    func updateSurfaceGitBranch(
        tabId: UUID,
        surfaceId: UUID,
        branch: String,
        isDirty: Bool?
    ) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let probeKey = WorkspaceGitProbeKey(workspaceId: tabId, panelId: surfaceId)
        guard sidebarGitMetadataWatchEnabled else {
            clearWorkspaceGitMetadata(for: probeKey)
            return
        }
        let current = tab.panelGitBranches[surfaceId]
        let normalizedBranch = GitMetadataService.normalizedBranchName(branch) ?? branch
        let nextIsDirty = isDirty ?? (current?.branch == normalizedBranch ? current?.isDirty ?? false : false)
        guard current?.branch != normalizedBranch || current?.isDirty != nextIsDirty else { return }
        tab.updatePanelGitBranch(panelId: surfaceId, branch: normalizedBranch, isDirty: nextIsDirty)
        removeWorkspacePullRequestShellRefreshProbeKey(probeKey)
        if let directory = gitProbeDirectory(for: tab, panelId: surfaceId) {
            workspaceGitTrackedDirectoryByKey[probeKey] = directory
            updateWorkspaceGitMetadataWatcher(for: probeKey, directory: directory)
            updateWorkspaceGitMetadataFallbackTimer()
        }
        scheduleWorkspacePullRequestRefresh(
            workspaceId: tabId,
            panelId: surfaceId,
            reason: "branchChange"
        )
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: tabId,
            panelId: surfaceId,
            reason: "branchChange"
        )
    }

    func clearSurfaceGitBranch(tabId: UUID, surfaceId: UUID) {
        sidebarGitMetadataService.clearSurfaceGitBranch(workspaceId: tabId, panelId: surfaceId)
    }

    func updateSurfaceShellActivity(
        tabId: UUID,
        surfaceId: UUID,
        state: PanelShellActivityState
    ) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.updatePanelShellActivityState(panelId: surfaceId, state: state)
        if state == .promptIdle {
            pullRequestProbing.scheduleWorkspacePullRequestRefresh(
                workspaceId: tabId,
                panelId: surfaceId,
                reason: "shellPrompt"
            )
        }
    }

    func handleWorkspacePullRequestCommandHint(
        tabId: UUID,
        surfaceId: UUID,
        action: String,
        target: String?
    ) {
        pullRequestProbing.handleWorkspacePullRequestCommandHint(
            workspaceId: tabId,
            panelId: surfaceId,
            action: action,
            target: target
        )
    }


    func closeWorkspace(_ workspace: Workspace, recordHistory: Bool = true) {
        guard tabs.count > 1 else { return }
        sentryBreadcrumb("workspace.close", data: ["tabCount": tabs.count - 1])
        // User-initiated close of a mirrored remote tmux session kills it on the
        // remote. (App quit tears down windows without calling closeWorkspace, so
        // quitting still leaves remote sessions alive.)
        if workspace.isRemoteTmuxMirror {
            AppDelegate.shared?.remoteTmuxController.handleWorkspaceClosed(workspaceId: workspace.id)
        }
        if recordHistory,
           workspace.isRestorableInSessionSnapshot,
           let index = tabs.firstIndex(where: { $0.id == workspace.id }) {
            // Prefer the warm cached agent index over a synchronous
            // RestorableAgentSessionIndex.load() (sysctl-per-record + disk) so closing a
            // workspace does not freeze the main thread; fall back to a fresh load only
            // while the cache has not loaded yet. See closedPanelHistoryEntry.
            let snapshot = workspace.sessionSnapshot(
                includeScrollback: true,
                restorableAgentIndex: SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
                    ?? RestorableAgentSessionIndex.load()
            )
            ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: workspace.id,
                windowId: AppDelegate.shared?.windowId(for: self),
                workspaceIndex: index,
                snapshot: snapshot
            )))
        }
        clearWorkspaceGitProbes(workspaceId: workspace.id)
        clearWorkspacePullRequestTracking(workspaceId: workspace.id)
        sortAssistantWorkspaceDidClose(workspace.id)
        sidebarMultiSelection.removeFromSelection(workspace.id)
        invalidateFocusHistoryTarget(workspaceId: workspace.id, panelId: nil)

        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspace.id)
        workspace.withClosedPanelHistorySuppressed {
            workspace.teardownAllPanels()
        }
        workspace.teardownRemoteConnection()
        unwireClosedBrowserTracking(for: workspace)
        browserModel.removeClosedBrowserPanels(forWorkspaceId: workspace.id)
        workspace.owningTabManager = nil

        if let index = tabs.firstIndex(where: { $0.id == workspace.id }) {
            tabs.remove(at: index)
            // Real-close path: if the closed workspace anchored a group, the
            // group dissolves now and its remaining members survive as
            // ungrouped workspaces. This lives at the explicit close site (not
            // in the tabs didSet) so transient remove/insert reorders never
            // trigger dissolve.
            workspaces.dissolveGroupsAnchoredBy(closedWorkspaceId: workspace.id)

            if selectedTabId == workspace.id {
                // Keep the "focused index" stable when possible:
                // - If we closed workspace i and there is still a workspace at index i, focus it (the one that moved up).
                // - Otherwise (we closed the last workspace), focus the new last workspace (i-1).
                let newIndex = min(index, max(0, tabs.count - 1))
                selectedTabId = tabs[newIndex].id
            }
        }
        publishCmuxWorkspaceClosed(workspace)
    }


    /// Detach a workspace from this window without closing its panels.
    /// Used by the socket API for cross-window moves.
    @discardableResult
    func detachWorkspace(tabId: UUID) -> Workspace? {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        sidebarGitMetadataService.clearWorkspaceGitProbes(workspaceId: tabId)
        sidebarMultiSelection.removeFromSelection(tabId)
        invalidateFocusHistoryTarget(workspaceId: tabId, panelId: nil)

        let removed = tabs.remove(at: index)
        // Same anchor-close lifecycle as closeWorkspace: detaching a group's
        // anchor dissolves the group; non-anchor members stay in tabs as
        // ungrouped workspaces.
        workspaces.dissolveGroupsAnchoredBy(closedWorkspaceId: removed.id)
        // Clear the detached workspace's own group membership so the
        // destination window — which has no matching WorkspaceGroup — doesn't
        // render it as an orphaned indented row with stale grouping state.
        removed.groupId = nil
        unwireClosedBrowserTracking(for: removed)
        browserModel.removeClosedBrowserPanels(forWorkspaceId: removed.id)
        removed.owningTabManager = nil
        lastFocusedPanelByTab.removeValue(forKey: removed.id)

        if tabs.isEmpty {
            // The UI assumes each window always has at least one workspace.
            _ = addWorkspace()
            return removed
        }

        if selectedTabId == removed.id {
            let nextIndex = min(index, max(0, tabs.count - 1))
            selectedTabId = tabs[nextIndex].id
        }

        return removed
    }

    /// Attach an existing workspace to this window.
    func attachWorkspace(_ workspace: Workspace, at index: Int? = nil, select: Bool = true) {
        workspace.owningTabManager = self
        wireClosedBrowserTracking(for: workspace)
        let insertIndex: Int = {
            guard let index else { return tabs.count }
            return max(0, min(index, tabs.count))
        }()
        tabs.insert(workspace, at: insertIndex)
        // A workspace moved in from another window arrives ungrouped (detach
        // clears `groupId`) and may be pinned, so an arbitrary insert index can
        // split a destination group's contiguous run or drop a pinned workspace
        // below unpinned ones. Re-run the same normalization every insertion
        // path uses so the destination's sidebar invariants — leading pinned
        // segment, contiguous group runs — hold regardless of the drop index.
        workspaces.normalizeWorkspaceGroupContiguity()
        if select {
            selectedTabId = workspace.id
        }
    }

    // Keep closeTab as convenience alias
    func closeTab(_ tab: Workspace) { closeWorkspace(tab) }
    func closeCurrentTabWithConfirmation() { closeCurrentWorkspaceWithConfirmation() }

    func closeCurrentWorkspace() {
        guard let selectedId = selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedId }) else { return }
        closeWorkspace(workspace)
    }

    func closeCurrentPanelWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closePanelInvocations")
#endif
        guard !closeConfirmationInFlight else { return }
        guard let selectedId = selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedId }) else { return }
        reconcileFocusedPanelFromFirstResponderForKeyboard()
        guard let focusedPanelId = shortcutCloseTargetPanelId(in: tab) else { return }
        closePanelWithConfirmation(tab: tab, panelId: focusedPanelId)
    }

    func canCloseOtherTabsInFocusedPane() -> Bool {
        closeOtherTabsInFocusedPanePlan() != nil
    }

    func closeOtherTabsInFocusedPaneWithConfirmation() {
        guard !closeConfirmationInFlight else { return }
        guard let plan = closeOtherTabsInFocusedPanePlan() else { return }

        if CloseTabWarningStore(defaults: .standard).shouldConfirmClose(requiresConfirmation: true, source: .shortcut) {
            let prompt = CloseOtherTabsConfirmationPrompt(titles: plan.titles)
            guard confirmClose(
                title: prompt.title,
                message: prompt.message,
                acceptCmdD: false
            ) else { return }
        }

        for panelId in plan.panelIds {
            plan.workspace.markCloseHistoryEligible(panelId: panelId)
            _ = plan.workspace.closePanel(panelId, force: true)
        }
    }

    func closeCurrentWorkspaceWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closeTabInvocations")
#endif
        guard !closeConfirmationInFlight else { return }
        let sidebarSelectionIds = orderedSidebarSelectedWorkspaceIds()
        if sidebarSelectionIds.count > 1 {
            closeWorkspacesWithConfirmation(sidebarSelectionIds, allowPinned: true)
            return
        }
        guard let selectedId = selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedId }) else { return }
        closeWorkspaceWithConfirmation(workspace)
    }

    func canCloseWorkspace(_ workspace: Workspace, allowPinned: Bool = false) -> Bool {
        allowPinned || !workspace.isPinned
    }

    @discardableResult
    func closeWorkspaceWithConfirmation(_ workspace: Workspace) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .workspace) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace)
        return true
    }

    @discardableResult
    func closeWorkspaceFromCloseTabGesture(_ workspace: Workspace) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .tabClose) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace, source: .tabClose)
        return true
    }

    @discardableResult
    func closeWorkspaceFromTabCloseButton(_ workspace: Workspace) -> Bool {
        if workspace.isPinned {
            guard confirmPinnedWorkspaceClose(source: .tabCloseButton) else { return false }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
            return true
        }
        closeWorkspaceIfRunningProcess(workspace, source: .tabCloseButton)
        return true
    }

    @discardableResult
    func closeWorkspaceWithConfirmation(tabId: UUID) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == tabId }) else { return false }
        return closeWorkspaceWithConfirmation(workspace)
    }

    func setSidebarSelectedWorkspaceIds(_ workspaceIds: Set<UUID>) {
        let existingIds = Set(tabs.map(\.id))
        sidebarMultiSelection.replaceSelection(with: workspaceIds.intersection(existingIds))
    }

    /// Marks the window's pending close as a tab/session close so a remote-tmux
    /// mirror among `workspaces` is KILLED (synced with tmux) on the close commit
    /// rather than detached. The single decision point for every close path that
    /// closes the whole window directly — the last-workspace branch of
    /// ``closeWorkspaceIfRunningProcess`` and the batch/anchor paths in
    /// ``closeWorkspacesWithConfirmation`` — so every explicit tab-close intent kills
    /// consistently. ``AppDelegate``'s `shouldClose`/`onClose` consume or clear the
    /// marker (veto vs commit).
    private func markRemoteTmuxKillOnWindowCloseIfNeeded(for workspaces: [Workspace]) {
        guard workspaces.contains(where: { $0.isRemoteTmuxMirror }),
              let windowId = AppDelegate.shared?.windowId(for: self) else { return }
        AppDelegate.shared?.remoteTmuxController.markKillSessionsOnWindowClose(windowId: windowId)
    }

    func closeWorkspacesWithConfirmation(_ workspaceIds: [UUID], allowPinned: Bool) {
        let workspaces = orderedClosableWorkspaces(workspaceIds, allowPinned: allowPinned)
        guard !workspaces.isEmpty else { return }
        guard workspaces.count > 1 else {
            closeWorkspaceFromCloseTabGesture(workspaces[0])
            return
        }

        let plan = closeWorkspacesPlan(for: workspaces)
        if shouldConfirmClose(requiresConfirmation: true, source: .tabClose) {
            guard confirmClose(
                title: plan.title,
                message: plan.message,
                acceptCmdD: plan.acceptCmdD
            ) else { return }
        }

        if plan.workspaces.count == tabs.count,
           let firstWorkspace = plan.workspaces.first {
            // Closing every tab is still an explicit tab/session close: kill the
            // remote-tmux session(s) on commit, not detach.
            markRemoteTmuxKillOnWindowCloseIfNeeded(for: plan.workspaces)
            if let window {
                window.performClose(nil)
                return
            }
            if AppDelegate.shared != nil {
                AppDelegate.shared?.closeMainWindowContainingTabId(firstWorkspace.id)
                return
            }
        }

        for workspace in plan.workspaces {
            guard tabs.contains(where: { $0.id == workspace.id }) else { continue }
            // Anchor-close confirms inside closeWorkspaceIfRunningProcess.
            // If the user cancels that dialog during a batch, abort the
            // whole batch — otherwise the loop keeps closing later items
            // even though the user said "no" to the dialog that was up.
            if let groupId = workspace.groupId,
               let group = workspaceGroups.first(where: { $0.id == groupId }),
               group.anchorWorkspaceId == workspace.id,
               !settings.value(for: settingsCatalog.workspaceGroups.anchorCloseSuppressed) {
                let otherMemberCount = tabs.reduce(0) { partial, tab in
                    tab.groupId == groupId && tab.id != workspace.id ? partial + 1 : partial
                }
                if !confirmAnchorWorkspaceClose(groupName: group.name, otherMemberCount: otherMemberCount) {
                    return
                }
                // Anchor confirmed (or suppressed); skip the inner re-prompt
                // by closing without going through closeWorkspaceIfRunningProcess.
                if tabs.count <= 1 {
                    // Still a tab/session close → kill the remote session on commit.
                    markRemoteTmuxKillOnWindowCloseIfNeeded(for: [workspace])
                    if let window {
                        window.performClose(nil)
                    } else {
                        AppDelegate.shared?.closeMainWindowContainingTabId(workspace.id)
                    }
                } else {
                    closeWorkspace(workspace)
                }
                continue
            }
            closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
        }
    }

    func selectWorkspace(_ workspace: Workspace) {
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("select", to: workspace.id)
#endif
        selectWorkspaceId(workspace.id, notificationDismissalContext: .explicitWorkspaceResume)
    }

    // Keep selectTab as convenience alias
    func selectTab(_ tab: Workspace) { selectWorkspace(tab) }

    var isCloseConfirmationInFlight: Bool { closeConfirmationInFlight }

    func beginCloseConfirmationSession() -> Bool {
        guard !closeConfirmationInFlight else { return false }
        closeConfirmationInFlight = true
        return true
    }

    func endCloseConfirmationSession() {
        DispatchQueue.main.async { [weak self] in
            self?.closeConfirmationInFlight = false
        }
    }

    func confirmClose(title: String, message: String, acceptCmdD: Bool) -> Bool {
        guard beginCloseConfirmationSession() else { return false }
        defer { endCloseConfirmationSession() }

        if let confirmCloseHandler {
            return confirmCloseHandler(title, message, acceptCmdD)
        }
        _ = acceptCmdD

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))

        if let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "\r"
            closeButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = closeButton
        }
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        #if DEBUG
        UITestRecorder.record([
            "closeConfirmationTitle": title,
            "closeConfirmationMessage": message,
        ])
        #endif

        return runCloseConfirmationAlert(alert) == .alertFirstButtonReturn
    }

    private func runCloseConfirmationAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        // Presentation (activate + sheet-on-main-window, else app-modal) is
        // shared with every other cmux dialog via `runCmuxModalAlert`. This
        // wrapper only adds the close-confirmation-specific UITest telemetry,
        // recorded from the presenter's actual path so the label can never
        // disagree with how the alert was really shown.
        return runCmuxModalAlert(
            alert,
            presentingWindow: closeConfirmationPresentingWindow()
        ) { presentation in
            #if DEBUG
            switch presentation {
            case .sheet(let hostWindow):
                // The sheet attaches after this hook returns, so read the
                // attachment on the next runloop turn (during the modal loop).
                DispatchQueue.main.async {
                    UITestRecorder.record([
                        "closeConfirmationPresentation": "sheet",
                        "closeConfirmationAttachedSheet": hostWindow.attachedSheet == nil ? "0" : "1",
                    ])
                }
            case .appModal(let hostWindowHadAttachedSheet):
                UITestRecorder.record([
                    "closeConfirmationPresentation": "appModal",
                    "closeConfirmationAttachedSheet": hostWindowHadAttachedSheet ? "1" : "0",
                ])
            }
            #endif
        }
    }

    private func closeConfirmationPresentingWindow() -> NSWindow? {
        cmuxMainWindowForModalPresentation(preferring: window)
    }

    private struct CloseOtherTabsInFocusedPanePlan {
        let workspace: Workspace
        let panelIds: [UUID]
        let titles: [String]
    }

    private struct CloseWorkspacesPlan {
        let workspaces: [Workspace]
        let title: String
        let message: String
        let acceptCmdD: Bool
    }

    private enum CloseConfirmationSource {
        case workspace
        case tabClose
        case tabCloseButton
    }

    private func closeOtherTabsInFocusedPanePlan() -> CloseOtherTabsInFocusedPanePlan? {
        guard let workspace = selectedWorkspace else { return nil }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }

        let tabsInPane = workspace.bonsplitController.tabs(inPane: paneId)
        guard !tabsInPane.isEmpty else { return nil }
        guard let selectedTabId = workspace.bonsplitController.selectedTab(inPane: paneId)?.id ?? tabsInPane.first?.id else {
            return nil
        }

        var targetPanelIds: [UUID] = []
        var targetTitles: [String] = []
        for tab in tabsInPane where tab.id != selectedTabId {
            guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
            if workspace.isPanelPinned(panelId) {
                continue
            }
            targetPanelIds.append(panelId)
            targetTitles.append(CloseOtherTabsConfirmationPrompt.displayTitle(workspace.panelTitle(panelId: panelId)))
        }

        guard !targetPanelIds.isEmpty else { return nil }
        return CloseOtherTabsInFocusedPanePlan(
            workspace: workspace,
            panelIds: targetPanelIds,
            titles: targetTitles
        )
    }

    private func orderedClosableWorkspaces(_ workspaceIds: [UUID], allowPinned: Bool) -> [Workspace] {
        let targetIds = Set(workspaceIds)
        return tabs.compactMap { workspace in
            guard targetIds.contains(workspace.id) else { return nil }
            guard allowPinned || !workspace.isPinned else { return nil }
            return workspace
        }
    }

    private func orderedSidebarSelectedWorkspaceIds() -> [UUID] {
        tabs.compactMap { workspace in
            sidebarSelectedWorkspaceIds.contains(workspace.id) ? workspace.id : nil
        }
    }

    private func closeWorkspacesPlan(for workspaces: [Workspace]) -> CloseWorkspacesPlan {
        let willCloseWindow = workspaces.count == tabs.count
        let title = willCloseWindow
            ? String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
            : String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?")
        let titleLines = workspaces
            .map { "• \(closeWorkspaceDisplayTitle($0.title))" }
            .joined(separator: "\n")
        let format = willCloseWindow
            ? String(
                localized: "dialog.closeWorkspacesWindow.message",
                defaultValue: "This will close the current window, its %1$lld workspaces, and all of their panels:\n%2$@"
            )
            : String(
                localized: "dialog.closeWorkspaces.message",
                defaultValue: "This will close %1$lld workspaces and all of their panels:\n%2$@"
            )
        let message = String(format: format, locale: .current, Int64(workspaces.count), titleLines)
        return CloseWorkspacesPlan(
            workspaces: workspaces,
            title: title,
            message: message,
            acceptCmdD: willCloseWindow
        )
    }

    private func closeWorkspaceDisplayTitle(_ title: String?) -> String {
        let collapsed = title?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let collapsed, !collapsed.isEmpty {
            return collapsed
        }
        return String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
    }

    private func closeWorkspaceIfRunningProcess(
        _ workspace: Workspace,
        requiresConfirmation: Bool = true,
        source: CloseConfirmationSource = .workspace
    ) {
        // Anchor-close ALWAYS prompts (subject to its own
        // workspaceGroups.anchorCloseSuppressed flag), regardless of
        // requiresConfirmation. Batch-close paths set requiresConfirmation=false
        // after their own generic prompt, but that generic prompt doesn't
        // mention group dissolution — silently ungrouping members during a
        // multi-close would be surprising. The "Don't ask again" toggle on
        // the anchor dialog is the user's opt-out.
        if let groupId = workspace.groupId,
           let group = workspaceGroups.first(where: { $0.id == groupId }),
           group.anchorWorkspaceId == workspace.id {
            let otherMemberCount = tabs.reduce(0) { partial, tab in
                tab.groupId == groupId && tab.id != workspace.id ? partial + 1 : partial
            }
            if !confirmAnchorWorkspaceClose(groupName: group.name, otherMemberCount: otherMemberCount) {
                return
            }
        }
        let willCloseWindow = tabs.count <= 1
        let needsCloseConfirmation = workspaceNeedsConfirmClose(workspace)
        if requiresConfirmation,
           shouldConfirmClose(requiresConfirmation: needsCloseConfirmation, source: source),
           !confirmClose(
               title: String(localized: "dialog.closeWorkspace.title", defaultValue: "Close workspace?"),
               message: String(localized: "dialog.closeWorkspace.message", defaultValue: "This will close the workspace and all of its panels."),
               acceptCmdD: willCloseWindow
           ) {
            return
        }
        if tabs.count <= 1 {
            // Last workspace in this window closes via the window-close path, but it
            // is still an explicit TAB/session close: for a remote-tmux mirror, mark
            // the close to KILL the session on commit (synced with tmux), even though
            // it also closes the app window. The marker is consumed on the (non-vetoed)
            // close commit, or cleared if the close is vetoed (single-window quit
            // warning) so a cancelled close never kills. A plain window/quit close
            // never sets it, so it detaches. Non-last workspaces kill via closeWorkspace.
            markRemoteTmuxKillOnWindowCloseIfNeeded(for: [workspace])
            if let window {
                window.performClose(nil)
            } else {
                AppDelegate.shared?.closeMainWindowContainingTabId(workspace.id)
            }
        } else {
            closeWorkspace(workspace)
        }
    }

    private func shouldConfirmClose(requiresConfirmation: Bool, source: CloseConfirmationSource) -> Bool {
        switch source {
        case .workspace:
            return requiresConfirmation
        case .tabClose:
            return CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
                requiresConfirmation: requiresConfirmation,
                source: .shortcut
            )
        case .tabCloseButton:
            return CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
                requiresConfirmation: requiresConfirmation,
                source: .tabCloseButton
            )
        }
    }

    /// Confirm before closing a workspace that is its group's anchor. Closing
    /// the anchor dissolves the group (other members survive ungrouped).
    /// "Don't ask again" sets the `workspaceGroups.anchorCloseSuppressed` flag.
    private func confirmAnchorWorkspaceClose(groupName: String, otherMemberCount: Int) -> Bool {
        if settings.value(for: settingsCatalog.workspaceGroups.anchorCloseSuppressed) {
            return true
        }
        // Do NOT acquire beginCloseConfirmationSession here. The standard
        // close confirmation path that runs immediately after (confirmClose())
        // gates itself with the same flag, and endCloseConfirmationSession
        // releases the flag asynchronously on the next main-queue turn — so
        // wrapping this dialog with begin/end would leave the flag set when
        // the inner confirmClose runs, causing it to return false and silently
        // refuse the close even after the user accepted both prompts.
        let title = String(
            localized: "dialog.closeAnchor.title",
            defaultValue: "Close this workspace?"
        )
        // Use printf-style format specifiers and String(format:) so the
        // catalog entry can substitute the group name and member count at
        // runtime. Embedding Swift `\(groupName)` interpolation in the
        // catalog `value` would render literal `\(groupName)` on lookup.
        let message: String
        if otherMemberCount == 0 {
            let format = String(
                localized: "dialog.closeAnchor.message.lone",
                defaultValue: "Closing this workspace will remove the group \u{201C}%@\u{201D}."
            )
            message = String.localizedStringWithFormat(format, groupName)
        } else if otherMemberCount == 1 {
            let format = String(
                localized: "dialog.closeAnchor.message.one",
                defaultValue: "Closing this workspace will ungroup \u{201C}%@\u{201D} and release 1 other workspace."
            )
            message = String.localizedStringWithFormat(format, groupName)
        } else {
            let format = String(
                localized: "dialog.closeAnchor.message.many",
                defaultValue: "Closing this workspace will ungroup \u{201C}%1$@\u{201D} and release %2$lld other workspaces."
            )
            message = String.localizedStringWithFormat(format, groupName, otherMemberCount)
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))
        let suppressionButton = NSButton(
            checkboxWithTitle: String(
                localized: "dialog.dontAskAgain",
                defaultValue: "Don\u{2019}t ask again"
            ),
            target: nil,
            action: nil
        )
        suppressionButton.state = .off
        alert.accessoryView = suppressionButton
        if let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "\r"
            closeButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = closeButton
        }
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        let response = runCloseConfirmationAlert(alert)
        guard response == .alertFirstButtonReturn else { return false }
        if suppressionButton.state == .on {
            settings.set(true, for: settingsCatalog.workspaceGroups.anchorCloseSuppressed)
        }
        return true
    }

    private func confirmPinnedWorkspaceClose(source: CloseConfirmationSource) -> Bool {
        guard shouldConfirmClose(requiresConfirmation: true, source: source) else { return true }
        return confirmClose(
            title: String(localized: "dialog.closePinnedWorkspace.title", defaultValue: "Close pinned workspace?"),
            message: String(
                localized: "dialog.closePinnedWorkspace.message",
                defaultValue: "This workspace is pinned. Closing it will close the workspace and all of its panels."
            ),
            acceptCmdD: tabs.count <= 1
        )
    }

    private func shouldCloseWorkspaceOnLastSurfaceShortcut(_ workspace: Workspace, panelId: UUID) -> Bool {
        // Stored under the legacy closeWorkspaceOnLastSurfaceShortcut key:
        // true means the Close shortcut closes the workspace on its last surface.
        settings.value(for: settingsCatalog.app.keepWorkspaceOpenWhenClosingLastSurface) &&
            workspace.panels.count <= 1 &&
            workspace.panels[panelId] != nil
    }

    private func closePanelWithConfirmation(tab: Workspace, panelId: UUID) {
        guard tab.panels[panelId] != nil else {
#if DEBUG
            cmuxDebugLog(
                "surface.close.shortcut.skip tab=\(tab.id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) reason=missingPanel"
            )
#endif
            return
        }

        let bonsplitTabCount = tab.bonsplitController.allPaneIds.reduce(0) { partial, paneId in
            partial + tab.bonsplitController.tabs(inPane: paneId).count
        }
        let panelKind: String = {
            guard let panel = tab.panels[panelId] else { return "missing" }
            if panel is TerminalPanel { return "terminal" }
            if panel is BrowserPanel { return "browser" }
            return String(describing: type(of: panel))
        }()
        let closesWorkspaceOnLastSurfaceShortcut = shouldCloseWorkspaceOnLastSurfaceShortcut(tab, panelId: panelId)
#if DEBUG
        cmuxDebugLog(
            "surface.close.shortcut.begin tab=\(tab.id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) kind=\(panelKind) " +
            "panelCount=\(tab.panels.count) bonsplitTabs=\(bonsplitTabCount) " +
            "closeWorkspaceOnLastSurface=\(closesWorkspaceOnLastSurfaceShortcut ? 1 : 0)"
        )
#endif

        // The last-surface shortcut preference only affects the Close Tab shortcut path.
        // The tab close button continues to use Workspace's explicit-close path when it
        // closes the last surface.
        if closesWorkspaceOnLastSurfaceShortcut,
           let surfaceId = tab.surfaceIdFromPanelId(panelId) {
            tab.markExplicitClose(surfaceId: surfaceId)
        }
        tab.markCloseHistoryEligible(panelId: panelId)
        let closed = tab.closePanel(panelId)
#if DEBUG
        cmuxDebugLog(
            "surface.close.shortcut tab=\(tab.id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) closed=\(closed ? 1 : 0) " +
            "panelsAfterCall=\(tab.panels.count)"
        )
#endif
    }

    private func shortcutCloseTargetPanelId(in workspace: Workspace) -> UUID? {
        if let focusedPanelId = workspace.focusedPanelId,
           workspace.panels[focusedPanelId] != nil {
            return focusedPanelId
        }

        if workspace.panels.count == 1 {
            return workspace.panels.keys.first
        }

        let candidatePane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first
        if let candidatePane,
           let selectedTabId = workspace.bonsplitController.selectedTab(inPane: candidatePane)?.id
                ?? workspace.bonsplitController.tabs(inPane: candidatePane).first?.id,
           let panelId = workspace.panelIdFromSurfaceId(selectedTabId),
           workspace.panels[panelId] != nil {
            return panelId
        }

        return nil
    }

    func closePanelWithConfirmation(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        closePanelWithConfirmation(tab: tab, panelId: surfaceId)
    }

    /// Runtime close requests from Ghostty should only ever target the specific surface.
    /// They must not escalate into workspace/window-close semantics for "last tab".
    func closeRuntimeSurfaceWithConfirmation(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        guard tab.panels[surfaceId] != nil else { return }

        let requiresConfirmation: Bool
        if let terminalPanel = tab.terminalPanel(for: surfaceId),
           tab.panelNeedsConfirmClose(panelId: surfaceId, fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()) {
            requiresConfirmation = true
        } else {
            requiresConfirmation = false
        }

        if CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
            requiresConfirmation: requiresConfirmation,
            source: .shortcut
        ) {
            guard confirmClose(
                title: String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
                message: String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab."),
                acceptCmdD: false
            ) else { return }
        }

        _ = tab.closePanel(surfaceId, force: true)
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id, surfaceId: surfaceId)
    }

    /// Runtime close requests from Ghostty without confirmation (e.g. child-exit).
    /// This path must only close the addressed surface and must never close the workspace window.
    func closeRuntimeSurface(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        guard tab.panels[surfaceId] != nil else { return }

#if DEBUG
        cmuxDebugLog(
            "surface.close.runtime tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) panelsBefore=\(tab.panels.count)"
        )
#endif

        // Keep AppKit first responder in sync with workspace focus before routing the close.
        // If split reparenting caused a temporary model/view mismatch, fallback close logic in
        // Workspace.closePanel uses focused selection to resolve the correct tab deterministically.
        reconcileFocusedPanelFromFirstResponderForKeyboard()
        let closed = tab.closePanel(surfaceId, force: true)
#if DEBUG
        cmuxDebugLog(
            "surface.close.runtime.done tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) closed=\(closed ? 1 : 0) panelsAfter=\(tab.panels.count)"
        )
#endif
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id, surfaceId: surfaceId)
    }

    /// Close a panel because its child process exited (e.g. the user hit Ctrl+D).
    ///
    /// This should never prompt: the process is already gone, and Ghostty emits the
    /// `SHOW_CHILD_EXITED` action specifically so the host app can decide what to do.
    func closePanelAfterChildExited(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        guard tab.panels[surfaceId] != nil else { return }
        let keepsPersistentRemoteSurfaceOpen =
            tab.shouldKeepPersistentRemoteSurfaceOpenAfterChildExit(surfaceId)
        if !keepsPersistentRemoteSurfaceOpen,
           tab.shouldDemoteWorkspaceAfterChildExit(surfaceId: surfaceId) {
            let relayPort: Int?
            if tab.remoteConfiguration?.transport == .ssh {
                relayPort = tab.remoteConfiguration?.relayPort
            } else {
                relayPort = nil
            }
            tab.markRemoteTerminalSessionEnded(
                surfaceId: surfaceId,
                relayPort: relayPort,
                allowUntracked: !tab.isRemoteTerminalSurface(surfaceId)
            )
        }
        let handlesRemoteExitThroughWorkspace =
            tab.panels.count <= 1 && tab.shouldDemoteWorkspaceAfterChildExit(surfaceId: surfaceId)

#if DEBUG
        cmuxDebugLog(
            "surface.close.childExited tab=\(tabId.uuidString.prefix(5)) " +
            "surface=\(surfaceId.uuidString.prefix(5)) panels=\(tab.panels.count) workspaces=\(tabs.count) " +
            "remoteWorkspace=\(tab.isRemoteWorkspace ? 1 : 0) keepRemote=\(handlesRemoteExitThroughWorkspace ? 1 : 0) " +
            "keepPersistentRemote=\(keepsPersistentRemoteSurfaceOpen ? 1 : 0)"
        )
#endif

        // A persistent SSH workspace must never silently replace a failed remote attach with
        // a local login shell. Keep the exited surface visible so the user can see the error
        // and retry instead of making a detached remote workspace look local after relaunch.
        if keepsPersistentRemoteSurfaceOpen {
            tab.markPersistentRemotePTYAttachFailed(surfaceId: surfaceId)
            return
        }

        // Route the last remote child exit through Workspace close handling so remote teardown
        // and replacement-panel logic run before TabManager considers removing the workspace.
        if handlesRemoteExitThroughWorkspace {
            closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
            return
        }

        // Child-exit on the last panel should collapse the workspace, matching explicit close
        // semantics (and close the window when it was the last workspace).
        if tab.panels.count <= 1 {
            if tabs.count <= 1 {
                if let app = AppDelegate.shared {
                    app.notificationStore?.clearNotifications(forTabId: tabId)
                    app.closeMainWindowContainingTabId(tabId, recordHistory: false)
                } else {
                    // Headless/test fallback when no AppDelegate window context exists.
                    closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
                }
            } else {
                closeWorkspace(tab, recordHistory: false)
            }
            return
        }

        closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
    }

    private func workspaceNeedsConfirmClose(_ workspace: Workspace) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] == "1" {
            return true
        }
#endif
        return workspace.needsConfirmClose()
    }

    func titleForTab(_ tabId: UUID) -> String? {
        tabs.first(where: { $0.id == tabId })?.title
    }

    // MARK: - Panel/Surface ID Access

    /// Returns the focused panel ID for a tab (replaces focusedSurfaceId)
    func focusedPanelId(for tabId: UUID) -> UUID? {
        tabs.first(where: { $0.id == tabId })?.focusedPanelId
    }

    /// Returns the focused panel if it's a BrowserPanel, nil otherwise
    var focusedBrowserPanel: BrowserPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId else { return nil }
        return tab.panels[panelId] as? BrowserPanel
    }

    /// Returns the focused panel if it's a MarkdownPanel showing the rendered
    /// preview, nil otherwise. Zoom applies to the preview WKWebView, so the raw
    /// text-edit mode is deliberately excluded.
    var focusedMarkdownPanel: MarkdownPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId,
              let panel = tab.panels[panelId] as? MarkdownPanel,
              panel.displayMode == .preview else { return nil }
        return panel
    }

    @discardableResult
    func zoomInFocusedBrowser() -> Bool {
        focusedBrowserPanel?.zoomIn() ?? false
    }

    @discardableResult
    func zoomOutFocusedBrowser() -> Bool {
        focusedBrowserPanel?.zoomOut() ?? false
    }

    @discardableResult
    func resetZoomFocusedBrowser() -> Bool {
        focusedBrowserPanel?.resetZoom() ?? false
    }

    var canToggleBrowserFocusModeForFocusedBrowser: Bool {
        focusedBrowserPanel?.canToggleBrowserFocusMode == true
    }

    @discardableResult
    func toggleBrowserFocusModeForFocusedBrowser(reason: String) -> Bool {
        guard let browserPanel = focusedBrowserPanel else { return false }
        return browserPanel.toggleBrowserFocusMode(reason: reason, focusWebView: true)
    }

    @discardableResult
    func setFocusedBrowserFocusModeActive(_ active: Bool, reason: String) -> Bool {
        guard let browserPanel = focusedBrowserPanel else { return false }
        return browserPanel.setBrowserFocusModeActive(active, reason: reason, focusWebView: active)
    }

    @discardableResult
    func zoomInFocusedMarkdown() -> Bool {
        focusedMarkdownPanel?.zoomIn() ?? false
    }

    @discardableResult
    func zoomOutFocusedMarkdown() -> Bool {
        focusedMarkdownPanel?.zoomOut() ?? false
    }

    @discardableResult
    func resetZoomFocusedMarkdown() -> Bool {
        focusedMarkdownPanel?.resetZoom() ?? false
    }

    @discardableResult
    func toggleDeveloperToolsFocusedBrowser() -> Bool {
        focusedBrowserPanel?.toggleDeveloperTools() ?? false
    }

    @discardableResult
    func showJavaScriptConsoleFocusedBrowser() -> Bool {
        focusedBrowserPanel?.showDeveloperToolsConsole() ?? false
    }

    @discardableResult
    func toggleOmnibarFocusedBrowser() -> Bool {
        guard let panel = focusedBrowserPanel else { return false }
        panel.toggleOmnibarVisibility()
        return true
    }

    @discardableResult
    func toggleReactGrabFromCurrentFocus() -> Bool {
        guard let workspace = selectedWorkspace else { return false }
        return toggleReactGrab(in: workspace, browserSurfaceId: nil, returnTerminalSurfaceId: nil) != nil
    }

    /// Toggles React Grab for a specific workspace. When `browserSurfaceId`/`returnTerminalSurfaceId`
    /// are nil this mirrors the keyboard shortcut: it resolves the browser + return terminal from the
    /// focused panel layout. An explicit browser surface (must be a browser) or return terminal
    /// (must be a terminal) overrides that route. Used by both the Cmd+Shift+G shortcut and the
    /// `cmux browser react-grab toggle` CLI command so both share one action path.
    /// Returns the resolved browser surface id it acted on, or nil if it could not resolve/act
    /// (so callers can report the actual browser surface rather than the focused panel).
    @discardableResult
    func toggleReactGrab(
        in workspace: Workspace,
        browserSurfaceId: UUID?,
        returnTerminalSurfaceId: UUID?
    ) -> UUID? {
        let snapshots = workspace.panels.values.map { panel in
            ReactGrabShortcutPanelSnapshot(
                id: panel.id,
                panelType: panel.panelType,
                isFocused: panel.id == workspace.focusedPanelId
            )
        }
        let route = resolveReactGrabShortcutRoute(panels: snapshots)

        // Browser target: an explicit surface is authoritative (it must be a browser, no
        // fallback to a different browser); otherwise resolve the route's browser from focus.
        let browserPanelId: UUID?
        if let explicit = browserSurfaceId {
            guard workspace.browserPanel(for: explicit) != nil else { return nil }
            browserPanelId = explicit
        } else {
            browserPanelId = route?.browserPanelId
        }
        guard let browserPanelId else { return nil }

        // Return terminal: an explicit return surface is authoritative (must be a terminal in
        // this workspace, no fallback) so pasteback never silently goes to the wrong terminal.
        // With no explicit return, adopt the route's terminal only when the browser also came
        // from the route (matching shortcut semantics).
        let returnTerminalPanelId: UUID?
        if let explicit = returnTerminalSurfaceId {
            guard workspace.panels[explicit]?.panelType == .terminal else { return nil }
            returnTerminalPanelId = explicit
        } else if browserSurfaceId == nil {
            returnTerminalPanelId = route?.returnTerminalPanelId
        } else {
            returnTerminalPanelId = nil
        }

        let didToggle = performReactGrabToggle(
            in: workspace,
            browserPanelId: browserPanelId,
            returnTerminalPanelId: returnTerminalPanelId
        )
        return didToggle ? browserPanelId : nil
    }

    @discardableResult
    private func performReactGrabToggle(
        in workspace: Workspace,
        browserPanelId: UUID,
        returnTerminalPanelId: UUID?
    ) -> Bool {
        guard let browserPanel = workspace.browserPanel(for: browserPanelId) else { return false }

        if let returnTerminalPanelId {
            browserPanel.armReactGrabRoundTrip(returnTo: returnTerminalPanelId)
        } else {
            browserPanel.clearReactGrabRoundTrip(reason: "shortcut.noReturnTarget")
        }

        if workspace.focusedPanelId != browserPanel.id {
            workspace.clearSplitZoom()
            workspace.focusPanel(browserPanel.id)
        }

        let didRequestExplicitWebViewFocus = browserPanel.requestExplicitWebViewFocus()
#if DEBUG
        cmuxDebugLog(
            "reactGrab.pasteback h1.focusRequestResult " +
            "workspace=\(workspace.id.uuidString.prefix(5)) " +
            "browser=\(browserPanel.id.uuidString.prefix(5)) " +
            "return=\(returnTerminalPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil") " +
            "success=\(didRequestExplicitWebViewFocus ? 1 : 0)"
        )
#endif

        Task { @MainActor [weak browserPanel] in
            guard let browserPanel else { return }
            if returnTerminalPanelId != nil {
                await browserPanel.ensureReactGrabActive()
            } else {
                await browserPanel.toggleOrInjectReactGrab()
            }
            if !didRequestExplicitWebViewFocus {
                _ = browserPanel.requestExplicitWebViewFocus()
            }
        }
        return true
    }

    /// Backwards compatibility: returns the focused surface ID
    func focusedSurfaceId(for tabId: UUID) -> UUID? {
        focusedPanelId(for: tabId)
    }

    func rememberFocusedSurface(tabId: UUID, surfaceId: UUID) {
        lastFocusedPanelByTab[tabId] = surfaceId
    }

    func applyWindowBackgroundForSelectedTab() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let terminalPanel = tab.focusedTerminalPanel else { return }
        terminalPanel.applyWindowBackgroundIfActive()
    }

    func applyWindowBackdropModeForAllTabs(reason: String) {
        let backgroundColor = GhosttyApp.shared.defaultBackgroundColor
        let backgroundOpacity = GhosttyApp.shared.defaultBackgroundOpacity
        for tab in tabs {
            tab.applyGhosttyChrome(
                backgroundColor: backgroundColor,
                backgroundOpacity: backgroundOpacity,
                reason: reason
            )
        }
        applyWindowBackgroundForSelectedTab()
    }

    private func focusSelectedTabPanel(previousTabId: UUID?) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }

        let panelId: UUID
        if let restoredPanelId = lastFocusedPanelByTab[selectedTabId],
           tab.panels[restoredPanelId] != nil {
            panelId = restoredPanelId
        } else if let focusedPanelId = tab.focusedPanelId,
                  tab.panels[focusedPanelId] != nil {
            panelId = focusedPanelId
        } else {
            return
        }

        // Defer unfocusing the previous workspace's panel until ContentView confirms handoff
        // completion (new workspace has focus or timeout fallback), to avoid a visible freeze gap.
        if let previousTabId,
           let previousTab = tabs.first(where: { $0.id == previousTabId }),
           let previousPanelId = previousTab.focusedPanelId,
           previousTab.panels[previousPanelId] != nil {
            replacePendingWorkspaceUnfocusTarget(
                with: (tabId: previousTabId, panelId: previousPanelId)
            )
        }

        // Route workspace reactivation through the normal focus machinery so panel-local
        // activation intents like browser find-field focus are restored on return.
        tab.focusPanel(panelId)
    }

    func completePendingWorkspaceUnfocus(reason: String) {
        guard let pending = pendingWorkspaceUnfocusTarget else { return }
        // If this tab became selected again before handoff completion, drop the stale
        // pending entry so it cannot be flushed later and deactivate the selected workspace.
        guard Self.shouldUnfocusPendingWorkspace(
            pendingTabId: pending.tabId,
            selectedTabId: selectedTabId
        ) else {
            pendingWorkspaceUnfocusTarget = nil
#if DEBUG
            cmuxDebugLog(
                "ws.unfocus.drop tab=\(Self.debugShortWorkspaceId(pending.tabId)) panel=\(String(pending.panelId.uuidString.prefix(5))) reason=selected_again"
            )
#endif
            return
        }
        pendingWorkspaceUnfocusTarget = nil
        unfocusWorkspacePanel(tabId: pending.tabId, panelId: pending.panelId)
#if DEBUG
        if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            cmuxDebugLog(
                "ws.unfocus.complete id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) " +
                "tab=\(Self.debugShortWorkspaceId(pending.tabId)) panel=\(String(pending.panelId.uuidString.prefix(5))) reason=\(reason)"
            )
        } else {
            cmuxDebugLog(
                "ws.unfocus.complete id=none tab=\(Self.debugShortWorkspaceId(pending.tabId)) " +
                "panel=\(String(pending.panelId.uuidString.prefix(5))) reason=\(reason)"
            )
        }
#endif
    }

    private func replacePendingWorkspaceUnfocusTarget(with next: (tabId: UUID, panelId: UUID)) {
        if let current = pendingWorkspaceUnfocusTarget,
           current.tabId == next.tabId,
           current.panelId == next.panelId {
            return
        }

        if let current = pendingWorkspaceUnfocusTarget {
            // Never unfocus the currently selected workspace when replacing stale pending state.
            if Self.shouldUnfocusPendingWorkspace(
                pendingTabId: current.tabId,
                selectedTabId: selectedTabId
            ) {
                unfocusWorkspacePanel(tabId: current.tabId, panelId: current.panelId)
#if DEBUG
                cmuxDebugLog(
                    "ws.unfocus.flush tab=\(Self.debugShortWorkspaceId(current.tabId)) panel=\(String(current.panelId.uuidString.prefix(5))) reason=replaced"
                )
#endif
            } else {
#if DEBUG
                cmuxDebugLog(
                    "ws.unfocus.drop tab=\(Self.debugShortWorkspaceId(current.tabId)) panel=\(String(current.panelId.uuidString.prefix(5))) reason=replaced_selected"
                )
#endif
            }
        }

        pendingWorkspaceUnfocusTarget = next
#if DEBUG
        if let snapshot = debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            cmuxDebugLog(
                "ws.unfocus.defer id=\(snapshot.id) dt=\(Self.debugMsText(dtMs)) " +
                "tab=\(Self.debugShortWorkspaceId(next.tabId)) panel=\(String(next.panelId.uuidString.prefix(5)))"
            )
        } else {
            cmuxDebugLog(
                "ws.unfocus.defer id=none tab=\(Self.debugShortWorkspaceId(next.tabId)) panel=\(String(next.panelId.uuidString.prefix(5)))"
            )
        }
#endif
    }

    private func unfocusWorkspacePanel(tabId: UUID, panelId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let panel = tab.panels[panelId] else { return }
        panel.unfocus()
    }

    static func shouldUnfocusPendingWorkspace(pendingTabId: UUID, selectedTabId: UUID?) -> Bool {
        selectedTabId != pendingTabId
    }

    // MARK: Notification dismissal (CmuxNotifications)
    //
    // The dismissal decision flow lives in NotificationDismissalModel;
    // TabManager hosts its seam (TabManager+NotificationDismissalHosting)
    // and forwards the legacy entry points below.

    private func selectWorkspaceId(
        _ tabId: UUID,
        notificationDismissalContext: NotificationDismissalContext?
    ) {
        guard selectedTabId != tabId else {
            notificationDismissal.setPendingSelectionContext(nil)
            if let notificationDismissalContext {
                notificationDismissal.dismissFocusedPanelNotificationIfActive(
                    workspaceId: tabId,
                    context: notificationDismissalContext
                )
            }
            return
        }

        notificationDismissal.setPendingSelectionContext(notificationDismissalContext)
        selectedTabId = tabId
    }

    private func dismissFocusedPanelNotificationIfActive(
        tabId: UUID,
        context: NotificationDismissalContext = .activeFocus
    ) {
        notificationDismissal.dismissFocusedPanelNotificationIfActive(workspaceId: tabId, context: context)
    }

    private func dismissPanelNotificationOnFocus(tabId: UUID, panelId: UUID, explicitFocusIntent: Bool) {
        notificationDismissal.dismissPanelNotificationOnFocus(
            workspaceId: tabId,
            panelId: panelId,
            explicitFocusIntent: explicitFocusIntent
        )
    }

    @discardableResult
    func dismissNotificationOnDirectInteraction(tabId: UUID, surfaceId: UUID?) -> Bool {
        notificationDismissal.dismissNotificationOnDirectInteraction(workspaceId: tabId, surfaceId: surfaceId)
    }

    @discardableResult
    func dismissNotificationOnTerminalInteraction(tabId: UUID, surfaceId: UUID?) -> Bool {
        notificationDismissal.dismissNotificationOnTerminalInteraction(workspaceId: tabId, surfaceId: surfaceId)
    }


    private func enqueuePanelTitleUpdate(tabId: UUID, panelId: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
#if DEBUG
        cmuxDebugLog(
            "workspace.title.enqueue workspace=\(Self.debugShortWorkspaceId(tabId)) " +
            "panel=\(panelId.uuidString.prefix(5)) title=\"\(Self.debugTitlePreview(trimmed))\""
        )
#endif
        let key = PanelTitleUpdateKey(tabId: tabId, panelId: panelId)
        pendingPanelTitleUpdates[key] = trimmed
        panelTitleUpdateCoalescer.signal { [weak self] in
            self?.flushPendingPanelTitleUpdates()
        }
    }

    private func flushPendingPanelTitleUpdates() {
        guard !pendingPanelTitleUpdates.isEmpty else { return }
        let updates = pendingPanelTitleUpdates
        pendingPanelTitleUpdates.removeAll(keepingCapacity: true)
        for (key, title) in updates {
            updatePanelTitle(tabId: key.tabId, panelId: key.panelId, title: title)
        }
    }

    private func updatePanelTitle(tabId: UUID, panelId: UUID, title: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        _ = tab.updatePanelTitle(panelId: panelId, title: title)

        if tab.focusedPanelId == panelId {
            tab.applyProcessTitle(title)
            if selectedTabId == tabId {
                updateWindowTitle(for: tab)
            }
        }
    }

    func focusedSurfaceTitleDidChange(tabId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let focusedPanelId = tab.focusedPanelId,
              let title = tab.panelTitles[focusedPanelId] else { return }
        tab.applyProcessTitle(title)
        if selectedTabId == tabId {
            updateWindowTitle(for: tab)
        }
    }

    func focusTab(
        _ tabId: UUID,
        surfaceId: UUID? = nil,
        suppressFlash: Bool = false,
        focusIntent: PanelFocusIntent? = nil,
        dismissRestoredUnreadOnResume: Bool? = nil
    ) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let targetPanelId = surfaceId.flatMap { panelId(forSurfaceOrPanelId: $0, in: tab) }
        if let targetPanelId {
            // Keep selected-surface intent stable across selectedTabId didSet async restore.
            lastFocusedPanelByTab[tabId] = targetPanelId
        }
        let shouldDismissRestoredUnread = dismissRestoredUnreadOnResume ?? !suppressFlash
        let dismissalContext: NotificationDismissalContext? = shouldDismissRestoredUnread ? .explicitWorkspaceResume : nil
        let shouldDeferSelectedWorkspaceDismissal =
            selectedTabId == tabId &&
            targetPanelId.map { $0 != focusedPanelId(for: tabId) } == true
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("focus", to: tabId)
#endif
        selectWorkspaceId(
            tabId,
            notificationDismissalContext: shouldDeferSelectedWorkspaceDismissal ? nil : dismissalContext
        )
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: tabId]
        )

        if let surfaceId {
            let focusPanelId = targetPanelId ?? surfaceId
            if !suppressFlash {
                focusSurface(tabId: tabId, surfaceId: focusPanelId)
            } else {
                tab.focusPanel(focusPanelId, focusIntent: focusIntent)
            }
            if let dismissalContext {
                _ = notificationDismissal.dismissNotification(
                    workspaceId: tabId,
                    surfaceId: surfaceId,
                    context: dismissalContext
                )
            }
        }
    }

    @discardableResult
    func focusTabFromNotification(_ tabId: UUID, surfaceId: UUID? = nil) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else {
#if DEBUG
            cmuxDebugLog("notification.focus.fail tab=\(tabId.uuidString.prefix(5)) reason=missingTab")
#endif
            return false
        }
        if let surfaceId, tab.panels[surfaceId] == nil {
#if DEBUG
            cmuxDebugLog(
                "notification.focus.fail tab=\(tabId.uuidString.prefix(5)) " +
                "panel=\(surfaceId.uuidString.prefix(5)) reason=missingPanel"
            )
#endif
            return false
        }
        let desiredPanelId = surfaceId ?? tab.focusedPanelId
#if DEBUG
        if let desiredPanelId {
            AppDelegate.shared?.armJumpUnreadFocusRecord(tabId: tabId, surfaceId: desiredPanelId)
        }
#endif
        // Jump-to-unread should reveal the destination pane instead of keeping an old split-zoom
        // state active around it.
        tab.clearSplitZoom()
        notificationDismissal.setSuppressesFocusFlash(true)
        focusTab(tabId, surfaceId: desiredPanelId, suppressFlash: true)
        notificationDismissal.setSuppressesFocusFlash(false)

        if let targetPanelId = desiredPanelId ?? tab.focusedPanelId,
           tab.panels[targetPanelId] != nil {
            _ = dismissNotificationOnDirectInteraction(tabId: tabId, surfaceId: targetPanelId)
        }
        return true
    }

    func focusSurface(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.focusPanel(panelId(forSurfaceOrPanelId: surfaceId, in: tab) ?? surfaceId)
    }

    func panelId(forSurfaceOrPanelId surfaceOrPanelId: UUID, in workspace: Workspace) -> UUID? {
        if workspace.panels[surfaceOrPanelId] != nil {
            return surfaceOrPanelId
        }
        return workspace.panelIdFromSurfaceId(TabID(uuid: surfaceOrPanelId))
    }

    func selectNextTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
#if DEBUG
        let nextId = tabs[nextIndex].id
        debugPrepareWorkspaceSwitch("next", from: currentId, to: nextId)
#endif
        activateWorkspaceCycleHotWindow()
        selectWorkspaceId(
            tabs[nextIndex].id,
            notificationDismissalContext: .explicitWorkspaceResume
        )
        // Keyboard nav is an explicit "focus one workspace" gesture, so drop
        // any stale sidebar multi-selection (Shift-click range) so subsequent
        // batch actions don't operate on workspaces the user thought they
        // had unselected by moving on.
        clearSidebarMultiSelection(except: tabs[nextIndex].id)
    }

    func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
#if DEBUG
        let prevId = tabs[prevIndex].id
        debugPrepareWorkspaceSwitch("prev", from: currentId, to: prevId)
#endif
        activateWorkspaceCycleHotWindow()
        selectWorkspaceId(
            tabs[prevIndex].id,
            notificationDismissalContext: .explicitWorkspaceResume
        )
        clearSidebarMultiSelection(except: tabs[prevIndex].id)
    }

    /// Reduce sidebar multi-selection to a single workspace (or clear if
    /// `except` isn't a known tab). Called from keyboard-nav paths so a
    /// stale Shift-click range doesn't survive after the user moves focus.
    /// Posts the should-collapse event so the SwiftUI binding
    /// in ContentView (a @State Set<UUID> separate from this tab manager)
    /// can collapse to the focused workspace too.
    private func clearSidebarMultiSelection(except workspaceId: UUID) {
        sidebarMultiSelection.collapseSelection(
            to: workspaceId,
            isKnownWorkspace: tabs.contains(where: { $0.id == workspaceId })
        )
    }

    private func activateWorkspaceCycleHotWindow() {
        workspaceCycleGeneration &+= 1
        let generation = workspaceCycleGeneration
#if DEBUG
        let switchId = debugWorkspaceSwitchId
        let switchDtMs = debugWorkspaceSwitchStartTime > 0
            ? (CACurrentMediaTime() - debugWorkspaceSwitchStartTime) * 1000
            : 0
#endif
        if !isWorkspaceCycleHot {
            isWorkspaceCycleHot = true
#if DEBUG
            cmuxDebugLog(
                "ws.hot.on id=\(switchId) gen=\(generation) dt=\(Self.debugMsText(switchDtMs))"
            )
#endif
        }

        let hadPendingCooldown = workspaceCycleCooldownTask != nil
        workspaceCycleCooldownTask?.cancel()
#if DEBUG
        if hadPendingCooldown {
            cmuxDebugLog(
                "ws.hot.cancelPrev id=\(switchId) gen=\(generation) dt=\(Self.debugMsText(switchDtMs))"
            )
        }
#endif
        workspaceCycleCooldownTask = Task { [weak self, generation] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
#if DEBUG
                await MainActor.run {
                    guard let self else { return }
                    let dtMs = self.debugWorkspaceSwitchStartTime > 0
                        ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                        : 0
                    cmuxDebugLog(
                        "ws.hot.cooldownCanceled id=\(self.debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(dtMs))"
                    )
                }
#endif
                return
            }
            await MainActor.run {
                guard let self else { return }
                guard self.workspaceCycleGeneration == generation else { return }
#if DEBUG
                let dtMs = self.debugWorkspaceSwitchStartTime > 0
                    ? (CACurrentMediaTime() - self.debugWorkspaceSwitchStartTime) * 1000
                    : 0
                cmuxDebugLog(
                    "ws.hot.off id=\(self.debugWorkspaceSwitchId) gen=\(generation) dt=\(Self.debugMsText(dtMs))"
                )
#endif
                self.isWorkspaceCycleHot = false
                self.workspaceCycleCooldownTask = nil
            }
        }
    }

#if DEBUG
    func debugCurrentWorkspaceSwitchSnapshot() -> (id: UInt64, startedAt: CFTimeInterval)? {
        guard debugWorkspaceSwitchId > 0, debugWorkspaceSwitchStartTime > 0 else { return nil }
        return (debugWorkspaceSwitchId, debugWorkspaceSwitchStartTime)
    }

    func debugPrimeWorkspaceSwitchTrigger(_ trigger: String, to target: UUID?) {
        guard selectedTabId != target else {
            debugPendingWorkspaceSwitchTrigger = nil
            debugPendingWorkspaceSwitchTarget = nil
            return
        }
        debugPendingWorkspaceSwitchTrigger = trigger
        debugPendingWorkspaceSwitchTarget = target
    }

    private func debugPrepareWorkspaceSwitch(_ trigger: String, from: UUID?, to: UUID?) {
        guard from != to else {
            debugPendingWorkspaceSwitchTrigger = nil
            debugPendingWorkspaceSwitchTarget = nil
            debugPreparedWorkspaceSwitchTarget = nil
            return
        }
        debugPendingWorkspaceSwitchTrigger = nil
        debugPendingWorkspaceSwitchTarget = nil
        debugBeginWorkspaceSwitch(trigger: trigger, from: from, to: to)
        debugPreparedWorkspaceSwitchTarget = to
    }

    private func debugBeginWorkspaceSwitch(trigger: String, from: UUID?, to: UUID?) {
        debugWorkspaceSwitchCounter &+= 1
        debugWorkspaceSwitchId = debugWorkspaceSwitchCounter
        debugWorkspaceSwitchStartTime = CACurrentMediaTime()
        cmuxDebugLog(
            "ws.switch.begin id=\(debugWorkspaceSwitchId) trigger=\(trigger) " +
            "from=\(Self.debugShortWorkspaceId(from)) to=\(Self.debugShortWorkspaceId(to)) " +
            "hot=\(isWorkspaceCycleHot ? 1 : 0) tabs=\(tabs.count)"
        )
    }

    private static func debugShortWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }

    private static func debugTitlePreview(_ title: String, limit: Int = 120) -> String {
        let escaped = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard escaped.count > limit else { return escaped }
        return "\(escaped.prefix(limit))..."
    }

    private static func debugMsText(_ ms: Double) -> String {
        String(format: "%.2fms", ms)
    }
#endif

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
#if DEBUG
        debugPrimeWorkspaceSwitchTrigger("select_index", to: tabs[index].id)
#endif
        selectWorkspaceId(tabs[index].id, notificationDismissalContext: .explicitWorkspaceResume)
    }

    func selectLastTab() {
        guard let lastTab = tabs.last else { return }
        selectWorkspaceId(lastTab.id, notificationDismissalContext: .explicitWorkspaceResume)
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane of the selected workspace
    func selectNextSurface() {
        selectedWorkspace?.selectNextSurface()
    }

    /// Select the previous surface in the currently focused pane of the selected workspace
    func selectPreviousSurface() {
        selectedWorkspace?.selectPreviousSurface()
    }

    /// Select a surface by index in the currently focused pane of the selected workspace
    func selectSurface(at index: Int) {
        selectedWorkspace?.selectSurface(at: index)
    }

    /// Select the last surface in the currently focused pane of the selected workspace
    func selectLastSurface() {
        selectedWorkspace?.selectLastSurface()
    }

    /// Create a new terminal surface in the focused pane of the selected workspace
    func newSurface() {
        // Cmd+T should always focus the newly created surface.
        selectedWorkspace?.clearSplitZoom()
        selectedWorkspace?.newTerminalSurfaceInFocusedPane(focus: true)
    }

    func newSurface(initialInput: String) {
        selectedWorkspace?.clearSplitZoom()
        selectedWorkspace?.newTerminalSurfaceInFocusedPane(focus: true, initialInput: initialInput)
    }

    // MARK: - Split Creation

    /// Create a new split in the current tab
    @discardableResult
    func createSplit(direction: SplitDirection) -> UUID? {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let focusedPanelId = tab.focusedPanelId else { return nil }
        return createSplit(tabId: selectedTabId, surfaceId: focusedPanelId, direction: direction)
    }

    /// Create a new split from an explicit source panel.
    @discardableResult
    func createSplit(tabId: UUID, surfaceId: UUID, direction: SplitDirection, focus: Bool = true) -> UUID? {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              tab.panels[surfaceId] != nil else { return nil }
        tab.clearSplitZoom()
        sentryBreadcrumb("split.create", data: ["direction": String(describing: direction)])
        return newSplit(tabId: tabId, surfaceId: surfaceId, direction: direction, focus: focus)
    }

    /// Create a new browser split from the currently focused panel.
    @discardableResult
    func createBrowserSplit(direction: SplitDirection, url: URL? = nil) -> UUID? {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let focusedPanelId = tab.focusedPanelId else { return nil }
        tab.clearSplitZoom()
        return newBrowserSplit(
            tabId: selectedTabId,
            fromPanelId: focusedPanelId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            url: url
        )
    }

    /// Refresh Bonsplit right-side action button tooltips for all workspaces.
    func refreshSplitButtonTooltips() {
        for workspace in tabs {
            workspace.refreshSplitButtonTooltips()
        }
    }

    func refreshTabCloseButtonVisibility() {
        for workspace in tabs {
            workspace.refreshTabCloseButtonVisibility()
        }
    }

    func applySurfaceTabBarButtons(
        _ buttons: [CmuxSurfaceTabBarButton],
        sourcePath: String?,
        globalConfigPath: String,
        terminalCommandSourcePaths: [String: String],
        workspaceCommands: [String: CmuxResolvedCommand]
    ) {
        for workspace in tabs {
            workspace.applySurfaceTabBarButtons(
                buttons,
                sourcePath: sourcePath,
                globalConfigPath: globalConfigPath,
                terminalCommandSourcePaths: terminalCommandSourcePaths,
                workspaceCommands: workspaceCommands
            )
        }
    }

    // MARK: - Pane Focus Navigation

    /// Move focus to an adjacent pane in the specified direction
    func movePaneFocus(direction: NavigationDirection) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }
        tab.moveFocus(direction: direction)
    }

    // MARK: - Focus History Navigation (CmuxWorkspaceNavigation)

    // The back/forward stack, suppression depth, and navigation logic live
    // in FocusHistoryModel; these forwarders keep every existing entrypoint
    // (menus, shortcuts, titlebar buttons, socket commands) unchanged.

    @discardableResult
    func withFocusHistoryRecordingSuppressed<Result>(_ body: () throws -> Result) rethrows -> Result {
        try focusHistoryNavigation.withFocusHistoryRecordingSuppressed(body)
    }

    func invalidateFocusHistoryTarget(workspaceId: UUID, panelId: UUID?) {
        focusHistoryNavigation.invalidateFocusHistoryTarget(workspaceId: workspaceId, panelId: panelId)
    }

    private func panelIdForFocusHistorySurface(_ surfaceId: UUID, workspaceId: UUID) -> UUID {
        tabs.first(where: { $0.id == workspaceId })?.panelIdFromSurfaceId(TabID(uuid: surfaceId)) ?? surfaceId
    }

    var currentFocusHistoryEntry: FocusHistoryEntry? {
        focusHistoryNavigation.currentFocusHistoryEntry
    }

    func focusHistoryMenuSnapshot(
        direction: FocusHistoryMenuDirection,
        maxItemCount: Int? = nil
    ) -> FocusHistoryMenuSnapshot {
        focusHistoryNavigation.focusHistoryMenuSnapshot(direction: direction, maxItemCount: maxItemCount)
    }

    @discardableResult
    func navigateToFocusHistoryMenuItem(_ item: FocusHistoryMenuItem) -> Bool {
        focusHistoryNavigation.navigateToFocusHistoryMenuItem(item)
    }

    @discardableResult
    func navigateBack() -> Bool {
        focusHistoryNavigation.navigateBack()
    }

    @discardableResult
    func navigateForward() -> Bool {
        focusHistoryNavigation.navigateForward()
    }

    var canNavigateBack: Bool {
        focusHistoryNavigation.canNavigateBack
    }

    var canNavigateForward: Bool {
        focusHistoryNavigation.canNavigateForward
    }

    // FocusHistoryHosting witnesses that touch private members
    // (`focusSelectedTabPanel`, the `private(set)` revision counter); the
    // rest of the conformance lives in TabManager+FocusHistoryHosting.swift.

    func focusSelectedWorkspacePanel() {
        focusSelectedTabPanel(previousTabId: nil)
    }

    func focusHistoryRevisionDidChange() {
        focusHistoryRevision &+= 1
    }

    // MARK: - Split Operations (Backwards Compatibility)

    /// Create a new split in the specified direction
    /// Returns the new panel's ID (which is also the surface ID for terminals)
    func newSplit(
        tabId: UUID,
        surfaceId: UUID,
        direction: SplitDirection,
        focus: Bool = true,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        startupEnvironment: [String: String] = [:],
        initialDividerPosition: CGFloat? = nil,
        remotePTYSessionID: String? = nil
    ) -> UUID? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newTerminalSplit(
            from: surfaceId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            startupEnvironment: startupEnvironment,
            initialDividerPosition: initialDividerPosition,
            remotePTYSessionID: remotePTYSessionID
        )?.id
    }

    /// Move focus in the specified direction
    func moveSplitFocus(tabId: UUID, surfaceId: UUID, direction: NavigationDirection) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        tab.moveFocus(direction: direction)
        return true
    }

    /// Resize split - not directly supported by bonsplit, but we can adjust divider positions
    func resizeSplit(tabId: UUID, surfaceId: UUID, direction: ResizeDirection, amount: UInt16) -> Bool {
        guard amount > 0,
              let tab = tabs.first(where: { $0.id == tabId }),
              let paneId = tab.paneId(forPanelId: surfaceId) else { return false }

        let paneUUID = paneId.id
        guard tab.bonsplitController.allPaneIds.contains(where: { $0.id == paneUUID }) else {
            return false
        }

        return paneLayout.resizeSplit(
            in: tab.bonsplitController.treeSnapshot(),
            targetPaneId: paneUUID.uuidString,
            direction: direction,
            amountPixels: amount,
            controller: tab.bonsplitController
        )
    }

    /// Toggle zoom on a panel.
    func toggleSplitZoom(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.toggleSplitZoom(panelId: surfaceId)
    }

    /// Toggle zoom for the currently focused panel in the selected workspace.
    @discardableResult
    func toggleFocusedSplitZoom() -> Bool {
        guard let tab = selectedWorkspace,
              let focusedPanelId = tab.focusedPanelId else { return false }
        return tab.toggleSplitZoom(panelId: focusedPanelId)
    }

    /// Close a surface/panel
    func closeSurface(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        // Guard against stale close callbacks (e.g. child-exit can trigger multiple actions).
        // A stale callback must never affect unrelated panels/workspaces.
        guard tab.panels[surfaceId] != nil,
              tab.surfaceIdFromPanelId(surfaceId) != nil else { return false }
        tab.closePanel(surfaceId)
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tabId, surfaceId: surfaceId)
        return true
    }

    /// Create a new browser panel in a split
    func newBrowserSplit(
        tabId: UUID,
        fromPanelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        focus: Bool = true,
        initialDividerPosition: CGFloat? = nil
    ) -> UUID? {
        guard BrowserAvailabilitySettings.isEnabled() else { return nil }
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newBrowserSplit(
            from: fromPanelId,
            orientation: orientation,
            insertFirst: insertFirst,
            url: url,
            preferredProfileID: preferredProfileID,
            focus: focus,
            initialDividerPosition: initialDividerPosition
        )?.id
    }

    /// Create a new browser surface in a pane
    func newBrowserSurface(
        tabId: UUID,
        inPane paneId: PaneID,
        url: URL? = nil,
        preferredProfileID: UUID? = nil
    ) -> UUID? {
        guard BrowserAvailabilitySettings.isEnabled() else { return nil }
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newBrowserSurface(
            inPane: paneId,
            url: url,
            preferredProfileID: preferredProfileID
        )?.id
    }

    /// Get a browser panel by ID
    func browserPanel(tabId: UUID, panelId: UUID) -> BrowserPanel? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.browserPanel(for: panelId)
    }

    /// Open a browser in a specific workspace, optionally preferring a split-right layout.
    @discardableResult
    func openBrowser(
        inWorkspace tabId: UUID,
        url: URL? = nil,
        preferSplitRight: Bool = false,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        guard BrowserAvailabilitySettings.isEnabled() else { return nil }
        guard let workspace = tabs.first(where: { $0.id == tabId }) else { return nil }
        if selectedTabId != tabId {
            selectWorkspaceId(tabId, notificationDismissalContext: .explicitWorkspaceResume)
        }

        if preferSplitRight {
            if let targetPaneId = workspace.topRightBrowserReusePane(),
               let browserPanel = workspace.newBrowserSurface(
                   inPane: targetPaneId,
                   url: url,
                   focus: true,
                   insertAtEnd: insertAtEnd,
                   preferredProfileID: preferredProfileID
               ) {
                rememberFocusedSurface(tabId: tabId, surfaceId: browserPanel.id)
                return browserPanel.id
            }

            let splitSourcePanelId: UUID? = {
                if let focusedPanelId = workspace.focusedPanelId,
                   workspace.panels[focusedPanelId] != nil {
                    return focusedPanelId
                }
                if let rememberedPanelId = lastFocusedPanelByTab[tabId],
                   workspace.panels[rememberedPanelId] != nil {
                    return rememberedPanelId
                }
                if let orderedPanelId = workspace.sidebarOrderedPanelIds().first(where: { workspace.panels[$0] != nil }) {
                    return orderedPanelId
                }
                return workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }.first
            }()

            if let splitSourcePanelId,
               let browserPanel = workspace.newBrowserSplit(
                   from: splitSourcePanelId,
                   orientation: .horizontal,
                   url: url,
                   preferredProfileID: preferredProfileID,
                   focus: true
               ) {
                rememberFocusedSurface(tabId: tabId, surfaceId: browserPanel.id)
                return browserPanel.id
            }
        }

        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first,
              let browserPanel = workspace.newBrowserSurface(
                  inPane: paneId,
                  url: url,
                  focus: true,
                  insertAtEnd: insertAtEnd,
                  preferredProfileID: preferredProfileID
              ) else {
            return nil
        }
        rememberFocusedSurface(tabId: tabId, surfaceId: browserPanel.id)
        return browserPanel.id
    }

    /// Open a browser for a sidebar link, reusing an existing browser surface in the workspace
    /// when it already represents the same PR/Jira/exact URL.
    @discardableResult
    func openOrFocusBrowser(
        inWorkspace tabId: UUID,
        url: URL,
        preferSplitRight: Bool = false,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        guard BrowserAvailabilitySettings.isEnabled() else { return nil }
        guard let workspace = tabs.first(where: { $0.id == tabId }) else { return nil }
        if selectedTabId != tabId {
            selectWorkspaceId(tabId, notificationDismissalContext: .explicitWorkspaceResume)
        }

        if let existingBrowserPanel = workspace.focusBrowserPanel(matchingSidebarLinkURL: url) {
            rememberFocusedSurface(tabId: tabId, surfaceId: existingBrowserPanel.id)
            return existingBrowserPanel.id
        }

        return openBrowser(
            inWorkspace: tabId,
            url: url,
            preferSplitRight: preferSplitRight,
            preferredProfileID: preferredProfileID,
            insertAtEnd: insertAtEnd
        )
    }

    /// Open a browser in the currently focused pane (as a new surface)
    @discardableResult
    func openBrowser(
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        guard let tabId = selectedTabId else { return nil }
        return openBrowser(
            inWorkspace: tabId,
            url: url,
            preferSplitRight: false,
            preferredProfileID: preferredProfileID,
            insertAtEnd: insertAtEnd
        )
    }

    /// Reopen the most recently closed browser panel (Cmd+Shift+T).
    /// No-op when no browser panel restore snapshot is available.
    @discardableResult
    func reopenMostRecentlyClosedBrowserPanel() -> Bool {
        if reopenMostRecentlyClosedItem() {
            return true
        }

        return reopenMostRecentlyClosedBrowserPanelFromLegacyStack()
    }

    @discardableResult
    func reopenMostRecentlyClosedBrowserPanelFromLegacyStack() -> Bool {
        guard BrowserAvailabilitySettings.isEnabled() else { return false }

        while let snapshot = browserModel.popMostRecentlyClosedBrowserPanel() {
            // The legacy stack must restore into the workspace that originally owned the
            // browser. If that workspace is gone, the snapshot is stale and we drop it
            // instead of barging into whatever workspace happens to be selected now
            // (which surfaced yesterday's browser inside today's unrelated workspaces).
            guard let targetWorkspace = tabs.first(where: { $0.id == snapshot.workspaceId }) else {
                continue
            }
            let preReopenFocusedPanelId = focusedPanelId(for: targetWorkspace.id)

            if selectedTabId != targetWorkspace.id {
                selectWorkspaceId(
                    targetWorkspace.id,
                    notificationDismissalContext: .explicitWorkspaceResume
                )
            }

            if let reopenedPanelId = reopenClosedBrowserPanel(snapshot, in: targetWorkspace) {
                enforceReopenedBrowserFocus(
                    tabId: targetWorkspace.id,
                    reopenedPanelId: reopenedPanelId,
                    preReopenFocusedPanelId: preReopenFocusedPanelId
                )
                return true
            }
        }

        return false
    }

    func clearRecentlyClosedBrowserPanelHistory() {
        browserModel.clearRecentlyClosedBrowserPanels()
    }

    func mostRecentLegacyClosedBrowserPanelClosedAt() -> Date? {
        browserModel.mostRecentClosedBrowserPanelClosedAt
    }

    @discardableResult
    func reopenMostRecentlyClosedItem() -> Bool {
        if let appDelegate = AppDelegate.shared {
            return appDelegate.reopenMostRecentlyClosedItem(preferredTabManager: self)
        }

        if ClosedItemHistoryStore.shared.restoreFirstRestorable(using: { entry in
            switch entry {
            case .panel(let panelEntry):
                return restoreClosedPanel(panelEntry)
            case .workspace(let workspaceEntry):
                return restoreClosedWorkspace(workspaceEntry)
            case .window:
                return false
            }
        }) {
            return true
        }

        return false
    }

    @discardableResult
    func reopenClosedHistoryItem(id: UUID) -> Bool {
        if let appDelegate = AppDelegate.shared {
            return appDelegate.reopenClosedHistoryItem(id: id, preferredTabManager: self)
        }

        guard let removed = ClosedItemHistoryStore.shared.removeRecord(id: id) else {
            return false
        }

        let didRestore: Bool
        switch removed.record.entry {
        case .panel(let panelEntry):
            didRestore = restoreClosedPanel(panelEntry)
        case .workspace(let workspaceEntry):
            didRestore = restoreClosedWorkspace(workspaceEntry)
        case .window:
            didRestore = false
        }

        if !didRestore {
            ClosedItemHistoryStore.shared.insert(removed.record, at: removed.index)
        }
        return didRestore
    }

    @discardableResult
    func restoreClosedPanel(_ entry: ClosedPanelHistoryEntry) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == entry.workspaceId }) else {
            return false
        }

        let preRestoreFocus = currentFocusHistoryEntry
        let panelId = withFocusHistoryRecordingSuppressed {
            workspace.restoreClosedPanel(entry)
        }

        guard let panelId else { return false }
        ClosedItemHistoryStore.shared.remapPanelAnchorIds(from: entry.snapshot.id, to: panelId)
        withFocusHistoryRecordingSuppressed {
            if selectedTabId != workspace.id {
                selectedTabId = workspace.id
            }
        }
        focusHistoryNavigation.recordFocusInHistory(preRestoreFocus, preservingForwardBranch: true)
        rememberFocusedSurface(tabId: workspace.id, surfaceId: panelId)
        focusHistoryNavigation.recordFocusInHistory(workspaceId: workspace.id, panelId: panelId, preservingForwardBranch: true)
        return true
    }

    @discardableResult
    func restoreClosedWorkspace(_ entry: ClosedWorkspaceHistoryEntry) -> Bool {
        let preRestoreFocus = currentFocusHistoryEntry
        let workspace = addWorkspace(
            title: entry.snapshot.customTitle ?? entry.snapshot.processTitle,
            workingDirectory: entry.snapshot.currentDirectory,
            select: false,
            autoWelcomeIfNeeded: false
        )
        let restoredPanelIds = workspace.restoreSessionSnapshot(entry.snapshot)
        guard !entry.snapshot.hasRestorablePanels || !restoredPanelIds.isEmpty else {
            closeWorkspace(workspace, recordHistory: false)
            return false
        }
        guard !workspace.panels.isEmpty else {
            closeWorkspace(workspace, recordHistory: false)
            return false
        }
        // The snapshot may carry a groupId for a group that no longer exists
        // in this TabManager (e.g. the group was dissolved between close and
        // reopen). Drop those stale references so the restored workspace
        // doesn't render as an orphaned indented row under no header.
        if let groupId = workspace.groupId,
           !workspaceGroups.contains(where: { $0.id == groupId }) {
            workspace.groupId = nil
        }
        // When the group DOES still exist, the workspace is about to be
        // reinserted at its old absolute index, which may now sit inside a
        // different group section after intervening reorders. Renormalize
        // so the restored member lands beside its group.
        let needsNormalize = workspace.groupId != nil && !workspaceGroups.isEmpty
        ClosedItemHistoryStore.shared.remapPanelWorkspaceIds(
            from: entry.workspaceId,
            to: workspace.id,
            panelIdMap: restoredPanelIds
        )

        if let currentIndex = tabs.firstIndex(where: { $0.id == workspace.id }) {
            let removed = tabs.remove(at: currentIndex)
            let insertIndex = min(max(entry.workspaceIndex, 0), tabs.count)
            tabs.insert(removed, at: insertIndex)
        }
        if needsNormalize {
            workspaces.normalizeWorkspaceGroupContiguity()
        }

        withFocusHistoryRecordingSuppressed {
            selectedTabId = workspace.id
        }
        focusHistoryNavigation.recordFocusInHistory(preRestoreFocus, preservingForwardBranch: true)
        if let focusedPanelId = workspace.focusedPanelId {
            rememberFocusedSurface(tabId: workspace.id, surfaceId: focusedPanelId)
            workspace.triggerFocusFlash(panelId: focusedPanelId)
            focusHistoryNavigation.recordFocusInHistory(workspaceId: workspace.id, panelId: focusedPanelId, preservingForwardBranch: true)
        } else {
            focusHistoryNavigation.recordFocusInHistory(workspaceId: workspace.id, panelId: nil, preservingForwardBranch: true)
        }
        return true
    }

    private func enforceReopenedBrowserFocus(
        tabId: UUID,
        reopenedPanelId: UUID,
        preReopenFocusedPanelId: UUID?
    ) {
        // Keep workspace-switch restoration pinned to the reopened browser panel.
        rememberFocusedSurface(tabId: tabId, surfaceId: reopenedPanelId)
        enforceReopenedBrowserFocusIfNeeded(
            tabId: tabId,
            reopenedPanelId: reopenedPanelId,
            preReopenFocusedPanelId: preReopenFocusedPanelId
        )

        // Some stale focus callbacks can land one runloop turn later. Re-assert focus in two
        // consecutive turns, but only when focus drifted back to the pre-reopen panel.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.enforceReopenedBrowserFocusIfNeeded(
                tabId: tabId,
                reopenedPanelId: reopenedPanelId,
                preReopenFocusedPanelId: preReopenFocusedPanelId
            )
            DispatchQueue.main.async { [weak self] in
                self?.enforceReopenedBrowserFocusIfNeeded(
                    tabId: tabId,
                    reopenedPanelId: reopenedPanelId,
                    preReopenFocusedPanelId: preReopenFocusedPanelId
                )
            }
        }
    }

    private func enforceReopenedBrowserFocusIfNeeded(
        tabId: UUID,
        reopenedPanelId: UUID,
        preReopenFocusedPanelId: UUID?
    ) {
        guard selectedTabId == tabId,
              let tab = tabs.first(where: { $0.id == tabId }),
              tab.panels[reopenedPanelId] != nil else {
            return
        }

        rememberFocusedSurface(tabId: tabId, surfaceId: reopenedPanelId)

        guard tab.focusedPanelId != reopenedPanelId else { return }

        if let focusedPanelId = tab.focusedPanelId,
           let preReopenFocusedPanelId,
           focusedPanelId != preReopenFocusedPanelId {
            return
        }

        tab.focusPanel(reopenedPanelId)
    }

    private func reopenClosedBrowserPanel(
        _ snapshot: ClosedBrowserPanelRestoreSnapshot,
        in workspace: Workspace
    ) -> UUID? {
        if let originalPane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == snapshot.originalPaneId }),
           let browserPanel = workspace.newBrowserSurface(
               inPane: originalPane,
               url: snapshot.url,
               focus: true,
               preferredProfileID: snapshot.profileID
           ) {
            let tabCount = workspace.bonsplitController.tabs(inPane: originalPane).count
            let maxIndex = max(0, tabCount - 1)
            let targetIndex = min(max(snapshot.originalTabIndex, 0), maxIndex)
            _ = workspace.reorderSurface(panelId: browserPanel.id, toIndex: targetIndex)
            return browserPanel.id
        }

        if let orientation = snapshot.fallbackSplitOrientation,
           let fallbackAnchorPaneId = snapshot.fallbackAnchorPaneId,
           let anchorPane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == fallbackAnchorPaneId }),
           let anchorTab = workspace.bonsplitController.selectedTab(inPane: anchorPane) ?? workspace.bonsplitController.tabs(inPane: anchorPane).first,
           let anchorPanelId = workspace.panelIdFromSurfaceId(anchorTab.id),
           let browserPanelId = workspace.newBrowserSplit(
               from: anchorPanelId,
               orientation: orientation,
               insertFirst: snapshot.fallbackSplitInsertFirst,
               url: snapshot.url,
               preferredProfileID: snapshot.profileID
           )?.id {
            return browserPanelId
        }

        guard let focusedPane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }
        return workspace.newBrowserSurface(
            inPane: focusedPane,
            url: snapshot.url,
            focus: true,
            preferredProfileID: snapshot.profileID
        )?.id
    }

    /// Flash the currently focused panel so the user can visually confirm focus.
    func triggerFocusFlash() {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId else { return }
        tab.triggerFocusFlash(panelId: panelId)
    }

    /// Ensure AppKit first responder matches the currently focused terminal panel.
    /// This keeps real keyboard events (including Ctrl+D) on the same panel as the
    /// bonsplit focus indicator after rapid split topology changes.
    func ensureFocusedTerminalFirstResponder() {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId,
              let terminal = tab.terminalPanel(for: panelId) else { return }
        terminal.hostedView.ensureFocus(for: tab.id, surfaceId: panelId)
    }

    /// Reconcile keyboard routing before terminal control shortcuts (e.g. Ctrl+D).
    ///
    /// Source of truth for pane focus is bonsplit's focused pane + selected tab.
    /// Keyboard delivery must converge AppKit first responder to that model state, not mutate
    /// the model from whatever first responder happened to be during reparenting transitions.
    func reconcileFocusedPanelFromFirstResponderForKeyboard() {
        ensureFocusedTerminalFirstResponder()
    }

    /// Get a terminal panel by ID
    func terminalPanel(tabId: UUID, panelId: UUID) -> TerminalPanel? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.terminalPanel(for: panelId)
    }

    /// Get the panel for a surface ID (terminal panels use surface ID as panel ID)
    func surface(for tabId: UUID, surfaceId: UUID) -> TerminalSurface? {
        terminalPanel(tabId: tabId, panelId: surfaceId)?.surface
    }

#if DEBUG
    @MainActor
    private func waitForWorkspacePanelsCondition(
        tab: Workspace,
        timeoutSeconds: TimeInterval,
        condition: @escaping (Workspace) -> Bool
    ) async -> Bool {
        guard !condition(tab) else { return true }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resolved = false
            var cancellable: AnyCancellable?

            func finish(_ value: Bool) {
                guard !resolved else { return }
                resolved = true
                cancellable?.cancel()
                cont.resume(returning: value)
            }

            func evaluate() {
                if condition(tab) {
                    finish(true)
                }
            }

            cancellable = tab.panelsPublisher
                .map { _ in () }
                .sink { _ in evaluate() }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                Task { @MainActor in
                    finish(condition(tab))
                }
            }
            evaluate()
        }
    }

    @MainActor
    private func waitForTerminalPanelCondition(
        tab: Workspace,
        panelId: UUID,
        timeoutSeconds: TimeInterval,
        condition: @escaping (TerminalPanel) -> Bool
    ) async -> Bool {
        if let panel = tab.terminalPanel(for: panelId), condition(panel) {
            return true
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resolved = false
            var panelsCancellable: AnyCancellable?
            var readyObserver: NSObjectProtocol?
            var hostedViewObserver: NSObjectProtocol?

            @MainActor
            func finish(_ value: Bool) {
                guard !resolved else { return }
                resolved = true
                panelsCancellable?.cancel()
                if let readyObserver {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if let hostedViewObserver {
                    NotificationCenter.default.removeObserver(hostedViewObserver)
                }
                cont.resume(returning: value)
            }

            @MainActor
            func evaluate() {
                guard let panel = tab.terminalPanel(for: panelId) else {
                    finish(false)
                    return
                }
                panel.surface.requestBackgroundSurfaceStartIfNeeded()
                if condition(panel) {
                    finish(true)
                }
            }

            panelsCancellable = tab.panelsPublisher
                .map { _ in () }
                .sink { _ in
                    Task { @MainActor in
                        evaluate()
                    }
                }
            readyObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { note in
                guard let readySurfaceId = note.userInfo?["surfaceId"] as? UUID,
                      readySurfaceId == panelId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }
            hostedViewObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceHostedViewDidMoveToWindow,
                object: nil,
                queue: .main
            ) { note in
                guard let hostedSurfaceId = note.userInfo?["surfaceId"] as? UUID,
                      hostedSurfaceId == panelId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                Task { @MainActor in
                    if let panel = tab.terminalPanel(for: panelId) {
                        finish(condition(panel))
                    } else {
                        finish(false)
                    }
                }
            }
            evaluate()
        }
    }

    @MainActor
    private func waitForTerminalPanelReadyForUITest(
        tab: Workspace,
        panelId: UUID,
        timeoutSeconds: TimeInterval = 6.0
    ) async -> (attached: Bool, hasSurface: Bool, firstResponder: Bool) {
        var attached = false
        var hasSurface = false
        var firstResponder = false

        let _ = await waitForTerminalPanelCondition(
            tab: tab,
            panelId: panelId,
            timeoutSeconds: timeoutSeconds
        ) { panel in
            panel.surface.requestBackgroundSurfaceStartIfNeeded()
            attached = panel.surface.isViewInWindow
            hasSurface = panel.surface.surface != nil
            firstResponder = panel.hostedView.isSurfaceViewFirstResponder()
            return attached && hasSurface
        }

        return (attached, hasSurface, firstResponder)
    }

    private func setupUITestFocusShortcutsIfNeeded() {
        guard !didSetupUITestFocusShortcuts else { return }
        didSetupUITestFocusShortcuts = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_FOCUS_SHORTCUTS"] == "1" else { return }

        // UI tests can't record arrow keys via the shortcut recorder. Use letter-based shortcuts
        // so tests can reliably drive pane navigation without mouse clicks.
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "h", command: true, shift: false, option: false, control: true),
            for: .focusLeft
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "l", command: true, shift: false, option: false, control: true),
            for: .focusRight
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "k", command: true, shift: false, option: false, control: true),
            for: .focusUp
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "j", command: true, shift: false, option: false, control: true),
            for: .focusDown
        )
    }

    private func setupSplitCloseRightUITestIfNeeded() {
        guard !didSetupSplitCloseRightUITest else { return }
        didSetupSplitCloseRightUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH"], !path.isEmpty else { return }
        let visualMode = env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] == "1"
        let shotsDir = (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SHOTS_DIR"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let visualIterations = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS"] ?? "20").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 20
        let burstFrames = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_BURST_FRAMES"] ?? "6").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 6
        let closeDelayMs = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_CLOSE_DELAY_MS"] ?? "70").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 70
        let pattern = (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATTERN"] ?? "close_right")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let tab = self.selectedWorkspace else {
                    self.writeSplitCloseRightTestData(["setupError": "Missing selected workspace"], at: path)
                    return
                }

                guard let topLeftPanelId = tab.focusedPanelId else {
                    self.writeSplitCloseRightTestData(["setupError": "Missing initial focused panel"], at: path)
                    return
                }
                let initialTerminalReadiness = await self.waitForTerminalPanelReadyForUITest(
                    tab: tab,
                    panelId: topLeftPanelId
                )

                guard initialTerminalReadiness.attached,
                      initialTerminalReadiness.hasSurface,
                      let terminal = tab.terminalPanel(for: topLeftPanelId) else {
                    self.writeSplitCloseRightTestData([
                        "preTerminalAttached": initialTerminalReadiness.attached ? "1" : "0",
                        "preTerminalSurfaceNil": initialTerminalReadiness.hasSurface ? "0" : "1",
                        "setupError": "Initial terminal not ready (not attached or surface nil)"
                    ], at: path)
                    return
                }

                self.writeSplitCloseRightTestData([
                    "preTerminalAttached": "1",
                    "preTerminalSurfaceNil": terminal.surface.surface == nil ? "1" : "0"
                ], at: path)

                if visualMode {
                    // Visual repro mode: repeat the split/close sequence many times and write
                    // screenshots to `shotsDir`. This avoids relying on XCUITest to click hover-only
                    // close buttons, while still exercising the "close unfocused right tabs" path.
                    self.writeSplitCloseRightTestData([
                        "visualMode": "1",
                        "visualIterations": String(visualIterations),
                        "visualDone": "0"
                    ], at: path)

                    await self.runSplitCloseRightVisualRepro(
                        tab: tab,
                        topLeftPanelId: topLeftPanelId,
                        path: path,
                        shotsDir: shotsDir,
                        iterations: max(1, min(visualIterations, 60)),
                        burstFrames: max(0, min(burstFrames, 80)),
                        closeDelayMs: max(0, min(closeDelayMs, 500)),
                        pattern: pattern
                    )

                    self.writeSplitCloseRightTestData(["visualDone": "1"], at: path)
                    return
                }

                // Layout goal: 2x2 grid (2 top, 2 bottom), then close both right panels.
                // Order matters: split down first, then split right in each row (matches UI shortcut repro).
                guard let bottomLeft = tab.newTerminalSplit(from: topLeftPanelId, orientation: .vertical) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create bottom-left split"], at: path)
                    return
                }
                guard let bottomRight = tab.newTerminalSplit(from: bottomLeft.id, orientation: .horizontal) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create bottom-right split"], at: path)
                    return
                }
                tab.focusPanel(topLeftPanelId)
                guard let topRight = tab.newTerminalSplit(from: topLeftPanelId, orientation: .horizontal) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create top-right split"], at: path)
                    return
                }

                self.writeSplitCloseRightTestData([
                    "tabId": tab.id.uuidString,
                    "topLeftPanelId": topLeftPanelId.uuidString,
                    "bottomLeftPanelId": bottomLeft.id.uuidString,
                    "topRightPanelId": topRight.id.uuidString,
                    "bottomRightPanelId": bottomRight.id.uuidString,
                    "createdPaneCount": String(tab.bonsplitController.allPaneIds.count),
                    "createdPanelCount": String(tab.panels.count)
                ], at: path)

                DebugUIEventCounters.resetEmptyPanelAppearCount()

                // Close the two right panes via the same path as the Close Tab shortcut.
                tab.focusPanel(topRight.id)
                tab.closePanel(topRight.id, force: true)
                tab.focusPanel(bottomRight.id)
                tab.closePanel(bottomRight.id, force: true)


                // Capture final state after Bonsplit/AppKit/Ghostty geometry reconciliation.
                // We avoid sleep-based timing and converge over a few main-actor turns.
                 @MainActor func collectSplitCloseRightState() -> (data: [String: String], settled: Bool) {
                    let paneIds = tab.bonsplitController.allPaneIds
                    let bonsplitTabCount = tab.bonsplitController.allTabIds.count
                    let panelCount = tab.panels.count

                    var missingSelectedTabCount = 0
                    var missingPanelMappingCount = 0
                    var selectedTerminalCount = 0
                    var selectedTerminalAttachedCount = 0
                    var selectedTerminalZeroSizeCount = 0
                    var selectedTerminalSurfaceNilCount = 0

                    for paneId in paneIds {
                        guard let selected = tab.bonsplitController.selectedTab(inPane: paneId) else {
                            missingSelectedTabCount += 1
                            continue
                        }
                        guard let panel = tab.panel(for: selected.id) else {
                            missingPanelMappingCount += 1
                            continue
                        }
                        if let terminal = panel as? TerminalPanel {
                            selectedTerminalCount += 1
                            if terminal.surface.isViewInWindow {
                                selectedTerminalAttachedCount += 1
                            }
                            let size = terminal.hostedView.bounds.size
                            if size.width < 5 || size.height < 5 {
                                selectedTerminalZeroSizeCount += 1
                            }
                            if terminal.surface.surface == nil {
                                selectedTerminalSurfaceNilCount += 1
                            }
                        }
                    }

                    let settled =
                        paneIds.count == 2 &&
                        missingSelectedTabCount == 0 &&
                        missingPanelMappingCount == 0 &&
                        DebugUIEventCounters.emptyPanelAppearCount == 0 &&
                        selectedTerminalCount == 2 &&
                        selectedTerminalAttachedCount == 2 &&
                        selectedTerminalZeroSizeCount == 0 &&
                        selectedTerminalSurfaceNilCount == 0

                    return (
                        data: [
                            "finalPaneCount": String(paneIds.count),
                            "finalBonsplitTabCount": String(bonsplitTabCount),
                            "finalPanelCount": String(panelCount),
                            "missingSelectedTabCount": String(missingSelectedTabCount),
                            "missingPanelMappingCount": String(missingPanelMappingCount),
                            "emptyPanelAppearCount": String(DebugUIEventCounters.emptyPanelAppearCount),
                            "selectedTerminalCount": String(selectedTerminalCount),
                            "selectedTerminalAttachedCount": String(selectedTerminalAttachedCount),
                            "selectedTerminalZeroSizeCount": String(selectedTerminalZeroSizeCount),
                            "selectedTerminalSurfaceNilCount": String(selectedTerminalSurfaceNilCount),
                        ],
                        settled: settled
                    )
                }
                 @MainActor func reconcileVisibleTerminalGeometry() {
                    NSApp.windows.forEach { window in
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.contentView?.displayIfNeeded()
                    }
                    for paneId in tab.bonsplitController.allPaneIds {
                        guard let selected = tab.bonsplitController.selectedTab(inPane: paneId),
                              let terminal = tab.panel(for: selected.id) as? TerminalPanel else {
                            continue
                        }
                        terminal.hostedView.reconcileGeometryNow()
                        terminal.surface.forceRefresh()
                    }
                }

                var finalState = collectSplitCloseRightState()
                for attempt in 1...8 {
                    reconcileVisibleTerminalGeometry()
                    await Task.yield()
                    finalState = collectSplitCloseRightState()
                    var payload = finalState.data
                    payload["finalAttempt"] = String(attempt)
                    self.writeSplitCloseRightTestData(payload, at: path)
                    if finalState.settled {
                        break
                    }
                }
            }
        }
    }

	    @MainActor
	    private func runSplitCloseRightVisualRepro(
	        tab: Workspace,
	        topLeftPanelId: UUID,
	        path: String,
	        shotsDir: String,
	        iterations: Int,
	        burstFrames: Int,
	        closeDelayMs: Int,
	        pattern: String
	    ) async {
        _ = shotsDir // legacy: screenshots removed in favor of IOSurface sampling

        func sendText(_ panelId: UUID, _ text: String) {
            guard let tp = tab.terminalPanel(for: panelId) else { return }
            tp.sendText(text)
        }

        // Sample a very top strip so the probe remains valid even after vertical expand/collapse.
        // We pin marker text to row 1 before each close sequence.
        let sampleCrop = CGRect(x: 0.04, y: 0.01, width: 0.92, height: 0.08)

        for i in 1...iterations {
            // Reset to a single pane: close everything except the top-left panel.
            tab.focusPanel(topLeftPanelId)
            let toClose = Array(tab.panels.keys).filter { $0 != topLeftPanelId }
            for pid in toClose {
                tab.closePanel(pid, force: true)
            }

            // Create the repro layout. Most patterns use a 2x2 grid, but keep a single-split
            // variant for the exact "close right in a horizontal pair" user report.
            let topLeftId = topLeftPanelId
            let topRight: TerminalPanel
            var bottomLeft: TerminalPanel?
            var bottomRight: TerminalPanel?

            switch pattern {
            case "close_right_single":
                guard let tr = tab.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
            case "close_right_lrtd", "close_right_lrtd_bottom_first", "close_right_bottom_first", "close_right_lrtd_unfocused":
                // User repro: split left/right first, then split top/down in each column.
                guard let tr = tab.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                guard let bl = tab.newTerminalSplit(from: topLeftId, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from left (iteration \(i))"], at: path)
                    return
                }
                guard let br = tab.newTerminalSplit(from: tr.id, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from right (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
                bottomLeft = bl
                bottomRight = br
            default:
                // Default: split top/down first, then split left/right in each row.
                guard let bl = tab.newTerminalSplit(from: topLeftId, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from top-left (iteration \(i))"], at: path)
                    return
                }
                guard let br = tab.newTerminalSplit(from: bl.id, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from bottom-left (iteration \(i))"], at: path)
                    return
                }
                guard let tr = tab.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
                bottomLeft = bl
                bottomRight = br
            }

            // Let newly created surfaces attach before priming content, so sampled panes have
            // stable non-blank text before the close timeline begins.
            try? await Task.sleep(nanoseconds: 180_000_000)

            // Fill left panes with visible content.
            sendText(topLeftId, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_TOPLEFT_\(i); done; printf '\\033[HCMUX_MARKER_TOPLEFT\\n'\r")
            sendText(topRight.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_TOPRIGHT_\(i); done; printf '\\033[HCMUX_MARKER_TOPRIGHT\\n'\r")
            if let bottomLeft {
                sendText(bottomLeft.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_BOTTOMLEFT_\(i); done; printf '\\033[HCMUX_MARKER_BOTTOMLEFT\\n'\r")
            }
            if let bottomRight {
                sendText(bottomRight.id, "printf '\\033[2J\\033[H'; for i in {1..200}; do echo CMUX_SPLIT_BOTTOMRIGHT_\(i); done; printf '\\033[HCMUX_MARKER_BOTTOMRIGHT\\n'\r")
            }
            // Give shell output a moment to paint before we start the close timeline.
            try? await Task.sleep(nanoseconds: 180_000_000)

            let desiredFrames = max(16, min(burstFrames, 60))
            let closeFrame = min(6, max(1, desiredFrames / 4))
            let delayFrames = max(0, Int((Double(max(0, closeDelayMs)) / 16.6667).rounded(.up)))
            let secondCloseFrame = min(desiredFrames - 1, closeFrame + delayFrames)

            var closeOrder = ""
            let actions: [(frame: Int, action: () -> Void)] = {
                switch pattern {
                case "close_right_single":
                    closeOrder = "TR_ONLY"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(topRight.id)
                            tab.closePanel(topRight.id, force: true)
                        }),
                    ]
                case "close_bottom":
                    guard let bottomRight, let bottomLeft else { return [] }
                    closeOrder = "BR_THEN_BL"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(bottomRight.id)
                            tab.closePanel(bottomRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.focusPanel(bottomLeft.id)
                            tab.closePanel(bottomLeft.id, force: true)
                        }),
                    ]
                case "close_right_lrtd_bottom_first", "close_right_bottom_first":
                    guard let bottomRight else { return [] }
                    closeOrder = "BR_THEN_TR"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(bottomRight.id)
                            tab.closePanel(bottomRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.focusPanel(topRight.id)
                            tab.closePanel(topRight.id, force: true)
                        }),
                    ]
                case "close_right_lrtd_unfocused":
                    guard let bottomRight else { return [] }
                    closeOrder = "TR_THEN_BR_UNFOCUSED"
                    return [
                        (frame: closeFrame, action: {
                            tab.closePanel(topRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.closePanel(bottomRight.id, force: true)
                        }),
                    ]
                default:
                    guard let bottomRight else { return [] }
                    closeOrder = "TR_THEN_BR"
                    return [
                        (frame: closeFrame, action: {
                            tab.focusPanel(topRight.id)
                            tab.closePanel(topRight.id, force: true)
                        }),
                        (frame: secondCloseFrame, action: {
                            tab.focusPanel(bottomRight.id)
                            tab.closePanel(bottomRight.id, force: true)
                        }),
                    ]
                }
            }()

            let targets: [(label: String, view: GhosttySurfaceScrollView)] = {
                switch pattern {
                case "close_right_single":
                    return [
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                    ]
                case "close_bottom":
                    return [
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                        ("TR", topRight.surface.hostedView),
                    ]
                case "close_right_lrtd_bottom_first", "close_right_bottom_first":
                    return [
                        ("TR", topRight.surface.hostedView),
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                    ]
                default:
                    guard let bottomLeft else { return [] }
                    return [
                        ("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                        ("BL", bottomLeft.surface.hostedView),
                    ]
                }
            }()

            let result = await captureVsyncIOSurfaceTimeline(
                frameCount: desiredFrames,
                closeFrame: closeFrame,
                crop: sampleCrop,
                targets: targets,
                actions: actions
            )

            let paneStateTrace: String = {
                tab.bonsplitController.allPaneIds.map { paneId in
                    let tabs = tab.bonsplitController.tabs(inPane: paneId)
                    let selected = tab.bonsplitController.selectedTab(inPane: paneId)
                    let selectedId = selected.map { String(describing: $0.id) } ?? "nil"
                    let selectedPanelId = selected.flatMap { tab.panelIdFromSurfaceId($0.id) }
                    let selectedPanelLive: String = {
                        guard let selected else { return "0" }
                        return tab.panel(for: selected.id) != nil ? "1" : "0"
                    }()
                    let mappedCount = tabs.filter { tab.panelIdFromSurfaceId($0.id) != nil }.count
                    let selectedPanel = selectedPanelId?.uuidString.prefix(8) ?? "nil"
                    return "pane=\(paneId.id.uuidString.prefix(8)):tabs=\(tabs.count):mapped=\(mappedCount):selected=\(selectedId.prefix(8)):selectedPanel=\(selectedPanel):selectedLive=\(selectedPanelLive)"
                }.joined(separator: ";")
            }()

            writeSplitCloseRightTestData([
                "pattern": pattern,
                "iteration": String(i),
                "closeDelayMs": String(closeDelayMs),
                "closeDelayFrames": String(delayFrames),
                "closeOrder": closeOrder,
                "timelineFrameCount": String(desiredFrames),
                "timelineCloseFrame": String(closeFrame),
                "timelineSecondCloseFrame": String(secondCloseFrame),
                "timelineFirstBlank": result.firstBlank.map { "\($0.label)@\($0.frame)" } ?? "",
                "timelineFirstSizeMismatch": result.firstSizeMismatch.map { "\($0.label)@\($0.frame):ios=\($0.ios):exp=\($0.expected)" } ?? "",
                "timelineTrace": result.trace.joined(separator: "|"),
                "timelinePaneState": paneStateTrace,
                "visualLastIteration": String(i),
            ], at: path)

            if let firstBlank = result.firstBlank {
                writeSplitCloseRightTestData([
                    "blankFrameSeen": "1",
                    "blankObservedIteration": String(i),
                    "blankObservedAt": "\(firstBlank.label)@\(firstBlank.frame)"
                ], at: path)
                return
            }

            if let firstMismatch = result.firstSizeMismatch {
                writeSplitCloseRightTestData([
                    "sizeMismatchSeen": "1",
                    "sizeMismatchObservedIteration": String(i),
                    "sizeMismatchObservedAt": "\(firstMismatch.label)@\(firstMismatch.frame):ios=\(firstMismatch.ios):exp=\(firstMismatch.expected)"
                ], at: path)
                return
            }
        }
	    }

	    @MainActor
	    private func captureVsyncIOSurfaceTimeline(
	        frameCount: Int,
	        closeFrame: Int,
	        crop: CGRect,
	        targets: [(label: String, view: GhosttySurfaceScrollView)],
	        actions: [(frame: Int, action: () -> Void)] = []
	    ) async -> (firstBlank: (label: String, frame: Int)?, firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?, trace: [String]) {
	        guard frameCount > 0 else { return (nil, nil, []) }

	        let st = VsyncIOSurfaceTimelineState(frameCount: frameCount, closeFrame: closeFrame)
	        st.scheduledActions = actions.sorted(by: { $0.frame < $1.frame })
	        st.nextActionIndex = 0
	        st.targets = targets.map { t in
	            VsyncIOSurfaceTimelineState.Target(label: t.label, sample: { @MainActor in
	                t.view.debugSampleIOSurface(normalizedCrop: crop)
	            })
	        }

	        let unmanaged = Unmanaged.passRetained(st)
	        let ctx = unmanaged.toOpaque()

	        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
	            st.continuation = cont
	            var link: CVDisplayLink?
	            CVDisplayLinkCreateWithActiveCGDisplays(&link)
	            guard let link else {
	                st.finish()
	                Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).release()
	                return
	            }
	            st.link = link

	            CVDisplayLinkSetOutputCallback(link, cmuxVsyncIOSurfaceTimelineCallback, ctx)
	            CVDisplayLinkStart(link)
	        }

	        return (st.firstBlank, st.firstSizeMismatch, st.trace)
	    }

    private func writeSplitCloseRightTestData(_ updates: [String: String], at path: String) {
        var payload = loadSplitCloseRightTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadSplitCloseRightTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func setupChildExitSplitUITestIfNeeded() {
        guard !didSetupChildExitSplitUITest else { return }
        didSetupChildExitSplitUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_PATH"], !path.isEmpty else { return }
        let requestedIterations = Int(env["CMUX_UI_TEST_CHILD_EXIT_SPLIT_ITERATIONS"] ?? "1") ?? 1
        let iterations = max(1, min(requestedIterations, 20))

        func write(_ updates: [String: String]) {
            var payload: [String: String] = {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    return [:]
                }
                return obj
            }()
            for (k, v) in updates { payload[k] = v }
            guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Small delay so the initial window/panel has completed first layout.
            try? await Task.sleep(nanoseconds: 200_000_000)

            guard let tab = self.selectedWorkspace else {
                write(["setupError": "Missing selected workspace", "done": "1"])
                return
            }
            write([
                "requestedIterations": String(requestedIterations),
                "iterations": String(iterations),
                "workspaceCountBefore": String(self.tabs.count),
                "panelCountBefore": String(tab.panels.count),
                "done": "0",
            ])

            var completedIterations = 0
            var timedOut = false
            var closedWorkspace = false

            for i in 1...iterations {
                guard self.tabs.contains(where: { $0.id == tab.id }) else {
                    closedWorkspace = true
                    break
                }

                guard let leftPanelId = tab.focusedPanelId ?? tab.panels.keys.first else {
                    write(["setupError": "Missing focused panel before iteration \(i)", "done": "1"])
                    return
                }

                // Start each iteration from a deterministic 1x1 workspace.
                if tab.panels.count > 1 {
                    for panelId in tab.panels.keys where panelId != leftPanelId {
                        tab.closePanel(panelId, force: true)
                    }
                    let collapsed = await self.waitForWorkspacePanelsCondition(
                        tab: tab,
                        timeoutSeconds: 2.0
                    ) { workspace in
                        workspace.panels.count == 1
                    }
                    if !collapsed {
                        write(["setupError": "Timed out collapsing workspace before iteration \(i)", "done": "1"])
                        return
                    }
                }

                guard let rightPanel = tab.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                    write(["setupError": "Failed to create right split at iteration \(i)", "done": "1"])
                    return
                }

                write([
                    "iteration": String(i),
                    "leftPanelId": leftPanelId.uuidString,
                    "rightPanelId": rightPanel.id.uuidString,
                ])

                tab.focusPanel(rightPanel.id)
                // Wait for the split terminal surface to be attached before sending exit.
                // Without this, very early writes can be dropped during initial surface creation.
                _ = await self.waitForTerminalPanelCondition(
                    tab: tab,
                    panelId: rightPanel.id,
                    timeoutSeconds: 2.0
                ) { panel in
                    panel.surface.isViewInWindow && panel.surface.surface != nil
                }
                // Use an explicit shell exit command for deterministic child-exit behavior across
                // startup timing variance; this still exercises the same SHOW_CHILD_EXITED path.
                rightPanel.sendText("exit\r")

                // Wait for the right panel to close.
                let closed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    var cancellable: AnyCancellable?
                    var resolved = false

                    func finish(_ value: Bool) {
                        guard !resolved else { return }
                        resolved = true
                        cancellable?.cancel()
                        cont.resume(returning: value)
                    }

                    cancellable = tab.panelsPublisher
                        .map { $0.count }
                        .removeDuplicates()
                        .sink { count in
                            if count == 1 {
                                finish(true)
                            }
                        }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                        finish(false)
                    }
                }

                if !closed {
                    timedOut = true
                    write(["timedOutIteration": String(i)])
                    break
                }

                if !self.tabs.contains(where: { $0.id == tab.id }) {
                    closedWorkspace = true
                    write(["closedWorkspaceIteration": String(i)])
                    break
                }

                completedIterations = i
            }

            let workspaceStillOpen = self.tabs.contains(where: { $0.id == tab.id })
            let effectiveClosedWorkspace = closedWorkspace || !workspaceStillOpen

            write([
                "workspaceCountAfter": String(self.tabs.count),
                "panelCountAfter": String(tab.panels.count),
                "workspaceStillOpen": workspaceStillOpen ? "1" : "0",
                "closedWorkspace": effectiveClosedWorkspace ? "1" : "0",
                "timedOut": timedOut ? "1" : "0",
                "completedIterations": String(completedIterations),
                "done": "1",
            ])
        }
    }

    private func setupChildExitKeyboardUITestIfNeeded() {
        guard !didSetupChildExitKeyboardUITest else { return }
        didSetupChildExitKeyboardUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"], !path.isEmpty else { return }
        let autoTrigger = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_AUTO_TRIGGER"] == "1"
        let strictKeyOnly = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_STRICT"] == "1"
        let triggerMode = (env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_TRIGGER_MODE"] ?? "shell_input")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let useEarlyCtrlShiftTrigger = triggerMode == "early_ctrl_shift_d"
        let useEarlyCtrlDTrigger = triggerMode == "early_ctrl_d"
        let useEarlyTrigger = useEarlyCtrlShiftTrigger || useEarlyCtrlDTrigger
        let triggerUsesShift = triggerMode == "ctrl_shift_d" || useEarlyCtrlShiftTrigger
        let layout = (env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_LAYOUT"] ?? "lr")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedPanelsAfter = max(
            1,
            Int((env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_EXPECTED_PANELS_AFTER"] ?? "1")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ) ?? 1
        )

        func write(_ updates: [String: String]) {
            var payload: [String: String] = {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    return [:]
                }
                return obj
            }()
            for (k, v) in updates { payload[k] = v }
            guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)

            guard let tab = self.selectedWorkspace else {
                write(["setupError": "Missing selected workspace", "done": "1"])
                return
            }
            guard let leftPanelId = tab.focusedPanelId else {
                write(["setupError": "Missing initial focused panel", "done": "1"])
                return
            }
            guard let rightPanel = tab.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                write(["setupError": "Failed to create right split", "done": "1"])
                return
            }

            var bottomLeftPanelId = ""
            let topRightPanelId = rightPanel.id.uuidString
            var bottomRightPanelId = ""
            var exitPanelId = rightPanel.id

            if layout == "lr_left_vertical" {
                guard let bottomLeft = tab.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
            } else if layout == "lrtd_close_right_then_exit_top_left" {
                guard let bottomLeft = tab.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                guard let bottomRight = tab.newTerminalSplit(from: rightPanel.id, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-right split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
                bottomRightPanelId = bottomRight.id.uuidString

                // Repro flow: with a 2x2 (left/right then top/down), close both right panes,
                // then trigger Ctrl+D in top-left.
                tab.focusPanel(rightPanel.id)
                tab.closePanel(rightPanel.id, force: true)
                tab.focusPanel(bottomRight.id)
                tab.closePanel(bottomRight.id, force: true)
                exitPanelId = leftPanelId

                let collapsed = await self.waitForWorkspacePanelsCondition(
                    tab: tab,
                    timeoutSeconds: 2.0
                ) { workspace in
                    workspace.panels.count == 2
                }
                if !collapsed {
                    write([
                        "setupError": "Expected 2 panels after closing right column, got \(tab.panels.count)",
                        "done": "1",
                    ])
                    return
                }
            } else if layout == "tdlr_close_bottom_then_exit_top_left" {
                // Alternate repro flow:
                // 1) split top/down
                // 2) split left/right for each row (2x2)
                // 3) close both bottom panes
                // 4) trigger Ctrl+D in top-left
                guard let bottomLeft = tab.newTerminalSplit(from: leftPanelId, orientation: .vertical) else {
                    write(["setupError": "Failed to create bottom-left split", "done": "1"])
                    return
                }
                guard let topRight = tab.newTerminalSplit(from: leftPanelId, orientation: .horizontal) else {
                    write(["setupError": "Failed to create top-right split", "done": "1"])
                    return
                }
                guard let bottomRight = tab.newTerminalSplit(from: bottomLeft.id, orientation: .horizontal) else {
                    write(["setupError": "Failed to create bottom-right split", "done": "1"])
                    return
                }
                bottomLeftPanelId = bottomLeft.id.uuidString
                bottomRightPanelId = bottomRight.id.uuidString

                // Close every pane except the top row; do it one-by-one and wait for model convergence.
                let keepPanels: Set<UUID> = [leftPanelId, topRight.id]
                for panelId in Array(tab.panels.keys) where !keepPanels.contains(panelId) {
                    tab.focusPanel(panelId)
                    tab.closePanel(panelId, force: true)
                    let closed = await self.waitForWorkspacePanelsCondition(
                        tab: tab,
                        timeoutSeconds: 1.0
                    ) { workspace in
                        workspace.panels[panelId] == nil
                    }
                    if !closed {
                        write([
                            "setupError": "Failed to close bottom pane \(panelId.uuidString)",
                            "done": "1",
                        ])
                        return
                    }
                }
                exitPanelId = leftPanelId

                let collapsed = await self.waitForWorkspacePanelsCondition(
                    tab: tab,
                    timeoutSeconds: 2.0
                ) { workspace in
                    workspace.panels.count == 2
                }
                if !collapsed {
                    write([
                        "setupError": "Expected 2 panels after closing bottom row, got \(tab.panels.count)",
                        "done": "1",
                    ])
                    return
                }
            }

            tab.focusPanel(exitPanelId)
            // Keep child-exit keyboard tests deterministic across user shell configs.
            // `exec cat` exits on a single Ctrl+D and avoids ignore-eof shell settings.
            if let exitPanel = tab.terminalPanel(for: exitPanelId) {
                exitPanel.sendText("exec cat\r")
            }

            var exitPanelAttachedBeforeCtrlD = false
            var exitPanelHasSurfaceBeforeCtrlD = false
            if !useEarlyTrigger {
                let readiness = await self.waitForTerminalPanelReadyForUITest(
                    tab: tab,
                    panelId: exitPanelId
                )
                exitPanelAttachedBeforeCtrlD = readiness.attached
                exitPanelHasSurfaceBeforeCtrlD = readiness.hasSurface
                if !(readiness.attached && readiness.hasSurface) {
                    write([
                        "exitPanelAttachedBeforeCtrlD": readiness.attached ? "1" : "0",
                        "exitPanelHasSurfaceBeforeCtrlD": readiness.hasSurface ? "1" : "0",
                        "setupError": "Exit panel not ready for Ctrl+D (not attached or surface nil)",
                        "done": "1",
                    ])
                    return
                }
                self.ensureFocusedTerminalFirstResponder()
            } else if let exitPanel = tab.terminalPanel(for: exitPanelId) {
                exitPanelAttachedBeforeCtrlD = exitPanel.surface.isViewInWindow
                exitPanelHasSurfaceBeforeCtrlD = exitPanel.surface.surface != nil
            }

            let focusedPanelBefore = tab.focusedPanelId?.uuidString ?? ""
            let firstResponderPanelBefore = tab.panels.compactMap { (panelId, panel) -> UUID? in
                guard let terminal = panel as? TerminalPanel else { return nil }
                return terminal.hostedView.isSurfaceViewFirstResponder() ? panelId : nil
            }.first?.uuidString ?? ""

            write([
                "workspaceId": tab.id.uuidString,
                "leftPanelId": leftPanelId.uuidString,
                "rightPanelId": rightPanel.id.uuidString,
                "topRightPanelId": topRightPanelId,
                "bottomLeftPanelId": bottomLeftPanelId,
                "bottomRightPanelId": bottomRightPanelId,
                "exitPanelId": exitPanelId.uuidString,
                "panelCountBeforeCtrlD": String(tab.panels.count),
                "layout": layout,
                "expectedPanelsAfter": String(expectedPanelsAfter),
                "focusedPanelBefore": focusedPanelBefore,
                "firstResponderPanelBefore": firstResponderPanelBefore,
                "exitPanelAttachedBeforeCtrlD": exitPanelAttachedBeforeCtrlD ? "1" : "0",
                "exitPanelHasSurfaceBeforeCtrlD": exitPanelHasSurfaceBeforeCtrlD ? "1" : "0",
                "ready": "1",
                "done": "0",
            ])

            var finished = false
            var timeoutWork: DispatchWorkItem?

            @MainActor
            func finish(_ updates: [String: String]) {
                guard !finished else { return }
                finished = true
                timeoutWork?.cancel()
                write(updates.merging(["done": "1"], uniquingKeysWith: { _, new in new }))
                self.uiTestCancellables.removeAll()
            }

            tab.panelsPublisher
                .map { $0.count }
                .removeDuplicates()
                .sink { [weak self, weak tab] count in
                    Task { @MainActor in
                        guard let self, let tab else { return }
                        if count == expectedPanelsAfter {
                            // Require the post-exit state to be stable for a short window so
                            // we catch "close looked correct, then workspace vanished" races.
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            guard tab.panels.count == expectedPanelsAfter else { return }

                            let firstResponderPanelAfter = tab.panels.compactMap { (panelId, panel) -> UUID? in
                                guard let terminal = panel as? TerminalPanel else { return nil }
                                return terminal.hostedView.isSurfaceViewFirstResponder() ? panelId : nil
                            }.first?.uuidString ?? ""

                            finish([
                                "workspaceCountAfter": String(self.tabs.count),
                                "panelCountAfter": String(tab.panels.count),
                                "closedWorkspace": self.tabs.contains(where: { $0.id == tab.id }) ? "0" : "1",
                                "focusedPanelAfter": tab.focusedPanelId?.uuidString ?? "",
                                "firstResponderPanelAfter": firstResponderPanelAfter,
                            ])
                        }
                    }
                }
                .store(in: &uiTestCancellables)

            tabsPublisher
                .map { $0.contains(where: { $0.id == tab.id }) }
                .removeDuplicates()
                .sink { alive in
                    Task { @MainActor in
                        if !alive {
                            finish([
                                "workspaceCountAfter": "0",
                                "panelCountAfter": "0",
                                "closedWorkspace": "1",
                            ])
                        }
                    }
                }
                .store(in: &uiTestCancellables)

            let work = DispatchWorkItem {
                finish([
                    "workspaceCountAfter": String(self.tabs.count),
                    "panelCountAfter": String(tab.panels.count),
                    "closedWorkspace": self.tabs.contains(where: { $0.id == tab.id }) ? "0" : "1",
                    "timedOut": "1",
                ])
            }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)

            if autoTrigger {
                Task { @MainActor [weak tab] in
                    guard let tab else { return }
                    write(["autoTriggerStarted": "1"])

                    if triggerMode == "runtime_close_callback" {
                        write(["autoTriggerMode": "runtime_close_callback"])
                        self.closePanelAfterChildExited(tabId: tab.id, surfaceId: exitPanelId)
                        return
                    }

                    let triggerModifiers: NSEvent.ModifierFlags = triggerUsesShift
                        ? [.control, .shift]
                        : [.control]
                    let shouldWaitForSurface = !useEarlyTrigger

                    var attachedBeforeTrigger = false
                    var hasSurfaceBeforeTrigger = false
                    if shouldWaitForSurface {
                        let ready = await self.waitForTerminalPanelCondition(
                            tab: tab,
                            panelId: exitPanelId,
                            timeoutSeconds: 5.0
                        ) { panel in
                            attachedBeforeTrigger = panel.surface.isViewInWindow
                            hasSurfaceBeforeTrigger = panel.surface.surface != nil
                            return attachedBeforeTrigger && hasSurfaceBeforeTrigger
                        }
                        if !ready,
                           tab.terminalPanel(for: exitPanelId) == nil {
                            write(["autoTriggerError": "missingExitPanelBeforeTrigger"])
                            return
                        }
                    } else if let panel = tab.terminalPanel(for: exitPanelId) {
                        attachedBeforeTrigger = panel.surface.isViewInWindow
                        hasSurfaceBeforeTrigger = panel.surface.surface != nil
                    }
                    write([
                        "exitPanelAttachedBeforeTrigger": attachedBeforeTrigger ? "1" : "0",
                        "exitPanelHasSurfaceBeforeTrigger": hasSurfaceBeforeTrigger ? "1" : "0",
                    ])
                    if shouldWaitForSurface && !(attachedBeforeTrigger && hasSurfaceBeforeTrigger) {
                        write(["autoTriggerError": "exitPanelNotReadyBeforeTrigger"])
                        return
                    }

                    guard let panel = tab.terminalPanel(for: exitPanelId) else {
                        write(["autoTriggerError": "missingExitPanelAtTrigger"])
                        return
                    }
                    // Exercise the real key path (ghostty_surface_key for Ctrl+D).
                    if panel.hostedView.sendSyntheticCtrlDForUITest(modifierFlags: triggerModifiers) {
                        write(["autoTriggerSentCtrlDKey1": "1"])
                    } else {
                        write([
                            "autoTriggerCtrlDKeyUnavailable": "1",
                            "autoTriggerError": "ctrlDKeyUnavailable",
                        ])
                        return
                    }

                    // In strict mode, never mask routing bugs with fallback writes.
                    if strictKeyOnly {
                        let strictModeLabel: String = {
                            if useEarlyCtrlShiftTrigger { return "strict_early_ctrl_shift_d" }
                            if useEarlyCtrlDTrigger { return "strict_early_ctrl_d" }
                            if triggerUsesShift { return "strict_ctrl_shift_d" }
                            return "strict_ctrl_d"
                        }()
                        write(["autoTriggerMode": strictModeLabel])
                        return
                    }

                    // Non-strict mode keeps one additional Ctrl+D retry for startup timing variance.
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if tab.panels[exitPanelId] != nil,
                       panel.hostedView.sendSyntheticCtrlDForUITest(modifierFlags: triggerModifiers) {
                        write(["autoTriggerSentCtrlDKey2": "1"])
                    }
                }
            }
        }
    }
#endif
}

extension TabManager {
    func sessionAutosaveFingerprint(
        restorableAgentIndex: RestorableAgentSessionIndex = .empty,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex = .empty
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(selectedTabId)
        hasher.combine(tabs.count)
        let notificationStore = AppDelegate.shared?.notificationStore

        // Workspace groups participate in the session snapshot, so changes
        // that only touch group metadata (rename / collapse / pin a group,
        // or move a workspace between groups without reordering tabs) must
        // bump the fingerprint or the autosave timer skips the write.
        hasher.combine(workspaceGroups.count)
        for group in workspaceGroups {
            hasher.combine(group.id)
            hasher.combine(group.name)
            hasher.combine(group.isCollapsed)
            hasher.combine(group.isPinned)
            hasher.combine(group.anchorWorkspaceId)
            hasher.combine(group.customColor ?? "")
            hasher.combine(group.iconSymbol ?? "")
        }
        for workspace in tabs.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow) {
            hasher.combine(workspace.id)
            hasher.combine(workspace.groupId)
            hasher.combine(workspace.focusedPanelId)
            hasher.combine(workspace.currentDirectory)
            hasher.combine(workspace.customTitle ?? "")
            hasher.combine(workspace.customDescription ?? "")
            hasher.combine(workspace.customColor ?? "")
            hasher.combine(workspace.isPinned)
            hasher.combine(workspace.panels.count)
            hasher.combine(workspace.statusEntries.count)
            hasher.combine(workspace.metadataBlocks.count)
            hasher.combine(workspace.logEntries.count)
            hasher.combine(workspace.panelDirectories.count)
            hasher.combine(workspace.panelTitles.count)
            hasher.combine(workspace.panelPullRequests.count)
            hasher.combine(workspace.panelGitBranches.count)
            hasher.combine(workspace.surfaceListeningPorts.count)
            hasher.combine(notificationStore?.hasManualUnread(forTabId: workspace.id) ?? false)
            hasher.combine(notificationStore?.workspaceIsUnread(forTabId: workspace.id) ?? false)
            Self.hashNotifications(
                notificationStore?.notifications(forTabId: workspace.id, surfaceId: nil) ?? [],
                into: &hasher
            )

            let panelIds = workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }
            hasher.combine(panelIds.count)
            for panelId in panelIds {
                hasher.combine(panelId)
                hasher.combine(workspace.manualUnreadPanelIds.contains(panelId))
                hasher.combine(workspace.restoredUnreadPanelIds.contains(panelId))
                hasher.combine(workspace.restoredUnreadIndicatorContributesToWorkspace(panelId: panelId))
                hasher.combine(
                    notificationStore?.hasVisibleNotificationIndicator(
                        forTabId: workspace.id,
                        surfaceId: panelId
                    ) ?? false
                )
                Self.hashNotifications(
                    notificationStore?.notifications(forTabId: workspace.id, surfaceId: panelId) ?? [],
                    into: &hasher
                )
                Self.hashRestorableAgentSnapshot(
                    restorableAgentIndex.snapshot(
                        workspaceId: workspace.id,
                        panelId: panelId
                    ),
                    into: &hasher
                )
                Self.hashAgentHibernationPanelState(
                    (workspace.panels[panelId] as? TerminalPanel)?.agentHibernationState,
                    into: &hasher
                )
                Self.hashSurfaceResumeBindingSnapshot(
                    workspace.effectiveSurfaceResumeBinding(
                        panelId: panelId,
                        surfaceResumeBindingIndex: surfaceResumeBindingIndex
                    ),
                    into: &hasher
                )
                if let terminalPanel = workspace.terminalPanel(for: panelId) {
                    Self.hashTextBoxDraftSnapshot(
                        terminalPanel.sessionTextBoxDraftSnapshot(),
                        into: &hasher
                    )
                } else {
                    hasher.combine(false)
                }
            }

            if let progress = workspace.progress {
                hasher.combine(Int((progress.value * 1000).rounded()))
                hasher.combine(progress.label)
            } else {
                hasher.combine(-1)
            }

            if let gitBranch = workspace.gitBranch {
                hasher.combine(gitBranch.branch)
                hasher.combine(gitBranch.isDirty)
            } else {
                hasher.combine("")
                hasher.combine(false)
            }
        }

        return hasher.finalize()
    }

    nonisolated static func restorableAgentSnapshotFingerprint(
        _ snapshot: SessionRestorableAgentSnapshot?
    ) -> Int {
        var hasher = Hasher()
        hashRestorableAgentSnapshot(snapshot, into: &hasher)
        return hasher.finalize()
    }

    nonisolated private static func hashRestorableAgentSnapshot(
        _ snapshot: SessionRestorableAgentSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.kind.rawValue)
        hasher.combine(snapshot.sessionId)
        hashOptionalString(snapshot.workingDirectory, into: &hasher)
        hashAgentLaunchCommand(snapshot.launchCommand, into: &hasher)
    }

    nonisolated private static func hashAgentLaunchCommand(
        _ launchCommand: AgentLaunchCommandSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let launchCommand else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashOptionalString(launchCommand.launcher, into: &hasher)
        hashOptionalString(launchCommand.executablePath, into: &hasher)
        hasher.combine(launchCommand.arguments)
        hashOptionalString(launchCommand.workingDirectory, into: &hasher)
        if let environment = launchCommand.environment {
            hasher.combine(true)
            hasher.combine(environment.count)
            for key in environment.keys.sorted() {
                hasher.combine(key)
                hasher.combine(environment[key])
            }
        } else {
            hasher.combine(false)
        }
        hashOptionalDouble(launchCommand.capturedAt, into: &hasher)
        hashOptionalString(launchCommand.source, into: &hasher)
    }

    private static func hashAgentHibernationPanelState(
        _ state: AgentHibernationPanelState?,
        into hasher: inout Hasher
    ) {
        guard let state else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashRestorableAgentSnapshot(state.agent, into: &hasher)
        hasher.combine(state.hibernatedAt.timeIntervalSince1970)
        hasher.combine(state.lastActivityAt.timeIntervalSince1970)
    }

    nonisolated private static func hashSurfaceResumeBindingSnapshot(
        _ snapshot: SurfaceResumeBindingSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashOptionalString(snapshot.name, into: &hasher)
        hashOptionalString(snapshot.kind, into: &hasher)
        hasher.combine(snapshot.command)
        hashOptionalString(snapshot.cwd, into: &hasher)
        hashOptionalString(snapshot.checkpointId, into: &hasher)
        hashOptionalString(snapshot.source, into: &hasher)
        hashStringMap(snapshot.environment, into: &hasher)
        hasher.combine(snapshot.allowsAutomaticResume)
        if snapshot.isProcessDetected {
            hasher.combine(false)
        } else {
            hashOptionalDouble(snapshot.updatedAt, into: &hasher)
        }
    }

    nonisolated private static func hashTextBoxDraftSnapshot(
        _ snapshot: SessionTextBoxInputDraftSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.isActive)
        hasher.combine(snapshot.parts.count)
        for part in snapshot.parts {
            hasher.combine(part.kind.rawValue)
            hashOptionalString(part.text, into: &hasher)
            hashTextBoxAttachmentSnapshot(part.attachment, into: &hasher)
        }
    }

    nonisolated private static func hashTextBoxAttachmentSnapshot(
        _ snapshot: SessionTextBoxInputAttachmentSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.displayName)
        hasher.combine(snapshot.submissionText)
        hasher.combine(snapshot.submissionPath)
        hashOptionalString(snapshot.localPath, into: &hasher)
        hasher.combine(snapshot.cleanupLocalPathWhenDisposed)
    }

    nonisolated private static func hashNotifications(
        _ notifications: [TerminalNotification],
        into hasher: inout Hasher
    ) {
        hasher.combine(notifications.count)
        for notification in notifications.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hasher.combine(notification.id)
            hasher.combine(notification.title)
            hasher.combine(notification.subtitle)
            hasher.combine(notification.body)
            hasher.combine(notification.createdAt.timeIntervalSince1970)
            hasher.combine(notification.isRead)
            hasher.combine(notification.paneFlash)
            hasher.combine(notification.panelId)
            hasher.combine(notification.clickAction)
        }
    }

    nonisolated private static func hashOptionalString(_ value: String?, into hasher: inout Hasher) {
        if let value {
            hasher.combine(true)
            hasher.combine(value)
        } else {
            hasher.combine(false)
        }
    }

    nonisolated private static func hashOptionalDouble(_ value: Double?, into hasher: inout Hasher) {
        if let value {
            hasher.combine(true)
            hasher.combine(value)
        } else {
            hasher.combine(false)
        }
    }

    nonisolated private static func hashStringMap(_ value: [String: String]?, into hasher: inout Hasher) {
        guard let value, !value.isEmpty else {
            hasher.combine(false)
            return
        }
        hasher.combine(true)
        let keys = value.keys.sorted()
        hasher.combine(keys.count)
        for key in keys {
            hasher.combine(key)
            hasher.combine(value[key] ?? "")
        }
    }

    func sessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex = .empty,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> SessionTabManagerSnapshot {
        let restorableTabs = tabs
            .filter(\.isRestorableInSessionSnapshot)
            .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
        let workspaceSnapshots = restorableTabs
            .map {
                $0.sessionSnapshot(
                    includeScrollback: includeScrollback,
                    restorableAgentIndex: restorableAgentIndex,
                    surfaceResumeBindingIndex: surfaceResumeBindingIndex
                )
            }
        let selectedWorkspaceIndex = selectedTabId.flatMap { selectedTabId in
            restorableTabs.firstIndex(where: { $0.id == selectedTabId })
        }
        let occupiedGroupIds = Set(restorableTabs.compactMap(\.groupId))
        // Build a per-group ordered list of restorable member IDs so we can
        // record the anchor's index (restore-stable across UUID rotation).
        let restorableMembersByGroupId: [UUID: [UUID]] = {
            var map: [UUID: [UUID]] = [:]
            for tab in restorableTabs {
                if let gid = tab.groupId {
                    map[gid, default: []].append(tab.id)
                }
            }
            return map
        }()
        let groupSnapshots: [SessionWorkspaceGroupSnapshot]? = {
            let snapshots = workspaceGroups
                .filter { occupiedGroupIds.contains($0.id) }
                .map { group in
                    let memberIds = restorableMembersByGroupId[group.id] ?? []
                    let anchorIndex = memberIds.firstIndex(of: group.anchorWorkspaceId)
                    return SessionWorkspaceGroupSnapshot(
                        id: group.id,
                        name: group.name,
                        isCollapsed: group.isCollapsed,
                        anchorWorkspaceId: group.anchorWorkspaceId,
                        anchorMemberIndex: anchorIndex,
                        isPinned: group.isPinned,
                        customColor: group.customColor,
                        iconSymbol: group.iconSymbol
                    )
                }
            return snapshots.isEmpty ? nil : snapshots
        }()
        return SessionTabManagerSnapshot(
            selectedWorkspaceIndex: selectedWorkspaceIndex,
            workspaces: workspaceSnapshots,
            workspaceGroups: groupSnapshots
        )
    }

    func sessionSnapshotWorkspaceIds() -> [UUID] {
        Array(
            tabs
                .filter(\.isRestorableInSessionSnapshot)
                .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
                .map(\.id)
        )
    }

    private func releaseRestoredAwayWorkspace(_ workspace: Workspace) {
        // Session restore replaces the bootstrap workspace objects with freshly
        // restored ones. Tear the old graph down after the atomic swap so late
        // panel/socket callbacks cannot keep mutating hidden pre-restore state.
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspace.id)
        workspace.teardownAllPanels()
        workspace.teardownRemoteConnection()
        workspace.owningTabManager = nil
    }

    @discardableResult
    func restoreSessionSnapshot(
        _ snapshot: SessionTabManagerSnapshot,
        remapClosedPanelHistory: Bool = true
    ) -> [[UUID: UUID]] {
        isRestoringSessionSnapshot = true
        defer { isRestoringSessionSnapshot = false }
        let previousTabs = tabs
        for tab in previousTabs {
            unwireClosedBrowserTracking(for: tab)
        }
        ClosedItemHistoryStore.shared.removePanelRecords(
            forWorkspaceIds: Set(previousTabs.map(\.id))
        )
        sidebarGitMetadataService.resetAllWorkspaceGitProbeTracking()

        // Clear non-@Published state without touching tabs/selectedTabId yet.
        lastFocusedPanelByTab.removeAll()
        pendingPanelTitleUpdates.removeAll()
        focusHistoryNavigation.reset()
        focusHistoryRevision &+= 1
        pendingWorkspaceUnfocusTarget = nil
        workspaceCycleCooldownTask?.cancel()
        workspaceCycleCooldownTask = nil
        isWorkspaceCycleHot = false
        selectionSideEffectsGeneration &+= 1
        browserModel.clearRecentlyClosedBrowserPanels()

        // Build the new workspace list locally to avoid intermediate @Published
        // emissions (empty tabs, nil selectedTabId) that can leave SwiftUI's
        // mountedWorkspaceIds empty and cause a frozen blank launch state (#399).
        var newTabs: [Workspace] = []
        var restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]] = []
        let workspaceSnapshots = Array(snapshot.workspaces
            .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
        )
        let selectedWorkspaceIndex = snapshot.selectedWorkspaceIndex.flatMap { index in
            workspaceSnapshots.indices.contains(index) ? index : nil
        } ?? workspaceSnapshots.indices.first
        var restoredOriginalWorkspaceIds: [UUID?] = []
        for (workspaceIndex, workspaceSnapshot) in workspaceSnapshots.enumerated() {
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let workspace = Workspace(
                title: workspaceSnapshot.processTitle,
                workingDirectory: workspaceSnapshot.currentDirectory,
                portOrdinal: ordinal
            )
            workspace.owningTabManager = self
            let restoredPanelIds = workspace.restoreSessionSnapshot(
                workspaceSnapshot,
                renderRestoredBrowserWebViews: selectedWorkspaceIndex.map { workspaceIndex == $0 } ?? false
            )
            wireClosedBrowserTracking(for: workspace)
            newTabs.append(workspace)
            restoredPanelIdsByWorkspaceIndex.append(restoredPanelIds)
            restoredOriginalWorkspaceIds.append(workspaceSnapshot.workspaceId)
        }

        if newTabs.isEmpty {
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let fallback = Workspace(title: "Terminal 1", portOrdinal: ordinal)
            fallback.owningTabManager = self
            wireClosedBrowserTracking(for: fallback)
            newTabs.append(fallback)
        }

        // Determine selection before mutating @Published properties.
        let newSelectedId: UUID?
        if let selectedWorkspaceIndex,
           newTabs.indices.contains(selectedWorkspaceIndex) {
            newSelectedId = newTabs[selectedWorkspaceIndex].id
        } else {
            newSelectedId = newTabs.first?.id
        }

        // Single atomic assignment of @Published properties so SwiftUI observers
        // never see an intermediate state with empty tabs or nil selection.
        tabs = newTabs
        let restoredGroups: [WorkspaceGroup] = {
            guard let groupSnapshots = snapshot.workspaceGroups else { return [] }
            let workspaceIdsByGroupId: [UUID: [UUID]] = {
                var map: [UUID: [UUID]] = [:]
                for workspace in newTabs {
                    if let gid = workspace.groupId {
                        map[gid, default: []].append(workspace.id)
                    }
                }
                return map
            }()
            var seen: Set<UUID> = []
            return groupSnapshots.compactMap { groupSnapshot in
                guard let members = workspaceIdsByGroupId[groupSnapshot.id], !members.isEmpty,
                      seen.insert(groupSnapshot.id).inserted else { return nil }
                // Resolve anchor: prefer the restore-stable index (since each
                // restored workspace gets a fresh UUID, the old
                // anchorWorkspaceId rarely matches). Fall back to the in-process
                // UUID hint, then to "first member by tab order" for very old
                // snapshots that pre-date both fields.
                let anchorId: UUID = {
                    if let index = groupSnapshot.anchorMemberIndex,
                       members.indices.contains(index) {
                        return members[index]
                    }
                    if let stored = groupSnapshot.anchorWorkspaceId, members.contains(stored) {
                        return stored
                    }
                    return members[0]
                }()
                return WorkspaceGroup(
                    id: groupSnapshot.id,
                    name: groupSnapshot.name,
                    isCollapsed: groupSnapshot.isCollapsed,
                    isPinned: groupSnapshot.isPinned ?? false,
                    anchorWorkspaceId: anchorId,
                    customColor: groupSnapshot.customColor,
                    iconSymbol: groupSnapshot.iconSymbol
                )
            }
        }()
        // Clear any group references on restored workspaces that no longer correspond
        // to a known group (older snapshots, manual edits, etc.).
        let knownGroupIds = Set(restoredGroups.map(\.id))
        for workspace in newTabs where workspace.groupId.map({ !knownGroupIds.contains($0) }) ?? false {
            workspace.groupId = nil
        }
        workspaceGroups = restoredGroups
        selectedTabId = newSelectedId
        let existingIds = Set(newTabs.map(\.id))
        pruneBackgroundWorkspaceLoads(existingIds: existingIds)
        sidebarMultiSelection.intersectSelection(with: existingIds)
        for workspace in previousTabs {
            releaseRestoredAwayWorkspace(workspace)
        }
        for workspace in newTabs {
            let terminalPanels = workspace.panels.values.compactMap { $0 as? TerminalPanel }
            for terminalPanel in terminalPanels {
                scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspace.id,
                    panelId: terminalPanel.id
                )
            }
        }
        if remapClosedPanelHistory {
            remapClosedPanelHistoryAfterSessionRestore(
                originalWorkspaceIds: restoredOriginalWorkspaceIds,
                restoredPanelIdsByWorkspaceIndex: restoredPanelIdsByWorkspaceIndex
            )
        }

        if let selectedTabId {
            NotificationCenter.default.post(
                name: .ghosttyDidFocusTab,
                object: nil,
                userInfo: [GhosttyNotificationKey.tabId: selectedTabId]
            )
        }
        return restoredPanelIdsByWorkspaceIndex
    }

    func remapClosedPanelHistoryAfterSessionRestore(
        originalWorkspaceIds: [UUID?],
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]]
    ) {
        let count = min(originalWorkspaceIds.count, tabs.count)
        guard count > 0 else { return }
        var didRequestHistoryRemap = false
        for index in 0..<count {
            guard let originalWorkspaceId = originalWorkspaceIds[index],
                  originalWorkspaceId != tabs[index].id else {
                continue
            }
            didRequestHistoryRemap = true
            let panelIdMap = restoredPanelIdsByWorkspaceIndex.indices.contains(index)
                ? restoredPanelIdsByWorkspaceIndex[index]
                : [:]
            ClosedItemHistoryStore.shared.remapPanelWorkspaceIds(
                from: originalWorkspaceId,
                to: tabs[index].id,
                panelIdMap: panelIdMap
            )
        }
        if didRequestHistoryRemap {
            ClosedItemHistoryStore.shared.flushPendingSaves()
        }
    }

    func remapClosedPanelHistoryAfterWindowRestore(
        originalWorkspaceIds: [UUID],
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]]
    ) {
        guard !originalWorkspaceIds.isEmpty else { return }
        let count = min(originalWorkspaceIds.count, tabs.count)
        guard count > 0 else { return }
        var didRequestHistoryRemap = false
        for index in 0..<count {
            didRequestHistoryRemap = true
            let panelIdMap = restoredPanelIdsByWorkspaceIndex.indices.contains(index)
                ? restoredPanelIdsByWorkspaceIndex[index]
                : [:]
            ClosedItemHistoryStore.shared.remapPanelWorkspaceIds(
                from: originalWorkspaceIds[index],
                to: tabs[index].id,
                panelIdMap: panelIdMap
            )
        }
        if didRequestHistoryRemap {
            ClosedItemHistoryStore.shared.flushPendingSaves()
        }
    }
}

// The hook methods live in the class body (they touch private selection /
// DEBUG state); these extensions only bind the conformances.
extension TabManager: WorkspacesHosting {}
extension TabManager: WorkspaceGroupHosting {}

// Workspace satisfies the CmuxWorkspaces tab seam with its existing
// id/groupId/isPinned storage.
extension Workspace: WorkspaceTabRepresenting {}

extension Notification.Name {
    // The sidebar multi-selection sync events moved to CmuxSidebar as typed
    // SidebarMultiSelectionShouldCollapseEvent / DidHideEvent (same names).
    static let commandPaletteToggleRequested = Notification.Name("cmux.commandPaletteToggleRequested")
    static let commandPaletteRequested = Notification.Name("cmux.commandPaletteRequested")
    static let commandPaletteSwitcherRequested = Notification.Name("cmux.commandPaletteSwitcherRequested")
    static let commandPaletteSubmitRequested = Notification.Name("cmux.commandPaletteSubmitRequested")
    static let commandPaletteDismissRequested = Notification.Name("cmux.commandPaletteDismissRequested")
    static let commandPaletteRenameTabRequested = Notification.Name("cmux.commandPaletteRenameTabRequested")
    static let commandPaletteRenameWorkspaceRequested = Notification.Name("cmux.commandPaletteRenameWorkspaceRequested")
    static let commandPaletteEditWorkspaceDescriptionRequested = Notification.Name("cmux.commandPaletteEditWorkspaceDescriptionRequested")
    static let commandPaletteMoveSelection = Notification.Name("cmux.commandPaletteMoveSelection")
    static let commandPaletteRenameInputInteractionRequested = Notification.Name("cmux.commandPaletteRenameInputInteractionRequested")
    static let commandPaletteRenameInputDeleteBackwardRequested = Notification.Name("cmux.commandPaletteRenameInputDeleteBackwardRequested")
    static let feedbackComposerRequested = Notification.Name("cmux.feedbackComposerRequested")
    static let ghosttyDidSetTitle = Notification.Name("ghosttyDidSetTitle")
    static let ghosttyDidFocusTab = Notification.Name("ghosttyDidFocusTab")
    static let ghosttyDidFocusSurface = Notification.Name("ghosttyDidFocusSurface")
    static let ghosttyDidBecomeFirstResponderSurface = Notification.Name("ghosttyDidBecomeFirstResponderSurface")
    static let browserDidBecomeFirstResponderWebView = Notification.Name("browserDidBecomeFirstResponderWebView")
    static let browserFocusAddressBar = Notification.Name("browserFocusAddressBar")
    static let browserMoveOmnibarSelection = Notification.Name("browserMoveOmnibarSelection")
    static let browserDidExitAddressBar = Notification.Name("browserDidExitAddressBar")
    static let browserDidFocusAddressBar = Notification.Name("browserDidFocusAddressBar")
    static let browserDidBlurAddressBar = Notification.Name("browserDidBlurAddressBar")
    static let browserFocusModeStateDidChange = Notification.Name("cmux.browserFocusModeStateDidChange")
    static let webViewDidReceiveClick = Notification.Name("webViewDidReceiveClick")
    static let terminalPortalVisibilityDidChange = Notification.Name("cmux.terminalPortalVisibilityDidChange")
    static let browserPortalRegistryDidChange = Notification.Name("cmux.browserPortalRegistryDidChange")
    static let workspaceOrderDidChange = Notification.Name("cmux.workspaceOrderDidChange")
    /// Posted when an existing workspace group's `name` changes (rename). The
    /// imperatively-cached window-chrome surfaces (custom title bar in
    /// `ContentView`, toolbar command label in `WindowToolbarController`) read
    /// a grouped anchor's displayed name from `group.name` and refresh on this.
    static let workspaceGroupNameDidChange = Notification.Name("cmux.workspaceGroupNameDidChange")
    static let workspaceCurrentDirectoryDidChange = Notification.Name("cmux.workspaceCurrentDirectoryDidChange")
    static let tabManagerFocusHistoryRevisionDidChange = Notification.Name("cmux.tabManagerFocusHistoryRevisionDidChange")
}

enum BrowserFirstResponderNotificationUserInfoKey {
    static let pointerInitiated = "pointerInitiated"
}

extension TabManager: CMUXLeaderModeOwner {}
