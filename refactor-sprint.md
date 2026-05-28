我看了 `plus` 分支的公开代码。下面是静态架构评估，我没有本地编译或跑 UI，所以结论主要基于目录、关键 Swift 文件和 SpriteAssistant 主链路阅读。

我的结论是：**基础设施已经有了，问题集中在 SpriteAssistant 巨型文件和“助手仍承担上下文收集决策”这两点。** 现在最适合做渐进式切分，先改调用方向，再拆包。

## 当前架构里值得保留的基础

cmux 本体确实适合走 Swift 原生服务化路线。README 里明确它是 Swift/AppKit 的 native macOS app，并且已有 CLI/socket API、sidebar、linked PR status、agent notification 等基础能力。([GitHub][1])

你已经有几块可以复用为新架构地基的东西：

第一，`Sources` 目录已经有 `CMUXEnhancementSystem.swift`、`CMUXPluginSystem.swift`、`CmuxActionTrust.swift`、`CmuxEventBus.swift`、`CmuxEventPublishing.swift`、`CmuxEventStream.swift` 这些基础设施文件。说明你无需从零搭 event bus / plugin / action trust。([GitHub][2])

第二，`CmuxActionTrust` 已经有 action descriptor、fingerprint、`trusted-actions.json` 这套机制。它可以直接升级成 `SemanticActionGateway` 的信任与审计底座。([GitHub][3])

第三，`CMUXEnhancementSystem` 里已经有 GitHub PR refresh interceptor 和 `CMUXGitHubEnhancementService.queueRefreshIfNeeded`，这说明“外部状态刷新”已经有 queue / debounce 的雏形。它很适合迁移进 ContextAgent 的 provider scheduler。([GitHub][4])

第四，SpriteAssistant 已经有 semantic router、MCP tool discovery、local LLM / Claude fallback、route catalog、allowed tools、mutating tool 标记。这套东西不用推翻，应该把它收敛成 assistant runtime 的一部分。`SortAssistantIntentRouter` 已经支持 local LLM、Claude Code fallback、confidence floor、routeAdjustment 等能力。

## 主要问题一：SpriteAssistant 的职责过度集中

`Sources/SpriteAssistant` 目录只有 4 个文件，核心能力几乎都挤在 `SortAssistantFeature.swift` 里。([GitHub][5]) 这个文件本身有 12,759 行、504 KB。([GitHub][6])

我看到它同时包含这些职责：

```txt
SwiftUI thread view
completion UI
memory card / memory row
intent router
semantic router
MCP server discovery
Claude Code process runner
MCP config writer / launcher
prompt fragments
MCP result parser
action router
sort context / operator / coordinator
workspace mention / completion logic
```

这不是单纯“文件太大”的问题。它会直接影响你接下来要做的主动上下文系统，因为 ContextAgent、assistant、ranking、semantic review 的边界会被这个文件自然拉回到一起。

第一阶段最值得做的改动不是重写逻辑，而是**无行为变化拆文件**。建议先拆成这些文件：

```txt
Sources/SpriteAssistant/
  Contracts/
    SortAssistantModels.swift
    SortAssistantRouteModels.swift
    SortAssistantResultModels.swift

  UI/
    SortAssistantThreadView.swift
    SortAssistantCompletionView.swift
    SortAssistantMemoryViews.swift
    SortAssistantInputTextField.swift

  Router/
    SortAssistantIntentRouter.swift
    SortAssistantActionRouter.swift
    SortAssistantSemanticPrompt.swift

  MCP/
    SortAssistantMCPClient.swift
    SortAssistantMCPDiscovery.swift
    SortAssistantMCPConfigWriter.swift
    SortAssistantMCPResultParser.swift
    SortAssistantClaudeCodeRuntime.swift

  Sorting/
    SortContextProvider.swift
    SortOperator.swift
    SortEngineAdapter.swift

  Memory/
    SortAssistantMemoryStore.swift
    SortAssistantMemoryCandidate.swift

  Coordinator/
    SortAssistantCoordinator.swift
```

