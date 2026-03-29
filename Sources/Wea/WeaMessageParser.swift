import Foundation

// MARK: - Parsed message

/// A structured representation of an inbound WEA (Difft) webhook payload.
///
/// The raw SDK wire format looks like:
/// ```json
/// {
///   "version": 1,
///   "src": "+75601775597",
///   "srcDevice": 1,
///   "dest": {
///     "wuid": ["+21084"],
///     "groupID": "abc123",
///     "type": "USER" | "GROUP"
///   },
///   "type": "TEXT",
///   "timestamp": 1653969339615,
///   "msg": {
///     "body": "hello",
///     "refID": "v1:1653969339615:+75601775597",
///     "atPersons": ["+botId"]
///   },
///   "mentions": [{ "uid": "+botId", "start": 0, "length": 5, "type": 0 }],
///   "context": { "topic": { "id": "topicId" } }
/// }
/// ```
struct WeaParsedMessage {

    /// Whether this message arrived in a 1:1 DM or a group chat.
    enum ChatType: String, Sendable {
        case directMessage
        case groupChat
    }

    let messageId: String
    let senderWuid: String
    let senderName: String?
    let text: String
    let timestamp: Int64
    let chatType: ChatType
    let groupId: String?
    let topicId: String?
    let isMentionBot: Bool

    /// The raw JSON dictionary for fields we don't parse.
    let rawPayload: [String: Any]
}

// MARK: - Message destination

/// An outbound message destination for replies.
///
/// Matches the SDK `SendMessageDest` wire format:
/// ```json
/// { "wuid": ["+123"], "type": "USER" }
/// { "groupID": "abc", "type": "GROUP" }
/// ```
struct WeaMessageDest: Sendable {

    enum DestType: String, Sendable {
        case user = "USER"
        case group = "GROUP"
    }

    let type: DestType
    /// For DMs: the recipient wuid (single value).
    let wuid: String?
    /// For groups: the target group ID.
    let groupId: String?

    // MARK: - JSON

    /// A JSON-serializable dictionary suitable for the `dest` field in send requests.
    var json: [String: Any] {
        var dict: [String: Any] = ["type": type.rawValue]
        switch type {
        case .user:
            if let wuid {
                dict["wuid"] = [wuid]
            }
        case .group:
            if let groupId {
                dict["groupID"] = groupId
            }
        }
        return dict
    }

    // MARK: - Factory methods

    /// Create a DM destination targeting a single wuid.
    static func dm(to wuid: String) -> WeaMessageDest {
        WeaMessageDest(type: .user, wuid: wuid, groupId: nil)
    }

    /// Create a group chat destination.
    static func group(_ groupId: String) -> WeaMessageDest {
        WeaMessageDest(type: .group, wuid: nil, groupId: groupId)
    }
}

// MARK: - Parser

/// Stateless parser that converts raw WEA/Difft JSON payloads into typed messages.
///
/// Ported from `claude_wea` TypeScript `MessageHandler.parseMessage()`.
enum WeaMessageParser {

    // MARK: - Errors

    enum ParseError: LocalizedError, Equatable {
        case invalidPayload
        case missingSource
        case unsupportedType(String)

        var errorDescription: String? {
            switch self {
            case .invalidPayload:
                return "Payload must be a non-null JSON object"
            case .missingSource:
                return "Missing src / from in payload"
            case .unsupportedType(let type):
                return "Skipping non-text message type: \(type)"
            }
        }
    }

    // MARK: - Public API

    /// Parse a raw JSON dictionary from the WEA WebSocket into a structured message.
    ///
    /// - Parameters:
    ///   - payload: The raw JSON dictionary from the WebSocket frame.
    ///   - botId: The bot's own wuid (e.g. `"29905"` or `"+29905"`), used for mention detection.
    /// - Throws: `ParseError` if the payload is malformed or a non-text type.
    static func parse(_ payload: [String: Any], botId: String) throws -> WeaParsedMessage {

        // --- Skip non-text messages (RECEIPT, RECALL, etc.)
        if let msgType = payload["type"] as? String,
           msgType != "TEXT", msgType != "CARD" {
            throw ParseError.unsupportedType(msgType)
        }

        // --- Sender wuid
        let senderWuid: String = {
            if let src = payload["src"] as? String, !src.isEmpty { return src }
            if let from = payload["from"] as? String, !from.isEmpty { return from }
            return ""
        }()
        guard !senderWuid.isEmpty else {
            throw ParseError.missingSource
        }

        // --- Message ID: prefer msg.refID, fall back to timestamp+src
        let msg = payload["msg"] as? [String: Any]
        let timestamp: Int64 = {
            if let ts = payload["timestamp"] as? Int64 { return ts }
            if let ts = payload["timestamp"] as? Int { return Int64(ts) }
            if let ts = payload["timestamp"] as? Double { return Int64(ts) }
            return Int64(Date().timeIntervalSince1970 * 1000)
        }()
        let messageId: String = {
            if let refID = msg?["refID"] as? String, !refID.isEmpty { return refID }
            if let refId = msg?["refId"] as? String, !refId.isEmpty { return refId }
            return "\(timestamp):\(senderWuid)"
        }()

        let senderName = payload["fromName"] as? String

        // --- Dest (normalize SDK format)
        let dest = parseDest(payload)

        // --- Content
        let text = extractContent(payload)

        // --- Chat type and group ID
        let groupId = dest.groupId
        let chatType: WeaParsedMessage.ChatType =
            dest.type == .group || groupId != nil ? .groupChat : .directMessage

        // --- Mention detection
        let isMentionBot = detectMentionBot(payload, content: text, botId: botId)

        // --- Topic ID
        let topicId = extractTopicId(payload)

        return WeaParsedMessage(
            messageId: messageId,
            senderWuid: senderWuid,
            senderName: senderName,
            text: text,
            timestamp: timestamp,
            chatType: chatType,
            groupId: groupId,
            topicId: topicId,
            isMentionBot: isMentionBot,
            rawPayload: payload
        )
    }

