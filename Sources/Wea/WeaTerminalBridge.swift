// Sources/Wea/WeaTerminalBridge.swift
import Foundation
import os

/// Bridges WEA messages to/from a terminal running Claude.
/// One instance per session (DM or group chat tab).
@MainActor
final class WeaTerminalBridge {
    enum State: Equatable {
        case idle
        case processing       // Claude is working on a WEA message
        case waitingInput     // Claude is asking a question
    }

    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "WeaTerminalBridge")
    let sessionKey: String              // "direct:{wuid}" or "group:{groupId}"
    private weak var panel: TerminalPanel?
    private let httpClient: WeaHttpClient
    private let dest: WeaMessageDest

    private(set) var state: State = .idle
    private var activeCardId: String?
    private var transcriptWatcher: DispatchSourceFileSystemObject?
    private var transcriptPath: String?
    private var transcriptOffset: UInt64 = 0
    private var accumulatedText: String = ""
    private var lastRefreshTime: Date = .distantPast
    private let refreshThrottleInterval: TimeInterval = 0.8

    /// Set by WeaBotService when a WEA message is being injected.
    /// Claude Code hooks check this to know if the current prompt is from WEA.
    var isWeaMessageActive: Bool { state == .processing || state == .waitingInput }

    /// Flag file used by hooks to detect WEA-originated prompts.
    var weaActiveMarkerPath: String {
        let dir = NSTemporaryDirectory()
        let safe = sessionKey.replacingOccurrences(of: ":", with: "_")
        return "\(dir)cmux-wea-active-\(safe)"
    }

    init(sessionKey: String, panel: TerminalPanel, httpClient: WeaHttpClient, dest: WeaMessageDest) {
        self.sessionKey = sessionKey
        self.panel = panel
        self.httpClient = httpClient
        self.dest = dest
    }

    deinit {
        stopTranscriptWatch()
        cleanupMarker()
    }

    // MARK: - Inject WEA message into terminal

    func injectMessage(_ text: String) async {
        guard let panel else {
            logger.warning("Panel is nil for session \(self.sessionKey)")
            return
        }

        state = .processing
        accumulatedText = ""
        writeMarker()

        // Send initial "thinking..." card to WEA
        do {
            activeCardId = try await httpClient.sendCard(
                content: "thinking...",
                dest: dest
            )
        } catch {
            logger.error("Failed to send thinking card: \(error.localizedDescription)")
        }

        // Inject the message text into the terminal
        panel.sendInput(text + "\n")
    }

    // MARK: - Hook Callbacks (called by WeaBotService)

    /// Called when Stop hook fires — Claude finished responding.
    func onClaudeStop(transcriptPath: String?, lastMessage: String?) async {
        guard state == .processing || state == .waitingInput else { return }
        stopTranscriptWatch()

        // Read full reply from transcript if available
        let fullReply: String
        if let path = transcriptPath {
            fullReply = readLastAssistantMessage(from: path) ?? lastMessage ?? accumulatedText
        } else {
            fullReply = lastMessage ?? accumulatedText
        }

        guard !fullReply.isEmpty else {
            state = .idle
            cleanupMarker()
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

        state = .idle
        activeCardId = nil
        cleanupMarker()
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
        guard state == .waitingInput, let panel else { return }
        state = .processing
        panel.sendInput(reply + "\n")
    }

    // MARK: - Transcript Watching (for streaming)

    func startTranscriptWatch(path: String) {
        stopTranscriptWatch()
        self.transcriptPath = path

        // Record current file size as offset (skip pre-existing content)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            transcriptOffset = (attrs[.size] as? UInt64) ?? 0
        }

        let fd = open(path, O_RDONLY | O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Cannot open transcript for watching: \(path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.readNewTranscriptLines()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        transcriptWatcher = source
    }

    private func stopTranscriptWatch() {
        transcriptWatcher?.cancel()
        transcriptWatcher = nil
    }

    private func readNewTranscriptLines() {
        guard let path = transcriptPath,
              let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        handle.seek(toFileOffset: transcriptOffset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        transcriptOffset += UInt64(data.count)

        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let role = message["role"] as? String,
                  role == "assistant",
                  let content = message["content"] as? [[String: Any]] else {
                continue
            }

            for block in content {
                if (block["type"] as? String) == "text",
                   let blockText = block["text"] as? String {
                    accumulatedText += blockText
                }
            }
        }

        // Throttled REFRESH to WEA
        let now = Date()
        guard now.timeIntervalSince(lastRefreshTime) >= refreshThrottleInterval,
              let cardId = activeCardId,
              !accumulatedText.isEmpty else { return }

        lastRefreshTime = now
        let content = accumulatedText
        let client = httpClient
        let destination = dest
        Task { @MainActor in
            try? await client.refreshCard(cardId: cardId, content: content, dest: destination)
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
