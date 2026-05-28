import Foundation

actor WorkspaceSnapshotStore: AssistantContextReadable {
    private var activeWorkspaceId: UUID?
    private var snapshotsByWorkspaceId: [UUID: WorkspaceSnapshot] = [:]
    private var freshnessOverride: ContextFreshness?
    private var suggestions: [ProactiveSuggestion] = []
    private var ranking: RankingSnapshot?

    func replace(_ context: AssistantWorkingContext) {
        activeWorkspaceId = context.activeWorkspaceId
        snapshotsByWorkspaceId = Dictionary(
            context.snapshots.map { ($0.workspaceId, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        freshnessOverride = context.freshness
        suggestions = context.activeSuggestions
        ranking = context.latestRanking
    }

    func write(_ snapshot: WorkspaceSnapshot, activeWorkspaceId: UUID? = nil) {
        snapshotsByWorkspaceId[snapshot.workspaceId] = snapshot
        if let activeWorkspaceId {
            self.activeWorkspaceId = activeWorkspaceId
        }
        freshnessOverride = nil
    }

    func mergeProviderSnapshot(_ snapshot: WorkspaceSnapshot, activeWorkspaceId: UUID? = nil) -> WorkspaceSnapshot {
        let merged = snapshotsByWorkspaceId[snapshot.workspaceId]
            .map { $0.mergingProviderOutput(snapshot) }
            ?? snapshot
        write(merged, activeWorkspaceId: activeWorkspaceId)
        return merged
    }

    func setActiveSuggestions(_ suggestions: [ProactiveSuggestion]) {
        self.suggestions = suggestions
    }

    func setLatestRanking(_ ranking: RankingSnapshot?) {
        self.ranking = ranking
    }

    func assistantWorkingContext() async -> AssistantWorkingContext {
        let snapshots = orderedSnapshots()
        return AssistantWorkingContext(
            activeWorkspaceId: activeWorkspaceId,
            snapshots: snapshots,
            freshness: freshnessOverride ?? Self.aggregateFreshness(from: snapshots.map(\.freshness)),
            activeSuggestions: suggestions,
            latestRanking: ranking
        )
    }

    func workspaceSnapshot(_ id: UUID) async -> WorkspaceSnapshot? {
        snapshotsByWorkspaceId[id]
    }

    func activeSuggestions() async -> [ProactiveSuggestion] {
        suggestions
    }

    func latestRanking() async -> RankingSnapshot? {
        ranking
    }

    private func orderedSnapshots() -> [WorkspaceSnapshot] {
        snapshotsByWorkspaceId.values.sorted { lhs, rhs in
            if lhs.context.nativeOrder != rhs.context.nativeOrder {
                return lhs.context.nativeOrder < rhs.context.nativeOrder
            }
            return lhs.context.title.localizedStandardCompare(rhs.context.title) == .orderedAscending
        }
    }

    private static func aggregateFreshness(from values: [ContextFreshness]) -> ContextFreshness {
        guard !values.isEmpty else {
            return ContextFreshness(providers: [], overallConfidence: 0)
        }
        return ContextFreshness(
            providers: values.flatMap(\.providers),
            overallConfidence: values.map(\.overallConfidence).reduce(0, +) / Double(values.count)
        )
    }
}
