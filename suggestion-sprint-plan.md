# Suggestion Sprint Plan — 让系统精灵主动提示「下一步该干什么」

> 目标:把 `activate-plan.md` 描述的「精灵主动、事件驱动地告诉你该看哪个 workspace」从「零件齐备但没闭环」推到「真正能主动提示」。
>
> 关键判断(经代码审计确认):**plan 里的引擎、类型、事件总线、后台收集器全都已经建好并在运行**。本 sprint 不是从头造,而是接上**最后一条反馈边**(snapshot 变了 → 重算 suggestion → 主动呈现),再补一个**呈现通道**。
>
> 配套测试体系沿用 `activate-plan.md` 的分层(L0–L6)与 fixture 约定;本文件只覆盖「让精灵主动起来」这个最小可交付切片(对应 activate-plan 的 M4/M5 收尾 + 主动呈现)。

---

## 0. 现状(已验证,带 file:line)

| 组件 | 状态 | 位置 |
|---|---|---|
| `CmuxEventBus` 事件总线(replay/订阅/JSONL) | ✅ 运行中 | `Sources/CmuxEventBus.swift` |
| `ContextAgent` actor + 事件流(后台刷新 snapshot) | ✅ 实例化并 `startEventStream()` | `Sources/SpriteAssistant/SortAssistantCoordinator.swift:209-231`、`Sources/SpriteAssistant/ContextAgent.swift:63-99` |
| 4 个 provider(list_state/git_context/github_context/summary_priority) | ✅ 已注册 | `SortAssistantCoordinator.swift:224-229` |
| `ContextScheduler`(hot/visible/cold lease + 间隔刷新) | ✅ 存在,但 `enqueueDueProviderRefreshes` **零调用(死代码)** | `Packages/CMUXContextAgent/.../ContextAgent.swift` |
| `WorkspaceSnapshotStore`(被动 actor,无变更通知) | ✅ 存在,**无 publisher/observer** | `Sources/SpriteAssistant/WorkspaceSnapshotStore.swift:1-86` |
| `SuggestionEngine` → 三种类型 review_agent_waiting_user/fix_ci_failure/merge_ready | ✅ 实现 | `Packages/CMUXOrchestration/.../SuggestionRankingEngines.swift:49-161` |
| `generateAndStore`(去重感知的推送路径) | ⚠️ 存在但**全工程无调用** | 同上 `:71-84` |
| `RankingEngine.rank` | ✅ 实现并计算 | 同上 `:4-47` |
| `NextWorkspaceService`(排名版「下一个看哪个」) | ⚠️ 存在但**仅测试调用** | 同上 `:193-225` |
| `SemanticActionGateway` + ActionIntent/Evidence/审计 | ✅ 已接线 | `Packages/CMUXActions/.../SemanticActionGateway.swift` |
| Suggestion 卡片渲染 | ✅ 但**仅在面板打开时** | `Sources/SpriteAssistant/SortAssistantThreadView.swift:120-122` |
| `refreshVisibleSuggestions()` | ⚠️ **唯一调用点是 `attach()`** | `SortAssistantCoordinator.swift:318, 5873` |
| 气泡可见性 `isConversationBubblePresented` | ❌ **只能被用户动作翻转** | `SortAssistantCoordinator.swift:404-419` |

### 断点图

```
CmuxEventBus ──event──► ContextAgent.handleAndDrain ──► runScheduledBatch
                                  │                          │
                                  │                   返回 ContextAgentBatchResult
                                  │                   (含 updatedWorkspaceIds)
                                  ▼                          │
                       WorkspaceSnapshotStore ◄──merge──────┘
                       (被动,无变更通知)
                                  ✗  ← 断点①:批次结果被 `_ =` 丢弃 (ContextAgent.swift:97)
                                  ✗  ← 断点②:store 无 observer,coordinator 不知道 snapshot 变了
                                  ▼
        refreshVisibleSuggestions() ── 只被 attach() 调用(面板打开/切 tab 时)── 断点③
                                  ▼
        visibleSuggestions(@Published) ── 只在已打开的 ThreadView 里渲染 ── 断点④:无关闭态呈现通道
```

**结论:四个断点中,①+②+③是同一条反馈边,是一切的前置;④是呈现通道。** 引擎本身不用动。

---

## 1. 设计原则 / 护栏(均来自 CLAUDE.md,违反会引入已知事故)

