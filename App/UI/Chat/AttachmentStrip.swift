import DeskMateCore
import Observation
import SwiftUI

/// Asks for files to attach to the question being written. Buttons only set `request`; the chat view presents the
/// system chooser as a sheet (see `attachFilePicker`), so no button action ever runs a modal panel itself.
@MainActor
@Observable
final class AttachPicker {
    var request: FileRequest?

    func chooseAndAttach(to controller: ConversationController) {
        let remaining = controller.attachmentLimit - controller.attachments.count
        guard remaining > 0 else { return }
        request = .attachments(remaining: remaining)
    }

    func startComparison(with controller: ConversationController) {
        controller.beginComparison()
        chooseAndAttach(to: controller)
    }
}

extension View {
    /// Presents the attach chooser for `controller` as a sheet on this window and provides `AttachPicker` to
    /// the views below. Apply it once, to a view that stays in the hierarchy.
    func attachFilePicker(controller: ConversationController) -> some View {
        modifier(AttachFilePickerModifier(controller: controller))
    }
}

private struct AttachFilePickerModifier: ViewModifier {
    let controller: ConversationController
    @State private var picker = AttachPicker()

    func body(content: Content) -> some View {
        @Bindable var picker = picker
        content
            .environment(picker)
            .fileChooser($picker.request) { urls in
                // Reading the files runs off the main actor inside the controller; the extra files beyond the
                // limit are refused there with a notice.
                await controller.attach(urls: urls)
            }
    }
}

/// The files attached to the question (at most five), the comparison state, and why a file was not attached.
/// Drawn inside the composer surface, above the field.
struct AttachmentStrip: View {
    let controller: ConversationController
    @Environment(AttachPicker.self) private var picker

    var body: some View {
        if isVisible {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                if controller.isComparing {
                    HStack(spacing: DS.Spacing.s) {
                        Label(comparisonText, systemImage: "rectangle.split.2x1")
                            .font(.dmCaption.weight(.semibold))
                            .foregroundStyle(Color.dmBrandText)
                        Button("Choose files…") { picker.chooseAndAttach(to: controller) }
                            .buttonStyle(.borderless)
                            .font(.dmCaption)
                            .disabled(!controller.canAttachMore)
                        Spacer(minLength: 0)
                        Button("Cancel comparison") { controller.endComparison() }
                            .buttonStyle(.borderless)
                            .font(.dmCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !controller.attachments.isEmpty || controller.isLoadingAttachments {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Spacing.s) {
                            ForEach(controller.attachments) { attachment in
                                chip(attachment)
                            }
                            if controller.isLoadingAttachments {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Reading the file")
                            }
                            Text("\(controller.attachments.count) of \(controller.attachmentLimit)")
                                .font(.dmCaption)
                                .foregroundStyle(.secondary)
                        }
                        }
                }
                ForEach(Array(controller.attachmentNotices.enumerated()), id: \.offset) { _, notice in
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.dmCaption)
                        .foregroundStyle(Color.dmWarning)
                }
                if !controller.attachmentNotices.isEmpty {
                    Button("Dismiss") { controller.dismissAttachmentNotices() }
                        .buttonStyle(.borderless)
                        .font(.dmCaption)
                }
            }
            .padding(.horizontal, DS.Spacing.s)
            .padding(.top, DS.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Attached files")
        }
    }

    private var isVisible: Bool {
        controller.isComparing || !controller.attachments.isEmpty || !controller.attachmentNotices.isEmpty || controller.isLoadingAttachments
    }

    private var comparisonText: String {
        let chosen = controller.attachments.count
        return chosen == 2 ? "Comparing two documents" : "Comparing: choose two documents (\(chosen) of 2)"
    }

    private func chip(_ attachment: Attachment) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "doc.text")
                .font(.dmCaption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(attachment.fileName)
                .font(.dmCaption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: DS.Layout.readingWidth / 3)
            Button {
                controller.removeAttachment(attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove \(attachment.fileName)")
            .accessibilityLabel("Remove \(attachment.fileName)")
        }
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, DS.Spacing.xs)
        .background(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: DS.Stroke.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attached: \(attachment.fileName)")
    }
}
