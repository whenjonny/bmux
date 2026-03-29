# WEA Sidebar Refactor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor WEA from a single workspace with bonsplit tabs to independent workspaces per chat, rendered in a dedicated sidebar section, with per-chat folders, message queueing, auto-connect, and configurable sessions root path.

**Architecture:** Each WEA chat becomes a separate Workspace marked with `weaGroupId`. The sidebar splits into normal workspaces (top) and WEA chats (bottom, below a divider). Messages route by group-id UUID to find or create workspaces on demand, with the existing bridge queue handling pre-ready buffering.

**Tech Stack:** Swift, SwiftUI, AppKit, Ghostty terminal

**Design doc:** `docs/plans/2026-03-29-wea-sidebar-refactor-design.md`

---

### Task 1: Add `weaGroupId` property to Workspace

**Files:**
- Modify: `Sources/Workspace.swift:5433` (near other `@Published` properties)

**Step 1: Add property**

Add after line 5436 (`@Published var customColor: String?`):

```swift
/// Non-nil if this workspace is a WEA chat session. Stores the WEA group/DM ID.
var weaGroupId: String?
```

This is a plain stored property (not `@Published`) since the sidebar filters by it on each render pass and it never changes after creation.

**Step 2: Update `closeWorkspaceWithConfirmation` in TabManager**

Modify `Sources/TabManager.swift:2714-2728`. Replace the `workspace.title == "wea"` check with `workspace.weaGroupId != nil`:

```swift
// WEA chat workspace requires disconnect confirmation
if workspace.weaGroupId != nil && WeaBotService.shared.isRunning {
    guard confirmClose(
        title: String(localized: "weaBot.close.title", defaultValue: "Disconnect WEA Chat?"),
        message: String(
            localized: "weaBot.closeChat.message",
            defaultValue: "Closing this workspace will terminate the WEA chat session."
        ),
        acceptCmdD: tabs.count <= 1
    ) else {
        return false
    }
    // Remove the bridge for this session
    if let groupId = workspace.weaGroupId {
        WeaBotService.shared.removeBridge(for: "group:\(groupId)")
    }
    closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
    return true
}
```

**Step 3: Update WEA context menu in ContentView**

Modify `Sources/ContentView.swift:11820-11826`. Replace `tab.title == "wea"` check with `tab.weaGroupId != nil`.

**Step 4: Build to verify compilation**

```bash
./scripts/reload.sh --tag wea-sidebar
```

**Step 5: Commit**

```bash
git add Sources/Workspace.swift Sources/TabManager.swift Sources/ContentView.swift
git commit -m "feat(wea): add weaGroupId property to Workspace for WEA chat identification"
```

---

### Task 2: Add `sessionsRootPath` to WeaBotConfig

**Files:**
- Modify: `Sources/Wea/WeaBotConfig.swift`

**Step 1: Add property and persistence**

Add after `knownGroupsKey` (line 14):
```swift
private static let sessionsRootPathKey = "weaBot.sessionsRootPath"
```

Add after `knownGroups` property (line 35):
```swift
@Published var sessionsRootPath: String {
    didSet { UserDefaults.standard.set(sessionsRootPath, forKey: Self.sessionsRootPathKey) }
}
```

In `init()` (after line 49, knownGroups load):
```swift
self.sessionsRootPath = UserDefaults.standard.string(forKey: Self.sessionsRootPathKey) ?? ""
```

Add helper method after `isBlacklisted`:
```swift
/// Resolved sessions root path. Falls back to `{cwd}/wea-sessions` if empty.
var resolvedSessionsRootPath: String {
    let path = sessionsRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.isEmpty {
        return FileManager.default.currentDirectoryPath + "/wea-sessions"
    }
    return path
}

/// Creates and returns the session folder for a given group ID.
func sessionFolder(for groupId: String) -> String {
    let root = resolvedSessionsRootPath
    let folder = (root as NSString).appendingPathComponent(groupId)
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    return folder
}
```

