# WEA Bot Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Integrate WEA (Difft) bot functionality into cmux so users can manage WEA bot connections, receive/respond to messages via Claude-powered terminal tabs.

**Architecture:** Swift-native WEA communication (URLSessionWebSocketTask + CryptoKit HMAC-SHA256) with a `main-wea` sidebar workspace. Each WEA session (DM or group) maps to a TerminalPanel running `codemax claude`. Claude Code Hooks + transcript JSONL watching provide output collection and streaming without Ghostty modification.

**Tech Stack:** Swift, CryptoKit, URLSession, AppKit/SwiftUI (existing cmux patterns), Keychain Services

**Design doc:** `docs/plans/2026-03-29-wea-bot-integration-design.md`

---

## Task 1: WeaBotConfig — Configuration Model

**Files:**
- Create: `Sources/Wea/WeaBotConfig.swift`

**Step 1: Create the config model**

```swift
// Sources/Wea/WeaBotConfig.swift
import Foundation
import Security

/// Persistent configuration for the WEA bot connection.
final class WeaBotConfig: ObservableObject {
    static let shared = WeaBotConfig()

    private static let appIdKey = "weaBot.appId"
    private static let botIdKey = "weaBot.botId"
    private static let autoConnectKey = "weaBot.autoConnect"
    private static let groupBlacklistKey = "weaBot.groupBlacklist"
    private static let knownGroupsKey = "weaBot.knownGroups"
    private static let keychainService = "com.cmuxterm.app.wea-bot"
    private static let keychainAccount = "app-secret"

    @Published var appId: String {
        didSet { UserDefaults.standard.set(appId, forKey: Self.appIdKey) }
    }
    @Published var botId: String {
        didSet { UserDefaults.standard.set(botId, forKey: Self.botIdKey) }
    }
    @Published var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: Self.autoConnectKey) }
    }
    @Published var groupBlacklist: Set<String> {
        didSet { UserDefaults.standard.set(Array(groupBlacklist), forKey: Self.groupBlacklistKey) }
    }
    @Published var knownGroups: [String: String] = [:] {  // groupId → groupName
        didSet {
            if let data = try? JSONEncoder().encode(knownGroups) {
                UserDefaults.standard.set(data, forKey: Self.knownGroupsKey)
            }
        }
    }

    var isConfigured: Bool {
        !appId.isEmpty && !botId.isEmpty && loadSecret() != nil
    }

    private init() {
        self.appId = UserDefaults.standard.string(forKey: Self.appIdKey) ?? ""
        self.botId = UserDefaults.standard.string(forKey: Self.botIdKey) ?? ""
        self.autoConnect = UserDefaults.standard.bool(forKey: Self.autoConnectKey)
        self.groupBlacklist = Set(UserDefaults.standard.stringArray(forKey: Self.groupBlacklistKey) ?? [])
        if let data = UserDefaults.standard.data(forKey: Self.knownGroupsKey),
           let groups = try? JSONDecoder().decode([String: String].self, from: data) {
            self.knownGroups = groups
        }
    }

    // MARK: - Keychain (app secret)

    func saveSecret(_ secret: String) -> Bool {
        deleteSecret()
        guard let data = secret.data(using: .utf8) else { return false }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
            kSecValueData: data,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func loadSecret() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func deleteSecret() -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func addToBlacklist(_ groupId: String) {
        groupBlacklist.insert(groupId)
    }

    func removeFromBlacklist(_ groupId: String) {
        groupBlacklist.remove(groupId)
    }

    func isBlacklisted(_ groupId: String) -> Bool {
        groupBlacklist.contains(groupId)
    }
}
```

**Step 2: Verify it compiles**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-wea-build build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/Wea/WeaBotConfig.swift
git commit -m "feat(wea): add WeaBotConfig model with Keychain secret storage"
```

---

## Task 2: WeaSignature — HMAC-SHA256 Signing

**Files:**
- Create: `Sources/Wea/WeaSignature.swift`

**Reference:** `../claude_wea/src/utils/signature.ts`

**Step 1: Implement the signing utility**

```swift
// Sources/Wea/WeaSignature.swift
import Foundation
import CryptoKit

/// HMAC-SHA256 signing for WEA/Difft OpenAPI.
/// Reference: claude_wea/src/utils/signature.ts
enum WeaSignature {

    /// Headers required for a signed WEA API request.
    struct SignedHeaders {
        let appId: String
        let timestamp: String
        let nonce: String
        let algorithm: String = "HmacSHA256"
        let signature: String
        let signedHeaders: String

        var httpHeaders: [String: String] {
            [
                "X-Signature-appid": appId,
                "X-Signature-timestamp": timestamp,
                "X-Signature-nonce": nonce,
                "X-Signature-algorithm": algorithm,
                "X-Signature-signature": signature,
                "X-Signature-signedHeaders": signedHeaders,
            ]
        }
    }

    /// Sign a WebSocket GET connection request.
    static func signWebSocket(appId: String, appSecret: String) -> SignedHeaders {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let calcStr = "\(appId);\(timestamp);\(nonce);GET;/v1/websocket;"
        let sig = hmacSHA256(message: calcStr, secret: appSecret)
        return SignedHeaders(
            appId: appId, timestamp: timestamp, nonce: nonce,
            signature: sig, signedHeaders: ""
        )
    }

