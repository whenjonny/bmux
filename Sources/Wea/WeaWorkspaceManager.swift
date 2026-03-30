// Sources/Wea/WeaWorkspaceManager.swift
import Foundation
import os

/// Manages WEA chat workspaces.
/// Each WEA group/DM gets its own independent Workspace with a dedicated session folder.
@MainActor
final class WeaWorkspaceManager {
    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "WeaWorkspaceManager")
    private weak var tabManager: TabManager?
    /// Tracks panels where Claude was launched this app session.
    /// Panels from restored workspaces won't be in this set.
    private var launchedPanelIds: Set<UUID> = []

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    // MARK: - Workspace Lookup & Creation

    /// Find the existing workspace for a group ID, or nil.
    func workspace(for groupId: String) -> Workspace? {
        tabManager?.tabs.first { $0.weaGroupId == groupId }
    }

    /// Whether a specific terminal panel is still alive in the session workspace.
    func hasLiveTerminalPanel(groupId: String, panelId: UUID) -> Bool {
        guard let workspace = workspace(for: groupId),
              let panel = workspace.panels[panelId] as? TerminalPanel else {
            return false
        }
        return panel.workspaceId == workspace.id
    }

    /// Build the shell command to launch Claude in a WEA session.
    /// Since this is sent via sendInput into an already-running login shell,
    /// we just need cd + the launch command (shell already has full PATH).
    func launchCommand(for groupId: String, claudeSessionId: String? = nil) -> String {
        let folder = WeaBotConfig.shared.sessionFolder(for: groupId)
        return launchCommand(workingDirectory: folder, claudeSessionId: claudeSessionId)
    }

    private func launchCommand(workingDirectory: String, claudeSessionId: String? = nil) -> String {
        let quotedCwd = shellSingleQuote(workingDirectory)
        var cmd = "cd \(quotedCwd) && codemax claude --allow-dangerously-skip-permissions --model=bedrock-claude-4-6-opus"
        if let sessionId = claudeSessionId, !sessionId.isEmpty {
            cmd += " --resume \(shellSingleQuote(sessionId))"
        }
        return cmd
    }

    /// Find or create a workspace for a group/DM session.
    /// Returns the terminal panel for message injection.
    func findOrCreatePanel(groupId: String, displayName: String, claudeSessionId: String? = nil) -> TerminalPanel? {
        let folder = WeaBotConfig.shared.sessionFolder(for: groupId)
        let command = launchCommand(workingDirectory: folder, claudeSessionId: claudeSessionId)

        // Check for existing workspace
        if let existing = workspace(for: groupId) {
            if let existingPanel = existing.panels.values.compactMap({ $0 as? TerminalPanel }).first {
                // If Claude wasn't launched this session (e.g. workspace restored after restart),
                // relaunch with --resume using the saved session ID.
                if !launchedPanelIds.contains(existingPanel.id) {
                    let resumeId = claudeSessionId ?? existing.claudeSessionId
                    let resumeCmd = launchCommand(workingDirectory: folder, claudeSessionId: resumeId)
                    logger.info("Resuming Claude in restored panel for \(groupId), sessionId=\(resumeId ?? "nil")")
                    launchedPanelIds.insert(existingPanel.id)
                    // Wait for the terminal surface to be live before sending the command.
                    // After app restart, restored workspaces need time to mount their views.
                    Task { [weak existingPanel, weak self] in
                        guard let existingPanel else { return }
                        for _ in 0..<50 { // up to ~5 seconds
                            if existingPanel.surface.hasLiveSurface { break }
                            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                        }
                        guard existingPanel.surface.hasLiveSurface else {
                            self?.logger.error("Restored WEA surface failed to initialize for \(groupId)")
                            return
                        }
                        existingPanel.sendInput(resumeCmd + "\n")
                    }
                }
                return existingPanel
            }
            // Workspace exists but terminal was closed. Recreate a new terminal panel.
            guard let paneId = existing.bonsplitController.focusedPaneId ?? existing.bonsplitController.allPaneIds.first,
                  let newPanel = existing.newTerminalSurface(inPane: paneId, focus: false, workingDirectory: folder) else {
                return nil
            }
            newPanel.sendInput(command + "\n")
            launchedPanelIds.insert(newPanel.id)
            logger.info("Recreated WEA terminal panel for \(groupId) in existing workspace \(existing.id.uuidString)")
            return newPanel
        }

        // Create workspace in the background (not selected) with eager terminal loading.
        // This primes the terminal surface via the background workspace load mechanism
        // (mounted at opacity ~0) without stealing user focus.
        guard let tabManager else { return nil }
        let workspace = tabManager.addWorkspace(
            title: displayName,
            workingDirectory: folder,
            select: false,
            eagerLoadTerminal: true
        )
        workspace.weaGroupId = groupId
        logger.info("Created WEA workspace '\(displayName)' for \(groupId) at \(folder)")
        logger.info("WEA launch command for \(groupId): \(command)")

        guard let panel = workspace.panels.values.compactMap({ $0 as? TerminalPanel }).first else {
            return nil
        }
        // Wait for the terminal surface to be live before sending the launch command.
        // The background load mechanism needs a few runloop ticks to mount the view
        // and create the ghostty surface.
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
            self?.launchedPanelIds.insert(panel.id)
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