**Step 2: Build to verify**

```bash
./scripts/reload.sh --tag wea-sidebar
```

**Step 3: Commit**

```bash
git add Sources/Wea/WeaBotConfig.swift
git commit -m "feat(wea): add sessionsRootPath config for WEA chat folder location"
```

---

### Task 3: Add sessions root path to config sheet

**Files:**
- Modify: `Sources/Wea/WeaBotConfigSheet.swift`

**Step 1: Add folder picker field**

Add after the Auto-connect toggle field row (after line 64, closing `}`), still inside the `GroupBox` VStack:

```swift
Divider()

fieldRow(
    label: String(localized: "weaBot.config.sessionsRoot", defaultValue: "Sessions Folder")
) {
    HStack(spacing: 4) {
        TextField(
            "",
            text: $config.sessionsRootPath,
            prompt: Text(config.resolvedSessionsRootPath)
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 180)

        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                config.sessionsRootPath = url.path
            }
        } label: {
            Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
    }
}
```

**Step 2: Build to verify**

```bash
./scripts/reload.sh --tag wea-sidebar
```

**Step 3: Commit**

```bash
git add Sources/Wea/WeaBotConfigSheet.swift
git commit -m "feat(wea): add sessions folder picker to WEA config sheet"
```

---

### Task 4: Rewrite WeaWorkspaceManager for per-group workspaces

**Files:**
- Modify: `Sources/Wea/WeaWorkspaceManager.swift` (full rewrite)

**Step 1: Rewrite the file**

Replace the entire contents of `Sources/Wea/WeaWorkspaceManager.swift`:

```swift
// Sources/Wea/WeaWorkspaceManager.swift
import Foundation
import os

/// Manages WEA chat workspaces.
/// Each WEA group/DM gets its own independent Workspace with a dedicated session folder.
@MainActor
final class WeaWorkspaceManager {
    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "WeaWorkspaceManager")
    private weak var tabManager: TabManager?

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    // MARK: - Workspace Lookup & Creation

    /// Find the existing workspace for a group ID, or nil.
    func workspace(for groupId: String) -> Workspace? {
        tabManager?.tabs.first { $0.weaGroupId == groupId }
    }

    /// Find or create a workspace for a group/DM session.
    /// Returns the terminal panel for message injection.
    func findOrCreatePanel(groupId: String, displayName: String) -> TerminalPanel? {
        // Check for existing workspace
        if let existing = workspace(for: groupId) {
            return existing.panels.values.compactMap({ $0 as? TerminalPanel }).first
        }

        // Create session folder
        let folder = WeaBotConfig.shared.sessionFolder(for: groupId)

        // Create workspace
        guard let tabManager else { return nil }
        let workspace = tabManager.addWorkspace(
            title: displayName,
            workingDirectory: folder,
            initialTerminalCommand: "codemax claude --allow-dangerously-skip-permissions --model=bedrock-claude-4-6-opus",
            select: false
        )
        workspace.weaGroupId = groupId
        logger.info("Created WEA workspace '\(displayName)' for \(groupId) at \(folder)")

        return workspace.panels.values.compactMap({ $0 as? TerminalPanel }).first
    }

    // MARK: - Cleanup

    /// Close all WEA workspaces (called on disconnect).
    func closeAllWeaWorkspaces() {
        guard let tabManager else { return }
        let weaWorkspaces = tabManager.tabs.filter { $0.weaGroupId != nil }
        for workspace in weaWorkspaces {
            tabManager.closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
        }
        logger.info("Closed \(weaWorkspaces.count) WEA workspaces")
    }

    /// Close workspace for a specific group.
    func closeWorkspace(for groupId: String) {
        guard let tabManager, let workspace = workspace(for: groupId) else { return }
        tabManager.closeWorkspaceIfRunningProcess(workspace, requiresConfirmation: false)
    }
}
```