    /// Sign an HTTP POST request.
    static func signPost(
        appId: String,
        appSecret: String,
        path: String,
        jsonBody: String
    ) -> SignedHeaders {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let bodyBytes = jsonBody.data(using: .utf8)?.count ?? 0
        let calcStr = "\(appId);\(timestamp);\(nonce);POST;\(path);content-length=\(bodyBytes),content-type=application/json;charset=utf-8;\(jsonBody)"
        let sig = hmacSHA256(message: calcStr, secret: appSecret)
        return SignedHeaders(
            appId: appId, timestamp: timestamp, nonce: nonce,
            signature: sig, signedHeaders: "Content-Length,Content-Type"
        )
    }

    private static func hmacSHA256(message: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
```

**Step 2: Verify it compiles**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-wea-build build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/Wea/WeaSignature.swift
git commit -m "feat(wea): add HMAC-SHA256 signing for WEA OpenAPI"
```

---

## Task 3: WeaMessageParser — Inbound Message Parsing

**Files:**
- Create: `Sources/Wea/WeaMessageParser.swift`

**Reference:** `../claude_wea/src/bot/message-handler.ts` parseMessage()

**Step 1: Implement the parser with message types**

```swift
// Sources/Wea/WeaMessageParser.swift
import Foundation

/// Parsed WEA message ready for routing.
struct WeaParsedMessage {
    enum ChatType {
        case directMessage
        case groupChat
    }

    let chatType: ChatType
    let senderWuid: String
    let text: String
    let groupId: String?       // nil for DMs
    let groupName: String?     // nil for DMs, may be nil for groups too
    let timestamp: Int64
    let isMentioned: Bool      // was the bot @mentioned (group only)
    let topicId: String?       // thread topic ID
    let refId: String?         // message reference ID for threading
    let rawPayload: [String: Any]
}

/// Destination for outbound WEA messages.
struct WeaMessageDest {
    let type: String   // "USER" or "GROUP"
    let wuid: [String]?
    let groupId: String?

    var json: [String: Any] {
        var d: [String: Any] = ["type": type]
        if let wuid { d["wuid"] = wuid }
        if let groupId { d["groupID"] = groupId }
        return d
    }

    static func dm(to wuid: String) -> WeaMessageDest {
        WeaMessageDest(type: "USER", wuid: [wuid], groupId: nil)
    }

    static func group(_ groupId: String) -> WeaMessageDest {
        WeaMessageDest(type: "GROUP", wuid: nil, groupId: groupId)
    }
}

/// Parses raw WEA/Difft message payloads.
enum WeaMessageParser {

    /// Parse a raw JSON payload from the WEA WebSocket.
    /// Returns nil if the message should be ignored (e.g., RECEIPT, RECALL).
    static func parse(_ payload: [String: Any], botId: String) -> WeaParsedMessage? {
        guard let msgType = payload["type"] as? String,
              (msgType == "TEXT" || msgType == "CARD") else {
            return nil  // Skip RECEIPT, RECALL, etc.
        }

        guard let src = payload["src"] as? String,
              let dest = payload["dest"] as? [String: Any],
              let destType = dest["type"] as? String else {
            return nil
        }

        let msg = payload["msg"] as? [String: Any]
        let text: String
        if msgType == "CARD", let card = payload["card"] as? [String: Any] {
            text = (card["content"] as? String) ?? (msg?["body"] as? String) ?? ""
        } else {
            text = (msg?["body"] as? String) ?? ""
        }

        guard !text.isEmpty else { return nil }

        let timestamp = (payload["timestamp"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
        let refId = msg?["refID"] as? String
        let topicId = (payload["context"] as? [String: Any])?["topic"].flatMap { ($0 as? [String: Any])?["id"] as? String }

        // Check if bot is mentioned
        let mentions = payload["mentions"] as? [[String: Any]] ?? []
        let atPersons = msg?["atPersons"] as? [String] ?? []
        let isMentioned = atPersons.contains(botId) ||
            mentions.contains(where: { ($0["uid"] as? String) == botId })

        let chatType: WeaParsedMessage.ChatType
        let groupId: String?

        if destType == "GROUP", let gid = dest["groupID"] as? String {
            chatType = .groupChat
            groupId = gid
        } else {
            chatType = .directMessage
            groupId = nil
        }

        return WeaParsedMessage(
            chatType: chatType,
            senderWuid: src,
            text: text,
            groupId: groupId,
            groupName: nil, // Resolved later from group metadata
            timestamp: timestamp,
            isMentioned: isMentioned,
            topicId: topicId,
            refId: refId,
            rawPayload: payload
        )
    }

    /// Build the reply destination for a parsed message.
    static func replyDest(for message: WeaParsedMessage) -> WeaMessageDest {
        switch message.chatType {
        case .directMessage:
            return .dm(to: message.senderWuid)
        case .groupChat:
            return .group(message.groupId ?? "")
        }
    }
}
```

**Step 2: Verify it compiles**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-wea-build build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/Wea/WeaMessageParser.swift
git commit -m "feat(wea): add inbound message parser with DM/group routing"
```

---

## Task 4: WeaWebSocket — WebSocket Connection Manager

**Files:**
- Create: `Sources/Wea/WeaWebSocket.swift`

**Reference:** `../claude_wea/src/bot/ws-listener.ts`

**Step 1: Implement the WebSocket manager**

```swift
// Sources/Wea/WeaWebSocket.swift
import Foundation
import os

/// Manages the WebSocket connection to WEA/Difft OpenAPI.
/// Uses pull-based message fetching: sends {cmd:"fetch"} to pull pending messages.
final class WeaWebSocket: NSObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "WeaWebSocket")
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private let reconnectInterval: TimeInterval = 3.0
    private let pingInterval: TimeInterval = 30.0
    private var intentionalDisconnect = false

