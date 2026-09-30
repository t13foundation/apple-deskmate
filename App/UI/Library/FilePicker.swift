import AppKit
import UniformTypeIdentifiers

/// The system open panel. DeskMate reads only what the person chooses here; it never browses on its own.
@MainActor
enum FilePicker {
    private static var documentTypes: [UTType] {
        var types: [UTType] = [.plainText, .pdf]
        for fileExtension in ["md", "markdown"] {
            if let type = UTType(filenameExtension: fileExtension) { types.append(type) }
        }
        return types
    }

    /// Folders to add to My files.
    static func chooseFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Add folders to My files"
        panel.message = "Choose folders DeskMate may read. It reads only what you choose, and nothing leaves your Mac."
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Individual files to add to My files.
    static func chooseSourceFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Add files to My files"
        panel.message = "Choose files DeskMate may read. It reads only what you choose, and nothing leaves your Mac."
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = documentTypes
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Files to attach to one question.
    static func chooseFiles(remaining: Int) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Attach files"
        panel.message = "Choose up to \(remaining) TXT, Markdown or PDF file\(remaining == 1 ? "" : "s"). They are read once, on your Mac, for this question."
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = remaining > 1
        panel.allowedContentTypes = documentTypes
        return panel.runModal() == .OK ? panel.urls : []
    }
}
