// Sources/Wea/WeaWorkspaceManager.swift
import Foundation
import os

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

    /// Whether a specific terminal panel is still alive in the session workspace.
    func hasLiveTerminalPanel(groupId: String, panelId: UUID) -> Bool {
        guard let workspace = workspace(for: groupId),
              let panel = workspace.panels[panelId] as? TerminalPanel else {
            return false
        }
        return panel.workspaceId == workspace.id
    }

    /// Build the WEA Claude launch plan:
    /// 1) Prefer codemax claude for user intent.
    /// 2) If startup hook is missing, retry with plain claude wrapper so hooks are guaranteed.
    private func resolveClaudeLaunchPlan(workingDirectory: String) -> (initialCommand: String, retryCommands: [String]) {
        let directScript = "exec claude --allow-dangerously-skip-permissions --model=bedrock-claude-4-6-opus"

        let codemaxCandidates = [
            "\(NSHomeDirectory())/.local/bin/codemax",
            "/usr/local/bin/codemax"
        ]
        for path in codemaxCandidates where FileManager.default.isExecutableFile(atPath: path) {
            let codemax = shellSingleQuote(path)
            let codemaxScript = "exec \(codemax) claude --allow-dangerously-skip-permissions --model=bedrock-claude-4-6-opus"
            return (
                initialCommand: makeShellLaunchCommand(codemaxScript, workingDirectory: workingDirectory),
                retryCommands: [makeShellLaunchCommand(directScript, workingDirectory: workingDirectory)]
            )
        }

        // No codemax found: start and retry with plain claude wrapper command.
        let directCommand = makeShellLaunchCommand(directScript, workingDirectory: workingDirectory)
        return (initialCommand: directCommand, retryCommands: [])
    }

    private func makeShellLaunchCommand(_ launchScript: String, workingDirectory: String) -> String {
        var script = launchScript
        // Ensure cmux's bundled bin directory stays first on PATH so codemax
        // resolves `claude` to cmux's wrapper (which injects WEA hooks).
        if let cmuxBinDir = bundledCmuxBinDirectory() {
            let quotedDir = shellSingleQuote(cmuxBinDir)
            script = "export PATH=\(quotedDir):\"$PATH\"; " + script
        }
        let quotedCwd = shellSingleQuote(workingDirectory)
        script = "cd \(quotedCwd) || exit 1; " + script
        // Wrap in login shell so the full user environment is available.
        // Use exec so the shell process becomes the claude process (clean signal forwarding).
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return "\(userShell) -l -c \(shellSingleQuote(script))"
    }

    /// Retry commands for WEA startup fallback, in order.
    func claudeRetryCommands(for groupId: String) -> [String] {
        let folder = WeaBotConfig.shared.sessionFolder(for: groupId)
        return resolveClaudeLaunchPlan(workingDirectory: folder).retryCommands
    }

    /// Find or create a workspace for a group/DM session.
    /// Returns the terminal panel for message injection.
    func findOrCreatePanel(groupId: String, displayName: String) -> TerminalPanel? {
        let folder = WeaBotConfig.shared.sessionFolder(for: groupId)
        let launchPlan = resolveClaudeLaunchPlan(workingDirectory: folder)

        // Check for existing workspace
        if let existing = workspace(for: groupId) {
            if let existingPanel = existing.panels.values.compactMap({ $0 as? TerminalPanel }).first {
                return existingPanel
            }
            // Workspace exists but terminal was closed. Recreate a new terminal panel.
            guard let paneId = existing.bonsplitController.focusedPaneId ?? existing.bonsplitController.allPaneIds.first,
                  let newPanel = existing.newTerminalSurface(inPane: paneId, focus: false, workingDirectory: folder, initialCommand: launchPlan.initialCommand) else {
                return nil
            }
            logger.info("Recreated WEA terminal panel for \(groupId) in existing workspace \(existing.id.uuidString)")
            return newPanel
        }

        // Create workspace
        guard let tabManager else { return nil }
        let workspace = tabManager.addWorkspace(
            title: displayName,
            workingDirectory: folder,
            initialTerminalCommand: launchPlan.initialCommand,
            select: false,
            eagerLoadTerminal: true
        )
        workspace.weaGroupId = groupId
        logger.info("Created WEA workspace '\(displayName)' for \(groupId) at \(folder)")
        logger.info("WEA launch command for \(groupId): \(launchPlan.initialCommand)")

        return workspace.panels.values.compactMap({ $0 as? TerminalPanel }).first
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

    private func bundledCmuxBinDirectory() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let binDir = (resourcePath as NSString).appendingPathComponent("bin")
        let cmuxPath = (binDir as NSString).appendingPathComponent("cmux")
        guard FileManager.default.isExecutableFile(atPath: cmuxPath) else { return nil }
        return binDir
    }
}
