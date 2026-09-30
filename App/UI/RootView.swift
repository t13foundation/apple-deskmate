import AppKit
import DeskMateCore
import SwiftUI

/// Main window: a restrained sidebar and the conversation.
/// Later packages add Recent, My files, Connections and Settings to the sidebar.
struct RootView: View {
    let controller: ConversationController

    var body: some View {
        NavigationSplitView {
            SidebarView(controller: controller)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            ChatView(controller: controller)
                .navigationTitle(controller.conversationTitle)
                .navigationSubtitle(controller.readiness.isReady ? "Runs on your Mac" : controller.readiness.statusLabel)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.newChat()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .help("Start a new chat (⌘N)")
                .accessibilityLabel("New chat")
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The person may have just turned Apple Intelligence on in System Settings.
            controller.refreshReadiness()
        }
        .task { controller.prewarmIfReady() }
    }
}

struct SidebarView: View {
    let controller: ConversationController

    var body: some View {
        List(selection: .constant("current")) {
            Section {
                Button {
                    controller.newChat()
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
                    .tag("current")
                    .accessibilityLabel("Current conversation: \(controller.conversationTitle)")
            }
        }
        .listStyle(.sidebar)
    }
}
