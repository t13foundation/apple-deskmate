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

/// The Connections screen: the services DeskMate can reach, their tools, and the controls to connect, turn tools on,
/// disconnect or delete. Standalone: pass a `ConnectionManager` (call `restore()` once when the app starts).
struct ConnectionsView: View {
    let manager: ConnectionManager

    @State private var editor: ConnectionEditorMode?
    @State private var pendingDelete: MCPConnection?
    @State private var deleteProblem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                header

                if let notice = manager.storageNotice {
                    NoteRow(symbol: "exclamationmark.triangle", text: notice, tint: .orange)
                        .padding(DS.Spacing.m)
                        .dmSurface(radius: DS.Radius.control, emphasis: .orange)
                }

                if manager.connections.isEmpty {
                    emptyState
                } else {
                    ForEach(manager.connections) { connection in
                        ConnectionCard(
                            manager: manager,
                            connection: connection,
                            onEdit: { editor = .edit(connection.id) },
                            onDelete: { pendingDelete = connection }
                        )
                    }
                }
            }
            .frame(maxWidth: DS.Layout.readingWidth, alignment: .leading)
            .padding(DS.Spacing.panel)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Connections")
        .sheet(item: $editor) { mode in
            ConnectionFormSheet(manager: manager, mode: mode)
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { connection in
            Button("Delete Connection", role: .destructive) {
                Task {
                    if case .failure(let problem) = await manager.deleteConnection(connection.id) {
                        deleteProblem = problem.message
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { connection in
            Text(verbatim: "This removes “\(connection.name)” from DeskMate and deletes its saved token from your Keychain. You can add it again later.")
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

    private var deleteTitle: String {
        pendingDelete.map { "Delete “\($0.name)”?" } ?? "Delete connection?"
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.l) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Connections")
                    .font(.dmTitle)
                    .accessibilityAddTraits(.isHeader)
                Text("Connect DeskMate to a tool service you trust. Adding a connection sends nothing: DeskMate contacts the address only when you choose Connect or Test connection.")
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                editor = .add
            } label: {
                Label("Add Connection", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("Add a connection (⇧⌘N)")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.dmAccent)
                .accessibilityHidden(true)
            Text("No connections yet")
                .font(.dmSection)
            Text("A connection lets the assistant look things up in a service you choose, for example your team’s project notes. You decide which tools it may use, and nothing is used without your say-so.")
                .font(.dmBody)
                .foregroundStyle(.secondary)
            Button("Add Connection") { editor = .add }
                .buttonStyle(.bordered)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dmSurface()
        .accessibilityElement(children: .contain)
    }
}

/// A short line with a leading symbol, used for notes and warnings.
struct NoteRow: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.dmCaption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
