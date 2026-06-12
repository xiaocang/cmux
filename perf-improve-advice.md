# cmux Main-Thread Performance Analysis

Generated from `sample` profiles of the running cmux app (pid 748, v0.63.2 build 79, macOS 26.4.1, Apple Silicon).

- Sample 1 (idle baseline): `/tmp/cmux.sample.txt` — 5 s, no user interaction
- Sample 2 (heavy browser-pane use): `/tmp/cmux.browser.sample.txt` — 15 s, user actively interacting with browser panes

---

## Headline

**The dominant main-thread cost during interactive browser-pane use is *not* WebKit, *not* `BrowserWindowPortal` synchronization, and *not* SwiftUI re-layout. It is `TabManager` PR-refresh code shelling out to external commands synchronously on the main thread.**

The `BrowserWindowPortal` / `synchronizeWebView` path that we suspected first is essentially cold (`synchronizeWebView` had 3 hits, `synchronizeAllWebViews` had 0).

---

## Sample 2 — main-thread budget (15 s window)

```
total main-thread samples:  11665
DPSBlock idle:               8813    →  75.6 % idle
busy:                        2852    →  24.4 % busy  (~2852 ms of CPU on main thread)
```

### Top cmux symbols on the main thread (by sample count)

| samples | symbol | category |
|---:|---|---|
| 1705 | `TabManager.refreshTrackedWorkspacePullRequestsIfNeeded(reason:allowCachedResultsOverride:)` | PR refresh |
| 1704 | `TabManager.applyWorkspacePullRequestRefreshResults(...)` | PR refresh |
| 1700 | `TabManager.runCommandResult(directory:executable:arguments:timeout:)` | **synchronous external command on main thread** |
| 971 | `NSWindow.cmux_sendEvent(_:)` | mouse event entry |
| 843 | `WindowBrowserHostView.dividerHit(at:in:hostView:)` | browser-pane divider hit-test |
| 413 | `WindowTerminalHostView.dividerCursorKind(at:in:)` | terminal-pane divider hit-test |
| 412 | `NSWindow.cmuxTopHitViewForEvent(in:event:)` | hit-test routing |
| 187 | `OmnibarTextFieldRepresentable.Coordinator.controlTextDidChange(_:)` | address-bar typing |
| 184 | `closure #2 in closure #1 in BrowserPanelView.omnibarField.getter` | address-bar SwiftUI |
| 183 | `BrowserPanelView.refreshSuggestions()` | suggestions |
| 170 | `BrowserHistoryStore.suggestions(for:limit:)` | suggestion scan |
| 138 | `BrowserHistoryStore.suggestionScore(candidate:query:queryTokens:now:)` | full scoring |
| 128 | `WindowBrowserHostView.splitDividerHit(at:)` | hit-test |
| 119 | `WindowBrowserHostView.hitTest(_:)` | hit-test |
|  78 | `TabItemView.body.getter` | sidebar tab row body |
|  68 | `BrowserHistoryStore.suggestionScore` token-match closures | suggestion scoring |
|  63 | `WindowBrowserHostView.updateDividerCursor(...)` | hit-test follow-up |
|  46 | `WindowTerminalHostView.hitTest(_:)` | hit-test |
|  43 | `NSWindow.cmux_makeFirstResponder(_:)` | focus path |
|  31 | `BrowserHistoryStore.makeSuggestionCandidate(entry:)` | suggestion scoring |
|  30 | `CmuxWebView.performKeyEquivalent(with:)` | keyboard routing into web view |

### Aggregate of the three biggest categories

| category | ~main-thread samples | share of busy |
|---|---:|---:|
| **TabManager PR refresh (`runCommandResult` etc.)** | ~1705 | **~60 %** |
| **Mouse hit-testing (`cmux_sendEvent` + divider hit-test + cursor)** | ~1500 | ~26 % |
| **Browser omnibar suggestions (per keystroke)** | ~700 | ~12 % |

These three account for almost all of the 2852 ms of busy time.

### Keyword counts (Sample 2, full file)

