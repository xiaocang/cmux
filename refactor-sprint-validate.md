下面把规划扩展成一个 **可验证、可回归、可持续迁移** 的路线。重点是：每个 milestone 都要有清晰的完成标准、架构边界检查、单元测试、集成测试、图形化 UI 回归，以及失败时能定位到哪一层出了问题。

我会按你当前 `plus` 分支的实际情况来设计：仓库根目录已经有 `GhosttyTabs.xcodeproj`、`cmuxTests`、`cmuxUITests`，说明可以直接沿用 Xcode XCTest / XCUITest 的测试体系推进。([GitHub][1]) 项目文件里也已经注册了大量 Swift 测试源文件，包括 `CmuxEventBusTests.swift`、`CMUXPluginSystemTests.swift`、`CMUXEnhancementSystemTests.swift`、`WorkspaceActionDispatcherTests.swift` 等，这对后续把 ContextAgent、ActionGateway、Assistant 分层纳入测试非常有利。

---

# 总体测试策略

## 1. 测试分层

建议把测试分为 7 层：

```txt
L0 Static architecture checks
  检查依赖方向、禁用 import、禁用 assistant 调 refresh

L1 Pure unit tests
  Contracts / scheduler / ranking / semantic review / freshness

L2 Actor integration tests
  ContextAgent + EventBus + SnapshotStore + fake providers

L3 Replay tests
  输入一段固定 event log，验证最终 snapshot / suggestions / ranking

L4 Assistant tool contract tests
  验证 assistant 只能读 snapshot，mutation 必须走 ActionIntent

L5 XCUITest functional tests
  启动真实 app，点击/输入/切 workspace，验证 UI 状态

L6 Visual regression tests
  对关键 UI 截图或组件快照，比较 baseline image / text snapshot
```

Apple 的 UI testing 本身就是通过 XCTest 和 Accessibility 找到并操作 app UI 元素，然后验证 UI 元素的属性和状态；UI test 代码运行在独立进程里，像用户一样驱动 app。这个特性很适合你这种“workspace 切换、assistant panel、sort preview、suggestion badge”的端到端验证。([Apple Developer][2])

## 2. 测试模式必须先做

图形化自动测试要稳定，cmux app 必须有一个 deterministic test mode。

建议所有 UI 测试都这样启动：

```swift
let app = XCUIApplication()
app.launchArguments = [
    "--cmux-ui-test",
    "--fixture", "assistant-context-agent-basic",
    "--disable-network",
    "--disable-sparkle",
    "--disable-real-llm",
    "--disable-auto-update",
    "--fixed-now", "2026-05-23T10:00:00Z"
]
app.launchEnvironment = [
    "CMUX_TEST_MODE": "1",
    "CMUX_FAKE_CONTEXT_AGENT": "1",
    "CMUX_FAKE_ASSISTANT": "1",
    "CMUX_DISABLE_ANIMATIONS": "1"
]
app.launch()
```

对应 app 内部：

```swift
struct CmuxRuntimeMode {
    let isUITest: Bool
    let fixtureName: String?
    let disableNetwork: Bool
    let disableRealLLM: Bool
    let fixedNow: Date?
}
```

图形化回归最怕随机性，所以必须固定：

```txt
时间
workspace id
workspace 顺序
窗口尺寸
动画
LLM 输出
网络响应
provider 返回值
字体 / appearance
```

## 3. UI 元素必须加 accessibilityIdentifier

XCUITest 依赖 Accessibility 语义数据。Apple 文档也强调 UI testing rests on XCTest and Accessibility。([Apple Developer][2])

因此关键 UI 都要加 identifier：

```swift
.assistantPanel
.assistantInput
.assistantSendButton
.assistantMessageList
.workspaceSidebar
.workspaceRow(workspaceId)
.workspaceSuggestionBadge(workspaceId)
.workspaceFreshnessIndicator(workspaceId)
.sortPreviewList
.sortApplyButton
.semanticReviewBanner
.contextAgentStatusIndicator
```

SwiftUI 示例：

```swift
Text(workspace.title)
    .accessibilityIdentifier("workspace-row-\(workspace.id.rawValue)")

Button("Apply Sort") {
    viewModel.applySort()
}
.accessibilityIdentifier("sort-apply-button")
```

AppKit 示例：

```swift
button.setAccessibilityIdentifier("sort-apply-button")
```

## 4. Visual regression 两条线并行

第一条是 **组件快照测试**。对 SwiftUI / AppKit view 做 image snapshot、text snapshot、JSON snapshot。Point-Free 的 `swift-snapshot-testing` 支持 `assertSnapshot`，能对 view controller 做 image snapshot，也能对 Encodable 数据结构做 JSON / plist / dump snapshot；失败时能产出 diff 和 XCTest attachments，且支持 macOS。([GitHub][3])

第二条是 **真实 app XCUITest 截图回归**。XCUITest 驱动 app 到某个状态，然后截图、附加到测试结果，并用你自己的 pixel diff 或 snapshot baseline 做比较。Apple UI tests 的 test reports 会包含 UI test failure 时的 UI 状态快照，这对定位图形回归很有帮助。([Apple Developer][2])

两者分工：

```txt
组件 snapshot:
  快
  稳定
  适合 assistant panel、workspace row、suggestion card、sort preview

真实 app screenshot:
  慢
  覆盖真实窗口和交互
  适合端到端 smoke、布局破坏、sidebar / panel / overlay 回归
```

---

# 推荐新增测试目录

基于现有结构，建议新增或整理成：

```txt
cmuxTests/
  Architecture/
    AssistantDependencyBoundaryTests.swift
    SourceImportBoundaryTests.swift

  Contracts/
    WorkspaceSnapshotCodableTests.swift
    ContextFreshnessTests.swift
    ActionIntentCodableTests.swift

  ContextAgent/
    ContextSchedulerTests.swift
    ContextAgentEventHandlingTests.swift
    ContextAgentFreshnessTests.swift
    ContextAgentReplayTests.swift

  Orchestration/
    RankingEngineTests.swift
    SuggestionEngineTests.swift
    NextWorkspaceTests.swift

  Assistant/
    AssistantContextReaderTests.swift
    AssistantToolCatalogTests.swift
    AssistantPromptPolicyTests.swift

  Actions/
    SemanticActionGatewayTests.swift
    ActionFreshnessReviewerTests.swift
    ActionAuditLogTests.swift

  Snapshots/
    AssistantPanelSnapshotTests.swift
    WorkspaceSidebarSnapshotTests.swift
    SuggestionCardSnapshotTests.swift
    SortPreviewSnapshotTests.swift

cmuxUITests/
  Harness/
    CmuxUITestCase.swift
    ScreenshotAssert.swift
    FixtureLauncher.swift

  Scenarios/
    AssistantReadsSnapshotUITests.swift
    ContextAgentSuggestionUITests.swift
    SortApplySemanticReviewUITests.swift
    VisualRegressionUITests.swift

TestsFixtures/
  ContextAgent/
    agent_waiting_user.eventlog.jsonl
    ci_failed.eventlog.jsonl
    ready_to_merge.eventlog.jsonl

  Snapshots/
    assistant_panel_waiting_user.png
    workspace_sidebar_ranked.png
    semantic_review_confirmation.png
```

