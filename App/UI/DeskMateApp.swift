import AppKit
import DeskMateCore
import SwiftUI

/// Entry point. Headless diagnostic commands run without any UI and exit; otherwise the app starts.
@main
enum DeskMateLauncher {
    @MainActor
    static func main() {
        if let command = HeadlessCommand(arguments: Array(CommandLine.arguments.dropFirst())) {
            Task {
                let code = await command.run()
                exit(code)
            }
            dispatchMain()
        }
        DeskMateApp.main()
    }
}

struct DeskMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = ConversationController(engine: SystemModelEngine())

    var body: some Scene {
        Window("DeskMate", id: "main") {
            RootView(controller: controller)
                .tint(Color.dmAccent)
        }
        .defaultSize(width: 980, height: 720)
        .commands { ConversationCommands(controller: controller) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Makes `swift run` (an unbundled executable) behave like a normal foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ConversationCommands: Commands {
    let controller: ConversationController

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { controller.newChat() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Conversation") {
            Button("Stop Generating") { controller.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!controller.isBusy)
            Button("Try Last Answer Again") { controller.retry() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!controller.canRetry)
        }
    }
}
