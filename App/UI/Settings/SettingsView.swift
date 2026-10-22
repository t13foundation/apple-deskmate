import DeskMateCore
import SwiftUI

/// The Settings window (⌘,): what DeskMate keeps on this Mac, and the two separate ways to clear it.
struct SettingsView: View {
    let history: ConversationHistory
    let controller: ConversationController
    let library: LibraryStore
    let desktop: DesktopAccess

    @State private var confirmingHistory = false
    @State private var confirmingLibrary = false

    var body: some View {
        Form {
            ShortcutSettingsSection(desktop: desktop)

            Section("Saved on this Mac") {
                Text("DeskMate keeps your conversations so you can pick them up again: your questions, its answers, the source excerpts those answers showed, the names (not the contents) of files you attached, and the briefs or task lists you created.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Saved conversations and My files stay on this Mac in DeskMate’s own folder. They are not synced or uploaded. Tokens for connections are kept in your Keychain, never in a conversation.")
                    .dmFootnote()
                    .fixedSize(horizontal: false, vertical: true)
                Text("When you approve a call to a connected service, the inputs shown in the review are sent to that service.")
                    .dmFootnote()
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Conversation history") {
                LabeledContent("Saved conversations") {
                    Text(history.summaries.count, format: .number)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                Button("Clear history…", role: .destructive) { confirmingHistory = true }
                    .disabled(history.summaries.isEmpty && !controller.hasConversation)
                    .accessibilityHint("Removes every saved conversation after you confirm")
                Text("Removes every saved conversation and its results. Your own files, My files and Connections are not touched.")
                    .dmFootnote()
                    .fixedSize(horizontal: false, vertical: true)
                if history.lastClearFailures > 0 {
                    Label("\(history.lastClearFailures) saved \(history.lastClearFailures == 1 ? "file" : "files") could not be removed. Quit DeskMate and try again.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.dmWarning)
                        .dmFootnote()
                }
            }

            Section("My files") {
                LabeledContent("Folders and files") {
                    Text(library.isEmpty ? "None" : "\(library.sources.count) \(library.sources.count == 1 ? "folder or file" : "folders and files")")
                }
                .accessibilityElement(children: .combine)
                Button("Clear library…", role: .destructive) { confirmingLibrary = true }
                    .disabled(library.isEmpty)
                    .accessibilityHint("Makes DeskMate forget the files it may search, after you confirm")
                Text("This is separate from history. DeskMate forgets every folder and file and deletes its search index. Your files are not touched.")
                    .dmFootnote()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .confirmationDialog("Clear conversation history?", isPresented: $confirmingHistory, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) {
                controller.clearHistory()
                Announcer.post("Conversation history cleared")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved conversation and its results will be removed from this Mac. This can’t be undone. Your own files and My files are not touched.")
        }
        .confirmationDialog("Clear My files?", isPresented: $confirmingLibrary, titleVisibility: .visible) {
            Button("Clear library", role: .destructive) { library.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("DeskMate forgets every folder and file and deletes its search index. Your files are not touched. Conversation history is not affected.")
        }
    }
}
