import Foundation

struct SortAssistantSortContext: Codable, Equatable {
    struct CurrentList: Codable, Equatable {
        let listId: String
        let revision: Int
        let visibleItemIds: [String]
        let selectedItemIds: [String]?
        let lockedItemIds: [String]?
        let pinnedItemIds: [String]?
    }

    struct RecentMove: Codable, Equatable {
        let itemId: String
        let fromIndex: Int
        let toIndex: Int
        let reason: String?
    }

    struct ShortTermMemory: Codable, Equatable {
        let recentMoves: [RecentMove]
        let activeConstraints: [String]
        let lastAssistantProposal: [String]?
    }

    struct LongTermMemory: Codable, Equatable {
        let userPreferences: [String]
        let projectRules: [String]
        let workspaceRules: [String]
    }

    struct ItemSignals: Codable, Equatable {
        let title: String
        let deadline: String?
        let priority: String?
        let status: String?
        let assignee: String?
        let customerImpact: Double?
        let blockedBy: [String]?
        let tags: [String]?
    }

    let userIntent: String
    let currentList: CurrentList
    let shortTermMemory: ShortTermMemory
    let longTermMemory: LongTermMemory
    let itemSignals: [String: ItemSignals]
}

enum SortGroupField: String, Codable, Equatable {
    case project
    case priority
    case status
    case assignee
    case tag
}

enum SortPinPosition: String, Codable, Equatable {
    case top
    case bottom
}

enum SortOperation: Equatable {
    case moveBefore(itemId: UUID, beforeItemId: UUID)
    case moveAfter(itemId: UUID, afterItemId: UUID)
    case batchReorder(itemIds: [UUID], preserveLockedItems: Bool)
    case pin(itemId: UUID, position: SortPinPosition)
    case lock(itemId: UUID)
    case groupBy(field: SortGroupField)

    var itemIds: [UUID] {
        switch self {
        case .moveBefore(let itemId, let beforeItemId):
            return [itemId, beforeItemId]
        case .moveAfter(let itemId, let afterItemId):
            return [itemId, afterItemId]
        case .batchReorder(let itemIds, _):
            return itemIds
        case .pin(let itemId, _), .lock(let itemId):
            return [itemId]
        case .groupBy:
            return []
        }
    }
}

extension SortOperation: Codable {
    private enum OperationType: String, Codable {
        case moveBefore = "move_before"
        case moveAfter = "move_after"
        case batchReorder = "batch_reorder"
        case pin
        case lock
        case groupBy = "group_by"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case itemId
        case beforeItemId
        case afterItemId
        case itemIds
        case preserveLockedItems
        case position
        case field
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(OperationType.self, forKey: .type)
        switch type {
        case .moveBefore:
            self = .moveBefore(
                itemId: try container.decode(UUID.self, forKey: .itemId),
                beforeItemId: try container.decode(UUID.self, forKey: .beforeItemId)
            )
        case .moveAfter:
            self = .moveAfter(
                itemId: try container.decode(UUID.self, forKey: .itemId),
                afterItemId: try container.decode(UUID.self, forKey: .afterItemId)
            )
        case .batchReorder:
            self = .batchReorder(
                itemIds: try container.decode([UUID].self, forKey: .itemIds),
                preserveLockedItems: try container.decodeIfPresent(Bool.self, forKey: .preserveLockedItems) ?? true
            )
        case .pin:
            self = .pin(
                itemId: try container.decode(UUID.self, forKey: .itemId),
                position: try container.decodeIfPresent(SortPinPosition.self, forKey: .position) ?? .top
            )
        case .lock:
            self = .lock(itemId: try container.decode(UUID.self, forKey: .itemId))
        case .groupBy:
            self = .groupBy(field: try container.decode(SortGroupField.self, forKey: .field))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .moveBefore(let itemId, let beforeItemId):
            try container.encode(OperationType.moveBefore, forKey: .type)
            try container.encode(itemId, forKey: .itemId)
            try container.encode(beforeItemId, forKey: .beforeItemId)
        case .moveAfter(let itemId, let afterItemId):
            try container.encode(OperationType.moveAfter, forKey: .type)
            try container.encode(itemId, forKey: .itemId)
            try container.encode(afterItemId, forKey: .afterItemId)
        case .batchReorder(let itemIds, let preserveLockedItems):
            try container.encode(OperationType.batchReorder, forKey: .type)
            try container.encode(itemIds, forKey: .itemIds)
            try container.encode(preserveLockedItems, forKey: .preserveLockedItems)
        case .pin(let itemId, let position):
            try container.encode(OperationType.pin, forKey: .type)
            try container.encode(itemId, forKey: .itemId)
            try container.encode(position, forKey: .position)
        case .lock(let itemId):
            try container.encode(OperationType.lock, forKey: .type)
            try container.encode(itemId, forKey: .itemId)
        case .groupBy(let field):
            try container.encode(OperationType.groupBy, forKey: .type)
            try container.encode(field, forKey: .field)
        }
    }
}

struct SortPatch: Identifiable, Codable, Equatable {
    let id: UUID
    let listId: String
    let baseRevision: Int
    let operations: [SortOperation]
    let rationale: String?
    let confidence: Double?
    var requiresConfirmation: Bool

    init(
        id: UUID = UUID(),
        listId: String,
        baseRevision: Int,
        operations: [SortOperation],
        rationale: String? = nil,
        confidence: Double? = nil,
        requiresConfirmation: Bool
    ) {
        self.id = id
        self.listId = listId
        self.baseRevision = baseRevision
        self.operations = operations
        self.rationale = rationale
        self.confidence = confidence
        self.requiresConfirmation = requiresConfirmation
    }
}

struct SortEnginePreview: Equatable {
    let patch: SortPatch
    let orderBefore: [UUID]
    let orderAfter: [UUID]
    let changes: [String]
    let affectedItemIds: [UUID]
    let rationale: String?
    let requiresConfirmation: Bool
}

struct SortEngineApplyResult: Equatable {
    let preview: SortEnginePreview
    let undoPatch: SortPatch
    let revisionAfter: Int
}

enum SortEngineError: LocalizedError, Equatable {
    case wrongList(String)
    case emptyPatch
    case revisionConflict(expected: Int, actual: Int)
    case unknownItem(UUID)
    case lockedItemMoved(UUID)
    case pinnedConstraint(UUID)
    case applyFailed

    var errorDescription: String? {
        switch self {
        case .wrongList(let listId):
            return String(localized: "sortAssistant.error.wrongList", defaultValue: "Unsupported sort list: \(listId)")
        case .emptyPatch:
            return String(localized: "sortAssistant.error.emptyPatch", defaultValue: "The sort patch has no operations.")
        case .revisionConflict(let expected, let actual):
            return String(
                localized: "sortAssistant.error.revisionConflict",
                defaultValue: "The workspace order changed before the sort could apply. Expected revision \(expected), found \(actual)."
            )
        case .unknownItem(let itemId):
            return String(localized: "sortAssistant.error.unknownItem", defaultValue: "The sort patch references an unknown workspace: \(itemId.uuidString).")
        case .lockedItemMoved(let itemId):
            return String(localized: "sortAssistant.error.lockedItemMoved", defaultValue: "A locked workspace would move: \(itemId.uuidString).")
        case .pinnedConstraint(let itemId):
            return String(localized: "sortAssistant.error.pinnedConstraint", defaultValue: "A pinned workspace would leave the pinned section: \(itemId.uuidString).")
        case .applyFailed:
            return String(localized: "sortAssistant.error.applyFailed", defaultValue: "The workspace order could not be applied.")
        }
    }
}
