import AppKit
import DeskMateCore
import DeskMateShared
import Observation
import SwiftUI
import WidgetKit

/// Connects the app to the desktop: the widget's links, the global shortcut, the menu bar, the compact panel and
/// the widget's snapshot. It owns no conversation of its own. Everything it opens shows the one shared
/// `ConversationController`, so the panel and the main window are two views of the same chat.
@MainActor
@Observable
final class DesktopAccess {
    let controller: ConversationController
    let history: ConversationHistory
    let library: LibraryStore
    let approvals: ToolApprovalBroker
    let shortcuts: ShortcutSettings
    let mainNavigation: AppNavigation
    /// The panel has no sidebar, so its own navigation state only records a wish to go somewhere that needs the main window.
    let panelNavigation = AppNavigation()

    private(set) var panel: CompactPanelController!
    /// A short, plain message about the last request, shown in the panel until dismissed.
    var routeNotice: String?
    /// Set by the Ask my files link: the panel shows how to point DeskMate at files.
    var showsFilesGuidance = false

    @ObservationIgnored private let hotKey = GlobalHotKey()
    @ObservationIgnored private var publisher: WidgetSnapshotPublisher?
    @ObservationIgnored private weak var mainWindow: NSWindow?
    @ObservationIgnored private var openMainWindowAction: (() -> Void)?
    @ObservationIgnored private var lastLink: (url: URL, at: Date)?
    @ObservationIgnored private let launchedAt = Date()
    @ObservationIgnored private var hideMainWindowWhenItAppears = false
    @ObservationIgnored private var started = false

    /// A link that arrives this soon after launch started the app, so the main window is not wanted behind the panel.
    private static let launchLinkWindow: TimeInterval = 6

    init(
        controller: ConversationController,
        history: ConversationHistory,
        library: LibraryStore,
        approvals: ToolApprovalBroker,
        shortcuts: ShortcutSettings,
        mainNavigation: AppNavigation
    ) {
        self.controller = controller
        self.history = history
        self.library = library
        self.approvals = approvals
        self.shortcuts = shortcuts
        self.mainNavigation = mainNavigation
        self.panel = CompactPanelController { [unowned self] in self.makePanelContent() }
    }

    private func makePanelContent() -> NSView {
        let hosting = NSHostingView(rootView: CompactPanelView(desktop: self))
        // The panel keeps the size the person gave it; SwiftUI never resizes the window to fit its content.
        hosting.sizingOptions = []
        return hosting
    }

    // MARK: Start

    /// Registers the shortcut, starts the widget snapshot, and begins watching for waiting approvals. Once per launch.
    func start() {
        guard !started else { return }
        started = true
        panel.escapeStopsWork = { [controller] in controller.isBusy }
        panel.mustStayVisible = { [approvals] in approvals.pending != nil }
        hotKey.onPress = { [weak self] in self?.panel.toggle(trigger: .shortcut) }
        applyShortcut()
        watchShortcutChoice()
        watchApprovals()

        let publisher = WidgetSnapshotPublisher(
            controller: controller,
            history: history,
            store: WidgetSnapshotStore.appGroup(),
            reload: { WidgetCenter.shared.reloadAllTimelines() }
        )
        publisher.start()
        self.publisher = publisher
    }

    // MARK: Links from the widget and elsewhere

    /// Handles a link. Anything that is not exactly one of DeskMate's own routes is ignored.
    func open(url: URL) {
        guard let route = DeskMateRoute(url: url) else { return }
        // The same link can arrive through both the app delegate and the scene; it is acted on once.
        if let lastLink, lastLink.url == url, Date().timeIntervalSince(lastLink.at) < 0.75 { return }
        lastLink = (url, Date())
        handle(route, trigger: .widget)
    }

    func handle(_ route: DeskMateRoute, trigger: OpenTrigger) {
        routeNotice = nil
        keepMainWindowAwayIfThisLaunchedTheApp()
        switch route {
        case .ask:
            showsFilesGuidance = false
        case .new:
            showsFilesGuidance = false
            if controller.isBusy {
                routeNotice = "DeskMate is still writing an answer. Stop it or wait for it to finish, then start a new chat."
            } else if controller.hasConversation {
                controller.newChat()
            }
            panelNavigation.section = .chat
        case .files:
            showsFilesGuidance = true
        case .resume(let id):
            showsFilesGuidance = false
            if controller.isBusy, id != controller.conversationID {
                routeNotice = "DeskMate is still writing an answer. Stop it or wait for it to finish, then resume that conversation."
            } else {
                Task { await resume(id) }
            }
        }
        panel.show(trigger: trigger)
        if let message = routeNotice { Announcer.post(message) }
    }

