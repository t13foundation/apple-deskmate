import AppKit
import SwiftUI

/// The composer row: a control on each side of the message field.
///
/// The controls are `DS.Layout.controlSize` (32 pt) squares. The field pads itself so that one line is exactly
/// that tall, which puts its text on the same centre line as both controls. As the field grows, the row is
/// bottom aligned, so the controls stay level with the last line, as in Messages.
struct ComposerBar<Attach: View, Action: View>: View {
    @Binding var text: String
    var placeholder: String
    var focusToken: Int
    var onSubmit: () -> Void
    var onCancel: () -> Void
    @ViewBuilder var attach: Attach
    @ViewBuilder var action: Action

    /// Padding above and below the field that lifts a one-line field (line height plus its own 4 pt insets)
    /// to the control size.
    private static var fieldPadding: CGFloat {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: ComposerScrollView.font)
        let oneLine = (lineHeight + ComposerScrollView.verticalInset * 2).rounded(.up)
        return max((DS.Layout.controlSize - oneLine) / 2, 0)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: DS.Spacing.s) {
            attach

            ComposerTextView(
                text: $text,
                placeholder: placeholder,
                focusToken: focusToken,
                onSubmit: onSubmit,
                onCancel: onCancel
            )
            .padding(.vertical, Self.fieldPadding)
            .help("Return sends. Shift+Return adds a new line.")

            action
        }
        .padding(DS.Spacing.s)
    }
}
