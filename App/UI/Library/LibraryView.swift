import AppKit
import DeskMateCore
import SwiftUI

/// My files: the folders and files DeskMate may read, what was found in them, and what was skipped and why.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @State private var confirmingClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                header
                actions
                notices
                if library.needsRefresh { staleBanner }
                if library.isEmpty {
                    emptyState
                } else {
                    ForEach(library.sources) { source in
                        SourceCard(source: source)
                    }
                    limitsFootnote
                }
            }
            .frame(maxWidth: DS.Layout.readingWidth, alignment: .leading)
            .padding(DS.Spacing.panel)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Clear My files?", isPresented: $confirmingClear) {
            Button("Clear library", role: .destructive) { library.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("DeskMate forgets every folder and file and deletes its search index. Your files are not touched.")
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("My files")
                .font(.dmTitle)
                .accessibilityAddTraits(.isHeader)
            Text("DeskMate reads only the folders and files you add here, and only on your Mac. Ask about them in normal chat and answers show where they came from.")
                .font(.dmBody)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: DS.Spacing.s) {
            Button {
                addSources()
            } label: {
                Label("Add folder or files…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(library.isWorking)
            .help("Choose folders or files DeskMate may read")

            Button {
                Task { await library.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(library.isEmpty || library.isWorking)
            .help("Look for added, changed and removed files")

            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Label("Clear library", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(library.isEmpty || library.isWorking)
            .help("Forget every source and delete the search index. Your files are not touched.")

            if library.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, DS.Spacing.xs)
                    .accessibilityLabel("Reading your files")
            }
            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }

    @ViewBuilder private var notices: some View {
        if !library.notices.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ForEach(Array(library.notices.enumerated()), id: \.offset) { _, notice in
                    Label(notice, systemImage: "info.circle")
                        .font(.dmBody)
                        .foregroundStyle(.secondary)
                }
                Button("Dismiss") { library.dismissNotices() }
                    .buttonStyle(.borderless)
                    .font(.dmCaption)
            }
            .padding(DS.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dmSurface(radius: DS.Radius.surface)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Notices")
        }
    }

    private var staleBanner: some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Some files changed or disappeared since the last refresh. Changed files are not used until you refresh.")
                .font(.dmBody)
            Spacer(minLength: 0)
            Button("Refresh") { Task { await library.refresh() } }
                .buttonStyle(.bordered)
                .disabled(library.isWorking)
        }
        .padding(DS.Spacing.l)
        .dmSurface(radius: DS.Radius.surface, emphasis: .orange)
        .accessibilityElement(children: .contain)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.dmAccent)
                .accessibilityHidden(true)
            Text("Nothing added yet")
                .font(.dmSection)
            Text("Add a folder of notes, plans or reports, or single files. DeskMate reads text, Markdown and text-based PDF files.")
                .font(.dmBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add folder or files…") { addSources() }
                .buttonStyle(.borderedProminent)
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity)
        .dmSurface(radius: DS.Radius.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("My files is empty")
    }

    private var limitsFootnote: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("\(library.searchableFiles.count) of \(LibraryLimits.maxFiles) files searchable" + refreshedText)
                .font(.dmCaption)
                .foregroundStyle(.secondary)
            Text("Limits: \(LibraryLimits.maxFiles) files, PDFs up to 10 MB and \(LibraryLimits.maxPDFPages) pages, text and Markdown up to 1 MB. Scanned PDFs need OCR, which DeskMate does not do.")
                .font(.dmCaption)
                .foregroundStyle(.secondary)
        }
    }

    private var refreshedText: String {
        guard let report = library.lastReport else { return "" }
        return ". Last refresh: \(report.summary)"
    }

    private func addSources() {
        let urls = FilePicker.chooseSources()
        guard !urls.isEmpty else { return }
        Task { await library.addSources(urls: urls) }
    }
}

/// One folder or file the person added, with its files.
private struct SourceCard: View {
    let source: LibrarySource
    @Environment(LibraryStore.self) private var library
    @State private var showsSearchable = false

    var body: some View {
        let state = library.state(of: source)
        let files = library.files(in: source.id)
        let searchable = files.filter(\.isIndexed)
        let skipped = files.filter { !$0.isIndexed }

        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .top, spacing: DS.Spacing.m) {
                Image(systemName: source.kind == .folder ? "folder" : "doc.text")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.dmAccent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(source.displayName)
                        .font(.dmSection)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(summary(state: state, searchable: searchable.count, skipped: skipped.count))
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    library.remove(sourceID: source.id)
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
                .buttonStyle(.bordered)
                .disabled(library.isWorking)
                .help("Stop using this \(source.kind == .folder ? "folder" : "file"). Your files are not deleted.")
                .accessibilityLabel("Remove \(source.displayName) from My files")
            }

            if case .unavailable(let reason) = state {
                Label(reason.explanation, systemImage: "exclamationmark.triangle")
                    .font(.dmBody)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("\(reason.label). \(reason.explanation)")
            }

            if !skipped.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    Text("Not searchable (\(skipped.count))")
                        .font(.dmCaption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(skipped) { file in
                        SkippedFileRow(file: file)
                    }
                    if source.omittedIgnoredCount > 0 {
                        Text("And \(source.omittedIgnoredCount) more files of other types, which DeskMate ignores.")
                            .font(.dmCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !searchable.isEmpty {
                DisclosureGroup(isExpanded: $showsSearchable) {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        ForEach(searchable) { file in
                            SearchableFileRow(file: file, canReveal: state.isAvailable)
                        }
                    }
                    .padding(.top, DS.Spacing.s)
                } label: {
                    Text("Searchable files (\(searchable.count))")
                        .font(.dmBody)
                }
            }
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dmSurface(radius: DS.Radius.surface, emphasis: state.isAvailable ? nil : .orange)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source: \(source.displayName)")
    }

    private func summary(state: SourceState, searchable: Int, skipped: Int) -> String {
        if case .unavailable(let reason) = state { return reason.label }
        var parts = ["\(searchable) searchable"]
        if skipped > 0 { parts.append("\(skipped) not searchable") }
        return parts.joined(separator: " · ")
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
                .frame(width: 20)
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

    var body: some View {
        if let reason = file.skip {
            HStack(alignment: .top, spacing: DS.Spacing.s) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(file.relativePath)
                        .font(.dmBody)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(reason.label). \(reason.explanation)")
                        .font(.dmCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(file.relativePath) is not searchable. \(reason.label). \(reason.explanation)")
        }
    }
}
