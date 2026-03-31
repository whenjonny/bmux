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
        case digesting        // Background summarization running
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
    private(set) var replReady = false
    private var startupTimeoutTask: Task<Void, Never>?
    private let startupTimeoutSeconds: UInt64 = 30

    // A1: Streaming output via periodic transcript polling
    private var streamingTimer: Task<Void, Never>?
    private var lastStreamedLength: Int = 0
    private var transcriptPath: String?

    // A2: Hook timeout fallback watchdog
    private var processingWatchdog: Task<Void, Never>?


    /// Set by WeaBotService when a WEA message is being injected.
    /// Claude Code hooks check this to know if the current prompt is from WEA.
    var isWeaMessageActive: Bool { state == .processing || state == .waitingInput }

    /// True when a message was queued before the REPL was ready (startup).
    var hasPendingStartup: Bool { !replReady && !pendingMessages.isEmpty }

    /// Flag file used by hooks to detect WEA-originated prompts.
    nonisolated let weaActiveMarkerPath: String

    /// Marker file that tracks whether the Claude agent process is alive.
    /// Created on SessionStart, removed by the launch command suffix when Claude exits.
    nonisolated let agentAlivePath: String

    /// Whether the Claude agent process is currently running (marker file exists).
    var isAgentRunning: Bool {
        FileManager.default.fileExists(atPath: agentAlivePath)
    }

    /// Log prefix including sessionKey and truncated claudeSessionId for easy filtering.
    private var lp: String {
        let sid = claudeSessionId.map { " sid=\($0.prefix(8))" } ?? ""
        return "[Bridge:\(sessionKey)\(sid)]"
    }

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
        self.agentAlivePath = "\(NSTemporaryDirectory())cmux-wea-agent-\(safe)"

        // Wait for Claude session-start hook to mark REPL as ready.
        scheduleStartupTimeout()
    }

    deinit {
        startupTimeoutTask?.cancel()
        streamingTimer?.cancel()
        processingWatchdog?.cancel()
        try? FileManager.default.removeItem(atPath: weaActiveMarkerPath)
        try? FileManager.default.removeItem(atPath: agentAlivePath)
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

        weaLog("\(lp) Claude failed to initialize (no session-start hook after \(startupTimeoutSeconds)s)")
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
        weaLog("\(lp) REPL marked as ready, pending=\(pendingMessages.count)")

        // Flush pending messages (queued during startup before REPL was ready)
        guard state != .processing, state != .waitingInput else { return }
        if let first = pendingMessages.first {
            pendingMessages.removeFirst()
            Task { await injectMessage(first) }
        }
    }

    // MARK: - Inject WEA message into terminal

    func injectMessage(_ text: String) async {
        // Queue only during startup — REPL not ready yet.
        if !replReady {
            weaLog("\(lp) REPL not ready, queueing: \(text.prefix(50))")
            pendingMessages.append(text)
            return
        }

        // Agent marker gone — Claude exited but shell is still alive.
        // Reset processing state and queue; the service will restart Claude.
        if !isAgentRunning {
            weaLog("\(lp) Agent marker missing, resetting. Queueing: \(text.prefix(50))")
            resetProcessingState()
            replReady = false
            pendingMessages.append(text)
            return
        }

        // If Claude is waiting for input (permission question), just forward.
        if state == .waitingInput {
            weaLog("\(lp) Injecting reply to question: \(text.prefix(80))")
            state = .processing
            panel.sendInput(text + "\n")
            return
        }

        pendingReplyCount += 1
        weaLog("\(lp) Injecting (state=\(state), pending=\(pendingReplyCount)): \(text.prefix(80))")

        // Always forward to terminal immediately — no queueing after startup.
        panel.sendInput(text + "\n")

        // Enter processing state on first message; subsequent messages just stack.
        if state != .processing {
            state = .processing
            writeMarker()
            startStreamingTimer()
            startWatchdog()
        }

        // Each message gets its own thinking card for FIFO reply matching.
        do {
            let cardId = try await httpClient.sendCard(
                content: "⏳ thinking...",
                dest: dest
            )
            thinkingCardIds.append(cardId)
            weaLog("\(lp) Sent thinking card, id=\(cardId)")
        } catch {
            weaLog("\(lp) Failed to send thinking card: \(error.localizedDescription)")
        }
    }

    // MARK: - Hook Callbacks (called by WeaBotService)

    /// Called when Stop hook fires — Claude finished responding.
    func onClaudeStop(transcriptPath: String?, lastMessage: String?) async {
        processingWatchdog?.cancel()
        processingWatchdog = nil

        guard state == .processing || state == .waitingInput || state == .digesting else { return }

        // If digesting, just fire the completion — don't send reply to WEA.
        if state == .digesting {
            completeDigestIfNeeded()
            return
        }

        // FIFO mismatch detection
        if thinkingCardIds.isEmpty && pendingReplyCount > 0 {
            weaLog("\(lp) Warning: no thinking cards but pendingReplyCount=\(pendingReplyCount)")
        }

        pendingReplyCount = max(0, pendingReplyCount - 1)

        // Read full reply from transcript if available (includes images)
        let content: AssistantContent
        if let path = transcriptPath, let parsed = readLastAssistantContent(from: path) {
            content = parsed
        } else {
            content = AssistantContent(text: lastMessage ?? "", images: [])
        }

        weaLog("\(lp) Claude stopped, text=\(content.text.count) chars, images=\(content.images.count), pending=\(pendingReplyCount), cards=\(thinkingCardIds.count)")

        // Send text reply and clean up thinking card.
        let cardId = thinkingCardIds.isEmpty ? nil : thinkingCardIds.removeFirst()
        if !content.text.isEmpty {
            if let cardId {
                do {
                    try await httpClient.refreshCard(cardId: cardId, content: content.text, dest: dest)
                } catch {
                    weaLog("\(lp) Refresh failed: \(error.localizedDescription)")
                    try? await httpClient.sendReply(text: content.text, dest: dest)
                    // Clean up orphaned thinking card so it doesn't stay as "thinking..."
                    try? await httpClient.refreshCard(cardId: cardId, content: "✓", dest: dest)
                }
            } else {
                try? await httpClient.sendReply(text: content.text, dest: dest)
            }
        } else if let cardId {
            // No content but have a thinking card — mark it done.
            try? await httpClient.refreshCard(cardId: cardId, content: "✓", dest: dest)
        }

        // Send images sequentially
        for (i, image) in content.images.enumerated() {
            guard let imageData = Data(base64Encoded: image.base64Data) else {
                weaLog("\(lp) Failed to decode base64 image \(i)")
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
                weaLog("\(lp) Sent image \(i + 1)/\(content.images.count): \(fileName) (\(imageData.count)B)")
            } catch {
                weaLog("\(lp) Failed to send image \(i + 1): \(error.localizedDescription)")
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
        processingWatchdog?.cancel()
        processingWatchdog = nil
        state = .waitingInput
        await refreshOrSendCard(content: question, label: "input request")
    }

    /// Called when PreToolUse fires AskUserQuestion.
    /// Refreshes the current thinking card to show the question.
    func onAskUserQuestion(questionText: String) async {
        processingWatchdog?.cancel()
        processingWatchdog = nil
        state = .waitingInput
        await refreshOrSendCard(content: questionText, label: "AskUserQuestion")
    }

    /// Refresh the latest thinking card with content, or send a new card if none exists.
    private func refreshOrSendCard(content: String, label: String) async {
        if let cardId = thinkingCardIds.last {
            do {
                weaLog("\(lp) Refreshing thinking card for \(label): \(content.prefix(100))")
                try await httpClient.refreshCard(cardId: cardId, content: content, dest: dest)
                // Remove from queue so the reply creates a new card instead of overwriting this one.
                thinkingCardIds.removeAll { $0 == cardId }
                return
            } catch {
                weaLog("\(lp) Refresh failed for \(label): \(error.localizedDescription)")
            }
        }
        // Fallback: send as new card
        do {
            weaLog("\(lp) Sending \(label) as new card: \(content.prefix(100))")
            try await httpClient.sendCard(content: content, dest: dest)
        } catch {
            weaLog("\(lp) Failed to send \(label): \(error.localizedDescription)")
        }
    }

    /// Called when a WEA user replies to a question.
    func injectQuestionReply(_ reply: String) {
        guard state == .waitingInput else { return }
        state = .processing
        weaLog("\(lp) Injecting reply: '\(reply)'")
        panel.sendInput(reply + "\n")
    }

    /// Called by claude-hook when SessionStart fires.
    func startTranscriptWatch(path: String?, sessionId: String? = nil) {
        if let sessionId, !sessionId.isEmpty {
            claudeSessionId = sessionId
            weaLog("\(lp) Claude session ID: \(sessionId)")
        }
        if let path, !path.isEmpty {
            transcriptPath = path
            weaLog("\(lp) Transcript: \(path)")
        } else {
            weaLog("\(lp) SessionStart received without transcript path")
        }
        // Mark agent as alive — the launch command suffix removes this on exit.
        FileManager.default.createFile(atPath: agentAlivePath, contents: Data())
        // SessionStart is the authoritative readiness signal.
        markReady()
    }

    // MARK: - Process Liveness

    /// Reset all processing state (timers, watchdog, cards, counters).
    /// Used when Claude exits, restarts, or agent marker disappears.
    private func resetProcessingState() {
        streamingTimer?.cancel()
        streamingTimer = nil
        processingWatchdog?.cancel()
        processingWatchdog = nil
        // Clean up orphaned thinking cards
        let orphanedCards = thinkingCardIds
        if !orphanedCards.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                for cardId in orphanedCards {
                    try? await self.httpClient.refreshCard(cardId: cardId, content: "✓", dest: self.dest)
                }
            }
        }
        state = .idle
        activeCardId = nil
        thinkingCardIds.removeAll()
        pendingReplyCount = 0
        lastStreamedLength = 0
        cleanupMarker()
    }

    /// Called when the terminal's child process exits (PTY closed).
    func markProcessExited() {
        resetProcessingState()
        processAlive = false
        replReady = false
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        try? FileManager.default.removeItem(atPath: agentAlivePath)
        weaLog("\(lp) Process exited, bridge marked dead")
    }

    /// Restart Claude in the same terminal panel after process died.
    func restartClaude(command: String) {
        guard !command.isEmpty else { return }
        resetProcessingState()
        processAlive = true
        replReady = false
        panel.sendInput(command + "\n")
        scheduleStartupTimeout()
        weaLog("\(lp) Restarting Claude: \(command.prefix(80))")
    }

    // MARK: - Finish & Queue

    private func finishProcessing() {
        resetProcessingState()

        // Flush startup queue if any messages were waiting.
        if let next = pendingMessages.first {
            pendingMessages.removeFirst()
            Task {
                await injectMessage(next)
            }
        }
    }

    // MARK: - Streaming Output (A1)

    private func startStreamingTimer() {
        streamingTimer?.cancel()
        streamingTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
                guard !Task.isCancelled else { break }
                guard let self, self.state == .processing else { break }
                await self.streamUpdate()
            }
        }
    }

    private func streamUpdate() async {
        guard let path = transcriptPath, !path.isEmpty else { return }
        guard let content = readLastAssistantContent(from: path) else { return }
        if content.text.count > lastStreamedLength {
            lastStreamedLength = content.text.count
            let cardId = thinkingCardIds.first ?? ""
            if !cardId.isEmpty {
                try? await httpClient.refreshCard(cardId: cardId, content: content.text, dest: dest)
            }
            weaLog("\(lp) Stream update: \(content.text.count) chars")
        }
    }

    // MARK: - Watchdog Fallback (A2)

    private func startWatchdog() {
        processingWatchdog?.cancel()
        processingWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
            guard !Task.isCancelled else { return }
            guard let self, self.state == .processing else { return }
            await self.handleWatchdogFired()
        }
    }

    private func handleWatchdogFired() async {
        if !processAlive {
            weaLog("\(lp) Watchdog: process dead, recovering")
            if let path = transcriptPath, let content = readLastAssistantContent(from: path), !content.isEmpty {
                try? await httpClient.sendReply(text: content.text, dest: dest)
            } else {
                try? await httpClient.sendReply(text: "Process ended without response.", dest: dest)
            }
            finishProcessing()
        } else {
            // Check if transcript has content that stopped growing — likely missed Stop hook.
            // The streaming timer updates lastStreamedLength every 5s, so by the 5-min watchdog
            // fire it will have caught up. If both are >0 and equal, Claude finished outputting.
            let currentContent = transcriptPath.flatMap { readLastAssistantContent(from: $0) }
            let currentLength = currentContent?.text.count ?? 0

            if currentLength > 0 && currentLength == lastStreamedLength {
                weaLog("\(lp) Watchdog: transcript stale (\(currentLength) chars), recovering as missed Stop")
                if let content = currentContent, !content.text.isEmpty {
                    let cardId = thinkingCardIds.isEmpty ? nil : thinkingCardIds.removeFirst()
                    if let cardId {
                        do {
                            try await httpClient.refreshCard(cardId: cardId, content: content.text, dest: dest)
                        } catch {
                            try? await httpClient.sendReply(text: content.text, dest: dest)
                        }
                    } else {
                        try? await httpClient.sendReply(text: content.text, dest: dest)
                    }
                }
                finishProcessing()
            } else {
                weaLog("\(lp) Watchdog: still alive, resetting (transcript=\(currentLength) streamed=\(lastStreamedLength))")
                await refreshOrSendCard(content: "Still processing, please wait...", label: "watchdog")
                startWatchdog() // reset for another 5 min
            }
        }
    }

    /// Mark bridge as stale — called by WeaBotService for dead session cleanup.
    func markStale() {
        weaLog("\(lp) Marked stale by service")
        processingWatchdog?.cancel()
        streamingTimer?.cancel()
        finishProcessing()
    }

    // MARK: - Digest / Summarization

    private var digestCompletion: (() -> Void)?

    /// Inject a summarization prompt into the terminal and transition to `.digesting` state.
    /// The `onComplete` callback fires when `onClaudeStop` is received while in `.digesting` state.
    func injectSummarizationPrompt(onComplete: @escaping () -> Void) async {
        guard replReady, processAlive else {
            onComplete()
            return
        }
        state = .digesting
        digestCompletion = onComplete
        let prompt = "/compact Summarize this session: key decisions, files changed, and outcomes."
        panel.sendInput(prompt + "\n")
        weaLog("\(lp) Digest prompt injected")
    }

    /// Force-finish a digest that hasn't completed within the timeout.
    func forceFinishDigest() {
        guard state == .digesting else { return }
        weaLog("\(lp) Force finishing digest")
        let completion = digestCompletion
        digestCompletion = nil
        finishProcessing()
        completion?()
    }

    /// Called from `onClaudeStop` when state is `.digesting` to fire the completion handler.
    func completeDigestIfNeeded() {
        guard state == .digesting else { return }
        let completion = digestCompletion
        digestCompletion = nil
        finishProcessing()
        completion?()
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