    var onMessage: (([String: Any]) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?

    @Published private(set) var state: ConnectionState = .disconnected {
        didSet {
            if oldValue != state {
                onStateChange?(state)
            }
        }
    }

    func connect(appId: String, appSecret: String) {
        intentionalDisconnect = false
        state = .connecting

        let signed = WeaSignature.signWebSocket(appId: appId, appSecret: appSecret)
        var request = URLRequest(url: URL(string: "wss://openapi.difft.org/v1/websocket")!)
        for (key, value) in signed.httpHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        webSocketTask = session?.webSocketTask(with: request)
        webSocketTask?.resume()
    }

    func disconnect() {
        intentionalDisconnect = true
        cleanup()
        state = .disconnected
    }

    private func cleanup() {
        pingTimer?.invalidate()
        pingTimer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func onConnected() {
        state = .connected
        startPingLoop()
        sendFetch()
    }

    private func sendFetch() {
        guard state == .connected else { return }
        let fetchMsg = URLSessionWebSocketTask.Message.string("{\"cmd\":\"fetch\"}")
        webSocketTask?.send(fetchMsg) { [weak self] error in
            if let error {
                self?.logger.error("Failed to send fetch: \(error.localizedDescription)")
            }
        }
    }

    private func receiveNext() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveNext()
            case .failure(let error):
                self.logger.error("WebSocket receive error: \(error.localizedDescription)")
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let str): text = str
        case .data(let data): text = String(data: data, encoding: .utf8) ?? ""
        @unknown default: return
        }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Process messages array
        if let messages = json["messages"] as? [[String: Any]] {
            for msg in messages {
                if let msgData = msg["data"] as? [String: Any] {
                    onMessage?(msgData)
                }
            }
        }

        // ACK and fetch next batch
        sendFetch()
    }

    private func startPingLoop() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            self?.webSocketTask?.sendPing { error in
                if let error {
                    self?.logger.warning("Ping failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !intentionalDisconnect else { return }
        cleanup()
        state = .reconnecting
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectInterval, repeats: false) { [weak self] _ in
            guard let self, !self.intentionalDisconnect else { return }
            let config = WeaBotConfig.shared
            guard let secret = config.loadSecret(), !config.appId.isEmpty else { return }
            self.connect(appId: config.appId, appSecret: secret)
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension WeaWebSocket: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.onConnected()
        }
        receiveNext()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        DispatchQueue.main.async { [weak self] in
            if closeCode.rawValue == 1008 {
                self?.logger.error("WEA rejected connection (1008), not reconnecting")
                self?.state = .disconnected
            } else {
                self?.scheduleReconnect()
            }
        }
    }
}
```

**Step 2: Verify it compiles**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-wea-build build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/Wea/WeaWebSocket.swift
git commit -m "feat(wea): add WebSocket connection manager with pull-based fetch"
```

---

## Task 5: WeaHttpClient — Outbound Message Sending

**Files:**
- Create: `Sources/Wea/WeaHttpClient.swift`

**Reference:** `../claude_wea/src/bot/difft-client.ts`

**Step 1: Implement the HTTP client**

