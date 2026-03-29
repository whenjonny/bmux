// Sources/Wea/WeaWorkspaceManager.swift
import Foundation
import os

/// Manages the main-wea workspace and its tabs.
/// Creates workspace on connect, destroys on disconnect, spawns group chat tabs.
@MainActor
final class WeaWorkspaceManager {
    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "WeaWorkspaceManager")
    private weak var tabManager: TabManager?
    private var weaWorkspace: Workspace?
    private var groupPanels: [String: UUID] = [:]  // groupId → panelId

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        setupCallbacks()
    }

    private func setupCallbacks() {
        let service = WeaBotService.shared
        service.tabManager = tabManager

        service.onGetMainPanel = { [weak self] in
            self?.getMainPanel()
        }

        service.onCreateGroupTab = { [weak self] groupId, groupName in
            self?.createGroupTab(groupId: groupId, groupName: groupName)
        }
    }

    // MARK: - Workspace Lifecycle

    func createWeaWorkspace() {
        guard let tabManager else { return }
        let workspace = tabManager.addWorkspace(
            title: "main-wea",
            initialTerminalCommand: "codemax claude --dangerously-skip-permissions",
            select: true
        )
        weaWorkspace = workspace
        logger.info("Created main-wea workspace: \(workspace.id)")
    }

    func destroyWeaWorkspace() {
        guard let workspace = weaWorkspace, let tabManager else { return }
        tabManager.closeWorkspaceWithConfirmation(workspace)
        weaWorkspace = nil
        groupPanels.removeAll()
        logger.info("Destroyed main-wea workspace")
    }

    // MARK: - Panel Access

    private func getMainPanel() -> TerminalPanel? {
        guard let workspace = weaWorkspace else { return nil }
        // The first terminal panel in the workspace is the "main" DM tab
        return workspace.panels.values.compactMap { $0 as? TerminalPanel }.first
    }

    private func createGroupTab(groupId: String, groupName: String) -> TerminalPanel? {
        guard let workspace = weaWorkspace else { return nil }

        // Check if we already have a panel for this group
        if let existingPanelId = groupPanels[groupId],
           let existing = workspace.panels[existingPanelId] as? TerminalPanel {
            return existing
        }

        // Create a new terminal in the focused pane (adds as a tab)
        guard let paneId = workspace.bonsplitController.focusedPaneId else { return nil }
        guard let newPanel = workspace.newTerminalSurface(
            inPane: paneId,
            focus: false
        ) else { return nil }

        groupPanels[groupId] = newPanel.id
        logger.info("Created group tab '\(groupName)' for \(groupId)")
        return newPanel
    }

    // MARK: - Queries

    var hasWeaWorkspace: Bool { weaWorkspace != nil }

    /// Check if a workspace is the WEA workspace
    func isWeaWorkspace(_ workspace: Workspace) -> Bool {
        workspace.id == weaWorkspace?.id
    }

    /// Get the group ID for a panel, if it's a WEA group tab
    func groupIdForPanel(_ panelId: UUID) -> String? {
        groupPanels.first { $0.value == panelId }?.key
    }
}
