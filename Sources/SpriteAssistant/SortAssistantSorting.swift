import CMUXWorkstream
import Foundation

final class SortAssistantLockStore {
    private let defaults: UserDefaults
    private let key = "sortAssistant.lockedWorkspaceIds"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lockedItemIds() -> Set<UUID> {
        let values = defaults.stringArray(forKey: key) ?? []
        return Set(values.compactMap(UUID.init(uuidString:)))
    }

    func setLocked(_ locked: Bool, itemId: UUID) {
        var ids = lockedItemIds()
        if locked {
            ids.insert(itemId)
        } else {
            ids.remove(itemId)
        }
        defaults.set(ids.map(\.uuidString).sorted(), forKey: key)
    }
}

@MainActor
final class SortEngine {
    static let workspaceListId = "workspace-sidebar"

    private let lockStore: SortAssistantLockStore

    init(lockStore: SortAssistantLockStore = SortAssistantLockStore()) {
        self.lockStore = lockStore
    }

    static func revision(for tabs: [Workspace]) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func feed(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        for tab in tabs {
            feed(tab.id.uuidString)
            feed(tab.isPinned ? ":pinned" : ":unpinned")
        }
        return Int(hash & 0x7fff_ffff)
    }

    func lockedItemIds() -> Set<UUID> {
        lockStore.lockedItemIds()
    }

    func setLocked(_ locked: Bool, itemId: UUID) {
        lockStore.setLocked(locked, itemId: itemId)
    }

