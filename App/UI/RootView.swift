import AppKit
import DeskMateCore
import SwiftUI

/// Main window: a restrained sidebar and the conversation, My files or Connections.
/// Later packages add Settings to the sidebar.
struct RootView: View {
    let controller: ConversationController
    let library: LibraryStore
    let connections: ConnectionManager
    @Bindable var navigation: AppNavigation

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var wasCompact: Bool?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(controller: controller, navigation: navigation)
                .navigationSplitViewColumnWidth(
                    min: DS.Layout.sidebarMinWidth,
                    ideal: DS.Layout.sidebarIdealWidth,
                    max: DS.Layout.sidebarMaxWidth
                )
        } detail: {
            switch navigation.section {
            case .chat:
                ChatView(controller: controller)
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
                    Label("New chat", systemImage: "square.and.pencil")
                }
                // ⌘N itself is the File > New Chat command, which does the same thing.
                .help("Start a new chat (⌘N)")
                .accessibilityLabel("New chat")
                .accessibilityHint("Clears the conversation and starts fresh")
            }
        }
        .environment(library)
        .environment(navigation)
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
        .task { controller.prewarmIfReady() }
        .task { await library.load() }
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

/// Sidebar rows: New chat, the current conversation (once there is one), My files and Connections.
/// Conversations are not stored yet, so there is no Recent list to show.
struct SidebarView: View {
    let controller: ConversationController
    @Bindable var navigation: AppNavigation

    private enum Item: Hashable {
        case newChat
        case current
        case files
        case connections
    }

    var body: some View {
        List(selection: selection) {
            Section {
                Label("New chat", systemImage: "square.and.pencil")
                    .tag(Item.newChat)
                    .accessibilityLabel("New chat")
                    .accessibilityHint("Clears the conversation and starts fresh")
                if controller.hasConversation {
                    Label(controller.conversationTitle, systemImage: "bubble.left")
                        .lineLimit(1)
                        .tag(Item.current)
                        .accessibilityLabel("Current conversation: \(controller.conversationTitle)")
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
    }

    private var selection: Binding<Item?> {
        Binding(
            get: {
                switch navigation.section {
                case .files: .files
                case .connections: .connections
                case .chat: controller.hasConversation ? .current : .newChat
                }
            },
            set: { item in
                switch item {
                case .newChat:
                    if controller.hasConversation { controller.newChat() }
                    navigation.section = .chat
                case .current:
                    navigation.section = .chat
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
