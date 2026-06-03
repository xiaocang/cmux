import CMUXContracts
import Foundation

public struct RankingEngine: Sendable {
    public static let `default` = RankingEngine()

    public init() {}

    public func rank(_ snapshots: [WorkspaceSnapshot]) -> RankingSnapshot {
        let ordered = snapshots.sorted { lhs, rhs in
            if lhs.derived.userAttentionNeeded != rhs.derived.userAttentionNeeded {
                return lhs.derived.userAttentionNeeded > rhs.derived.userAttentionNeeded
            }

            let lhsScore = score(for: lhs)
            let rhsScore = score(for: rhs)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }

            if lhs.context.nativeOrder != rhs.context.nativeOrder {
                return lhs.context.nativeOrder < rhs.context.nativeOrder
            }

            return lhs.workspaceId.uuidString < rhs.workspaceId.uuidString
        }
        let components = ordered.map { snapshot in
            "\(snapshot.workspaceId.uuidString):\(snapshot.version):\(snapshot.contextHash)"
        }
        return RankingSnapshot(
            id: StableSnapshotIdentifier.uuid(namespace: "ranking", components: components),
            updatedAt: snapshots.map(\.updatedAt).max() ?? Date(timeIntervalSince1970: 0),
            items: ordered.enumerated().map { index, snapshot in
                RankingSnapshot.Item(
                    workspaceId: snapshot.workspaceId,
                    rank: index + 1,
                    score: score(for: snapshot),
                    reason: snapshot.derived.rankReason ?? snapshot.derived.nextAction
                )
            }
        )
    }

    private func score(for snapshot: WorkspaceSnapshot) -> Double {
        snapshot.derived.priorityScore ?? (snapshot.derived.userAttentionNeeded * 100)
    }
}

public enum ProactiveSuggestionTypes {
    public static let reviewAgentWaitingUser = "review_agent_waiting_user"
    public static let fixCIFailure = "fix_ci_failure"
    public static let mergeReady = "merge_ready"
    public static let workspaceNeedsAttention = "workspace_needs_attention"
}

public struct SuggestionEngine: Sendable {
    public static let `default` = SuggestionEngine()

    public let store: SuggestionStore

    public init(store: SuggestionStore = SuggestionStore()) {
        self.store = store
    }

    public func generate(
        from snapshots: [WorkspaceSnapshot],
        now: Date? = nil
    ) -> [ProactiveSuggestion] {
        makeCandidates(from: snapshots, now: now).map(\.suggestion)
    }

    public func generateAndStore(
        from snapshots: [WorkspaceSnapshot],
        now: Date? = nil
    ) async -> [ProactiveSuggestion] {
        let candidates = makeCandidates(from: snapshots, now: now)
        var visible: [SuggestionCandidate] = []
        for candidate in candidates {
            if await store.isDismissed(candidate.identity) {
                continue
            }
            visible.append(candidate)
        }
        return await store.replaceActive(visible)
    }

    private func makeCandidates(
        from snapshots: [WorkspaceSnapshot],
        now: Date?
    ) -> [SuggestionCandidate] {
        snapshots
            .sorted { lhs, rhs in
                if lhs.context.nativeOrder != rhs.context.nativeOrder {
                    return lhs.context.nativeOrder < rhs.context.nativeOrder
                }
                return lhs.workspaceId.uuidString < rhs.workspaceId.uuidString
            }
            .compactMap { candidate(for: $0, now: now) }
    }

    private func candidate(
        for snapshot: WorkspaceSnapshot,
        now: Date?
    ) -> SuggestionCandidate? {
        let type: String
        switch snapshot.derived.status.lowercased() {
        case "waiting_user", "permission_requested", "question_requested", "exit_plan_ready":
            type = ProactiveSuggestionTypes.reviewAgentWaitingUser
        case "ci_failed":
            type = ProactiveSuggestionTypes.fixCIFailure
        case "ready_to_merge":
            type = ProactiveSuggestionTypes.mergeReady
        default:
            // Any other status (agent_completed, notification, workspace_activity,
            // needs_attention, or an unknown signal) surfaces a generic attention
            // suggestion only when it is both high-attention and actionable.
            guard snapshot.derived.userAttentionNeeded >= 0.9,
                  hasActionableContext(snapshot) else {
                return nil
            }
            type = ProactiveSuggestionTypes.workspaceNeedsAttention
        }

        let identity = SuggestionIdentity(
            workspaceId: snapshot.workspaceId,
            type: type,
            contextHash: snapshot.contextHash
        )
        return SuggestionCandidate(
            suggestion: ProactiveSuggestion(
                id: StableSnapshotIdentifier.uuid(
                    namespace: "suggestion",
                    components: [
                        snapshot.workspaceId.uuidString,
                        type,
                        snapshot.contextHash,
                    ]
                ),
                workspaceId: snapshot.workspaceId,
                type: type,
                title: suggestionTitle(for: snapshot),
                reason: suggestionReason(for: snapshot),
                confidence: max(0.85, snapshot.derived.userAttentionNeeded),
                createdAt: now ?? snapshot.updatedAt
            ),
            identity: identity
        )
    }

