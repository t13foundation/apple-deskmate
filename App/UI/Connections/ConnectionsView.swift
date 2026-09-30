import AppKit
import DeskMateCore
import SwiftUI

/// What the add/edit sheet is for. Identifiable so it can drive `.sheet(item:)`.
enum ConnectionEditorMode: Identifiable, Equatable {
    case add
    case edit(UUID)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let id): "edit-\(id.uuidString)"
        }
    }
}

/// Connections: the tool services DeskMate may reach, what each one offers, and the controls to test, turn tools on,
/// disconnect or delete. Same layout as My files: actions in the window toolbar, one list in the shared reading column.
///
/// Adding a connection only saves it. DeskMate contacts the address when the person chooses Test connection.
struct ConnectionsView: View {
    let manager: ConnectionManager

    @State private var selectedID: UUID?
    @State private var editor: ConnectionEditorMode?
    @State private var pendingDelete: MCPConnection?
    @State private var deleteProblem: String?

    /// The chosen connection, or the first one when nothing valid is chosen.
    private var selected: MCPConnection? {
        selectedID.flatMap { manager.connection($0) } ?? manager.connections.first
    }

    var body: some View {
        Group {
            if manager.connections.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar { toolbar }
        .sheet(item: $editor) { mode in
            ConnectionFormSheet(manager: manager, mode: mode) { id in
                selectedID = id
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { connection in
            Button("Delete connection", role: .destructive) { delete(connection) }
            Button("Cancel", role: .cancel) {}
        } message: { connection in
            Text(verbatim: deleteMessage(connection))
        }
        .alert(
            "The connection was not deleted",
            isPresented: Binding(get: { deleteProblem != nil }, set: { if !$0 { deleteProblem = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: deleteProblem ?? "")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let selected, manager.status(of: selected.id).isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Contacting \(selected.endpoint.displayHost)")
            }
            Button {
                editor = .add
            } label: {
                Label("Add connection", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("Add a connection (⇧⌘N)")

            Button {
                if let selected { Task { await manager.connect(selected.id) } }
            } label: {
                Label("Test connection", systemImage: "bolt.horizontal")
            }
            .disabled(!canTest)
            .help(canTest ? "Connect to the selected service and list its tools" : "Select an enabled connection to test it")
        }
    }

    private var canTest: Bool {
        guard let selected else { return false }
        return selected.isEnabled && !manager.status(of: selected.id).isBusy
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                Text("Connect a tool service you trust, then choose which of its tools the assistant may use. Adding a connection sends nothing. DeskMate contacts the address only when you test or connect.")
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                storageNotice
                connectionList

                if let selected {
                    ConnectionDetail(
                        manager: manager,
                        connection: selected,
                        onEdit: { editor = .edit(selected.id) },
                        onDelete: { pendingDelete = selected }
                    )
                    .id(selected.id)
                }

                footnote
            }
            .dmReadingColumn()
            .padding(.vertical, DS.Spacing.l)
        }
    }

    @ViewBuilder private var storageNotice: some View {
        if let notice = manager.storageNotice {
            DMNotice(symbol: "exclamationmark.triangle", tint: .dmWarning, title: notice)
        }
    }

    private var connectionList: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Your connections")
                .font(.dmSection)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(manager.connections.enumerated()), id: \.element.id) { index, connection in
                    if index > 0 { Divider() }
                    ConnectionRow(
                        connection: connection,
                        status: manager.status(of: connection.id),
                        isSelected: connection.id == selected?.id,
                        onSelect: { selectedID = connection.id }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .dmSurface(radius: DS.Radius.control)
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Testing sends only the start-up handshake and a request for the tool list. No file or chat text is sent.")
            Text("DeskMate does not follow redirects, start programs or look for services on its own. Up to \(ConnectionManager.maxConnections) connections and \(manager.maxEnabledTools) tools turned on per connection. Tokens stay in your Keychain.")
        }
        .font(.dmCaption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Empty state

    private var emptyState: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: DS.Spacing.xl) {
                    if let notice = manager.storageNotice {
                        DMNotice(symbol: "exclamationmark.triangle", tint: .dmWarning, title: notice)
                    }
                    DMEmptyHeader(
                        symbol: "point.3.connected.trianglepath.dotted",
                        title: "No connections yet",
                        subtitle: "A connection lets the assistant look things up in a service you choose, for example your team’s project notes. You decide which tools it may use. Adding one sends nothing."
                    )
                    Button("Add connection…") { editor = .add }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .dmReadingColumn()
                .dmEmptyStateAnchor(height: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connections is empty")
    }

    // MARK: Deleting

    private var deleteTitle: String {
        pendingDelete.map { "Delete “\($0.name)”?" } ?? "Delete connection?"
    }

    private func deleteMessage(_ connection: MCPConnection) -> String {
        let token = connection.auth == .bearer ? " and removes its saved token from your Keychain" : ""
        return "This removes the connection from DeskMate\(token). The service itself is not changed. You can add it again later."
    }

    private func delete(_ connection: MCPConnection) {
        Task {
            switch await manager.deleteConnection(connection.id) {
            case .success:
                Announcer.post("Deleted \(connection.name).")
            case .failure(let problem):
                deleteProblem = problem.message
            }
        }
    }
}