    func preview(
        patch: SortPatch,
        tabs: [Workspace],
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals] = [:]
    ) throws -> SortEnginePreview {
        let plan = try resolvePlan(patch: patch, tabs: tabs, itemSignals: itemSignals)
        let titleById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.title) })
        return SortEnginePreview(
            patch: patch,
            orderBefore: tabs.map(\.id),
            orderAfter: plan.orderAfter,
            changes: Self.topChanges(
                before: tabs.map(\.id),
                after: plan.orderAfter,
                titleById: titleById
            ),
            affectedItemIds: affectedItemIds(before: tabs.map(\.id), after: plan.orderAfter, operations: patch.operations),
            rationale: patch.rationale,
            requiresConfirmation: patch.requiresConfirmation
        )
    }

    func apply(
        patch: SortPatch,
        tabManager: TabManager,
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals] = [:]
    ) throws -> SortEngineApplyResult {
        let plan = try resolvePlan(patch: patch, tabs: tabManager.tabs, itemSignals: itemSignals)
        let before = tabManager.tabs.map(\.id)
        let titleById = Dictionary(uniqueKeysWithValues: tabManager.tabs.map { ($0.id, $0.title) })

        for change in plan.pinChanges {
            guard let workspace = tabManager.tabs.first(where: { $0.id == change.itemId }) else {
                throw SortEngineError.unknownItem(change.itemId)
            }
            tabManager.setPinned(workspace, pinned: true)
        }
        for change in plan.lockChanges {
            lockStore.setLocked(change.locked, itemId: change.itemId)
        }

        guard tabManager.reorderWorkspaces(to: plan.orderAfter) else {
            throw SortEngineError.applyFailed
        }

        let revisionAfter = Self.revision(for: tabManager.tabs)
        let undoPatch = SortPatch(
            listId: patch.listId,
            baseRevision: revisionAfter,
            operations: [.batchReorder(itemIds: before, preserveLockedItems: false)],
            rationale: String(localized: "sortAssistant.undo.patchRationale", defaultValue: "Restore the previous workspace order."),
            confidence: 1,
            requiresConfirmation: false
        )
        let preview = SortEnginePreview(
            patch: patch,
            orderBefore: before,
            orderAfter: tabManager.tabs.map(\.id),
            changes: Self.topChanges(
                before: before,
                after: tabManager.tabs.map(\.id),
                titleById: titleById
            ),
            affectedItemIds: affectedItemIds(before: before, after: tabManager.tabs.map(\.id), operations: patch.operations),
            rationale: patch.rationale,
            requiresConfirmation: patch.requiresConfirmation
        )
        return SortEngineApplyResult(
            preview: preview,
            undoPatch: undoPatch,
            revisionAfter: revisionAfter
        )
    }

    private struct ResolvedPlan {
        let orderAfter: [UUID]
        let pinChanges: [(itemId: UUID, position: SortPinPosition)]
        let lockChanges: [(itemId: UUID, locked: Bool)]
    }

    private func resolvePlan(
        patch: SortPatch,
        tabs: [Workspace],
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals]
    ) throws -> ResolvedPlan {
        guard patch.listId == Self.workspaceListId else {
            throw SortEngineError.wrongList(patch.listId)
        }
        guard !patch.operations.isEmpty else {
            throw SortEngineError.emptyPatch
        }
        let actualRevision = Self.revision(for: tabs)
        guard patch.baseRevision == actualRevision else {
            throw SortEngineError.revisionConflict(expected: patch.baseRevision, actual: actualRevision)
        }

        let knownIds = Set(tabs.map(\.id))
        for operation in patch.operations {
            for itemId in operation.itemIds where !knownIds.contains(itemId) {
                throw SortEngineError.unknownItem(itemId)
            }
        }

        var order = tabs.map(\.id)
        var pinnedIds = Set(tabs.filter(\.isPinned).map(\.id))
        let initiallyLockedIds = lockStore.lockedItemIds()
        var lockedIds = initiallyLockedIds
        var pinChanges: [(itemId: UUID, position: SortPinPosition)] = []
        var lockChanges: [(itemId: UUID, locked: Bool)] = []

        for operation in patch.operations {
            switch operation {
            case .batchReorder(let itemIds, let preserveLockedItems):
                order = rankedOrder(
                    currentOrder: order,
                    prioritizedIds: itemIds,
                    pinnedIds: pinnedIds
                )
                if preserveLockedItems {
                    order = preserveLockedPositions(
                        before: tabs.map(\.id),
                        after: order,
                        lockedIds: initiallyLockedIds
                    )
                } else {
                    try validateLockedPositions(before: tabs.map(\.id), after: order, lockedIds: initiallyLockedIds)
                }
            case .moveBefore(let itemId, let beforeItemId):
                guard !lockedIds.contains(itemId) else { throw SortEngineError.lockedItemMoved(itemId) }
                order = move(itemId: itemId, before: beforeItemId, in: order)
                order = pinnedFirst(order, pinnedIds: pinnedIds)
            case .moveAfter(let itemId, let afterItemId):
                guard !lockedIds.contains(itemId) else { throw SortEngineError.lockedItemMoved(itemId) }
                order = move(itemId: itemId, after: afterItemId, in: order)
                order = pinnedFirst(order, pinnedIds: pinnedIds)
            case .pin(let itemId, let position):
                pinnedIds.insert(itemId)
                pinChanges.append((itemId, position))
                order.removeAll { $0 == itemId }
                switch position {
                case .top:
                    order.insert(itemId, at: 0)
                case .bottom:
                    let pinnedCount = order.filter { pinnedIds.contains($0) }.count
                    order.insert(itemId, at: min(pinnedCount, order.count))
                }
                order = pinnedFirst(order, pinnedIds: pinnedIds)
            case .lock(let itemId):
                lockedIds.insert(itemId)
                lockChanges.append((itemId, true))
            case .groupBy(let field):
                order = groupedOrder(
                    currentOrder: order,
                    pinnedIds: pinnedIds,
                    field: field,
                    tabs: tabs,
                    itemSignals: itemSignals
                )
            }
        }

        try validatePinnedSection(order: order, pinnedIds: pinnedIds)
        try validateLockedPositions(before: tabs.map(\.id), after: order, lockedIds: initiallyLockedIds)

        return ResolvedPlan(
            orderAfter: order,
            pinChanges: pinChanges,
            lockChanges: lockChanges
        )
    }

    private func rankedOrder(
        currentOrder: [UUID],
        prioritizedIds: [UUID],
        pinnedIds: Set<UUID>
    ) -> [UUID] {
        var rankById: [UUID: Int] = [:]
        for id in prioritizedIds where rankById[id] == nil {
            rankById[id] = rankById.count
        }
        let indexed = currentOrder.enumerated().map { (index: $0.offset, id: $0.element) }
        return indexed.sorted { lhs, rhs in
            if pinnedIds.contains(lhs.id) != pinnedIds.contains(rhs.id) {
                return pinnedIds.contains(lhs.id)
            }
            switch (rankById[lhs.id], rankById[rhs.id]) {
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
        }.map(\.id)
    }

    private func preserveLockedPositions(
        before: [UUID],
        after: [UUID],
        lockedIds: Set<UUID>
    ) -> [UUID] {
        guard !lockedIds.isEmpty else { return after }
        var output = after.filter { !lockedIds.contains($0) }
        for (index, id) in before.enumerated() where lockedIds.contains(id) {
            output.removeAll { $0 == id }
            output.insert(id, at: min(index, output.count))
        }
        return output
    }

    private func validateLockedPositions(
        before: [UUID],
        after: [UUID],
        lockedIds: Set<UUID>
    ) throws {
        guard !lockedIds.isEmpty else { return }
        let beforeIndex = Dictionary(uniqueKeysWithValues: before.enumerated().map { ($0.element, $0.offset) })
        let afterIndex = Dictionary(uniqueKeysWithValues: after.enumerated().map { ($0.element, $0.offset) })
        for itemId in lockedIds {
            guard beforeIndex[itemId] == afterIndex[itemId] else {
                throw SortEngineError.lockedItemMoved(itemId)
            }
        }
    }

    private func validatePinnedSection(order: [UUID], pinnedIds: Set<UUID>) throws {
        guard !pinnedIds.isEmpty else { return }
        var seenUnpinned = false
        for id in order {
            if pinnedIds.contains(id), seenUnpinned {
                throw SortEngineError.pinnedConstraint(id)
            }
            if !pinnedIds.contains(id) {
                seenUnpinned = true
            }
        }
    }

    private func pinnedFirst(_ order: [UUID], pinnedIds: Set<UUID>) -> [UUID] {
        order.filter { pinnedIds.contains($0) } + order.filter { !pinnedIds.contains($0) }
    }

    private func move(itemId: UUID, before targetId: UUID, in order: [UUID]) -> [UUID] {
        var output = order
        output.removeAll { $0 == itemId }
        let index = output.firstIndex(of: targetId) ?? output.endIndex
        output.insert(itemId, at: index)
        return output
    }

    private func move(itemId: UUID, after targetId: UUID, in order: [UUID]) -> [UUID] {
        var output = order
        output.removeAll { $0 == itemId }
        let index = output.firstIndex(of: targetId).map { output.index(after: $0) } ?? output.endIndex
        output.insert(itemId, at: index)
        return output
    }

    private func groupedOrder(
        currentOrder: [UUID],
        pinnedIds: Set<UUID>,
        field: SortGroupField,
        tabs: [Workspace],
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals]
    ) -> [UUID] {
        let titleById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.title) })
        let indexById = Dictionary(uniqueKeysWithValues: currentOrder.enumerated().map { ($0.element, $0.offset) })
        return currentOrder.sorted { lhs, rhs in
            if pinnedIds.contains(lhs) != pinnedIds.contains(rhs) {
                return pinnedIds.contains(lhs)
            }
            let lhsValue = groupValue(for: lhs, field: field, titleById: titleById, itemSignals: itemSignals)
            let rhsValue = groupValue(for: rhs, field: field, titleById: titleById, itemSignals: itemSignals)
            if lhsValue != rhsValue {
                return lhsValue.localizedStandardCompare(rhsValue) == .orderedAscending
            }
            return (indexById[lhs] ?? 0) < (indexById[rhs] ?? 0)
        }
    }

    private func groupValue(
        for itemId: UUID,
        field: SortGroupField,
        titleById: [UUID: String],
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals]
    ) -> String {
        let signal = itemSignals[itemId]
        switch field {
        case .project:
            return titleById[itemId]?.components(separatedBy: CharacterSet(charactersIn: ":-/")).first ?? ""
        case .priority:
            return signal?.priority ?? ""
        case .status:
            return signal?.status ?? ""
        case .assignee:
            return signal?.assignee ?? ""
        case .tag:
            return signal?.tags?.first ?? ""
        }
    }

    private func affectedItemIds(before: [UUID], after: [UUID], operations: [SortOperation]) -> [UUID] {
        let beforeIndex = Dictionary(uniqueKeysWithValues: before.enumerated().map { ($0.element, $0.offset) })
        var ids = operations.flatMap(\.itemIds)
        ids.append(contentsOf: after.filter { beforeIndex[$0] != after.firstIndex(of: $0) })
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    static func topChanges(
        before: [UUID],
        after: [UUID],
        titleById: [UUID: String]
    ) -> [String] {
        let beforeIndex = Dictionary(uniqueKeysWithValues: before.enumerated().map { ($0.element, $0.offset) })
        var changes: [String] = []
        for (index, id) in after.enumerated() {
            guard let previous = beforeIndex[id], previous != index else { continue }
            let title = titleById[id] ?? String(localized: "sortAssistant.workspace.fallback", defaultValue: "Workspace")
            changes.append("\(index + 1). \(title)")
            if changes.count >= 5 { break }
        }
        if changes.isEmpty {
            return [String(localized: "sortAssistant.result.noVisibleChanges", defaultValue: "Order was already up to date.")]
        }
        return changes
    }
}

