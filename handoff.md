# Handoff: rebase `plus` onto `main` (manaflow-ai/cmux)

## Goal

Reconstruct branch `plus` on top of current `main` by cherry-picking plus's 4 unique commits in order. The pre-existing merge commit on origin (`22aafd35 Merge branch 'main' into plus`) was a botched 3-way merge that produced a corrupted `project.pbxproj`, malformed Swift files, and ~111 build errors. We're discarding that merge and rebasing instead.

**User instructions / repo conventions** (must respect):
- User: `xiaocang` (jiahao.wang@konghq.com), CLAUDE.md says: do NOT run tests in agent — let user run manually.
- Build with `./scripts/reload.sh --tag <slug>` for Debug, never bare `xcodebuild`.
- For one-off compile checks: `xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<tag> build`.
- All UI strings localized via `String(localized: "key", defaultValue: "...")` with entries in `Resources/Localizable.xcstrings`.
- Submodule pointers: PLUS uses NEWER bonsplit/ghostty (with `SplitButtonBackdropEffect`); main uses older. Plus's code depends on plus's pointers — keep plus's submodule pointers.
- Debug logging: main migrated `dlog(...)` → `cmuxDebugLog(...)` (in `Sources/App/DebugLogging.swift`, wrapped in `#if DEBUG`). Translate any `dlog` from plus commits to `cmuxDebugLog`.
- Pbxproj note: when this Xcode 26.3 / macOS 26.4.1 environment hits parse errors, the issue is real corruption — the OpenStep parser still works.

## Current state (as of handoff)

- Working dir: `/Users/jiahao.wang/work/cmux.plus`
- On branch `plus` (local was reset to `b9c9c373` = origin/main; cherry-picking forward).
- Safety branch: `plus-pre-rebase` → `890ba297` (the pre-merge plus tip, full original work preserved).
- Note: `origin/plus` still has the bad merge `22aafd35` and is 5 commits "ahead" of local. Final push will need `git push --force-with-lease origin plus` after rebase completes — DO NOT do this until user confirms and the build is green.

### Mid-cherry-pick state

`git status` says **"You are currently cherry-picking commit d22b224b"**. (Note: `.git/CHERRY_PICK_HEAD` is missing from the status capture, but `git status` still reports the cherry-pick. Treat the cherry-pick as in progress.)

**Resolved (already staged):**
- `Sources/AppDelegate.swift` — 2 conflict regions resolved (combined main's `configuredCmuxShortcutActions`/`handleConfiguredCmuxShortcut`/`executeConfiguredCmuxActionShortcut` with plus's leader-key helpers; translated `dlog` → `cmuxDebugLog`).
- `Sources/ContentView.swift` — 3 conflict regions resolved.
  - VStack now contains plus's leader-key indicator above main's `workspaceScrollArea(renderContext:)` call. Plus's old inline GeometryReader/ScrollView block was removed (main's refactor superseded it).
  - `workspaceSnapshot.title` kept (instead of plus's `tab.displayTitle`).
  - Fix that lets plus's tagging propagate: `SidebarWorkspaceSnapshotBuilder.Snapshot` is built with `title: tab.displayTitle` (was `tab.title`) so the tag prefix shows up in the existing snapshot field.

**Remaining conflict — 1 region in 1 file:**
- `GhosttyTabs.xcodeproj/project.pbxproj` — lines `893..1004`. This is the PBXSourcesBuildPhase (`A5001050 /* Sources */`) `files` list. Strategy: keep HEAD's full ordered list and add only `A50012F8 /* LeaderKeySettings.swift in Sources */,` (the build-file ref id is `A50012F7` in this project — verify by grep'ing the section above). The cherry-pick of `d22b224b` shows that the actual diff to pbxproj is just 4 lines:
  ```
  + A50012F7 /* LeaderKeySettings.swift in Sources */ = {isa = PBXBuildFile; fileRef = A50012F6 /* LeaderKeySettings.swift */; };
  + A50012F6 /* LeaderKeySettings.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LeaderKeySettings.swift; sourceTree = "<group>"; };
  +     A50012F6 /* LeaderKeySettings.swift */,
  +     A50012F7 /* LeaderKeySettings.swift in Sources */,
  ```
  The first three are already inserted into HEAD's structure in earlier conflict regions. Only the fourth (the entry inside `Sources` build phase `files = (...)`) is left. Add `A50012F7 /* LeaderKeySettings.swift in Sources */,` near the other `*Settings.swift in Sources` entries (e.g., next to `A50012F3 /* KeyboardShortcutSettings.swift in Sources */,`). Discard everything in the d22b224b side that isn't that one line.

After resolving:

```
git add GhosttyTabs.xcodeproj/project.pbxproj
git cherry-pick --continue
```

Use `git commit --no-edit` if the editor opens — preserve the original commit message.

### Untracked file kept

`scripts/install-local.sh` — created by user. Contents include `CODE_SIGNING_ALLOWED=NO` on the xcodebuild line (added so local Release builds succeed without a configured DEVELOPMENT_TEAM). A backup exists at `/tmp/install-local.sh.bak`. Once the rebase is done you can `git add scripts/install-local.sh` as a separate commit on plus if the user wants it tracked — confirm with the user first.

