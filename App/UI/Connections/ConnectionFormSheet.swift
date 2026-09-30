import DeskMateCore
import SwiftUI

/// Add or edit a connection. Saving never contacts the address: that happens only when the person presses
/// Test connection here, or Test connection on the connection itself.
struct ConnectionFormSheet: View {
    let manager: ConnectionManager
    let mode: ConnectionEditorMode
    /// Called with the connection's id after a successful save, so the list can select it.
    let onSaved: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable {
        case name
        case address
        case token
    }

    private enum TestState {
        case idle
        case running
        case succeeded(ConnectionProbeReport)
        case failed(ConnectionFailure)
    }

    @FocusState private var focus: Field?
    @State private var name = ""
    @State private var address = ""
    @State private var token = ""
    @State private var removeToken = false
    @State private var loaded = false
    @State private var addressTouched = false
    @State private var submitted = false
    @State private var formProblem: ConnectionFormProblem?
    @State private var test: TestState = .idle
    @State private var testTask: Task<Void, Never>?
    @State private var saving = false

    private var existing: MCPConnection? {
        if case .edit(let id) = mode { return manager.connection(id) }
        return nil
    }

    private var isEditing: Bool { existing != nil }
    private var hasSavedToken: Bool { existing?.auth == .bearer }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(isEditing ? "Edit connection" : "Add connection")
                    .font(.dmTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("Enter the address of a service that uses Streamable HTTP. Saving does not contact it.")
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
            }
            .padding([.top, .horizontal], DS.Spacing.panel)

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Project notes"))
                        .focused($focus, equals: .name)
                    if let text = nameProblem {
                        FormNote(symbol: "exclamationmark.triangle", text: text, tint: .dmWarning)
                    }

                    TextField("Address", text: $address, prompt: Text("https://example.com/mcp"))
                        .focused($focus, equals: .address)
                        .autocorrectionDisabled()
                        .help("A Streamable HTTP MCP address. https:// is required, except for http://localhost or http://127.0.0.1 on this Mac.")
                    addressNote