- **性能**:`ContextAgent` 在 actor/detached 上跑;反馈回 coordinator 必须 (a) 在 off-main 去抖/合并,(b) 仅在 suggestion 集合**实际变化**时才 `DispatchQueue.main.async` 写 `@Published`(`visibleSuggestions != suggestions` 的 diff 守卫已存在于 `SortAssistantCoordinator.swift:5864`,要复用)。
- **绝不在 view body 里写 store 状态**(re-render 反馈环 → 主线程 100% CPU)。重算只能在批次完成回调 / didSet / observer 里触发,不能在 `ForEach` 投影里。
- **侧栏快照边界**(Phase 3 必读):侧栏 row / drop-gap 下方不得持有任何 `ObservableObject`;row 只接收**不可变值快照 + 闭包**。参考 `Sources/SessionIndexView.swift` 的 `IndexSectionActions` 模式。否则重现 issue #2586 的 `LazyLayoutViewCache` 自旋。
- **不抢焦点**:主动呈现(气泡/侧栏徽章/通知)必须是 **non-activating**,不得激活 app 或抬升窗口(类比 socket focus policy)。
- **精灵浮动位置**:Phase 2 若自动弹气泡,mini/edge-recovery 判定**只能基于 `NSScreen.visibleFrame`**,不得用 cmux 父窗口/内容/frame;不得复用 autocomplete/popover 的可见性夹取逻辑去约束精灵拖动。
- **共享行为策略**:主动呈现若有多个入口(自动弹 / 命令面板 / 快捷键 / 设置),走**同一条 action/model 路径**,不要逐个 surface 复制逻辑。
- **本地化**:所有新文案用 `String(localized:defaultValue:)`,key 入 `Resources/Localizable.xcstrings`(英 + 日)。
- **快捷键策略**:若新增「跳到下一个 workspace」快捷键(Phase 4),必须进 `KeyboardShortcutSettings`、Settings 可编辑、支持 `~/.config/cmux/cmux.json`、并写进快捷键 + 配置文档。
- **设置/配置**:新功能开关进 Settings + `cmux.json` + docs。
- **Debug 菜单**:复用 `ContextAgentInspector`(已有,DEBUG-only)做可观测;新调试开关按「Debug Windows」约定加。
- **测试**:行为级测试(不测源码文本/签名);回归用**两提交红/绿**结构;新测试文件必须写入 `cmux.xcodeproj/project.pbxproj`(四处条目),否则 CI 静默 0 tests。**测试由我(用户)手动跑**,Claude 只负责写。

---

## Phase 0 — 安全网、特性开关、fixture(无行为变化)  ✅ 实现完成(2026-05-29)

**目的**:先能开关、能观测、能确定性回放,再动逻辑。

- [x] 运行期特性开关 `ProactiveSpriteSuggestionsSettings`(UD key `sprite.proactiveSuggestions`,默认 **off**)。全链路接好:Settings UI 卡片(`cmuxApp.swift`)、`cmux.json` 允许表/解析/模板(`CmuxSettingsJSONPathSupport.swift`、`KeyboardShortcutSettingsFileStore(.swift/+Template)`)、命令面板 toggle、设置搜索 nav+alias、`web/data/*.schema.json` ×2、`Localizable.xcstrings`(en/ja/zh-Hans/zh-Hant)。默认 off ⇒ 现状 100% 一致。**目前还没有任何代码读取它**(Phase 1 起消费)。
- [x] onBatch seam:`ContextAgent.startEventStream(onBatch:)` 不再丢弃 `runScheduledBatch` 结果(原 `ContextAgent.swift:97`),仅当 `updatedWorkspaceIds`/`failures` 非空时回调,避免空轮询唤醒 main。coordinator `handleContextAgentBatch(_:)`(`[weak self]`,@MainActor 跳转)接收。
- [x] Inspector 批次可观测(DEBUG):新增 `ContextAgentBatchTelemetry`(occurredAt/updatedWorkspaceIds/failureCount/triggeredRecompute/recomputeDurationMs)+ inspector「Last Context Batch」区块。Phase 0 只记录 `triggeredRecompute=false`(不触发重算 ⇒ 无行为变化);Phase 1 把它翻成 true 并填耗时。
- [x] **回放 harness/fixtures 已存在**(上个 session,commit `fd2c9eb35`),无需新建:`cmuxTests/Fixtures/ContextAgent/agent_waiting_user.eventlog.jsonl`、`multi_status.eventlog.jsonl`;loader `loadContextAgentReplayFixture`、provider `ReplayWorkspaceSnapshotProvider`(`WindowAndDragTests.swift:2673/2963`);测试 `testReplayProducesWaitingUserSnapshotAndSuggestion`(:1238)、`testReplayProducesCoreProactiveSuggestionAndRankingScenarios`(:1261)。**注意**:这些测的是「回放→snapshot→`SuggestionEngine.generate`」的各部件,**不**覆盖闭环(onBatch→coordinator.`visibleSuggestions` 关闭态)——闭环测试是 Phase 1 要补的。

