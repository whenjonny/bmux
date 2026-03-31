// Sources/Wea/WeaBotService.swift
import Foundation
import os

private func weaLog(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    let path = "/tmp/cmux-wea-debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}

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
            // Clean slate on restart — close any WEA workspaces restored from the session snapshot.
            // Reconnecting restored terminals is unreliable (surface init races), so we start fresh.
            // The registry is kept so we can --resume Claude sessions when messages arrive.
            workspaceManager?.closeAllWeaWorkspaces()
        }

        httpClient = WeaHttpClient(appId: config.appId, appSecret: secret, botId: config.botId)
        state = .connecting
        webSocket.connect(appId: config.appId, appSecret: secret)
    }

    func stop() {
        webSocket.disconnect()
        bridges.removeAll()
        workspaceSessionKeys.removeAll()
        // Don't clear the file-based registry — it's useful for restart reconnection.
        // Don't close WeA workspaces — they persist across disconnect/reconnect and app restarts.
        httpClient = nil
        workspaceManager = nil
        state = .stopped
    }

    // MARK: - Message Routing

    /// Messages older than this (in milliseconds) are dropped on reconnect to avoid backlog noise.
    private static let staleMessageThresholdMs: Int64 = 30_000

    private func handleInboundMessage(_ payload: [String: Any]) {
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

        if let existing = bridges[sessionKey], backgroundDigestWorkspaces[sessionKey] == nil {
            weaLog("[Route] \(sessionKey): processAlive=\(existing.processAlive) replReady=\(existing.replReady)")

            if existing.processAlive {
                // Claude running — use as-is.
                bridge = existing
            } else {
                // Claude died — restart with --resume or --continue.
                let resumeId = existing.claudeSessionId
                    ?? registry.entry(for: sessionKey)?.claudeSessionId
                logger.info("Restarting Claude for \(sessionKey), resumeId=\(resumeId ?? "nil")")
                existing.restartClaude(command: workspaceManager?.launchCommand(for: groupId, claudeSessionId: resumeId, continueLastSession: resumeId == nil) ?? "")
                bridge = existing
            }
        } else {
            // No active bridge, or old bridge is in background digest — create fresh.
            if backgroundDigestWorkspaces[sessionKey] != nil {
                logger.info("Session \(sessionKey) in background digest — creating new session")
            }
            guard let newBridge = createBridge(sessionKey: sessionKey, groupId: groupId, displayName: displayName, message: message) else {
                logger.error("Failed to create bridge for session \(sessionKey)")
                return
            }
            bridge = newBridge
            bridges[sessionKey] = bridge
        }

        registry.touchMessage(sessionKey: sessionKey)

        if let command = message.command {
            switch command {
            case .done, .summarize:
                Task {
                    await bridge.injectSummarizationPrompt()
                }
                return
            }
        }

        Task {
            await bridge.injectMessage(message.text)
        }
    }

    private func createBridge(sessionKey: String, groupId: String, displayName: String, message: WeaParsedMessage, claudeSessionId: String? = nil) -> WeaTerminalBridge? {
        guard let httpClient, let workspaceManager else { return nil }
        let dest = WeaMessageParser.replyDest(for: message)

        // Use provided session ID, check registry, or fall back to workspace.
        let resumeId = claudeSessionId
            ?? registry.entry(for: sessionKey)?.claudeSessionId
            ?? workspaceManager.workspace(for: groupId)?.claudeSessionId

        guard let panel = workspaceManager.findOrCreatePanel(groupId: groupId, displayName: displayName, claudeSessionId: resumeId) else {
            return nil
        }

        workspaceSessionKeys[panel.workspaceId.uuidString.lowercased()] = sessionKey

        let chatTypeStr: String? = dest.type == .user ? "direct" : "group"
        registry.register(
            sessionKey: sessionKey,
            groupId: groupId,
            displayName: displayName,
            workspaceId: panel.workspaceId,
            panelId: panel.id,
            chatType: chatTypeStr,
            destGroupId: dest.groupId,
            destWuid: dest.wuid
        )

        return WeaTerminalBridge(
            sessionKey: sessionKey,
            panel: panel,
            httpClient: httpClient,
            dest: dest
        )
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
        logger.info("handleSessionStart: workspaceId=\(workspaceId), sessionId=\(sessionId ?? "nil"), bridges=\(self.bridges.count), wsKeys=\(self.workspaceSessionKeys.keys.joined(separator: ","))")
        if let bridge = bridge(forWorkspaceId: workspaceId) {
            logger.info("handleSessionStart: matched bridge \(bridge.sessionKey)")
            bridge.startTranscriptWatch(path: transcriptPath, sessionId: sessionId)
            storeClaudeSessionId(sessionId, forWorkspaceId: workspaceId)
            if let sessionId, !sessionId.isEmpty {
                registry.updateClaudeSessionId(sessionId, for: bridge.sessionKey)
                logger.info("handleSessionStart: saved sessionId=\(sessionId) for \(bridge.sessionKey)")
            }
            return
        }
        for bridge in bridges.values where bridge.isWeaMessageActive {
            logger.info("handleSessionStart: fallback matched active bridge \(bridge.sessionKey)")
            bridge.startTranscriptWatch(path: transcriptPath, sessionId: sessionId)
            if let sessionId, !sessionId.isEmpty {
                registry.updateClaudeSessionId(sessionId, for: bridge.sessionKey)
                logger.info("handleSessionStart: saved sessionId=\(sessionId) for \(bridge.sessionKey) (fallback)")
            }
            return
        }
        logger.warning("handleSessionStart: no matching bridge found for workspaceId=\(workspaceId)")
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
