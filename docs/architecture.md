# cmux 项目架构分析

## Context

cmux 是一款原生 macOS 终端应用，基于 Ghostty 终端引擎构建，提供垂直标签页、分屏、内置浏览器、通知系统，以及面向 AI 编程代理的 CLI/Socket API。本文档分析其整体架构、数据流和核心原理。

---

## 一、整体架构总览

```
┌─────────────────────────────────────────────────────────────┐
│                      cmux 应用 (macOS)                       │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │  SwiftUI 层   │  │  AppKit 层    │  │  Ghostty C 引擎   │  │
│  │ (声明式 UI)   │  │ (系统集成)    │  │ (终端渲染)        │  │
│  └──────┬───────┘  └──────┬───────┘  └───────┬───────────┘  │
│         │                 │                   │              │
│         └────────┬────────┘                   │              │
│                  ▼                            │              │
│  ┌───────────────────────────┐               │              │
│  │      Panel 抽象层          │◄──────────────┘              │
│  │ Terminal / Browser / MD   │                              │
│  └──────────┬────────────────┘                              │
│             ▼                                               │
│  ┌───────────────────────────┐                              │
│  │   Bonsplit (分屏管理)      │                              │
│  │   Pane ←→ Tab ←→ Panel    │                              │
│  └──────────┬────────────────┘                              │
│             ▼                                               │
│  ┌───────────────────────────┐                              │
│  │   Workspace (工作区模型)   │                              │
│  └──────────┬────────────────┘                              │
│             ▼                                               │
│  ┌───────────────────────────┐                              │
│  │   TabManager (全局状态)    │                              │
│  └───────────────────────────┘                              │
│                                                             │
│  ┌─────────────────────┐  ┌──────────────────────────────┐  │
│  │  Socket Server       │  │  CLI (cmux 命令行)            │  │
│  │  (Unix Domain Socket)│◄─┤  通过 socket 与 app 通信      │  │
│  └─────────────────────┘  └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、核心模块与数据流

### 2.1 应用启动流程

```
cmuxApp (@main SwiftUI App)
    │
    ├─► 初始化 TabManager (全局工作区管理器)
    ├─► 初始化 TerminalNotificationStore (通知中心)
    ├─► 初始化 SidebarState / SidebarSelectionState
    ├─► 配置 Ghostty 环境变量与资源路径
    ├─► 启动 AppDelegate (AppKit 系统集成)
    │       ├─► 键盘事件监听 (NSEvent monitor)
    │       ├─► 窗口管理 & 焦点控制
    │       └─► Sparkle 更新检查
    └─► 启动 TerminalController (Socket 服务器)
            └─► 监听 Unix socket (/tmp/cmux-*.sock)
```

### 2.2 数据模型层级

```
TabManager (全局单例, ObservableObject)
│
├── tabs: [Workspace]              ← 所有工作区
├── selectedTabId: UUID?           ← 当前选中工作区
├── selectionHistory: [UUID]       ← 选择历史 (前进/后退)
│
└── Workspace (单个工作区)
    │
    ├── bonsplitController: BonsplitController  ← 分屏布局树
    │   │
    │   └── Pane (面板容器)
    │       └── Tab[] (标签页)
    │           └── Panel (内容抽象)
    │               ├── TerminalPanel  → GhosttyTerminalView
    │               ├── BrowserPanel   → WKWebView
    │               └── MarkdownPanel  → MarkdownUI
    │
    ├── panels: [UUID: Panel]        ← 所有面板实例
    ├── customTitle / currentDirectory / gitBranch
    ├── statusEntries / logEntries / metadataBlocks
    └── notifications / progress / ports
```

### 2.3 终端渲染管线

```
用户键盘输入
    │
    ▼
AppDelegate.performKeyEquivalent()
    │  (快捷键拦截 & 路由)
    ▼
NSEvent → GhosttyTerminalView
    │
    ▼
ghostty_surface_key()  ← Ghostty C API
    │
    ▼
libghostty (Zig 编译)
    ├── VT 解析器 (终端转义序列解析)
    ├── 终端状态机 (Grid/Cell/Cursor)
    └── GPU 渲染器 (Metal)
         │
         ▼
    屏幕帧输出 → TerminalSurface (NSView)
                    │
                    ▼
              TerminalWindowPortal (AppKit 宿主)
                    │
                    ▼
              SwiftUI ContentView (布局容器)
```

### 2.4 Socket/IPC 通信架构

```
外部进程 (AI Agent / CLI 工具)
    │
    ▼
cmux CLI (/usr/local/bin/cmux)
    │
    ▼  Unix Domain Socket 连接
    │  (/tmp/cmux-socket 或 /tmp/cmux-debug-<tag>.sock)
    │
    ▼
