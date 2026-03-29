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

            GroupBox {
                VStack(spacing: 0) {
                    fieldRow(
                        label: String(localized: "weaBot.config.appId", defaultValue: "App ID")
                    ) {
                        TextField("", text: $config.appId)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }

                    Divider()

                    fieldRow(
                        label: String(localized: "weaBot.config.appSecret", defaultValue: "App Secret")
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

                    Divider()

                    fieldRow(
                        label: String(localized: "weaBot.config.botId", defaultValue: "Bot ID")
                    ) {
                        TextField("", text: $config.botId)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }

                    Divider()

                    fieldRow(
                        label: String(localized: "weaBot.config.autoConnect", defaultValue: "Auto-connect on Launch")
                    ) {
                        Toggle("", isOn: $config.autoConnect)
                            .labelsHidden()
                    }
                }
            }

            // Group Blacklist
            if !config.knownGroups.isEmpty {
                Text(String(localized: "weaBot.config.blacklist", defaultValue: "Group Blacklist"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                GroupBox {
                    VStack(spacing: 0) {
                        let sorted = config.knownGroups.sorted(by: { $0.value < $1.value })
                        ForEach(Array(sorted.enumerated()), id: \.element.key) { index, item in
                            HStack {
                                Text(item.value)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { config.isBlacklisted(item.key) },
                                    set: { blocked in
                                        if blocked {
                                            config.addToBlacklist(item.key)
                                        } else {
                                            config.removeFromBlacklist(item.key)
                                        }
                                    }
                                ))
                                .labelsHidden()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)

                            if index < sorted.count - 1 {
                                Divider()
                            }
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
            if config.loadSecret() != nil {
                appSecret = "••••••••"
            }
        }
    }

    private func fieldRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .frame(width: 140, alignment: .trailing)
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
