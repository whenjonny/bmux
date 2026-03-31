// Sources/Wea/WeaWorkspaceManager.swift
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

/// Manages WEA chat workspaces.
/// Each WEA group/DM gets its own independent Workspace with a dedicated session folder.
@MainActor
final class WeaWorkspaceManager {
    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "WeaWorkspaceManager")
    private weak var tabManager: TabManager?

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    // MARK: - Workspace Lookup & Creation

    /// Find the existing workspace for a group ID, or nil.
    func workspace(for groupId: String) -> Workspace? {
        tabManager?.tabs.first { $0.weaGroupId == groupId }
    }

    /// Build the shell command to launch Claude in a WEA session.
    /// Since this is sent via sendInput into an already-running login shell,
    /// we just need cd + the launch command (shell already has full PATH).
    func launchCommand(for groupId: String, claudeSessionId: String? = nil, continueLastSession: Bool = false) -> String {
        let folder = WeaBotConfig.shared.sessionFolder(for: groupId)
        return launchCommand(workingDirectory: folder, claudeSessionId: claudeSessionId, continueLastSession: continueLastSession)
    }

    private func launchCommand(workingDirectory: String, claudeSessionId: String? = nil, continueLastSession: Bool = false) -> String {
        let quotedCwd = shellSingleQuote(workingDirectory)
        var cmd = "cd \(quotedCwd) && codemax claude --allow-dangerously-skip-permissions --model=bedrock-claude-4-6-opus"
        if let sessionId = claudeSessionId, !sessionId.isEmpty {
            cmd += " --resume \(shellSingleQuote(sessionId))"
        } else if continueLastSession {
            cmd += " --continue"
        }
        return cmd
    }

    /// Find or create a workspace for a group/DM session.
    /// Returns the terminal panel for message injection.
    func findOrCreatePanel(groupId: String, displayName: String, claudeSessionId: String? = nil) -> TerminalPanel? {
        let folder = WeaBotConfig.shared.sessionFolder(for: groupId)
        let command = launchCommand(workingDirectory: folder, claudeSessionId: claudeSessionId)
        weaLog("[WM] findOrCreatePanel: groupId=\(groupId) claudeSessionId=\(claudeSessionId ?? "nil")")

        // Check for existing workspace (created earlier this session).
        if let existing = workspace(for: groupId) {
            weaLog("[WM] Found existing workspace for \(groupId), panels=\(existing.panels.count)")
            if let existingPanel = existing.panels.values.compactMap({ $0 as? TerminalPanel }).first {
                logger.info("Reusing existing panel for \(groupId), panelId=\(existingPanel.id)")
                return existingPanel
            }
            // Workspace exists but terminal was closed. Recreate a new terminal panel.
            guard let paneId = existing.bonsplitController.focusedPaneId ?? existing.bonsplitController.allPaneIds.first,
                  let newPanel = existing.newTerminalSurface(inPane: paneId, focus: false, workingDirectory: folder) else {
                return nil
            }
            newPanel.sendInput(command + "\n")
            logger.info("Recreated WEA terminal panel for \(groupId) in existing workspace \(existing.id.uuidString)")
            return newPanel
        }

        // Create workspace in the background (not selected) with eager terminal loading.
        guard let tabManager else { return nil }
        let workspace = tabManager.addWorkspace(
            title: displayName,
            workingDirectory: folder,
            select: false,
            eagerLoadTerminal: true
        )
        workspace.weaGroupId = groupId
        logger.info("Created WEA workspace '\(displayName)' for \(groupId) at \(folder)")

        guard let panel = workspace.panels.values.compactMap({ $0 as? TerminalPanel }).first else {
            return nil
        }
        // Wait for the terminal surface to be live before sending the launch command.
        Task { [weak panel, weak self] in
            guard let panel else { return }
            for _ in 0..<50 { // up to ~5 seconds
                if panel.surface.hasLiveSurface { break }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            guard panel.surface.hasLiveSurface else {
                self?.logger.error("WEA workspace surface failed to initialize for \(groupId)")
                return
            }
            panel.sendInput(command + "\n")
        }
        return panel
    }

    // MARK: - Cleanup

    /// Close all WEA workspaces (called on disconnect).
    func closeAllWeaWorkspaces() {
        guard let tabManager else { return }
        let weaWorkspaces = tabManager.tabs.filter { $0.weaGroupId != nil }
        for workspace in weaWorkspaces {
            tabManager.closeWorkspace(workspace)
        }
        logger.info("Closed \(weaWorkspaces.count) WEA workspaces")
    }

    /// Close workspace for a specific group.
    func closeWorkspace(for groupId: String) {
        guard let tabManager, let workspace = workspace(for: groupId) else { return }
        tabManager.closeWorkspace(workspace)
    }

    private func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
