import AppKit
import DeskMateCore
import SwiftUI

/// My files: the folders and files DeskMate may read, what was found in them, and what was skipped and why.
///
/// Native layout in the shared reading column: the actions live in the window toolbar, sources are rows in
/// one grouped list with status badges, and skipped files sit in a collapsible section with their reasons.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var confirmingClear = false
    @State private var showsSkipped = false
    /// Set by the Add buttons; shows the system chooser as a sheet on this window.
    @State private var fileRequest: FileRequest?
    /// True from the moment files are chosen until they are added and read.
    @State private var isAdding = false

    private var isBusy: Bool { library.isWorking || isAdding }

    var body: some View {
        Group {
            if library.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar { toolbar }
        .fileChooser($fileRequest) { urls in
            // Adding and reading run off the main actor inside the store; this only shows progress around it.
            isAdding = true
            await library.addSources(urls: urls)
            isAdding = false
        }
        .confirmationDialog("Clear My files?", isPresented: $confirmingClear) {
            Button("Clear library", role: .destructive) { library.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("DeskMate forgets every folder and file and deletes its search index. Your files are not touched.")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // The set of toolbar items never changes while work runs; progress is shown in the content instead.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                fileRequest = .folders
            } label: {
                Label("Add folder", systemImage: "folder.badge.plus")
            }
            .disabled(isBusy)
            .help("Choose folders DeskMate may read")

            Button {
                fileRequest = .sourceFiles
            } label: {
                Label("Add files", systemImage: "doc.badge.plus")
            }
            .disabled(isBusy)
            .help("Choose individual files DeskMate may read")

            Button {
                Task { await library.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(library.isEmpty || isBusy)
            .help("Look for added, changed and removed files")

            Menu {
                Button("Clear library…", role: .destructive) { confirmingClear = true }
                    .disabled(library.isEmpty || isBusy)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Forget every source and delete the search index. Your files are not touched.")
        }
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                Text("DeskMate reads only what you add here, on your Mac. Ask about it in normal chat and answers show their sources.")
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                progressRow
                notices
                if library.needsRefresh { staleNotice }

                sourcesGroup
                if !library.skippedFiles.isEmpty { skippedGroup }
                limitsFootnote
            }
            .dmReadingColumn()
            .padding(.vertical, DS.Spacing.l)
        }
    }

    /// Visible while files are being added or re-read, so a long PDF never looks like a frozen window.
    @ViewBuilder private var progressRow: some View {
        if isBusy {
            let text = isAdding ? "Adding and reading your files…" : "Reading your files…"
            HStack(spacing: DS.Spacing.s) {
                ProgressView()
                    .controlSize(.small)
                Text(text)
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
        }
    }

    @ViewBuilder private var notices: some View {
        if !library.notices.isEmpty {
            DMNotice(
                symbol: "info.circle",
                tint: .dmAccent,
                title: library.notices.count == 1 ? library.notices[0] : "\(library.notices.count) things to know",
                message: library.notices.count > 1 ? library.notices.joined(separator: "\n") : nil,
                onDismiss: { library.dismissNotices() }
            )
            .accessibilityLabel("Notices")
        }
    }

    private var staleNotice: some View {
        DMNotice(
            symbol: "arrow.triangle.2.circlepath",
            tint: .dmWarning,
            title: "Some files changed or disappeared",
            message: "Changed files are not used until you refresh."
        ) {
            Button("Refresh") { Task { await library.refresh() } }
                .buttonStyle(.bordered)
                .disabled(isBusy)
        }
    }

    private var sourcesGroup: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Folders and files")
                .font(.dmSection)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(library.sources.enumerated()), id: \.element.id) { index, source in
                    if index > 0 { Divider() }
                    SourceRow(source: source)
                }
            }
            .dmSurface(radius: DS.Radius.control)
        }
    }

    private var skippedGroup: some View {
        let skipped = library.skippedFiles
        // The label and hint belong to the header button only. Each skipped row is its own accessibility element
        // that reads its reason.
        return DMDisclosure(
            isExpanded: $showsSkipped,
            label: "Skipped files, \(skipped.count)",
            hint: "Shows which files DeskMate can’t search and why"
        ) {
            HStack(spacing: DS.Spacing.s) {
                Text("Skipped files")
                    .font(.dmBody.weight(.medium))
                DMBadge(text: "\(skipped.count)", tint: .dmWarning)
                Spacer(minLength: 0)
            }
        } content: {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                ForEach(skipped) { file in
                    SkippedFileRow(file: file, sourceName: sourceName(for: file))
                }
            }
            .padding(.top, DS.Spacing.s)
        }
        .padding(DS.Spacing.m)
        .dmSurface(radius: DS.Radius.control)
    }

    private var limitsFootnote: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("\(library.searchableFiles.count) of \(LibraryLimits.maxFiles) files searchable" + refreshedText)
            Text("Limits: \(LibraryLimits.maxFiles) files, PDFs up to 10 MB and \(LibraryLimits.maxPDFPages) pages, text and Markdown up to 1 MB. Scanned PDFs need OCR, which DeskMate does not do.")
            if ignoredCount > 0 {
                Text("DeskMate ignores \(ignoredCount) more files of other types.")
            }
        }
        .font(.dmCaption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ignoredCount: Int {
        library.sources.reduce(0) { $0 + $1.omittedIgnoredCount }
    }

    private var refreshedText: String {
        guard let report = library.lastReport else { return "" }
        return ". Last refresh: \(report.summary)"
    }

    private func sourceName(for file: IndexedFile) -> String? {
        guard library.sources.count > 1 else { return nil }
        return library.sources.first { $0.id == file.sourceID }?.displayName
    }

    // MARK: Empty state

    private var emptyState: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: DS.Spacing.xl) {
                    DMEmptyHeader(
                        symbol: "folder.badge.plus",
                        title: "Nothing added yet",
                        subtitle: "Add a folder of notes, plans or reports, or single files. DeskMate reads text, Markdown and text-based PDF files."
                    )
                    HStack(spacing: DS.Spacing.s) {
                        Button("Add folder…") { fileRequest = .folders }
                            .buttonStyle(.borderedProminent)
                        Button("Add files…") { fileRequest = .sourceFiles }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    .disabled(isBusy)
                    progressRow
                }
                .dmReadingColumn()
                .dmEmptyStateAnchor(height: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("My files is empty")
    }

}

