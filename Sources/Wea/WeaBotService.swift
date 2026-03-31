// Sources/Wea/WeaBotService.swift
import Foundation
import os

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
    private let registry = WeaSessionRegistry()
    private var httpClient: WeaHttpClient?
    private var workspaceManager: WeaWorkspaceManager?

    @Published private(set) var state: ServiceState = .stopped
    private var bridges: [String: WeaTerminalBridge] = [:]
    private var workspaceSessionKeys: [String: String] = [:]  // workspace UUID string -> sessionKey

    // B1: Pre-service message queue — buffers messages arriving before .running state
    private var preServiceQueue: [(payload: [String: Any], receivedAt: Date)] = []
    private static let preServiceQueueMaxSize = 100
    private static let preServiceMessageTTL: TimeInterval = 60

    // B2: Dead bridge periodic cleanup timer
    private var cleanupTimer: Timer?

    // B3: Per-session rate limiting — sessionKey → recent message timestamps
    private var messageTimestamps: [String: [Date]] = [:]
    private static let rateLimitWindow: TimeInterval = 60
    private static let rateLimitMaxMessages = 10

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
                    self.flushPreServiceQueue()
                case .connecting: self.state = .connecting
                case .reconnecting: self.state = .reconnecting
                case .disconnected:
                    if case .error = self.state {} else {
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
            reconnectRestoredWorkspaces(tabManager: tabManager)
        }

        httpClient = WeaHttpClient(appId: config.appId, appSecret: secret, botId: config.botId)
        state = .connecting
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupDeadBridges()
            }
        }
        webSocket.connect(appId: config.appId, appSecret: secret)
    }

    func stop() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        webSocket.disconnect()
        bridges.removeAll()
        workspaceSessionKeys.removeAll()
        messageTimestamps.removeAll()
        preServiceQueue.removeAll()
        // Don't clear the file-based registry — it's useful for restart reconnection.
        // Don't close WeA workspaces — they persist across disconnect/reconnect and app restarts.
        httpClient = nil
        workspaceManager = nil
        state = .stopped
    }

    // MARK: - Restored Workspace Reconnection

    /// Pre-populate workspace→sessionKey mappings for WeA workspaces that were restored
    /// from the session snapshot. Bridges are created lazily when the first message arrives.
    private func reconnectRestoredWorkspaces(tabManager: TabManager) {
        for workspace in tabManager.tabs {
            guard let groupId = workspace.weaGroupId else { continue }
            let sessionKey = sessionKey(for: groupId)
            workspaceSessionKeys[workspace.id.uuidString.lowercased()] = sessionKey
            logger.info("Reconnected restored WEA workspace '\(workspace.title)' for \(groupId)")
        }
    }

    /// Derive a session key from a group ID. Group messages use "group:{id}",
    /// DM sessions use "direct:{wuid}". For restored workspaces where we don't
    /// know the chat type, we inspect the groupId format to determine the key.
    private func sessionKey(for groupId: String) -> String {
        // The groupId stored on the workspace is the raw group/wuid value.
        // During routeDirectMessage we use "direct:{wuid}" and in routeGroupMessage "group:{groupId}".
        // For restored workspaces, check if the registry has an entry to determine the prefix.
        // Fall back to "group:" since that's the most common case.
        if let entry = registry.entry(for: "direct:\(groupId)") {
            return "direct:\(entry.groupId)"
        }
        return "group:\(groupId)"
    }

    // MARK: - Message Routing

    /// Messages older than this (in milliseconds) are dropped on reconnect to avoid backlog noise.
    private static let staleMessageThresholdMs: Int64 = 30_000

    private func handleInboundMessage(_ payload: [String: Any]) {
        // B1: Queue messages arriving before service is fully running
        if state != .running {
            if preServiceQueue.count >= Self.preServiceQueueMaxSize {
                preServiceQueue.removeFirst()
                logger.warning("Pre-service queue overflow — dropped oldest message")
            }
            preServiceQueue.append((payload: payload, receivedAt: Date()))
            weaLog("[queue.preService] count=\(preServiceQueue.count)")
            return
        }

        let config = WeaBotConfig.shared
        let message: WeaParsedMessage
        do {
            message = try WeaMessageParser.parse(payload, botId: config.botId)
        } catch {
            return
        }

        // Drop stale messages that arrive as backlog on WebSocket reconnect.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let ageMs = nowMs - message.timestamp
        if ageMs > Self.staleMessageThresholdMs {
            logger.info("Dropping stale WEA message (age=\(ageMs)ms): \(message.text.prefix(40))")
            return
        }

        logger.info("WEA inbound: type=\(message.chatType.rawValue) groupId=\(message.groupId ?? "nil") groupName=\(message.groupName ?? "nil") sender=\(message.senderWuid) mention=\(message.isMentionBot) text=\(message.text.prefix(40))")

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

        // Prefer the group name from the payload, fall back to existing known name.
        if let name = message.groupName, !name.isEmpty {
            config.knownGroups[groupId] = name
        }

        let sessionKey = "group:\(groupId)"
        let displayName = config.knownGroups[groupId]
            ?? "Group \(String(groupId.prefix(6)))"
        let bridgeCount = self.bridges.count
        let hasExisting = self.bridges[sessionKey] != nil
        logger.info("WEA group route: \(sessionKey) → '\(displayName)' (bridges=\(bridgeCount) existing=\(hasExisting))")
        routeToSession(sessionKey: sessionKey, groupId: groupId, displayName: displayName, message: message)
    }

    private func routeToSession(sessionKey: String, groupId: String, displayName: String, message: WeaParsedMessage) {
        // B3: Per-session rate limiting
        var timestamps = messageTimestamps[sessionKey, default: []]
        let cutoff = Date().addingTimeInterval(-Self.rateLimitWindow)
        timestamps.removeAll { $0 < cutoff }
        if timestamps.count >= Self.rateLimitMaxMessages {
            weaLog("[rateLimit.exceeded] sessionKey=\(sessionKey) count=\(timestamps.count)")
            Task {
                try? await httpClient?.sendReply(
                    text: "Rate limited — please wait before sending more messages.",
                    dest: WeaMessageParser.replyDest(for: message)
                )
            }
            return
        }
        timestamps.append(Date())
        messageTimestamps[sessionKey] = timestamps

        let bridge: WeaTerminalBridge

        if let existing = bridges[sessionKey] {
            let panelLive = workspaceManager?.hasLiveTerminalPanel(groupId: groupId, panelId: existing.panelId) == true
            if panelLive && existing.processAlive {
                bridge = existing
            } else if panelLive && !existing.processAlive {
                // Panel exists but Claude died — restart Claude in the same terminal.
                logger.info("Restarting Claude in existing panel for \(sessionKey)")
                existing.restartClaude(command: workspaceManager?.launchCommand(for: groupId) ?? "")
                bridge = existing
            } else {
                // Panel gone — recreate everything.
                logger.info("Recreating bridge for \(sessionKey): panelLive=\(panelLive) processAlive=\(existing.processAlive)")
                bridges.removeValue(forKey: sessionKey)
                registry.markDead(sessionKey: sessionKey)
                if let newBridge = createBridge(sessionKey: sessionKey, groupId: groupId, displayName: displayName, message: message) {
                    bridge = newBridge
                    bridges[sessionKey] = bridge
                } else {
                    logger.error("Failed to recreate bridge for session \(sessionKey)")
                    return
                }
            }
        } else {
            guard let newBridge = createBridge(sessionKey: sessionKey, groupId: groupId, displayName: displayName, message: message) else {
                logger.error("Failed to create bridge for session \(sessionKey)")
                return
            }
            bridge = newBridge
            bridges[sessionKey] = bridge
        }

        registry.touchMessage(sessionKey: sessionKey)

        Task {
            await bridge.injectMessage(message.text)
        }
    }

    private func createBridge(sessionKey: String, groupId: String, displayName: String, message: WeaParsedMessage) -> WeaTerminalBridge? {
        guard let httpClient, let workspaceManager else { return nil }
        let dest = WeaMessageParser.replyDest(for: message)

        // Check if the workspace was restored from a previous session and has a saved Claude session ID.
        let claudeSessionId = workspaceManager.workspace(for: groupId)?.claudeSessionId

        guard let panel = workspaceManager.findOrCreatePanel(groupId: groupId, displayName: displayName, claudeSessionId: claudeSessionId) else {
            return nil
        }

        workspaceSessionKeys[panel.workspaceId.uuidString.lowercased()] = sessionKey
        registry.register(sessionKey: sessionKey, groupId: groupId, displayName: displayName, workspaceId: panel.workspaceId, panelId: panel.id)

        return WeaTerminalBridge(
            sessionKey: sessionKey,
            panel: panel,
            httpClient: httpClient,
            dest: dest
        )
    }

    // MARK: - Pre-Service Queue (B1)

    private func flushPreServiceQueue() {
        guard !preServiceQueue.isEmpty else { return }
        debugLog("queue.flush count=\(preServiceQueue.count)")
        let now = Date()
        let validMessages = preServiceQueue.filter {
            now.timeIntervalSince($0.receivedAt) <= Self.preServiceMessageTTL
        }
        let expiredCount = preServiceQueue.count - validMessages.count
        if expiredCount > 0 {
            logger.info("Pre-service queue: dropped \(expiredCount) expired messages")
        }
        preServiceQueue.removeAll()
        for msg in validMessages {
            // State is .running at this point, so handleInboundMessage won't re-queue
            handleInboundMessage(msg.payload)
        }
    }

    // MARK: - Dead Bridge Cleanup (B2)

    private func cleanupDeadBridges() {
        for (key, bridge) in bridges {
            // Don't clean up bridges in .processing or .waitingInput state —
            // they may still get hook callbacks.
            guard !bridge.processAlive, bridge.state == .idle else { continue }
            bridges.removeValue(forKey: key)
            workspaceSessionKeys = workspaceSessionKeys.filter { $0.value != key }
            messageTimestamps.removeValue(forKey: key)
            registry.markDead(sessionKey: key)
            debugLog("cleanup.bridge sessionKey=\(key) reason=processDeadIdle")
        }
    }

    // MARK: - Digest

    /// Workspaces kept alive while background digest runs. Prevents deallocation
    /// so the terminal process stays alive until summarization finishes.
    private var backgroundDigestWorkspaces: [String: Workspace] = [:]  // sessionKey → Workspace

    /// Start a background digest for a WEA session. The workspace is detached from the
    /// tab list (visual close) but the terminal process stays alive. When the digest
    /// completes (or times out), the result is sent to WEA and the workspace is torn down.
    func startBackgroundDigest(sessionKey: String, groupId: String, workspace: Workspace) {
        guard let bridge = bridges[sessionKey], bridge.processAlive, bridge.replReady else {
            // Claude not alive — fallback immediately
            fallbackDigestAndNotify(for: groupId, sessionKey: sessionKey)
            return
        }

        // Hold workspace reference to keep terminal process alive
        backgroundDigestWorkspaces[sessionKey] = workspace
        logger.info("Background digest started for \(sessionKey)")

        Task {
            await bridge.injectSummarizationPrompt { [weak self] in
                Task { @MainActor in
                    self?.finishBackgroundDigest(sessionKey: sessionKey)
                }
            }
        }

        // 2-minute timeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard let self, self.backgroundDigestWorkspaces[sessionKey] != nil else { return }
            if bridge.state == .digesting {
                self.logger.warning("Background digest timed out for \(sessionKey)")
                bridge.forceFinishDigest()
                self.fallbackDigestAndNotify(for: groupId, sessionKey: sessionKey)
                self.finishBackgroundDigest(sessionKey: sessionKey)
            }
        }
    }

    /// Clean up after background digest: tear down the held workspace, remove bridge.
    private func finishBackgroundDigest(sessionKey: String) {
        if let workspace = backgroundDigestWorkspaces.removeValue(forKey: sessionKey) {
            workspace.teardownAllPanels()
            workspace.teardownRemoteConnection()
            workspace.owningTabManager = nil
            logger.info("Background digest workspace torn down for \(sessionKey)")
        }
        removeBridge(for: sessionKey)
    }

    /// Trigger knowledge digest for a workspace (non-closing), then call completion.
    func triggerDigest(forWorkspaceId workspaceId: String, completion: @escaping () -> Void) -> Bool {
        guard let bridge = bridge(forWorkspaceId: workspaceId),
              bridge.processAlive, bridge.replReady else {
            return false
        }
        Task {
            await bridge.injectSummarizationPrompt(onComplete: completion)
        }
        // 2-minute timeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if bridge.state == .digesting {
                self?.logger.warning("Digest timed out for workspace \(workspaceId)")
                bridge.forceFinishDigest()
                completion()
            }
        }
        return true
    }

    /// Fallback: copy journal.md to summary.md and notify WEA that auto-summarization was skipped.
    private func fallbackDigestAndNotify(for groupId: String, sessionKey: String) {
        let folder = WeaBotConfig.shared.sessionFolder(for: groupId)
        let journalPath = (folder as NSString).appendingPathComponent("journal.md")
        let summaryPath = (folder as NSString).appendingPathComponent("summary.md")
        if FileManager.default.fileExists(atPath: journalPath),
           !FileManager.default.fileExists(atPath: summaryPath) {
            try? FileManager.default.copyItem(atPath: journalPath, toPath: summaryPath)
        }
        logger.info("Fallback digest for \(groupId)")

        // Notify WEA
        if let bridge = bridges[sessionKey], let httpClient {
            Task {
                try? await httpClient.sendText(
                    body: "[\u{1F4CB} Session closed — auto-summarization skipped (Claude not available). Journal saved.]",
                    dest: bridge.dest
                )
            }
        }
    }

    /// Fallback: copy journal.md to summary.md when Claude is dead (public, for external callers).
    func fallbackDigest(for groupId: String) {
        let sessionKey = sessionKeyForGroup(groupId)
        fallbackDigestAndNotify(for: groupId, sessionKey: sessionKey)
    }

    /// Determine the correct session key prefix for a group ID.
    func sessionKeyForGroup(_ groupId: String) -> String {
        if let _ = registry.entry(for: "direct:\(groupId)") {
            return "direct:\(groupId)"
        }
        return "group:\(groupId)"
    }
    // MARK: - Hook Integration

    func handleClaudeStop(workspaceId: String, transcriptPath: String?, lastMessage: String?) {
        if let bridge = bridge(forWorkspaceId: workspaceId) {
            Task { await bridge.onClaudeStop(transcriptPath: transcriptPath, lastMessage: lastMessage) }
            return
        }
        for bridge in bridges.values where bridge.isWeaMessageActive {
            Task { await bridge.onClaudeStop(transcriptPath: transcriptPath, lastMessage: lastMessage) }
            return
        }
    }

    func handleClaudeNotification(workspaceId: String, question: String) {
        if let bridge = bridge(forWorkspaceId: workspaceId) {
            Task { await bridge.onNeedsInput(question: question) }
            return
        }
        for bridge in bridges.values where bridge.isWeaMessageActive {
            Task { await bridge.onNeedsInput(question: question) }
            return
        }
    }

    func handleAskUserQuestion(workspaceId: String, questionText: String) {
        if let bridge = bridge(forWorkspaceId: workspaceId) {
            Task { await bridge.onAskUserQuestion(questionText: questionText) }
            return
        }
        for bridge in bridges.values where bridge.isWeaMessageActive {
            Task { await bridge.onAskUserQuestion(questionText: questionText) }
            return
        }
    }

    func handleSessionStart(workspaceId: String, transcriptPath: String?, sessionId: String? = nil) {
        if let bridge = bridge(forWorkspaceId: workspaceId) {
            bridge.startTranscriptWatch(path: transcriptPath, sessionId: sessionId)
            storeClaudeSessionId(sessionId, forWorkspaceId: workspaceId)
            return
        }
        for bridge in bridges.values where bridge.isWeaMessageActive || bridge.hasPendingStartup {
            bridge.startTranscriptWatch(path: transcriptPath, sessionId: sessionId)
            return
        }
    }

    private func storeClaudeSessionId(_ sessionId: String?, forWorkspaceId workspaceId: String) {
        guard let sessionId, !sessionId.isEmpty else { return }
        let normalized = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let workspace = tabManager?.tabs.first(where: { $0.id.uuidString.lowercased() == normalized }) else { return }
        workspace.claudeSessionId = sessionId
    }

    // MARK: - File Sending

    /// Send a file to WEA on behalf of a workspace's Claude session.
    /// Called by the `wea_send_file` socket command.
    func handleSendFile(workspaceId: String, filePath: String, body: String) async {
        guard let bridge = bridge(forWorkspaceId: workspaceId),
              let httpClient else {
            logger.error("Cannot send file: no bridge for workspace \(workspaceId)")
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            logger.error("Cannot read file at \(filePath)")
            return
        }
        let fileName = (filePath as NSString).lastPathComponent
        let contentType = Self.mimeType(for: fileName)
        do {
            try await httpClient.sendAttachment(
                data: data,
                fileName: fileName,
                contentType: contentType,
                dest: bridge.dest,
                body: body
            )
            logger.info("Sent file \(fileName) (\(data.count)B) to WEA for \(bridge.sessionKey)")
        } catch {
            logger.error("Failed to send file \(fileName): \(error.localizedDescription)")
        }
    }

    private static func mimeType(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "txt", "log", "md": return "text/plain"
        case "json": return "application/json"
        case "csv": return "text/csv"
        case "html", "htm": return "text/html"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Process Lifecycle

    /// Called by TabManager when a WEA terminal's child process exits.
    func handleChildExited(workspaceId: String) {
        guard let bridge = bridge(forWorkspaceId: workspaceId) else { return }
        logger.info("Child process exited for session \(bridge.sessionKey)")
        bridge.markProcessExited()
        registry.markDead(sessionKey: bridge.sessionKey)
    }

    // MARK: - Session Management

    func removeBridge(for sessionKey: String) {
        bridges.removeValue(forKey: sessionKey)
        workspaceSessionKeys = workspaceSessionKeys.filter { $0.value != sessionKey }
        registry.unregister(sessionKey: sessionKey)
    }

    func bridge(for sessionKey: String) -> WeaTerminalBridge? {
        bridges[sessionKey]
    }

    var isRunning: Bool { state == .running }

    func reportConnectionError(_ message: String) {
        state = .error(message)
    }

    private func bridge(forWorkspaceId workspaceId: String) -> WeaTerminalBridge? {
        let normalized = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              let sessionKey = workspaceSessionKeys[normalized] else {
            return nil
        }
        return bridges[sessionKey]
    }
}
