import AppKit
import DeskMateCore
import SwiftUI
import UniformTypeIdentifiers

/// Quiet line shown where a reopened conversation's model memory begins.
struct MemoryNote: View {
    static let text = "Older messages aren't in the model's memory for this chat"

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            VStack { Divider() }
            Label(Self.text, systemImage: "clock.arrow.circlepath")
                .labelStyle(.titleAndIcon)
                .dmFootnote()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack { Divider() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.text)
    }
}

/// The visible, recoverable notice for a conversation that could not be written to disk. It names no path and no
/// content. It clears by itself when a write succeeds; Try again re-attempts the write at once.
struct SaveProblemNotice: View {
    let controller: ConversationController
    /// Runs before the retry, so an open editor can hand over its latest text.
    var beforeRetry: () -> Void = {}

    var body: some View {
        if let problem = controller.saveProblem {
            DMNotice(
                symbol: "exclamationmark.triangle",
                tint: .dmWarning,
                title: problem.title,
                message: problem.message,
                actionsBelow: true
            ) {
                Button("Try again") {
                    beforeRetry()
                    controller.retrySave()
                }
                .accessibilityHint("Tries to save the conversation again")
            }
            .accessibilityLabel("Problem: \(problem.title). \(problem.message)")
            .onAppear { Announcer.post("\(problem.title). \(problem.message)") }
        }
    }
}

/// The briefs and task lists made in this conversation. Each opens in the result sheet.
struct SavedResultsSection: View {
    let controller: ConversationController

    /// The time line of a result. It never says "saved" while the last write failed.
    private func timeLine(_ result: StoredResult) -> String {
        let when = result.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return controller.currentConversationUnsaved ? "Not saved to this Mac · edited \(when)" : when
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Saved results")
                .font(.dmCaption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(controller.results) { result in
                Button {
                    controller.presentedResultID = result.id
                } label: {
                    HStack(spacing: DS.Spacing.m) {
                        Image(systemName: result.kind == .brief ? "doc.text" : "checklist")
                            .foregroundStyle(Color.dmBrandText)
                            .frame(width: DS.Layout.iconWidth)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.kind.title).font(.dmBody.weight(.medium))
                            Text(timeLine(result))
                                .font(.dmCaption)
                                .foregroundStyle(controller.currentConversationUnsaved ? Color.dmWarning : Color.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.dmCaption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(DS.Spacing.m)
                    .dmSurface()
                    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(result.kind.title), \(timeLine(result))")
                .accessibilityHint("Opens it so you can edit, copy or save it")
            }
        }
    }
}

/// The result as editable Markdown, with Copy and Save as Markdown. Edits are saved with the conversation.
struct ResultSheet: View {
    let controller: ConversationController
    let resultID: UUID

    private enum Mode: String, CaseIterable, Identifiable {
        case edit = "Edit"
        case preview = "Preview"
        var id: String { rawValue }
    }

    @State private var text = ""
    @State private var loaded = false
    @State private var mode: Mode = .edit
    @State private var exporting = false
    @State private var confirmingDelete = false
    @State private var copied = false
    @State private var saveProblem: String?
    @Environment(\.dismiss) private var dismiss

    private var kind: ResultKind { controller.result(resultID)?.kind ?? .brief }

    var body: some View {
        VStack(spacing: 0) {
            header
            if controller.currentConversationUnsaved {
                SaveProblemNotice(controller: controller) {
                    if loaded { controller.updateResult(resultID, markdown: text) }
                }
                .padding([.horizontal, .bottom], DS.Spacing.l)
            }
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 660, minHeight: 460, idealHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            guard !loaded else { return }
            text = controller.result(resultID)?.markdown ?? ""
            loaded = true
        }
        .task(id: text) {
            // Saved a moment after typing stops, and again when the sheet closes.
            guard loaded else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            controller.updateResult(resultID, markdown: text)
        }
        .onDisappear {
            if loaded { controller.updateResult(resultID, markdown: text) }
        }
        .fileExporter(
            isPresented: $exporting,
            document: MarkdownDocument(text: text),
            contentType: MarkdownDocument.markdownType,
            defaultFilename: suggestedFileName
        ) { result in
            switch result {
            case .success:
                saveProblem = nil
                Announcer.post("Saved as Markdown")
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    saveProblem = "DeskMate couldn’t save the file. Choose another folder and try again."
                }
            }
        }
        .confirmationDialog("Delete this \(kind.title.lowercased())?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete \(kind.title.lowercased())", role: .destructive) {
                controller.deleteResult(resultID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is removed from this conversation. Files you already saved are not touched.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(kind.title)
                    .font(.dmTitle)
                    .accessibilityAddTraits(.isHeader)
                Text(controller.currentConversationUnsaved
                    ? "Edit it here, then copy it or save it as a Markdown file. Your edits are kept while the app is open but are not saved yet."
                    : "Edit it here, then copy it or save it as a Markdown file. Your edits are saved with this conversation.")
                    .dmFootnote()
            }
            Spacer(minLength: DS.Spacing.m)
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            .accessibilityLabel("Show the Markdown text or a preview")
        }
        .padding(DS.Spacing.l)
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .edit:
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(DS.Spacing.m)
                .accessibilityLabel("Markdown text of the \(kind.title.lowercased())")
        case .preview:
            ScrollView {
                MarkdownText(markdown: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.l)
            }
            .accessibilityLabel("Preview of the \(kind.title.lowercased())")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            if let saveProblem {
                Label(saveProblem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.dmWarning)
                    .dmFootnote()
            }
            HStack(spacing: DS.Spacing.s) {
                Button("Delete…", role: .destructive) { confirmingDelete = true }
                    .accessibilityHint("Removes this result from the conversation after you confirm")
                Spacer(minLength: DS.Spacing.m)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Announcer.post("Copied")
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel("Copy the \(kind.title.lowercased()) as Markdown")
                Button {
                    exporting = true
                } label: {
                    Label("Save as Markdown…", systemImage: "square.and.arrow.down")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Spacing.l)
    }

    private var suggestedFileName: String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
        let title = controller.conversationTitle.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(title.prefix(60)).trimmingCharacters(in: .whitespaces)
        return clipped.isEmpty ? kind.suggestedFileName : "\(kind.suggestedFileName) - \(clipped)"
    }
}

/// A Markdown file for the save panel. Written as UTF-8 text.
struct MarkdownDocument: FileDocument {
    /// `.md` when the system knows Markdown, plain text otherwise.
    static let markdownType: UTType = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText

    static var readableContentTypes: [UTType] { [markdownType] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