```
BrowserWindowPortal              306
synchronizeWebView                 3   ← cold
synchronizeAllWebViews             0
WindowBrowserHostView            323
WebViewRepresentable              11
WKWebView                          6
WebKit                           133   (almost entirely on the IPC stream queue, off-main)
WebCore                           41
RemoteLayer                       24
hitTest                          941
layoutSubtree                    208
NSHostingView                    400
TabItemView                      115
GhosttyTerminalView                6
synchronizeGeometryAndContent      1
PortScanner                       18
workspacePullRequest              52
```

### Where WebKit work actually runs

In Sample 2, the entire WebKit IPC tree (`IPC::StreamConnectionWorkQueue::startProcessingThread`) runs on its own dedicated thread — **not on the cmux main thread**. The main thread only sees a handful of dispatched callbacks:

```
 19  RemoteLayerTreeDisplayLinkClient::displayLinkFired
 18  IPC::Connection::dispatchMessage / dispatchIncomingMessages
 13  RemoteLayerTreeDrawingAreaProxyMac::didRefreshDisplay
 10  RemoteScrollingCoordinatorProxyMac::displayDidRefresh
  9  WebPageProxy::processNextQueuedMouseEvent
```

Real WebKit page-rendering cost lives in the WebKit `WebContent`/`GPU` subprocesses, not in `cmux` itself. **The browser portal/sync path is not the bottleneck in this profile.**

---

## Sample 1 — idle baseline (5 s, no interaction)

```
main-thread samples:           2850
DPSBlock idle:                 2778    →  97.5 % idle
```

Top cmux symbols on the main thread:

```
 97  WindowBrowserHostView.dividerHit
 65  NSWindow.cmux_sendEvent
 41  PreferenceKey.reduce  (SelectedTabFramePreferenceKey)
 28  NSWindow.cmuxTopHitViewForEvent
 23  WindowTerminalHostView.dividerCursorKind
 21  WindowBrowserHostView.splitDividerHit
 14  WindowBrowserHostView.hitTest
 13  TabItemView.body.getter
 10  TabManager.workspacePullRequestRepoFetchResult
  6  GhosttyTerminalView.updateNSView
  6  WindowTerminalPortal.bind
  6  SplitViewContainer.updateContainerFrame
  6  BonsplitController.notifyGeometryChange
  5  GhosttySurfaceScrollView.synchronizeGeometryAndContent
```

Idle keyword counts of interest:

```
BrowserWindowPortal     71
synchronizeWebView       0
synchronizeAllWebViews   0
WKWebView                0
TerminalSurface          0
forceRefresh             0
```

### Idle observations

1. App is essentially asleep at idle (97.5 % `mach_msg` wait).
2. Even at idle, sidebar rows (`TabItemView.body.getter`, 13 samples) and PR metadata are recomputed; this is small but persistent.
3. `synchronizeWebView` / `synchronizeAllWebViews` / `WKWebView` are all 0 at idle — confirming the portal-sync path is not always-on.

---

## Diagnoses

### 1. PR-refresh runs `runCommandResult` on the main thread

`TabManager.runCommandResult(directory:executable:arguments:timeout:)` accounts for ~1700 main-thread samples in the busy window. The signature implies a synchronous external process spawn (`git` / `gh` / etc.) blocking the main thread until completion or timeout. This is the single biggest cause of UI hitches during the sampled period.

Evidence:

- `runCommandResult` and `applyWorkspacePullRequestRefreshResults` have nearly identical sample counts (1700 vs 1704), meaning the apply path is essentially waiting on the command.
- The driver `refreshTrackedWorkspacePullRequestsIfNeeded` runs on the main thread (entered via the SwiftUI/AppKit runloop, not a Dispatch queue work item).

### 2. Hit-testing is O(panes) per mouse event

`WindowBrowserHostView.dividerHit` alone is ~843 samples, plus ~413 `WindowTerminalHostView.dividerCursorKind` and ~412 `cmuxTopHitViewForEvent`. These all fire from `cmux_sendEvent` for every pointer-class event. As pane count grows, every mouse move walks more divider geometry.

CLAUDE.md already warns about this class of problem on `WindowTerminalHostView.hitTest()` — the same pattern is now visible on the browser-host side.

### 3. Omnibar suggestions are synchronous, per-keystroke, full-list

Each `controlTextDidChange` event triggers `BrowserPanelView.refreshSuggestions` → `BrowserHistoryStore.suggestions(for:limit:)` → `compactMap { ... suggestionScore }` synchronously on the main thread. `suggestionScore` is itself called in nested closures (`allSatisfy`, token-match closure ×68 samples). At rapid typing this is a visible per-keystroke cost.

