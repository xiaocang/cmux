import Foundation

public struct NormalizedWorkspaceContext: Codable, Equatable, Sendable {
    public var title: String
    public var selected: Bool
    public var directory: String?
    public var listRevision: Int
    public var nativeOrder: Int
    public var pinned: Bool
    public var locked: Bool
    public var customColor: String?
    public var panelCount: Int
    public var pullRequestCount: Int
    public var stalePullRequestCount: Int

    public init(
        title: String,
        selected: Bool,
        directory: String?,
        listRevision: Int,
        nativeOrder: Int,
        pinned: Bool,
        locked: Bool,
        customColor: String?,
        panelCount: Int,
        pullRequestCount: Int,
        stalePullRequestCount: Int
    ) {
        self.title = title
        self.selected = selected
        self.directory = directory
        self.listRevision = listRevision
        self.nativeOrder = nativeOrder
        self.pinned = pinned
        self.locked = locked
        self.customColor = customColor
        self.panelCount = panelCount
        self.pullRequestCount = pullRequestCount
        self.stalePullRequestCount = stalePullRequestCount
    }
}

public struct DerivedWorkspaceState: Codable, Equatable, Sendable {
    public var status: String
    public var priorityScore: Double?
    public var rankReason: String?
    public var nextAction: String?
    public var userAttentionNeeded: Double

    public init(
        status: String,
        priorityScore: Double?,
        rankReason: String?,
        nextAction: String?,
        userAttentionNeeded: Double
    ) {
        self.status = status
        self.priorityScore = priorityScore
        self.rankReason = rankReason
        self.nextAction = nextAction
        self.userAttentionNeeded = userAttentionNeeded
    }
}

public struct WorkspaceDigest: Codable, Equatable, Sendable {
    public var summary: String
    public var generatedAt: Date?

    public init(summary: String, generatedAt: Date?) {
        self.summary = summary
        self.generatedAt = generatedAt
    }
}

public struct WorkspaceDigestUpdatePolicy: Equatable, Sendable {
    public static let semanticContextHash = WorkspaceDigestUpdatePolicy()

    public init() {}

    public func shouldUpdate(previous: WorkspaceSnapshot?, next: WorkspaceSnapshot) -> Bool {
        guard let previous else { return true }
        return previous.contextHash != next.contextHash
    }
}

public struct ProviderFreshness: Codable, Equatable, Sendable {
    public var providerId: String
    public var lastCollectedAt: Date?
    public var ttlSeconds: TimeInterval
    public var stale: Bool
    public var error: String?
    public var confidence: Double

    public init(
        providerId: String,
        lastCollectedAt: Date?,
        ttlSeconds: TimeInterval,
        stale: Bool,
        error: String?,
        confidence: Double
    ) {
        self.providerId = providerId
        self.lastCollectedAt = lastCollectedAt
        self.ttlSeconds = ttlSeconds
        self.stale = stale
        self.error = error
        self.confidence = confidence
    }

    public func evaluated(at now: Date) -> ProviderFreshness {
        var copy = self
        guard let lastCollectedAt else {
            copy.stale = true
            copy.confidence = min(confidence, 0)
            return copy
        }
        copy.stale = stale || now.timeIntervalSince(lastCollectedAt) > ttlSeconds
        if copy.stale {
            copy.confidence = min(confidence, 0.5)
        }
        return copy
    }
}

public struct ContextFreshness: Codable, Equatable, Sendable {
    public var providers: [ProviderFreshness]
    public var overallConfidence: Double

    public init(providers: [ProviderFreshness], overallConfidence: Double) {
        self.providers = providers
        self.overallConfidence = overallConfidence
    }

    public func evaluated(at now: Date) -> ContextFreshness {
        let evaluatedProviders = providers.map { $0.evaluated(at: now) }
        let confidence = evaluatedProviders.isEmpty
            ? 0
            : evaluatedProviders.map(\.confidence).reduce(0, +) / Double(evaluatedProviders.count)
        return ContextFreshness(
            providers: evaluatedProviders,
            overallConfidence: min(overallConfidence, confidence)
        )
    }

    public func merging(_ overlay: ContextFreshness) -> ContextFreshness {
        var providerOrder: [String] = []
        var providersById: [String: ProviderFreshness] = [:]
        for provider in providers + overlay.providers {
            if providersById[provider.providerId] == nil {
                providerOrder.append(provider.providerId)
            }
            providersById[provider.providerId] = provider
        }
        let mergedProviders = providerOrder.compactMap { providersById[$0] }
        return ContextFreshness(
            providers: mergedProviders,
            overallConfidence: Self.confidence(for: mergedProviders)
        )
    }

