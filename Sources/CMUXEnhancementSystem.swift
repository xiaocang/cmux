import AppKit
import Foundation
import CMUXEnhancementAPI

enum CMUXGitHubEnhancementActionID {
    static let pullRequestRefresh = "github.pull_request.refresh"
}

enum CMUXTmuxLeaderEnhancementActionID {
    static let secondKey = "tmux.leader.second_key"
    static let arm = "tmux.leader.arm"
}

final class CMUXTmuxLeaderSecondKeyRequest {
    let event: NSEvent
    var outcome: CMUXLeaderSecondKeyOutcome = .notHandled

    init(event: NSEvent) {
        self.event = event
    }
}

final class CMUXTmuxLeaderArmRequest {
    let event: NSEvent
    weak var owner: CMUXLeaderModeOwner?
    var didArm = false

    init(event: NSEvent, owner: CMUXLeaderModeOwner) {
        self.event = event
        self.owner = owner
    }
}

struct CMUXGitHubPullRequestRefreshKey: Hashable, Sendable {
    let workspaceId: UUID
    let panelId: UUID
}

struct CMUXGitHubPullRequestRefreshTarget: Hashable, Sendable {
    let branch: String
    let repoSlugs: [String]
}

struct CMUXGitHubPullRequestRefreshRequest: Sendable {
    let key: CMUXGitHubPullRequestRefreshKey
    let reason: String
    let target: CMUXGitHubPullRequestRefreshTarget?
    let bypassRepoCache: Bool
    let triggerImmediateRefresh: Bool

    init(
        key: CMUXGitHubPullRequestRefreshKey,
        reason: String,
        target: CMUXGitHubPullRequestRefreshTarget?,
        bypassRepoCache: Bool,
        triggerImmediateRefresh: Bool = true
    ) {
        self.key = key
        self.reason = reason
        self.target = target
        self.bypassRepoCache = bypassRepoCache
        self.triggerImmediateRefresh = triggerImmediateRefresh
    }
}

protocol CMUXEnhancementAppProviding: AnyObject {
    var actions: CMUXAppEnhancementActionRegistry { get }
    var github: CMUXGitHubEnhancementService { get }
    var tmuxPrefix: CMUXTmuxPrefixService { get }
    func start()
    func shutdown()
}

final class CMUXEnhancementSystem {
    static let shared = CMUXEnhancementSystem()

    let logger: CMUXAppEnhancementLogger
    let actions: CMUXAppEnhancementActionRegistry
    let scheduler: CMUXDispatchEnhancementScheduler
    let github: CMUXGitHubEnhancementService
    let tmuxPrefix: CMUXTmuxPrefixService

    private let host: CMUXEnhancementHost
    private let lock = NSLock()
    private var started = false
    private var enhancements: [CMUXEnhancement] = []

    private init() {
        let logger = CMUXAppEnhancementLogger()
        let scheduler = CMUXDispatchEnhancementScheduler()
        let actions = CMUXAppEnhancementActionRegistry(logger: logger)
        let github = CMUXGitHubEnhancementService()
        let tmuxPrefix = CMUXTmuxPrefixService()
        let context = CMUXAppEnhancementContext(
            logger: logger,
            actions: actions,
            scheduler: scheduler
        )

        self.logger = logger
        self.actions = actions
        self.scheduler = scheduler
        self.github = github
        self.tmuxPrefix = tmuxPrefix
        self.host = CMUXEnhancementHost(context: context, logger: logger)
    }

    var activatedEnhancementIds: [String] {
        host.activatedEnhancementIds
    }

    func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        let enhancements = CMUXBuiltinEnhancements.make(
            githubService: github,
            tmuxPrefixService: tmuxPrefix
        )
        lock.lock()
        self.enhancements = enhancements
        lock.unlock()

        do {
            try host.activate(enhancements)
        } catch {
            lock.lock()
            started = false
            self.enhancements = []
            lock.unlock()
            logger.error("Enhancement activation failed: \(error.localizedDescription)")
        }
    }

    func activate(trigger: CMUXEnhancementHost.ActivationTrigger) {
        lock.lock()
        let shouldActivate = started
        let enhancements = self.enhancements
        lock.unlock()

        guard shouldActivate else { return }
        do {
            try host.activate(
                enhancements,
                trigger: trigger
            )
        } catch {
            logger.error("Enhancement activation trigger \(trigger.rawValue) failed: \(error.localizedDescription)")
        }
    }

    func shutdown() {
        lock.lock()
        let wasStarted = started
        started = false
        enhancements = []
        lock.unlock()

        guard wasStarted else {
            github.resetQueuedRefreshes()
            return
        }
        host.deactivate()
        github.resetQueuedRefreshes()
    }
}

