import SwiftUI
import UniformTypeIdentifiers

/// What the person is asked to choose in the system file chooser. DeskMate reads only what they choose here;
/// it never browses on its own.
///
/// The chooser is presented by SwiftUI's `fileImporter`, which shows the system panel as a sheet on the window.
/// It is never run as an app-modal panel from inside a button action: a nested modal run loop started from a
/// SwiftUI action (or a toolbar item) left the real sandboxed app unreachable for accessibility after the panel closed.
enum FileRequest: Equatable {
    /// Folders to add to My files.
    case folders
    /// Individual files to add to My files.
    case sourceFiles
    /// Files to attach to one question; `remaining` is how many more the question can take.
    case attachments(remaining: Int)

    static let documentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .pdf]
        for fileExtension in ["md", "markdown"] {
            if let type = UTType(filenameExtension: fileExtension) { types.append(type) }
        }
        return types
    }()

    var allowedContentTypes: [UTType] {
        switch self {
        case .folders: [.folder]
        case .sourceFiles, .attachments: Self.documentTypes
        }
    }

    var allowsMultipleSelection: Bool {
        switch self {
        case .folders, .sourceFiles: true
        case .attachments(let remaining): remaining > 1
        }
    }

    var message: String {
        switch self {
        case .folders:
            "Choose folders DeskMate may read. It reads only what you choose, and nothing leaves your Mac."
        case .sourceFiles:
            "Choose files DeskMate may read. It reads only what you choose, and nothing leaves your Mac."
        case .attachments(let remaining):
            "Choose up to \(remaining) TXT, Markdown or PDF file\(remaining == 1 ? "" : "s"). They are read once, on your Mac, for this question."
        }
    }

    var confirmation: String {
        switch self {
        case .folders, .sourceFiles: "Add"
        case .attachments: "Attach"
        }
    }
}

extension View {
    /// Presents the system file chooser as a sheet on this view's window while `request` is set, then calls
    /// `onChoose` with the chosen URLs. Security-scoped access to the URLs is held until `onChoose` returns,
    /// so it can create app-scope bookmarks and read the files. Attach it to a view that stays in the hierarchy
    /// (never inside a toolbar item or a menu), once per view.
    func fileChooser(_ request: Binding<FileRequest?>, onChoose: @escaping @MainActor ([URL]) async -> Void) -> some View {
        modifier(FileChooserModifier(request: request, onChoose: onChoose))
    }
}

private struct FileChooserModifier: ViewModifier {
    @Binding var request: FileRequest?
    let onChoose: @MainActor ([URL]) async -> Void
    @State private var problem: String?

    func body(content: Content) -> some View {
        // Keeps the panel's configuration stable while it is closing and `request` is already nil.
        let shown = request ?? .sourceFiles
        content
            .fileImporter(
                isPresented: isPresented,
                allowedContentTypes: shown.allowedContentTypes,
                allowsMultipleSelection: shown.allowsMultipleSelection,
                onCompletion: handle,
                onCancellation: { request = nil }
            )
            .fileDialogMessage(shown.message)
            .fileDialogConfirmationLabel(shown.confirmation)
            .alert("DeskMate couldn’t use that choice", isPresented: hasProblem) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { request != nil }, set: { if !$0 { request = nil } })
    }

    private var hasProblem: Binding<Bool> {
        Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
    }

    private func handle(_ result: Result<[URL], any Error>) {
        request = nil
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            let onChoose = onChoose
            Task { @MainActor in
                let held = urls.filter { $0.startAccessingSecurityScopedResource() }
                await onChoose(urls)
                for url in held { url.stopAccessingSecurityScopedResource() }
            }
        case .failure(let error):
            problem = error.localizedDescription
        }
    }
}