这一步先不引入 ContextAgent，也不改 semantic 行为。目标是降低后续 diff 风险。

## 主要问题二：助手现在仍在主动拉上下文

你前面明确说“由单独 agent 主动更新上下文，而不是由助手主动调用更新”。但当前 plus 分支里，assistant 仍然有多条路径会让 Claude / MCP 执行阶段去收集上下文。

证据很明显。`sortAssistantKnownInternalTools` 里包含 `context_collect`、`repository_context`、`github_context`、`github_pr_context`、`ghpr_context`、`ghpr_status`、`ghpr_refresh`、`workspace_digest_get`、`workspace_digest_progress`、`workspace_digest_refresh` 等工具。

`SortAssistantActionRouter` 的 context read tools 也包含 `context_collect`、`repository_context`、`github_context`、`github_pr_context`、`ghpr_context`、`ghpr_status`、`workspace_digest_get`、`workspace_digest_progress`。也就是说，ask context / sort / explain 等路径都会把“上下文收集工具”暴露给 assistant 执行链路。

更关键的是，`promptFragment("context")` 直接要求模型 “Gather relevant context before answering”，并指示使用 `context_collect`、`repository_context`、`ghpr_context`、`github_pr_context`、`github_context`、`workspace_digest_get`。这和你想要的“ContextAgent 主动维护上下文，assistant 只消费 snapshot”方向冲突。

建议调整成：

```txt
旧方向:
Assistant / Claude
  -> context_collect
  -> repository_context
  -> ghpr_context
  -> workspace_digest_refresh
  -> answer / mutate

新方向:
ContextAgent
  -> collect providers
  -> write WorkspaceSnapshot / Digest / Freshness

Assistant / Claude
  -> read snapshot_get
  -> read workspace_digest_get
  -> read context_freshness_get
  -> submit ActionIntent
```

你可以保留 MCP，但要换工具语义：

```txt
保留:
workspace_snapshot_get
workspace_digest_get
context_freshness_get
ranking_latest_get
suggestions_active_get
list_state

移出 assistant 默认 allowed tools:
context_collect
repository_context
ghpr_refresh
workspace_digest_refresh
github_pr_context 作为 refresh 型工具时也应移出

仅 dev/debug 暴露:
context_agent_force_refresh
provider_run_debug
digest_rebuild_debug
```

`workspace_digest_get` 可以继续存在，因为它是 read snapshot。`workspace_digest_refresh` 应该只给 ContextAgent 或 debug panel 使用。

## 主要问题三：semantic router 已经很强，但还不是 action gateway

你现在的 semantic router 做得比较完整。它会根据 intent 输出 route、steps、routeAdjustment，并用 allowed tools 控制 Claude 执行阶段。

但它目前更像：

```txt
semantic routing + tool affordance gating
```

还没有变成：

```txt
system-side semantic action review + freshness check + audit + execution gate
```

比如 `applySort` route 是 `.applyAllowed`，`needsConfirmation: false`，并允许 `sort_apply`、`sort_undo` 等工具。`workspaceColor` 也是 `.applyAllowed` 且无需确认。 这在 UX 上合理，但系统层还需要一个执行前网关，不能只靠 prompt、route、allowed tools。

建议新增：

```swift
public actor SemanticActionGateway {
    private let reviewers: [any ActionReviewer]
    private let executor: any CmuxActionExecutor
    private let auditLog: any ActionAuditLog

    public func submit(_ intent: ActionIntent) async throws -> SemanticReviewResult {
        let context = try await makeReviewContext(intent)
        let signals = await reviewers.asyncFlatMap { reviewer in
            await reviewer.review(intent, context: context)
        }

        let decision = SemanticReviewResult.merge(signals, intent: intent)
        await auditLog.record(intent: intent, decision: decision)

        if decision.decision == .allow {
            try await executor.execute(decision.normalizedAction)
            await auditLog.recordExecuted(intent.id)
        }

        return decision
    }
}
```