TerminalController (Socket Server)
    │
    ├── V1 协议: 空格分隔文本命令
    │   例: "new_workspace", "send hello\n", "focus_window"
    │
    └── V2 协议: JSON 结构化命令 + Handle 引用
        例: {"command":"workspace.list"} → [{"handle":"w1",...}]
        例: {"command":"surface.send","handle":"s1","text":"ls\n"}
    │
    ▼  命令路由
    │
    ├── 高频遥测命令 → 后台线程处理 (off-main)
    │   report_*, ports_kick, status/progress/log
    │
    └── UI 操作命令 → DispatchQueue.main.async
        focus, select, open, close, send_key
```

**Socket 命令分类:**

| 类别 | 命令示例 | 线程策略 |
|------|---------|---------|
| 窗口管理 | list_windows, focus_window | Main |
| 工作区 | new_workspace, select_workspace, close_workspace | Main |
| 输入控制 | send, send_key, send_surface | Main |
| 通知 | notify, list_notifications, clear_notifications | Main |
| 元数据 | set_status, report_meta, log, set_progress | Off-main |
| Git/PR | report_git_branch, report_pr | Off-main |
| 端口 | report_ports, ports_kick | Off-main |
| 浏览器 | JS eval, element selection | Main |

---

## 三、分屏系统 (Bonsplit)

```
BonsplitController
    │
    └── 二叉分屏树
        │
        ┌───────┴───────┐
        │               │
      Pane A          Split
      (终端)         /     \
                  Pane B   Pane C
                 (浏览器)  (终端)

每个 Pane 包含 Tab 数组:
  Pane A: [Tab1(Terminal), Tab2(Browser)]
  Pane B: [Tab1(Browser)]

分屏操作:
  splitPane(direction: .horizontal/.vertical)
  closePane()
  focusPane()
  moveTab(between panes)
```

**Workspace 实现 BonsplitControllerDelegate:**
- `didSplitPane` → 自动创建终端面板
- `didClosePane` → 清理面板实例
- `didSelectTab` → 切换面板焦点
- `didMoveTab` → 面板跨窗格拖放
- `didFocusPane` → 更新焦点状态
- `didChangeGeometry` → 布局尺寸变化

---

## 四、UI 渲染架构

```
┌─────────────────────────────────────────────────┐
│                  NSWindow                        │
│  ┌─────────────────────────────────────────────┐│
│  │        ContentView (SwiftUI Root)           ││
│  │  ┌──────────┬──────────────────────────┐    ││
│  │  │ Sidebar  │   WorkspaceContentView   │    ││
│  │  │          │                          │    ││
│  │  │ [WS 1]  │  ┌─────────┬──────────┐  │    ││
│  │  │ [WS 2]◄─┤  │ Pane A  │ Pane B   │  │    ││
│  │  │ [WS 3]  │  │         │          │  │    ││
│  │  │          │  │ Terminal│ Browser  │  │    ││
│  │  │  状态    │  │ Portal  │ Portal   │  │    ││
│  │  │  元数据  │  │ (AppKit)│ (AppKit) │  │    ││
│  │  │  端口    │  │         │          │  │    ││
│  │  └──────────┴──┴─────────┴──────────┘  │    ││
│  └─────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────┐│
│  │  SurfaceSearchOverlay (终端搜索浮层)         ││
│  └─────────────────────────────────────────────┘│
└─────────────────────────────────────────────────┘

渲染策略:
  SwiftUI  → 声明式布局 (Sidebar, 标签页, 工具栏)
  AppKit   → Portal 宿主 (终端 NSView, WKWebView)
  Metal    → Ghostty GPU 终端渲染
```

**性能关键路径 (打字延迟敏感):**
- `WindowTerminalHostView.hitTest()` — 每个事件都调用，仅处理指针事件
- `TabItemView` — 使用 `.equatable()` 跳过打字时的 body 重建
- `TerminalSurface.forceRefresh()` — 每次按键调用，禁止分配/IO

---

## 五、外部集成

### 5.1 子模块依赖

```
cmux (主仓库)
├── ghostty/        → manaflow-ai/ghostty (终端引擎 fork)
│   └── 编译: zig build → GhosttyKit.xcframework
├── vendor/bonsplit → manaflow-ai/bonsplit (分屏框架)
│   └── Swift Package, 提供 BonsplitView/Controller
└── homebrew-cmux/  → Homebrew 分发
```

### 5.2 Swift 包依赖

| 依赖 | 用途 |
|------|------|
| GhosttyKit.xcframework | Ghostty C 终端引擎绑定 |
| Sparkle | macOS 自动更新 |
| Sentry | 错误追踪与遥测 |
| PostHog | 产品分析 |
| MarkdownUI | Markdown 面板渲染 |
| SwiftTerm | 终端辅助工具 |

### 5.3 CLI 与 Daemon

```
cmux CLI (Swift, 编译为独立二进制)
    │
    ├── 连接 Unix Socket → 发送命令 → 接收响应
    ├── Sentry 遥测集成
    └── 支持 V1 / V2 双协议

