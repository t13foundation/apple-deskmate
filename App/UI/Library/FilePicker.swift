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

    /// Folders and files to add to My files.
    static func chooseSources() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Add to My files"
        panel.message = "Choose folders or files DeskMate may read. It reads only what you choose, and nothing leaves your Mac."
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
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