```swift
// Sources/Wea/WeaHttpClient.swift
import Foundation
import os

/// Sends messages (TEXT/CARD/REFRESH) to WEA via Difft OpenAPI.
final class WeaHttpClient {
    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "WeaHttpClient")
    private let baseURL = "https://openapi.difft.org"
    private let maxTextLength = 3800
    private let maxCardLength = 3500
    private let session = URLSession.shared

    private let appId: String
    private let appSecret: String
    private let botId: String

    init(appId: String, appSecret: String, botId: String) {
        self.appId = appId
        self.appSecret = appSecret
        self.botId = botId
    }

    // MARK: - Public API

    /// Send a smart reply: auto-selects TEXT vs CARD based on content.
    func sendReply(
        text: String,
        dest: WeaMessageDest,
        topicContext: [String: Any]? = nil
    ) async throws {
        let hasMarkdown = text.range(of: #"[#*`\[\]>|]"#, options: .regularExpression) != nil
        let isLong = text.count > 200

        if hasMarkdown || isLong {
            try await sendCard(content: text, dest: dest, context: topicContext)
        } else {
            try await sendText(body: text, dest: dest, context: topicContext)
        }
    }

    /// Send a CARD message (markdown content, creates a new chat bubble).
    /// Returns the card ID for subsequent REFRESH calls.
    @discardableResult
    func sendCard(
        content: String,
        dest: WeaMessageDest,
        context: [String: Any]? = nil,
        cardId: String? = nil
    ) async throws -> String {
        let id = cardId ?? "claude-\(UUID().uuidString.lowercased())"
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let preview = String(content.prefix(200))

        var payload: [String: Any] = [
            "version": 1,
            "type": "CARD",
            "src": botId,
            "srcDevice": 1,
            "dest": dest.json,
            "timestamp": now,
            "msg": ["body": preview],
            "card": [
                "appID": appId,
                "id": id,
                "content": String(content.prefix(maxCardLength)),
                "creator": botId,
                "timestamp": now,
                "fixedWidth": false,
                "version": now,
            ] as [String: Any],
        ]
        if let context { payload["context"] = context }

        try await sendMessage(payload)
        return id
    }

    /// Refresh an existing CARD (updates in-place, no new bubble).
    func refreshCard(
        cardId: String,
        content: String,
        dest: WeaMessageDest,
        context: [String: Any]? = nil
    ) async throws {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var payload: [String: Any] = [
            "version": 1,
            "type": "REFRESH",
            "src": botId,
            "srcDevice": 1,
            "dest": dest.json,
            "timestamp": now,
            "card": [
                "id": cardId,
                "content": String(content.prefix(maxCardLength)),
                "version": now,
            ] as [String: Any],
        ]
        if let context { payload["context"] = context }

        try await sendMessage(payload)
    }

    /// Send a plain TEXT message.
    func sendText(
        body: String,
        dest: WeaMessageDest,
        context: [String: Any]? = nil
    ) async throws {
        let chunks = splitText(body, maxLength: maxTextLength)
        for chunk in chunks {
            var payload: [String: Any] = [
                "version": 1,
                "type": "TEXT",
                "src": botId,
                "srcDevice": 1,
                "dest": dest.json,
                "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                "msg": ["body": chunk],
            ]
            if let context { payload["context"] = context }
            try await sendMessage(payload)
        }
    }

    // MARK: - Private

    private func sendMessage(_ payload: [String: Any]) async throws {
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? ""

        let path = "/v1/messages"
        let signed = WeaSignature.signPost(
            appId: appId, appSecret: appSecret,
            path: path, jsonBody: jsonStr
        )

        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (key, value) in signed.httpHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("WEA API error \(httpResponse.statusCode): \(body)")
            throw WeaError.apiError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    /// Split text at paragraph/line/word boundaries.
    func splitText(_ text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength else { return [text] }
        var chunks: [String] = []
        var remaining = text

        while !remaining.isEmpty {
            if remaining.count <= maxLength {
                chunks.append(remaining)
                break
            }
            let prefix = String(remaining.prefix(maxLength))
            // Try paragraph boundary
            if let range = prefix.range(of: "\n\n", options: .backwards) {
                let chunk = String(prefix[..<range.lowerBound])
                chunks.append(chunk)
                remaining = String(remaining[range.upperBound...])
            // Try line boundary
            } else if let range = prefix.range(of: "\n", options: .backwards) {
                let chunk = String(prefix[..<range.lowerBound])
                chunks.append(chunk)
                remaining = String(remaining[range.upperBound...])
            // Try word boundary
            } else if let range = prefix.range(of: " ", options: .backwards) {
                let chunk = String(prefix[..<range.lowerBound])
                chunks.append(chunk)
                remaining = String(remaining[range.upperBound...])
            } else {
                // Hard cut
                chunks.append(prefix)
                remaining = String(remaining.dropFirst(maxLength))
            }
        }
        return chunks
    }
}

enum WeaError: LocalizedError {
    case apiError(statusCode: Int, body: String)
    case notConfigured
    case notConnected

    var errorDescription: String? {
        switch self {
        case .apiError(let code, let body): return "WEA API error \(code): \(body)"
        case .notConfigured: return "WEA bot is not configured"
        case .notConnected: return "WEA bot is not connected"
        }
    }
}
```

**Step 2: Verify it compiles**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-wea-build build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/Wea/WeaHttpClient.swift
git commit -m "feat(wea): add HTTP client for TEXT/CARD/REFRESH message sending"
```

---

## Task 6: WeaTerminalBridge — Terminal ↔ WEA Bridge

**Files:**
- Create: `Sources/Wea/WeaTerminalBridge.swift`

**Step 1: Implement the bridge**

This is the core bridge between WEA messages and terminal tabs. It:
- Injects WEA messages into the terminal via `sendInput()`
- Tracks active WEA messages (to discriminate WEA vs local input)
- Watches transcript JSONL for streaming output
- Sends replies back to WEA via `WeaHttpClient`