extension CMUXEnhancementSystem: CMUXEnhancementAppProviding {}

final class CMUXEnhancementHost {
    enum ActivationTrigger: String {
        case onAppStart
        case onWorkspaceOpen
        case onAgentEvent
    }

    enum HostError: Error, LocalizedError, Equatable {
        case unsupportedPermissions(enhancementId: String, permissions: [String])

        var errorDescription: String? {
            switch self {
            case let .unsupportedPermissions(enhancementId, permissions):
                return "Enhancement \(enhancementId) declares unsupported permissions: \(permissions.joined(separator: ","))"
            }
        }
    }

    private static let supportedPermissions: Set<String> = [
        "actions:intercept",
        "github:refresh",
        "keyboard:intercept",
        "workspace:read",
    ]

    private let context: CMUXEnhancementContext
    private let logger: CMUXEnhancementLogger
    private var activatedEnhancements: [CMUXEnhancement] = []

    init(context: CMUXEnhancementContext, logger: CMUXEnhancementLogger) {
        self.context = context
        self.logger = logger
    }

    var activatedEnhancementIds: [String] {
        activatedEnhancements.map(\.manifest.id)
    }

    func activate(
        _ enhancements: [CMUXEnhancement],
        trigger: ActivationTrigger = .onAppStart
    ) throws {
        var activatedIds = Set(activatedEnhancements.map(\.manifest.id))
        for enhancement in enhancements {
            let manifest = enhancement.manifest
            guard shouldActivate(manifest, for: trigger) else {
                logger.debug("Skipping enhancement \(manifest.id) for activation trigger \(trigger.rawValue)")
                continue
            }
            guard !activatedIds.contains(manifest.id) else {
                logger.debug("Skipping already-active enhancement \(manifest.id)")
                continue
            }
            let unsupportedPermissions = manifest.permissions.filter { !Self.supportedPermissions.contains($0) }
            guard unsupportedPermissions.isEmpty else {
                let error = HostError.unsupportedPermissions(
                    enhancementId: manifest.id,
                    permissions: unsupportedPermissions.sorted()
                )
                logger.error(error.localizedDescription)
                deactivate()
                throw error
            }
            logger.info("Activating enhancement \(manifest.id)")
            if !manifest.permissions.isEmpty {
                logger.debug("Enhancement \(manifest.id) declares permissions: \(manifest.permissions.joined(separator: ","))")
            }
            do {
                try enhancement.activate(context: context)
                activatedEnhancements.append(enhancement)
                activatedIds.insert(manifest.id)
            } catch {
                logger.error("Enhancement \(manifest.id) activation failed: \(error.localizedDescription)")
                deactivate()
                throw error
            }
        }
    }

    func deactivate() {
        let enhancements = activatedEnhancements.reversed()
        activatedEnhancements.removeAll()
        for enhancement in enhancements {
            logger.info("Deactivating enhancement \(enhancement.manifest.id)")
            enhancement.deactivate()
        }
    }

    private func shouldActivate(_ manifest: CMUXEnhancementManifest, for trigger: ActivationTrigger) -> Bool {
        if manifest.activation.isEmpty {
            return trigger == .onAppStart
        }
        return manifest.activation.contains(trigger.rawValue)
    }
}

enum CMUXBuiltinEnhancements {
    static func make(
        githubService: CMUXGitHubEnhancementService,
        tmuxPrefixService: CMUXTmuxPrefixService
    ) -> [CMUXEnhancement] {
        [
            CMUXNoopEnhancement(),
            CMUXGitHubEnhancement(service: githubService),
            CMUXTmuxLeaderEnhancement(service: tmuxPrefixService),
        ]
    }
}

final class CMUXNoopEnhancement: CMUXEnhancement {
    let manifest = CMUXEnhancementManifest(
        id: "@cmux/enhancement-noop",
        name: "cmux No-op Enhancement",
        version: "0.1.0",
        activation: ["onAppStart"],
        permissions: []
    )

    private(set) var isActive = false

    func activate(context: CMUXEnhancementContext) {
        isActive = true
        context.logger.debug("No-op enhancement activated")
    }

    func deactivate() {
        isActive = false
    }
}