**完成门槛**:开关 off 时无差异(✅,无消费方);Inspector 能看到批次(✅);harness 已能确定性回放(✅,既有)。建议构建:`reload.sh --tag proactive-sprite`。

---

## Phase 1 — 闭合反馈环(keystone,唯一的 must-have)

> 修断点 ①②③。完成这一 Phase,「世界变了 → suggestion 重算」就成立,精灵**打开时**会实时跟着上下文变;这是后续所有主动呈现的前置。

### 1a. 让 `ContextAgent` 把批次结果交出来(断点①)✅
- [x] `Sources/SpriteAssistant/ContextAgent.swift`:`handleAndDrain` 改为捕获 `runScheduledBatch` 结果,仅当 `updatedWorkspaceIds`/`failures` 非空时回调(避免空轮询唤醒 main)。
- [x] `startEventStream(onBatch:)` 增加 `(@Sendable (ContextAgentBatchResult) async -> Void)? = nil` 参数,贯穿两个 detached 循环;默认 nil → 旧行为不变。(已在 Phase 0 落地)

### 1b. coordinator 订阅批次并重算(断点②③)✅
- [x] `handleContextAgentBatch(_:)`:flag(`ProactiveSpriteSuggestionsSettings.isEnabled()`)+ `updatedWorkspaceIds` 非空时 → `scheduleProactiveSuggestionRecompute()`。
- [x] 去抖/合并:`scheduleProactiveSuggestionRecompute` 用「首事件起一个 250ms trailing 窗口,窗口内后续事件只翻 `pending`(不重排,杜绝事件流饿死)」。DEBUG 可用 `debugProactiveSuggestionRecomputeDebounceOverrideNanos` 置 0 做确定性测试。
- [x] **数据源决策**:事件驱动重算读 **store**(`workspaceSnapshotStore.assistantWorkingContext().snapshots`),不是 live。理由:matches plan「assistant 只读 ContextAgent 维护的 snapshot」+ 可测(种子 store 即可)。`attach()`(面板打开)仍读 live 做即时刷新;store 随采集补齐,两者收敛。**已知小分歧**:store 是采集到的子集,首次 attach 时可能比 live 少(未采集的 workspace);Phase 2 上 badge 前再决定是否让 attach 也读 store 以完全统一。
- [x] 重算后写 `visibleSuggestions`(复用 `activeSuggestions(snapshots:)` 既有 `visibleSuggestions != suggestions` diff 守卫,无变化不写 `@Published` → 防自旋)+ publish 到 `suggestionSnapshotStore`。DEBUG 记录重算耗时到 `lastBatchTelemetry.recomputeDurationMs` + `triggeredRecompute`。
- [ ] **(延后到 Phase 4)** 同步刷新 ranking(`latestRanking(publish:true)`)—— NextWorkspace 才用,Phase 1 不需要,避免每次批次多算一次排序。

### 1c. 去重一致性 —— ⚠️ 决策需重新确认(新证据)
- [x] **调查结论**:coordinator 本地 `dismissedSuggestionIds`(`Set<UUID>`)的 UUID **就是** `StableSnapshotIdentifier.uuid(workspaceId+type+contextHash)`,与 `SuggestionStore` 的 `SuggestionIdentity{workspaceId,type,contextHash}` **语义完全等价**(dismiss 后同 contextHash 不复现、contextHash 变了复现)。`activeSuggestions` 已对事件驱动重算同样应用该过滤,所以**闭环不会把刚 dismiss 的建议弹回来——无需收敛即正确**。
- [ ] **待确认**:切到 `generateAndStore`+`SuggestionStore` 是**零行为变化的纯架构收敛**,且会把多个同步 socket 路径(`socketAcceptSuggestion`/`socketDismissSuggestion`/`activeSuggestionForAction`)改成 async(侵入大、风险高)。**建议:本 sprint 跳过,留作独立 cleanup PR**;或保留等价的本地集合。**请拍板**。

