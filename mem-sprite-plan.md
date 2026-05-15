# mem-sprite-plan: 记忆系统 + Sprite 小助手架构演进

> 目标：把当前 PR (`refactor/mem`) 里耦合在 `SortAssistantCoordinator` 里的"记忆 + 排序 + UI 入口"按职责拆开，演进成 **独立记忆系统 + 双能力 Sprite 小助手** 的架构。

> ⚠️ **范围约束（不要改）**：当前 sprite 的 **UI 实现已经满意**，不在本次演进范围内。具体包括：
> - `SortAssistantMascotView` / `SortAssistantMascotButton` / `SortAssistantMascotAvatar` / `SortAssistantMascotIntroView`（像素 sprite + `TimelineView` 帧动画 + `SpriteState` idle/hover/review）
> - `SortAssistantFloatingPanelWindow`（borderless `NSPanel` child window）的拖拽、定位、clamp、parent-window 跟随
> - 像素气泡相关 shape：`SortAssistantPixelPanelShape` / `SortAssistantBubbleTail` / `SortAssistantPetBubbleTail`
> - 入口三处：tab bar 按钮 / right sidebar 浮动 pet / `ExtensionColumnSortQuickPopover` 自定义目标
>
> 本计划只重构 **数据流、能力分层、记忆/排序后端、MCP 接入**；不调整像素风格、布局、动画曲线、拖拽手感、入口位置。

---

## 1. 产品定位

产品上是**一个**小助手（浮动 mascot + 像素气泡），但工程上有两个能力面：

```
小助手 (sprite)
├── 1. Context Provider 入口：整理记忆、采集偏好（输入端）
└── 2. Sort Operator 入口：通过 MCP 调后端，回答问题 + 操作排序（super-agent 大脑端）
```

核心原则：

```
LLM            负责理解意图、提取规则、生成排序计划
排序系统       负责计算、校验、应用、回滚
记忆系统       独立工作，为排序和回答提供上下文，沉淀偏好
Sprite        只做输入采集 + LLM 客户端，通过 MCP 调用后端能力
```

不要让 LLM "看上下文 + 决定排序 + 修改排序状态" 一条龙完成。

---

## 2. 三层分工

### 2.1 记忆系统（独立服务，read-only 给排序）

只回答："这次排序应该参考什么？"

```ts
type SortContext = {
  userIntent: string

  currentList: {
    listId: string
    revision: number
    visibleItemIds: string[]
    selectedItemIds?: string[]
    lockedItemIds?: string[]
    pinnedItemIds?: string[]
  }

  shortTermMemory: {
    recentMoves: Array<{
      itemId: string
      fromIndex: number
      toIndex: number
      reason?: string
    }>
    activeConstraints: string[]
    lastAssistantProposal?: string[]
  }

  longTermMemory: {
    userPreferences: string[]
    projectRules: string[]
    workspaceRules: string[]
  }

  itemSignals: Record<string, {
    title: string
    deadline?: string
    priority?: string
    status?: string
    assignee?: string
    customerImpact?: number
    blockedBy?: string[]
    tags?: string[]
  }>
}
```

记忆分两类：

- **Context memory**（显式偏好/规则）：用户偏好、项目规则、workspace 规则
- **Operation memory**（行为偏好）：从用户实际拖拽/接受/拒绝事件抽取出来的统计

### 2.2 排序系统（Sort Operator，write-capable）

LLM **不能直接覆盖最终 order**。LLM 输出意图 + 约束 + 打分，系统生成 patch 并执行。

```ts
type SortPatch = {
  listId: string
  baseRevision: number
  operations: SortOperation[]
  rationale?: string
  confidence?: number
  requiresConfirmation: boolean
}

type SortOperation =
  | { type: "move_before"; itemId: string; beforeItemId: string }
  | { type: "move_after"; itemId: string; afterItemId: string }
  | { type: "batch_reorder"; itemIds: string[]; preserveLockedItems: boolean }
  | { type: "pin"; itemId: string; position: "top" | "bottom" }
  | { type: "lock"; itemId: string }
  | { type: "group_by"; field: "project" | "priority" | "status" | "assignee" | "tag" }
```

LLM 推荐输出的是结构化打分意图，由 Swift 端 `SortRanker` 算出排序：

```json
{
  "goal": "prioritize_today_work",
  "signals": [
    { "name": "deadline", "weight": 0.3 },
    { "name": "customer_blocker", "weight": 0.35 },
    { "name": "project_mainline", "weight": 0.2 },
    { "name": "effort_small_win", "weight": 0.15 }
  ],
  "constraints": [
    "do_not_move_locked_items",
    "keep_pinned_items_at_top",
    "preserve_relative_order_when_score_ties"
  ]
}
```

