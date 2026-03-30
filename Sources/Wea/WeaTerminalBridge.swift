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
    let dest: WeaMessageDest

    private(set) var state: State = .idle
    private(set) var processAlive: Bool = true
    private(set) var claudeSessionId: String?
    private var activeCardId: String?
    /// Queue of thinking card IDs — one per injected message, replied in FIFO order.
    private var thinkingCardIds: [String] = []
    /// Number of messages injected that haven't received a Stop reply yet.
    private var pendingReplyCount = 0
    private var pendingMessages: [String] = []
    private var replReady = false
    private var startupTimeoutTask: Task<Void, Never>?
    private let startupTimeoutSeconds: UInt64 = 30


    /// Set by WeaBotService when a WEA message is being injected.
    /// Claude Code hooks check this to know if the current prompt is from WEA.
    var isWeaMessageActive: Bool { state == .processing || state == .waitingInput }

    /// True when a message was queued before the REPL was ready (startup).
    var hasPendingStartup: Bool { !replReady && !pendingMessages.isEmpty }

    /// Flag file used by hooks to detect WEA-originated prompts.
    nonisolated let weaActiveMarkerPath: String

    init(
        sessionKey: String,
        panel: TerminalPanel,
        httpClient: WeaHttpClient,
        dest: WeaMessageDest
    ) {
        self.sessionKey = sessionKey
        self.panel = panel
        self.panelId = panel.id
        self.httpClient = httpClient
        self.dest = dest
        let safe = sessionKey.replacingOccurrences(of: ":", with: "_")
        self.weaActiveMarkerPath = "\(NSTemporaryDirectory())cmux-wea-active-\(safe)"

        // Wait for Claude session-start hook to mark REPL as ready.
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

        weaLog("[Bridge:\(sessionKey)] Claude failed to initialize (no session-start hook after \(startupTimeoutSeconds)s)")
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

        // Flush pending messages (queued during startup before REPL was ready)
        guard state != .processing, state != .waitingInput else { return }
        if let first = pendingMessages.first {
            pendingMessages.removeFirst()
            Task { await injectMessage(first) }
        }
    }

    // MARK: - Inject WEA message into terminal

    func injectMessage(_ text: String) async {
        // Queue if Claude process isn't ready yet (startup / relaunch).
        if !replReady {
            weaLog("[Bridge:\(sessionKey)] REPL not ready, queueing: \(text.prefix(50))")
            pendingMessages.append(text)
            return
        }

        // If Claude is waiting for input (permission question), this is a reply
        // to the current turn — not a new command. Don't increment pendingReplyCount
        // or create a new thinking card; just forward to terminal.
        if state == .waitingInput {
            weaLog("[Bridge:\(sessionKey)] Injecting reply to question: \(text.prefix(80))")
            state = .processing
            panel.sendInput(text + "\n")
            return
        }

        pendingReplyCount += 1
        weaLog("[Bridge:\(sessionKey)] Injecting (state=\(state), pending=\(pendingReplyCount)): \(text.prefix(80))")

        // Always forward to terminal immediately.
        panel.sendInput(text + "\n")

        // Every injected message gets its own thinking card in the FIFO queue.
        state = .processing
        writeMarker()

        do {
            let cardId = try await httpClient.sendCard(
                content: "⏳ thinking...",
                dest: dest
            )
            thinkingCardIds.append(cardId)
            weaLog("[Bridge:\(sessionKey)] Sent thinking card, id=\(cardId)")
        } catch {
            weaLog("[Bridge:\(sessionKey)] Failed to send thinking card: \(error.localizedDescription)")
        }
    }

    // MARK: - Hook Callbacks (called by WeaBotService)

    /// Called when Stop hook fires — Claude finished responding.
    func onClaudeStop(transcriptPath: String?, lastMessage: String?) async {
        guard state == .processing || state == .waitingInput else { return }

        pendingReplyCount = max(0, pendingReplyCount - 1)

        // Read full reply from transcript if available (includes images)
        let content: AssistantContent
        if let path = transcriptPath, let parsed = readLastAssistantContent(from: path) {
            content = parsed
        } else {
            content = AssistantContent(text: lastMessage ?? "", images: [])
        }

        weaLog("[Bridge:\(sessionKey)] Claude stopped, text=\(content.text.count) chars, images=\(content.images.count), pending=\(pendingReplyCount), cards=\(thinkingCardIds.count)")

        // Send text reply
        if !content.text.isEmpty {
            let cardId = thinkingCardIds.isEmpty ? nil : thinkingCardIds.removeFirst()
            if let cardId {
                do {
                    try await httpClient.refreshCard(cardId: cardId, content: content.text, dest: dest)
                } catch {
                    weaLog("[Bridge:\(sessionKey)] Refresh failed: \(error.localizedDescription)")
                    try? await httpClient.sendReply(text: content.text, dest: dest)
                }
            } else {
                do {
                    try await httpClient.sendReply(text: content.text, dest: dest)
                } catch {
                    weaLog("[Bridge:\(sessionKey)] Failed to send reply: \(error.localizedDescription)")
                }
            }
        }

        // Send images sequentially
        for (i, image) in content.images.enumerated() {
            guard let imageData = Data(base64Encoded: image.base64Data) else {
                weaLog("[Bridge:\(sessionKey)] Failed to decode base64 image \(i)")
                continue
            }
            let ext = image.mediaType.components(separatedBy: "/").last ?? "png"
            let fileName = "claude-image-\(i + 1).\(ext)"
            do {
                try await httpClient.sendAttachment(
                    data: imageData,
                    fileName: fileName,
                    contentType: image.mediaType,
                    dest: dest
                )
                weaLog("[Bridge:\(sessionKey)] Sent image \(i + 1)/\(content.images.count): \(fileName) (\(imageData.count)B)")
            } catch {
                weaLog("[Bridge:\(sessionKey)] Failed to send image \(i + 1): \(error.localizedDescription)")
            }
        }

        // Only go idle when all injected messages have been replied to.
        if pendingReplyCount <= 0 {
            finishProcessing()
        }
    }

    /// Called when Claude needs user input (Notification hook).
    /// Refreshes the current thinking card to show the question.
    func onNeedsInput(question: String) async {
        state = .waitingInput
        await refreshOrSendCard(content: question, label: "input request")
    }

    /// Called when PreToolUse fires AskUserQuestion.
    /// Refreshes the current thinking card to show the question.
    func onAskUserQuestion(questionText: String) async {
        state = .waitingInput
        await refreshOrSendCard(content: questionText, label: "AskUserQuestion")
    }

    /// Refresh the latest thinking card with content, or send a new card if none exists.
    private func refreshOrSendCard(content: String, label: String) async {
        if let cardId = thinkingCardIds.last {
            do {
                weaLog("[Bridge:\(sessionKey)] Refreshing thinking card for \(label): \(content.prefix(100))")
                try await httpClient.refreshCard(cardId: cardId, content: content, dest: dest)
                // Remove from queue so the reply creates a new card instead of overwriting this one.
                thinkingCardIds.removeAll { $0 == cardId }
                return
            } catch {
                weaLog("[Bridge:\(sessionKey)] Refresh failed for \(label): \(error.localizedDescription)")
            }
        }
        // Fallback: send as new card
        do {
            weaLog("[Bridge:\(sessionKey)] Sending \(label) as new card: \(content.prefix(100))")
            try await httpClient.sendCard(content: content, dest: dest)
        } catch {
            weaLog("[Bridge:\(sessionKey)] Failed to send \(label): \(error.localizedDescription)")
        }
    }

    /// Called when a WEA user replies to a question.
    func injectQuestionReply(_ reply: String) {
        guard state == .waitingInput else { return }
        state = .processing
        weaLog("[Bridge:\(sessionKey)] Injecting reply: '\(reply)'")
        panel.sendInput(reply + "\n")
    }

    /// Called by claude-hook when SessionStart fires.
    func startTranscriptWatch(path: String?, sessionId: String? = nil) {
        if let sessionId, !sessionId.isEmpty {
            claudeSessionId = sessionId
            weaLog("[Bridge:\(sessionKey)] Claude session ID: \(sessionId)")
        }
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

    /// Restart Claude in the same terminal panel after process died.
    func restartClaude(command: String) {
        guard !command.isEmpty else { return }
        processAlive = true
        replReady = false
        panel.sendInput(command + "\n")
        scheduleStartupTimeout()
        weaLog("[Bridge:\(sessionKey)] Restarting Claude: \(command.prefix(80))")
    }

    // MARK: - Finish & Queue

    private func finishProcessing() {
        state = .idle
        activeCardId = nil
        thinkingCardIds.removeAll()
        pendingReplyCount = 0
        cleanupMarker()

        // Process next queued message (from startup queue)
        if let next = pendingMessages.first {
            pendingMessages.removeFirst()
            Task {
                await injectMessage(next)
            }
        }
    }

    // MARK: - Read full assistant message from transcript

    private struct AssistantContent {
        let text: String
        let images: [ImageBlock]

        struct ImageBlock {
            let mediaType: String   // e.g. "image/png"
            let base64Data: String
        }

        var isEmpty: Bool { text.isEmpty && images.isEmpty }
    }

    private func readLastAssistantContent(from path: String) -> AssistantContent? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8) else { return nil }

        var lastContent: AssistantContent?
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  role == "assistant" else { continue }

            var texts: [String] = []
            var images: [AssistantContent.ImageBlock] = []

            if let contentArr = message["content"] as? [[String: Any]] {
                for block in contentArr {
                    let blockType = block["type"] as? String ?? ""
                    if blockType == "text", let t = block["text"] as? String, !t.isEmpty {
                        texts.append(t)
                    } else if blockType == "image",
                              let source = block["source"] as? [String: Any],
                              (source["type"] as? String) == "base64",
                              let mediaType = source["media_type"] as? String,
                              let b64 = source["data"] as? String, !b64.isEmpty {
                        images.append(.init(mediaType: mediaType, base64Data: b64))
                    }
                }
            } else if let contentStr = message["content"] as? String, !contentStr.isEmpty {
                texts.append(contentStr)
            }

            let joined = texts.joined(separator: "\n")
            if !joined.isEmpty || !images.isEmpty {
                lastContent = AssistantContent(text: joined, images: images)
            }
        }
        return lastContent
    }

    // MARK: - Marker file for hook discrimination

    private func writeMarker() {
        FileManager.default.createFile(atPath: weaActiveMarkerPath, contents: Data())
    }

    private func cleanupMarker() {
        try? FileManager.default.removeItem(atPath: weaActiveMarkerPath)
    }
}