### 测试(行为级,L2/L3)
- [x] **闭环(红/绿核心)**:`cmuxTests/ProactiveSpriteSuggestionLoopTests.swift` —— 种子 store 一个 `waiting_user` snapshot → `handleContextAgentBatch` → `debugAwaitProactiveSuggestionRecompute()` → 断言 flag on 时 `visibleSuggestions` 出现 `review_agent_waiting_user`(面板未 attach);flag off 时不出现。已接 pbxproj 4 处 + `lint-pbxproj-test-wiring.sh` 通过(132 files)。
- [ ] **去抖 / diff 守卫 / dismiss 生命周期** 显式单测:**延后**(diff 守卫由既有代码保证;去抖逻辑已实现,补显式计数测试留到后续)。
- [ ] **两提交红/绿**:目前用 gstep(step-2 = Phase-0 no-op handler = 红;step-3 = 本实现 = 绿)。git commit 时再正式拆成两 commit。测试由用户手动跑。

**完成门槛**:flag on 时面板关闭也能让 `visibleSuggestions` 反映正确 suggestion(✅ 实现+测试);flag off 退回旧行为(✅);构建绿(进行中)。

---

## Phase 2 — 精灵主动呈现(mascot 徽章 + 可选自动气泡)★ 直接回答用户的问题

> 修断点④的「精灵这条线」。这是「系统精灵主动来提示」最忠实的形态:**不强制打开整个面板**,而是让收起的精灵自己冒出来提示。

分两档,默认从最不打扰的开始:

### Tier 1(开关 on 后默认):mascot 注意力徽章 ✅
- [x] 收起的浮动 mascot 上叠加角标(`SortAssistantMascotButton.attentionBadgeCount`,红色 capsule,>9 显示 `9+`,`allowsHitTesting(false)`,accessibilityId `SortAssistantMascotAttentionBadge`)。
- [x] **纯派生** `SortAssistantCoordinator.proactiveAttentionCount`:flag on 且 `visibleSuggestions` 里类型 ∈ {review/ci/merge} 且 `confidence ≥ proactiveBadgeConfidenceFloor`(0.85)的计数;flag off → 0。不在 view body 写状态(只读派生)。`FloatingHost.mascot` 把它传进按钮。
- [x] 点击徽章 = 点击落到下方 mascot 按钮 → 现有 `toggleConversationBubble`/openEntry 路径(徽章本身不拦截点击)。
- [x] 阈值常量集中在 coordinator:`proactiveBadgeConfidenceFloor=0.85`、`proactiveAutoSurfaceConfidenceFloor=0.90`(Tier 2 用)。

### Tier 2(opt-in,默认 off):新建议自动气泡 — ⏳ 未做(下一步)
- [ ] 当出现**新的**高置信度 suggestion(`confidence ≥ 0.90`,按 `SuggestionIdentity` 去重、且非本会话刚产生的 sort_preview/applied)时,自动以**紧凑 speech bubble**(非完整面板)呈现 top1,带 Open / Dismiss。
- [ ] 需新增**独立子开关**(默认 off);约束:**non-activating**(不抢焦点);**限频**(同一 workspace/type 冷却窗口);**自动消失**(超时);用户正在输入 / 面板已开时**不打断**。
- [ ] 复用 Phase 1 同一 model 状态;位置/mini 判定遵守精灵浮动护栏(`NSScreen.visibleFrame`)。

### 测试
- [x] **行为**:`ProactiveSpriteSuggestionLoopTests` 已断言 flag on 后 `proactiveAttentionCount ≥ 1`、flag off → 0。
- [ ] **组件 snapshot**:mascot 带徽章 / 不带徽章;紧凑气泡(Tier 2 时)。**延后**(无 swift-snapshot-testing 依赖时先靠 accessibilityId + 行为断言)。
- [ ] (可选)XCUITest:注入 waiting_user → 断言 `SortAssistantMascotAttentionBadge` 出现且**未**自动激活 app。**延后**。

