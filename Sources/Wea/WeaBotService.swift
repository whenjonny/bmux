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
                case .connected:
                    self.state = .running
                    self.createWeaWorkspaceIfNeeded()
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
        workspaceManager?.destroyWeaWorkspace()
        workspaceManager = nil
        state = .stopped
    }

    /// Creates the "wea" sidebar workspace with a Claude session when first connected.
    private func createWeaWorkspaceIfNeeded() {
        guard let tabManager, workspaceManager == nil else { return }
        let manager = WeaWorkspaceManager(tabManager: tabManager)
        manager.createWeaWorkspace()
        workspaceManager = manager
        logger.info("Auto-created wea workspace on connect")
    }

    // MARK: - Message Routing

    private func handleInboundMessage(_ payload: [String: Any]) {
        let config = WeaBotConfig.shared
        let message: WeaParsedMessage
        do {
            message = try WeaMessageParser.parse(payload, botId: config.botId)
        } catch {
            // Skip unparseable messages (RECEIPT, RECALL, etc.)
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
        routeToSession(sessionKey: sessionKey, message: message)
    }

    private func routeGroupMessage(_ message: WeaParsedMessage) {
        guard let groupId = message.groupId else { return }
        let config = WeaBotConfig.shared

        // Check blacklist
        guard !config.isBlacklisted(groupId) else { return }

        // Only process if bot is mentioned
        guard message.isMentionBot else { return }

        // Track known groups
        if let name = message.senderName, !name.isEmpty {
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
            let groupName = message.senderName ?? message.groupId ?? "Group"
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

    /// Called by WeaWebSocket when the connection fails with an error.
    func reportConnectionError(_ message: String) {
        state = .error(message)
    }
}
