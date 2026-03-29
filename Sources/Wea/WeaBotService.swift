// Sources/Wea/WeaBotService.swift
import Foundation
import os

/// Central orchestrator for WEA bot functionality.
/// Manages the WebSocket connection, routes messages to Claude subprocesses.
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

        httpClient = WeaHttpClient(appId: config.appId, appSecret: secret, botId: config.botId)
        state = .connecting
        webSocket.connect(appId: config.appId, appSecret: secret)
    }

    func stop() {
        webSocket.disconnect()
        bridges.removeAll()
        httpClient = nil
        state = .stopped
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

        Task {
            await bridge.injectMessage(message.text)
        }
    }

    private func createBridge(sessionKey: String, message: WeaParsedMessage) -> WeaTerminalBridge? {
        guard let httpClient else { return nil }
        let dest = WeaMessageParser.replyDest(for: message)
        return WeaTerminalBridge(
            sessionKey: sessionKey,
            httpClient: httpClient,
            dest: dest
        )
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
