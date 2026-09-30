import DeskMateCore
import SwiftUI

extension ToolInputSchema {
    /// One line naming every input and its type, for example "project (text, required), detail (one of: brief, full)".
    var summaryText: String {
        guard !properties.isEmpty else { return "Takes no inputs." }
        let parts = properties.map { property in
            "\(property.name) (\(property.kindLabel)\(property.isRequired ? ", required" : ""))"
        }
        return "Inputs: " + parts.joined(separator: ", ") + "."
    }
}

/// The tools a connected service offers, with a switch for each one DeskMate can check.
/// Everything the service wrote (names, descriptions, input notes) is untrusted: it is shown as plain text only.
struct ToolsSection: View {
    let manager: ConnectionManager
    let connection: MCPConnection

    @State private var message: String?

    var body: some View {
        let tools = manager.tools(of: connection.id)
        let totalCount = manager.totalEnabledToolCount
        let hereCount = manager.enabledToolCount(of: connection.id)
        let limit = manager.maxEnabledTools
        let atLimit = totalCount >= limit

        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Text("Tools")
                    .font(.dmSection)
                    .accessibilityAddTraits(.isHeader)
                DMBadge(text: "\(totalCount) of \(limit) tools on across all connections", tint: atLimit ? .dmWarning : .dmAccent)
                    .accessibilityLabel("\(totalCount) of \(limit) tools turned on across all connections, \(hereCount) in \(connection.name)")
                Spacer(minLength: 0)
            }

            Text("Turn on the tools the assistant may use. You can have up to \(limit) on in total across all connections, which keeps the assistant focused. Names and descriptions come from the service and DeskMate cannot verify them. Tools you leave off are never used.")
                .font(.dmCaption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if atLimit {
                DMNotice(
                    symbol: "info.circle",
                    tint: .dmAccent,
                    title: "\(limit) tools are turned on across all connections, the most allowed",
                    message: hereCount == totalCount
                        ? "Turn one off to choose another."
                        : "Turn one off, here or in another connection, to choose another."
                )
            }
            if let message {
                DMNotice(
                    symbol: "exclamationmark.circle",
                    tint: .dmWarning,
                    title: message,
                    onDismiss: { self.message = nil }
                )
            }

            if tools.isEmpty {
                Text("This service does not offer any tools.")
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 { Divider() }
                        ToolRow(
                            tool: tool,
                            isOn: manager.isToolEnabled(tool.name, in: connection.id),
                            atLimit: atLimit,
                            limit: limit,
                            setOn: { value in
                                let outcome = manager.setTool(tool.name, enabled: value, in: connection.id)
                                message = outcome.message
                                if outcome == .changed {
                                    Announcer.post(value ? "Turned on \(tool.displayName)." : "Turned off \(tool.displayName).")
                                }
                            }
                        )
                    }
                }
                .dmSurface(radius: DS.Radius.control)
            }

            if let omitted = manager.catalogs[connection.id]?.omittedCount, omitted > 0 {
                Text("\(omitted) more tools were not shown.")
                    .font(.dmCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools for \(connection.name)")
    }
}

/// One tool: switch, name, what the service says about it, and what it takes as input.
struct ToolRow: View {
    let tool: ConnectionTool
    let isOn: Bool
    let atLimit: Bool
    let limit: Int
    let setOn: (Bool) -> Void

    @State private var showsInputDetails = false

    private var canToggle: Bool {
        isOn || (tool.isEnableable && !atLimit)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(verbatim: tool.displayName)
                    .font(.dmBody.weight(.medium))
                if tool.displayName != tool.name {
                    Text(verbatim: tool.name)
                        .font(.dmCaption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !tool.descriptionText.isEmpty {
                    Text(verbatim: tool.descriptionText)
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                claim
                switch tool.support {
                case .supported(let schema):
                    supported(schema)
                case .unsupported(let reasons):
                    unsupported(reasons)
                }
                if !isOn, tool.isEnableable, atLimit {
                    Label("Turn another tool off to turn this one on.", systemImage: "info.circle")
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: DS.Spacing.s)
            Toggle(isOn: Binding(get: { isOn }, set: { setOn($0) })) {
                Text(verbatim: "Turn on \(tool.displayName)")
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!canToggle)
            .help(helpText)
            .accessibilityHint(accessibilityHint)
        }
        .padding(DS.Spacing.m)
        .accessibilityElement(children: .contain)
    }

    /// What the service says about changing data. A claim, never a guarantee: DeskMate's own rules do not depend on it.
    @ViewBuilder private var claim: some View {
        switch tool.serverClaimsReadOnly {
        case true?:
            Label("The service says this tool only reads data. DeskMate cannot check that.", systemImage: "eye")
                .font(.dmCaption)
                .foregroundStyle(.secondary)
        case false?:
            Label("The service says this tool can change data.", systemImage: "pencil")
                .font(.dmCaption)
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func supported(_ schema: ToolInputSchema) -> some View {
        Text(verbatim: schema.summaryText)
            .font(.dmCaption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        if schema.properties.contains(where: { !$0.description.isEmpty }) {
            DisclosureGroup(isExpanded: $showsInputDetails) {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    ForEach(schema.properties) { property in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: property.name + ", " + property.kindLabel + (property.isRequired ? ", required" : ", optional"))
                                .font(.dmCaption.weight(.medium))
                            if !property.description.isEmpty {
                                Text(verbatim: property.description)
                                    .font(.dmCaption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, DS.Spacing.xs)
            } label: {
                Text("Input details")
                    .font(.dmCaption)
            }
        }
    }

    private func unsupported(_ reasons: [String]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label("Cannot be turned on. DeskMate cannot check this tool’s inputs before sending them.", systemImage: "exclamationmark.triangle")
                .font(.dmCaption.weight(.medium))
                .foregroundStyle(Color.dmWarning)
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                Text(verbatim: "• " + reason)
                    .font(.dmCaption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var helpText: String {
        if !tool.isEnableable { return "This tool’s inputs use a format DeskMate cannot check." }
        if !isOn && atLimit { return "You can turn on up to \(limit) tools in total across all connections. Turn one off first." }
        return isOn ? "Turn this tool off" : "Turn this tool on"
    }

    private var accessibilityHint: String {
        if !tool.isEnableable { return "Unavailable. DeskMate cannot check this tool’s inputs." }
        if !isOn && atLimit { return "Unavailable. The limit of \(limit) tools across all connections is reached." }
        return ""
    }
}
