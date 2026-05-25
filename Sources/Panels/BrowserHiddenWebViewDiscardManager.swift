import Foundation

@MainActor
protocol BrowserHiddenWebViewDiscardManagerDelegate: AnyObject {
    var hiddenWebViewDiscardSnapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot { get }
    var hiddenWebViewDiscardHiddenAt: Date? { get }
    var hiddenWebViewDiscardWebViewInstanceID: UUID { get }

    func hiddenWebViewDiscardManagerDidRequestDiscard(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    )
    func hiddenWebViewDiscardManagerPolicyDidChange(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    )
}

@MainActor
final class BrowserHiddenWebViewDiscardManager {
    private static let retentionCoordinator = BrowserHiddenWebViewRetentionCoordinator()

    struct BlockerSnapshot {
        let isClosing: Bool
        let isVisibleInUI: Bool
        let shouldRenderWebView: Bool
        let hasPendingRemoteNavigation: Bool
        let hasCurrentURL: Bool
        let isLoading: Bool
        let webViewIsLoading: Bool
        let isDownloading: Bool
        let activeDownloadCount: Int
        let preferredDeveloperToolsVisible: Bool
        let isDeveloperToolsVisible: Bool
        let isElementFullscreenActive: Bool
        let isReactGrabActive: Bool
        let hasPopups: Bool
    }

    weak var delegate: BrowserHiddenWebViewDiscardManagerDelegate?

    private var discardTimer: DispatchSourceTimer?
    private var policyObserver: NSObjectProtocol?
    private var policyState = BrowserHiddenWebViewDiscardPolicy.resolved()
    private var scheduleGeneration: UInt64 = 0

    private(set) var isDiscardedForMemory: Bool = false
    private(set) var discardedAt: Date?
    private(set) var lastDiscardReason: String?
    private(set) var lastRestoreReason: String?
    private(set) var restoredSessionShouldRenderWebView: Bool?

    var hasScheduledDiscard: Bool {
        discardTimer != nil || Self.retentionCoordinator.contains(self)
    }

    func blockers(for snapshot: BlockerSnapshot) -> [String] {
        var blockers: [String] = []
        if !BrowserHiddenWebViewDiscardPolicy.isEnabled { blockers.append("policy_disabled") }
        if snapshot.isClosing { blockers.append("closing") }
        if isDiscardedForMemory { blockers.append("already_discarded") }
        if snapshot.isVisibleInUI { blockers.append("visible") }
        if !snapshot.shouldRenderWebView { blockers.append("not_rendered") }
        if snapshot.hasPendingRemoteNavigation { blockers.append("pending_remote_navigation") }
        if !snapshot.hasCurrentURL { blockers.append("no_url") }
        if snapshot.isDownloading || snapshot.activeDownloadCount != 0 { blockers.append("download") }
        if snapshot.preferredDeveloperToolsVisible || snapshot.isDeveloperToolsVisible {
            blockers.append("developer_tools")
        }
        if snapshot.isElementFullscreenActive { blockers.append("fullscreen") }
        if snapshot.isReactGrabActive { blockers.append("react_grab") }
        if snapshot.hasPopups { blockers.append("popup") }
        return blockers
    }

