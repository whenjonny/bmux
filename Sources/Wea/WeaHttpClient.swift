// Sources/Wea/WeaHttpClient.swift
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

/// Result of a send attempt.
enum SendResult {
    case success
    case retryQueued
    case dropped(String)
}

/// Sends messages (TEXT/CARD/REFRESH) to WEA via Difft OpenAPI.
final class WeaHttpClient {
    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "WeaHttpClient")
    private let baseURL = "https://openapi.difft.org"
    private let maxTextLength = 3800
    private let maxCardLength = 3500
    private let session = URLSession.shared

    private let appId: String
    private let appSecret: String
    private let botId: String
    private lazy var uploader = WeaFileUploader(appId: appId, appSecret: appSecret, botId: botId)

    // MARK: - Retry queue

    private let maxRetryQueueSize = 50
    private let maxRetriesPerMessage = 3
    private let maxRetryAge: TimeInterval = 300 // 5 minutes
    private var retryQueue: [(payload: [String: Any], attempt: Int, firstAttempt: Date)] = []

    /// Called by WeaBotService when the WebSocket reconnects, to flush queued messages.
    var onConnectionRestored: (() -> Void)?

    /// Last send error message, for debugging.
    private(set) var lastSendError: String?

    init(appId: String, appSecret: String, botId: String) {
        self.appId = appId
        self.appSecret = appSecret
        self.botId = botId
    }

    // MARK: - Public API

    /// Send a smart reply: auto-selects TEXT vs CARD based on content.
    @discardableResult
    func sendReply(
        text: String,
        dest: WeaMessageDest,
        topicContext: [String: Any]? = nil
    ) async throws -> SendResult {
        let hasMarkdown = text.range(of: #"[#*`\[\]>|]"#, options: .regularExpression) != nil
        let isLong = text.count > 200

        if hasMarkdown || isLong {
            // sendCard returns cardId; the underlying sendMessage handles retry/tracking
            _ = try await sendCard(content: text, dest: dest, context: topicContext)
            return .success
        } else {
            return try await sendText(body: text, dest: dest, context: topicContext)
        }
    }

    /// Send a CARD message (markdown content, creates a new chat bubble).
    /// Returns the card ID for subsequent REFRESH calls.
    @discardableResult
    func sendCard(
        content: String,
        dest: WeaMessageDest,
        context: [String: Any]? = nil,
        cardId: String? = nil
    ) async throws -> String {
        let id = cardId ?? "claude-\(UUID().uuidString.lowercased())"
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let preview = String(content.prefix(200))

        var payload: [String: Any] = [
            "version": 1,
            "type": "CARD",
            "src": botId,
            "srcDevice": 1,
            "dest": dest.json,
            "timestamp": now,
            "msg": ["body": preview],
            "card": [
                "appID": appId,
                "id": id,
                "content": String(content.prefix(maxCardLength)),
                "creator": botId,
                "timestamp": now,
                "fixedWidth": false,
                "version": now,
            ] as [String: Any],
        ]
        if let context { payload["context"] = context }

        let result = try await sendMessage(payload)
        if case .dropped(let reason) = result {
            weaLog("[HTTP] CARD \(id) dropped: \(reason)")
        }
        return id
    }

    /// Refresh an existing CARD (updates in-place, no new bubble).
    @discardableResult
    func refreshCard(
        cardId: String,
        content: String,
        dest: WeaMessageDest,
        context: [String: Any]? = nil
    ) async throws -> SendResult {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        var payload: [String: Any] = [
            "version": 1,
            "type": "REFRESH",
            "src": botId,
            "srcDevice": 1,
            "dest": dest.json,
            "timestamp": now,
            "card": [
                "appID": appId,
                "id": cardId,
                "content": String(content.prefix(maxCardLength)),
                "creator": botId,
                "version": now,
            ] as [String: Any],
        ]
        if let context { payload["context"] = context }

        return try await sendMessage(payload)
    }

    /// Send a plain TEXT message.
    @discardableResult
    func sendText(
        body: String,
        dest: WeaMessageDest,
        context: [String: Any]? = nil
    ) async throws -> SendResult {
        let chunks = splitText(body, maxLength: maxTextLength)
        var lastResult: SendResult = .success
        for chunk in chunks {
            var payload: [String: Any] = [
                "version": 1,
                "type": "TEXT",
                "src": botId,
                "srcDevice": 1,
                "dest": dest.json,
                "timestamp": Int(Date().timeIntervalSince1970 * 1000),
                "msg": ["body": chunk],
            ]
            if let context { payload["context"] = context }
            lastResult = try await sendMessage(payload)
        }
        return lastResult
    }

    /// Upload a file and send it as a TEXT message with an attachment.
    @discardableResult
    func sendAttachment(
        data: Data,
        fileName: String,
        contentType: String,
        dest: WeaMessageDest,
        body: String = ""
    ) async throws -> SendResult {
        let uploadResult = try await uploader.upload(data: data, dest: dest)

        let payload: [String: Any] = [
            "version": 1,
            "type": "TEXT",
            "src": botId,
            "srcDevice": 1,
            "dest": dest.json,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "msg": [
                "body": body,
                "attachment": [
                    "contentType": contentType,
                    "key": uploadResult.key,
                    "authorizeId": uploadResult.authorizeId,
                    "size": uploadResult.encryptedSize,
                    "cipherHash": uploadResult.cipherHash,
                    "fileName": fileName,
                ] as [String: Any],
            ] as [String: Any],
        ]

        weaLog("[HTTP] Sending attachment: \(fileName) (\(contentType), \(data.count)B)")
        return try await sendMessage(payload)
    }

    /// Resolve group name via GET /v1/groups/members (the correct Difft OpenAPI endpoint).
    ///
    /// Returns the group display name, or nil on failure.
    /// The response envelope is `{ status: 0, data: { name: "...", members: [...] } }`.
    func fetchGroupName(groupId: String, botId: String) async -> String? {
        let normalizedBotId = botId.hasPrefix("+") ? botId : "+\(botId)"
        let path = "/v1/groups/members"
        let query = ["operator": normalizedBotId, "gid": groupId]

        guard let json = try? await sendSignedGet(path: path, query: query),
              let dict = json as? [String: Any],
              let status = dict["status"] as? Int, status == 0,
              let data = dict["data"] as? [String: Any],
              let name = data["name"] as? String, !name.isEmpty
        else {
            return nil
        }

        weaLog("[HTTP] Resolved group name via \(path): gid=\(groupId) name=\(name)")
        return name
    }

    // MARK: - Private

    @discardableResult
    private func sendMessage(_ payload: [String: Any]) async throws -> SendResult {
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? ""

        let path = "/v1/messages"
        let signed = WeaSignature.signPost(
            appId: appId, appSecret: appSecret,
            path: path, jsonBody: jsonStr
        )

        var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (key, value) in signed.httpHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let msgType = payload["type"] as? String ?? "?"
        weaLog("[HTTP] Sending \(msgType), body=\(jsonStr.prefix(300))")

        do {
            let (data, response) = try await session.data(for: request)
            let respBody = String(data: data, encoding: .utf8) ?? ""
            if let httpResponse = response as? HTTPURLResponse {
                weaLog("[HTTP] Response \(msgType): status=\(httpResponse.statusCode) body=\(respBody.prefix(500))")
                if httpResponse.statusCode >= 400 && httpResponse.statusCode < 500 {
                    // 4xx client errors are not retryable — throw immediately
                    lastSendError = "HTTP \(httpResponse.statusCode): \(respBody)"
                    weaLog("[HTTP] Send failed (client error, not retryable): \(lastSendError!)")
                    logger.error("WEA API error \(httpResponse.statusCode): \(respBody)")
                    throw WeaError.apiError(statusCode: httpResponse.statusCode, body: respBody)
                } else if httpResponse.statusCode >= 500 {
                    // 5xx server errors are retryable
                    let errorMsg = "HTTP \(httpResponse.statusCode): \(respBody)"
                    lastSendError = errorMsg
                    weaLog("[HTTP] Send failed (server error, queuing retry): \(errorMsg)")
                    return enqueueForRetry(payload: payload)
                }
            }
            lastSendError = nil
            weaLog("[HTTP] Send \(msgType) succeeded")
            return .success
        } catch let error where !(error is WeaError) {
            // Network/transport errors are retryable
            let errorMsg = error.localizedDescription
            lastSendError = errorMsg
            weaLog("[HTTP] Send failed (network error, queuing retry): \(errorMsg)")
            return enqueueForRetry(payload: payload)
        }
    }

    private func enqueueForRetry(payload: [String: Any]) -> SendResult {
        // Drop oldest if queue is full
        if retryQueue.count >= maxRetryQueueSize {
            let dropped = retryQueue.removeFirst()
            let droppedType = dropped.payload["type"] as? String ?? "?"
            weaLog("[HTTP] Retry queue full, dropping oldest \(droppedType) message")
        }
        retryQueue.append((payload: payload, attempt: 0, firstAttempt: Date()))
        weaLog("[HTTP] Message queued for retry (queue size: \(retryQueue.count))")
        return .retryQueued
    }

    /// Flush the retry queue, re-sending each message with exponential backoff.
    /// Called when the connection is restored.
    func flushRetryQueue() async {
        guard !retryQueue.isEmpty else { return }
        weaLog("[HTTP] Flushing retry queue (\(retryQueue.count) messages)")

        var remaining: [(payload: [String: Any], attempt: Int, firstAttempt: Date)] = []
        let snapshot = retryQueue
        retryQueue.removeAll()

        for entry in snapshot {
            let age = Date().timeIntervalSince(entry.firstAttempt)

            // Drop if too old
            if age > maxRetryAge {
                let msgType = entry.payload["type"] as? String ?? "?"
                weaLog("[HTTP] Dropping expired \(msgType) message (age: \(Int(age))s)")
                continue
            }

            // Drop if max retries exceeded
            let attempt = entry.attempt + 1
            if attempt > maxRetriesPerMessage {
                let msgType = entry.payload["type"] as? String ?? "?"
                weaLog("[HTTP] Dropping \(msgType) message after \(entry.attempt) retries")
                continue
            }

            // Exponential backoff: 1s, 2s, 4s
            let backoff = pow(2.0, Double(entry.attempt))
            weaLog("[HTTP] Retry attempt \(attempt)/\(maxRetriesPerMessage), backoff \(backoff)s")
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))

            do {
                let jsonData = try JSONSerialization.data(withJSONObject: entry.payload)
                let jsonStr = String(data: jsonData, encoding: .utf8) ?? ""

                let path = "/v1/messages"
                let signed = WeaSignature.signPost(
                    appId: appId, appSecret: appSecret,
                    path: path, jsonBody: jsonStr
                )

                var request = URLRequest(url: URL(string: "\(baseURL)\(path)")!)
                request.httpMethod = "POST"
                request.httpBody = jsonData
                request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
                for (key, value) in signed.httpHeaders {
                    request.setValue(value, forHTTPHeaderField: key)
                }

                let msgType = entry.payload["type"] as? String ?? "?"
                let (data, response) = try await session.data(for: request)
                let respBody = String(data: data, encoding: .utf8) ?? ""
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode < 400 {
                        weaLog("[HTTP] Retry succeeded for \(msgType)")
                    } else {
                        weaLog("[HTTP] Retry failed for \(msgType): status=\(httpResponse.statusCode) body=\(respBody.prefix(300))")
                        remaining.append((payload: entry.payload, attempt: attempt, firstAttempt: entry.firstAttempt))
                    }
                }
            } catch {
                weaLog("[HTTP] Retry network error: \(error.localizedDescription)")
                remaining.append((payload: entry.payload, attempt: attempt, firstAttempt: entry.firstAttempt))
            }
        }

        if !remaining.isEmpty {
            retryQueue.append(contentsOf: remaining)
            weaLog("[HTTP] \(remaining.count) messages remain in retry queue")
        } else {
            weaLog("[HTTP] Retry queue flushed successfully")
        }
    }

    private func sendSignedGet(path: String, query: [String: String]) async throws -> Any {
        let signed = WeaSignature.signGet(
            appId: appId,
            appSecret: appSecret,
            path: path,
            query: query
        )

        let encodedQuery = query
            .sorted { $0.key < $1.key }
            .map { "\(percentEncodeQueryComponent($0.key))=\(percentEncodeQueryComponent($0.value))" }
            .joined(separator: "&")
        guard let url = URL(string: "\(baseURL)\(path)?\(encodedQuery)") else {
            throw WeaError.notConnected
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in signed.httpHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let queryDesc = query.keys.sorted().map { "\($0)=\(query[$0]!)" }.joined(separator: "&")
        weaLog("[HTTP] GET \(path)?\(queryDesc)")
        let (data, response) = try await session.data(for: request)
        let respBody = String(data: data, encoding: .utf8) ?? ""
        if let httpResponse = response as? HTTPURLResponse {
            weaLog("[HTTP] GET response \(httpResponse.statusCode) for \(path): \(respBody.prefix(400))")
            guard httpResponse.statusCode < 400 else {
                throw WeaError.apiError(statusCode: httpResponse.statusCode, body: respBody)
            }
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func percentEncodeQueryComponent(_ value: String) -> String {
        // RFC 3986 unreserved chars only, so "+" is encoded as "%2B".
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Split text at paragraph/line/word boundaries.
    func splitText(_ text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength else { return [text] }
        var chunks: [String] = []
        var remaining = text

        while !remaining.isEmpty {
            if remaining.count <= maxLength {
                chunks.append(remaining)
                break
            }
            let prefix = String(remaining.prefix(maxLength))
            // Try paragraph boundary
            if let range = prefix.range(of: "\n\n", options: .backwards) {
                let chunk = String(prefix[..<range.lowerBound])
                chunks.append(chunk)
                remaining = String(remaining[range.upperBound...])
            // Try line boundary
            } else if let range = prefix.range(of: "\n", options: .backwards) {
                let chunk = String(prefix[..<range.lowerBound])
                chunks.append(chunk)
                remaining = String(remaining[range.upperBound...])
            // Try word boundary
            } else if let range = prefix.range(of: " ", options: .backwards) {
                let chunk = String(prefix[..<range.lowerBound])
                chunks.append(chunk)
                remaining = String(remaining[range.upperBound...])
            } else {
                // Hard cut
                chunks.append(prefix)
                remaining = String(remaining.dropFirst(maxLength))
            }
        }
        return chunks
    }
}

enum WeaError: LocalizedError {
    case apiError(statusCode: Int, body: String)
    case notConfigured
    case notConnected

    var errorDescription: String? {
        switch self {
        case .apiError(let code, let body): return "WEA API error \(code): \(body)"
        case .notConfigured: return "WEA bot is not configured"
        case .notConnected: return "WEA bot is not connected"
        }
    }
}