---

# Milestone 0：测试基础设施和安全网

## 目标

先把“测试环境”建起来，再动架构。这个 milestone 不改产品行为。

## 代码改动

新增：

```txt
CmuxTestSupport
  DeterministicClock
  InMemoryEventBus
  InMemorySnapshotStore
  FakeContextProvider
  FakeAssistantLLM
  FixtureWorkspaceFactory
  FixtureLoader

cmuxUITests harness
  launch args parser
  fixed window size
  screenshot attachment helper
  UI fixture mode
```

新增 app 启动参数：

```txt
--cmux-ui-test
--fixture <name>
--disable-network
--disable-real-llm
--fixed-now <iso8601>
--reset-test-state
```

## 验证标准

```txt
xcodebuild test 能跑 cmuxTests
xcodebuild test 能跑 cmuxUITests
UI test 能启动 app
UI test 能加载一个固定 workspace fixture
UI test 能截图并作为 artifact 保存
```

## 自动测试

### Unit

```swift
final class FixtureLoaderTests: XCTestCase {
    func testLoadsWorkspaceFixtureDeterministically() throws {
        let fixture = try FixtureLoader.load("three-workspaces-basic")
        XCTAssertEqual(fixture.workspaces.count, 3)
        XCTAssertEqual(fixture.workspaces.map(\.title), [
            "API fix",
            "CI failure",
            "Refactor agent"
        ])
    }
}
```

### UI smoke

```swift
final class CmuxLaunchFixtureUITests: XCTestCase {
    func testLaunchesWithThreeWorkspaceFixture() {
        let app = CmuxFixtureLauncher.launch(fixture: "three-workspaces-basic")

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["workspace-row-api-fix"].exists)
        XCTAssertTrue(app.staticTexts["workspace-row-ci-failure"].exists)
        XCTAssertTrue(app.staticTexts["workspace-row-refactor-agent"].exists)
    }
}
```

### 图形化回归

先只做 smoke screenshot，不做 pixel diff：

```swift
let screenshot = XCUIScreen.main.screenshot()
let attachment = XCTAttachment(screenshot: screenshot)
attachment.name = "launch-three-workspaces"
attachment.lifetime = .keepAlways
add(attachment)
```

## 完成门槛

```txt
CI / 本地命令稳定通过 10 次
UI smoke failure 时能拿到 screenshot
所有 fixture 均不访问网络、不调用真实 LLM
```

---

# Milestone 1：无行为变化拆分 SortAssistantFeature

## 目标

把 `SortAssistantFeature.swift` 的职责拆开，但不改变行为。当前 plus 分支里 `SortAssistantFeature.swift` 已在 Xcode project 里作为 source 注册。 第一阶段先“切文件”，不要“改架构”。

## 拆分目标

```txt
SortAssistantFeature.swift
  降到 500 到 1000 行以内，只保留 feature composition

SortAssistantModels.swift
SortAssistantThreadView.swift
SortAssistantIntentRouter.swift
SortAssistantActionRouter.swift
SortAssistantMCPClient.swift
SortAssistantMCPResultParser.swift
SortAssistantPromptFragments.swift
SortAssistantCoordinator.swift
SortAssistantMemoryStore.swift
SortAssistantSortOperator.swift
```

## 验证标准

```txt
所有旧测试通过
assistant UI 截图无变化
router 对同一输入输出相同 route
tool catalog 对同一 route 输出相同 allowed tools
prompt fragment 输出 byte-for-byte 或 normalized 相同
```

## 自动测试

### Router golden tests

```swift
func testRouteCatalogIsStableAfterFileSplit() async throws {
    let router = SortAssistantIntentRouter.fakeDeterministic()

    let cases: [(String, SortAssistantRoute)] = [
        ("把等待我的 workspace 排前面", .sort),
        ("为什么这个 workspace 排第一", .explain),
        ("给这个 workspace 标红", .workspaceColor),
        ("记住我偏好先处理 CI failed", .memory)
    ]

    for (input, expected) in cases {
        let result = await router.route(input)
        XCTAssertEqual(result.route, expected)
    }
}
```

### Tool catalog snapshot

```swift
func testAllowedToolsSnapshot() {
    let catalog = SortAssistantActionRouter.allowedTools(for: .applySort)
    assertSnapshot(of: catalog.sorted(), as: .json)
}
```

### UI snapshot

组件级 snapshot：

```swift
@MainActor
func testAssistantThreadEmptyStateSnapshot() {
    let view = SortAssistantThreadView.previewFixture(.empty)
    assertSnapshot(of: view, as: .image(layout: .fixed(width: 420, height: 720)))
}
```

## 图形回归场景

```txt
assistant panel empty
assistant panel with one answer
assistant panel with tool result
assistant completion menu open
memory card visible
sort preview visible
```

## 完成门槛

```txt
SortAssistantFeature 拆分后功能截图和 baseline 一致
Router golden tests 全部通过
Tool catalog snapshot 全部通过
无新增 assistant -> provider 依赖
```

---

# Milestone 2：引入 Contracts 和 WorkspaceSnapshot

## 目标

先建立稳定数据契约，让 Assistant / Ranking / Suggestion 都能围绕 snapshot 工作。

## 新增类型

```swift
public struct WorkspaceSnapshot: Codable, Sendable, Equatable {
    public let workspaceId: WorkspaceID
    public let version: Int
    public let updatedAt: Date
    public let context: NormalizedWorkspaceContext
    public let derived: DerivedWorkspaceState
    public let digest: WorkspaceDigest?
    public let freshness: ContextFreshness
    public let contextHash: String
}

public struct ContextFreshness: Codable, Sendable, Equatable {
    public let providers: [ProviderFreshness]
    public let overallConfidence: Double
}

public struct ProviderFreshness: Codable, Sendable, Equatable {
    public let providerId: String
    public let lastCollectedAt: Date?
    public let ttlSeconds: TimeInterval
    public let stale: Bool
    public let error: String?
    public let confidence: Double
}
```

## 验证标准

```txt
Snapshot Codable 稳定
Context hash 对语义字段变化敏感
Context hash 对无关字段变化不敏感
Freshness stale 判定稳定
Assistant 可以通过 Reader 读取 snapshot
```

## 自动测试

### Codable golden

```swift
func testWorkspaceSnapshotCodableGolden() throws {
    let snapshot = WorkspaceSnapshot.fixture(.agentWaitingUser)
    let data = try JSONEncoder.cmuxStable.encode(snapshot)
    assertSnapshot(of: String(decoding: data, as: UTF8.self), as: .lines)
}
```

### Hash semantics

```swift
func testContextHashIgnoresUpdatedAt() {
    var a = WorkspaceSnapshot.fixture(.ciFailed)
    var b = a
    b.updatedAt = a.updatedAt.addingTimeInterval(30)

    XCTAssertEqual(a.contextHash, b.contextHash)
}

func testContextHashChangesWhenDerivedStateChanges() {
    let a = WorkspaceSnapshot.fixture(.runningAgent)
    let b = WorkspaceSnapshot.fixture(.waitingUser)

    XCTAssertNotEqual(a.contextHash, b.contextHash)
}
```

