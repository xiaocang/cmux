import Foundation

@MainActor
final class SortAssistantWorkspaceMonitorCenter {
    struct Snapshot: Equatable {
        let id: UUID
        let shortId: String
        let workspaceId: UUID
        let workspaceTitle: String
        let condition: String
        let interval: TimeInterval
        let createdAt: Date
    }

    private struct Monitor {
        let id: UUID
        let workspaceId: UUID
        var workspaceTitle: String
        let condition: String
        var interval: TimeInterval
        var nextFireAt: Date
        var createdAt: Date

        var shortId: String {
            String(id.uuidString.prefix(8)).lowercased()
        }
    }

    static let shared = SortAssistantWorkspaceMonitorCenter()
    private static let statusKeyPrefix = "sprite.monitor."
    private static let statusColor = "#00BCD4"
    private static let globalMonitorLimit = 128
    private static let workspaceMonitorLimit = 16
    private var monitors: [UUID: Monitor] = [:]
    private var schedulerTask: Task<Void, Never>?
    private var schedulerGeneration = 0

    func add(
        workspaceId: UUID,
        workspaceTitle: String,
        condition: String,
        interval: TimeInterval
    ) -> Snapshot {
        let createdAt = Date()
        let nextFireAt = createdAt.addingTimeInterval(interval)
        if let existingId = existingMonitorId(workspaceId: workspaceId, condition: condition),
           var existing = monitors[existingId] {
            existing.workspaceTitle = workspaceTitle
            existing.interval = interval
            existing.nextFireAt = nextFireAt
            existing.createdAt = createdAt
            monitors[existingId] = existing
            updateStatus(for: existing, reached: false)
            wakeScheduler()
            return snapshot(for: existing)
        }

        let id = UUID()
        let monitor = Monitor(
            id: id,
            workspaceId: workspaceId,
            workspaceTitle: workspaceTitle,
            condition: condition,
            interval: interval,
            nextFireAt: nextFireAt,
            createdAt: createdAt
        )
        monitors[id] = monitor
        enforceMonitorLimits(protectedId: id, workspaceId: workspaceId)
        updateStatus(for: monitor, reached: false)
        wakeScheduler()
        return snapshot(for: monitor)
    }

    func list(workspaceId: UUID?) -> [Snapshot] {
        monitors.values
            .filter { workspaceId == nil || $0.workspaceId == workspaceId }
            .sorted { $0.createdAt < $1.createdAt }
            .map(snapshot(for:))
    }

    @discardableResult
    func stop(workspaceId: UUID?, selector: String?) -> Int {
        let normalizedSelector = selector?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ids = monitors.values.compactMap { monitor -> UUID? in
            if let workspaceId, monitor.workspaceId != workspaceId { return nil }
            guard let normalizedSelector, !normalizedSelector.isEmpty, normalizedSelector != "all" else {
                return monitor.id
            }
            if monitor.id.uuidString.lowercased().hasPrefix(normalizedSelector) ||
                monitor.condition.lowercased().contains(normalizedSelector) {
                return monitor.id
            }
            return nil
        }
        for id in ids {
            removeMonitor(id, clearStatus: true)
        }
        wakeScheduler()
        return ids.count
    }

    func workspaceDidClose(_ workspaceId: UUID) {
        let ids = monitors.values.compactMap { monitor in
            monitor.workspaceId == workspaceId ? monitor.id : nil
        }
        for id in ids {
            removeMonitor(id, clearStatus: true)
        }
        wakeScheduler()
    }

