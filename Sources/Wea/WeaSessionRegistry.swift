// Sources/Wea/WeaSessionRegistry.swift
import Foundation
import os

/// Persists WEA session mappings (uid/gid → terminal) to a local JSON file
/// so the state is inspectable externally and survives across routing decisions.
@MainActor
final class WeaSessionRegistry {
    struct Entry: Codable {
        let sessionKey: String
        let groupId: String
        let displayName: String
        var workspaceId: String
        var panelId: String
        var alive: Bool
        var lastMessageAt: Date
        var claudeSessionId: String?
        var chatType: String?           // "direct" or "group"
        var lastSummaryAt: Date?
        var destGroupId: String?        // for GROUP dest reconstruction
        var destWuid: String?           // for USER dest reconstruction
    }

    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "WeaSessionRegistry")
    private var entries: [String: Entry] = [:]

    private var filePath: String {
        let root = WeaBotConfig.shared.resolvedSessionsRootPath
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return (root as NSString).appendingPathComponent("session-map.json")
    }

    init() {
        load()
    }

    // MARK: - Public API

    func register(sessionKey: String, groupId: String, displayName: String, workspaceId: UUID, panelId: UUID, chatType: String? = nil, destGroupId: String? = nil, destWuid: String? = nil) {
        entries[sessionKey] = Entry(
            sessionKey: sessionKey,
            groupId: groupId,
            displayName: displayName,
            workspaceId: workspaceId.uuidString,
            panelId: panelId.uuidString,
            alive: true,
            lastMessageAt: Date(),
            claudeSessionId: nil,
            chatType: chatType,
            lastSummaryAt: nil,
            destGroupId: destGroupId,
            destWuid: destWuid
        )
        save()
    }

    func unregister(sessionKey: String) {
        entries.removeValue(forKey: sessionKey)
        save()
    }

    func markDead(sessionKey: String) {
        guard var entry = entries[sessionKey] else { return }
        entry.alive = false
        entries[sessionKey] = entry
        save()
    }

    func touchMessage(sessionKey: String) {
        guard var entry = entries[sessionKey] else { return }
        entry.alive = true
        entry.lastMessageAt = Date()
        entries[sessionKey] = entry
        save()
    }

    func updateClaudeSessionId(_ sessionId: String, for sessionKey: String) {
        guard var entry = entries[sessionKey] else { return }
        entry.claudeSessionId = sessionId
        entries[sessionKey] = entry
        save()
    }

    func updateLastSummary(for sessionKey: String) {
        guard var entry = entries[sessionKey] else { return }
        entry.lastSummaryAt = Date()
        entries[sessionKey] = entry
        save()
    }

    func entry(for sessionKey: String) -> Entry? {
        entries[sessionKey]
    }

    /// Returns all entries with `alive == true` and `lastMessageAt` after the given date.
    func activeEntries(since cutoff: Date) -> [Entry] {
        entries.values.filter { $0.alive && $0.lastMessageAt >= cutoff }
    }

    func removeAll() {
        entries.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        let path = filePath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: Entry].self, from: data) {
            entries = decoded
            logger.info("Loaded \(decoded.count) session entries from registry")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        let path = filePath
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