### Freshness

```swift
func testProviderFreshnessMarksStaleAfterTTL() {
    let now = Date(timeIntervalSince1970: 1000)
    let provider = ProviderFreshness(
        providerId: "agent_session",
        lastCollectedAt: now.addingTimeInterval(-61),
        ttlSeconds: 60,
        stale: false,
        error: nil,
        confidence: 1.0
    )

    XCTAssertTrue(provider.evaluated(at: now).stale)
}
```

## 图形回归

新增 `workspace freshness indicator` 组件 snapshot：

```txt
fresh: green dot / normal text
stale: yellow dot / stale label
error: red dot / error tooltip
missing: gray dot
```

## 完成门槛

```txt
Contracts target 没有依赖 UI、Assistant、Provider
Snapshot JSON baseline review 通过
Freshness UI snapshot 稳定
```

---

# Milestone 3：AssistantContextReadable，助手改为只读 snapshot

## 目标

先改读取路径，不急着删除旧工具。Assistant 内部改成只依赖：

```swift
protocol AssistantContextReadable
```

## 新接口

```swift
public protocol AssistantContextReadable: Sendable {
    func assistantWorkingContext() async -> AssistantWorkingContext
    func workspaceSnapshot(_ id: WorkspaceID) async -> WorkspaceSnapshot?
    func activeSuggestions() async -> [ProactiveSuggestion]
    func latestRanking() async -> RankingSnapshot?
}
```

## 验证标准

```txt
AssistantRuntime 不直接持有 ContextAgent
AssistantRuntime 不直接持有 GitProvider / PRProvider / DigestUpdater
assistant answer 使用 snapshot / digest / freshness
当 freshness stale 时，回答要显式提示
```

## 自动测试

### Dependency boundary test

可以写一个简单源码扫描测试。它不优雅，但很实用。

```swift
final class AssistantDependencyBoundaryTests: XCTestCase {
    func testAssistantDoesNotImportContextProviders() throws {
        let assistantFiles = try SourceScanner.files(under: "Sources/SpriteAssistant")

        let banned = [
            "GitProvider",
            "GitHubPRProvider",
            "ContextScheduler",
            "ContextAgent",
            "WorkspaceDigestUpdater",
            "context_collect",
            "workspace_digest_refresh"
        ]

        for file in assistantFiles {
            let text = try String(contentsOf: file)
            for symbol in banned {
                XCTAssertFalse(
                    text.contains(symbol),
                    "\(file.lastPathComponent) must not reference \(symbol)"
                )
            }
        }
    }
}
```

### Assistant stale context test

```swift
func testAssistantMentionsStaleFreshness() async throws {
    let reader = FakeAssistantContextReader(
        snapshot: .fixture(.ciFailedStalePRProvider)
    )
    let assistant = AssistantRuntime(
        contextReader: reader,
        actionGateway: .fakeDenyAll()
    )

    let response = try await assistant.answer("现在该看哪个 workspace？")

    XCTAssertTrue(response.text.contains("PR 上下文"))
    XCTAssertTrue(response.text.contains("过期"))
}
```

### Tool catalog test

```swift
func testProductionRoutesDoNotExposeRefreshTools() {
    let routes: [SortAssistantRoute] = [.askContext, .sort, .explain, .applySort]

    for route in routes {
        let tools = SortAssistantActionRouter.allowedTools(for: route)
        XCTAssertFalse(tools.contains("context_collect"))
        XCTAssertFalse(tools.contains("workspace_digest_refresh"))
        XCTAssertFalse(tools.contains("ghpr_refresh"))
    }
}
```

## 图形回归

场景：

```txt
assistant answer with fresh context
assistant answer with stale context banner
assistant answer with missing snapshot empty state
```

UI 断言：

```swift
XCTAssertTrue(app.staticTexts["assistant-freshness-warning"].exists)
```

截图 baseline：

```txt
assistant_stale_context_warning.png
assistant_missing_snapshot_empty_state.png
```

## 完成门槛

```txt
生产 route 不暴露 refresh 类工具
AssistantContextReadable mock 能覆盖 ask/sort/explain 三类问题
stale freshness 在 UI 和回答里可见
```

---

# Milestone 4：ContextAgent actor 进入系统，但先复用现有 provider

## 目标

引入单独 ContextAgent 主动更新 snapshot。先不重写 provider，只把现有上下文获取逻辑包起来。

## 新增组件

```txt
ContextAgent actor
ContextScheduler actor
ProviderRegistry
WorkspaceSnapshotStore actor
ContextRefreshJob
ProviderRunStore
```

## 验证标准

```txt
ContextAgent 订阅 event bus
ContextAgent 根据事件 enqueue refresh job
Provider 运行后写 snapshot
Assistant 不调用 refresh
Snapshot version 单调递增
Provider freshness 正确记录
```

## 自动测试

### Event handling

```swift
func testAgentMessageEventSchedulesAgentSessionProvider() async {
    let scheduler = InMemoryContextScheduler()
    let agent = ContextAgent(
        eventBus: .fake(),
        scheduler: scheduler,
        snapshotStore: .memory(),
        providers: [.fake(id: "agent_session")]
    )

    await agent.handle(.agentMessageAppended(workspaceId: .fixture("a")))

    let jobs = await scheduler.pendingJobs()
    XCTAssertEqual(jobs.first?.workspaceId, .fixture("a"))
    XCTAssertEqual(jobs.first?.reason, "dev.cmux.agent.message_appended.v1")
}
```

### Snapshot write

```swift
func testContextAgentWritesSnapshotAfterProviderRun() async throws {
    let store = InMemoryWorkspaceSnapshotStore()
    let provider = FakeWorkspaceContextProvider.agentWaitingUser()

    let agent = ContextAgent(
        eventBus: .fake(),
        scheduler: .immediate(),
        snapshotStore: store,
        providers: [provider]
    )

    await agent.updateWorkspace(.fixture("a"), reason: "test")

    let snapshot = await store.read(.fixture("a"))
    XCTAssertEqual(snapshot?.derived.status, .waitingUser)
    XCTAssertEqual(snapshot?.version, 1)
}
```

### Replay test

```swift
func testReplayAgentWaitingUserEventLog() async throws {
    let events = try EventLogFixture.load("agent_waiting_user.eventlog.jsonl")
    let harness = ContextAgentReplayHarness.fixture()

    for event in events {
        await harness.agent.handle(event)
    }
    await harness.drain()

    let snapshot = await harness.store.read(.fixture("api-fix"))
    XCTAssertEqual(snapshot?.derived.status, .waitingUser)
    XCTAssertGreaterThan(snapshot?.derived.userAttentionNeeded ?? 0, 0.8)
}
```

## 图形回归

XCUITest 场景：

