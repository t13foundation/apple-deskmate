import DeskMateCore
import SwiftUI

/// The tools a connected service offers, with a checkbox for each one DeskMate can check.
struct ToolsSection: View {
    let manager: ConnectionManager
    let connection: MCPConnection

    @State private var message: String?

    var body: some View {
        let tools = manager.tools(of: connection.id)
        let enabledCount = manager.enabledToolCount(of: connection.id)
        let limit = manager.maxEnabledTools
        let atLimit = enabledCount >= limit

        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tools")
                    .font(.dmSection)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Text("\(enabledCount) of \(limit) turned on")
                    .font(.dmCaption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(enabledCount) of \(limit) tools turned on")
            }

            Text("Choose the tools the assistant may use, up to \(limit). Names and descriptions come from the service and DeskMate cannot verify them. Tools you leave off are never used.")
                .font(.dmCaption)
                .foregroundStyle(.secondary)

            if atLimit {
                NoteRow(
                    symbol: "info.circle",
                    text: "You have turned on the most tools allowed (\(limit)). Turn one off to choose another.",
                    tint: Color.dmAccent
                )
            }
            if let message {
                NoteRow(symbol: "exclamationmark.circle", text: message, tint: .orange)
            }

            if tools.isEmpty {
                Text("This service does not offer any tools.")
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
            }

            ForEach(tools) { tool in
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

struct ToolRow: View {
    let tool: ConnectionTool
    let isOn: Bool
    let atLimit: Bool
    let limit: Int
    let setOn: (Bool) -> Void

    @State private var showInputs = false

    private var canToggle: Bool {
        isOn || (tool.isEnableable && !atLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Toggle(
                isOn: Binding(get: { isOn }, set: { setOn($0) })
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: tool.displayName)
                        .font(.dmBody.weight(.medium))
                    if tool.displayName != tool.name {
                        Text(verbatim: tool.name)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!canToggle)
            .help(helpText)
            .accessibilityLabel("Turn on \(tool.displayName)")
            .accessibilityHint(accessibilityHint)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                if !tool.descriptionText.isEmpty {
                    Text(verbatim: tool.descriptionText)
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }

                switch tool.serverClaimsReadOnly {
                case true?:
                    NoteRow(symbol: "eye", text: "The service says this tool only reads data. DeskMate cannot check that.")
                case false?:
                    NoteRow(symbol: "pencil", text: "The service says this tool can change data.")
                case nil:
                    EmptyView()
                }

                switch tool.support {
                case .supported(let schema):
                    DisclosureGroup(isExpanded: $showInputs) {
                        inputs(schema)
                    } label: {
                        Text(schema.properties.isEmpty ? "Takes no inputs" : "Inputs (\(schema.properties.count))")
                            .font(.dmCaption)
                    }
                    .font(.dmCaption)
                case .unsupported(let reasons):
                    unsupported(reasons)
                }
            }
            .padding(.leading, 22)
        }
        .padding(.vertical, DS.Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    private func inputs(_ schema: ToolInputSchema) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ForEach(schema.properties) { property in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(verbatim: property.name)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        Text(verbatim: property.kindLabel + (property.isRequired ? ", required" : ", optional"))
                            .font(.dmCaption)
                            .foregroundStyle(.secondary)
                    }
                    if !property.description.isEmpty {
                        Text(verbatim: property.description)
                            .font(.dmCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, DS.Spacing.xs)
    }

    private func unsupported(_ reasons: [String]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            NoteRow(
                symbol: "exclamationmark.triangle",
                text: "Cannot be turned on: DeskMate cannot check this tool’s inputs before sending them.",
                tint: .orange
            )
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                Text(verbatim: "• " + reason)
                    .font(.dmCaption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var helpText: String {
        if !tool.isEnableable { return "This tool’s inputs use a format DeskMate cannot check." }
        if !isOn && atLimit { return "You can turn on up to \(limit) tools. Turn one off first." }
        return isOn ? "Turn this tool off" : "Turn this tool on"
    }

    private var accessibilityHint: String {
        if !tool.isEnableable { return "Unavailable. DeskMate cannot check this tool’s inputs." }
        if !isOn && atLimit { return "Unavailable. The limit of \(limit) tools is reached." }
        return ""
    }
}
