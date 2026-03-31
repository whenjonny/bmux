// Sources/Wea/WeaBotConfig.swift
import Foundation
import Security

/// Persistent configuration for the WEA bot connection.
final class WeaBotConfig: ObservableObject {
    static let shared = WeaBotConfig()

    private static let appIdKey = "weaBot.appId"
    private static let botIdKey = "weaBot.botId"
    private static let autoConnectKey = "weaBot.autoConnect"
    private static let groupBlacklistKey = "weaBot.groupBlacklist"
    private static let knownGroupsKey = "weaBot.knownGroups"
    private static let sessionsRootPathKey = "weaBot.sessionsRootPath"
    private static let keychainService = "com.cmuxterm.app.wea-bot"
    private static let keychainAccount = "app-secret"

    @Published var appId: String {
        didSet { UserDefaults.standard.set(appId, forKey: Self.appIdKey) }
    }
    @Published var botId: String {
        didSet { UserDefaults.standard.set(botId, forKey: Self.botIdKey) }
    }
    @Published var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: Self.autoConnectKey) }
    }
    @Published var groupBlacklist: Set<String> {
        didSet { UserDefaults.standard.set(Array(groupBlacklist), forKey: Self.groupBlacklistKey) }
    }
    @Published var knownGroups: [String: String] = [:] {  // groupId → groupName
        didSet {
            if let data = try? JSONEncoder().encode(knownGroups) {
                UserDefaults.standard.set(data, forKey: Self.knownGroupsKey)
            }
        }
    }
    @Published var sessionsRootPath: String {
        didSet { UserDefaults.standard.set(sessionsRootPath, forKey: Self.sessionsRootPathKey) }
    }

    /// Messages older than this threshold (in milliseconds) are considered stale and skipped.
    /// Default: 120,000ms (2 minutes).
    var staleMessageThresholdMs: Int64 = 120_000

    var isConfigured: Bool {
        !appId.isEmpty && !botId.isEmpty && loadSecret() != nil
    }

    private init() {
        self.appId = UserDefaults.standard.string(forKey: Self.appIdKey) ?? ""
        self.botId = UserDefaults.standard.string(forKey: Self.botIdKey) ?? ""
        self.autoConnect = UserDefaults.standard.bool(forKey: Self.autoConnectKey)
        self.groupBlacklist = Set(UserDefaults.standard.stringArray(forKey: Self.groupBlacklistKey) ?? [])
        if let data = UserDefaults.standard.data(forKey: Self.knownGroupsKey),
           let groups = try? JSONDecoder().decode([String: String].self, from: data) {
            self.knownGroups = groups
        }
        self.sessionsRootPath = UserDefaults.standard.string(forKey: Self.sessionsRootPathKey) ?? ""
    }

    // MARK: - Keychain (app secret)

    func saveSecret(_ secret: String) -> Bool {
        deleteSecret()
        guard let data = secret.data(using: .utf8) else { return false }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
            kSecValueData: data,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func loadSecret() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func deleteSecret() -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func addToBlacklist(_ groupId: String) {
        groupBlacklist.insert(groupId)
    }

    func removeFromBlacklist(_ groupId: String) {
        groupBlacklist.remove(groupId)
    }

    func isBlacklisted(_ groupId: String) -> Bool {
        groupBlacklist.contains(groupId)
    }

    /// Resolved sessions root path. Falls back to `{cwd}/wea-sessions` if empty.
    var resolvedSessionsRootPath: String {
        let path = sessionsRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("wea-sessions")
        }
        return path
    }

    /// Creates and returns the session folder for a given group ID.
    /// Seeds CLAUDE.md and journal.md on first creation.
    func sessionFolder(for groupId: String) -> String {
        let root = resolvedSessionsRootPath
        let folder = (root as NSString).appendingPathComponent(groupId)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        seedClaudeMd(in: folder)
        seedJournal(in: folder)
        updateJournalIndex(in: folder, currentGroupId: groupId)
        return folder
    }

    private func seedClaudeMd(in folder: String) {
        let path = (folder as NSString).appendingPathComponent("CLAUDE.md")
        guard !FileManager.default.fileExists(atPath: path) else { return }

        let content = """
        # WEA Bot Session

        You are running inside a cmux WEA bot session. User messages come from WEA (IM chat).
        Your text responses are automatically sent back to the WEA chat.

        ## Context recovery priority

        When starting a session, recover context in this order:
        1. **Session resume** — if `--resume` was used, full conversation history is already loaded. Skip to user's message.
        2. **journal.md** — read `journal.md` in this directory for prior session history. This is your persistent memory across sessions.
        3. **Parent CLAUDE.md** — project-level instructions are inherited automatically from the parent directory.

        ## Journal protocol

        `journal.md` is your persistent memory. It survives session restarts and context compression.

        **On session start:** Read `journal.md` to understand what happened in prior sessions.

        **After completing significant work:** Append an entry to `journal.md`:

        ```
        ## YYYY-MM-DD HH:MM — [Topic]
        **Context:** What was discussed or requested
        **Done:** What was accomplished
        **Decisions:** Key decisions made (and why)
        **Status:** Current state
        **Next:** What should happen next
        ```

        **After context compression:** Re-read `journal.md` to recover key details that were lost.

        Keep entries concise (5-10 lines). Focus on decisions and state, not conversation replay.

        ## Sending files/images to the chat

        To send a file or image to the WEA user, use the cmux CLI:

            cmux wea send-file <path>

        Example — take a screenshot and send it:

            cmux screenshot              # captures window, prints "OK <id> <path>"
            cmux wea send-file /tmp/cmux-screenshots/<filename>.png

        Example — send any file:

            cmux wea send-file /path/to/report.pdf --body "Here's the report"

        The `--body` flag adds a text caption alongside the attachment.

        ## Available cmux commands

        - `cmux screenshot [label]` — capture the cmux window as PNG, returns path
        - `cmux wea send-file <path> [--body "text"]` — send a file to this WEA chat
        """
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func seedJournal(in folder: String) {
        let path = (folder as NSString).appendingPathComponent("journal.md")
        guard !FileManager.default.fileExists(atPath: path) else { return }

        let content = """
        # Session Journal

        Persistent context log for this WEA chat session.
        Append entries after completing significant work. Read on session start.

        ---

        """
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Updates the cross-session journal index section in CLAUDE.md.
    /// Scans sibling session directories for journal.md files and writes
    /// a machine-readable index so the bot can discover cross-session context.
    private func updateJournalIndex(in folder: String, currentGroupId: String) {
        let claudeMdPath = (folder as NSString).appendingPathComponent("CLAUDE.md")
        guard FileManager.default.fileExists(atPath: claudeMdPath),
              var content = try? String(contentsOfFile: claudeMdPath, encoding: .utf8) else { return }

        let root = resolvedSessionsRootPath
        let fm = FileManager.default
        guard let siblings = try? fm.contentsOfDirectory(atPath: root) else { return }

        let startMarker = "<!-- JOURNAL_INDEX_START -->"
        let endMarker = "<!-- JOURNAL_INDEX_END -->"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var entries: [String] = []
        for sibling in siblings.sorted() {
            guard sibling != currentGroupId else { continue }
            let journalPath = (root as NSString)
                .appendingPathComponent(sibling)
                .appending("/journal.md")
            guard fm.fileExists(atPath: journalPath) else { continue }

            let displayName: String
            if let name = knownGroups[sibling], !name.isEmpty {
                displayName = "\(name) (\(sibling))"
            } else {
                displayName = sibling
            }

            var dateStr = ""
            if let attrs = try? fm.attributesOfItem(atPath: journalPath),
               let modified = attrs[.modificationDate] as? Date {
                dateStr = " (updated: \(dateFormatter.string(from: modified)))"
            }
            entries.append("- `../\(sibling)/journal.md` — \(displayName)\(dateStr)")
        }

        var indexSection = "\(startMarker)\n\n## Cross-session journal index\n\n"
        if entries.isEmpty {
            indexSection += "No other sessions found yet.\n"
        } else {
            indexSection += "Other WEA sessions maintain their own journals. Read these for cross-session context:\n\n"
            indexSection += entries.joined(separator: "\n") + "\n"
        }
        indexSection += "\n\(endMarker)"

        // Replace existing index or append.
        if let startRange = content.range(of: startMarker),
           let endRange = content.range(of: endMarker) {
            content.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: indexSection)
        } else {
            content += "\n\n\(indexSection)\n"
        }

        try? content.write(toFile: claudeMdPath, atomically: true, encoding: .utf8)
    }
}