```txt
启动 fixture: agent running
注入 event: agent waiting_user
等待 sidebar badge 出现
打开 assistant panel
看到“需要你确认”的 suggestion card
```

UI test 伪代码：

```swift
func testAgentWaitingUserSuggestionAppears() {
    let app = CmuxFixtureLauncher.launch(fixture: "agent-running")

    app.buttons["debug-inject-agent-waiting-user"].click()

    XCTAssertTrue(
        app.staticTexts["suggestion-review-agent-waiting-user"]
            .waitForExistence(timeout: 5)
    )

    ScreenshotAssert.match(
        app,
        name: "sidebar_agent_waiting_user_badge"
    )
}
```

## 完成门槛

```txt
ContextAgent 可在测试 fixture 中独立推进
Snapshot version、freshness、provider run metadata 可观察
UI 能展示 ContextAgent 写出的结果
```

---

# Milestone 5：SuggestionEngine 和 RankingEngine 从 Assistant 中拆出

## 目标

主动建议和排序不再由 assistant 临时推理生成。它们读 snapshot，写 suggestion / ranking snapshot。

## 新增组件

```txt
SuggestionEngine
SuggestionStore
RankingEngine
RankingSnapshotStore
NextWorkspaceService
```

## 验证标准

```txt
同一组 WorkspaceSnapshot 输入，Ranking 输出稳定
waiting_user 生成 review_agent_waiting_user suggestion
ci_failed 生成 fix_ci_failure suggestion
ready_to_merge 生成 merge_ready suggestion
dismiss 后同类 suggestion 不重复出现
```

## 自动测试

### Ranking deterministic

```swift
func testRankingPrioritizesUserAttentionNeeded() {
    let snapshots: [WorkspaceSnapshot] = [
        .fixture(.runningAgentLowImportance),
        .fixture(.waitingUserMediumImportance),
        .fixture(.ciFailedHighImportance)
    ]

    let result = RankingEngine.default.rank(snapshots)

    XCTAssertEqual(result.items[0].workspaceId, .fixture("ci-failed"))
    XCTAssertEqual(result.items[1].workspaceId, .fixture("waiting-user"))
}
```

### Suggestion rule

```swift
func testWaitingUserCreatesSuggestion() {
    let snapshot = WorkspaceSnapshot.fixture(.agentWaitingUser)

    let suggestions = SuggestionEngine.default.generate(from: [snapshot])

    XCTAssertTrue(suggestions.contains { suggestion in
        suggestion.type == .reviewAgentWaitingUser &&
        suggestion.workspaceId == snapshot.workspaceId &&
        suggestion.confidence > 0.8
    })
}
```

### Dismiss lifecycle

```swift
func testDismissedSuggestionDoesNotRepeatUntilStateChanges() async {
    let store = InMemorySuggestionStore()
    let engine = SuggestionEngine(store: store)

    let snapshot = WorkspaceSnapshot.fixture(.agentWaitingUser)
    let first = await engine.generateAndStore(from: [snapshot]).first!
    await store.dismiss(first.id)

    let second = await engine.generateAndStore(from: [snapshot])
    XCTAssertTrue(second.isEmpty)

    let changed = snapshot.withContextHash("new-context-hash")
    let third = await engine.generateAndStore(from: [changed])
    XCTAssertFalse(third.isEmpty)
}
```

## 图形回归

组件 snapshots：

```txt
suggestion_card_waiting_user.png
suggestion_card_ci_failed.png
suggestion_card_ready_to_merge.png
ranking_preview_3_workspaces.png
next_workspace_button_active.png
next_workspace_button_disabled.png
```

XCUITest：

```txt
打开 sort panel
看到根据 snapshot 生成的排序
点击 next workspace
切到排序第一项
```

## 完成门槛

```txt
Assistant 删除生成 suggestion/ranking 的业务逻辑
UI 和 assistant 都读相同 RankingSnapshot / SuggestionStore
视觉回归覆盖 suggestion card 和 sort preview
```

---

# Milestone 6：SemanticActionGateway 包住所有 assistant mutation

## 目标

助手仍保留简单操作接口，但所有 mutation 都必须先进入 ActionIntent，再通过 semantic 审核。

## 包住的第一批操作

```txt
sort_apply
sort_undo
workspace_color_set
workspace_color_clear
list_pin
list_lock
suggestion_accept
suggestion_dismiss
memory_write_candidate
sprite_memory_write
```

## 新增组件

```txt
ActionIntent
CmuxAction
SemanticActionGateway
RuleBasedActionReviewer
FreshnessActionReviewer
SemanticConsistencyReviewer
ActionAuditLog
```

## 验证标准

```txt
assistant mutating tool 不直接执行 workspace mutation
低风险 action 可 allow
中风险 action stale 时 requireConfirmation
高风险 action 永远 requireConfirmation 或 deny
所有 action 有 audit log
ActionIntent 记录 evidence snapshot version
```

## 自动测试

### Gateway allow

```swift
func testSwitchWorkspaceAllowedWhenTargetExists() async throws {
    let gateway = SemanticActionGateway.fixture(
        snapshots: [.fixture(.runningAgent)]
    )

    let intent = ActionIntent.fixture(
        kind: .switchWorkspace,
        workspaceId: .fixture("running-agent")
    )

    let result = try await gateway.submit(intent)

    XCTAssertEqual(result.decision, .allow)
    XCTAssertEqual(result.risk, .low)
}
```

### Gateway stale requires confirmation

```swift
func testApplySortRequiresConfirmationWhenSnapshotsAreStale() async throws {
    let gateway = SemanticActionGateway.fixture(
        snapshots: [
            .fixture(.ciFailedStale),
            .fixture(.waitingUserStale)
        ]
    )

    let intent = ActionIntent.fixture(
        kind: .applySort,
        workspaceIds: [.fixture("ci"), .fixture("waiting")]
    )

    let result = try await gateway.submit(intent)

    XCTAssertEqual(result.decision, .requireConfirmation)
    XCTAssertTrue(result.reasons.contains { $0.contains("stale") })
}
```

### Bypass test

源码扫描：

```swift
func testAssistantToolsDoNotCallWorkspaceExecutorDirectly() throws {
    let files = try SourceScanner.files(under: "Sources/SpriteAssistant")

    let banned = [
        "workspaceService.switch",
        "sortStore.apply",
        "WorkspaceActionDispatcher.dispatch",
        "TabManager.shared"
    ]

    for file in files {
        let text = try String(contentsOf: file)
        for symbol in banned {
            XCTAssertFalse(text.contains(symbol))
        }
    }
}
```

## 图形回归

场景：

```txt
assistant proposes apply sort
semantic review allows
UI shows applied sort

assistant proposes apply sort with stale context
semantic review requires confirmation
UI shows confirmation banner

assistant proposes denied action
UI shows denied reason
```

截图 baseline：

```txt
semantic_review_allow_sort.png
semantic_review_requires_confirmation_stale_context.png
semantic_review_denied_invalid_target.png
```

## 完成门槛

```txt
所有 production mutating tools 走 Gateway
AuditLog 测试覆盖 allow / confirmation / deny
UI 有 confirmation / deny 图形回归
```

