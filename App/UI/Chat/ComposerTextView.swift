import AppKit
import SwiftUI

/// Multi-line message field. Return sends, Shift+Return (or Option+Return) inserts a new line,
/// Escape and Command+Period cancel generation. Grows with its text up to `maxLines`, then scrolls.
///
/// Layout contract (this is what keeps the field from crashing the app):
/// - SwiftUI measures the field with a separate, detached TextKit stack (`ComposerHeightMeter`).
///   `sizeThatFits` never touches the live text view or its text container.
/// - The live text view never resizes itself. It is neither vertically nor horizontally resizable and its
///   container does not track its width, so AppKit never changes its frame from inside a draw pass.
///   `ComposerScrollView` owns the document size and updates it only from `layout()`, after the text
///   changes, and after storage edits that bypass the delegate (for example an Accessibility set-value).
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Changing this value moves keyboard focus into the field.
    var focusToken: Int
    var maxLines = 8
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerScrollView {
        let scrollView = ComposerScrollView()
        let textView = scrollView.textView
        let coordinator = context.coordinator
        textView.delegate = coordinator
        textView.placeholder = placeholder
        textView.string = text
        textView.setAccessibilityLabel("Message")
        textView.setAccessibilityPlaceholderValue(placeholder)
        textView.setAccessibilityHelp("Press Return to send. Press Shift Return for a new line.")
        coordinator.lastFocusToken = focusToken
        coordinator.lastSyncedText = text
        scrollView.onStorageEdit = { [weak coordinator] string in coordinator?.viewTextChanged(string) }
        return scrollView
    }

    func updateNSView(_ scrollView: ComposerScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let textView = scrollView.textView
        textView.placeholder = placeholder
        if textView.string != text {
            // External change (message sent, starter inserted, New chat). Keep the caret at the end.
            // Layout is not forced here: the scroll view lays the text out in its own layout pass,
            // which always runs before display.
            coordinator.lastSyncedText = text
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.needsDisplay = true
            scrollView.needsLayout = true
        } else {
            coordinator.lastSyncedText = text
        }
        if coordinator.lastFocusToken != focusToken {
            coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerScrollView, context: Context) -> CGSize? {
        let proposed = proposal.width ?? 400
        let width = proposed.isFinite ? max(proposed, 1) : 400
        return CGSize(width: width, height: nsView.fittingHeight(for: text, width: width, maxLines: maxLines))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var lastFocusToken = 0
        /// The last text known to be identical in the view and in the binding.
        var lastSyncedText = ""

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            viewTextChanged(textView.string)
        }

        /// Pushes an edit made on the view side into the binding. A string equal to `lastSyncedText`
        /// is not an edit (it is a pending update in the other direction) and must not overwrite the binding.
        func viewTextChanged(_ string: String) {
            guard string != lastSyncedText else { return }
            lastSyncedText = string
            if parent.text != string { parent.text = string }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if textView.hasMarkedText() { return false } // let an input method finish composing
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                if modifiers.contains(.shift) || modifiers.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.insertLineBreak(_:)):
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// Measures wrapped text height with a private TextKit stack that is never attached to a view.
/// Used from SwiftUI's `sizeThatFits`, where the live text view must not be touched.
@MainActor
final class ComposerHeightMeter {
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container: NSTextContainer
    private let font: NSFont
    private var cache: (text: String, width: CGFloat, height: CGFloat)?

    init(font: NSFont, lineFragmentPadding: CGFloat) {
        self.font = font
        container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = lineFragmentPadding
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    var lineHeight: CGFloat { layoutManager.defaultLineHeight(for: font) }

    /// Height of `text` wrapped to `width`, without insets. At least one line.
    func height(of text: String, width: CGFloat) -> CGFloat {
        if let cache, cache.width == width, cache.text == text { return cache.height }
        container.containerSize = NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        layoutManager.ensureLayout(for: container)
        var used = layoutManager.usedRect(for: container).height
        let extra = layoutManager.extraLineFragmentRect
        if !extra.isEmpty { used = max(used, extra.maxY) }
        let height = max(used, lineHeight)
        cache = (text, width, height)
        return height
    }
}

final class ComposerScrollView: NSScrollView {
    let textView = PlaceholderTextView(usingTextLayoutManager: false)
    /// Called (on the next main-queue turn) after character edits, including ones that bypass the delegate.
    var onStorageEdit: ((String) -> Void)?

    private static let font = NSFont.systemFont(ofSize: 14)
    private static let verticalInset: CGFloat = 4
    private let meter: ComposerHeightMeter
    private var isSyncingDocumentLayout = false
    private var storageEditPending = false

    init() {
        meter = ComposerHeightMeter(font: Self.font, lineFragmentPadding: 5)
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay

        textView.font = Self.font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 0, height: Self.verticalInset)
        // The text view must never resize itself: AppKit does that lazily from inside drawRect, and a frame
        // change there rewrites autoresizing constraints during the display pass, which throws.
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 5
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: meter.lineHeight + Self.verticalInset * 2)
        documentView = textView

        if let storage = textView.textStorage {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(composerStorageDidProcessEditing(_:)),
                name: NSTextStorage.didProcessEditingNotification,
                object: storage
            )
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Height the field wants for `text` at `width`, clamped to one line ... `maxLines` lines. Pure measurement.
    func fittingHeight(for text: String, width: CGFloat, maxLines: Int) -> CGFloat {
        let inset = Self.verticalInset * 2
        let containerWidth = max(width - textView.textContainerInset.width * 2, 1)
        let lineHeight = meter.lineHeight
        let used = meter.height(of: text, width: containerWidth)
        let minimum = lineHeight + inset
        let maximum = lineHeight * CGFloat(max(maxLines, 1)) + inset
        return min(max(used + inset, minimum), maximum).rounded(.up)
    }

    override func layout() {
        super.layout()
        syncDocumentLayout()
    }

    /// Lays the text out at the current width and sizes the document view to it. Runs outside the draw pass
    /// (layout pass, event handling, or a main-queue turn), so drawing never has layout work left to do.
    func syncDocumentLayout() {
        guard !isSyncingDocumentLayout else { return }
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else { return }
        let clip = contentSize
        guard clip.width >= 1 else { return } // not laid out yet; layout() will call again
        isSyncingDocumentLayout = true
        defer { isSyncingDocumentLayout = false }

        let inset = textView.textContainerInset
        let containerWidth = max(clip.width - inset.width * 2, 1)
        if abs(container.containerSize.width - containerWidth) > 0.5 {
            container.containerSize = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: container)
        var used = layoutManager.usedRect(for: container).height
        let extra = layoutManager.extraLineFragmentRect
        if !extra.isEmpty { used = max(used, extra.maxY) }

        let frame = NSRect(
            x: 0, y: 0,
            width: clip.width,
            height: max((used + inset.height * 2).rounded(.up), clip.height)
        )
        if textView.frame != frame { textView.frame = frame }

        // When the field has just grown to fit its text, drop any leftover scroll offset.
        let bounds = contentView.bounds
        let constrained = contentView.constrainBoundsRect(bounds)
        if constrained.origin != bounds.origin {
            contentView.scroll(to: constrained.origin)
            reflectScrolledClipView(contentView)
        }
    }

    @MainActor @objc private func composerStorageDidProcessEditing(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters),
              !storageEditPending else { return }
        storageEditPending = true
        // Not synchronous: the layout manager has not processed this edit yet.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.storageEditPending = false
            self.syncDocumentLayout()
            self.onStorageEdit?(self.textView.string)
        }
    }
}

final class PlaceholderTextView: NSTextView {
    var placeholder = "" {
        didSet { if oldValue != placeholder { needsDisplay = true } }
    }
    private var didTakeInitialFocus = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        // Typing and pasting: settle layout and document size now, in the event, not later in a draw.
        (enclosingScrollView as? ComposerScrollView)?.syncDocumentLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Focus lands in the composer when the window first appears.
        guard !didTakeInitialFocus, window != nil else { return }
        didTakeInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}
