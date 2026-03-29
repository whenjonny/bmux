# WEA Bot Integration Design

**Date:** 2026-03-29
**Status:** Approved

## Goal

Integrate WEA (Difft) bot functionality into cmux so that:
- The main process handles WEA communication (WebSocket + HTTP, Swift native)
- Private DMs are handled by a `main` tab with an interactive Claude session
- Each WEA group chat gets its own tab with an independent Claude process
- Users can interact with Claude both via WEA and directly in the cmux terminal
- Closing the `main-wea` workspace disconnects the bot with a confirmation prompt

## Architecture Overview

```
┌─ cmux App ──────────────────────────────────────────────────┐
│                                                              │
│  ┌─ WeaBotService (Swift, singleton) ──────────────────────┐ │
│  │  URLSessionWebSocketTask → wss://openapi.difft.org      │ │
│  │  HMAC-SHA256 signing (CryptoKit)                        │ │
│  │  Message parsing, routing, CARD/REFRESH/TEXT replies     │ │
│  └──────┬───────────────────────┬──────────────────────────┘ │
│         │ DM messages           │ Group messages              │
│         ▼                       ▼                             │
│  ┌─ main tab ──────┐   ┌─ group-N tab ──────────┐           │
│  │ TerminalPanel    │   │ TerminalPanel           │          │
│  │ (codemax claude) │   │ (codemax claude)        │          │
│  │                  │   │                         │          │
│  │ WeaTerminalBridge│   │ WeaTerminalBridge       │          │
│  │ • sendInput()    │   │ • sendInput()           │          │
│  │ • hooks+transcript   │ • hooks+transcript      │          │
│  └──────────────────┘   └─────────────────────────┘          │
│                                                              │
│  Sidebar: [main-wea] workspace                               │
│    └─ Tabs: [main] [group-A] [group-B] ...                   │
└──────────────────────────────────────────────────────────────┘
```

## WEA Communication Layer (Swift Native)

### New Files: `Sources/Wea/`

| File | Responsibility |
|------|---------------|
| `WeaBotConfig.swift` | Config model: appId, appSecret, botId, blacklist. Keychain (secret) + UserDefaults |
| `WeaSignature.swift` | HMAC-SHA256 signing (CryptoKit), GET (WebSocket) and POST (HTTP) signature modes |
| `WeaWebSocket.swift` | URLSessionWebSocketTask, pull-based `{cmd:"fetch"}`, ping/reconnect |
| `WeaHttpClient.swift` | Send TEXT/CARD/REFRESH messages, long message splitting (~3500 char chunks) |
| `WeaMessageParser.swift` | Parse inbound messages (DM vs Group), extract text/mentions/topic |
| `WeaBotService.swift` | Core orchestrator: message routing, session lifecycle, connection management |
| `WeaTerminalBridge.swift` | Bridge: WEA message injection into terminal + Claude output collection via hooks/transcript |

### Signing Implementation (ref: claude_wea `signature.ts`)

```swift
// WebSocket GET signature
let calcStr = "\(appId);\(timestamp);\(nonce);GET;/v1/websocket;"
let key = SymmetricKey(data: Data(appSecret.utf8))
let signature = HMAC<SHA256>.authenticationCode(for: Data(calcStr.utf8), using: key)

// HTTP POST signature
let calcStr = "\(appId);\(ts);\(nonce);POST;\(path);content-length=\(bodyLen),content-type=application/json;charset=utf-8;\(jsonBody)"
```

### Message Protocol

**Inbound (from WEA):**
- WebSocket at `wss://openapi.difft.org/v1/websocket` with HMAC auth headers
- Pull-based: send `{cmd:"fetch"}` to pull pending messages
- Message types: TEXT and CARD processed; RECEIPT, RECALL etc. ignored
- DM: `dest.type == "USER"`, session key = `direct:{senderWuid}`
- Group: `dest.type == "GROUP"`, session key = `group:{groupId}`; only @mentioned or bot-topic messages

**Outbound (to WEA):**
- HTTP POST to `https://openapi.difft.org/v1/messages` with HMAC-signed body
- TEXT: short plain text without markdown
- CARD: rich content with markdown, `card.id` = unique UUID
- REFRESH: update existing CARD in-place by matching `card.id`
- Auto-detect: markdown patterns → CARD, plain short text → TEXT
- Long message splitting: paragraph boundary > newline > whitespace > hard cut at ~3500 chars