---

# Milestone 7：替换生产上下文工具，assistant 不再拥有 refresh 能力

## 目标

把 `context_collect`、`workspace_digest_refresh`、`ghpr_refresh` 从 production assistant routes 移除。保留 dev/debug 入口。

## 变更

生产 routes：

```txt
允许:
assistant_working_context_get
workspace_snapshot_get
workspace_digest_get
context_freshness_get
ranking_latest_get
suggestions_active_get
list_state

移出:
context_collect
repository_context
github_context
github_pr_context
ghpr_context
ghpr_status 视语义决定
ghpr_refresh
workspace_digest_refresh
workspace_digest_progress 视语义决定
```

更细一点：

```txt
ghpr_status 如果只读 cached PR state，可以保留
ghpr_status 如果会触发网络刷新，应移出 production assistant
workspace_digest_get 保留
workspace_digest_refresh 移出
```

## 验证标准

```txt
assistant prompt 不再要求 gather context
assistant production tool catalog 不含 refresh / collect
用户提问时 UI/Core 发 attention event
ContextAgent 基于 attention event 提升刷新优先级
assistant 只读最新可用 snapshot
```

## 自动测试

### Prompt policy snapshot

```swift
func testContextPromptDoesNotTellModelToCollectContext() {
    let prompt = SortAssistantPromptFragments.context

    XCTAssertFalse(prompt.contains("Gather relevant context"))
    XCTAssertFalse(prompt.contains("context_collect"))
    XCTAssertFalse(prompt.contains("workspace_digest_refresh"))

    XCTAssertTrue(prompt.contains("ContextAgent"))
    XCTAssertTrue(prompt.contains("freshness"))
}
```

### Query started event

```swift
func testAssistantQueryPublishesAttentionEvent() async {
    let eventBus = InMemoryEventBus()
    let assistant = AssistantRuntime.fixture(eventBus: eventBus)

    _ = try? await assistant.answer("现在该处理哪个 workspace？")

    let events = await eventBus.recordedEvents()
    XCTAssertTrue(events.contains {
        $0.type == "dev.cmux.assistant.query_started.v1"
    })
}
```

### ContextAgent lease

```swift
func testAssistantQueryEventCreatesHotLease() async {
    let agent = ContextAgent.fixture()

    await agent.handle(.assistantQueryStarted(relatedWorkspaceIds: [.fixture("a")]))

    let lease = await agent.scheduler.lease(for: .fixture("a"))
    XCTAssertEqual(lease?.priority, .hot)
}
```

## 图形回归

场景：

```txt
用户提问
assistant immediately shows "using snapshot updated 12s ago"
ContextAgent status indicator shows refreshing
freshness updates after provider completes
assistant follow-up sees newer snapshot
```

截图：

```txt
assistant_snapshot_freshness_inline.png
context_agent_refresh_indicator.png
```

## 完成门槛

```txt
Production assistant 无 refresh tool
ContextAgent attention lease 测试通过
用户体验上仍能看到上下文 freshness
```

---

# Milestone 8：图形化自动回归升级为 CI gate

## 目标

把 UI / visual 回归从“本地可跑”升级成“CI 必跑或至少 nightly 必跑”。

GitHub-hosted runners 支持 macOS runner，runner 会 clone repo、安装测试软件并运行命令；GitHub 维护标准 runner image，并提供 macOS、Linux、Windows 环境。([GitHub Docs][4]) 对 macOS App 的 XCUITest，建议优先跑在固定 macOS/Xcode 版本的 runner 或自托管 runner，以降低截图差异。

## CI 分层

### PR 必跑

```txt
xcodebuild test cmuxTests
architecture boundary tests
contracts golden tests
semantic gateway tests
context agent replay tests
component snapshot tests, 只跑 text/json 或少量 image
```

### PR 可选 / label 触发

```txt
XCUITest smoke
critical visual snapshots
```

### Nightly 必跑

```txt
full cmuxUITests
full visual regression
multiple window sizes
light/dark appearance
```

## CI 命令示例

```bash
set -o pipefail

xcodebuild test \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -destination 'platform=macOS' \
  -resultBundlePath build/results/cmuxTests.xcresult \
  | xcbeautify
```

UI test：

```bash
xcodebuild test \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -destination 'platform=macOS' \
  -only-testing:cmuxUITests \
  -resultBundlePath build/results/cmuxUITests.xcresult
```

Artifact：

```txt
build/results/*.xcresult
cmuxUITests/Screenshots/diff/*.png
cmuxTests/__Snapshots__/**/*.png
```

## 图形 diff 策略

建议分三档：

```txt
strict:
  关键小组件，例如 suggestion card、sort preview row

tolerant:
  整窗 screenshot，允许 0.5% 到 1.0% 像素差异

semantic:
  对文字、accessibility tree、元素位置做结构化断言
```

整窗截图容易受字体渲染、系统版本、窗口阴影影响，所以不要只靠 pixel-perfect。更稳的组合是：

```txt
XCUITest accessibility assertions
+ component image snapshot
+ full window screenshot artifact
+ tolerant pixel diff
```

## 完成门槛

```txt
PR 能阻止架构边界破坏
PR 能阻止 Contracts golden 变化
Nightly 能发现 UI 布局退化
失败时 artifacts 足以定位问题
```

---

# Milestone 9：ContextAgent provider 外移与刷新频率验证

## 目标

开始把 Git / PR / screen / agent session 这类大块非核心逻辑从 core 拆出去，同时验证刷新频率符合预期。

## 新增测试重点

```txt
Hot workspace refresh faster
Warm workspace medium frequency
Cold workspace slow refresh
Provider debounce 生效
Provider timeout 生效
Provider max concurrency 生效
digest update 被 semantic diff 控制
```

## 自动测试

### Scheduler frequency

```swift
func testHotWorkspaceRefreshesBeforeColdWorkspace() async {
    let clock = TestClock()
    let scheduler = ContextScheduler(clock: clock)

    await scheduler.setLease(.hot, for: .fixture("hot"))
    await scheduler.setLease(.cold, for: .fixture("cold"))

    await scheduler.markProviderCollected("git", workspace: .fixture("hot"))
    await scheduler.markProviderCollected("git", workspace: .fixture("cold"))

    await clock.advance(by: .seconds(20))

    let jobs = await scheduler.nextBatch()
    XCTAssertTrue(jobs.contains { $0.workspaceId == .fixture("hot") })
    XCTAssertFalse(jobs.contains { $0.workspaceId == .fixture("cold") })
}
```

### Debounce

```swift
func testGitProviderDebouncesFileChangeBurst() async {
    let scheduler = ContextScheduler.fixture(debounce: .seconds(2))

    for _ in 0..<20 {
        await scheduler.enqueue(.gitChanged(workspaceId: .fixture("a")))
    }

    let jobs = await scheduler.nextBatch()
    XCTAssertEqual(jobs.filter { $0.providerId == "git" }.count, 1)
}
```

### Digest semantic diff