struct SortAssistantSortEvent: Codable, Equatable {
    enum EventType: String, Codable {
        case userDragMove = "user_drag_move"
        case assistantPatchApplied = "assistant_patch_applied"
        case assistantPatchRejected = "assistant_patch_rejected"
        case undoApplied = "undo_applied"
    }

    let schemaVersion: String
    let eventType: EventType
    let eventId: UUID
    let patchId: UUID?
    let undoPatchId: UUID?
    let listId: String
    let itemId: UUID?
    let fromIndex: Int?
    let toIndex: Int?
    let revisionBefore: Int?
    let revisionAfter: Int?
    let reason: String?
    let rationale: String?
    let patch: SortPatch?
    let undoPatch: SortPatch?
    let createdAt: String
}

final class SortAssistantSortEventLog {
    static let workstreamId = "cmux-sort-assistant"
    static let toolName = "cmux.sort_event"
    static let schemaVersion = "cmux.sort_event.v1"

    private let fileURL: URL
    private let itemDecoder: JSONDecoder
    private let eventDecoder = JSONDecoder()
    private let eventEncoder = JSONEncoder()

    init(fileURL: URL = WorkstreamPersistence.defaultFileURL()) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.itemDecoder = decoder
    }

    @MainActor
    func append(_ event: SortAssistantSortEvent) {
        guard let data = try? eventEncoder.encode(event),
              let resultJSON = String(data: data, encoding: .utf8) else {
            return
        }
        let item = WorkstreamItem(
            workstreamId: Self.workstreamId,
            source: .cmux,
            kind: .toolResult,
            title: Self.title(for: event.eventType),
            payload: .toolResult(
                toolName: Self.toolName,
                resultJSON: resultJSON,
                isError: false
            )
        )
        Task {
            try? await SortAssistantWorkstreamPersistence.shared.append(item)
        }
    }

    func loadEvents() -> [SortAssistantSortEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        return lines.compactMap { line in
            let lineData = Data(line)
            guard let item = try? itemDecoder.decode(WorkstreamItem.self, from: lineData),
                  case .toolResult(let toolName, let resultJSON, false) = item.payload,
                  toolName == Self.toolName,
                  let eventData = resultJSON.data(using: .utf8),
                  let event = try? eventDecoder.decode(SortAssistantSortEvent.self, from: eventData),
                  event.schemaVersion == Self.schemaVersion else {
                return nil
            }
            return event
        }
    }

    private static func title(for eventType: SortAssistantSortEvent.EventType) -> String {
        switch eventType {
        case .userDragMove:
            return String(localized: "sortAssistant.event.userDragMove", defaultValue: "Workspace order changed")
        case .assistantPatchApplied:
            return String(localized: "sortAssistant.event.patchApplied", defaultValue: "Assistant sort applied")
        case .assistantPatchRejected:
            return String(localized: "sortAssistant.event.patchRejected", defaultValue: "Assistant sort rejected")
        case .undoApplied:
            return String(localized: "sortAssistant.event.undoApplied", defaultValue: "Assistant sort undone")
        }
    }
}