private final class CMUXGitHubEnhancement: CMUXEnhancement {
    let manifest = CMUXEnhancementManifest(
        id: "@cmux/enhancement-github",
        name: "cmux GitHub",
        version: "0.1.0",
        activation: ["onAppStart"],
        permissions: [
            "actions:intercept",
            "workspace:read",
            "github:refresh",
        ]
    )

    private let service: CMUXGitHubEnhancementService
    private var disposables: [CMUXEnhancementDisposable] = []

    init(service: CMUXGitHubEnhancementService) {
        self.service = service
    }

    func activate(context: CMUXEnhancementContext) {
        disposables.append(
            context.actions.registerInterceptor(
                CMUXGitHubPullRequestRefreshInterceptor(service: service)
            )
        )
    }

    func deactivate() {
        disposables.forEach { $0.dispose() }
        disposables.removeAll()
    }
}

private final class CMUXTmuxLeaderEnhancement: CMUXEnhancement {
    let manifest = CMUXEnhancementManifest(
        id: "@cmux/enhancement-tmux-leader",
        name: "cmux tmux Leader",
        version: "0.1.0",
        activation: ["onAppStart"],
        permissions: [
            "actions:intercept",
            "keyboard:intercept",
        ]
    )

    private let service: CMUXTmuxPrefixService
    private var disposables: [CMUXEnhancementDisposable] = []
    private var leaderActionRegistrations: [CMUXLeaderActionContributionRegistration] = []

    init(service: CMUXTmuxPrefixService) {
        self.service = service
    }

    func activate(context: CMUXEnhancementContext) {
        let restoreScheduler = MainActor.assumeIsolated {
            service.replaceTimeoutScheduler { timeout, workItem in
                _ = context.scheduler.asyncAfter(delay: timeout) {
                    guard !workItem.isCancelled else { return }
                    workItem.perform()
                }
            }
        }
        disposables.append(
            CMUXEnhancementBlockDisposable {
                MainActor.assumeIsolated {
                    restoreScheduler()
                }
            }
        )
        leaderActionRegistrations.append(
            service.registerBuiltInLeaderActionContributions()
        )
        disposables.append(
            context.actions.registerInterceptor(
                CMUXTmuxLeaderSecondKeyInterceptor(service: service)
            )
        )
        disposables.append(
            context.actions.registerInterceptor(
                CMUXTmuxLeaderArmInterceptor(service: service)
            )
        )
    }

    func deactivate() {
        disposables.forEach { $0.dispose() }
        disposables.removeAll()
        leaderActionRegistrations.forEach { $0.dispose() }
        leaderActionRegistrations.removeAll()
    }
}

private final class CMUXTmuxLeaderSecondKeyInterceptor: CMUXEnhancementActionInterceptor {
    let id = "@cmux/enhancement-tmux-leader.second-key"
    let actionIds: Set<String> = [CMUXTmuxLeaderEnhancementActionID.secondKey]
    let priority = 100

    private let service: CMUXTmuxPrefixService

    init(service: CMUXTmuxPrefixService) {
        self.service = service
    }

    func intercept(
        action: CMUXEnhancementAction,
        proceed: @escaping (CMUXEnhancementAction) -> Void
    ) throws -> CMUXEnhancementActionDisposition {
        guard let request = action.payload as? CMUXTmuxLeaderSecondKeyRequest else {
            return .continue
        }
        let outcome = MainActor.assumeIsolated {
            service.handleSecondKey(event: request.event)
        }
        request.outcome = outcome
        if case .notHandled = outcome {
            proceed(action)
        }
        return .handled
    }
}

private final class CMUXTmuxLeaderArmInterceptor: CMUXEnhancementActionInterceptor {
    let id = "@cmux/enhancement-tmux-leader.arm"
    let actionIds: Set<String> = [CMUXTmuxLeaderEnhancementActionID.arm]
    let priority = 100

    private let service: CMUXTmuxPrefixService

    init(service: CMUXTmuxPrefixService) {
        self.service = service
    }

    func intercept(
        action: CMUXEnhancementAction,
        proceed: @escaping (CMUXEnhancementAction) -> Void
    ) throws -> CMUXEnhancementActionDisposition {
        guard let request = action.payload as? CMUXTmuxLeaderArmRequest,
              let owner = request.owner else {
            return .continue
        }
        let didArm = MainActor.assumeIsolated {
            service.handleLeaderArm(event: request.event, owner: owner)
        }
        request.didArm = didArm
        if !didArm {
            proceed(action)
        }
        return .handled
    }
}