```swift
func testDigestSkipsWhenOnlyTimestampChanges() async {
    let updater = DigestUpdater.fixture()

    let previous = WorkspaceSnapshot.fixture(.runningAgent)
    let next = previous.withUpdatedAt(previous.updatedAt.addingTimeInterval(30))

    let shouldUpdate = await updater.shouldUpdate(previous: previous, next: next)

    XCTAssertFalse(shouldUpdate)
}
```

## 图形回归

新增一个 debug-only ContextAgent inspector：

```txt
provider freshness table
last provider run
hot/warm/cold lease
snapshot version
pending refresh jobs
```

UI snapshot：

```txt
context_agent_inspector_hot_workspace.png
context_agent_inspector_provider_error.png
context_agent_inspector_debounce.png
```

这个 inspector 对开发很有价值。它能解释“为什么助手没更新上下文”。

## 完成门槛

```txt
Scheduler 频率可测试
Provider 移出 core 后现有 UI 行为不变
ContextAgent inspector 可视化 provider freshness
```

---

# Milestone 10：端到端主动助手回归套件

## 目标

建立一组稳定的 dogfood 场景。每次架构变更都能跑这些场景，验证主动助手仍然合理。

## 核心 E2E 场景

### 场景 A：agent waiting user

输入 event log：

```txt
workspace A running
agent session appended prompt
agent state waiting_user
```

期望：

```txt
ContextAgent 写 snapshot status = waiting_user
SuggestionEngine 生成 review_agent_waiting_user
Sidebar 出现 badge
Assistant panel 解释原因
用户点击切过去
ActionGateway allow switchWorkspace
```

### 场景 B：CI failed

期望：

```txt
workspace 排序上升
suggestion card = fix_ci_failure
assistant 说明 CI failed freshness
```

### 场景 C：ready to merge，但 PR provider stale

期望：

```txt
suggestion risk medium
Context freshness warning visible
accept suggestion requires confirmation 或不展示 merge action
```

### 场景 D：assistant apply sort

期望：

```txt
assistant 读取 ranking snapshot
提交 ActionIntent
Gateway 审核通过
sort preview 应用
audit log 有记录
```

### 场景 E：assistant attempts refresh

期望：

```txt
production tool catalog 没有 refresh
prompt 没有 context_collect
源码边界测试通过
```

## E2E UI test 骨架

```swift
final class ProactiveAssistantE2EUITests: CmuxUITestCase {
    func testAgentWaitingUserFullFlow() {
        let app = launchCmux(fixture: "e2e-agent-running")

        app.buttons["debug-inject-agent-waiting-user"].click()

        XCTAssertTrue(app.staticTexts["workspace-status-waiting-user-api"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["suggestion-review-agent-waiting-user"].exists)

        app.buttons["suggestion-open-api"].click()

        XCTAssertTrue(app.staticTexts["workspace-row-api"].isSelectedLike)

        ScreenshotAssert.match(
            app,
            name: "e2e_agent_waiting_user_after_switch"
        )
    }
}
```

## 完成门槛

```txt
5 个 E2E 场景稳定
每个场景都有 screenshot artifact
每个场景同时验证数据状态和 UI 状态
```

---

# 图形化回归的具体落地建议

## 1. 先做组件 snapshot，再做全窗口 screenshot

优先组件：

```txt
WorkspaceRow
SuggestionCard
AssistantMessageBubble
FreshnessWarningView
SortPreviewView
SemanticReviewBanner
ContextAgentInspectorView
```

这些组件更稳定，也更容易 review。

## 2. 全窗口截图只覆盖关键流程

全窗口截图数量控制在 5 到 10 张：

```txt
app_launch_three_workspaces
assistant_open_with_suggestions
sort_preview_waiting_user_first
semantic_review_requires_confirmation
context_agent_inspector_provider_error
```

## 3. Baseline 管理

目录：

```txt
cmuxTests/__Snapshots__/
  AssistantPanelSnapshotTests/
  WorkspaceSidebarSnapshotTests/
  SuggestionCardSnapshotTests/

cmuxUITests/__Screenshots__/
  baseline/
  actual/
  diff/
```

规则：

```txt
baseline 更新必须单独 PR 或单独 commit
CI 失败上传 actual/diff
PR reviewer 需要看 diff image
不允许在普通逻辑 PR 中顺手大规模更新 baseline
```

## 4. 降低 flakiness

```txt
禁用动画
固定窗口尺寸
固定 appearance
固定时间
固定字体 fallback
隐藏光标
禁止网络
禁止真实 LLM
禁止自动更新
等待 accessibility element，不 sleep 固定秒数
```

示例：

```swift
extension XCUIElement {
    func waitAndClick(timeout: TimeInterval = 5) {
        XCTAssertTrue(waitForExistence(timeout: timeout))
        click()
    }
}
```

---

# 建议的 PR 节奏

```txt
PR 1
  Test harness + fixture mode + UI smoke screenshot

PR 2
  SortAssistantFeature 无行为拆分 + router/tool snapshot

PR 3
  Contracts + WorkspaceSnapshot + freshness tests

PR 4
  AssistantContextReadable + production prompt/tool catalog 收敛

PR 5
  ContextAgent actor + fake providers + replay tests

PR 6
  SuggestionEngine / RankingEngine snapshot 化

PR 7
  SemanticActionGateway 包住 mutating tools

PR 8
  移除 production refresh tools，改为 ContextAgent attention lease

PR 9
  Visual regression CI + nightly full UI regression

PR 10
  Provider 外移 + ContextAgent inspector + frequency tests
```

---

# 每个 milestone 的统一验收模板

每个 PR 都强制填这个 checklist：

```txt
Architecture
  [ ] Assistant 没有新增 provider / scheduler / refresh 依赖
  [ ] Mutation 通过 SemanticActionGateway
  [ ] Context update 由 ContextAgent 或 test fixture 驱动
  [ ] 新 public type 在 Contracts 层有 Codable / Sendable 测试

Unit
  [ ] 新逻辑有 pure unit tests
  [ ] 关键输出有 golden / snapshot test
  [ ] 错误路径有测试

Integration
  [ ] EventBus + Store + Actor 链路有测试
  [ ] Replay fixture 覆盖主要状态变化

UI
  [ ] 关键 UI 元素有 accessibilityIdentifier
  [ ] XCUITest 覆盖主要用户路径
  [ ] Screenshot artifact 可用于失败定位

Visual
  [ ] 组件 snapshot 已更新或确认无需更新
  [ ] 全窗口截图无非预期 diff

Operational
  [ ] 无真实网络依赖
  [ ] 无真实 LLM 依赖
  [ ] CI 可复现
```

当前 refactor-sprite 分支的验收状态：

