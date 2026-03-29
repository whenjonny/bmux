// Sources/Wea/WeaBotConfigSheet.swift
import SwiftUI

/// Configuration sheet for the WEA Bot connection settings.
struct WeaBotConfigSheet: View {
    @ObservedObject private var config = WeaBotConfig.shared
    @ObservedObject private var service = WeaBotService.shared
    @State private var appSecret: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(localized: "weaBot.config.title", defaultValue: "WEA Bot Configuration"))
                    .font(.headline)
                Spacer()
                statusBadge
            }

            SettingsCard {
                SettingsCardRow(
                    String(localized: "weaBot.config.appId", defaultValue: "App ID")
                ) {
                    TextField("", text: $config.appId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }

                SettingsCardDivider()

                SettingsCardRow(
                    String(localized: "weaBot.config.appSecret", defaultValue: "App Secret")
                ) {
                    SecureField("", text: $appSecret)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onChange(of: appSecret) { newValue in
                            if !newValue.isEmpty {
                                config.saveSecret(newValue)
                            }
                        }
                }

                SettingsCardDivider()

                SettingsCardRow(
                    String(localized: "weaBot.config.botId", defaultValue: "Bot ID")
                ) {
                    TextField("", text: $config.botId)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }

                SettingsCardDivider()

                SettingsCardRow(
                    String(localized: "weaBot.config.autoConnect", defaultValue: "Auto-connect on Launch")
                ) {
                    Toggle("", isOn: $config.autoConnect)
                        .labelsHidden()
                }
            }

            // Group Blacklist
            if !config.knownGroups.isEmpty {
                SettingsSectionHeader(
                    title: String(localized: "weaBot.config.blacklist", defaultValue: "Group Blacklist")
                )
                SettingsCard {
                    ForEach(Array(config.knownGroups.sorted(by: { $0.value < $1.value })), id: \.key) { groupId, groupName in
                        HStack {
                            Text(groupName)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { config.isBlacklisted(groupId) },
                                set: { blocked in
                                    if blocked {
                                        config.addToBlacklist(groupId)
                                    } else {
                                        config.removeFromBlacklist(groupId)
                                    }
                                }
                            ))
                            .labelsHidden()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)

                        if groupId != config.knownGroups.sorted(by: { $0.value < $1.value }).last?.key {
                            SettingsCardDivider()
                        }
                    }
                }
            }

            // Connect/Disconnect
            HStack {
                Spacer()
                Button(String(localized: "weaBot.config.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if service.isRunning {
                    Button(String(localized: "weaBot.config.disconnect", defaultValue: "Disconnect")) {
                        service.stop()
                    }
                } else {
                    Button(String(localized: "weaBot.config.connect", defaultValue: "Connect")) {
                        service.start()
                    }
                    .disabled(!config.isConfigured)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        .onAppear {
            // Load existing secret for display (masked)
            if config.loadSecret() != nil {
                appSecret = "••••••••"
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var statusColor: Color {
        switch service.state {
        case .running: return .green
        case .connecting, .reconnecting: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }

    private var statusText: String {
        switch service.state {
        case .running:
            return String(localized: "weaBot.status.connected", defaultValue: "Connected")
        case .connecting:
            return String(localized: "weaBot.status.connecting", defaultValue: "Connecting…")
        case .reconnecting:
            return String(localized: "weaBot.status.reconnecting", defaultValue: "Reconnecting…")
        case .error(let msg):
            return msg
        case .stopped:
            return String(localized: "weaBot.status.disconnected", defaultValue: "Disconnected")
        }
    }
}