**完成门槛**:关闭面板时高优建议让精灵显形(徽章 ✅);不抢焦点(徽章 `allowsHitTesting(false)`,点击走既有路径 ✅);Tier 2 自动气泡 ⏳。

---

## Phase 3 — 侧栏 suggestion 徽章 ✅

> 让「该看哪个 workspace」直接长在侧栏行上,即使精灵完全没出现也能看到。

- [x] 侧栏 workspace row 叠加由 suggestion 驱动的徽章(三类各一图标:review=`exclamationmark.bubble.fill`、ci=`xmark.octagon.fill`、merge=`checkmark.seal.fill`),capsule chip,模仿 `summaryScoreBadgeView`。
- [x] **快照边界**:`SortAssistantCoordinator.proactiveBadgeByWorkspaceId()` 返回 app-module 值类型 `WorkspaceProactiveSuggestionBadge`,在 `VerticalTabsSidebar.body` 边界算好(`proactiveSuggestionBadgeById`),塞进 `WorkspaceListRenderContext` → 按 `tab.id` 取值 → 作为不可变 `let` 传入 `TabItemView`,**并加入 `==`**。row 内部不读 store。`VerticalTabsSidebar` 加 `@ObservedObject SortAssistantCoordinator.shared` 让 body 在 `visibleSuggestions` 变化时重算(row 因 `.equatable()` 不变则不重渲)。
- [x] 去重:一 workspace 一徽章,类型优先级 review(3) > ci(2) > merge(1),同级比 confidence。**已知小重叠**:`fix_ci_failure` 与已有 `ghpr.ci` 可能并存(ghpr badge 在 PR 区,proactive badge 在 title 行)——接受,后续可在边界把 ghpr.ci присутствие 也下传做抑制。
- [x] 点击行选中 workspace(走现有行点击路径;徽章是被动 chip)。

### 测试
- [x] **行为**:`proactiveBadgeByWorkspaceId()[id]?.type == review_agent_waiting_user`(flag on)、`.isEmpty`(flag off)已断言。
- [ ] 组件 snapshot(四态)/ 自旋守卫显式测试:**延后**(rows 受 `.equatable()` 保护;边界 map 仅在 coordinator 变化时重建)。

**完成门槛**:侧栏徽章随事件驱动重算更新(✅);快照边界遵守(✅,值+闭包注入);默认 off 时 map 为空(✅)。

---

## Phase 4 — NextWorkspace 命令 + 通知通道 ✅

- [x] **NextWorkspace**:`SortAssistantCoordinator.nextWorkspaceByAttention()`(flag-gated)用 `buildAssistantWorkingContext`(内联算 ranking)→ `NextWorkspaceService.default.nextWorkspace(in:)`。命令面板新增 `palette.spriteNextWorkspace`「Go to Next Workspace (by Attention)」+ register handler(flag 守卫,选中目标 workspace,无目标 `NSSound.beep()`)。**仅命令面板,不加快捷键**(未在 `commandPaletteShortcutAction` 映射 → 无 shortcut hint,合规)。
- [x] **OS 通知通道**(默认 off,sub-flag `ProactiveSuggestionNotificationsSettings`):在 `runProactiveSuggestionRecompute` 末尾 `maybeNotifyProactiveSuggestions` —— flag on + `!AppFocusState.isAppActive()`(后台)+ confidence ≥ 0.90 + 类型 ∈ 三类 + 未通知过 → `TerminalNotificationStore.shared.addNotification(source: .monitor, cooldownKey: "sprite.proactive.<id>", cooldownInterval: 300)`。去重 `notifiedProactiveSuggestionIds`(prune 到当前集合);focus-safe(只发横幅,不激活 app)。
- [x] **Mutation 一致性**:新呈现面只做「打开面板」(`openEntry`,用户驱动)——不直接 mutate workspace;accept/dismiss 仍走既有经 `SemanticActionGateway` 的 socket 路径,未新增绕过路径。

### 测试
- [ ] NextWorkspace:`NextWorkspaceService` 选择/锁定/wraparound 已有 `WindowAndDragTests`(:1444-1494)+ 包级测试覆盖;coordinator 薄包装需 TabManager,**延后**。
- [ ] 通知:firing/dedup 经 `AppFocusState.overrideIsFocused` + cooldown 可测,**延后**(默认 off,逻辑简单)。

**完成门槛**:「下一个该看哪个」命令面板可点(✅);通知默认 off、后台触发、去重限频、不抢焦点(✅)。