private final class CMUXGitHubPullRequestRefreshInterceptor: CMUXEnhancementActionInterceptor {
    let id = "@cmux/enhancement-github.pr-refresh"
    let actionIds: Set<String> = [CMUXGitHubEnhancementActionID.pullRequestRefresh]
    let priority = 100

    private let service: CMUXGitHubEnhancementService

    init(service: CMUXGitHubEnhancementService) {
        self.service = service
    }

    func intercept(
        action: CMUXEnhancementAction,
        proceed _: @escaping (CMUXEnhancementAction) -> Void
    ) throws -> CMUXEnhancementActionDisposition {
        guard let request = action.payload as? CMUXGitHubPullRequestRefreshRequest else {
            return .continue
        }

        return service.queueRefreshIfNeeded(request: request) ? .handled : .continue
    }
}

final class CMUXGitHubEnhancementService {
    private struct QueuedRefreshEntry: Sendable {
        var probeKeys: Set<CMUXGitHubPullRequestRefreshKey>
        var fireAt: Date
        var bypassRepoCache: Bool
    }

    private let lock = NSLock()
    private var queuedRefreshesByTarget: [CMUXGitHubPullRequestRefreshTarget: QueuedRefreshEntry] = [:]

    @discardableResult
    func queueRefreshIfNeeded(
        request: CMUXGitHubPullRequestRefreshRequest,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard SidebarPullRequestShellDebounceSettings.isEnabled(defaults: defaults),
              Self.isShellTriggered(reason: request.reason),
              let target = request.target else {
            return false
        }

        lock.lock()
        removeQueuedRefreshLocked(key: request.key)
        let fireAt = now.addingTimeInterval(
            TimeInterval(SidebarPullRequestShellDebounceSettings.delaySeconds(defaults: defaults))
        )
        if var existingEntry = queuedRefreshesByTarget[target] {
            existingEntry.probeKeys.insert(request.key)
            existingEntry.bypassRepoCache = existingEntry.bypassRepoCache || request.bypassRepoCache
            queuedRefreshesByTarget[target] = existingEntry
        } else {
            queuedRefreshesByTarget[target] = QueuedRefreshEntry(
                probeKeys: [request.key],
                fireAt: fireAt,
                bypassRepoCache: request.bypassRepoCache
            )
        }
        let snapshot = queuedRefreshesByTarget[target]
        lock.unlock()

#if DEBUG
        if let snapshot {
            let fireDelay = snapshot.fireAt.timeIntervalSince(now)
            cmuxDebugLog(
                "githubEnhancement.prRefresh.queue workspace=\(request.key.workspaceId.uuidString.prefix(5)) " +
                "panel=\(request.key.panelId.uuidString.prefix(5)) reason=\(request.reason) " +
                "branch=\(target.branch) repos=\(target.repoSlugs.count) " +
                "keys=\(snapshot.probeKeys.count) delay=\(String(format: "%.2f", fireDelay))"
            )
        }
#endif
        return true
    }