cmuxd (Zig 编译的守护进程)
    └── 后台服务，辅助 cmux 应用
        编译: cd cmuxd && zig build -Doptimize=ReleaseFast
```

---

## 六、关键设计原则

1. **Panel 抽象** — Terminal/Browser/Markdown 统一为 Panel 协议，可在任意 Pane 中混排
2. **AppKit Portal 模式** — 高性能内容 (终端/浏览器) 使用 AppKit NSView 托管，避免 SwiftUI 渲染开销
3. **Socket-first 设计** — 所有 UI 操作均可通过 Socket API 远程控制，面向 AI Agent 场景优化
4. **Off-main 遥测** — 高频状态上报在后台线程处理，仅必要 UI 更新调度到主线程
5. **二叉分屏树** — Bonsplit 用二叉树管理分屏布局，支持任意嵌套和动态调整
6. **焦点隔离** — Socket 命令默认不抢占 macOS 应用焦点，仅显式焦点命令可改变焦点
7. **Tagged Build 隔离** — 开发构建通过 tag 隔离 Bundle ID / Socket / DerivedData，支持多实例并行

---

## 七、完整数据流: 用户输入到屏幕输出

```
┌──────────┐    ┌───────────┐    ┌──────────────┐    ┌──────────┐
│ 键盘输入  │───▶│AppDelegate│───▶│ Ghostty C API│───▶│ VT 解析  │
│ (NSEvent) │    │ 事件路由   │    │ surface_key  │    │ 转义序列 │
└──────────┘    └───────────┘    └──────────────┘    └────┬─────┘
                                                          │
┌──────────┐    ┌───────────┐    ┌──────────────┐    ┌────▼─────┐
│ 屏幕显示  │◄───│ Metal GPU │◄───│ 渲染器       │◄───│ 终端状态 │
│ (NSView)  │    │ 绘制      │    │ 字形/颜色    │    │ Grid/Cell│
└──────────┘    └───────────┘    └──────────────┘    └──────────┘
```

```
┌──────────┐    ┌───────────┐    ┌──────────────┐    ┌──────────┐
│ CLI 命令  │───▶│ Socket    │───▶│ Terminal     │───▶│ TabMgr / │
│ cmux send │    │ 连接      │    │ Controller   │    │ Workspace│
└──────────┘    └───────────┘    │ 命令路由      │    │ 状态更新 │
                                 └──────────────┘    └──────────┘
```

---

## 八、核心文件索引

| 文件 | 大小 | 职责 |
|------|------|------|
| `Sources/cmuxApp.swift` | 238KB | 应用入口，状态初始化 |
| `Sources/AppDelegate.swift` | 470KB | AppKit 系统集成，键盘路由 |
| `Sources/ContentView.swift` | 525KB | 主 UI 布局 (侧边栏 + 内容) |
| `Sources/TerminalController.swift` | 608KB | Socket 服务器，命令处理 |
| `Sources/TabManager.swift` | 179KB | 工作区全局管理器 |
| `Sources/Workspace.swift` | 214KB | 工作区数据模型 |
| `Sources/GhosttyTerminalView.swift` | 359KB | Ghostty 终端视图集成 |
| `Sources/BrowserPanelView.swift` | 244KB | 浏览器面板视图 |
| `Sources/BrowserPanel.swift` | 196KB | 浏览器面板逻辑 |
| `Sources/BrowserWindowPortal.swift` | 152KB | 浏览器 AppKit 宿主 |
| `Sources/Panels/Panel.swift` | - | Panel 协议定义 |
| `CLI/cmux.swift` | 413KB | CLI 命令行客户端 |

---

## 九、与 tmux 的对比及改进建议

### 9.1 cmux vs tmux 功能对比

| 功能 | tmux | cmux 现状 | 差距 |
|------|------|-----------|------|
| 分屏 | ✅ prefix + %/" | ✅ Cmd+D / Cmd+Shift+D | 无 prefix 模式 |
| 会话持久化 | ✅ 服务端进程存活 | ⚠️ 应用重启可恢复布局+滚动历史 | 进程不存活 |
| 远程 attach | ✅ ssh + tmux attach | ❌ 仅本地 Unix socket | 无远程能力 |
| 会话命名 | ✅ rename-session | ✅ customTitle (Cmd+Shift+R) | 已有 |
| 窗口分组/tag | ❌ 无 | ❌ 无 | 两者都缺 |
| 脚本化 | ✅ tmux send-keys | ✅ Socket API v1/v2 | cmux 更强 |
| 浏览器集成 | ❌ 无 | ✅ 内置 WKWebView | cmux 独有 |
| GPU 渲染 | ❌ 无 | ✅ Metal | cmux 独有 |

### 9.2 改进方案

#### 方案 A: tmux 风格 Leader Key 模式

**问题:** 当前所有快捷键都是 Cmd+X 直接触发，无法像 tmux 的 `Ctrl-B → %` 那样用 prefix 序列快速操作。

**建议实现:**

```
新增 Leader Key 系统:

