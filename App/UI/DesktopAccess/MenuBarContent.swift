import AppKit
import DeskMateCore
import SwiftUI

/// The menu bar menu. It stays available whatever happens to the keyboard shortcut. The status line is generic:
/// readiness only, never anything from a conversation.
struct MenuBarContent: View {
    let desktop: DesktopAccess
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Ask DeskMate") { desktop.handle(.ask, trigger: .menuBar) }
        Button("New chat") { desktop.handle(.new, trigger: .menuBar) }
        Button("Open DeskMate") {
            desktop.setOpenMainWindowAction { openWindow(id: "main") }
            desktop.showMainWindow()
        }
        Divider()
        Text(desktop.statusLine)
        if let shortcut = desktop.shortcuts.shortcut {
            Text(desktop.shortcuts.problem == nil ? "Shortcut: \(shortcut.display)" : "Shortcut unavailable. See Settings.")
        }
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("Quit DeskMate") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

/// Hands the main window to `DesktopAccess` once it exists, so the panel can bring it forward or keep it away.
struct MainWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
    }
}