    private func suggestionTitle(for snapshot: WorkspaceSnapshot) -> String {
        nonEmpty(snapshot.derived.nextAction)
            ?? nonEmpty(snapshot.derived.rankReason)
            ?? nonEmpty(snapshot.digest?.summary)
            ?? snapshot.context.title
    }

    private func suggestionReason(for snapshot: WorkspaceSnapshot) -> String? {
        nonEmpty(snapshot.derived.rankReason)
            ?? nonEmpty(snapshot.digest?.summary)
    }

    private func hasActionableContext(_ snapshot: WorkspaceSnapshot) -> Bool {
        nonEmpty(snapshot.derived.nextAction) != nil
            || nonEmpty(snapshot.derived.rankReason) != nil
            || nonEmpty(snapshot.digest?.summary) != nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

public actor SuggestionStore {
    private var active: [ProactiveSuggestion] = []
    private var identitiesById: [UUID: SuggestionIdentity] = [:]
    private var dismissedIdentities: Set<SuggestionIdentity> = []

    public init() {}

    public func activeSuggestions() -> [ProactiveSuggestion] {
        active
    }

    fileprivate func replaceActive(_ candidates: [SuggestionCandidate]) -> [ProactiveSuggestion] {
        active = candidates.map(\.suggestion)
        identitiesById = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.suggestion.id, $0.identity) }
        )
        return active
    }

    public func dismiss(_ suggestionId: UUID) {
        guard let identity = identitiesById[suggestionId] else { return }
        dismissedIdentities.insert(identity)
        active.removeAll { $0.id == suggestionId }
    }

    fileprivate func isDismissed(_ identity: SuggestionIdentity) -> Bool {
        dismissedIdentities.contains(identity)
    }
}

public struct NextWorkspaceService: Sendable {
    public static let `default` = NextWorkspaceService()

    public init() {}

    public func nextWorkspace(in context: AssistantWorkingContext) -> RankingSnapshot.Item? {
        guard let ranking = context.latestRanking,
              !ranking.items.isEmpty else {
            return nil
        }

        let snapshotsById = Dictionary(uniqueKeysWithValues: context.snapshots.map { ($0.workspaceId, $0) })
        let rankedItems = ranking.items
            .filter { item in
                guard let snapshot = snapshotsById[item.workspaceId] else { return false }
                return !snapshot.context.locked && !snapshot.context.pinned
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank {
                    return lhs.rank < rhs.rank
                }
                return lhs.workspaceId.uuidString < rhs.workspaceId.uuidString
            }

        guard !rankedItems.isEmpty else { return nil }
        guard let activeWorkspaceId = context.activeWorkspaceId,
              let activeIndex = rankedItems.firstIndex(where: { $0.workspaceId == activeWorkspaceId }) else {
            return rankedItems.first
        }
        let nextIndex = rankedItems.index(after: activeIndex)
        return nextIndex < rankedItems.endIndex ? rankedItems[nextIndex] : rankedItems.first
    }
}

private struct SuggestionCandidate: Sendable {
    var suggestion: ProactiveSuggestion
    var identity: SuggestionIdentity
}

private struct SuggestionIdentity: Hashable, Sendable {
    var workspaceId: UUID
    var type: String
    var contextHash: String
}

private enum StableSnapshotIdentifier {
    static func uuid(namespace: String, components: [String]) -> UUID {
        let payload = ([namespace] + components).joined(separator: "|")
        let first = fnv1a64(Data(payload.utf8))
        let second = fnv1a64(Data("cmux|\(payload)".utf8))
        let uuidString = String(
            format: "%08llx-%04llx-%04llx-%04llx-%012llx",
            (first >> 32) & 0xffff_ffff,
            (first >> 16) & 0xffff,
            first & 0xffff,
            (second >> 48) & 0xffff,
            second & 0xffff_ffff_ffff
        )
        return UUID(uuidString: uuidString)!
    }

    private static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