    func scheduleIfNeeded(reason: String) {
        scheduleGeneration &+= 1
        discardTimer?.cancel()
        discardTimer = nil

        guard let delegate else {
            Self.retentionCoordinator.remove(self)
            return
        }
        guard blockers(for: delegate.hiddenWebViewDiscardSnapshot).isEmpty else {
            Self.retentionCoordinator.remove(self)
            return
        }

        let observedWebViewInstanceID = delegate.hiddenWebViewDiscardWebViewInstanceID
        let generation = scheduleGeneration
        let hiddenAt = delegate.hiddenWebViewDiscardHiddenAt ?? Date()
        let elapsed = Date().timeIntervalSince(hiddenAt)
        let remaining = max(0, BrowserHiddenWebViewDiscardPolicy.hiddenDelay - elapsed)
        Self.retentionCoordinator.retainIfEligible(self, reason: reason)
        if remaining <= 0 {
            Self.retentionCoordinator.enforceLimit(reason: reason)
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + remaining)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.scheduleGeneration == generation else { return }
                guard let delegate = self.delegate else { return }
                guard delegate.hiddenWebViewDiscardWebViewInstanceID == observedWebViewInstanceID else { return }
                self.discardTimer?.cancel()
                self.discardTimer = nil
                Self.retentionCoordinator.enforceLimit(reason: reason)
            }
        }
        discardTimer = timer
        timer.resume()
    }

    func cancel() {
        scheduleGeneration &+= 1
        discardTimer?.cancel()
        discardTimer = nil
        Self.retentionCoordinator.remove(self)
    }

    func installPolicyObserver() {
        policyState = BrowserHiddenWebViewDiscardPolicy.resolved()
        guard policyObserver == nil else { return }
        policyObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePolicyDefaultsChanged()
            }
        }
    }

    nonisolated func stop() {
        Task { @MainActor [self] in
            stopOnMainActor()
        }
    }

    func markDiscarded(reason: String, now: Date) {
        cancel()
        isDiscardedForMemory = true
        discardedAt = now
        lastDiscardReason = reason
        updateRestoredSessionRenderIntent(true)
    }

    @discardableResult
    func restoreIfNeeded(reason: String, performRestore: () -> Void) -> Bool {
        guard isDiscardedForMemory else { return false }
        cancel()
        guard clearDiscardState(reason: reason) else { return false }
        updateRestoredSessionRenderIntent(nil)
        performRestore()
        return true
    }

    @discardableResult
    func reactivateWithoutNavigation(reason: String, performReactivate: () -> Void) -> Bool {
        guard isDiscardedForMemory else { return false }
        cancel()
        guard clearDiscardState(reason: reason) else { return false }
        updateRestoredSessionRenderIntent(nil)
        performReactivate()
        return true
    }

    func updateRestoredSessionRenderIntent(_ shouldRenderWebView: Bool?) {
        restoredSessionShouldRenderWebView = shouldRenderWebView
    }

    @discardableResult
    func clearDiscardState(reason: String) -> Bool {
        guard isDiscardedForMemory else { return false }
        isDiscardedForMemory = false
        discardedAt = nil
        lastRestoreReason = reason
        return true
    }

    func resetMetadata() {
        cancel()
        isDiscardedForMemory = false
        discardedAt = nil
        lastDiscardReason = nil
        lastRestoreReason = nil
        updateRestoredSessionRenderIntent(nil)
    }

    private func handlePolicyDefaultsChanged() {
        let nextPolicyState = BrowserHiddenWebViewDiscardPolicy.resolved()
        guard policyState != nextPolicyState else { return }
        policyState = nextPolicyState
        delegate?.hiddenWebViewDiscardManagerPolicyDidChange(self, reason: "policy_changed")
    }

    private func stopOnMainActor() {
        cancel()
        if let policyObserver {
            NotificationCenter.default.removeObserver(policyObserver)
            self.policyObserver = nil
        }
    }

#if DEBUG
    static func debugResetRetentionCoordinatorForTesting() {
        retentionCoordinator.reset()
    }
#endif
}

@MainActor
private final class BrowserHiddenWebViewRetentionCoordinator {
    private struct Entry {
        weak var manager: BrowserHiddenWebViewDiscardManager?
        let hiddenAt: Date
        let sequence: UInt64
        let webViewInstanceID: UUID
        var lastReason: String
    }

    private var entriesByManagerId: [ObjectIdentifier: Entry] = [:]
    private var nextSequence: UInt64 = 0

    func contains(_ manager: BrowserHiddenWebViewDiscardManager) -> Bool {
        pruneInvalidEntries()
        return entriesByManagerId[ObjectIdentifier(manager)] != nil
    }