**Step 2: Build to verify**

```bash
./scripts/reload.sh --tag wea-sidebar
```

**Step 3: Commit**

```bash
git add Sources/Wea/WeaWorkspaceManager.swift
git commit -m "feat(wea): rewrite WeaWorkspaceManager for per-group independent workspaces"
```

---

### Task 5: Rewrite WeaBotService routing

**Files:**
- Modify: `Sources/Wea/WeaBotService.swift`

**Step 1: Remove old callback-based routing, use WeaWorkspaceManager directly**

Replace the entire `WeaBotService` implementation. Key changes:
- Remove `onCreateGroupTab`, `onGetMainPanel` callbacks
- Remove `createWeaWorkspaceIfNeeded()` (no single workspace on connect)
- `createBridge()` uses `workspaceManager.findOrCreatePanel(groupId:displayName:)`
- `stop()` calls `workspaceManager.closeAllWeaWorkspaces()`
- `workspaceManager` is created eagerly on `start()` instead of on connect

```swift
// Sources/Wea/WeaBotService.swift
import Foundation
import os

/// Central orchestrator for WEA bot functionality.
/// Manages the WebSocket connection, routes messages, creates/manages terminal bridges.
@MainActor
final class WeaBotService: ObservableObject {
    static let shared = WeaBotService()

    enum ServiceState: Equatable {
        case stopped
        case connecting
        case running
        case reconnecting
        case error(String)
    }

    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "WeaBotService")
    private let webSocket = WeaWebSocket()
    private var httpClient: WeaHttpClient?
    private var workspaceManager: WeaWorkspaceManager?

    @Published private(set) var state: ServiceState = .stopped
    private var bridges: [String: WeaTerminalBridge] = [:]  // sessionKey → bridge

    /// Reference to the TabManager for workspace management.
    weak var tabManager: TabManager?

    private init() {
        webSocket.onMessage = { [weak self] payload in
            Task { @MainActor [weak self] in
                self?.handleInboundMessage(payload)
            }
        }
        webSocket.onStateChange = { [weak self] wsState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch wsState {
                case .connected:
                    self.state = .running
                case .connecting: self.state = .connecting
                case .reconnecting: self.state = .reconnecting
                case .disconnected:
                    if case .error = self.state { /* keep error state */ } else {
                        self.state = .stopped
                    }
                }
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        let config = WeaBotConfig.shared
        guard let secret = config.loadSecret(), !config.appId.isEmpty, !config.botId.isEmpty else {
            state = .error("WEA bot not configured")
            return
        }

        if let tabManager {
            workspaceManager = WeaWorkspaceManager(tabManager: tabManager)
        }

        httpClient = WeaHttpClient(appId: config.appId, appSecret: secret, botId: config.botId)
        state = .connecting
        webSocket.connect(appId: config.appId, appSecret: secret)
    }

    func stop() {
        webSocket.disconnect()
        bridges.removeAll()
        httpClient = nil
        workspaceManager?.closeAllWeaWorkspaces()
        workspaceManager = nil
        state = .stopped
    }

    // MARK: - Message Routing

    private func handleInboundMessage(_ payload: [String: Any]) {
        let config = WeaBotConfig.shared
        let message: WeaParsedMessage
        do {
            message = try WeaMessageParser.parse(payload, botId: config.botId)
        } catch {
            return
        }

        switch message.chatType {
        case .directMessage:
            routeDirectMessage(message)
        case .groupChat:
            routeGroupMessage(message)
        }
    }

    private func routeDirectMessage(_ message: WeaParsedMessage) {
        let sessionKey = "direct:\(message.senderWuid)"
        let displayName = message.senderName ?? "DM"
        routeToSession(sessionKey: sessionKey, groupId: message.senderWuid, displayName: displayName, message: message)
    }

    private func routeGroupMessage(_ message: WeaParsedMessage) {
        guard let groupId = message.groupId else { return }
        let config = WeaBotConfig.shared

        guard !config.isBlacklisted(groupId) else { return }
        guard message.isMentionBot else { return }

        if let name = message.senderName, !name.isEmpty {
            config.knownGroups[groupId] = name
        }

        let sessionKey = "group:\(groupId)"
        let displayName = config.knownGroups[groupId] ?? "Group"
        routeToSession(sessionKey: sessionKey, groupId: groupId, displayName: displayName, message: message)
    }

    private func routeToSession(sessionKey: String, groupId: String, displayName: String, message: WeaParsedMessage) {
        let bridge: WeaTerminalBridge

        if let existing = bridges[sessionKey] {
            bridge = existing
        } else {
            guard let newBridge = createBridge(sessionKey: sessionKey, groupId: groupId, displayName: displayName, message: message) else {
                logger.error("Failed to create bridge for session \(sessionKey)")
                return
            }
            bridge = newBridge
            bridges[sessionKey] = bridge
        }

        if bridge.state == .waitingInput {
            bridge.injectQuestionReply(message.text)
        } else {
            Task {
                await bridge.injectMessage(message.text)
            }
        }
    }

    private func createBridge(sessionKey: String, groupId: String, displayName: String, message: WeaParsedMessage) -> WeaTerminalBridge? {
        guard let httpClient, let workspaceManager else { return nil }
        let dest = WeaMessageParser.replyDest(for: message)

        guard let panel = workspaceManager.findOrCreatePanel(groupId: groupId, displayName: displayName) else {
            return nil
        }

        return WeaTerminalBridge(
            sessionKey: sessionKey,
            panel: panel,
            httpClient: httpClient,
            dest: dest
        )
    }

    // MARK: - Hook Integration

    func handleClaudeStop(workspaceId: String, transcriptPath: String?, lastMessage: String?) {
        for bridge in bridges.values {
            guard bridge.isWeaMessageActive else { continue }
            Task {
                await bridge.onClaudeStop(transcriptPath: transcriptPath, lastMessage: lastMessage)
            }
            return
        }
    }

    func handleClaudeNotification(workspaceId: String, question: String) {
        for bridge in bridges.values {
            guard bridge.isWeaMessageActive else { continue }
            Task {
                await bridge.onNeedsInput(question: question)
            }
            return
        }
    }

    func handleAskUserQuestion(workspaceId: String, questionText: String) {
        for bridge in bridges.values {
            guard bridge.isWeaMessageActive else { continue }
            Task {
                await bridge.onAskUserQuestion(questionText: questionText)
            }
            return
        }
    }

    func handleSessionStart(workspaceId: String, transcriptPath: String?) {
        guard let transcriptPath else { return }
        for bridge in bridges.values {
            guard bridge.isWeaMessageActive else { continue }
            bridge.startTranscriptWatch(path: transcriptPath)
            return
        }
    }

    // MARK: - Session Management

    func removeBridge(for sessionKey: String) {
        bridges.removeValue(forKey: sessionKey)
    }

    func bridge(for sessionKey: String) -> WeaTerminalBridge? {
        bridges[sessionKey]
    }

    var isRunning: Bool { state == .running }

    func reportConnectionError(_ message: String) {
        state = .error(message)
    }
}
```

