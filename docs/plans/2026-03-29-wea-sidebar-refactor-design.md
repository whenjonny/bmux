# WEA Sidebar Refactor Design

**Date:** 2026-03-29
**Status:** Approved

## Problem

Current WEA implementation creates a single "wea" workspace with all chats as bonsplit tabs inside it. This needs to change to:
1. Each WEA chat is an independent workspace with its own folder (cwd + session storage)
2. Sidebar renders a dedicated WEA section separated from normal workspaces
3. Messages route by group-id (UUID) to find/create the right workspace
4. Messages queue until Claude process is ready
5. Auto-connect WebSocket on app launch if credentials exist
6. Sessions root path is configurable in settings

## Architecture

### Data Model Changes

**Workspace** — add `weaGroupId: String?` property. Non-nil marks it as a WEA chat workspace.

**WeaBotConfig** — add `sessionsRootPath: String` (default: `{cwd}/wea-sessions`). Persisted in UserDefaults.

### Folder Structure

```
{sessionsRootPath}/
  ├ {group-id-1}/       ← Claude cwd + session data
  │   ├ .claude/        ← auto-created by Claude Code
  │   └ ...
  ├ {group-id-2}/
  └ ...
```

Each folder is created lazily when the first message arrives for a group. The folder path doubles as the terminal's working directory (so Claude can read/write files there) and stores session metadata (transcript, etc.).

### Sidebar Rendering

`VerticalTabsSidebar` splits `tabManager.tabs` into two groups:

- **Normal workspaces:** `tabs.filter { $0.weaGroupId == nil }`
- **WEA chats:** `tabs.filter { $0.weaGroupId != nil }`

Layout:
```
[Normal workspace 1]
[Normal workspace 2]
─────────────────────
WEA  ●               ← section header with connection status dot
  [Group: Team Chat]
  [Group: Deploy Alerts]
  [DM: John]
```

- WEA chat items use simplified row style (title = group/user name)
- Cmd+1/2/3 shortcuts only number normal workspaces
- Click selects the workspace (same as normal workspace selection)
- Context menu: disconnect WEA, close chat, blacklist group

### Message Routing (WeaWorkspaceManager rewrite)

On inbound WS message:
1. Extract `groupId` from parsed message
2. Search `tabManager.tabs` for workspace where `weaGroupId == groupId`
3. **Found:** get its TerminalPanel → route to existing bridge
4. **Not found:**
   a. Create folder at `{sessionsRootPath}/{groupId}/`
   b. `tabManager.addWorkspace(title: groupName, workingDirectory: folder, initialTerminalCommand: "codemax claude ...")`
   c. Set `workspace.weaGroupId = groupId`
   d. Create bridge with the new workspace's panel
   e. Bridge queues message until Claude REPL is ready

### Message Queue (unchanged)

`WeaTerminalBridge` already has:
- `pendingMessages: [String]` queue
- `replReady` flag with Timer-based polling (2s interval, 20s max)
- `startTranscriptWatch()` called on SessionStart hook marks ready immediately
- Queue flushes automatically when ready

No changes needed.

### Auto-Connect on Launch

In `AppDelegate.applicationDidFinishLaunching`:
```swift
if WeaBotConfig.shared.autoConnect && WeaBotConfig.shared.isConfigured {
    WeaBotService.shared.tabManager = tabManager
    WeaBotService.shared.start()
}
```

The `autoConnect` toggle already exists in `WeaBotConfig` and `WeaBotConfigSheet`. Just need to wire it into app startup.

### Settings Panel Extension

Add to `WeaBotConfigSheet`:
- "Sessions Root Path" field with folder picker button
- Shows current path, defaults to `{cwd}/wea-sessions`

### WeaBotService Changes

- Remove the single-workspace model (`createWeaWorkspaceIfNeeded` → no longer creates a workspace on connect)
- On connect, just set state to `.running` (workspaces are created on-demand per message)
- `stop()` closes all WEA workspaces (filter `tabManager.tabs` by `weaGroupId != nil`)
- Remove `onGetMainPanel` / `onCreateGroupTab` callbacks — routing is now internal to `WeaWorkspaceManager`

### Files to Modify

1. **Sources/Workspace.swift** — add `weaGroupId: String?`
2. **Sources/Wea/WeaBotConfig.swift** — add `sessionsRootPath`
3. **Sources/Wea/WeaBotService.swift** — remove single-workspace creation, update stop/routing
4. **Sources/Wea/WeaWorkspaceManager.swift** — rewrite: per-group workspace creation, group-id lookup
5. **Sources/Wea/WeaBotConfigSheet.swift** — add sessions root path field
6. **Sources/ContentView.swift** — split sidebar rendering into normal/WEA sections
7. **Sources/AppDelegate.swift** — add auto-connect on launch
8. **Sources/TabManager.swift** — exclude WEA workspaces from Cmd+N numbering (if applicable)
