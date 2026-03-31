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
        var displayName: String
        var workspaceId: String
        var panelId: String
        var claudeSessionId: String?
        var alive: Bool
        var lastMessageAt: Date
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

    func register(sessionKey: String, groupId: String, displayName: String, workspaceId: UUID, panelId: UUID) {
        let existingSessionId = entries[sessionKey]?.claudeSessionId
        entries[sessionKey] = Entry(
            sessionKey: sessionKey,
            groupId: groupId,
            displayName: displayName,
            workspaceId: workspaceId.uuidString,
            panelId: panelId.uuidString,
            claudeSessionId: existingSessionId,
            alive: true,
            lastMessageAt: Date()
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

    func updateDisplayName(sessionKey: String, displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var entry = entries[sessionKey] else { return }
        guard entry.displayName != trimmed else { return }
        entry.displayName = trimmed
        entries[sessionKey] = entry
        save()
    }

    func updateClaudeSessionId(sessionKey: String, sessionId: String) {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var entry = entries[sessionKey] else { return }
        guard entry.claudeSessionId != trimmed else { return }
        entry.claudeSessionId = trimmed
        entries[sessionKey] = entry
        save()
    }

    func entry(for sessionKey: String) -> Entry? {
        entries[sessionKey]
    }

    func entry(forWorkspaceId workspaceId: UUID) -> Entry? {
        let normalized = workspaceId.uuidString.lowercased()
        return entries.values.first { $0.workspaceId.lowercased() == normalized }
    }

    func entries(forGroupId groupId: String) -> [Entry] {
        entries.values.filter { $0.groupId == groupId }
    }

    func preferredSessionKey(groupId: String, workspaceId: UUID? = nil) -> String? {
        let normalizedWorkspaceId = workspaceId?.uuidString.lowercased()
        if let normalizedWorkspaceId {
            if let byWorkspace = entries.values.first(where: { $0.workspaceId.lowercased() == normalizedWorkspaceId }) {
                return byWorkspace.sessionKey
            }
        }

        let candidates = entries.values
            .filter { $0.groupId == groupId }
            .sorted {
                if $0.alive != $1.alive {
                    return $0.alive && !$1.alive
                }
                return $0.lastMessageAt > $1.lastMessageAt
            }
        return candidates.first?.sessionKey
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
