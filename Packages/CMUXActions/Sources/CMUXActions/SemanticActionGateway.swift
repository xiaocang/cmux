import Foundation

public enum CmuxActionKind: String, Codable, Equatable, Sendable {
    case switchWorkspace
    case applySort
    case undoSort
    case setWorkspaceColor
    case clearWorkspaceColor
    case pinWorkspace
    case lockList
    case acceptSuggestion
    case dismissSuggestion
    case writeMemory
    case forgetMemory
}

public struct ActionRequester: Codable, Equatable, Sendable {
    public var id: String
    public var route: String?

    public init(id: String, route: String? = nil) {
        self.id = id
        self.route = route
    }
}

public struct ActionEvidence: Codable, Equatable, Sendable {
    public var snapshotVersions: [UUID: Int]
    public var snapshotUpdatedAt: [UUID: Date]
    public var suggestionId: UUID?
    public var rankingSnapshotId: UUID?

    public init(
        snapshotVersions: [UUID: Int],
        snapshotUpdatedAt: [UUID: Date],
        suggestionId: UUID? = nil,
        rankingSnapshotId: UUID? = nil
    ) {
        self.snapshotVersions = snapshotVersions
        self.snapshotUpdatedAt = snapshotUpdatedAt
        self.suggestionId = suggestionId
        self.rankingSnapshotId = rankingSnapshotId
    }
}

public struct ActionIntent: Codable, Equatable, Sendable {
    public var id: UUID
    public var requestedBy: ActionRequester
    public var kind: CmuxActionKind
    public var arguments: [String: String]
    public var reason: String?
    public var evidence: ActionEvidence
    public var createdAt: Date

    public init(
        id: UUID,
        requestedBy: ActionRequester,
        kind: CmuxActionKind,
        arguments: [String: String],
        reason: String? = nil,
        evidence: ActionEvidence,
        createdAt: Date
    ) {
        self.id = id
        self.requestedBy = requestedBy
        self.kind = kind
        self.arguments = arguments
        self.reason = reason
        self.evidence = evidence
        self.createdAt = createdAt
    }
}

public enum SemanticActionDecision: String, Codable, Equatable, Sendable {
    case allow
    case requireConfirmation
    case deny
}

public struct SemanticReviewSignal: Equatable, Sendable {
    public var decision: SemanticActionDecision
    public var reason: String

    public init(decision: SemanticActionDecision, reason: String) {
        self.decision = decision
        self.reason = reason
    }
}

public struct ActionExecutionResult: Equatable, Sendable {
    public var payload: [String: String]

    public init(payload: [String: String]) {
        self.payload = payload
    }
}

public struct SemanticReviewResult: Equatable, Sendable {
    public var intentId: UUID
    public var decision: SemanticActionDecision
    public var reasons: [String]
    public var executed: Bool
    public var executionResult: ActionExecutionResult?

    public init(
        intentId: UUID,
        decision: SemanticActionDecision,
        reasons: [String],
        executed: Bool,
        executionResult: ActionExecutionResult?
    ) {
        self.intentId = intentId
        self.decision = decision
        self.reasons = reasons
        self.executed = executed
        self.executionResult = executionResult
    }
}

public struct SemanticActionAuditEntry: Equatable, Sendable {
    public var intentId: UUID
    public var kind: CmuxActionKind
    public var trustFingerprint: String
    public var decision: SemanticActionDecision
    public var executed: Bool
    public var reasons: [String]
    public var recordedAt: Date

    public init(
        intentId: UUID,
        kind: CmuxActionKind,
        trustFingerprint: String,
        decision: SemanticActionDecision,
        executed: Bool,
        reasons: [String],
        recordedAt: Date
    ) {
        self.intentId = intentId
        self.kind = kind
        self.trustFingerprint = trustFingerprint
        self.decision = decision
        self.executed = executed
        self.reasons = reasons
        self.recordedAt = recordedAt
    }
}

public protocol ActionReviewer: Sendable {
    func review(_ intent: ActionIntent) async -> SemanticReviewSignal?
}

public protocol CmuxActionExecutor: Sendable {
    func execute(_ intent: ActionIntent) async throws -> ActionExecutionResult
}

public protocol ActionAuditLog: Sendable {
    func recordReview(intent: ActionIntent, result: SemanticReviewResult) async
    func recordExecuted(intent: ActionIntent, result: ActionExecutionResult) async
}

public struct AllowingActionReviewer: ActionReviewer {
    public init() {}

    public func review(_ intent: ActionIntent) async -> SemanticReviewSignal? {
        nil
    }
}

public struct ActionFreshnessReviewer: ActionReviewer {
    public var maxSnapshotAge: TimeInterval
    public var now: Date

    public init(maxSnapshotAge: TimeInterval, now: Date) {
        self.maxSnapshotAge = maxSnapshotAge
        self.now = now
    }