## Terminal Integration

### Claude Process Startup

Each tab (main or group chat) runs in a standard TerminalPanel:
```bash
codemax claude --dangerously-skip-permissions
```

Interactive mode, normal terminal UI. No `--output-format stream-json`.

### Input Injection (WEA → Terminal)

When a WEA message arrives for a specific session:
1. Format the message (e.g., the raw user text, without prefix decoration in the prompt itself)
2. Inject via `TerminalSurface.sendInput()` which calls `ghostty_surface_key`
3. This appears as if the user typed in the terminal

### Output Collection (Terminal → WEA) via Claude Code Hooks

**No Ghostty modification needed.** Leverages existing Claude Code hook mechanism.

#### Hook Events Used

| Hook | Trigger | WEA Action |
|------|---------|------------|
| `SessionStart` | Claude starts | Record `transcript_path`, start watching transcript file |
| `UserPromptSubmit` | User/WEA submits prompt | Mark source (wea vs local); if WEA → send CARD "thinking..." |
| `PreToolUse` (AskUserQuestion) | Claude asks a question | Extract question+options, forward to WEA, wait for reply |
| `PostToolUse` (NEW) | Tool execution completes | REFRESH streaming card with progress |
| `Notification` (needs-input) | Claude waiting for input | Forward to WEA, wait for reply, inject response |
| `Stop` | Claude finishes responding | Read full reply from transcript, final REFRESH to WEA |
| `SessionEnd` | Claude process exits | Cleanup |

#### Streaming via Transcript Watch

```
1. SessionStart hook → obtain transcript_path
2. DispatchSource.makeFileSystemObjectSource watches the file
3. On file change:
   - Read new lines from last offset
   - Parse JSONL, extract assistant text blocks
   - If active WEA message → REFRESH update CARD (throttled 800ms)
4. Stop hook → read complete last reply → final REFRESH
```

#### Enhanced Claude Wrapper Hooks

Add `PostToolUse` to the existing hook set in `Resources/bin/claude`:
```json
{
  "hooks": {
    "SessionStart":      [existing + WeaBotService records transcript_path],
    "UserPromptSubmit":  [existing + WeaBotService marks source=wea/local],
    "PreToolUse":        [existing + AskUserQuestion → forward to WEA],
    "PostToolUse":       [NEW: WeaBotService updates streaming card],
    "Notification":      [existing + needs-input → forward to WEA],
    "Stop":              [existing + WeaBotService sends final reply to WEA],
    "SessionEnd":        [existing + WeaBotService cleanup]
  }
}
```

### Response Completion Detection

**Multi-signal approach (no false positives):**

| Signal | Meaning | Source |
|--------|---------|--------|
| `Stop` hook fires | Claude finished responding | Hook event |
| `Notification` hook with "needs input" | Claude waiting for user | Hook event |
| `PreToolUse` with `AskUserQuestion` | Claude asking a question | Hook event |
| `SessionEnd` hook | Claude process exited | Hook event |
| 300s timeout (fallback) | Safety net | Timer |

**State Machine:**
```
                    WEA msg injected
                         │
                         ▼
    ┌─────────┐    ┌───────────┐
    │  idle    │───>│ processing│◄──────────────┐
    └─────────┘    └─────┬─────┘               │
         ▲               │                      │
         │        Hook events fire              │
         │               │                      │
         │     ┌─────────┴──────────┐           │
         │     ▼                    ▼           │
         │ ┌──────────┐   ┌──────────────┐      │
         │ │ completed │   │waitingInput  │      │
         │ │(Stop hook)│   │(Notification/│      │
         │ └────┬─────┘   │AskUserQ)     │      │
         │      │          └──────┬───────┘      │
         │ send final         forward Q to WEA   │
         │ reply to WEA      wait for reply      │
         │      │              inject answer ─────┘
         └──────┘
```

### WEA-originated vs Local Input Discrimination

Only WEA-triggered Claude responses should be sent back to WEA. Discrimination:
- `WeaTerminalBridge` sets a flag `activeWeaMessage` before injecting
- `UserPromptSubmit` hook checks this flag (via shared state / temp file marker)
- Only if `activeWeaMessage == true` do we track output and send to WEA
- Direct terminal typing doesn't set this flag → responses stay local

## UI Integration

### 1. Top Menu — WEA Bot Configuration

New menu item in `cmuxApp.swift` `.commands {}`:

```
cmux menu:
  ├── Settings...          (Cmd+,)
  ├── WEA Bot...           (NEW) → opens config sheet
  ├── About cmux
  └── ...
```

**Config Sheet content:**
- App ID (text field)
- App Secret (secure field, stored in Keychain)
- Bot ID (text field)
- Group Blacklist (multi-select list, populated after connection)
- Connect / Disconnect button
- Connection status indicator (connected / connecting / disconnected / error)

### 2. Left Sidebar — `main-wea` Workspace

On successful connection:
- Create special `Workspace` via `tabManager.addWorkspace(title: "main-wea")`
- Distinct icon (WEA logo or chat bubble icon) + connection status indicator
- Default contains one `main` tab (TerminalPanel running `codemax claude`)
- Workspace marked as special type (not closable without confirmation)

### 3. Right Side Tabs — Group Chat Tabs

On new group message (not blacklisted, not existing tab):
- Create new TerminalPanel in the `main-wea` workspace
- Tab name = group chat name (from WEA group metadata)
- Launch `codemax claude --dangerously-skip-permissions` in the terminal
- Register `WeaTerminalBridge` for this session

### 4. Close `main-wea` Workspace — Confirmation

On close attempt, show alert:
> "Closing this workspace will disconnect the WEA bot. All group chat sessions will be terminated. Continue?"
> [Cancel] [Disconnect & Close]

On confirm: disconnect WebSocket, terminate all Claude sessions, remove workspace.

### 5. Tab Context Menu — Blacklist

Group chat tab right-click menu additions:
- "Block this group" → add to blacklist, close tab, stop receiving messages
- "Unblock groups..." → link to WEA Bot config panel

Both the config panel and context menu sync via `WeaBotConfig`.

## Data Persistence

| Data | Storage |
|------|---------|
| Bot credentials (appId, botId) | UserDefaults |
| Bot secret (appSecret) | Keychain |
| Group blacklist | UserDefaults |
| Auto-connect on launch | UserDefaults |
| Session IDs (Claude `--resume`) | `~/.cmux/wea-sessions/{session-key}.id` |
| Known group list (for blacklist UI) | UserDefaults |
| Connection state | In-memory (not persisted) |

## Error Handling & Recovery

| Scenario | Handling |
|----------|----------|
| WebSocket disconnect | Auto-reconnect (3s interval), sidebar shows status |
| Claude process crash | Mark tab "disconnected", next WEA message triggers restart |
| Message send failure | Retry 3x, then show error in terminal |
| App restart | Restore config, auto-connect if enabled, rebuild workspace & tabs |
| Message burst | Batch within 900ms window (ref: claude_wea merge logic) |

## Message Flow Summary

### Inbound (WEA → Claude)

```
1. WeaWebSocket receives message
2. WeaMessageParser: extract sender, groupId, text, mentions, type
3. WeaBotService routes:
   - DM → main tab's WeaTerminalBridge
   - Group → group tab's WeaTerminalBridge (create if needed)
4. WeaTerminalBridge.injectMessage():
   - Set activeWeaMessage flag
   - sendInput() into terminal
5. Claude processes, hooks fire:
   - Transcript watch → streaming REFRESH updates
   - Stop → final reply to WEA
```

### Outbound (Claude → WEA)

```
1. Stop hook fires with transcript_path
2. Read full transcript JSONL
3. Extract last assistant message (complete, not truncated)
4. Send to WEA:
   - Short text without markdown → TEXT
   - Long/markdown content → CARD (auto-split if >3500 chars)
5. Clear activeWeaMessage flag
```

### Interactive Questions (Claude → WEA → Claude)

```
1. PreToolUse(AskUserQuestion) hook fires
2. Extract question text + numbered options
3. Format and send to WEA:
   "Claude is asking:
    [question text]
    1. Option A
    2. Option B
    Reply with a number or type your answer"
4. Wait for WEA user reply
5. Parse reply (number → select option, text → "Type something" + text)
6. sendInput() into terminal
7. Resume processing
```

## Key Dependencies

- **CryptoKit** (built-in): HMAC-SHA256 signing
- **URLSession** (built-in): WebSocket + HTTP client
- **No new external dependencies**

## Non-Goals (v1)

- Access control / pairing system (ref: claude_wea `access-manager.ts`) — can add later
- Circuit breaker pattern — start simple, add if needed
- Health check HTTP server — not needed for embedded service
- Context store with invisible markers — Claude handles context via `--resume`