---

## 横切:测试策略(对齐 activate-plan.md L0–L6)

| 层 | 本 sprint 覆盖 |
|---|---|
| L1 纯单元 | SuggestionEngine 三类映射(已有可补)、去抖窗口、diff 守卫、NextWorkspace 选择 |
| L2 actor 集成 | ContextAgent 批次 → coordinator 重算的回调链 |
| L3 replay | 三个 event-log fixture → 关闭态下产生正确 suggestion |
| L5 XCUITest | (可选)注入事件 → mascot 徽章 / 侧栏徽章出现且不抢焦点 |
| L6 视觉回归 | mascot 徽章、紧凑气泡、侧栏 row 四态 组件 snapshot |

- 所有 fixture 不触网、不调真 LLM、固定时间。
- 回归测试两提交红/绿;新测试文件写 pbxproj 四处条目。
- 测试由用户手动跑(遵守全局 CLAUDE.md)。

---

## 已确认的决策(2026-05-29)

1. **Tier 2 自动弹气泡**:**做,但默认 off**。仍然实现,藏在开关后;开箱靠 mascot 徽章 + 侧栏徽章。
2. **Phase 优先级**:Phase 1(闭环)→ **Phase 2(精灵显形)** → **Phase 3(侧栏徽章)** → Phase 4。
3. **去重收敛(1c)**:原定切到 `generateAndStore` + `SuggestionStore`,但实现期发现本地 `dismissedSuggestionIds`(键=稳定 suggestion id)与 `SuggestionStore.SuggestionIdentity` **语义完全等价**,闭环已正确过滤 dismissed;收敛是**零行为变化**却要把多个同步 socket 路径改 async(侵入大)。→ **本 sprint 跳过**,留作独立 cleanup PR。详见 Phase 1 §1c。
4. **通知通道(Phase 4)**:**做**,默认 off,去重 + 限频 + 经 Gateway。
5. **置信度阈值**(我定):引擎给的是 `confidence = max(0.85, userAttentionNeeded)`,故三类建议天然 ≥ 0.85。采用两档常量:
   - `proactiveBadgeConfidenceFloor = 0.85` —— mascot 徽章 + 侧栏徽章:展示**全部三类可执行建议**(0.85 即「存在该类建议」)。
   - `proactiveAutoSurfaceConfidenceFloor = 0.90` —— Tier 2 自动气泡 + Phase 4 通知:只对 `userAttentionNeeded ≥ 0.90` 的高注意力项主动打扰。
   - 两者集中定义为可调常量(后续可进 `cmux.json`),不要散落魔数。

---

## 范围外 / 风险

- **原生状态检测不在本 sprint**:`derived.status` 变成 `waiting_user`/`ci_failed`/`ready_to_merge` **依赖外部** 通过 `set_status` socket 命令写入(ghpr MCP/CLI、DigestCLI);app 自身不轮询 GitHub。本 sprint 假设这些信号已被外部产出;**如果外部不写,精灵就没东西可提示**——这是最大外部依赖,需先确认 dogfood 环境里这些状态确实在产生(可用 Inspector 验证 snapshot.derived.status)。
- `enqueueDueProviderRefreshes`(间隔刷新)目前是死代码:本 sprint 是**事件驱动**触发就够;若发现某些状态变化不产生事件(纯时间相关,如 CI 跑完),再单独评估是否启用周期 tick(独立小改动,不阻塞本 sprint)。
- 自动气泡的打扰度是产品风险:务必限频 + non-activating + 可一键关。

---

## 建议的 PR / commit 顺序

```
PR 1  Phase 0:特性开关 + Inspector 批次可观测 + replay harness/fixtures(无行为变化)
PR 2  Phase 1:闭合反馈环(批次回调 → 去抖 → 事件驱动重算)+ 去重收敛 + L2/L3 测试   ← keystone
PR 3  Phase 2:mascot 徽章(Tier 1)+ 组件 snapshot;(可选)Tier 2 自动气泡
PR 4  Phase 3:侧栏 suggestion 徽章(严守快照边界)+ snapshot + 自旋守卫
PR 5  Phase 4:NextWorkspace 生产接线 +(可选)通知通道
```

> 只要 PR 2 合入,精灵在**打开状态**就已经是「跟着上下文实时变」;PR 3 起才真正「主动显形」。