Sort engine 必须做：

1. `baseRevision` 冲突检测
2. locked / pinned 硬约束校验
3. 隐藏 item 越权拦截
4. 生成 undo patch
5. 标记是否 `requiresConfirmation`

### 2.3 Router 系统

#### IntentRouter（用户想干什么）

```ts
type AssistantIntent =
  | "ask_context"            // “为什么这样排？”
  | "explain_current_order"
  | "propose_sort"           // 看建议但不应用
  | "apply_sort"             // 直接排
  | "manual_reorder_feedback" // 用户拖完之后给反馈
  | "remember_preference"
  | "forget_preference"
  | "undo_sort"
  | "normal_chat"
```

#### ActionRouter（能不能动）

```ts
type ActionRoute = {
  mode: "read_only" | "preview_only" | "apply_allowed"
  needsConfirmation: boolean
  allowedTools: string[]
  memoryWritePolicy: "none" | "event_log" | "candidate" | "long_term"
}
```

---

## 3. 三种交互模式

| 模式 | 触发 | 行为 |
|---|---|---|
| 解释模式 | "为什么这个排第一？" | 只读，读 order + 排序依据 + 相关记忆，生成解释 |
| 建议模式 | "怎么排更合理？" | 生成 SortPatch，UI 显示 preview，不写 |
| 执行模式 | "直接帮我排好" | 生成 SortPatch → engine.apply，写 EventLog + Undo |

UI 上 preview 提供：`[应用] [部分应用] [忽略] [解释更多]`

---

## 4. EventLog（patch / event sourcing）

自由排序里用户会拖拽、撤销、局部调整、锁定、接受/拒绝建议，所以不能只存 final order：

```
base order + operation log + materialized order
```

```ts
type SortEvent =
  | { type: "user_drag_move"; itemId; fromIndex; toIndex; listId; revision; timestamp }
  | { type: "assistant_patch_applied"; patchId; listId; revisionBefore; revisionAfter; rationale? }
  | { type: "assistant_patch_rejected"; patchId; reason? }
  | { type: "undo_applied"; undoPatchId }
```

EventLog 同时供：
- 状态恢复
- Operation memory 提取（行为偏好）

---

## 5. 当前 PR (`refactor/mem`) 现状映射

把现有代码放到上面分层里，标出**已经做的**和**缺的**。

### 5.1 Context Provider 层 — 已基本独立

| 分层位置 | 现状 |
|---|---|
| `longTermMemory.userPreferences` | ✅ `cmux.sort_memory.v1` 事件，存在 Workstream JSONL，`SortAssistantCoordinator.loadMemories(from:)` 启动时直接读文件 |
| `itemSignals` per workspace | ✅ digest pipeline 已在跑：`SurfaceDigest` / `AgentSessionDigest` / `GHPRPullRequestContext` / `GitFacts` |
| 注入排序 | ✅ `SummaryPriorityAssistantContext { requestId, goal, memorySnippets }` 沿 `DigestCLI/cmux-digest.swift` 传到维度打分 + 跨 workspace 校准 prompt |
| `shortTermMemory.recentMoves` | ❌ 只有内存里 `SortAssistantUndoSnapshot { order, titleById }`，重启即丢 |
| `projectRules` / `workspaceRules` | ❌ 没有，只有用户自由文本偏好 |
| `activeConstraints` / `lastAssistantProposal` | ❌ 没有 |
| ContextAssembler 接口 | ❌ 没抽出来，逻辑内联在 `SortAssistantCoordinator.startSort` 里 |

### 5.2 Sort Operator 层 — 命中反模式

当前链路：

```
LLM 给每个 workspace 打 dimension 分
→ WorkspaceTabStore.orderedWorkspaceIds(from:state, ...)
→ TabManager.reorderWorkspaces(to: ordered)   ← 全量覆盖
```

正是要避免的 "LLM 输出完整新顺序，系统直接覆盖" 模式。

缺的：

- ❌ `SortPatch` / `SortOperation` 中间层
- ❌ `baseRevision` 冲突检测
- ❌ locked / pinned 硬约束校验（prompt 里只是软约束）
- ❌ preview 模式 — "建议" 和 "执行" 同一条路径
- ⚠️ Undo 只有内存一帧 `SortAssistantUndoSnapshot`，重启丢
- ❌ 部分应用 / 拒绝
- ❌ `requiresConfirmation` 策略

