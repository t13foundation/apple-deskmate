import AppKit
import Observation
import SwiftUI

/// The compact assistant panel: a borderless floating panel that hosts the same conversation views as the main window.
/// This type owns only the window behaviour (placement, pin, Escape, focus); the conversation itself, its history and
/// its files all stay in the shared `ConversationController`.
///
/// Window rules (docs/design-system.md, "Compact panel and widget"):
/// - Opens in the Space that is active now, about 460 by 560, ready for typing.
/// - Pinned: stays above other apps' windows while they are used, without taking focus from them and without
///   joining full-screen Spaces. Unpinned: an ordinary window that hides when DeskMate is no longer the active app.
/// - Escape closes it, unless an answer is being written (then Escape stops that) or a sheet is open (then the sheet
///   handles it).
@MainActor
@Observable
final class CompactPanelController: NSObject, NSWindowDelegate {
    static let defaultSize = NSSize(width: 460, height: 560)
    static let minimumSize = NSSize(width: 380, height: 440)
    static let pinnedKey = "desktopAccess.panelPinned"
    static let frameKey = "desktopAccess.panelFrame"

    private(set) var isVisible = false
    private(set) var isPinned: Bool

    /// True once the window exists, so the next open is a warm one.
    var isWarm: Bool { panel != nil }
    var window: NSWindow? { panel }

    /// Whether an answer is being written. While it is, Escape stops the answer instead of closing the panel.
    @ObservationIgnored var escapeStopsWork: () -> Bool = { false }
    /// Whether something must stay answerable (a waiting tool approval), so the panel must not hide by itself.
    @ObservationIgnored var mustStayVisible: () -> Bool = { false }
    @ObservationIgnored private var panel: AssistantPanel?
    @ObservationIgnored private let makeContent: () -> NSView
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var escapeMonitor: Any?
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?

    init(defaults: UserDefaults = .standard, makeContent: @escaping () -> NSView) {
        self.defaults = defaults
        self.makeContent = makeContent
        self.isPinned = defaults.bool(forKey: Self.pinnedKey)
        super.init()
    }

    // MARK: Showing and hiding

    /// Shows the panel. `activate: false` shows it without taking focus from the app in use, for something that
    /// needs a person's attention (a waiting tool approval).
    func show(trigger: OpenTrigger, activate: Bool = true) {
        if activate { PanelOpenTiming.begin(trigger: trigger, warm: isWarm) }
        let panel = ensurePanel()
        if !panel.isVisible { place(panel) }
        isVisible = true
        installObservers()
        if activate {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            focusComposer()
            // A warm panel already has its field; a new one takes focus as soon as SwiftUI has put it in the window.
            DispatchQueue.main.async { [weak self] in self?.focusComposer() }
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Hides the panel. With `returnFocus`, DeskMate steps aside when nothing else of it is open, so the app the
    /// person was using gets the keyboard back.
    func hide(returnFocus: Bool = false) {
        guard let panel, isVisible else { return }
        PanelOpenTiming.abandon()
        panel.orderOut(nil)
        isVisible = false
        removeObservers()
        if returnFocus, !NSApp.windows.contains(where: { $0 !== panel && $0.isVisible && $0.canBecomeMain }) {
            NSApp.hide(nil)
        }
    }

    /// The shortcut: closes the panel when it is the thing the person is using, otherwise brings it up.
    func toggle(trigger: OpenTrigger) {
        if isVisible, let panel, panel.isKeyWindow, NSApp.isActive {
            hide(returnFocus: true)
        } else {
            show(trigger: trigger)
        }
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        defaults.set(pinned, forKey: Self.pinnedKey)
        if let panel { apply(pinned: pinned, to: panel) }
    }

    /// Puts the caret in the message field.
    func focusComposer() {
        guard let panel, let field = Self.composerField(in: panel.contentView) else { return }
        if panel.firstResponder !== field { panel.makeFirstResponder(field) } else { PanelOpenTiming.composerReady() }
    }

    // MARK: Window

    private func ensurePanel() -> AssistantPanel {
        if let panel { return panel }
        let panel = AssistantPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "DeskMate Assistant"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.minSize = Self.minimumSize
        panel.isExcludedFromWindowsMenu = true
        // The Space that is active now; deliberately not full-screen Spaces and not every Space.
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.delegate = self
        panel.onComposerFocus = { PanelOpenTiming.composerReady() }
        panel.onCloseRequest = { [weak self] in self?.hide(returnFocus: true) }
        panel.contentView = makeContent()
        panel.setContentSize(Self.defaultSize)
        apply(pinned: isPinned, to: panel)
        self.panel = panel
        return panel
    }

    private func apply(pinned: Bool, to panel: AssistantPanel) {
        panel.isFloatingPanel = pinned
        panel.level = pinned ? .floating : .normal
    }

    /// Keeps the person's position when it is still on the screen they are using; otherwise centres it there,
    /// a little above the middle.
    private func place(_ panel: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        var frame = panel.frame
        if let text = defaults.string(forKey: Self.frameKey) {
            let saved = NSRectFromString(text)
            if saved.width >= Self.minimumSize.width, saved.height >= Self.minimumSize.height {
                frame.size = saved.size
                if visible.intersects(saved) {
                    frame.origin = saved.origin
                    panel.setFrame(Self.clamped(frame, to: visible), display: false)
                    return
                }
            }
        }
        frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2 + visible.height * 0.08)
        panel.setFrame(Self.clamped(frame, to: visible), display: false)
    }

    private static func clamped(_ frame: NSRect, to bounds: NSRect) -> NSRect {
        var result = frame
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
        return result
    }

    private func rememberFrame() {
        guard let panel else { return }
        defaults.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    private static func composerField(in view: NSView?) -> PlaceholderTextView? {
        guard let view else { return nil }
        if let field = view as? PlaceholderTextView { return field }
        for child in view.subviews {
            if let found = composerField(in: child) { return found }
        }
        return nil
    }

    // MARK: Escape and deactivation

    private func installObservers() {
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event) ?? event
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidResignActive() }
            }
        }
    }

    private func removeObservers() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// Escape in the panel: closes it. It is left alone when an answer is being written (the message field turns it
    /// into Stop), when a sheet is open (the sheet's own Escape), and while an input method is composing text.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 53, let panel, event.window === panel,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              panel.attachedSheet == nil,
              !escapeStopsWork()
        else { return event }
        if let text = panel.firstResponder as? NSTextView, text.hasMarkedText() { return event }
        hide(returnFocus: true)
        return nil
    }

    /// An unpinned panel is an ordinary window and goes away when another app is used. A pinned one stays, and so does
    /// anything that is waiting for an answer.
    private func appDidResignActive() {
        guard isVisible, !isPinned, !mustStayVisible() else { return }
        hide()
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) { rememberFrame() }
    func windowDidEndLiveResize(_ notification: Notification) {
        rememberFrame()
        panel?.invalidateShadow()
    }

    func windowWillClose(_ notification: Notification) {
        isVisible = false
        removeObservers()
    }
}

/// A borderless panel that can take keyboard focus. Reports when the message field becomes the first responder, which
/// is the moment the panel is ready for typing.
final class AssistantPanel: NSPanel {
    var onComposerFocus: (() -> Void)?
    var onCloseRequest: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted, responder is PlaceholderTextView { onComposerFocus?() }
        return accepted
    }

    /// Command-W and the Close menu item.
    override func performClose(_ sender: Any?) {
        onCloseRequest?()
    }
}