```swift
// Sources/Wea/WeaTerminalBridge.swift
import Foundation
import os

/// Bridges WEA messages to/from a terminal running Claude.
/// One instance per session (DM or group chat tab).
@MainActor
final class WeaTerminalBridge {
    enum State: Equatable {
        case idle
        case processing       // Claude is working on a WEA message
        case waitingInput     // Claude is asking a question
    }

    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "WeaTerminalBridge")
    let sessionKey: String              // "direct:{wuid}" or "group:{groupId}"
    private weak var panel: TerminalPanel?
    private let httpClient: WeaHttpClient
    private let dest: WeaMessageDest

    private(set) var state: State = .idle
    private var activeCardId: String?
    private var transcriptWatcher: DispatchSourceFileSystemObject?
    private var transcriptPath: String?
    private var transcriptOffset: UInt64 = 0
    private var accumulatedText: String = ""
    private var lastRefreshTime: Date = .distantPast
    private let refreshThrottleInterval: TimeInterval = 0.8

    /// Set by WeaBotService when a WEA message is being injected.
    /// Claude Code hooks check this to know if the current prompt is from WEA.
    var isWeaMessageActive: Bool { state == .processing || state == .waitingInput }

    /// Flag file used by hooks to detect WEA-originated prompts.
    var weaActiveMarkerPath: String {
        let dir = NSTemporaryDirectory()
        let safe = sessionKey.replacingOccurrences(of: ":", with: "_")
        return "\(dir)cmux-wea-active-\(safe)"
    }

    init(sessionKey: String, panel: TerminalPanel, httpClient: WeaHttpClient, dest: WeaMessageDest) {
        self.sessionKey = sessionKey
        self.panel = panel
        self.httpClient = httpClient
        self.dest = dest
    }

    deinit {
        stopTranscriptWatch()
        cleanupMarker()
    }

    // MARK: - Inject WEA message into terminal

    func injectMessage(_ text: String) async {
        guard let panel else {
            logger.warning("Panel is nil for session \(self.sessionKey)")
            return
        }

        state = .processing
        accumulatedText = ""
        writeMarker()

        // Send initial "thinking..." card to WEA
        do {
            activeCardId = try await httpClient.sendCard(
                content: "thinking...",
                dest: dest
            )
        } catch {
            logger.error("Failed to send thinking card: \(error.localizedDescription)")
        }

        // Inject the message text into the terminal
        panel.sendInput(text + "\n")
    }

    // MARK: - Hook Callbacks (called by WeaBotService)

    /// Called when Stop hook fires — Claude finished responding.
    func onClaudeStop(transcriptPath: String?, lastMessage: String?) async {
        guard state == .processing || state == .waitingInput else { return }
        stopTranscriptWatch()

        // Read full reply from transcript if available
        let fullReply: String
        if let path = transcriptPath {
            fullReply = readLastAssistantMessage(from: path) ?? lastMessage ?? accumulatedText
        } else {
            fullReply = lastMessage ?? accumulatedText
        }

        guard !fullReply.isEmpty else {
            state = .idle
            cleanupMarker()
            return
        }

        // Send final reply to WEA
        do {
            if let cardId = activeCardId {
                try await httpClient.refreshCard(cardId: cardId, content: fullReply, dest: dest)
            } else {
                try await httpClient.sendReply(text: fullReply, dest: dest)
            }
        } catch {
            logger.error("Failed to send reply to WEA: \(error.localizedDescription)")
        }

        state = .idle
        activeCardId = nil
        cleanupMarker()
    }

    /// Called when Claude needs user input (Notification hook).
    func onNeedsInput(question: String) async {
        state = .waitingInput

        do {
            try await httpClient.sendReply(text: question, dest: dest)
        } catch {
            logger.error("Failed to forward question to WEA: \(error.localizedDescription)")
        }
    }

    /// Called when PreToolUse fires AskUserQuestion.
    func onAskUserQuestion(questionText: String) async {
        state = .waitingInput

        do {
            try await httpClient.sendReply(text: questionText, dest: dest)
        } catch {
            logger.error("Failed to forward AskUserQuestion to WEA: \(error.localizedDescription)")
        }
    }

    /// Called when a WEA user replies to a question.
    func injectQuestionReply(_ reply: String) {
        guard state == .waitingInput, let panel else { return }
        state = .processing
        panel.sendInput(reply + "\n")
    }

    // MARK: - Transcript Watching (for streaming)

    func startTranscriptWatch(path: String) {
        stopTranscriptWatch()
        self.transcriptPath = path

        // Record current file size as offset (skip pre-existing content)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            transcriptOffset = (attrs[.size] as? UInt64) ?? 0
        }

        guard let fd = open(path, O_RDONLY | O_EVTONLY).nilIfNegative else {
            logger.warning("Cannot open transcript for watching: \(path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.readNewTranscriptLines()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        transcriptWatcher = source
    }

    private func stopTranscriptWatch() {
        transcriptWatcher?.cancel()
        transcriptWatcher = nil
    }

    private func readNewTranscriptLines() {
        guard let path = transcriptPath,
              let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        handle.seek(toFileOffset: transcriptOffset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        transcriptOffset += UInt64(data.count)

        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  role == "assistant",
                  let content = message["content"] as? [[String: Any]] else {
                continue
            }

            for block in content {
                if (block["type"] as? String) == "text",
                   let blockText = block["text"] as? String {
                    accumulatedText += blockText
                }
            }
        }

        // Throttled REFRESH to WEA
        let now = Date()
        guard now.timeIntervalSince(lastRefreshTime) >= refreshThrottleInterval,
              let cardId = activeCardId,
              !accumulatedText.isEmpty else { return }

        lastRefreshTime = now
        let content = accumulatedText
        Task { @MainActor in
            try? await httpClient.refreshCard(cardId: cardId, content: content, dest: dest)
        }
    }

    // MARK: - Read full assistant message from transcript

    private func readLastAssistantMessage(from path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8) else { return nil }

        var lastText: String?
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  role == "assistant" else { continue }

            if let contentArr = message["content"] as? [[String: Any]] {
                let texts = contentArr.compactMap { block -> String? in
                    guard (block["type"] as? String) == "text",
                          let t = block["text"] as? String else { return nil }
                    return t
                }
                let joined = texts.joined(separator: "\n")
                if !joined.isEmpty { lastText = joined }
            } else if let contentStr = message["content"] as? String, !contentStr.isEmpty {
                lastText = contentStr
            }
        }
        return lastText
    }

    // MARK: - Marker file for hook discrimination

    private func writeMarker() {
        FileManager.default.createFile(atPath: weaActiveMarkerPath, contents: Data())
    }

    private func cleanupMarker() {
        try? FileManager.default.removeItem(atPath: weaActiveMarkerPath)
    }
}

private extension Int32 {
    var nilIfNegative: Int32? { self >= 0 ? self : nil }
}
```

