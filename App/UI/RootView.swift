import AppKit
import DeskMateCore
import SwiftUI

/// Main window: a restrained sidebar and the conversation or My files.
/// Later packages add Connections and Settings to the sidebar.
struct RootView: View {
    let controller: ConversationController
    let library: LibraryStore
    @Bindable var navigation: AppNavigation

    var body: some View {
        NavigationSplitView {
            SidebarView(controller: controller, navigation: navigation)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            switch navigation.section {
            case .chat:
                ChatView(controller: controller)
                    .inspector(isPresented: viewerIsPresented) {
                        SourceViewer(navigation: navigation)
                            .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
                    }
                    .navigationTitle(controller.conversationTitle)
                    .navigationSubtitle(controller.readiness.isReady ? "Runs on your Mac" : controller.readiness.statusLabel)
            case .files:
                LibraryView()
                    .navigationTitle("My files")
                    .navigationSubtitle("Stays on your Mac")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    startNewChat()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .help("Start a new chat (⌘N)")
                .accessibilityLabel("New chat")
            }
        }
        .environment(library)
        .environment(navigation)
        .frame(minWidth: 640, minHeight: 520)
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

    private func startNewChat() {
        controller.newChat()
        navigation.section = .chat
    }
}

struct SidebarView: View {
    let controller: ConversationController
    @Bindable var navigation: AppNavigation

    var body: some View {
        List(selection: selection) {
            Section {
                Button {
                    controller.newChat()
                    navigation.section = .chat
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                        .font(.dmBody)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New chat")
                .accessibilityHint("Clears the conversation and starts fresh")
            }
            Section("Current") {
                Label(controller.conversationTitle, systemImage: "bubble.left")
                    .font(.dmBody)
                    .lineLimit(1)
                    .tag(AppSection.chat)
                    .accessibilityLabel("Current conversation: \(controller.conversationTitle)")
            }
            Section("Library") {
                Label("My files", systemImage: "folder")
                    .font(.dmBody)
                    .tag(AppSection.files)
                    .accessibilityLabel("My files")
                    .accessibilityHint("Shows the folders and files DeskMate may read")
            }
        }
        .listStyle(.sidebar)
    }

    private var selection: Binding<AppSection?> {
        Binding(
            get: { navigation.section },
            set: { if let section = $0 { navigation.section = section } }
        )
    }
}