    func retainIfEligible(_ manager: BrowserHiddenWebViewDiscardManager, reason: String) {
        pruneInvalidEntries()

        guard BrowserHiddenWebViewDiscardPolicy.isEnabled,
              let delegate = manager.delegate,
              manager.blockers(for: delegate.hiddenWebViewDiscardSnapshot).isEmpty else {
            remove(manager)
            return
        }

        let managerId = ObjectIdentifier(manager)
        let hiddenAt = delegate.hiddenWebViewDiscardHiddenAt ?? Date()
        let webViewInstanceID = delegate.hiddenWebViewDiscardWebViewInstanceID

        if var entry = entriesByManagerId[managerId],
           entry.webViewInstanceID == webViewInstanceID {
            entry.lastReason = reason
            entriesByManagerId[managerId] = entry
        } else {
            nextSequence &+= 1
            entriesByManagerId[managerId] = Entry(
                manager: manager,
                hiddenAt: hiddenAt,
                sequence: nextSequence,
                webViewInstanceID: webViewInstanceID,
                lastReason: reason
            )
        }

        enforceLimit(reason: reason)
    }

    func remove(_ manager: BrowserHiddenWebViewDiscardManager) {
        entriesByManagerId.removeValue(forKey: ObjectIdentifier(manager))
    }

    func enforceLimit(reason: String) {
        pruneInvalidEntries()

        let retentionLimit = BrowserHiddenWebViewDiscardPolicy.hiddenWebViewRetentionLimit
        guard BrowserHiddenWebViewDiscardPolicy.isEnabled, retentionLimit >= 0 else {
            entriesByManagerId.removeAll()
            return
        }

        let retainedEntries = sortedEntries()
        let overflowCount = retainedEntries.count - retentionLimit
        guard overflowCount > 0 else { return }

        let now = Date()
        let evictionCandidates = retainedEntries
            .filter { isPastGracePeriod($0, now: now) }
            .prefix(overflowCount)

        for entry in evictionCandidates {
            guard let manager = entry.manager,
                  let delegate = manager.delegate else {
                entriesByManagerId.removeValue(forKey: entry.id)
                continue
            }

            guard delegate.hiddenWebViewDiscardWebViewInstanceID == entry.webViewInstanceID,
                  manager.blockers(for: delegate.hiddenWebViewDiscardSnapshot).isEmpty,
                  isPastGracePeriod(entry, now: now) else {
                entriesByManagerId.removeValue(forKey: entry.id)
                continue
            }

            entriesByManagerId.removeValue(forKey: entry.id)
            delegate.hiddenWebViewDiscardManagerDidRequestDiscard(
                manager,
                reason: "lru_retention_limit.\(reason)"
            )
        }

        pruneInvalidEntries()
    }

#if DEBUG
    func reset() {
        entriesByManagerId.removeAll()
        nextSequence = 0
    }
#endif

    private func pruneInvalidEntries() {
        guard BrowserHiddenWebViewDiscardPolicy.isEnabled else {
            entriesByManagerId.removeAll()
            return
        }

        entriesByManagerId = entriesByManagerId.filter { _, entry in
            guard let manager = entry.manager,
                  let delegate = manager.delegate,
                  delegate.hiddenWebViewDiscardWebViewInstanceID == entry.webViewInstanceID else {
                return false
            }
            return manager.blockers(for: delegate.hiddenWebViewDiscardSnapshot).isEmpty
        }
    }

    private func sortedEntries() -> [EntryWithID] {
        entriesByManagerId
            .map { EntryWithID(id: $0.key, entry: $0.value) }
            .sorted { lhs, rhs in
                if lhs.entry.hiddenAt != rhs.entry.hiddenAt {
                    return lhs.entry.hiddenAt < rhs.entry.hiddenAt
                }
                return lhs.entry.sequence < rhs.entry.sequence
            }
    }

    private func isPastGracePeriod(_ entry: EntryWithID, now: Date) -> Bool {
        now.timeIntervalSince(entry.entry.hiddenAt) >= BrowserHiddenWebViewDiscardPolicy.hiddenDelay
    }

    private struct EntryWithID {
        let id: ObjectIdentifier
        let entry: Entry

        var manager: BrowserHiddenWebViewDiscardManager? {
            entry.manager
        }

        var webViewInstanceID: UUID {
            entry.webViewInstanceID
        }
    }
}