    private func resume(_ id: UUID) async {
        await controller.open(id)
        guard controller.hasConversation, controller.conversationID == id else {
            routeNotice = "That conversation is no longer available."
            Announcer.post("That conversation is no longer available.")
            return
        }
        panel.focusComposer()
    }

    // MARK: Main window

    /// Records the main window the first time it appears, so the panel can bring it forward and, when a link
    /// launched the app, keep it out of the way.
    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        if hideMainWindowWhenItAppears, Date().timeIntervalSince(launchedAt) < Self.launchLinkWindow * 2 {
            hideMainWindowWhenItAppears = false
            window.orderOut(nil)
        }
    }

    func setOpenMainWindowAction(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    /// A widget link that started the app is for the panel. SwiftUI opens the main window at launch regardless, so it
    /// is hidden again rather than left behind the panel. Opening DeskMate later brings it back.
    private func keepMainWindowAwayIfThisLaunchedTheApp() {
        guard Date().timeIntervalSince(launchedAt) < Self.launchLinkWindow, !panel.isVisible else { return }
        if let mainWindow {
            mainWindow.orderOut(nil)
        } else {
            hideMainWindowWhenItAppears = true
        }
    }

    func showMainWindow() {
        hideMainWindowWhenItAppears = false
        NSApp.activate()
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
    }

    /// Clicking the Dock icon with only the panel on screen: bring the main window back. Returns whether it did.
    func reopen() -> Bool {
        guard mainWindow?.isVisible != true else { return false }
        showMainWindow()
        return true
    }

    /// The panel's Open in main window: the same conversation, at full size. A place only the main window has
    /// (My files, Connections, the source viewer) is carried over.
    func expandToMainWindow() {
        if let citation = panelNavigation.viewedCitation {
            mainNavigation.show(citation)
            panelNavigation.closeViewer()
        }
        if panelNavigation.section != .chat {
            mainNavigation.section = panelNavigation.section
            panelNavigation.section = .chat
        } else {
            mainNavigation.section = .chat
        }
        panel.hide()
        showMainWindow()
    }

    var mainWindowIsShowing: Bool { mainWindow?.isVisible == true }

    // MARK: Shortcut

    /// Registers the saved shortcut with the system and records what happened.
    func applyShortcut() {
        guard let shortcut = shortcuts.shortcut else {
            hotKey.unregister()
            shortcuts.registration = .off
            return
        }
        shortcuts.registration = hotKey.register(shortcut)
    }

    /// Changes the shortcut. When the system refuses the new one, the old one keeps working and the reason is kept for
    /// Settings to show. Returns whether the new shortcut is now active.
    @discardableResult
    func changeShortcut(to new: Shortcut) -> Bool {
        let previous = shortcuts.shortcut
        let result = hotKey.register(new)
        if result == .registered {
            shortcuts.choose(new)
            shortcuts.registration = .registered
            return true
        }
        shortcuts.rejection = ShortcutSettings.Rejection(shortcut: new, reason: result)
        if let previous {
            shortcuts.registration = hotKey.register(previous)
        } else {
            hotKey.unregister()
        }
        return false
    }

    func turnOffShortcut() {
        shortcuts.turnOff()
        hotKey.unregister()
    }

    func restoreStandardShortcut() {
        shortcuts.restoreStandard()
        applyShortcut()
    }

    /// Another window (Settings) may change the choice; the registration follows it.
    private func watchShortcutChoice() {
        withObservationTracking {
            _ = shortcuts.shortcut
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Registering is done by the methods that change the choice; this only covers a change from elsewhere.
                if self.shortcuts.shortcut == nil, self.shortcuts.registration != .off { self.applyShortcut() }
                self.watchShortcutChoice()
            }
        }
    }

    // MARK: Approvals

    /// A tool call waits for a person's answer, and the answer is only possible where the sheet is visible. If nothing
    /// of DeskMate is on screen, the panel comes up (without taking focus) and the Dock icon asks for attention.
    private func watchApprovals() {
        withObservationTracking {
            _ = approvals.pending?.id
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.approvalMayNeedASurface()
                self.watchApprovals()
            }
        }
    }

    private func approvalMayNeedASurface() {
        guard approvals.pending != nil else { return }
        if !panel.isVisible, !mainWindowIsShowing {
            panel.show(trigger: .link, activate: false)
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    // MARK: Menu bar

    /// Generic, content-free status for the menu bar.
    var statusLine: String {
        if controller.isBusy { return "Writing an answer…" }
        return controller.readiness.isReady ? "On-device model ready" : controller.readiness.statusLabel
    }
}