@MainActor
final class SortContextProvider {
    private let eventLog: SortAssistantSortEventLog
    private let engine: SortEngine

    init(eventLog: SortAssistantSortEventLog, engine: SortEngine) {
        self.eventLog = eventLog
        self.engine = engine
    }

    func context(
        userIntent: String,
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore,
        memories: [SortAssistantMemory],
        lastAssistantProposal: [UUID]?
    ) -> SortAssistantSortContext {
        let tabs = tabManager.tabs
        let itemSignals = Self.itemSignals(
            tabs: tabs,
            summaryPriority: workspaceTabStore.summaryPriority
        )
        let ruleBuckets = Self.ruleBuckets(memories: memories)
        return SortAssistantSortContext(
            userIntent: userIntent,
            currentList: SortAssistantSortContext.CurrentList(
                listId: SortEngine.workspaceListId,
                revision: SortEngine.revision(for: tabs),
                visibleItemIds: tabs.map { $0.id.uuidString },
                selectedItemIds: tabManager.selectedTabId.map { [$0.uuidString] },
                lockedItemIds: engine.lockedItemIds().map(\.uuidString).sorted(),
                pinnedItemIds: tabs.filter(\.isPinned).map { $0.id.uuidString }
            ),
            shortTermMemory: SortAssistantSortContext.ShortTermMemory(
                recentMoves: recentMoves(limit: 8),
                activeConstraints: activeConstraints(tabs: tabs),
                lastAssistantProposal: lastAssistantProposal?.map(\.uuidString)
            ),
            longTermMemory: SortAssistantSortContext.LongTermMemory(
                userPreferences: ruleBuckets.userPreferences,
                projectRules: ruleBuckets.projectRules,
                workspaceRules: ruleBuckets.workspaceRules
            ),
            itemSignals: itemSignals.reduce(into: [:]) { partial, pair in
                partial[pair.key.uuidString] = pair.value
            }
        )
    }