    public func filteringProviders(_ providerIds: Set<String>) -> ContextFreshness {
        let filteredProviders = providers.filter { providerIds.contains($0.providerId) }
        return ContextFreshness(
            providers: filteredProviders,
            overallConfidence: Self.confidence(for: filteredProviders)
        )
    }

    private static func confidence(for providers: [ProviderFreshness]) -> Double {
        guard !providers.isEmpty else { return 0 }
        return providers.map(\.confidence).reduce(0, +) / Double(providers.count)
    }
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var workspaceId: UUID
    public var version: Int
    public var updatedAt: Date
    public var context: NormalizedWorkspaceContext
    public var derived: DerivedWorkspaceState
    public var digest: WorkspaceDigest?
    public var freshness: ContextFreshness
    public var contextHash: String

    public init(
        workspaceId: UUID,
        version: Int,
        updatedAt: Date,
        context: NormalizedWorkspaceContext,
        derived: DerivedWorkspaceState,
        digest: WorkspaceDigest?,
        freshness: ContextFreshness,
        contextHash: String? = nil
    ) {
        self.workspaceId = workspaceId
        self.version = version
        self.updatedAt = updatedAt
        self.context = context
        self.derived = derived
        self.digest = digest
        self.freshness = freshness
        self.contextHash = contextHash ?? Self.semanticHash(
            context: context,
            derived: derived,
            digest: digest
        )
    }

    public func mergingProviderOutput(_ overlay: WorkspaceSnapshot) -> WorkspaceSnapshot {
        guard workspaceId == overlay.workspaceId else {
            return self
        }
        let selected = if overlay.updatedAt > updatedAt {
            overlay
        } else if overlay.updatedAt == updatedAt, overlay.version >= version {
            overlay
        } else {
            self
        }
        return WorkspaceSnapshot(
            workspaceId: workspaceId,
            version: max(version, overlay.version),
            updatedAt: max(updatedAt, overlay.updatedAt),
            context: selected.context,
            derived: selected.derived,
            digest: selected.digest ?? digest,
            freshness: freshness.merging(overlay.freshness)
        )
    }

    private static func semanticHash(
        context: NormalizedWorkspaceContext,
        derived: DerivedWorkspaceState,
        digest: WorkspaceDigest?
    ) -> String {
        let payload = SnapshotSemanticPayload(
            context: context,
            derived: derived,
            digestSummary: digest?.summary
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        return "fnv1a64:\(String(format: "%016llx", fnv1a64(data)))"
    }

    private static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    private struct SnapshotSemanticPayload: Codable {
        let context: NormalizedWorkspaceContext
        let derived: DerivedWorkspaceState
        let digestSummary: String?
    }
}

public struct RankingSnapshot: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var workspaceId: UUID
        public var rank: Int
        public var score: Double?
        public var reason: String?

        public init(
            workspaceId: UUID,
            rank: Int,
            score: Double?,
            reason: String?
        ) {
            self.workspaceId = workspaceId
            self.rank = rank
            self.score = score
            self.reason = reason
        }
    }

    public var id: UUID
    public var updatedAt: Date
    public var items: [Item]

    public init(id: UUID, updatedAt: Date, items: [Item]) {
        self.id = id
        self.updatedAt = updatedAt
        self.items = items
    }
}

public struct ProactiveSuggestion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var workspaceId: UUID
    public var type: String
    public var title: String
    public var reason: String?
    public var confidence: Double
    public var createdAt: Date

    public init(
        id: UUID,
        workspaceId: UUID,
        type: String,
        title: String,
        reason: String?,
        confidence: Double,
        createdAt: Date
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.type = type
        self.title = title
        self.reason = reason
        self.confidence = confidence
        self.createdAt = createdAt
    }
}

public struct AssistantWorkingContext: Codable, Equatable, Sendable {
    public var activeWorkspaceId: UUID?
    public var snapshots: [WorkspaceSnapshot]
    public var freshness: ContextFreshness
    public var activeSuggestions: [ProactiveSuggestion]
    public var latestRanking: RankingSnapshot?

    public init(
        activeWorkspaceId: UUID?,
        snapshots: [WorkspaceSnapshot],
        freshness: ContextFreshness,
        activeSuggestions: [ProactiveSuggestion],
        latestRanking: RankingSnapshot?
    ) {
        self.activeWorkspaceId = activeWorkspaceId
        self.snapshots = snapshots
        self.freshness = freshness
        self.activeSuggestions = activeSuggestions
        self.latestRanking = latestRanking
    }
}

public protocol AssistantContextReadable: Sendable {
    func assistantWorkingContext() async -> AssistantWorkingContext
    func workspaceSnapshot(_ id: UUID) async -> WorkspaceSnapshot?
    func activeSuggestions() async -> [ProactiveSuggestion]
    func latestRanking() async -> RankingSnapshot?
}
