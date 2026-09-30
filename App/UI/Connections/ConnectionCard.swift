import DeskMateCore
import SwiftUI

/// One connection: what it is, where data goes, its state, and the actions for it.
struct ConnectionCard: View {
    let manager: ConnectionManager
    let connection: MCPConnection
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let status = manager.status(of: connection.id)
        let host = connection.endpoint.displayHost

        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .center, spacing: DS.Spacing.m) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.dmAccent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: connection.name)
                        .font(.dmSection)
                        .lineLimit(1)
                    Text(verbatim: connection.endpoint.url.absoluteString)
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                StatusBadge(status: status, isTurnedOff: !connection.isEnabled)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                NoteRow(symbol: "arrow.up.forward.app", text: "This connection sends data to \(host).")
                if connection.endpoint.isLoopbackDevelopment {
                    NoteRow(
                        symbol: "hammer",
                        text: "Local development connection: plain http to this Mac only. Nothing leaves your computer."
                    )
                }
                NoteRow(
                    symbol: connection.auth == .bearer ? "key" : "lock.open",
                    text: connection.auth == .bearer
                        ? "Signs in with a Bearer token kept in your Keychain."
                        : "No sign-in is used."
                )
            }

            if case .failed(let failure) = status {
                FailureNote(failure: failure)
            }
            if let notices = manager.notices[connection.id], !notices.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                        NoteRow(symbol: "info.circle", text: notice, tint: Color.dmAccent)
                    }
                }
            }

            controls(status: status)

            if status.isConnected {
                Divider()
                ToolsSection(manager: manager, connection: connection)
            }
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dmSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connection \(connection.name), \(status.spokenDescription(isTurnedOff: !connection.isEnabled))")
        .onChange(of: status) { _, new in
            switch new {
            case .connected:
                Announcer.post("Connected to \(connection.name). \(manager.tools(of: connection.id).count) tools available.")
            case .failed(let failure):
                Announcer.post("Could not connect to \(connection.name). \(failure.summary)")
            default:
                break
            }
        }
    }

    @ViewBuilder
    private func controls(status: ConnectionStatus) -> some View {
        HStack(spacing: DS.Spacing.s) {
            switch status {
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…").font(.dmBody).foregroundStyle(.secondary)
                Button("Stop") { Task { await manager.disconnect(connection.id) } }
                    .buttonStyle(.bordered)
            case .connected:
                Button("Disconnect") { Task { await manager.disconnect(connection.id) } }
                    .buttonStyle(.bordered)
                    .help("Stops any request in progress and closes the connection")
                Button("Refresh Tools") { Task { await manager.connect(connection.id) } }
                    .buttonStyle(.bordered)
            case .disconnected, .failed:
                Button(status == .disconnected ? "Connect" : "Try Again") {
                    Task { await manager.connect(connection.id) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!connection.isEnabled)
                .help(connection.isEnabled ? "Contacts the service and lists its tools" : "Turn the connection on first")
            }

            Spacer(minLength: 0)

            Toggle(
                "On",
                isOn: Binding(
                    get: { connection.isEnabled },
                    set: { value in Task { await manager.setConnectionEnabled(connection.id, value) } }
                )
            )
            .toggleStyle(.switch)
            .help(connection.isEnabled ? "Turn this connection off. DeskMate will not contact it." : "Turn this connection on")
            .accessibilityLabel("Connection \(connection.name) is on")

            Button("Edit…", action: onEdit)
                .buttonStyle(.bordered)
            Button("Delete…", role: .destructive, action: onDelete)
                .buttonStyle(.bordered)
        }
        .controlSize(.regular)
    }
}

extension ConnectionStatus {
    func spokenDescription(isTurnedOff: Bool) -> String {
        if isTurnedOff { return "turned off" }
        switch self {
        case .disconnected: return "not connected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed: return "problem"
        }
    }
}

struct StatusBadge: View {
    let status: ConnectionStatus
    let isTurnedOff: Bool

    var body: some View {
        let style = appearance
        Label {
            Text(style.title)
                .font(.dmCaption.weight(.medium))
        } icon: {
            Image(systemName: style.symbol)
        }
        .foregroundStyle(style.tint)
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, DS.Spacing.xs)
        .background(Capsule().fill(style.tint.opacity(0.12)))
        .accessibilityHidden(true)
    }

    private var appearance: (title: String, symbol: String, tint: Color) {
        if isTurnedOff { return ("Turned off", "power", .secondary) }
        switch status {
        case .disconnected: return ("Not connected", "circle", .secondary)
        case .connecting: return ("Connecting", "arrow.triangle.2.circlepath", Color.dmAccent)
        case .connected: return ("Connected", "checkmark.circle.fill", Color.dmAccent)
        case .failed: return ("Problem", "exclamationmark.triangle.fill", .orange)
        }
    }
}

struct FailureNote: View {
    let failure: ConnectionFailure

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(verbatim: failure.summary)
                    .font(.dmBody)
                if !failure.recovery.isEmpty {
                    Text(verbatim: failure.recovery)
                        .font(.dmBody)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Spacing.m)
        .dmSurface(radius: DS.Radius.control, emphasis: .orange)
        .accessibilityElement(children: .combine)
    }
}