### 5.3 Router 层

- ⚠️ IntentRouter：`looksLikeUndo / looksLikeRemember / looksLikeForget / looksLikeExplain` 手写正则覆盖一部分，fallthrough 全是 `startSort`
- ❌ ActionRouter / 权限策略：完全没有

### 5.4 Sprite 两个角色

- ✅ **输入整理端**：浮动 `SortAssistantFloatingPanelWindow` (borderless `NSPanel` child window) + 像素气泡 + memory candidate review (`SortAssistantMemoryCandidate` → `confirmMemoryCandidate`) 在做这件事
- ❌ **MCP super-agent 大脑端**：完全没有 MCP。当前 `SortAssistantCoordinator` 直接持有 `TabManager` / `WorkspaceTabStore` 引用，闭源直调

---

## 6. 演进路线（最小裂缝）

按依赖顺序，最小改动落地：

### Phase 1 — 解耦 Coordinator

把 `SortAssistantCoordinator` 一拆为二：

- `SortContextProvider`（read-only）：装配 `SortContext`，喂 prompt
- `SortOperator`（write）：接受 `SortPatch`，做 revision / lock / pin 校验，写 EventLog，吐 undo patch

`SortAssistantCoordinator` 退化为 UI 编排 + IntentRouter 入口。

### Phase 2 — 引入 SortPatch + engine.apply

- LLM 输出仍保留分数+约束，Swift 侧组装 `SortPatch`（至少先支持 `batch_reorder`）
- `SortEngine.applyPatch({ listId, patch, actor, createUndoPatch })` 单点 apply
- 替换掉现有 `TabManager.reorderWorkspaces(to: ordered)` 的直调

### Phase 3 — EventLog 持久化

- 复用现有 `CMUXWorkstream` JSONL，新增 `sort.event.v1` 事件类型（drag / patch_applied / patch_rejected / undo）
- 把内存里的 `SortAssistantUndoSnapshot` 升级成基于 EventLog 的 undo stack
- 给 operation memory 提取留好证据来源

### Phase 4 — Preview / Confirmation

- `SortEngine.preview(patch)` 不写状态，返回 affected items + rationale
- UI 三种模式落地：`[应用] [部分应用] [忽略] [解释更多]`
- `requiresConfirmation` 策略接入 ActionRouter

### Phase 5 — MCP 化（super-agent 大脑端）

把 Sort Operator + Context Provider 的关键函数暴露成 MCP tools：

- `memory.query` / `memory.write_candidate` / `memory.forget`
- `sort.context` / `sort.preview` / `sort.apply` / `sort.undo` / `sort.explain`
- `list.state` / `list.lock` / `list.pin`

Sprite 进入 super-agent 模式时改走 LLM tool call，不再直调 Swift 对象。这一步之后 sprite 才真正成为 "通过 MCP 操作排序" 的大脑端。

### Phase 6 — IntentRouter / ActionRouter LLM 化

- 用 LLM + 少量规则替换 `looksLike*` 正则
- ActionRouter 接入 lock / pin / hidden item 权限策略，并对 `apply_sort` 默认要求确认

---

## 7. 目录建议（落地时）

```
Sources/Sprite/
  Coordinator/
    SortAssistantCoordinator.swift   # UI 编排 + IntentRouter 入口
  Context/
    SortContextProvider.swift        # 只读，装配 SortContext
    ContextAssembler.swift
  Operator/
    SortPatch.swift
    SortEngine.swift                 # 校验 / preview / apply
    UndoStack.swift
  Router/
    IntentRouter.swift
    ActionRouter.swift
  Memory/
    MemoryWriter.swift               # 写候选 / 长期记忆
    MemoryReview.swift               # UI 审阅候选
  Mascot/                            # 🔒 锁定，不改
    SortAssistantMascotView.swift    # 现有 sprite 渲染（保持原样）
    SortAssistantFloatingPanel.swift # 现有浮动 NSPanel（保持原样）
  MCP/
    SpriteMCPServer.swift            # Phase 5
    Tools/
      MemoryTools.swift
      SortTools.swift
      ListTools.swift
```

---

## 8. 一句话总结

> 上下文助手负责"知道该怎么排"，操作助手负责"安全地把它排出来"。产品上合成一个 sprite 小助手，工程上必须分权：**记忆系统独立、排序系统独立、Sprite 通过 MCP 连接二者**。LLM 只生成意图和补丁，不直接覆盖状态。
