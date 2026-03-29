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
    func sessionFolder(for groupId: String) -> String {
        let root = resolvedSessionsRootPath
        let folder = (root as NSString).appendingPathComponent(groupId)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }
}
