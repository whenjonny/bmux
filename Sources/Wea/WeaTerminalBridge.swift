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

/// Bridges WEA messages to/from Claude using one-shot subprocess per message.
/// Matches the Node.js architecture: `claude -p <prompt> --output-format stream-json --resume <sessionId>`
/// One instance per session (DM or group chat tab).
final class WeaTerminalBridge: @unchecked Sendable {
    enum State: Equatable {
        case idle
        case processing       // Claude subprocess is running
        case waitingInput     // Not used in one-shot mode, kept for API compat
    }

    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "WeaTerminalBridge")
    let sessionKey: String              // "direct:{wuid}" or "group:{groupId}"
    private let httpClient: WeaHttpClient
    private let dest: WeaMessageDest

    private(set) var state: State = .idle
    private var activeCardId: String?
    private var claudeSessionId: String?
    private var accumulatedText: String = ""
    private var lastRefreshTime: Date = .distantPast
    private let refreshThrottleInterval: TimeInterval = 0.8
    private var currentProcess: Process?

    /// Working directory for Claude sessions
    private let workDir: String

    /// Set by WeaBotService when a WEA message is being injected.
    var isWeaMessageActive: Bool { state == .processing }

    /// Kept for API compat with WeaBotService
    nonisolated let weaActiveMarkerPath: String

    init(sessionKey: String, httpClient: WeaHttpClient, dest: WeaMessageDest) {
        self.sessionKey = sessionKey
        self.httpClient = httpClient
        self.dest = dest
        let safe = sessionKey.replacingOccurrences(of: ":", with: "_")
        self.weaActiveMarkerPath = "\(NSTemporaryDirectory())cmux-wea-active-\(safe)"

        // Create a per-session working directory
        let dir = NSTemporaryDirectory() + "cmux-wea-sessions/\(safe)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.workDir = dir

        // Try to load persisted session ID
        let idFile = dir + "/.claude-session-id"
        self.claudeSessionId = try? String(contentsOfFile: idFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit {
        currentProcess?.terminate()
        try? FileManager.default.removeItem(atPath: weaActiveMarkerPath)
    }

    // MARK: - Process WEA message via one-shot subprocess

    func injectMessage(_ text: String) async {
        guard state == .idle else {
            weaLog("[Bridge:\(sessionKey)] Busy, ignoring message: \(text.prefix(50))")
            return
        }

        state = .processing
        accumulatedText = ""

        weaLog("[Bridge:\(sessionKey)] Processing message: \(text.prefix(100))")

        // Send initial "thinking..." card to WEA
        do {
            activeCardId = try await httpClient.sendCard(
                content: "⏳ thinking...",
                dest: dest
            )
        } catch {
            logger.error("Failed to send thinking card: \(error.localizedDescription)")
        }

        // Run Claude in one-shot mode
        let response = await runClaude(prompt: text)

        weaLog("[Bridge:\(sessionKey)] Got response (\(response.count) chars): \(response.prefix(200))")

        // Send final reply to WEA
        guard !response.isEmpty else {
            state = .idle
            activeCardId = nil
            return
        }

        do {
            if let cardId = activeCardId {
                try await httpClient.refreshCard(cardId: cardId, content: response, dest: dest)
            } else {
                try await httpClient.sendReply(text: response, dest: dest)
            }
        } catch {
            logger.error("Failed to send reply to WEA: \(error.localizedDescription)")
        }

        state = .idle
        activeCardId = nil
    }

    // MARK: - Run Claude subprocess

    private func runClaude(prompt: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()

                // Build args matching Node.js: claude -p <prompt> --output-format stream-json --verbose
                var args = ["claude", "-p", prompt,
                            "--output-format", "stream-json",
                            "--verbose",
                            "--model", "bedrock-claude-4-6-opus",
                            "--dangerously-skip-permissions"]

                if let sessionId = claudeSessionId {
                    args.append(contentsOf: ["--resume", sessionId])
                }

                process.executableURL = URL(fileURLWithPath: "/Users/user/.local/bin/codemax")
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: workDir)
                process.standardOutput = stdout
                process.standardError = stderr

                // Add environment for non-interactive
                var env = ProcessInfo.processInfo.environment
                env["TERM"] = "dumb"
                env["NO_COLOR"] = "1"
                process.environment = env

                currentProcess = process

                var textBuffer = ""
                var sessionIdCaptured = false

                // Read stdout incrementally
                let readQueue = DispatchQueue(label: "wea.claude.stdout.\(sessionKey)")
                var lineBuf = ""

                stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

                    readQueue.sync {
                        lineBuf += chunk
                        while let idx = lineBuf.firstIndex(of: "\n") {
                            let line = String(lineBuf[lineBuf.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
                            lineBuf = String(lineBuf[lineBuf.index(after: idx)...])
                            guard !line.isEmpty else { continue }

                            self?.processJsonLine(line, textBuffer: &textBuffer, sessionIdCaptured: &sessionIdCaptured)
                        }
                    }
                }

                // Timeout after 5 minutes
                let timeoutItem = DispatchWorkItem { [weak process] in
                    weaLog("[Bridge] Claude process timed out, killing")
                    process?.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeoutItem)

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    weaLog("[Bridge:\(self.sessionKey)] Failed to launch Claude: \(error)")
                    continuation.resume(returning: "")
                    return
                }

                timeoutItem.cancel()
                currentProcess = nil
                stdout.fileHandleForReading.readabilityHandler = nil

                // Process any remaining data in buffer
                readQueue.sync {
                    if let remaining = try? stdout.fileHandleForReading.availableData,
                       !remaining.isEmpty,
                       let chunk = String(data: remaining, encoding: .utf8) {
                        lineBuf += chunk
                    }
                    for line in lineBuf.split(separator: "\n") {
                        let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        self.processJsonLine(trimmed, textBuffer: &textBuffer, sessionIdCaptured: &sessionIdCaptured)
                    }
                }

                let exitCode = process.terminationStatus
                weaLog("[Bridge:\(self.sessionKey)] Claude exited with code \(exitCode), text=\(textBuffer.count) chars")

                if let stderrData = try? stderr.fileHandleForReading.readDataToEndOfFile(),
                   let stderrStr = String(data: stderrData, encoding: .utf8),
                   !stderrStr.isEmpty {
                    weaLog("[Bridge:\(self.sessionKey)] stderr: \(stderrStr.prefix(500))")
                }

                let finalText = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: finalText)
            }
        }
    }

    /// Parse a stream-json line from Claude CLI output
    private func processJsonLine(_ line: String, textBuffer: inout String, sessionIdCaptured: inout Bool) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let type = obj["type"] as? String ?? ""

        switch type {
        case "assistant":
            // Extract text from content blocks
            if let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if (block["type"] as? String) == "text",
                       let text = block["text"] as? String {
                        textBuffer += text
                        throttledRefresh(textBuffer)
                    }
                }
            }

        case "content_block_delta":
            // Streaming text delta
            if let delta = obj["delta"] as? [String: Any],
               (delta["type"] as? String) == "text_delta",
               let text = delta["text"] as? String {
                textBuffer += text
                throttledRefresh(textBuffer)
            }

        case "result":
            // Final result — capture session ID
            if !sessionIdCaptured, let sessionId = obj["session_id"] as? String {
                claudeSessionId = sessionId
                sessionIdCaptured = true
                saveSessionId(sessionId)
                weaLog("[Bridge:\(sessionKey)] Captured session ID: \(sessionId)")
            }
            // Fallback result text
            if textBuffer.isEmpty, let resultText = obj["result"] as? String {
                textBuffer = resultText
            }

        case "system":
            // Log but ignore
            break

        default:
            break
        }
    }

    /// Throttled card refresh while Claude is streaming
    private func throttledRefresh(_ content: String) {
        let now = Date()
        guard now.timeIntervalSince(lastRefreshTime) >= refreshThrottleInterval,
              let cardId = activeCardId,
              !content.isEmpty else { return }

        lastRefreshTime = now
        let client = httpClient
        let destination = dest
        let text = content
        Task {
            try? await client.refreshCard(cardId: cardId, content: text, dest: destination)
        }
    }

    private func saveSessionId(_ id: String) {
        let path = workDir + "/.claude-session-id"
        try? id.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Legacy API (kept for WeaBotService compat)

    func injectQuestionReply(_ reply: String) {
        // Not applicable in one-shot mode
    }

    func onClaudeStop(transcriptPath: String?, lastMessage: String?) async {
        // Not needed — process exit handles completion
    }

    func onNeedsInput(question: String) async {
        // Not applicable in one-shot mode
    }

    func onAskUserQuestion(questionText: String) async {
        // Not applicable in one-shot mode
    }

    func startTranscriptWatch(path: String) {
        // Not needed — we read stdout directly
    }
}