**Step 2: Verify it compiles**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-wea-build build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED (may need to add file to Xcode project first)

**Step 3: Commit**

```bash
git add Sources/Wea/WeaTerminalBridge.swift
git commit -m "feat(wea): add terminal bridge with transcript watching and streaming"
```

---

## Task 7: WeaBotService — Core Orchestrator

**Files:**
- Create: `Sources/Wea/WeaBotService.swift`

**Step 1: Implement the orchestrator**

This is the main service that ties everything together: WebSocket connection, message routing, session management, and bridge lifecycle.

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

    @Published private(set) var state: ServiceState = .stopped
    private var bridges: [String: WeaTerminalBridge] = [:]  // sessionKey → bridge
    private var weaWorkspaceId: UUID?

    /// Callback to create a new group chat tab. Set by the UI layer.
    var onCreateGroupTab: ((_ groupId: String, _ groupName: String) -> TerminalPanel?)?
    /// Callback to get the main DM tab's panel.
    var onGetMainPanel: (() -> TerminalPanel?)?
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
                case .connected: self.state = .running
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

        httpClient = WeaHttpClient(appId: config.appId, appSecret: secret, botId: config.botId)
        state = .connecting
        webSocket.connect(appId: config.appId, appSecret: secret)
    }

    func stop() {
        webSocket.disconnect()
        for bridge in bridges.values {
            Task { await bridge.onClaudeStop(transcriptPath: nil, lastMessage: nil) }
        }
        bridges.removeAll()
        httpClient = nil
        state = .stopped
    }

    // MARK: - Message Routing

    private func handleInboundMessage(_ payload: [String: Any]) {
        let config = WeaBotConfig.shared
        guard let message = WeaMessageParser.parse(payload, botId: config.botId) else { return }

        switch message.chatType {
        case .directMessage:
            routeDirectMessage(message)
        case .groupChat:
            routeGroupMessage(message)
        }
    }

    private func routeDirectMessage(_ message: WeaParsedMessage) {
        let sessionKey = "direct:\(message.senderWuid)"
        routeToSession(sessionKey: sessionKey, message: message)
    }

    private func routeGroupMessage(_ message: WeaParsedMessage) {
        guard let groupId = message.groupId else { return }
        let config = WeaBotConfig.shared

        // Check blacklist
        guard !config.isBlacklisted(groupId) else { return }

        // Only process if bot is mentioned or in bot topic
        guard message.isMentioned else { return }

        // Track known groups
        if let name = message.groupName, !name.isEmpty {
            config.knownGroups[groupId] = name
        }

        let sessionKey = "group:\(groupId)"
        routeToSession(sessionKey: sessionKey, message: message)
    }

    private func routeToSession(sessionKey: String, message: WeaParsedMessage) {
        let bridge: WeaTerminalBridge

        if let existing = bridges[sessionKey] {
            bridge = existing
        } else {
            guard let newBridge = createBridge(sessionKey: sessionKey, message: message) else {
                logger.error("Failed to create bridge for session \(sessionKey)")
                return
            }
            bridge = newBridge
            bridges[sessionKey] = bridge
        }

        // If bridge is waiting for input (question reply), treat this as a reply
        if bridge.state == .waitingInput {
            bridge.injectQuestionReply(message.text)
        } else {
            Task {
                await bridge.injectMessage(message.text)
            }
        }
    }

    private func createBridge(sessionKey: String, message: WeaParsedMessage) -> WeaTerminalBridge? {
        guard let httpClient else { return nil }
        let dest = WeaMessageParser.replyDest(for: message)
        let panel: TerminalPanel?

        if message.chatType == .directMessage {
            panel = onGetMainPanel?()
        } else {
            let groupName = message.groupName ?? message.groupId ?? "Group"
            panel = onCreateGroupTab?(message.groupId!, groupName)
        }

        guard let panel else { return nil }
        return WeaTerminalBridge(
            sessionKey: sessionKey,
            panel: panel,
            httpClient: httpClient,
            dest: dest
        )
    }

    // MARK: - Hook Integration

    /// Called by claude-hook handler when Stop fires on a WEA session.
    func handleClaudeStop(workspaceId: String, transcriptPath: String?, lastMessage: String?) {
        // Find the bridge associated with this workspace
        for bridge in bridges.values {
            guard bridge.isWeaMessageActive else { continue }
            Task {
                await bridge.onClaudeStop(transcriptPath: transcriptPath, lastMessage: lastMessage)
            }
            return
        }
    }

    /// Called by claude-hook handler when Notification fires.
    func handleClaudeNotification(workspaceId: String, question: String) {
        for bridge in bridges.values {
            guard bridge.isWeaMessageActive else { continue }
            Task {
                await bridge.onNeedsInput(question: question)
            }
            return
        }
    }

    /// Called by claude-hook when PreToolUse(AskUserQuestion) fires.
    func handleAskUserQuestion(workspaceId: String, questionText: String) {
        for bridge in bridges.values {
            guard bridge.isWeaMessageActive else { continue }
            Task {
                await bridge.onAskUserQuestion(questionText: questionText)
            }
            return
        }
    }

    /// Called by claude-hook when SessionStart fires (to begin transcript watch).
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
}
```

**Step 2: Verify it compiles**

Run:
```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-wea-build build 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/Wea/WeaBotService.swift
git commit -m "feat(wea): add WeaBotService orchestrator with message routing"
```

---

## Task 8: UI — WEA Bot Config Menu & Sheet

**Files:**
- Modify: `Sources/cmuxApp.swift` (add menu item + config sheet)

**Step 1: Add WEA Bot menu item**

In `cmuxApp.swift`, find the `.commands {}` block (line 368). After the Settings button (around line 374), add:

```swift
// After the existing Settings button, before CommandGroup(replacing: .appInfo)
Button(String(localized: "menu.app.weaBot", defaultValue: "WEA Bot...")) {
    appDelegate.showWeaBotConfig()
}
```

**Step 2: Add the config sheet view**

Add a new SwiftUI view `WeaBotConfigSheet` either in a new file `Sources/Wea/WeaBotConfigSheet.swift` or at the bottom of `cmuxApp.swift`. Follow existing `SettingsView` patterns (SettingsSectionHeader, SettingsCard, SettingsCardRow).

**Step 3: Add AppDelegate method to show the sheet**

In `AppDelegate.swift`, add:

```swift
func showWeaBotConfig() {
    // Present WeaBotConfigSheet as a sheet/window
}
```

**Step 4: Verify it compiles and commit**

```bash
git add Sources/Wea/WeaBotConfigSheet.swift Sources/cmuxApp.swift Sources/AppDelegate.swift
git commit -m "feat(wea): add WEA Bot configuration menu and sheet"
```

---

## Task 9: UI — main-wea Workspace & Tab Creation

**Files:**
- Modify: `Sources/cmuxApp.swift` or `Sources/TabManager.swift`
- Create: `Sources/Wea/WeaWorkspaceManager.swift`

**Step 1: Create the workspace manager**

This connects `WeaBotService` to `TabManager`, creating the `main-wea` workspace and handling group chat tab creation.

```swift
// Sources/Wea/WeaWorkspaceManager.swift
import Foundation