    func itemSignals(
        tabManager: TabManager,
        workspaceTabStore: WorkspaceTabStore
    ) -> [UUID: SortAssistantSortContext.ItemSignals] {
        Self.itemSignals(tabs: tabManager.tabs, summaryPriority: workspaceTabStore.summaryPriority)
    }

    private func recentMoves(limit: Int) -> [SortAssistantSortContext.RecentMove] {
        eventLog.loadEvents().reversed().compactMap { event in
            guard event.eventType == .userDragMove,
                  let itemId = event.itemId,
                  let fromIndex = event.fromIndex,
                  let toIndex = event.toIndex else {
                return nil
            }
            return SortAssistantSortContext.RecentMove(
                itemId: itemId.uuidString,
                fromIndex: fromIndex,
                toIndex: toIndex,
                reason: event.reason
            )
        }.prefix(limit).map { $0 }
    }

    private func activeConstraints(tabs: [Workspace]) -> [String] {
        var constraints = [
            "do_not_move_locked_items",
            "keep_pinned_items_at_top",
            "preserve_relative_order_when_score_ties",
        ]
        if !tabs.filter(\.isPinned).isEmpty {
            constraints.append("pinned_workspaces_are_hard_constraints")
        }
        if !engine.lockedItemIds().isEmpty {
            constraints.append("locked_workspaces_keep_absolute_positions")
        }
        return constraints
    }

