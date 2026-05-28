import CMUXOrchestration

typealias RankingEngine = CMUXOrchestration.RankingEngine
typealias ProactiveSuggestionTypes = CMUXOrchestration.ProactiveSuggestionTypes
typealias SuggestionEngine = CMUXOrchestration.SuggestionEngine
typealias SuggestionStore = CMUXOrchestration.SuggestionStore
typealias NextWorkspaceService = CMUXOrchestration.NextWorkspaceService

struct RankingSnapshotStore: Sendable {
    private let snapshotStore: WorkspaceSnapshotStore

    init(snapshotStore: WorkspaceSnapshotStore) {
        self.snapshotStore = snapshotStore
    }

    func setLatestRanking(_ ranking: RankingSnapshot?) async {
        await snapshotStore.setLatestRanking(ranking)
    }

    func latestRanking() async -> RankingSnapshot? {
        await snapshotStore.latestRanking()
    }
}

struct SuggestionSnapshotStore: Sendable {
    private let snapshotStore: WorkspaceSnapshotStore

    init(snapshotStore: WorkspaceSnapshotStore) {
        self.snapshotStore = snapshotStore
    }

    func setActiveSuggestions(_ suggestions: [ProactiveSuggestion]) async {
        await snapshotStore.setActiveSuggestions(suggestions)
    }

    func activeSuggestions() async -> [ProactiveSuggestion] {
        await snapshotStore.activeSuggestions()
    }
}