现有 `SortAssistantActionRouter` 继续负责“这个请求能看到哪些工具”。新增 `SemanticActionGateway` 负责“这个动作现在能不能执行”。

两者关系应该是：

```txt
SortAssistantIntentRouter
  -> 判断用户意图

SortAssistantActionRouter
  -> 给 assistant 当前 turn 的工具视野

Assistant / Claude
  -> 产出 ActionIntent 或调用 accept_suggestion / apply_sort wrapper

SemanticActionGateway
  -> schema validation
  -> target resolution
  -> freshness check
  -> semantic consistency check
  -> policy decision
  -> audit
  -> execute
```

现有的 `CmuxActionTrustDescriptor` 已经能表达 action kind、command、target、projectRoot、fingerprint，很适合接入 Gateway 的 trust 层。([GitHub][3])

## 主要问题四：`requiresScopeRefresh` 容易和 context freshness 混淆

`SortAssistantMCPRequest` 里有 `visibleScopeSignature` 和 `requiresScopeRefresh`，`SortAssistantMCPClient.perform` 在需要时会先 `refreshSemanticRouterScope`，再写 expanded MCP config 并启动 Claude Code。

这套机制更像：

```txt
刷新 Claude 当前会话可见的 semantic router scope / route bundle
```

它不是 workspace context freshness。后面引入 ContextAgent 后，建议在命名上明确区分：

```txt
MCP scope freshness:
  visibleScopeSignature
  requiresScopeRefresh
  semanticRouterScopeRefresh

Workspace context freshness:
  WorkspaceSnapshot.version
  ProviderFreshness.lastCollectedAt
  ProviderFreshness.ttl
  ContextFreshness.overallConfidence
```

避免以后出现这种误判：

```txt
MCP scope 是 fresh
所以 workspace git / PR / screen context 也 fresh
```

这两个 freshness 应该完全独立。

## 建议的目标架构，贴合当前 Swift 代码

不要一开始拆 helper process。先在同一个 app 进程里用 actor 和 protocol 固定边界。

```txt
SwiftUI / AppKit UI
  -> user events

CmuxCore
  -> workspace / pane / session / action execution
  -> publish fact events

CmuxEventBus
  -> workspace focused
  -> agent message appended
  -> git changed
  -> PR refresh requested
  -> assistant query started

ContextAgent actor
  -> listens to events
  -> schedules providers
  -> writes WorkspaceSnapshot

SnapshotStore actor
  -> latest snapshots
  -> digests
  -> freshness
  -> provider run metadata

Orchestration
  -> ranking
  -> suggestions
  -> next workspace

AssistantRuntime
  -> reads AssistantContextReadable
  -> routes user intent
  -> submits ActionIntent

SemanticActionGateway
  -> reviews
  -> audits
  -> executes through CmuxCore
```

关键编译期边界：

```swift
public protocol AssistantContextReadable: Sendable {
    func assistantWorkingContext() async -> AssistantWorkingContext
    func workspaceSnapshot(_ id: UUID) async -> WorkspaceSnapshot?
    func activeSuggestions() async -> [ProactiveSuggestion]
    func latestRanking() async -> RankingSnapshot?
}

public final class AssistantRuntime {
    private let contextReader: any AssistantContextReadable
    private let actionGateway: SemanticActionGateway

    public init(
        contextReader: any AssistantContextReadable,
        actionGateway: SemanticActionGateway
    ) {
        self.contextReader = contextReader
        self.actionGateway = actionGateway
    }
}
```

Assistant target 不再 import provider / scheduler：