    private static func itemSignals(
        tabs: [Workspace],
        summaryPriority: WorkspaceSidebarSummaryPriorityState?
    ) -> [UUID: SortAssistantSortContext.ItemSignals] {
        let summaryById: [UUID: WorkspaceSidebarSummaryPriorityItem] = (summaryPriority?.items ?? [])
            .reduce(into: [:]) { partial, item in
                guard let id = UUID(uuidString: item.workspaceId), partial[id] == nil else { return }
                partial[id] = item
            }
        return Dictionary(uniqueKeysWithValues: tabs.map { tab in
            let item = summaryById[tab.id]
            let priority = item?.scores.dimensions
                .sorted { lhs, rhs in lhs.value.rawScore > rhs.value.rawScore }
                .first
                .map { "\($0.key):\(Int($0.value.rawScore))" }
            return (
                tab.id,
                SortAssistantSortContext.ItemSignals(
                    title: item?.title ?? tab.title,
                    deadline: nil,
                    priority: priority,
                    status: item?.presentStatus ?? item?.status,
                    assignee: nil,
                    customerImpact: item?.scores.dimensions["importance"]?.rawScore,
                    blockedBy: item?.status.lowercased().contains("blocked") == true ? [item?.status ?? "blocked"] : nil,
                    tags: item?.topic.text.isEmpty == false ? [item?.topic.text ?? ""] : nil
                )
            )
        })
    }

    private static func ruleBuckets(memories: [SortAssistantMemory]) -> (
        userPreferences: [String],
        projectRules: [String],
        workspaceRules: [String]
    ) {
        var userPreferences: [String] = []
        var projectRules: [String] = []
        var workspaceRules: [String] = []
        for memory in memories {
            let lower = memory.text.lowercased()
            if lower.contains("project") || lower.contains("项目") {
                projectRules.append(memory.text)
            } else if lower.contains("workspace") || lower.contains("工作区") {
                workspaceRules.append(memory.text)
            } else {
                userPreferences.append(memory.text)
            }
        }
        return (userPreferences, projectRules, workspaceRules)
    }
}

@MainActor
final class SortOperator {
    private let engine: SortEngine
    private let eventLog: SortAssistantSortEventLog
    private let iso8601Formatter = ISO8601DateFormatter()

    init(engine: SortEngine, eventLog: SortAssistantSortEventLog) {
        self.engine = engine
        self.eventLog = eventLog
    }

    func makeBatchPatch(
        orderedIds: [UUID],
        tabs: [Workspace],
        rationale: String?,
        confidence: Double? = nil,
        requiresConfirmation: Bool
    ) -> SortPatch {
        SortPatch(
            listId: SortEngine.workspaceListId,
            baseRevision: SortEngine.revision(for: tabs),
            operations: [.batchReorder(itemIds: orderedIds, preserveLockedItems: true)],
            rationale: rationale,
            confidence: confidence,
            requiresConfirmation: requiresConfirmation
        )
    }