**Step 2: Build to verify**

```bash
./scripts/reload.sh --tag wea-sidebar
```

**Step 3: Commit**

```bash
git add Sources/Wea/WeaBotService.swift
git commit -m "feat(wea): rewrite WeaBotService routing to create per-group workspaces on demand"
```

---

### Task 6: Add auto-connect on app launch

**Files:**
- Modify: `Sources/AppDelegate.swift`

**Step 1: Add auto-connect after existing startup code**

Find the end of `applicationDidFinishLaunching` setup (around line 2409, after `NSApp.servicesProvider = self`). Add:

```swift
// Auto-connect WEA bot if configured
if !isRunningUnderXCTest {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
        let config = WeaBotConfig.shared
        if config.autoConnect && config.isConfigured {
            if let tabManager = self?.tabManager {
                WeaBotService.shared.tabManager = tabManager
            }
            WeaBotService.shared.start()
        }
    }
}
```

The 1.5s delay ensures the main window and initial workspace are already loaded before WEA starts creating workspaces.

**Step 2: Build to verify**

```bash
./scripts/reload.sh --tag wea-sidebar
```

**Step 3: Commit**

```bash
git add Sources/AppDelegate.swift
git commit -m "feat(wea): auto-connect WebSocket on app launch when credentials configured"
```