```txt
Architecture
  [x] Assistant 没有新增 provider / scheduler / refresh 依赖
      Evidence: SortAssistantIntentRouterTests + tests/test_cli_sprite_mcp_tool_policy.py 验证 production/default tool catalog 不含 context_collect / workspace_digest_refresh / ghpr_refresh，prompt policy 使用 assistant_working_context_get。
  [x] Mutation 通过 SemanticActionGateway
      Evidence: Packages/CMUXActions/Tests/CMUXActionsTests/SemanticActionGatewayTests.swift；cmuxTests/WindowAndDragTests.swift 覆盖 socket/apply/undo/suggestion/memory audit。
  [x] Context update 由 ContextAgent 或 test fixture 驱动
      Evidence: Packages/CMUXContextAgent tests；ContextAgent replay fixture tests；SpriteAssistantUITests deterministic fixture。
  [x] 新 public type 在 Contracts 层有 Codable / Sendable 测试
      Evidence: CMUXContracts public context types declare Codable/Equatable/Sendable；WorkspaceContextContractsTests 覆盖 WorkspaceSnapshot / AssistantWorkingContext Codable round trip 和 freshness/hash semantics。

Unit
  [x] 新逻辑有 pure unit tests
      Evidence: CMUXActions / CMUXAssistant / CMUXContracts / CMUXContextAgent / CMUXOrchestration package tests。
  [x] 关键输出有 golden / snapshot test
      Evidence: SortAssistantIntentRouterTests 覆盖 prompt/tool catalog policy；SpriteAssistant component semantic snapshot 覆盖 runtime anchors；SpriteAssistantUITests writes screenshot artifacts.
  [x] 错误路径有测试
      Evidence: SemanticActionGateway deny/requireConfirmation tests；ContextAgent provider timeout/failure tests；AssistantRuntime missing snapshot tests。

Integration
  [x] EventBus + Store + Actor 链路有测试
      Evidence: ContextAgent event stream tests；Suggestion/Ranking store publication tests；assistant query started refresh tests。
  [x] Replay fixture 覆盖主要状态变化
      Evidence: cmuxTests/Fixtures/ContextAgent replay tests for agent_waiting_user and multi_status.

UI
  [x] 关键 UI 元素有 accessibilityIdentifier
      Evidence: SpriteAssistantUITests covers SortAssistantFloatingPanel, SortAssistantThread, SortAssistantInput, SortAssistantInputField, suggestion cards, semantic confirmation buttons, ContextAgentInspector.
  [x] XCUITest 覆盖主要用户路径
      Evidence: SpriteAssistantUITests full focused class passes 5 tests.
  [x] Screenshot artifact 可用于失败定位
      Evidence: ScreenshotAssert failure artifacts; CI and test-e2e upload screenshot / xcresult artifacts from xctrunner container directories; tests/test_ci_e2e_ui_artifacts.sh guards the manual workflow.

Visual
  [x] 组件 snapshot 已更新或确认无需更新
      Evidence: SortAssistantIntentRouterTests/testSpriteAssistantComponentSemanticSnapshotMatchesBaseline compares runtime SpriteAssistant component semantics against cmuxTests/Fixtures/SpriteAssistant/component-semantic-snapshot.txt.
  [x] 全窗口截图无非预期 diff
      Evidence: SpriteAssistantUITests writes window-level PNG/JSON artifacts for four critical states and compares them against checked-in baselines in cmuxUITests/__Screenshots__/baseline. tests/validate_sprite_assistant_screenshots.py --require-baseline validates PNG dimensions against metadata, nonblank pixel ratio, comparisonStatus=compared, numeric mismatchRatio, and any failure screenshot/hierarchy sets.

Operational
  [x] 无真实网络依赖
      Evidence: deterministic UI launch passes --disable-network; CLI policy test uses tagged local CLI.
  [x] 无真实 LLM 依赖
      Evidence: deterministic UI launch passes --disable-real-llm; fake assistant response test passes.
  [x] CI 可复现
      Evidence: ci.yml runs Swift package tests, CLI policy, SpriteAssistantUITests with fixed fixture, screenshot validation, and workflow guard tests.
```

---

# 我建议最先做的 3 个测试

第一，**assistant tool catalog regression**。这是最直接防止助手重新获得 refresh 权限的测试。

```swift
func testProductionAssistantToolsDoNotIncludeContextRefresh() {
    let tools = SortAssistantActionRouter.productionAllowedTools()

    XCTAssertFalse(tools.contains("context_collect"))
    XCTAssertFalse(tools.contains("workspace_digest_refresh"))
    XCTAssertFalse(tools.contains("ghpr_refresh"))
}
```

第二，**ContextAgent replay test**。这是证明“上下文由单独 agent 主动维护”的核心测试。

```swift
func testReplayProducesWaitingUserSnapshotAndSuggestion() async throws {
    let harness = ContextAgentReplayHarness.fixture("agent_waiting_user")
    try await harness.replay()

    let snapshot = await harness.snapshot("api-fix")
    XCTAssertEqual(snapshot.derived.status, .waitingUser)

    let suggestions = await harness.suggestions()
    XCTAssertTrue(suggestions.contains { $0.type == .reviewAgentWaitingUser })
}
```

第三，**semantic gateway bypass test**。这是保证 assistant 简单操作接口不会绕过审核的测试。

```swift
func testAssistantMutatingToolsSubmitActionIntent() async throws {
    let gateway = RecordingSemanticActionGateway()
    let tool = SortApplyTool(actionGateway: gateway)

    _ = try await tool.call(arguments: .fixtureSortApply)

    XCTAssertEqual(gateway.recordedIntents.count, 1)
    XCTAssertEqual(gateway.recordedIntents.first?.kind, .applySort)
}
```

---

# 最终目标

迁移完成后，你应该能用测试证明这几件事：

```txt
1. Assistant 只读 snapshot / digest / freshness
2. ContextAgent 负责上下文更新频率
3. Ranking / Suggestion 不依赖 Assistant
4. Assistant mutation 全部走 SemanticActionGateway
5. UI 能稳定展示 freshness、suggestion、semantic review
6. 图形回归能发现 sidebar、assistant panel、sort preview 的布局破坏
7. Replay tests 能证明上下文事件到建议的链路没有退化
```

这套验证体系建起来之后，后续继续拆 GitHub provider、digest updater、screen parser、agent session parser、ranking strategy，都可以靠 replay tests 和 visual regression 兜底，不需要每次靠手动点 UI 验证。

---

# 2026-05-27 本地验证记录

当前分支已经允许在本地开发环境运行测试；根目录 `AGENTS.md` 指向 `CLAUDE.md`，测试策略已从“禁止本地跑测试”更新为“允许本地跑测试，但必须遵守 tagged Debug app / socket 隔离”。

已通过：

