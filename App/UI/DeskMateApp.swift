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
    @State private var library: LibraryStore
    @State private var controller: ConversationController
    @State private var connections: ConnectionManager
    @State private var navigation = AppNavigation()

    init() {
        WindowLayoutMigration.run()
        let library = LibraryStore()
        _library = State(initialValue: library)
        _controller = State(initialValue: ConversationController(engine: SystemModelEngine(library: library)))

        // Reads the saved connection list. Nothing is sent over the network: every connection starts disconnected.
        let connections = ConnectionManager()
        connections.restore()
        _connections = State(initialValue: connections)
        AppDelegate.connections = connections
    }

    var body: some Scene {
        Window("DeskMate", id: "main") {
            RootView(controller: controller, library: library, connections: connections, navigation: navigation)
                .tint(Color.dmBrandFill)
        }
        .defaultSize(width: DS.Layout.windowDefaultWidth, height: DS.Layout.windowDefaultHeight)
        .commands { ConversationCommands(controller: controller, navigation: navigation) }
    }
}

/// Forgets split-view widths that an earlier build saved. SwiftUI restores a saved sidebar width over the
/// ideal width of its column, so a width saved while the ideal was larger kept the sidebar wider than designed.
/// Runs once per layout version; after that, a width the person drags the sidebar to is kept again.
enum WindowLayoutMigration {
    /// Raise when a change to the window columns should discard widths saved by older builds.
    static let version = 2
    private static let versionKey = "DeskMateWindowLayoutVersion"

    static func run(defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: versionKey) < version else { return }
        for key in defaults.dictionaryRepresentation().keys where key.contains("SplitView") {
            defaults.removeObject(forKey: key)
        }
        defaults.set(version, forKey: versionKey)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once by `DeskMateApp` so quitting can close live connections.
    static var connections: ConnectionManager?

    /// Longest quitting waits for connections to close. A service that does not answer must not hold the app open.
    private static let shutdownGrace: Duration = .seconds(2)

    private var awaitingShutdown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Makes `swift run` (an unbundled executable) behave like a normal foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Closes open connections (which also stops in-flight requests) before quitting, for at most two seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager = Self.connections,
            manager.statuses.values.contains(where: { $0.isConnected || $0.isBusy })
        else { return .terminateNow }
        awaitingShutdown = true
        Task { @MainActor in
            await manager.disconnectAll()
            self.finishShutdown()
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.shutdownGrace)
            self.finishShutdown()
        }
        return .terminateLater
    }

    private func finishShutdown() {
        guard awaitingShutdown else { return }
        awaitingShutdown = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}

struct ConversationCommands: Commands {
    let controller: ConversationController
    let navigation: AppNavigation

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                controller.newChat()
                navigation.section = .chat
            }
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
