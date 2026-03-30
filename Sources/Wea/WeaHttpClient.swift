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

    init(appId: String, appSecret: String, botId: String) {
        self.appId = appId
        self.appSecret = appSecret
        self.botId = botId
    }

    // MARK: - Public API

    /// Send a smart reply: auto-selects TEXT vs CARD based on content.
    func sendReply(
        text: String,
        dest: WeaMessageDest,
        topicContext: [String: Any]? = nil
    ) async throws {
        let hasMarkdown = text.range(of: #"[#*`\[\]>|]"#, options: .regularExpression) != nil
        let isLong = text.count > 200

        if hasMarkdown || isLong {
            try await sendCard(content: text, dest: dest, context: topicContext)
        } else {
            try await sendText(body: text, dest: dest, context: topicContext)
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

        try await sendMessage(payload)
        return id
    }

    /// Refresh an existing CARD (updates in-place, no new bubble).
    func refreshCard(
        cardId: String,
        content: String,
        dest: WeaMessageDest,
        context: [String: Any]? = nil
    ) async throws {
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

        try await sendMessage(payload)
    }

    /// Send a plain TEXT message.
    func sendText(
        body: String,
        dest: WeaMessageDest,
        context: [String: Any]? = nil
    ) async throws {
        let chunks = splitText(body, maxLength: maxTextLength)
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
            try await sendMessage(payload)
        }
    }

    /// Upload a file and send it as a TEXT message with an attachment.
    func sendAttachment(
        data: Data,
        fileName: String,
        contentType: String,
        dest: WeaMessageDest,
        body: String = ""
    ) async throws {
        let result = try await uploader.upload(data: data, dest: dest)

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
                    "key": result.key,
                    "authorizeId": result.authorizeId,
                    "size": result.encryptedSize,
                    "cipherHash": result.cipherHash,
                    "fileName": fileName,
                ] as [String: Any],
            ] as [String: Any],
        ]

        weaLog("[HTTP] Sending attachment: \(fileName) (\(contentType), \(data.count)B)")
        try await sendMessage(payload)
    }

    // MARK: - Private

    private func sendMessage(_ payload: [String: Any]) async throws {
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

        let (data, response) = try await session.data(for: request)
        let respBody = String(data: data, encoding: .utf8) ?? ""
        if let httpResponse = response as? HTTPURLResponse {
            weaLog("[HTTP] Response \(msgType): status=\(httpResponse.statusCode) body=\(respBody.prefix(500))")
            if httpResponse.statusCode >= 400 {
                logger.error("WEA API error \(httpResponse.statusCode): \(respBody)")
                throw WeaError.apiError(statusCode: httpResponse.statusCode, body: respBody)
            }
        }
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