/// Manages the main-wea workspace and its tabs.
@MainActor
final class WeaWorkspaceManager {
    private weak var tabManager: TabManager?
    private var weaWorkspace: Workspace?

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        setupCallbacks()
    }

    private func setupCallbacks() {
        let service = WeaBotService.shared
        service.tabManager = tabManager

        service.onGetMainPanel = { [weak self] in
            self?.getMainPanel()
        }

        service.onCreateGroupTab = { [weak self] groupId, groupName in
            self?.createGroupTab(groupId: groupId, groupName: groupName)
        }
    }

    func createWeaWorkspace() {
        guard let tabManager else { return }
        let workspace = tabManager.addWorkspace(
            title: "main-wea",
            initialTerminalCommand: "codemax claude --dangerously-skip-permissions",
            select: true
        )
        weaWorkspace = workspace
    }

    func destroyWeaWorkspace() {
        guard let workspace = weaWorkspace, let tabManager else { return }
        tabManager.closeWorkspace(workspace)
        weaWorkspace = nil
    }

    private func getMainPanel() -> TerminalPanel? {
        guard let workspace = weaWorkspace else { return nil }
        // The first panel in the workspace is the "main" DM tab
        return workspace.panels.values.compactMap { $0 as? TerminalPanel }.first
    }

    private func createGroupTab(groupId: String, groupName: String) -> TerminalPanel? {
        guard let workspace = weaWorkspace else { return nil }
        // Create a new terminal panel (tab) in the WEA workspace
        // with the group name as title, running claude
        let panel = TerminalPanel(
            workspaceId: workspace.id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: workspace.configTemplate,
            initialCommand: "codemax claude --dangerously-skip-permissions"
        )
        workspace.panels[panel.id] = panel
        // Create bonsplit tab for this panel
        if let tabId = workspace.bonsplitController.createTab(
            title: groupName,
            icon: "bubble.left.fill",
            kind: SurfaceKind.terminal,
            isDirty: false,
            isPinned: false
        ) {
            workspace.surfaceIdToPanelId[tabId] = panel.id
        }
        return panel
    }

    var hasWeaWorkspace: Bool { weaWorkspace != nil }
}
```

**Step 2: Wire into app startup**

In `cmuxApp.swift` or `AppDelegate`, when the user connects the bot:
1. Create `WeaWorkspaceManager(tabManager:)`
2. Call `createWeaWorkspace()`
3. Call `WeaBotService.shared.start()`

**Step 3: Commit**

```bash
git add Sources/Wea/WeaWorkspaceManager.swift
git commit -m "feat(wea): add workspace manager for main-wea sidebar and group tabs"
```

---

## Task 10: UI — Close Confirmation & Tab Context Menu

**Files:**
- Modify: `Sources/ContentView.swift` (context menu additions)
- Modify: `Sources/TabManager.swift` (close confirmation logic)

**Step 1: Add close confirmation for main-wea**

In `TabManager.closeWorkspaceWithConfirmation()` (around line 2714), add a check:

```swift
// If this is the WEA workspace, show disconnect confirmation
if workspace.displayTitle == "main-wea" && WeaBotService.shared.isRunning {
    // Show alert: "Closing this workspace will disconnect the WEA bot..."
    // On confirm: WeaBotService.shared.stop() then close
}
```

**Step 2: Add "Block this group" to tab context menu**

In `ContentView.swift`, in the `workspaceContextMenu` (line 11659), add for WEA group tabs:

```swift
// After existing close buttons, add for WEA group tabs:
if isWeaGroupTab {
    Divider()
    Button(String(localized: "contextMenu.blockGroup", defaultValue: "Block This Group")) {
        // Add to blacklist, close tab
        WeaBotConfig.shared.addToBlacklist(groupId)
        WeaBotService.shared.removeBridge(for: "group:\(groupId)")
        // Close tab
    }
}
```

**Step 3: Commit**

```bash
git add Sources/ContentView.swift Sources/TabManager.swift
git commit -m "feat(wea): add close confirmation and block-group context menu"
```

---

## Task 11: Hook Integration — PostToolUse & WEA Discrimination

**Files:**
- Modify: `Resources/bin/claude` (add PostToolUse hook)
- Modify: `CLI/cmux.swift` (add hook handlers for WEA)

**Step 1: Add PostToolUse to HOOKS_JSON**

In `Resources/bin/claude` line 89, add PostToolUse to the JSON:

```bash
# Add after PreToolUse entry:
,"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"cmux claude-hook post-tool-use","timeout":5,"async":true}]}]
```

**Step 2: Add WEA-aware hook dispatch in CLI**

In `CLI/cmux.swift`, in the `runClaudeHook` function, modify the `stop` case to notify `WeaBotService` if the session has an active WEA marker:

```swift
case "post-tool-use":
    // Check if WEA marker exists, if so notify WeaBotService for streaming
    // This is async and non-blocking
    print("OK")