/// One folder or file the person added: name, status badges and a remove button. It opens to its searchable files.
private struct SourceRow: View {
    let source: LibrarySource
    @Environment(LibraryStore.self) private var library
    @State private var expanded = false

    var body: some View {
        let state = library.state(of: source)
        let files = library.files(in: source.id)
        let searchable = files.filter(\.isIndexed)
        let skipped = files.filter { !$0.isIndexed }

        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                if case .unavailable(let reason) = state {
                    Label(reason.explanation, systemImage: "exclamationmark.triangle")
                        .font(.dmCaption)
                        .foregroundStyle(Color.dmWarning)
                        .accessibilityLabel("\(reason.label). \(reason.explanation)")
                }
                ForEach(searchable) { file in
                    SearchableFileRow(file: file, canReveal: state.isAvailable)
                }
                if searchable.isEmpty, state.isAvailable {
                    Text("No searchable files in this \(source.kind == .folder ? "folder" : "file").")
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, DS.Spacing.s)
        } label: {
            header(state: state, searchable: searchable.count, skipped: skipped.count)
        }
        .padding(DS.Spacing.m)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source: \(source.displayName)")
    }

    private func header(state: SourceState, searchable: Int, skipped: Int) -> some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: source.kind == .folder ? "folder" : "doc.text")
                .font(.dmBody)
                .foregroundStyle(Color.dmAccent)
                .frame(width: DS.Layout.iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(source.displayName)
                    .font(.dmBody.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(state: state))
                    .font(.dmCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Spacing.s)
            if case .unavailable = state {
                DMBadge(text: "Unavailable", tint: .dmWarning)
            } else {
                DMBadge(text: "\(searchable) searchable", tint: .dmAccent)
                if skipped > 0 {
                    DMBadge(text: "\(skipped) skipped", tint: .dmWarning)
                }
            }
            Button(role: .destructive) {
                library.remove(sourceID: source.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(library.isWorking)
            .help("Stop using this \(source.kind == .folder ? "folder" : "file"). Your files are not deleted.")
            .accessibilityLabel("Remove \(source.displayName) from My files")
        }
        .contentShape(Rectangle())
    }

    private func subtitle(state: SourceState) -> String {
        if case .unavailable(let reason) = state { return reason.label }
        return source.kind == .folder ? "Folder" : "File"
    }
}

private struct SearchableFileRow: View {
    let file: IndexedFile
    let canReveal: Bool
    @Environment(LibraryStore.self) private var library

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: file.kind == .pdf ? "doc.richtext" : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: DS.Layout.iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.relativePath)
                    .font(.dmBody)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.dmCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if canReveal {
                Button {
                    if let url = library.revealURL(forFileID: file.id) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel("Show \(file.fileName) in Finder")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        var parts: [String] = [file.kind?.label ?? "File"]
        if let pages = file.pageCount { parts.append("\(pages) page\(pages == 1 ? "" : "s")") }
        parts.append("\(file.chunkCount) passage\(file.chunkCount == 1 ? "" : "s")")
        if let note = file.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

private struct SkippedFileRow: View {
    let file: IndexedFile
    /// Shown in front of the path when more than one source is in My files.
    let sourceName: String?

    var body: some View {
        if let reason = file.skip {
            HStack(alignment: .top, spacing: DS.Spacing.s) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Color.dmWarning)
                    .frame(width: DS.Layout.iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayPath)
                        .font(.dmBody)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(reason.label). \(reason.explanation)")
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(displayPath), skipped: \(reason.label)")
            .accessibilityHint(reason.explanation)
        }
    }

    private var displayPath: String {
        sourceName.map { "\($0) / \(file.relativePath)" } ?? file.relativePath
    }
}