用户按下 Leader Key (如 Ctrl+B 或自定义)
    │
    ▼
进入 "Leader 模式" (短暂等待第二键, 如 500ms)
    │
    ├── %  → splitRight   (水平分屏)
    ├── "  → splitDown    (垂直分屏)
    ├── o  → focusNext    (切换焦点到下一窗格)
    ├── x  → closePane    (关闭当前窗格)
    ├── c  → newWorkspace (新建工作区)
    ├── n  → nextWorkspace
    ├── p  → prevWorkspace
    ├── ,  → renameWorkspace
    ├── z  → toggleZoom   (最大化/还原窗格)
    ├── [  → scrollMode   (滚动模式)
    └── ESC/超时 → 退出 Leader 模式
```

**涉及文件:**
- `Sources/KeyboardShortcutSettings.swift` — 添加 leader key 配置项
- `Sources/AppDelegate.swift` — 在 `performKeyEquivalent()` 中实现两阶段按键状态机
- `Sources/ContentView.swift` — 添加 Leader 模式视觉指示 (如底部状态栏闪烁)

#### 方案 B: 工作区快速 Tag 标记

**问题:** 动态标题 (CWD/shell PS1) 经常变化，多个工作区难以快速定位。需要一个用户设定的固定前缀 tag。

**交互设计:**

```
Leader Key + ,  → 弹出输入框，设置当前工作区的 tag
                  (类似 tmux 的 prefix + , 重命名窗口)

侧边栏显示效果:
┌────────────────────────┐
│ [api] ~/projects/back  │  ← tag "api" 固定显示在动态标题前
│ [fe]  ~/projects/front │  ← tag "fe"
│       ~/random-stuff   │  ← 无 tag，正常显示
└────────────────────────┘

tag 特点:
  - 短文本 (建议 2-6 字符)
  - 固定不变，不受 shell CWD/title 影响
  - 持久化保存，重启恢复
  - 可通过 Leader+, 随时修改或清空
```

**数据模型变更:**
```swift
// Workspace.swift — 复用已有的 customTitle，或新增:
@Published var tag: String?   // 如 "api", "fe", "db"

// 与 customTitle 的区别:
//   customTitle → 完全替换动态标题
//   tag         → 作为前缀，动态标题仍然显示
```

**涉及文件:**
- `Sources/Workspace.swift` — 添加 `tag` 属性
- `Sources/ContentView.swift` — 侧边栏 TabItemView 渲染 `[tag] title` 格式
- `Sources/SessionPersistence.swift` — 持久化 tag 字段
- `Sources/AppDelegate.swift` — Leader Key 状态机中添加 `,` → 设置 tag
- `Sources/TerminalController.swift` — Socket API 添加 `workspace.set_tag`
- `CLI/cmux.swift` — CLI 添加 `cmux tag <name>` 子命令

#### 方案 C: 增强 cmux 作为 tmux 替代的能力

**已有能力（无需改进）:**
- ✅ 会话持久化 — 重启恢复布局 + 4000 行滚动历史
- ✅ 工作区命名 — `Cmd+Shift+R` 或 socket `rename_workspace`
- ✅ 分屏操作 — 完整的 split/focus/close/zoom 支持
- ✅ 脚本化 — Socket API 比 tmux 更强大

**建议优先级排序:**

| 优先级 | 改进项 | 影响 | 复杂度 |
|--------|--------|------|--------|
| P0 | Leader Key 模式 | 大幅提升分屏操作效率 | 中 |
| P0 | 工作区快速 Tag 标记 | 固定前缀快速定位工作区 | 低 |
| P1 | 预设布局模板 | 一键创建常用分屏布局 | 低 |
| P2 | 远程 attach (via SSH tunnel) | 替代 tmux 远程场景 | 高 |

---

## 十、验证方式

- 架构分析：基于源码阅读，可通过 `git log --oneline -20` 验证近期变更方向
- Leader Key：实现后通过 `./scripts/reload.sh --tag leader-key` 构建测试
- Tag 分组：实现后通过 Socket API 测试 `workspace.set_tags` 命令
- 持久化：重启应用后验证 tag 数据恢复