## What's left after cherry-pick #1 finishes

Cherry-pick the remaining 3 plus commits, in this order:

1. `ef41521f` — Allow repo cache for shellPrompt PR refreshes
2. `3eca1fcf` — Add GitHub rate-limit cooldown for workspace PR probes
3. `890ba297` — feat: add Workspace Handoff digests with cmux-digest sidecar (#3)

Each may produce its own conflicts. Apply the same per-conflict pattern: understand main's refactor, understand plus's addition, combine. Specifically watch for:

- **Symbol rename** main did: `CmuxDirectoryTrust` → `CmuxActionTrust`. Plus code may call the old name; update to new.
- **Missing types in main**: `LeaderKeySettings` (added by `d22b224b` cherry-pick #1; will be present after that one applies) and any plus-specific files. Confirm `Sources/LeaderKeySettings.swift` is in the index after #1.
- **`fileExplorerState` / `cmuxConfigStore`** — these surfaced as scope errors in the bad merge; if a conflict region uses them, check whether main passes them via a different mechanism (e.g., `MainWindowContext`) and translate.
- **Bonsplit `Appearance.SplitButtonBackdropEffect`** — only in newer bonsplit (`098d9fa0`). Make sure `vendor/bonsplit` index entry stays at `098d9fa00e2b1d4712f1a46b818ee7d53d4aa31f`. If a cherry-pick rewinds it to main's `d403ae6a`, override with: `git update-index --cacheinfo 160000,098d9fa00e2b1d4712f1a46b818ee7d53d4aa31f,vendor/bonsplit`. Same for ghostty (keep `3b684a085d40ec79e8a0ae863a4f2b48ed4dba74`).
- Pbxproj merges: keep HEAD's structure, add only the new entries plus's commit introduced. Don't take wholesale d22-side blocks — they re-introduce duplicate entries.

## Verification (DO NOT auto-run; ask user)

After all 4 cherry-picks land:

```bash
# Compile-only (tagged derivedDataPath, no app launch):
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-rebase-check build
```

Capture errors with: `... 2>&1 | grep -E 'error:' | grep -v 'Run script\|warning:' | head -50`

If clean, ask user before doing any of:
- `git push --force-with-lease origin plus`
- Deleting safety branch `plus-pre-rebase`

## Key file locations / structures touched

- `Sources/Workspace.swift:8615` — `displayTitle` getter (incorporates tag prefix `"[%@] %@"`).
- `Sources/ContentView.swift:13630` — `SidebarWorkspaceSnapshotBuilder.Snapshot(...)` construction; uses `tab.displayTitle` after my edit.
- `Sources/ContentView.swift` — body of `SidebarView` (around line 9670) — leader indicator + `workspaceScrollArea(renderContext:)`.
- `Sources/AppDelegate.swift` — leader-key helpers + cmux-config shortcut helpers coexist after my edit (around line 11770).
- `Sources/App/DebugLogging.swift` — defines `cmuxDebugLog(_:)`. Use this, NOT `dlog`.
- `Sources/LeaderKeySettings.swift` — added fresh by cherry-pick #1.

## Things NOT to do

- Don't run `git push --force-with-lease` without user explicit OK.
- Don't run `git push` (regular) — the rebase rewrites history; regular push will reject and the alternative is force.
- Don't delete `plus-pre-rebase` branch.
- Don't attempt to "fix" the bad merge `22aafd35` — it's been replaced by the rebase.
- Don't run tests (`bun test`, xcodebuild test, etc.) per user's CLAUDE.md.
- Don't open the untagged `cmux DEV.app`.
- Avoid `git add -A` — there's an intentional untracked `scripts/install-local.sh` that the user may or may not want committed; ask first.

## If something looks wrong

If conflicts get unmanageable on a later cherry-pick, the cleanest recovery is:

```bash
git cherry-pick --abort
git reset --hard plus-pre-rebase   # back to original plus tip 890ba297, full plus work intact
```

Then reconsider strategy. The original bad merge can also be reproduced from origin if needed (`origin/plus` still has it).

## Quick context dump

- Local git: `plus` currently mid-cherry-pick of `d22b224b`, base = `b9c9c373` (= `origin/main`).
- `plus-pre-rebase` is the safety net: `890ba297` (full original plus tip).
- 4 plus-only commits to apply: `d22b224b`, `ef41521f`, `3eca1fcf`, `890ba297` (in that order).
- Submodule pointers to keep: `ghostty=3b684a08...`, `vendor/bonsplit=098d9fa0...`.
- Last action: I'd just resolved the third pbxproj conflict region (PBXGroup `A5001041 /* Sources */` children list) by inserting `A50012F6 /* LeaderKeySettings.swift */,` between `KeyboardShortcutSettingsFileStore.swift` and `KeyboardLayout.swift`, keeping HEAD's full list. One more pbxproj conflict region remains (the PBXSourcesBuildPhase files list).
