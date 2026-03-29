// Sources/Wea/WeaWebSocket.swift
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

        weaLog("[WeaWebSocket] Connecting to wss://openapi.difft.org/v1/websocket")
        weaLog("[WeaWebSocket] appId=\(appId) secretLen=\(appSecret.count) secretPrefix=\(String(appSecret.prefix(4)))")
        weaLog("[WeaWebSocket] Headers: \(signed.httpHeaders)")
        weaLog("[WeaWebSocket] Request allHTTPHeaderFields: \(request.allHTTPHeaderFields ?? [:])")

        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        webSocketTask = session?.webSocketTask(with: request)
        weaLog("[WeaWebSocket] Task originalRequest headers: \(webSocketTask?.originalRequest?.allHTTPHeaderFields ?? [:])")
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
        weaLog("[WeaWebSocket] WebSocket connected")
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
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
        weaLog("[WeaWebSocket] WebSocket closed: code=\(closeCode.rawValue) reason=\(reasonStr)")
        DispatchQueue.main.async { [weak self] in
            if closeCode.rawValue == 1008 {
                self?.state = .disconnected
            } else {
                self?.scheduleReconnect()
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            weaLog("[WeaWebSocket] Connection failed: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onStateChange?(.disconnected)
                // Report error to service
                WeaBotService.shared.reportConnectionError(error.localizedDescription)
            }
        }
    }
}
