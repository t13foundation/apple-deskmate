import AppKit
import SwiftUI

/// Multi-line message field. Return sends, Shift+Return (or Option+Return) inserts a new line,
/// Escape and Command+Period cancel generation. Grows with its text up to `maxLines`, then scrolls.
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
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        textView.string = text
        textView.setAccessibilityLabel("Message")
        textView.setAccessibilityPlaceholderValue(placeholder)
        textView.setAccessibilityHelp("Press Return to send. Press Shift Return for a new line.")
        context.coordinator.lastFocusToken = focusToken
        return scrollView
    }

    func updateNSView(_ scrollView: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        let textView = scrollView.textView
        textView.placeholder = placeholder
        if textView.string != text {
            // External change (message sent, starter inserted, New chat). Keep the caret at the end.
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.needsDisplay = true
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        return CGSize(width: width, height: nsView.fittingHeight(forWidth: width, maxLines: maxLines))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var lastFocusToken = 0

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string { parent.text = textView.string }
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

final class ComposerScrollView: NSScrollView {
    let textView = PlaceholderTextView(usingTextLayoutManager: false)
    private static let font = NSFont.systemFont(ofSize: 14)

    init() {
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
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        documentView = textView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func fittingHeight(forWidth width: CGFloat, maxLines: Int) -> CGFloat {
        guard let container = textView.textContainer, let layout = textView.layoutManager else { return 28 }
        let lineHeight = layout.defaultLineHeight(for: Self.font)
        let inset = textView.textContainerInset.height * 2
        container.containerSize = NSSize(width: max(width, 20), height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        let minimum = lineHeight + inset
        let maximum = lineHeight * CGFloat(maxLines) + inset
        return min(max(used + inset, minimum), maximum).rounded(.up)
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