    func nextQueuedRefreshAt() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return queuedRefreshesByTarget.values.map(\.fireAt).min()
    }

    func queuedRefreshesAreEmpty() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return queuedRefreshesByTarget.isEmpty
    }

    func removeQueuedRefresh(key: CMUXGitHubPullRequestRefreshKey) {
        lock.lock()
        removeQueuedRefreshLocked(key: key)
        lock.unlock()
    }

    func removeQueuedRefreshes(workspaceId: UUID) {
        lock.lock()
        queuedRefreshesByTarget = queuedRefreshesByTarget.compactMapValues { entry in
            var nextEntry = entry
            nextEntry.probeKeys = Set(nextEntry.probeKeys.filter { $0.workspaceId != workspaceId })
            return nextEntry.probeKeys.isEmpty ? nil : nextEntry
        }
        lock.unlock()
    }

    func resetQueuedRefreshes() {
        lock.lock()
        queuedRefreshesByTarget.removeAll()
        lock.unlock()
    }

    func pruneQueuedRefreshes(
        validKeys: Set<CMUXGitHubPullRequestRefreshKey>,
        ownedWorkspaceIds: Set<UUID>,
        currentTarget: (CMUXGitHubPullRequestRefreshKey) -> CMUXGitHubPullRequestRefreshTarget?
    ) {
        lock.lock()
        pruneQueuedRefreshesLocked(
            validKeys: validKeys,
            ownedWorkspaceIds: ownedWorkspaceIds,
            currentTarget: currentTarget
        )
        lock.unlock()
    }

    func flushDueQueuedRefreshes(
        now: Date = Date(),
        validKeys: Set<CMUXGitHubPullRequestRefreshKey>,
        ownedWorkspaceIds: Set<UUID>,
        currentTarget: (CMUXGitHubPullRequestRefreshKey) -> CMUXGitHubPullRequestRefreshTarget?
    ) -> [CMUXGitHubPullRequestRefreshRequest] {
        lock.lock()
        pruneQueuedRefreshesLocked(
            validKeys: validKeys,
            ownedWorkspaceIds: ownedWorkspaceIds,
            currentTarget: currentTarget
        )
        let dueTargets = queuedRefreshesByTarget
            .filter { $0.value.fireAt <= now }
            .map(\.key)
        guard !dueTargets.isEmpty else {
            lock.unlock()
            return []
        }

        var requests: [CMUXGitHubPullRequestRefreshRequest] = []
#if DEBUG
        var flushSummaries: [(branch: String, repoCount: Int, scheduledTotal: Int)] = []
#endif
        for target in dueTargets {
            guard let entry = queuedRefreshesByTarget.removeValue(forKey: target) else {
                continue
            }
            var remainingEntry = entry
            remainingEntry.probeKeys.removeAll()
            for key in entry.probeKeys {
                guard ownedWorkspaceIds.contains(key.workspaceId) else {
                    remainingEntry.probeKeys.insert(key)
                    continue
                }
                guard currentTarget(key) == target else {
                    continue
                }
                requests.append(
                    CMUXGitHubPullRequestRefreshRequest(
                        key: key,
                        reason: TabManager.workspacePullRequestQueuedShellTriggerReason,
                        target: target,
                        bypassRepoCache: entry.bypassRepoCache,
                        triggerImmediateRefresh: false
                    )
                )
            }
            if !remainingEntry.probeKeys.isEmpty {
                queuedRefreshesByTarget[target] = remainingEntry
            }

#if DEBUG
            flushSummaries.append((target.branch, target.repoSlugs.count, requests.count))
#endif
        }
        lock.unlock()
#if DEBUG
        for summary in flushSummaries {
            cmuxDebugLog(
                "githubEnhancement.prRefresh.queue.flush branch=\(summary.branch) " +
                "repos=\(summary.repoCount) scheduled=\(summary.scheduledTotal)"
            )
        }
#endif
        return requests
    }

    func queuedRefreshTargets() -> [CMUXGitHubPullRequestRefreshTarget] {
        lock.lock()
        defer { lock.unlock() }
        return queuedRefreshesByTarget.keys.sorted {
            let lhs = "\($0.branch)|\($0.repoSlugs.joined(separator: ","))"
            let rhs = "\($1.branch)|\($1.repoSlugs.joined(separator: ","))"
            return lhs < rhs
        }
    }

    func queuedRefreshSnapshot() -> [(target: CMUXGitHubPullRequestRefreshTarget, fireAt: Date, probeKeyCount: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return queuedRefreshesByTarget
            .map { target, entry in
                (
                    target: target,
                    fireAt: entry.fireAt,
                    probeKeyCount: entry.probeKeys.count
                )
            }
            .sorted {
                let lhs = "\($0.target.branch)|\($0.target.repoSlugs.joined(separator: ","))"
                let rhs = "\($1.target.branch)|\($1.target.repoSlugs.joined(separator: ","))"
                return lhs < rhs
            }
    }

    private static func isShellTriggered(reason: String) -> Bool {
        reason == "shellPrompt" || reason.hasPrefix("commandHint:")
    }

    private func removeQueuedRefreshLocked(key: CMUXGitHubPullRequestRefreshKey) {
        guard !queuedRefreshesByTarget.isEmpty else { return }
        for target in Array(queuedRefreshesByTarget.keys) {
            guard var entry = queuedRefreshesByTarget[target] else { continue }
            entry.probeKeys.remove(key)
            if entry.probeKeys.isEmpty {
                queuedRefreshesByTarget.removeValue(forKey: target)
            } else {
                queuedRefreshesByTarget[target] = entry
            }
        }
    }

    private func pruneQueuedRefreshesLocked(
        validKeys: Set<CMUXGitHubPullRequestRefreshKey>,
        ownedWorkspaceIds: Set<UUID>,
        currentTarget: (CMUXGitHubPullRequestRefreshKey) -> CMUXGitHubPullRequestRefreshTarget?
    ) {
        var prunedEntries: [CMUXGitHubPullRequestRefreshTarget: QueuedRefreshEntry] = [:]

        for (target, entry) in queuedRefreshesByTarget {
            let matchingProbeKeys = entry.probeKeys.filter { key in
                guard ownedWorkspaceIds.contains(key.workspaceId) else { return true }
                guard validKeys.contains(key) else { return false }
                return currentTarget(key) == target
            }
            guard !matchingProbeKeys.isEmpty else { continue }

            var nextEntry = entry
            nextEntry.probeKeys = Set(matchingProbeKeys)
            prunedEntries[target] = nextEntry
        }

        queuedRefreshesByTarget = prunedEntries
    }
}