    func preview(
        patch: SortPatch,
        tabs: [Workspace],
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals] = [:]
    ) throws -> SortEnginePreview {
        try engine.preview(patch: patch, tabs: tabs, itemSignals: itemSignals)
    }

    func apply(
        patch: SortPatch,
        tabManager: TabManager,
        itemSignals: [UUID: SortAssistantSortContext.ItemSignals] = [:],
        actor: String
    ) throws -> SortEngineApplyResult {
        let revisionBefore = SortEngine.revision(for: tabManager.tabs)
        let result = try engine.apply(patch: patch, tabManager: tabManager, itemSignals: itemSignals)
        eventLog.append(
            SortAssistantSortEvent(
                schemaVersion: SortAssistantSortEventLog.schemaVersion,
                eventType: .assistantPatchApplied,
                eventId: UUID(),
                patchId: patch.id,
                undoPatchId: result.undoPatch.id,
                listId: patch.listId,
                itemId: nil,
                fromIndex: nil,
                toIndex: nil,
                revisionBefore: revisionBefore,
                revisionAfter: result.revisionAfter,
                reason: actor,
                rationale: patch.rationale,
                patch: patch,
                undoPatch: result.undoPatch,
                createdAt: iso8601Formatter.string(from: Date())
            )
        )
        return result
    }

    func reject(patch: SortPatch, reason: String?) {
        eventLog.append(
            SortAssistantSortEvent(
                schemaVersion: SortAssistantSortEventLog.schemaVersion,
                eventType: .assistantPatchRejected,
                eventId: UUID(),
                patchId: patch.id,
                undoPatchId: nil,
                listId: patch.listId,
                itemId: nil,
                fromIndex: nil,
                toIndex: nil,
                revisionBefore: nil,
                revisionAfter: nil,
                reason: reason,
                rationale: patch.rationale,
                patch: patch,
                undoPatch: nil,
                createdAt: iso8601Formatter.string(from: Date())
            )
        )
    }

    func undo(tabManager: TabManager) throws -> SortEngineApplyResult? {
        guard let event = lastUndoableEvent() else { return nil }
        guard let undoPatch = event.undoPatch else { return nil }
        let result = try engine.apply(patch: undoPatch, tabManager: tabManager)
        eventLog.append(
            SortAssistantSortEvent(
                schemaVersion: SortAssistantSortEventLog.schemaVersion,
                eventType: .undoApplied,
                eventId: UUID(),
                patchId: event.patchId,
                undoPatchId: undoPatch.id,
                listId: undoPatch.listId,
                itemId: nil,
                fromIndex: nil,
                toIndex: nil,
                revisionBefore: undoPatch.baseRevision,
                revisionAfter: result.revisionAfter,
                reason: "assistant_undo",
                rationale: undoPatch.rationale,
                patch: undoPatch,
                undoPatch: result.undoPatch,
                createdAt: iso8601Formatter.string(from: Date())
            )
        )
        return result
    }

    func recordUserDragMove(
        itemId: UUID,
        fromIndex: Int,
        toIndex: Int,
        revision: Int,
        reason: String?
    ) {
        eventLog.append(
            SortAssistantSortEvent(
                schemaVersion: SortAssistantSortEventLog.schemaVersion,
                eventType: .userDragMove,
                eventId: UUID(),
                patchId: nil,
                undoPatchId: nil,
                listId: SortEngine.workspaceListId,
                itemId: itemId,
                fromIndex: fromIndex,
                toIndex: toIndex,
                revisionBefore: nil,
                revisionAfter: revision,
                reason: reason,
                rationale: nil,
                patch: nil,
                undoPatch: nil,
                createdAt: iso8601Formatter.string(from: Date())
            )
        )
    }

    func lastUndoableEvent() -> SortAssistantSortEvent? {
        let events = eventLog.loadEvents()
        let undonePatchIds = Set(events.compactMap { event -> UUID? in
            event.eventType == .undoApplied ? event.patchId : nil
        })
        return events.reversed().first { event in
            event.eventType == .assistantPatchApplied &&
                event.patchId.map { !undonePatchIds.contains($0) } == true &&
                event.undoPatch != nil
        }
    }

    func events() -> [SortAssistantSortEvent] {
        eventLog.loadEvents()
    }
}