```txt
swift test --package-path Packages/CMUXActions
swift test --package-path Packages/CMUXAssistant
swift test --package-path Packages/CMUXContracts
swift test --package-path Packages/CMUXContextAgent
swift test --package-path Packages/CMUXOrchestration
xcodebuild test -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -only-testing:cmuxTests/CmuxRuntimeModeTests
CMUX_CLI_BIN=<tagged-debug-cli> python3 tests/test_cli_sprite_mcp_tool_policy.py
./scripts/reload.sh --tag refactor-sprite
xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-refactor-sprite-unit -only-testing:cmuxTests/SortAssistantIntentRouterTests
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-refactor-sprite-ui build-for-testing
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-refactor-sprite-ui -maximum-test-execution-time-allowance 120 -only-testing:cmuxUITests/SpriteAssistantUITests/testAssistantFixtureWorkspaceTitlesLoad test
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-refactor-sprite-ui -maximum-test-execution-time-allowance 120 -only-testing:cmuxUITests/SpriteAssistantUITests/testSpriteAssistantPanelHasStableAutomationAnchors test
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-refactor-sprite-ui -maximum-test-execution-time-allowance 120 -only-testing:cmuxUITests/SpriteAssistantUITests/testSuggestionActionWithStaleFixtureContextShowsConfirmation test
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-refactor-sprite-ui -maximum-test-execution-time-allowance 120 -only-testing:cmuxUITests/SpriteAssistantUITests/testFakeAssistantAnswersFromFixtureContext test
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-refactor-sprite-ui -maximum-test-execution-time-allowance 120 -only-testing:cmuxUITests/SpriteAssistantUITests/testContextAgentInspectorHasStableVisualAnchor test
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-refactor-sprite-ui -maximum-test-execution-time-allowance 180 -only-testing:cmuxUITests/SpriteAssistantUITests test
git diff --check
```

验证到的行为：

```txt
1. 新拆出的 package 单元测试通过。
2. runtime mode 参数解析测试通过。
3. Sprite assistant CLI/MCP tool policy 测试通过，production/default tool catalog 不暴露 context refresh/debug tools。
4. tagged Debug app build 通过，且 reload 输出 isolated refactor-sprite app path。
5. `SortAssistantIntentRouterTests` 通过 98 个 focused 单元测试，覆盖 production tool catalog、snapshot-backed context prompts、ContextAgent snapshot/replay、SemanticActionGateway audit、socket action review、suggestion accept/dismiss、MCP tools/list discovery。
6. UI test bundle 当前源码可编译。
7. Sprite Assistant fixture workspace UI smoke test 通过，证明 deterministic fixture workspace titles 能在 XCUITest 中稳定渲染和查询。
8. SpriteAssistantUITests full focused class 通过，覆盖 assistant panel anchors、semantic confirmation、fake assistant response、Context Agent Inspector screenshots。
9. diff whitespace 检查通过。
```

本轮修正了 Sprite Assistant UI test 的本地稳定性问题：

```txt
1. launchDeterministicApp 显式传入 ApplePersistenceIgnoreState / NSQuitAlwaysKeepsWindows，避免 AppKit saved-state 干扰 deterministic fixture。
2. fixture title 断言改为按 accessibility label 内容查询；未选中的 workspace row 会以组合 accessibility element 暴露，而不是每个标题都有独立 staticText identifier。
3. failure teardown 在 app termination 前写出 screenshot、accessibility hierarchy、metadata，并 attach artifact 路径；目录可通过 CMUX_UI_TEST_SCREENSHOT_OUTPUT_DIR 指定。
4. deterministic fixture 模式跳过本地 sidebar git metadata probe，避免真实本机目录状态清掉 fixture 的 stale PR，从而保证 fake assistant 回答能稳定暴露 github_context stale freshness。
```

# 2026-05-28 本地验证记录

本轮按交互反馈调整了 Sprite Assistant floating panel：

```txt
1. conversation bubble 拆成独立状态，默认收起。
2. Sort Assistant 入口不再关闭整个 sprite panel，而是确保 panel 存在并 toggle bubble。
3. external goal / openEntry 会按需展开 bubble 并聚焦输入。
4. 点击 floating mascot 会 toggle bubble。
5. edge-recovery mini sprite 也保留点击 toggle 能力。
```

已通过：

```txt
./scripts/reload.sh --tag refactor-sprite
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-refactor-sprite-ui -maximum-test-execution-time-allowance 180 -only-testing:cmuxUITests/SpriteAssistantUITests test
tests/test_ci_e2e_ui_artifacts.sh
python3 tests/validate_sprite_assistant_screenshots.py /Users/jiahao.wang/Library/Containers/com.cmuxterm.appuitests.xctrunner/Data/tmp/cmux-sprite-assistant-screenshots
xcodebuild test -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-refactor-sprite-unit -only-testing:cmuxTests/SortAssistantIntentRouterTests/testSpriteAssistantComponentSemanticSnapshotMatchesBaseline
python3 tests/validate_sprite_assistant_screenshots.py /Users/jiahao.wang/Library/Containers/com.cmuxterm.appuitests.xctrunner/Data/tmp/cmux-sprite-assistant-screenshots --require-baseline
tests/test_ci_sprite_assistant_visual_baseline.sh
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/test-e2e.yml"); YAML.load_file(".github/workflows/ci.yml"); puts "yaml ok"'
git diff --check
```

本轮继续修正：

```txt
1. suggestion card 的 accessibility id 挂在可见 title 文本上，避免 card 内 Button 抢占查询结果。
2. input row 保留 SortAssistantInput 容器 anchor，同时把真实 TextField 暴露为 SortAssistantInputField。
3. semantic confirmation card 使用 contain accessibility，让确认/取消按钮 anchor 不被父级 id 覆盖。
4. SpriteAssistantUITests 失败时保留 app 到 teardown 阶段再截图，便于卡住时快速 review。
5. Sprite Assistant CI regression 和手动 test-e2e workflow 都设置 CMUX_UI_TEST_SCREENSHOT_OUTPUT_DIR，并上传 screenshot / xcresult artifacts，失败时能直接下载 review。
6. Sprite Assistant CI regression 使用 xctrunner container screenshot directory，并通过 checked-in full-window baselines 做 pixel comparison。
7. 手动 test-e2e workflow 同时上传指定 screenshot directory 和 ScreenshotAssert fallback directory，避免 UI failure artifact 因 runner container 路径差异丢失。
8. workflow-guard-tests 接入 tests/test_ci_e2e_ui_artifacts.sh 和 tests/test_ci_sprite_assistant_visual_baseline.sh，防止 manual workflow / Sprite Assistant CI 丢失 result bundle、screenshot artifact、baseline comparison 链路。
9. tests/validate_sprite_assistant_screenshots.py 校验 Sprite Assistant UI 运行产物：PNG header 尺寸、metadata 尺寸、nonUniformPixelRatio、comparisonStatus、--require-baseline 下的 mismatchRatio，以及可选 failure screenshot / hierarchy metadata。
10. cmuxTests/Fixtures/SpriteAssistant/component-semantic-snapshot.txt 作为组件级 text snapshot，覆盖 assistant message row、suggestion card、semantic confirmation、input anchors 的 runtime semantic contract。
```

[1]: https://github.com/xiaocang/cmux/tree/plus "GitHub - xiaocang/cmux: Ghostty-based macOS terminal with vertical tabs and notifications for AI coding agents · GitHub"
[2]: https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/testing_with_xcode/chapters/09-ui_testing.html "User Interface Testing"
[3]: https://github.com/pointfreeco/swift-snapshot-testing "GitHub - pointfreeco/swift-snapshot-testing:  Delightful Swift snapshot testing. · GitHub"
[4]: https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners "GitHub-hosted runners - GitHub Docs"
