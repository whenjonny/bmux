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

    func register(sessionKey: String, groupId: String, displayName: String) {
        entries[sessionKey] = Entry(
            sessionKey: sessionKey,
            groupId: groupId,
            displayName: displayName,
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
