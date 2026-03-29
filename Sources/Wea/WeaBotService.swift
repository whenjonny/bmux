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
        }

        httpClient = WeaHttpClient(appId: config.appId, appSecret: secret, botId: config.botId)
        state = .connecting
        webSocket.connect(appId: config.appId, appSecret: secret)
    }

    func stop() {
        webSocket.disconnect()
        bridges.removeAll()
        workspaceSessionKeys.removeAll()
        registry.removeAll()
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
            // Recreate if terminal panel is gone OR Claude process exited.
            let panelLive = workspaceManager?.hasLiveTerminalPanel(groupId: groupId, panelId: existing.panelId) == true
            if panelLive && existing.processAlive {
                bridge = existing
            } else {
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

        workspaceSessionKeys[panel.workspaceId.uuidString.lowercased()] = sessionKey
        registry.register(sessionKey: sessionKey, groupId: groupId, displayName: displayName)

        return WeaTerminalBridge(
            sessionKey: sessionKey,
            panel: panel,
            httpClient: httpClient,
            dest: dest,
            launcherCommands: workspaceManager.claudeRetryCommands(for: groupId)
        )
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

    func handleSessionStart(workspaceId: String, transcriptPath: String?) {
        if let bridge = bridge(forWorkspaceId: workspaceId) {
            bridge.startTranscriptWatch(path: transcriptPath)
            return
        }
        for bridge in bridges.values where bridge.isWeaMessageActive {
            bridge.startTranscriptWatch(path: transcriptPath)
            return
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