    private func schedulerLoop(generation: Int) async {
        defer {
            if schedulerGeneration == generation {
                schedulerTask = nil
            }
        }
        while !Task.isCancelled, schedulerGeneration == generation {
            guard let nextFireAt = monitors.values.map(\.nextFireAt).min() else {
                return
            }
            let delay = max(0, nextFireAt.timeIntervalSinceNow)
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: Self.sleepNanoseconds(for: delay))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, schedulerGeneration == generation else { return }

            let now = Date()
            let dueIds = monitors.values
                .filter { $0.nextFireAt <= now }
                .map(\.id)
            guard !dueIds.isEmpty else { continue }
            for id in dueIds {
                guard !Task.isCancelled, schedulerGeneration == generation else { return }
                await evaluate(monitorId: id, now: now)
            }
        }
    }

    private func evaluate(monitorId: UUID, now: Date) async {
        guard let monitor = monitors[monitorId],
              let workspace = workspace(id: monitor.workspaceId) else {
            removeMonitor(monitorId, clearStatus: true)
            return
        }
        let snapshot = workspaceSnapshot(workspace: workspace)
        guard Self.conditionIsMet(monitor.condition, snapshot: snapshot) else {
            var next = monitor
            next.nextFireAt = now.addingTimeInterval(monitor.interval)
            monitors[monitorId] = next
            return
        }

        let title = String(localized: "sortAssistant.monitor.notification.title", defaultValue: "Monitor reached")
        let body = String(
            format: String(localized: "sortAssistant.monitor.notification.body", defaultValue: "%@ matched in %@."),
            monitor.condition,
            monitor.workspaceTitle
        )
        TerminalNotificationStore.shared.addNotification(
            tabId: monitor.workspaceId,
            surfaceId: nil,
            title: title,
            subtitle: monitor.workspaceTitle,
            body: body,
            source: .monitor,
            cooldownKey: "sprite.monitor.\(monitor.id.uuidString)",
            cooldownInterval: monitor.interval
        )
        updateStatus(for: monitor, reached: true)
        removeMonitor(monitorId, clearStatus: false)
    }

    private func removeMonitor(_ id: UUID, clearStatus: Bool) {
        guard let monitor = monitors.removeValue(forKey: id) else { return }
        if clearStatus {
            workspace(id: monitor.workspaceId)?.statusEntries.removeValue(forKey: Self.statusKeyPrefix + monitor.shortId)
        }
    }

    private func wakeScheduler() {
        schedulerGeneration += 1
        schedulerTask?.cancel()
        guard !monitors.isEmpty else {
            schedulerTask = nil
            return
        }
        let generation = schedulerGeneration
        schedulerTask = Task { [weak self] in
            await self?.schedulerLoop(generation: generation)
        }
    }

    private func existingMonitorId(workspaceId: UUID, condition: String) -> UUID? {
        let normalizedCondition = normalizedMonitorCondition(condition)
        return monitors.values.first { monitor in
            monitor.workspaceId == workspaceId &&
                normalizedMonitorCondition(monitor.condition) == normalizedCondition
        }?.id
    }

    private func enforceMonitorLimits(protectedId: UUID, workspaceId: UUID) {
        evictOldestMonitors(
            monitors.values.filter { $0.workspaceId == workspaceId },
            keeping: Self.workspaceMonitorLimit,
            protectedId: protectedId
        )
        evictOldestMonitors(
            Array(monitors.values),
            keeping: Self.globalMonitorLimit,
            protectedId: protectedId
        )
    }

    private func evictOldestMonitors(_ candidates: [Monitor], keeping limit: Int, protectedId: UUID) {
        guard candidates.count > limit else { return }
        let evictionIds = candidates
            .filter { $0.id != protectedId }
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(candidates.count - limit)
            .map(\.id)
        for id in evictionIds {
            removeMonitor(id, clearStatus: true)
        }
    }

    private func normalizedMonitorCondition(_ condition: String) -> String {
        condition.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func sleepNanoseconds(for interval: TimeInterval) -> UInt64 {
        let seconds = min(max(interval, 0), SortAssistantMonitorCommand.maximumInterval)
        return UInt64(seconds * 1_000_000_000)
    }

    private func updateStatus(for monitor: Monitor, reached: Bool) {
        guard let workspace = workspace(id: monitor.workspaceId) else { return }
        let prefix = reached
            ? String(localized: "sortAssistant.monitor.status.reached", defaultValue: "Reached")
            : String(localized: "sortAssistant.monitor.status.monitoring", defaultValue: "Monitoring")
        workspace.statusEntries[Self.statusKeyPrefix + monitor.shortId] = SidebarStatusEntry(
            key: Self.statusKeyPrefix + monitor.shortId,
            value: "\(prefix): \(monitor.condition)",
            icon: reached ? "bell.badge.fill" : "bell.badge",
            color: Self.statusColor,
            priority: 90,
            timestamp: Date()
        )
    }

    private func workspaceSnapshot(workspace: Workspace) -> String {
        var lines: [String] = [
            "title: \(workspace.displayTitle)",
        ]
        if let directory = workspace.currentDirectory ?? workspace.surfaceTabBarDirectory {
            lines.append("directory: \(directory)")
        }
        for entry in workspace.sidebarStatusEntriesInDisplayOrder()
            where !entry.key.hasPrefix(Self.statusKeyPrefix) {
            lines.append("status.\(entry.key): \(entry.value)")
        }
        for block in workspace.sidebarMetadataBlocksInDisplayOrder()
            where !block.key.hasPrefix(Self.statusKeyPrefix) {
            lines.append("metadata.\(block.key): \(block.markdown)")
        }
        if let latest = TerminalNotificationStore.shared.latestNotification(forTabId: workspace.id) {
            lines.append("latest_notification: \(latest.title) \(latest.subtitle) \(latest.body)")
        }
        return lines.joined(separator: "\n")
    }

    private static func conditionIsMet(_ condition: String, snapshot: String) -> Bool {
        let condition = condition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !condition.isEmpty else { return false }
        let lowerCondition = condition.lowercased()
        let lowerSnapshot = snapshot.lowercased()
        if lowerSnapshot.contains(lowerCondition) {
            return true
        }
        for term in quotedTerms(in: condition) where lowerSnapshot.contains(term.lowercased()) {
            return true
        }
        if containsAny(lowerCondition, ["done", "complete", "completed", "finished", "success", "pass", "passed", "完成", "成功", "通过"]) {
            return containsAny(lowerSnapshot, ["done", "complete", "completed", "finished", "success", "pass", "passed", "完成", "成功", "通过"])
        }
        if containsAny(lowerCondition, ["fail", "failed", "error", "broken", "失败", "错误", "报错"]) {
            return containsAny(lowerSnapshot, ["fail", "failed", "error", "broken", "失败", "错误", "报错"])
        }
        return false
    }

    private static func quotedTerms(in text: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let activeQuote = quote {
                if character == activeQuote {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { terms.append(trimmed) }
                    current = ""
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            }
        }
        return terms
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func workspace(id: UUID) -> Workspace? {
        if let manager = AppDelegate.shared?.tabManagerFor(tabId: id),
           let workspace = manager.tabs.first(where: { $0.id == id }) {
            return workspace
        }
        if let workspace = AppDelegate.shared?.tabManager?.tabs.first(where: { $0.id == id }) {
            return workspace
        }
        return nil
    }

    private func snapshot(for monitor: Monitor) -> Snapshot {
        Snapshot(
            id: monitor.id,
            shortId: monitor.shortId,
            workspaceId: monitor.workspaceId,
            workspaceTitle: monitor.workspaceTitle,
            condition: monitor.condition,
            interval: monitor.interval,
            createdAt: monitor.createdAt
        )
    }
}

func sortAssistantWorkspaceDidClose(_ workspaceId: UUID) {
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            SortAssistantWorkspaceMonitorCenter.shared.workspaceDidClose(workspaceId)
        }
    } else {
        Task { @MainActor in
            SortAssistantWorkspaceMonitorCenter.shared.workspaceDidClose(workspaceId)
        }
    }
}