                    SecureField("Bearer token", text: $token, prompt: Text(tokenPrompt))
                        .focused($focus, equals: .token)
                        .help("Kept in your Keychain. It is never shown again or written to DeskMate’s files.")
                    if let text = tokenProblem {
                        FormNote(symbol: "exclamationmark.triangle", text: text, tint: .dmWarning)
                    } else {
                        FormNote(symbol: "key", text: tokenHint, tint: .secondary)
                    }
                    if isEditing, hasSavedToken {
                        Toggle("Remove the saved token", isOn: $removeToken)
                            .disabled(!token.isEmpty)
                    }
                }

                if isEditing, changesReset {
                    Section {
                        DMNotice(
                            symbol: "info.circle",
                            tint: .dmAccent,
                            title: "This disconnects the connection and turns its tools off",
                            message: "Changing the address or token means the tools you approved no longer apply. Turn them on again after testing."
                        )
                    }
                }

                if !isEditing {
                    Section("Try it first") {
                        testSection
                    }
                }

                if let text = generalProblem {
                    Section {
                        DMNotice(symbol: "exclamationmark.triangle", tint: .dmWarning, title: text)
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
                Button(isEditing ? "Save changes" : "Add connection") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding([.horizontal, .bottom], DS.Spacing.panel)
        }
        .frame(width: DS.Layout.connectionSheetWidth)
        .onAppear(perform: load)
        .onDisappear { testTask?.cancel() }
        .onChange(of: focus) { old, _ in
            if old == .address { addressTouched = true }
        }
        .onChange(of: name) { _, _ in formProblem = nil }
        .onChange(of: address) { _, _ in
            formProblem = nil
            resetTest()
        }
        .onChange(of: token) { _, _ in
            formProblem = nil
            resetTest()
        }
    }

    private var canSave: Bool {
        !saving
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Validation messages

    private var nameProblem: String? {
        if formProblem == .nameMissing { return ConnectionFormProblem.nameMissing.message }
        if submitted, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ConnectionFormProblem.nameMissing.message }
        return nil
    }

    private var tokenProblem: String? {
        formProblem == .tokenInvalid ? ConnectionFormProblem.tokenInvalid.message : nil
    }

    /// Problems that belong to no single field (storage, too many connections).
    private var generalProblem: String? {
        switch formProblem {
        case .tooManyConnections, .storage: formProblem?.message
        default: nil
        }
    }

    private var tokenPrompt: String {
        hasSavedToken ? "Leave empty to keep the saved token" : "Optional"
    }

    private var tokenHint: String {
        hasSavedToken
            ? "A token is saved in your Keychain. Enter a new one to replace it."
            : "Only if the service asks for one. It is stored in your Keychain and never shown again."
    }

    @ViewBuilder private var addressNote: some View {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if submitted {
                FormNote(symbol: "exclamationmark.triangle", text: ConnectionEndpoint.Problem.empty.message, tint: .dmWarning)
            } else {
                FormNote(symbol: "link", text: "https:// is required. Plain http:// works only for localhost or 127.0.0.1 on this Mac.", tint: .secondary)
            }
        } else {
            switch ConnectionEndpoint.validate(trimmed) {
            case .failure(let problem):
                if addressTouched || submitted || problem.isClearAlready {
                    FormNote(symbol: "exclamationmark.triangle", text: problem.message, tint: .dmWarning)
                }
            case .success(let endpoint):
                FormNote(symbol: "arrow.up.forward.app", text: "This connection sends data to \(endpoint.displayHost).", tint: .secondary)
                if endpoint.isLoopbackDevelopment {
                    FormNote(symbol: "laptopcomputer", text: "Local development server on this Mac.", tint: .secondary)
                }
            }
        }
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

    // MARK: Test

    @ViewBuilder
    private var testSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(spacing: DS.Spacing.s) {
                Button("Test connection") { runTest() }
                    .disabled(!canTest)
                if case .running = test {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Contacting the service…")
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
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
                DMNotice(
                    symbol: "checkmark.circle",
                    tint: .dmAccent,
                    title: "Connected to \(report.negotiation.serverName)",
                    message: summary(of: report)
                )
            case .failed(let failure):
                DMNotice(
                    symbol: "exclamationmark.triangle",
                    tint: .dmWarning,
                    title: failure.summary,
                    message: failure.recovery.isEmpty ? nil : failure.recovery
                )
            }
        }
    }

    private func summary(of report: ConnectionProbeReport) -> String {
        let tools = report.listing.tools
        var lines = ["Agreed on MCP version \(report.negotiation.protocolVersion). \(tools.count) \(tools.count == 1 ? "tool" : "tools") offered."]
        for tool in tools.prefix(8) {
            lines.append("• " + tool.displayName + (tool.isEnableable ? "" : " (cannot be turned on)"))
        }
        if tools.count > 8 { lines.append("and \(tools.count - 8) more") }
        return lines.joined(separator: "\n")
    }

    private var canTest: Bool {
        if case .running = test { return false }
        if case .failure = ConnectionEndpoint.validate(address) { return false }
        return !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resetTest() {
        testTask?.cancel()
        test = .idle
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
        focus = .name
    }

    private func save() {
        formProblem = nil
        submitted = true
        addressTouched = true
        saving = true
        testTask?.cancel()
        switch mode {
        case .add:
            switch manager.addConnection(name: name, address: address, token: token) {
            case .success(let connection):
                onSaved(connection.id)
                Announcer.post("Added \(connection.name).")
                dismiss()
            case .failure(let problem):
                formProblem = problem
                saving = false
            }
        case .edit(let id):
            let change: TokenChange = removeToken ? .remove : (token.isEmpty ? .keep : .replace(token))
            Task {
                switch await manager.updateConnection(id, name: name, address: address, token: change) {
                case .success:
                    onSaved(id)
                    dismiss()
                case .failure(let problem):
                    formProblem = problem
                    saving = false
                }
            }
        }
    }
}

/// One supporting line under a field: an icon and 12 pt text, tinted for a problem.
private struct FormNote: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Image(systemName: symbol)
                .font(.dmCaption)
                .foregroundStyle(tint)
                .frame(width: DS.Layout.iconWidth)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.dmCaption)
                .foregroundStyle(tint == .secondary ? Color.secondary : tint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension ConnectionEndpoint.Problem {
    /// Problems that are true the moment they appear (a wrong scheme), so they are not held back until the person
    /// leaves the field. Others, such as a missing host or http:// on the way to http://localhost, are usually just
    /// an address still being typed.
    var isClearAlready: Bool {
        switch self {
        case .unsupportedScheme, .credentialsInURL: true
        default: false
        }
    }
}