```txt
Assistant 可以依赖:
SnapshotReader
SuggestionReader
RankingReader
SemanticActionGateway

Assistant 不直接依赖:
GitProvider
RepositoryContextProvider
GitHubPRProvider
WorkspaceDigestUpdater
ContextScheduler
ContextAgent
```

## ContextAgent 该怎么接现有代码

你已经有 EventBus 和 EnhancementSystem，所以 ContextAgent 可以先作为 “materializer” 接入。

```swift
public actor ContextAgent {
    private let eventBus: CmuxEventBus
    private let scheduler: ContextScheduler
    private let snapshotStore: WorkspaceSnapshotStore
    private let providers: [any AnyWorkspaceContextProvider]

    public func start() async {
        for await event in eventBus.events(matching: .contextRelevant) {
            await handle(event)
        }
    }

    public func handle(_ event: CmuxEventEnvelope) async {
        let affected = resolveAffectedWorkspaces(event)

        for workspaceId in affected {
            await scheduler.enqueue(
                ContextRefreshJob(
                    workspaceId: workspaceId,
                    reason: event.name,
                    priority: priority(for: event)
                )
            )
        }
    }

    public func runScheduledBatch() async {
        let jobs = await scheduler.nextBatch()
        await withTaskGroup(of: Void.self) { group in
            for job in jobs {
                group.addTask {
                    await self.updateWorkspace(job)
                }
            }
        }
    }

    private func updateWorkspace(_ job: ContextRefreshJob) async {
        let providerResults = await collectProviders(job)
        let normalized = normalize(providerResults)
        let derived = deriveWorkspaceState(normalized)
        let digest = await maybeUpdateDigest(
            workspaceId: job.workspaceId,
            context: normalized,
            derived: derived
        )

        await snapshotStore.write(
            WorkspaceSnapshot(
                workspaceId: job.workspaceId,
                context: normalized,
                derived: derived,
                digest: digest,
                freshness: computeFreshness(providerResults)
            )
        )
    }
}
```

第一批 provider 先复用现有代码，不重写：

```txt
workspace_meta_provider
  读 TabManager / WorkspaceTabStore 的稳定状态

agent_session_provider
  读 agent session / notification / terminal state

git_provider
  读现有 branch / currentDirectory / git 信息

github_provider
  复用 EnhancementSystem 里已有 PR refresh queue 的结果

digest_provider
  先包现有 workspace_digest_get 的底层实现
```

后面再把 GitHub refresh 从 EnhancementSystem 内部迁移到 ContextAgent provider scheduler。当前 `CMUXGitHubEnhancementService` 已经有 queued refresh map 和 debounce 逻辑，可以作为迁移起点。([GitHub][4])

## Snapshot 类型先做最小版

第一版不要追求完整，只要让 assistant 不再拉 raw context。

```swift
public struct WorkspaceSnapshot: Codable, Sendable {
    public var workspaceId: UUID
    public var version: Int
    public var updatedAt: Date

    public var context: NormalizedWorkspaceContext
    public var derived: DerivedWorkspaceState
    public var digest: WorkspaceDigest?
    public var freshness: ContextFreshness

    public var contextHash: String
}

public struct ContextFreshness: Codable, Sendable {
    public var providers: [ProviderFreshness]
    public var overallConfidence: Double
}

public struct ProviderFreshness: Codable, Sendable {
    public var providerId: String
    public var lastCollectedAt: Date?
    public var ttlSeconds: TimeInterval
    public var stale: Bool
    public var error: String?
    public var confidence: Double
}
```

然后 MCP 暴露读接口：

```txt
cmux_sprite.workspace_snapshot_get
cmux_sprite.workspace_digest_get
cmux_sprite.context_freshness_get
cmux_sprite.assistant_working_context_get
cmux_sprite.suggestions_active_get
cmux_sprite.ranking_latest_get
```

把 prompt 改成：

```txt
Use snapshot tools first. Do not collect or refresh context. If freshness is stale, say which provider is stale and answer with that limitation.
```

## ActionIntent 接现有 mutating tools

