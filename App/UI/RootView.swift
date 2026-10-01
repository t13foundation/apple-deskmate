import AppKit
import DeskMateCore
import SwiftUI

/// Main window: a restrained sidebar and the conversation, My files or Connections.
struct RootView: View {
    let controller: ConversationController
    let library: LibraryStore
    let connections: ConnectionManager
    let history: ConversationHistory
    let approvals: ToolApprovalBroker
    @Bindable var navigation: AppNavigation

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var wasCompact: Bool?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(controller: controller, history: history, navigation: navigation)
                .navigationSplitViewColumnWidth(
                    min: DS.Layout.sidebarMinWidth,
                    ideal: DS.Layout.sidebarIdealWidth,
                    max: DS.Layout.sidebarMaxWidth
                )
        } detail: {
            switch navigation.section {
            case .chat:
                ChatView(controller: controller, history: history)
                    .inspector(isPresented: viewerIsPresented) {
                        SourceViewer(navigation: navigation)
                            .inspectorColumnWidth(
                                min: DS.Layout.viewerMinWidth,
                                ideal: DS.Layout.viewerIdealWidth,
                                max: DS.Layout.viewerMaxWidth
                            )
                    }
                    .navigationTitle(controller.conversationTitle)
                    .navigationSubtitle(controller.readiness.isReady ? SystemModelEngine.provenance.shortLabel : controller.readiness.statusLabel)
            case .files:
                LibraryView()
                    .navigationTitle("My files")
                    .navigationSubtitle("Stays on your Mac")
            case .connections:
                ConnectionsView(manager: connections)
                    .navigationTitle("Connections")
                    .navigationSubtitle("You choose which tools it may use")
            }
        }
        .toolbar {
            // New chat is always one click away: here whether or not the sidebar is shown, and as the first sidebar row.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startNewChat()
                } label: {
                    // Named and tinted so the action stands out; Send stays the one filled accent control.
                    Label("New chat", systemImage: "square.and.pencil")
                        .labelStyle(.titleAndIcon)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .tint(Color.dmBrandText)
                // ⌘N itself is the File > New Chat command, which does the same thing.
                .help("Start a new chat (⌘N)")
                .accessibilityLabel("New chat")
                .accessibilityHint("Clears the conversation and starts fresh")
            }
        }
        .environment(library)
        .environment(navigation)
        // A connected-service call waits here for a person's answer, whichever section is open.
        .toolApprovalSheet(broker: approvals)
        .frame(minWidth: DS.Layout.windowMinWidth, minHeight: DS.Layout.windowMinHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            // A narrow window starts with the sidebar hidden. Only crossing the threshold changes it,
            // so a person's own show or hide choice is left alone while they resize within one range.
            let isCompact = width < DS.Layout.sidebarCollapseWidth
            if wasCompact != isCompact {
                wasCompact = isCompact
                columnVisibility = isCompact ? .detailOnly : .all
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The person may have just turned Apple Intelligence on in System Settings.
            controller.refreshReadiness()
        }
        .onChange(of: controller.hasConversation) { _, hasConversation in
            if !hasConversation { navigation.closeViewer() }
        }
        .onChange(of: controller.conversationID) {
            // An excerpt belongs to the conversation it was cited in.
            navigation.closeViewer()
        }
        .task { controller.prewarmIfReady() }
        .task { await library.load() }
        .task { await history.load() }
    }

    private var viewerIsPresented: Binding<Bool> {
        Binding(
            get: { navigation.viewedCitation != nil },
            set: { if !$0 { navigation.closeViewer() } }
        )
    }

    /// Same as the sidebar row: an empty chat is already new, so an unsent draft is not thrown away.
    private func startNewChat() {
        if controller.hasConversation { controller.newChat() }
        navigation.section = .chat
    }
}

/// Sidebar rows: New chat, Recent conversations, My files, Connections, and Settings.
struct SidebarView: View {
    let controller: ConversationController
    let history: ConversationHistory
    @Bindable var navigation: AppNavigation

