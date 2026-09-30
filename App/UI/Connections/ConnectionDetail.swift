import DeskMateCore
import SwiftUI

/// What the selected connection can do: its actions, anything that needs attention, and its tools.
struct ConnectionDetail: View {
    let manager: ConnectionManager
    let connection: MCPConnection
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let status = manager.status(of: connection.id)
        let host = connection.endpoint.displayHost

        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(verbatim: connection.name)
                    .font(.dmSection)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if case .connected(let negotiation) = status {
                    Text(verbatim: connectedLine(negotiation))
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                }
            }

            actions(status: status, host: host)

            if !connection.isEnabled {
                DMNotice(
                    symbol: "power",
                    tint: .secondary,
                    title: "This connection is turned off",
                    message: "DeskMate will not contact \(host) until you turn it on."
                ) {
                    Button("Enable") { setEnabled(true) }
                        .buttonStyle(.bordered)
                }
            }

            if case .failed(let failure) = status {
                failureNotice(failure)
            }

            changeNotice

            toolsArea(status: status)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details for \(connection.name)")
        .onChange(of: status) { _, new in
            switch new {
            case .connected:
                Announcer.post("Connected to \(connection.name). \(manager.tools(of: connection.id).count) tools found.")
            case .failed(let failure):
                Announcer.post("Could not connect to \(connection.name). \(failure.summary)")
            default:
                break
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(status: ConnectionStatus, host: String) -> some View {
        HStack(spacing: DS.Spacing.s) {
            switch status {
            case .connecting:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Contacting \(host)…")
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
                Button("Stop") { disconnect() }
                    .buttonStyle(.bordered)
                    .help("Stops the request and leaves the connection closed")
            case .connected:
                Button("Test connection") { test() }
                    .buttonStyle(.bordered)
                    .help(testHelp(host: host))
                Button("Disconnect") { disconnect() }
                    .buttonStyle(.bordered)
                    .help("Stops any request in progress and closes the connection. Your tool choices are kept.")
            case .disconnected, .failed:
                Button("Test connection") { test() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connection.isEnabled)
                    .help(connection.isEnabled ? testHelp(host: host) : "Enable the connection first")
            }

            Button(connection.isEnabled ? "Disable" : "Enable") { setEnabled(!connection.isEnabled) }
                .buttonStyle(.bordered)
                .help(
                    connection.isEnabled
                        ? "Disconnects and stops DeskMate from contacting this service until you enable it again"
                        : "Allow DeskMate to contact this service again"
                )

            Spacer(minLength: DS.Spacing.s)

            Button("Edit…", action: onEdit)
                .buttonStyle(.bordered)
                .help("Change the name, address or token")
            Button("Delete…", role: .destructive, action: onDelete)
                .buttonStyle(.bordered)
                .help("Remove this connection and its saved token")
        }
        .controlSize(.regular)
    }

    private func testHelp(host: String) -> String {
        "Contacts \(host): sends the start-up handshake and asks for its list of tools. Nothing from your files or chats is sent."
    }

    private func test() {
        Task { await manager.connect(connection.id) }
    }

    private func disconnect() {
        Task { await manager.disconnect(connection.id) }
    }

    private func setEnabled(_ value: Bool) {
        Task { await manager.setConnectionEnabled(connection.id, value) }
    }

    // MARK: Notices

    private func failureNotice(_ failure: ConnectionFailure) -> some View {
        DMNotice(
            symbol: "exclamationmark.triangle",
            tint: .dmWarning,
            title: failure.summary,
            message: failure.recovery.isEmpty ? nil : failure.recovery
        ) {
            if failure.needsEditedCredentials {
                Button("Edit connection…", action: onEdit)
                    .buttonStyle(.bordered)
            }
            if connection.isEnabled {
                Button("Try again") { test() }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder private var changeNotice: some View {
        if let notices = manager.notices[connection.id], !notices.isEmpty {
            DMNotice(
                symbol: "exclamationmark.circle",
                tint: .dmWarning,
                title: notices.count == 1 ? notices[0] : "\(notices.count) tools were turned off",
                message: notices.count > 1 ? notices.joined(separator: "\n") : nil
            )
        }
    }

    // MARK: Tools

    @ViewBuilder
    private func toolsArea(status: ConnectionStatus) -> some View {
        switch status {
        case .connected:
            ToolsSection(manager: manager, connection: connection)
        case .connecting:
            EmptyView()
        case .disconnected, .failed:
            if connection.isEnabled {
                let earlier = manager.enabledToolCount(of: connection.id)
                Text(
                    earlier > 0
                        ? "\(earlier) \(earlier == 1 ? "tool was" : "tools were") turned on earlier. Test the connection to review \(earlier == 1 ? "it" : "them")."
                        : "Test the connection to see which tools this service offers."
                )
                .font(.dmBody)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func connectedLine(_ negotiation: ConnectionNegotiation) -> String {
        let count = manager.tools(of: connection.id).count
        var line = "Connected to \(negotiation.serverName)"
        if !negotiation.serverVersion.isEmpty { line += " \(negotiation.serverVersion)" }
        line += ". Agreed on MCP version \(negotiation.protocolVersion). "
        line += negotiation.offersTools ? "\(count) \(count == 1 ? "tool" : "tools") offered." : "It does not offer tools."
        return line
    }
}

extension ConnectionFailure {
    /// The fix is in the connection's own settings (token or address), not another try.
    var needsEditedCredentials: Bool {
        switch kind {
        case .unauthorized, .forbidden, .missingToken, .notFound: true
        default: false
        }
    }
}