final class CMUXAppEnhancementContext: CMUXEnhancementContext {
    let logger: CMUXEnhancementLogger
    let actions: CMUXEnhancementActionRegistry
    let scheduler: CMUXEnhancementScheduler

    init(
        logger: CMUXEnhancementLogger,
        actions: CMUXEnhancementActionRegistry,
        scheduler: CMUXEnhancementScheduler
    ) {
        self.logger = logger
        self.actions = actions
        self.scheduler = scheduler
    }
}

final class CMUXAppEnhancementLogger: CMUXEnhancementLogger {
    func debug(_ message: String) {
#if DEBUG
        cmuxDebugLog("enhancement.debug \(message)")
#endif
    }

    func info(_ message: String) {
#if DEBUG
        cmuxDebugLog("enhancement.info \(message)")
#else
        NSLog("cmux enhancement: %@", message)
#endif
    }

    func warning(_ message: String) {
        NSLog("cmux enhancement warning: %@", message)
    }

    func error(_ message: String) {
        NSLog("cmux enhancement error: %@", message)
    }
}

final class CMUXAppEnhancementActionRegistry: CMUXEnhancementActionRegistry {
    private let logger: CMUXEnhancementLogger
    private let lock = NSLock()
    private var interceptors: [String: CMUXEnhancementActionInterceptor] = [:]
    // Pre-sorted snapshot of interceptors. Rebuilt only on register/dispose so
    // dispatch (called per keystroke for leader-action interception) avoids
    // re-sorting on every event.
    private var sortedSnapshot: [CMUXEnhancementActionInterceptor] = []

    init(logger: CMUXEnhancementLogger) {
        self.logger = logger
    }

    @discardableResult
    func registerInterceptor(_ interceptor: CMUXEnhancementActionInterceptor) -> CMUXEnhancementDisposable {
        lock.lock()
        interceptors[interceptor.id] = interceptor
        sortedSnapshot = Self.sort(interceptors.values)
        lock.unlock()
        return CMUXEnhancementBlockDisposable { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.interceptors.removeValue(forKey: interceptor.id)
            self.sortedSnapshot = Self.sort(self.interceptors.values)
            self.lock.unlock()
        }
    }

    private static func sort(
        _ values: Dictionary<String, CMUXEnhancementActionInterceptor>.Values
    ) -> [CMUXEnhancementActionInterceptor] {
        values.sorted {
            if $0.priority != $1.priority {
                return $0.priority > $1.priority
            }
            return $0.id < $1.id
        }
    }

    @discardableResult
    func dispatch(
        _ action: CMUXEnhancementAction,
        fallback: @escaping (CMUXEnhancementAction) -> Void
    ) -> Bool {
        lock.lock()
        let snapshot = sortedSnapshot
        lock.unlock()
        let active = snapshot.filter { $0.actionIds.isEmpty || $0.actionIds.contains(action.id) }

        func invoke(_ index: Int, _ nextAction: CMUXEnhancementAction) -> Bool {
            guard index < active.count else {
                fallback(nextAction)
                return false
            }

            let interceptor = active[index]
            do {
                let disposition = try interceptor.intercept(action: nextAction) { proceededAction in
                    _ = invoke(index + 1, proceededAction)
                }
                switch disposition {
                case .handled:
                    return true
                case .continue:
                    return invoke(index + 1, nextAction)
                }
            } catch {
                logger.error(
                    "Enhancement interceptor \(interceptor.id) failed for \(nextAction.id): \(error.localizedDescription)"
                )
                fallback(nextAction)
                return false
            }
        }

        return invoke(0, action)
    }
}

final class CMUXDispatchEnhancementScheduler: CMUXEnhancementScheduler {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    func async(execute work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    func asyncAfter(delay: TimeInterval, execute work: @escaping () -> Void) -> CMUXEnhancementDisposable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return CMUXEnhancementBlockDisposable {
            item.cancel()
        }
    }
}