当前 mutating 工具有 `sort_apply`、`sort_undo`、`workspace_color_set`、`workspace_color_clear`、`memory_write_candidate`、`sprite_memory_write`、`list_lock`、`list_pin` 等。

这些可以保留 MCP 名称，但内部实现改成：

```txt
MCP tool
  -> build ActionIntent
  -> SemanticActionGateway.submit
  -> executor
  -> result
```

示例：

```swift
public enum CmuxActionKind: String, Codable, Sendable {
    case switchWorkspace
    case applySort
    case undoSort
    case setWorkspaceColor
    case clearWorkspaceColor
    case pinWorkspace
    case lockList
    case writeMemory
    case forgetMemory
}

public struct ActionIntent: Codable, Sendable {
    public var id: UUID
    public var requestedBy: ActionRequester
    public var kind: CmuxActionKind
    public var arguments: ActionArguments
    public var reason: String?
    public var evidence: ActionEvidence
    public var createdAt: Date
}

public struct ActionEvidence: Codable, Sendable {
    public var snapshotVersions: [UUID: Int]
    public var suggestionId: UUID?
    public var rankingSnapshotId: UUID?
}
```

第一版 review 规则可以很简单：

```txt
sort_apply:
  workspace IDs exist
  no duplicates
  respects pinned/locked constraints
  snapshot age under 2 minutes, or require confirmation
  assistant route includes applySort
  audit always

workspace_color_set / clear:
  workspace exists
  color value valid
  route includes workspaceColor
  audit always

memory writes:
  if long-term memory, require confirmation unless explicit user wording
  audit always

sort_undo:
  previous assistant sort exists
  patch id matches current sort history
  audit always
```

这样你保留“助手有简单操作接口”，同时把最终执行权放回 Swift 系统层。

## 具体迁移顺序

我建议按这 6 个 PR 做，风险最低。

### PR 1：拆 `SortAssistantFeature.swift`，零行为变化

只移动代码，不改逻辑。目标是让 review 变容易。

拆完后应该能看出：

```txt
UI 层
Router 层
MCP 层
Sorting 层
Memory 层
Coordinator 层
```

这一步会立刻降低后续改动成本。

### PR 2：加 `WorkspaceSnapshotStore` 和 `AssistantContextReadable`

先用 adapter 从现有 `SortContextProvider`、`WorkspaceTabStore`、GitHub sidebar metadata、workspace digest 构造 snapshot。

这一阶段仍然允许旧工具存在，但 assistant prompt 先开始优先读 snapshot。

### PR 3：引入 `ContextAgent` actor

ContextAgent 先在进程内跑，监听现有事件和 UI attention event：

```txt
workspace_focused
workspace_visible
assistant_query_started
agent_message_appended
git_changed
github_pr_refresh_requested
```

它写 snapshot store。assistant 不再主动 refresh。

### PR 4：替换 assistant 的上下文工具

从 production route 里移除：

```txt
context_collect
repository_context
ghpr_refresh
workspace_digest_refresh
```

保留 dev/debug 入口。把 `promptFragment("context")` 改成读 snapshot / digest / freshness。

### PR 5：引入 `SemanticActionGateway`

先 wrap 这些工具：

```txt
sort_apply
sort_undo
workspace_color_set
workspace_color_clear
memory_write_candidate
sprite_memory_write
list_lock
list_pin
```

`SortAssistantActionRouter` 继续控制 allowed tools，Gateway 做系统侧审核。

### PR 6：把 ContextAgent / Orchestration 从 app core 中抽 target

等接口稳定后，再拆 Swift Package targets：

```txt
CmuxContracts
CmuxContextAgent
CmuxOrchestration
CmuxAssistant
CmuxActions
```

不要在 PR 1 就强拆 SPM target。Swift 项目里 target 边界会带来 access control、resource、build setting、preview、test dependency 的额外成本。