---

### Task 7: Add WEA section to sidebar

**Files:**
- Modify: `Sources/ContentView.swift` (inside `VerticalTabsSidebar`)

**Step 1: Split tabs into normal and WEA groups**

In `VerticalTabsSidebar.body` (line 8548), the existing code iterates `tabManager.tabs` with `ForEach`. We need to:

1. Compute two arrays at the top of body:
```swift
let normalTabs = tabManager.tabs.enumerated().filter { $0.element.weaGroupId == nil }
let weaTabs = tabManager.tabs.enumerated().filter { $0.element.weaGroupId != nil }
let normalWorkspaceCount = normalTabs.count
```

2. Replace the existing `ForEach(Array(tabManager.tabs.enumerated()), ...)` block (lines 8562-8606) with two sections:

**Normal workspaces** (same as before, but using `normalTabs` and `normalWorkspaceCount` for shortcut digits):
```swift
ForEach(normalTabs, id: \.element.id) { index, tab in
    // ... same TabItemView construction but use normalWorkspaceCount for shortcuts
    TabItemView(
        // ... existing params
        workspaceShortcutDigit: WorkspaceShortcutMapper.digitForWorkspace(
            at: normalTabs.firstIndex(where: { $0.offset == index }).map({ $0 }) ?? index,
            workspaceCount: normalWorkspaceCount
        ),
        // ... rest of params
    )
    .equatable()
}
```

**WEA divider + header** (only shown when WEA is running and there are WEA tabs):
```swift
if !weaTabs.isEmpty {
    VStack(spacing: 0) {
        Divider()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

        HStack(spacing: 6) {
            Text("WEA")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            Circle()
                .fill(WeaBotService.shared.isRunning ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}
```

**WEA workspace items** (simplified — no shortcuts):
```swift
ForEach(weaTabs, id: \.element.id) { index, tab in
    TabItemView(
        // ... same params as normal but:
        workspaceShortcutDigit: nil,  // no keyboard shortcuts for WEA tabs
        workspaceShortcutModifierSymbol: "",
        // ... rest of params
    )
    .equatable()
}
```

**Step 2: Update workspace count for `canCloseWorkspace`**

Change line 8550 from:
```swift
let canCloseWorkspace = workspaceCount > 1
```
to:
```swift
let canCloseWorkspace = normalTabs.count > 1 || !weaTabs.isEmpty
```

This ensures the last normal workspace can't be closed, but WEA workspaces can always be closed.

**Step 3: Build to verify**

```bash
./scripts/reload.sh --tag wea-sidebar
```

**Step 4: Commit**

```bash
git add Sources/ContentView.swift
git commit -m "feat(wea): render WEA chats in dedicated sidebar section with divider and status dot"
```

---

### Task 8: Update keyboard shortcut mapping to skip WEA workspaces

**Files:**
- Modify: `Sources/AppDelegate.swift` (keyboard shortcut handler)

**Step 1: Find the Cmd+digit handler**

Search for where `WorkspaceShortcutMapper.workspaceIndex(forDigit:)` is used to select workspaces. The handler needs to map digit → index in `normalTabs` only (tabs where `weaGroupId == nil`), then convert back to the full `tabs` array index.

