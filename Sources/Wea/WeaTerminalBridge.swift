// Sources/Wea/WeaTerminalBridge.swift
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

/// Bridges WEA messages to/from a terminal running Claude REPL.
/// One instance per session (DM or group chat tab).
/// Messages are injected into the terminal so the user can see and interact.
@MainActor
final class WeaTerminalBridge {
    enum State: Equatable {
        case idle
        case processing       // Claude is working on a WEA message
        case waitingInput     // Claude is asking a question
    }

    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "WeaTerminalBridge")
    let sessionKey: String              // "direct:{wuid}" or "group:{groupId}"
    private let panel: TerminalPanel
    let panelId: UUID
    private let httpClient: WeaHttpClient
    private let dest: WeaMessageDest
    private let launcherCommands: [String]

    private(set) var state: State = .idle
    private(set) var processAlive: Bool = true
    private var activeCardId: String?
    private var pendingMessages: [String] = []
    private var replReady = false
    private var startupTimeoutTask: Task<Void, Never>?
    private var startupRetryCount = 0
    private let startupTimeoutSeconds: UInt64 = 25

    /// Set by WeaBotService when a WEA message is being injected.
    /// Claude Code hooks check this to know if the current prompt is from WEA.
    var isWeaMessageActive: Bool { state == .processing || state == .waitingInput }

    /// Flag file used by hooks to detect WEA-originated prompts.
    nonisolated let weaActiveMarkerPath: String

    init(
        sessionKey: String,
        panel: TerminalPanel,
        httpClient: WeaHttpClient,
        dest: WeaMessageDest,
        launcherCommands: [String]
    ) {
        self.sessionKey = sessionKey
        self.panel = panel
        self.panelId = panel.id
        self.httpClient = httpClient
        self.dest = dest
        self.launcherCommands = launcherCommands
        let safe = sessionKey.replacingOccurrences(of: ":", with: "_")
        self.weaActiveMarkerPath = "\(NSTemporaryDirectory())cmux-wea-active-\(safe)"

        // Wait for an explicit Claude session-start hook; if startup stalls, retry once.
        scheduleStartupTimeout()
    }

    deinit {
        startupTimeoutTask?.cancel()
        try? FileManager.default.removeItem(atPath: weaActiveMarkerPath)
    }

    // MARK: - REPL Startup Handling

    private func scheduleStartupTimeout() {
        startupTimeoutTask?.cancel()
        startupTimeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: startupTimeoutSeconds * 1_000_000_000)
            await self.handleStartupTimeoutIfNeeded()
        }
    }

    private func handleStartupTimeoutIfNeeded() async {
        guard !replReady else { return }
        guard !Task.isCancelled else { return }

        if startupRetryCount < launcherCommands.count {
            let command = launcherCommands[startupRetryCount]
            startupRetryCount += 1
            weaLog("[Bridge:\(sessionKey)] Claude session-start timeout, retrying launch (\(startupRetryCount)/\(launcherCommands.count))")
            weaLog("[Bridge:\(sessionKey)] Retry launcher command: \(command)")
            panel.sendInput(command + "\n")
            scheduleStartupTimeout()
            return
        }

        weaLog("[Bridge:\(sessionKey)] Claude failed to initialize (no session-start hook)")
        await failPendingStartup()
    }

    private func failPendingStartup() async {
        let message = "Claude initialization failed in this workspace. Please check codemax/claude auth and startup."
        do {
            if let cardId = activeCardId {
                try await httpClient.refreshCard(cardId: cardId, content: message, dest: dest)
            } else if !pendingMessages.isEmpty {
                try await httpClient.sendReply(text: message, dest: dest)
            }
        } catch {
            logger.error("Failed to send startup failure message to WEA: \(error.localizedDescription)")
        }

        // Keep pending messages so a late SessionStart can still flush and reply.
        // We only notify the user about startup delay/failure here.
        state = .idle
        activeCardId = nil
        cleanupMarker()
    }

    private func markReady() {
        guard !replReady else { return }
        replReady = true
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        weaLog("[Bridge:\(sessionKey)] REPL marked as ready, pending=\(pendingMessages.count)")

        // Flush pending messages
        guard state != .processing, state != .waitingInput else { return }
        if let first = pendingMessages.first {
            pendingMessages.removeFirst()
            Task { await doInjectMessage(first) }
        }
    }

    // MARK: - Inject WEA message into terminal

    func injectMessage(_ text: String) async {
        if !replReady {
            weaLog("[Bridge:\(sessionKey)] REPL not ready, queueing: \(text.prefix(50))")
            pendingMessages.append(text)
            return
        }

        if state == .processing {
            weaLog("[Bridge:\(sessionKey)] Busy processing, queueing: \(text.prefix(50))")
            pendingMessages.append(text)
            return
        }

        await doInjectMessage(text)
    }

    private func doInjectMessage(_ text: String) async {
        state = .processing
        writeMarker()
        weaLog("[Bridge:\(sessionKey)] Injecting message: \(text.prefix(100))")

        // Send initial "thinking..." card to WEA
        do {
            activeCardId = try await httpClient.sendCard(
                content: "⏳ thinking...",
                dest: dest
            )
        } catch {
            logger.error("Failed to send thinking card: \(error.localizedDescription)")
        }

        // Inject the message text into the terminal + Enter
        panel.sendInput(text + "\n")
    }

    // MARK: - Hook Callbacks (called by WeaBotService)

    /// Called when Stop hook fires — Claude finished responding.
    func onClaudeStop(transcriptPath: String?, lastMessage: String?) async {
        guard state == .processing || state == .waitingInput else { return }

        // Read full reply from transcript if available
        let fullReply: String
        if let path = transcriptPath {
            fullReply = readLastAssistantMessage(from: path) ?? lastMessage ?? ""
        } else {
            fullReply = lastMessage ?? ""
        }

        weaLog("[Bridge:\(sessionKey)] Claude stopped, reply=\(fullReply.count) chars")

        guard !fullReply.isEmpty else {
            finishProcessing()
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

        finishProcessing()
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
        guard state == .waitingInput else { return }
        state = .processing
        panel.sendInput(reply + "\n")
    }

    /// Called by claude-hook when SessionStart fires.
    func startTranscriptWatch(path: String?) {
        if let path, !path.isEmpty {
            weaLog("[Bridge:\(sessionKey)] Transcript: \(path)")
        } else {
            weaLog("[Bridge:\(sessionKey)] SessionStart received without transcript path")
        }
        // SessionStart is the authoritative readiness signal.
        markReady()
    }

    // MARK: - Process Liveness

    /// Called when the terminal's child process exits (PTY closed).
    func markProcessExited() {
        processAlive = false
        replReady = false
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        cleanupMarker()
        weaLog("[Bridge:\(sessionKey)] Process exited, bridge marked dead")
    }

    // MARK: - Finish & Queue

    private func finishProcessing() {
        state = .idle
        activeCardId = nil
        cleanupMarker()

        // Process next queued message
        if let next = pendingMessages.first {
            pendingMessages.removeFirst()
            Task {
                await doInjectMessage(next)
            }
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