## 我会优先修改的几处代码

第一处，`SortAssistantActionRouter.contextReadTools`。

现在它允许 assistant 读和收集混在一起。建议变成：

```swift
private static let contextReadTools = [
    "assistant_working_context_get",
    "workspace_snapshot_get",
    "workspace_digest_get",
    "context_freshness_get",
    "ranking_latest_get",
    "suggestions_active_get",
    "list_state"
]
```

`context_collect`、`repository_context`、`ghpr_refresh`、`workspace_digest_refresh` 从 production routes 移出。

第二处，`promptFragment("context")`。

现在它要求模型主动 gather context。建议改成：

```txt
context:
Read assistant_working_context_get first.
Use workspace_snapshot_get or workspace_digest_get for specific workspaces.
Use context_freshness_get to report staleness.
Do not refresh or collect context. Context is maintained by cmux ContextAgent.
If required data is stale or missing, say which provider is stale or missing.
```

第三处，`SortAssistantMCPRequest.requiresScopeRefresh`。

保留它，但改名或加注释：

```swift
let requiresMCPScopeRefresh: Bool
```

避免和 ContextAgent freshness 混用。

第四处，mutating MCP tools 的实现。

把实际执行替换成：

```swift
let intent = ActionIntent(...)
let review = try await semanticActionGateway.submit(intent)
return encodeReviewResult(review)
```

第五处，`CmuxActionTrust`。

不要另起一套 trust store。扩展现有 descriptor：

```swift
struct CmuxActionTrustDescriptor {
    var schemaVersion: Int = 2
    var actionID: String
    var kind: String
    var command: String?
    var target: String?
    var workspaceId: String?
    var assistantRoute: String?
    var normalizedArgumentsHash: String?
    var contextSnapshotHash: String?
}
```

## 最终目标状态

你要的主动助手，落到当前 plus 分支上，我建议定义成：

```txt
ContextAgent 主动更新世界模型
Orchestration 主动生成 ranking / suggestions
Assistant 只读 snapshot 并解释
SemanticActionGateway 审核所有 mutation
Core 只执行审核通过的 action
```

当前代码已经有 MCP、semantic router、event bus、enhancement queue、action trust。真正要改的是责任方向：

```txt
当前:
Assistant decides when to gather context
Assistant receives tools that can refresh / collect
Assistant executes allowed mutating tools after semantic route

建议:
ContextAgent decides when to gather context
Assistant receives snapshot read tools
Assistant submits ActionIntent
SemanticActionGateway reviews and executes
```

这样你能保留现有 SpriteAssistant 的交互能力，同时把上下文更新频率、刷新预算、semantic 审核和 action 执行都放到 Swift 系统层。

[1]: https://github.com/xiaocang/cmux/tree/plus "GitHub - xiaocang/cmux: Ghostty-based macOS terminal with vertical tabs and notifications for AI coding agents · GitHub"
[2]: https://github.com/xiaocang/cmux/tree/plus/Sources "cmux/Sources at plus · xiaocang/cmux · GitHub"
[3]: https://github.com/xiaocang/cmux/blob/plus/Sources/CmuxActionTrust.swift "cmux/Sources/CmuxActionTrust.swift at plus · xiaocang/cmux · GitHub"
[4]: https://github.com/xiaocang/cmux/blob/plus/Sources/CMUXEnhancementSystem.swift "cmux/Sources/CMUXEnhancementSystem.swift at plus · xiaocang/cmux · GitHub"
[5]: https://github.com/xiaocang/cmux/tree/plus/Sources/SpriteAssistant "cmux/Sources/SpriteAssistant at plus · xiaocang/cmux · GitHub"
[6]: https://github.com/xiaocang/cmux/blob/plus/Sources/SpriteAssistant/SortAssistantFeature.swift "cmux/Sources/SpriteAssistant/SortAssistantFeature.swift at plus · xiaocang/cmux · GitHub"