    @Environment(\.openSettings) private var openSettings
    @State private var pendingDeletion: ConversationSummary?

    private enum Item: Hashable {
        case newChat
        case conversation(UUID)
        case files
        case connections
    }

    /// The conversation on screen is listed even in the moment before its first save reaches the list.
    private var showsCurrentSeparately: Bool {
        controller.hasConversation && !history.summaries.contains { $0.id == controller.conversationID }
    }

    var body: some View {
        List(selection: selection) {
            Section {
                newChatRow
                    .tag(Item.newChat)
                    .accessibilityLabel("New chat")
                    .accessibilityHint("Clears the conversation and starts fresh")
            }
            if showsCurrentSeparately || !history.summaries.isEmpty {
                Section("Recent") {
                    if showsCurrentSeparately {
                        Label(controller.conversationTitle, systemImage: "bubble.left")
                            .lineLimit(1)
                            .tag(Item.conversation(controller.conversationID))
                            .accessibilityLabel("Current conversation: \(controller.conversationTitle)")
                    }
                    ForEach(history.summaries) { summary in
                        recentRow(summary)
                    }
                }
            }
            Section("Library") {
                Label("My files", systemImage: "folder")
                    .tag(Item.files)
                    .accessibilityLabel("My files")
                    .accessibilityHint("Shows the folders and files DeskMate may read")
            }
            Section("Services") {
                Label("Connections", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(Item.connections)
                    .accessibilityLabel("Connections")
                    .accessibilityHint("Shows the tool services DeskMate may use and which tools are turned on")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Also reachable with ⌘, from the app menu.
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .help("What DeskMate saves, and how to clear it (⌘,)")
            .accessibilityLabel("Settings")
            .accessibilityHint("Opens the Settings window")
        }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { summary in
            Button("Delete conversation", role: .destructive) {
                controller.deleteConversation(summary.id)
                Announcer.post("Conversation deleted")
            }
            Button("Cancel", role: .cancel) {}
        } message: { summary in
            Text("“\(summary.title)” and its results will be removed from this Mac. Your files are not touched.")
        }
    }

    private func recentRow(_ summary: ConversationSummary) -> some View {
        Label(summary.title, systemImage: "bubble.left")
            .lineLimit(1)
            .help(summary.title)
            .tag(Item.conversation(summary.id))
            .accessibilityLabel(summary.title)
            .accessibilityHint("Opens this conversation. Last used \(summary.updatedAt.formatted(.relative(presentation: .named)))")
            .contextMenu {
                Button("Delete…", role: .destructive) { pendingDeletion = summary }
            }
    }

    /// The action row: a brand-text icon and a medium-weight label, so it reads as an action rather than a destination.
    /// While the row is selected the system selection colours apply, which keep it legible on the highlight.
    @ViewBuilder private var newChatRow: some View {
        let isSelected = selection.wrappedValue == .newChat
        Label {
            Text("New chat").fontWeight(.medium)
        } icon: {
            if isSelected {
                Image(systemName: "square.and.pencil")
            } else {
                Image(systemName: "square.and.pencil").foregroundStyle(Color.dmBrandText)
            }
        }
    }

    private var selection: Binding<Item?> {
        Binding(
            get: {
                switch navigation.section {
                case .files: .files
                case .connections: .connections
                case .chat: controller.hasConversation ? .conversation(controller.conversationID) : .newChat
                }
            },
            set: { item in
                switch item {
                case .newChat:
                    if controller.hasConversation { controller.newChat() }
                    navigation.section = .chat
                case .conversation(let id):
                    navigation.section = .chat
                    if id != controller.conversationID || !controller.hasConversation {
                        Task { await controller.open(id) }
                    }
                case .files:
                    navigation.section = .files
                case .connections:
                    navigation.section = .connections
                case nil:
                    break
                }
            }
        )
    }
}