    /// Compute the correct reply destination for a parsed message.
    ///
    /// - For group chats: reply to the group.
    /// - For DMs: reply to the sender (not `dest.wuid`, which is the bot itself).
    static func replyDest(for message: WeaParsedMessage) -> WeaMessageDest {
        switch message.chatType {
        case .groupChat:
            if let groupId = message.groupId {
                return .group(groupId)
            }
            // Shouldn't happen, but fall back to DM
            return .dm(to: message.senderWuid)
        case .directMessage:
            return .dm(to: message.senderWuid)
        }
    }

    // MARK: - Private helpers

    /// Parse the `dest` field out of the raw payload.
    ///
    /// SDK format:
    ///   - `dest.type` = `"USER"` or `"GROUP"` (uppercase)
    ///   - `dest.groupID` = `"abc123"` (capital D)
    ///   - `dest.wuid` = `["+123"]` (array)
    private static func parseDest(_ payload: [String: Any]) -> WeaMessageDest {
        let sender = (payload["src"] as? String) ?? (payload["from"] as? String) ?? ""

        if let destRaw = payload["dest"] as? [String: Any] {
            let destType = ((destRaw["type"] as? String) ?? "").uppercased()

            if destType == "GROUP" {
                let groupId = (destRaw["groupID"] as? String)
                    ?? (destRaw["groupId"] as? String)
                    ?? ""
                return .group(groupId)
            }

            // DM: reply to sender, not dest.wuid (which is the bot)
            return sender.isEmpty ? WeaMessageDest(type: .user, wuid: nil, groupId: nil)
                                  : .dm(to: sender)
        }

        // Fallback: infer from top-level fields
        if let groupId = (payload["groupID"] as? String) ?? (payload["groupId"] as? String) {
            return .group(groupId)
        }

        return sender.isEmpty ? WeaMessageDest(type: .user, wuid: nil, groupId: nil)
                              : .dm(to: sender)
    }

    /// Extract text content from the raw payload.
    ///
    /// Body can live in `msg.body`, `msg.text`, or top-level `content`/`text`.
    private static func extractContent(_ payload: [String: Any]) -> String {
        if let msg = payload["msg"] as? [String: Any] {
            if let body = msg["body"] as? String { return body }
            if let text = msg["text"] as? String { return text }
        }
        if let content = payload["content"] as? String { return content }
        if let text = payload["text"] as? String { return text }
        return ""
    }

    /// Extract topic ID from `context.topic.id`.
    private static func extractTopicId(_ payload: [String: Any]) -> String? {
        guard let ctx = payload["context"] as? [String: Any],
              let topic = ctx["topic"] as? [String: Any],
              let id = topic["id"] as? String,
              !id.isEmpty
        else { return nil }
        return id
    }

    /// Detect whether the bot was explicitly @-mentioned in the message.
    ///
    /// Checks multiple SDK locations:
    /// - `msg.atPersons` array
    /// - top-level `atPersons` array
    /// - `mentions[].uid`
    /// - `@botName` text pattern (not used here since we don't have botName)
    private static func detectMentionBot(
        _ payload: [String: Any],
        content: String,
        botId: String
    ) -> Bool {
        // Build variants: "29905", "+29905"
        let stripped = botId.hasPrefix("+") ? String(botId.dropFirst()) : botId
        let prefixed = botId.hasPrefix("+") ? botId : "+\(botId)"
        let variants: Set<String> = [botId, stripped, prefixed]

        let matchesBotId: (Any) -> Bool = { val in
            guard let s = val as? String else { return false }
            return variants.contains(s)
        }

        // Check msg.atPersons
        if let msg = payload["msg"] as? [String: Any],
           let atPersons = msg["atPersons"] as? [Any],
           atPersons.contains(where: matchesBotId) {
            return true
        }

        // Check top-level atPersons
        if let atPersons = payload["atPersons"] as? [Any],
           atPersons.contains(where: matchesBotId) {
            return true
        }

        // Check mentions array: [{ uid: "+botId", ... }]
        if let mentions = payload["mentions"] as? [[String: Any]] {
            if mentions.contains(where: { matchesBotId($0["uid"] as Any) }) {
                return true
            }
        }

        return false
    }
}
