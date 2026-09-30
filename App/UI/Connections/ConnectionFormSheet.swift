import DeskMateCore
import SwiftUI

/// Add or edit a connection. Adding only saves; the address is contacted when the person presses Test connection
/// here or Connect on the card.
struct ConnectionFormSheet: View {
    let manager: ConnectionManager
    let mode: ConnectionEditorMode

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var token = ""
    @State private var removeToken = false
    @State private var loaded = false
    @State private var problem: String?
    @State private var test: TestState = .idle
    @State private var testTask: Task<Void, Never>?
    @State private var saving = false

    private enum TestState {
        case idle
        case running
        case succeeded(ConnectionProbeReport)
        case failed(ConnectionFailure)
    }

    private var existing: MCPConnection? {
        if case .edit(let id) = mode { return manager.connection(id) }
        return nil
    }

    private var isEditing: Bool { existing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditing ? "Edit Connection" : "Add Connection")
                .font(.dmTitle)
                .accessibilityAddTraits(.isHeader)
                .padding([.top, .horizontal], DS.Spacing.panel)

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Team project notes"))
                    TextField("Address", text: $address, prompt: Text("https://example.com/mcp"))
                        .autocorrectionDisabled()
                        .help("The address of a Streamable HTTP MCP service. https:// is required, except http://localhost for development.")
                    SecureField("Bearer token (optional)", text: $token, prompt: Text(tokenPrompt))
                        .help("Kept in your Keychain. It is never shown again or written to DeskMate’s files.")
                    if isEditing, existing?.auth == .bearer {
                        Toggle("Remove the saved token", isOn: $removeToken)
                            .disabled(!token.isEmpty)
                    }
                } footer: {
                    addressFooter
                }

                if isEditing, changesReset {
                    Section {
                        NoteRow(
                            symbol: "info.circle",
                            text: "Changing the address or token disconnects this connection and turns off its tools. Turn them on again after reconnecting.",
                            tint: Color.dmAccent
                        )
                    }
                }

                if !isEditing {
                    Section("Try it first") {
                        testSection
                    }
                }

                if let problem {
                    Section {
                        NoteRow(symbol: "exclamationmark.triangle", text: problem, tint: .orange)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    testTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save Changes" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], DS.Spacing.panel)
        }
        .frame(width: 520)
        .onAppear(perform: load)
        .onDisappear { testTask?.cancel() }
    }

    private var tokenPrompt: String {
        if isEditing, existing?.auth == .bearer { return "Leave empty to keep the saved token" }
        return "Only if the service asks for one"
    }

    private var changesReset: Bool {
        guard let existing else { return false }
        let addressChanged: Bool
        switch ConnectionEndpoint.validate(address) {
        case .success(let endpoint): addressChanged = endpoint != existing.endpoint
        case .failure: addressChanged = false
        }
        return addressChanged || !token.isEmpty || removeToken
    }

    // MARK: Address hints

    @ViewBuilder
    private var addressFooter: some View {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if trimmed.isEmpty {
                Text("Enter the address of a service that uses Streamable HTTP. Saving does not contact it.")
            } else {
                switch ConnectionEndpoint.validate(trimmed) {
                case .failure(let problem):
                    NoteRow(symbol: "exclamationmark.triangle", text: problem.message, tint: .orange)
                case .success(let endpoint):
                    if endpoint.isLoopbackDevelopment {
                        NoteRow(
                            symbol: "hammer",
                            text: "Local development connection: plain http to this Mac only. Nothing leaves your computer."
                        )
                    } else {
                        NoteRow(symbol: "arrow.up.forward.app", text: "This connection sends data to \(endpoint.displayHost).")
                    }
                }
            }
        }
        .font(.dmCaption)
        .foregroundStyle(.secondary)
    }

    // MARK: Test

    @ViewBuilder
    private var testSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                Button("Test Connection") { runTest() }
                    .disabled(!canTest)
                if case .running = test {
                    ProgressView().controlSize(.small)
                    Text("Contacting the service…").font(.dmCaption).foregroundStyle(.secondary)
                    Button("Stop") {
                        testTask?.cancel()
                        test = .idle
                    }
                }
            }
            Text("Sends only the start-up handshake and a request for the list of tools. Nothing is saved and none of your files or chats are sent.")
                .font(.dmCaption)
                .foregroundStyle(.secondary)

            switch test {
            case .idle, .running:
                EmptyView()
            case .succeeded(let report):
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.dmAccent)
                        .font(.dmBody.weight(.medium))
                    Text(verbatim: "\(report.negotiation.serverName) agreed on protocol version \(report.negotiation.protocolVersion) and offers \(report.listing.tools.count) \(report.listing.tools.count == 1 ? "tool" : "tools"):")
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                    ForEach(report.listing.tools.prefix(8)) { tool in
                        Text(verbatim: "• " + tool.displayName + (tool.isEnableable ? "" : " (cannot be turned on)"))
                            .font(.dmCaption)
                            .foregroundStyle(.secondary)
                    }
                    if report.listing.tools.count > 8 {
                        Text("and \(report.listing.tools.count - 8) more").font(.dmCaption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            case .failed(let failure):
                FailureNote(failure: failure)
            }
        }
    }

    private var canTest: Bool {
        if case .running = test { return false }
        if case .failure = ConnectionEndpoint.validate(address) { return false }
        return !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func runTest() {
        test = .running
        let address = address
        let token = token.isEmpty ? nil : token
        testTask = Task {
            let result = await manager.probe(address: address, token: token)
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let report):
                test = .succeeded(report)
                Announcer.post("Connected. \(report.listing.tools.count) tools found.")
            case .failure(let failure):
                test = .failed(failure)
                Announcer.post("Test failed. \(failure.summary)")
            }
        }
    }

    // MARK: Save

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let existing {
            name = existing.name
            address = existing.endpoint.url.absoluteString
        }
    }

    private func save() {
        problem = nil
        saving = true
        testTask?.cancel()
        switch mode {
        case .add:
            switch manager.addConnection(name: name, address: address, token: token) {
            case .success:
                dismiss()
            case .failure(let failure):
                problem = failure.message
                saving = false
            }
        case .edit(let id):
            let change: TokenChange = removeToken ? .remove : (token.isEmpty ? .keep : .replace(token))
            Task {
                switch await manager.updateConnection(id, name: name, address: address, token: change) {
                case .success:
                    dismiss()
                case .failure(let failure):
                    problem = failure.message
                    saving = false
                }
            }
        }
    }
}