In the keyboard handler (AppDelegate), when processing Cmd+1 through Cmd+9:
- Filter to `tabManager.tabs.filter { $0.weaGroupId == nil }` to get normal tabs
- Map digit to index within that filtered array
- Get the workspace at that index
- Use `tabManager.selectedTabId = workspace.id` to select

**Step 2: Build to verify**

```bash
./scripts/reload.sh --tag wea-sidebar
```

**Step 3: Commit**

```bash
git add Sources/AppDelegate.swift
git commit -m "feat(wea): exclude WEA workspaces from Cmd+digit keyboard shortcut mapping"
```

---

### Task 9: Clean up old WEA workspace references

**Files:**
- Modify: `Sources/ContentView.swift:11820-11826` (WEA context menu)
- Modify: `Sources/TabManager.swift:2714-2728` (close confirmation already done in Task 1)
- Modify: `Sources/AppDelegate.swift:6277` (showWeaBotConfig)

**Step 1: Update sidebar context menu**

In the WEA tab context menu (ContentView ~11820), update to use `weaGroupId`:

```swift
if tab.weaGroupId != nil {
    Button(String(localized: "weaBot.contextMenu.closeChat", defaultValue: "Close WEA Chat")) {
        if let groupId = tab.weaGroupId {
            WeaBotService.shared.removeBridge(for: "group:\(groupId)")
        }
        tabManager.closeWorkspaceIfRunningProcess(tab, requiresConfirmation: false)
    }
}
```

**Step 2: Remove old "wea" workspace title checks**

Search for `workspace.title == "wea"` or `tab.title == "wea"` and replace all with `workspace.weaGroupId != nil` / `tab.weaGroupId != nil`.

**Step 3: Build to verify**

```bash
./scripts/reload.sh --tag wea-sidebar
```

**Step 4: Commit**

```bash
git add Sources/ContentView.swift Sources/TabManager.swift Sources/AppDelegate.swift
git commit -m "refactor(wea): replace title-based WEA checks with weaGroupId property"
```

---

### Task 10: Add localization strings

**Files:**
- Modify: `Resources/Localizable.xcstrings`

**Step 1: Add new localization keys**

Add entries for:
- `weaBot.config.sessionsRoot` — "Sessions Folder" / "セッションフォルダ"
- `weaBot.closeChat.message` — "Closing this workspace will terminate the WEA chat session." / corresponding Japanese
- `weaBot.contextMenu.closeChat` — "Close WEA Chat" / "WEAチャットを閉じる"

**Step 2: Build to verify**

```bash
./scripts/reload.sh --tag wea-sidebar
```

**Step 3: Commit**

```bash
git add Resources/Localizable.xcstrings
git commit -m "chore(i18n): add localization strings for WEA sidebar refactor"
```

---

### Task 11: End-to-end verification

**Step 1: Build final tagged app**

```bash
./scripts/reload.sh --tag wea-sidebar --launch
```

**Step 2: Manual verification checklist**

- [ ] App launches, sidebar shows only normal workspaces (no WEA section)
- [ ] Open WEA config, set credentials, enable auto-connect
- [ ] Restart app → WEA auto-connects (green dot appears in WEA section header)
- [ ] Send a message from WEA group → new workspace appears in WEA sidebar section
- [ ] Folder created at `{sessionsRootPath}/{groupId}/`
- [ ] Claude starts in that folder as cwd
- [ ] Second message to same group → reuses existing workspace
- [ ] Message to different group → creates second WEA workspace
- [ ] Cmd+1/2/3 only switch between normal workspaces, not WEA ones
- [ ] Click WEA chat in sidebar → switches to that workspace
- [ ] Close WEA chat → workspace removed, bridge cleaned up
- [ ] Disconnect WEA → all WEA workspaces close
- [ ] Sessions root path in config → folder picker works, new chats use new path

**Step 3: Commit any final fixes**

```bash
git add -A
git commit -m "feat(wea): complete WEA sidebar refactor with per-group workspaces"
```
