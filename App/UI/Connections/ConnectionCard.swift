import DeskMateCore
import SwiftUI

/// How a connection's state reads to a person: one badge word and its tint.
struct ConnectionStatusPresentation {
    let badge: String
    let tint: Color

    init(status: ConnectionStatus, isTurnedOff: Bool) {
        if isTurnedOff {
            badge = "Turned off"
            tint = .secondary
            return
        }
        switch status {
        case .disconnected:
            badge = "Not connected"
            tint = .secondary
        case .connecting:
            badge = "Connecting"
            tint = .dmAccent
        case .connected:
            badge = "Connected"
            tint = .dmAccent
        case .failed:
            badge = "Needs attention"
            tint = .dmWarning
        }
    }
}

extension MCPConnection {
    /// Never the token itself, only whether one is kept.
    var authSummary: String { auth == .bearer ? "Token saved" : "No token" }
}

/// One line in the list of connections: name, status, address, sign-in, and where data goes.
/// The whole row selects the connection; its tools and actions appear below the list.
struct ConnectionRow: View {
    let connection: MCPConnection
    let status: ConnectionStatus
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        let presentation = ConnectionStatusPresentation(status: status, isTurnedOff: !connection.isEnabled)
        let host = connection.endpoint.displayHost

        Button(action: onSelect) {
            HStack(alignment: .top, spacing: DS.Spacing.m) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.dmBody)
                    .foregroundStyle(Color.dmAccent)
                    .frame(width: DS.Layout.iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(verbatim: connection.name)
                        .font(.dmBody.weight(.medium))
                        .lineLimit(1)
                    Text(verbatim: "\(connection.endpoint.url.absoluteString) · \(connection.authSummary)")
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: sendsLine(host: host))
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: DS.Spacing.s)
                if status.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                DMBadge(text: presentation.badge, tint: presentation.tint)
            }
            .padding(DS.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.dmAccent.opacity(DS.Fill.tint) : Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel(presentation: presentation, host: host))
        .accessibilityHint("Shows its tools and actions")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sendsLine(host: String) -> String {
        var text = "This connection sends data to \(host)."
        if connection.endpoint.isLoopbackDevelopment {
            text += " Local development server on this Mac."
        }
        return text
    }

    private func spokenLabel(presentation: ConnectionStatusPresentation, host: String) -> String {
        "\(connection.name), \(presentation.badge). \(sendsLine(host: host)) \(connection.authSummary)."
    }
}