```

For the `stop` case, after existing notification logic, add:

```swift
// Notify WeaBotService if this was a WEA session
// Check for marker file at /tmp/cmux-wea-active-{sessionKey}
```

**Step 3: Commit**

```bash
git add Resources/bin/claude CLI/cmux.swift
git commit -m "feat(wea): add PostToolUse hook and WEA-aware hook dispatch"
```

---

## Task 12: Integration Testing & Polish

**Files:**
- All Wea/ files for compile verification
- Localization strings

**Step 1: Verify full build**

```bash
./scripts/reload.sh --tag wea-integration
```

**Step 2: Add localization keys**

Add to `Resources/Localizable.xcstrings`:
- `menu.app.weaBot` — "WEA Bot..."
- `contextMenu.blockGroup` — "Block This Group"
- `weaBot.config.title` — "WEA Bot Configuration"
- `weaBot.config.appId` — "App ID"
- `weaBot.config.appSecret` — "App Secret"
- `weaBot.config.botId` — "Bot ID"
- `weaBot.config.connect` — "Connect"
- `weaBot.config.disconnect` — "Disconnect"
- `weaBot.close.title` — "Disconnect WEA Bot?"
- `weaBot.close.message` — "Closing this workspace will disconnect the WEA bot. All group chat sessions will be terminated."

**Step 3: Final commit**

```bash
git add -A
git commit -m "feat(wea): localization and integration polish"
```

---

## Summary

| Task | Component | Files |
|------|-----------|-------|
| 1 | WeaBotConfig | `Sources/Wea/WeaBotConfig.swift` |
| 2 | WeaSignature | `Sources/Wea/WeaSignature.swift` |
| 3 | WeaMessageParser | `Sources/Wea/WeaMessageParser.swift` |
| 4 | WeaWebSocket | `Sources/Wea/WeaWebSocket.swift` |
| 5 | WeaHttpClient | `Sources/Wea/WeaHttpClient.swift` |
| 6 | WeaTerminalBridge | `Sources/Wea/WeaTerminalBridge.swift` |
| 7 | WeaBotService | `Sources/Wea/WeaBotService.swift` |
| 8 | Config UI | `Sources/Wea/WeaBotConfigSheet.swift` + menu |
| 9 | Workspace Manager | `Sources/Wea/WeaWorkspaceManager.swift` |
| 10 | Close/Blacklist UI | `Sources/ContentView.swift`, `TabManager.swift` |
| 11 | Hook Integration | `Resources/bin/claude`, `CLI/cmux.swift` |
| 12 | Polish & Build | Localization, full build verification |

**Dependencies:** Tasks 1-5 are independent (can be parallelized). Task 6 depends on 5. Task 7 depends on 4+5+6. Tasks 8-10 depend on 1+7. Task 11 depends on 7. Task 12 depends on all.