### 4. `TabItemView.body.getter` recomputes during PR refresh

78 samples on the busy profile and 13 on the idle profile suggest the sidebar row is being re-evaluated, likely because `@Published` PR metadata writes from the refresh path invalidate views that sit below the lazy-list snapshot boundary documented in CLAUDE.md (issue #2586 family). Worth re-checking `IndexSectionActions` / `SectionGapActions`-style boundaries for browser-side rows.

### 5. `BrowserWindowPortal` is *not* the problem in this profile

`synchronizeWebView` had 3 hits and `synchronizeAllWebViews` had 0 in the busy 15 s window. `WindowBrowserPortal.runHostedWebViewRefreshPass` had 24 samples (not main-thread-blocking). The earlier hypothesis that multi-browser-pane stutter is driven by per-frame webview synchronization is **not supported** by these traces. WebKit work is properly off-main on the `IPC::StreamConnectionWorkQueue` thread.

---

## Recommended fixes (in priority order)

### P0 — Move `TabManager.runCommandResult` off the main thread
Expected payoff: recovers ~60 % of the observed busy-time budget.
- Run external command spawning on a background `DispatchQueue` / `Task.detached` / Effect service.
- Coalesce concurrent refreshes by repo / cache key.
- Merge results back to main only as the final `apply...RefreshResults` step (and only mutate `@Published` state once per result batch, not once per command).
- Audit *all* call sites of `runCommandResult` for main-thread invocation; treat any main-thread external-process spawn as a bug.

### P1 — Cache divider geometry; make hit-test O(1) per mouse event
Expected payoff: removes ~26 % of the observed busy-time budget; reduces typing/mouse latency in many-pane sessions.
- Compute `dividerRect` arrays in `WindowBrowserHostView` / `WindowTerminalHostView` once per geometry change, not per mouse event.
- Inside `cmux_sendEvent` / `cmuxTopHitViewForEvent`, use a sorted/spatial structure (e.g. a flat array + binary search by axis, or a simple grid) for containment tests.
- Confirm `WindowBrowserHostView.hitTest(_:)` matches the `isPointerEvent` guard CLAUDE.md mandates for `WindowTerminalHostView.hitTest()`.

### P2 — Debounce + off-main omnibar suggestions
Expected payoff: removes ~12 % of busy-time budget; smooths typing in the address bar.
- Debounce `controlTextDidChange` (50–80 ms) before kicking off suggestions.
- Run `BrowserHistoryStore.suggestions(for:limit:)` and `suggestionScore` on a background queue; deliver results to the main thread.
- Cache an indexed (lower-cased token) view of `BrowserHistoryStore` so per-keystroke scoring touches a small candidate set, not the full history.

### P3 — Re-audit sidebar snapshot boundary for browser rows
Expected payoff: removes a small but persistent recompute cost; eliminates a likely contributor to scroll jank in the sidebar.
- Verify rows below the `LazyVStack` / `ForEach` in browser-related sidebar code never carry a reference to an `ObservableObject` / `@Observable` store.
- Confirm PR-refresh `@Published` writes don't invalidate `TabItemView` rows that should be receiving immutable value snapshots.

### P4 — Stretch: move `Bonsplit`/`SplitViewContainer` geometry callbacks behind a coalescing trampoline
Small effect (~6 samples each at idle, similar in busy), but `BonsplitController.notifyGeometryChange` and `SplitViewContainer.updateContainerFrame` fire even when the user isn't dragging. Worth a quick check that we are not redundantly notifying delegates per layout pass.

---

## Validation plan

After each fix lands, re-sample with the same matrix and compare:

```bash
sample <pid> 15 -file /tmp/cmux.after.txt
```

Targets to watch:

| metric | before (busy 15 s) | target |
|---|---:|---:|
| `TabManager.runCommandResult` main-thread samples | 1700 | 0 |
| `WindowBrowserHostView.dividerHit` samples | 843 | < 100 |
| `BrowserHistoryStore.suggestions` samples | 170 | < 30 |
| main-thread `busy` ratio | 24.4 % | < 8 % |

The P0 fix alone should drop busy ratio under ~12 %.