    public func review(_ intent: ActionIntent) async -> SemanticReviewSignal? {
        Self.review(intent, maxSnapshotAge: maxSnapshotAge, now: now)
    }

    public static func review(
        _ intent: ActionIntent,
        maxSnapshotAge: TimeInterval,
        now: Date
    ) -> SemanticReviewSignal? {
        guard requiresSnapshotEvidence(intent.kind) else { return nil }
        guard !intent.evidence.snapshotVersions.isEmpty else {
            return SemanticReviewSignal(
                decision: .requireConfirmation,
                reason: "missing snapshot evidence"
            )
        }
        let staleWorkspaceIds = intent.evidence.snapshotVersions.keys.filter { workspaceId in
            guard let updatedAt = intent.evidence.snapshotUpdatedAt[workspaceId] else { return true }
            return now.timeIntervalSince(updatedAt) > maxSnapshotAge
        }
        guard !staleWorkspaceIds.isEmpty else { return nil }
        return SemanticReviewSignal(
            decision: .requireConfirmation,
            reason: "stale snapshot evidence"
        )
    }

    private static func requiresSnapshotEvidence(_ kind: CmuxActionKind) -> Bool {
        switch kind {
        case .switchWorkspace,
             .applySort,
             .undoSort,
             .setWorkspaceColor,
             .clearWorkspaceColor,
             .pinWorkspace,
             .lockList,
             .acceptSuggestion,
             .dismissSuggestion:
            return true
        case .writeMemory,
             .forgetMemory:
            return false
        }
    }
}

public struct ActionArgumentReviewer: ActionReviewer {
    public init() {}

    public func review(_ intent: ActionIntent) async -> SemanticReviewSignal? {
        Self.review(intent)
    }

    public static func review(_ intent: ActionIntent) -> SemanticReviewSignal? {
        switch intent.kind {
        case .switchWorkspace:
            return requireWorkspaceId(in: intent)
        case .applySort:
            return reviewApplySort(intent)
        case .undoSort:
            return requireNonEmpty("listId", in: intent)
        case .setWorkspaceColor:
            return requireWorkspaceId(in: intent)
                ?? requireHexColor(in: intent)
        case .clearWorkspaceColor:
            return requireWorkspaceId(in: intent)
        case .pinWorkspace:
            return requireItemId(in: intent)
                ?? requireBoolean("pinned", in: intent)
        case .lockList:
            return requireItemId(in: intent)
                ?? requireBoolean("locked", in: intent)
        case .acceptSuggestion:
            return requireSuggestionId(in: intent)
                ?? requireWorkspaceId(in: intent)
        case .dismissSuggestion:
            return requireSuggestionId(in: intent)
                ?? requireWorkspaceId(in: intent)
        case .writeMemory:
            return requireMemoryWriteArguments(intent)
        case .forgetMemory:
            return requireMemoryForgetArguments(intent)
        }
    }

    private static func reviewApplySort(_ intent: ActionIntent) -> SemanticReviewSignal? {
        if let signal = requireUUID("patchId", in: intent) {
            return signal
        }
        guard nonEmpty("itemIds", in: intent) != nil else {
            return deny("missing sort target")
        }
        guard let itemIds = uuidList("itemIds", in: intent), !itemIds.isEmpty else {
            return deny("invalid workspace target")
        }
        guard Set(itemIds).count == itemIds.count else {
            return deny("duplicate workspace target")
        }
        return requireSnapshotEvidence(for: itemIds, intent: intent)
    }

    private static func requireWorkspaceId(in intent: ActionIntent) -> SemanticReviewSignal? {
        guard let workspaceId = uuid("workspaceId", in: intent) else {
            return deny("invalid workspace target")
        }
        return requireSnapshotEvidence(for: [workspaceId], intent: intent)
    }

    private static func requireItemId(in intent: ActionIntent) -> SemanticReviewSignal? {
        guard let itemId = uuid("itemId", in: intent) else {
            return deny("invalid workspace target")
        }
        return requireSnapshotEvidence(for: [itemId], intent: intent)
    }

    private static func requireSuggestionId(in intent: ActionIntent) -> SemanticReviewSignal? {
        requireUUID("suggestionId", in: intent)
    }

    private static func requireMemoryWriteArguments(_ intent: ActionIntent) -> SemanticReviewSignal? {
        guard let domain = nonEmpty("domain", in: intent),
              ["free_sort", "sprite"].contains(domain) else {
            return deny("invalid memory domain")
        }
        return requireNonEmpty("text", in: intent)
    }

    private static func requireMemoryForgetArguments(_ intent: ActionIntent) -> SemanticReviewSignal? {
        guard let domain = nonEmpty("domain", in: intent),
              ["free_sort", "sprite"].contains(domain) else {
            return deny("invalid memory domain")
        }
        if let id = nonEmpty("id", in: intent),
           UUID(uuidString: id) == nil {
            return deny("invalid memory id")
        }
        guard nonEmpty("id", in: intent) != nil || nonEmpty("text", in: intent) != nil else {
            return deny("missing memory target")
        }
        return nil
    }

    private static func requireHexColor(in intent: ActionIntent) -> SemanticReviewSignal? {
        guard let color = nonEmpty("color", in: intent),
              normalizedHexColor(color) != nil else {
            return deny("invalid color argument")
        }
        return nil
    }

    private static func requireBoolean(
        _ name: String,
        in intent: ActionIntent
    ) -> SemanticReviewSignal? {
        guard let value = nonEmpty(name, in: intent)?.lowercased(),
              value == "true" || value == "false" else {
            return deny("invalid \(name) argument")
        }
        return nil
    }

    private static func requireNonEmpty(
        _ name: String,
        in intent: ActionIntent
    ) -> SemanticReviewSignal? {
        nonEmpty(name, in: intent) == nil ? deny("missing \(name) argument") : nil
    }

    private static func requireUUID(
        _ name: String,
        in intent: ActionIntent
    ) -> SemanticReviewSignal? {
        uuid(name, in: intent) == nil ? deny("invalid \(name) argument") : nil
    }

    private static func requireSnapshotEvidence(
        for workspaceIds: [UUID],
        intent: ActionIntent
    ) -> SemanticReviewSignal? {
        let missingEvidence = workspaceIds.contains { workspaceId in
            intent.evidence.snapshotVersions[workspaceId] == nil
        }
        guard missingEvidence else { return nil }
        return SemanticReviewSignal(
            decision: .requireConfirmation,
            reason: "missing snapshot evidence for action target"
        )
    }

    private static func uuid(_ name: String, in intent: ActionIntent) -> UUID? {
        nonEmpty(name, in: intent).flatMap(UUID.init(uuidString:))
    }

    private static func uuidList(_ name: String, in intent: ActionIntent) -> [UUID]? {
        guard let raw = nonEmpty(name, in: intent) else { return nil }
        var ids: [UUID] = []
        for part in raw.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }) {
            guard let uuid = UUID(uuidString: String(part)) else {
                return nil
            }
            ids.append(uuid)
        }
        return ids
    }

    private static func nonEmpty(_ name: String, in intent: ActionIntent) -> String? {
        let value = intent.arguments[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func normalizedHexColor(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard body.count == 6,
              UInt64(body, radix: 16) != nil else {
            return nil
        }
        return "#" + body.uppercased()
    }

    private static func deny(_ reason: String) -> SemanticReviewSignal {
        SemanticReviewSignal(decision: .deny, reason: reason)
    }
}

public actor SemanticActionGateway {
    private let reviewers: [any ActionReviewer]
    private let executor: any CmuxActionExecutor
    private let auditLog: any ActionAuditLog

    public init(
        reviewers: [any ActionReviewer],
        executor: any CmuxActionExecutor,
        auditLog: any ActionAuditLog
    ) {
        self.reviewers = reviewers
        self.executor = executor
        self.auditLog = auditLog
    }

    public func submit(_ intent: ActionIntent) async throws -> SemanticReviewResult {
        var signals: [SemanticReviewSignal] = []
        for reviewer in reviewers {
            if let signal = await reviewer.review(intent) {
                signals.append(signal)
            }
        }

        let decision = Self.merge(signals)
        var result = SemanticReviewResult(
            intentId: intent.id,
            decision: decision,
            reasons: signals.map(\.reason),
            executed: false,
            executionResult: nil
        )
        await auditLog.recordReview(intent: intent, result: result)

        guard decision == .allow else {
            return result
        }

        let executionResult = try await executor.execute(intent)
        await auditLog.recordExecuted(intent: intent, result: executionResult)
        result.executed = true
        result.executionResult = executionResult
        return result
    }

    public static func submitSynchronously(
        _ intent: ActionIntent,
        reviewSignals: [SemanticReviewSignal] = [],
        recordedAt: Date = Date(),
        recordReview: ((ActionIntent, SemanticReviewResult, Date) -> Void)? = nil,
        recordExecuted: ((ActionIntent, ActionExecutionResult, Date) -> Void)? = nil,
        execute: () throws -> ActionExecutionResult
    ) throws -> SemanticReviewResult {
        let decision = merge(reviewSignals)
        var result = SemanticReviewResult(
            intentId: intent.id,
            decision: decision,
            reasons: reviewSignals.map(\.reason),
            executed: false,
            executionResult: nil
        )
        recordReview?(intent, result, recordedAt)

        guard decision == .allow else {
            return result
        }

        let executionResult = try execute()
        recordExecuted?(intent, executionResult, recordedAt)
        result.executed = true
        result.executionResult = executionResult
        return result
    }

    private static func merge(_ signals: [SemanticReviewSignal]) -> SemanticActionDecision {
        if signals.contains(where: { $0.decision == .deny }) {
            return .deny
        }
        if signals.contains(where: { $0.decision == .requireConfirmation }) {
            return .requireConfirmation
        }
        return .allow
    }
}
