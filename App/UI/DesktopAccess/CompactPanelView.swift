import AppKit
import DeskMateCore
import SwiftUI

/// The content of the compact panel: a slim header, the same chat the main window shows, and the same composer.
/// Nothing here keeps its own conversation; it reads and drives the one shared `ConversationController`.
struct CompactPanelView: View {
    let desktop: DesktopAccess

    var body: some View {
        let controller = desktop.controller
        VStack(spacing: 0) {
            PanelHeader(desktop: desktop)
            Divider()
            if let notice = desktop.routeNotice {
                DMNotice(
                    symbol: "info.circle",
                    tint: .dmBrandText,
                    title: notice,
                    onDismiss: { desktop.routeNotice = nil }
                )
                .accessibilityLabel("Notice: \(notice)")
                .padding(.horizontal, DS.Spacing.m)
                .padding(.top, DS.Spacing.m)
                .transition(.opacity)
            }
            if desktop.showsFilesGuidance {
                FilesGuidance(desktop: desktop)
                    .padding(.horizontal, DS.Spacing.m)
                    .padding(.top, DS.Spacing.m)
                    .transition(.opacity)
            }
            ChatView(controller: controller, history: desktop.history)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: DS.Stroke.hairline)
                .allowsHitTesting(false)
        )
        // Buttons in the header and the banner reach the same file chooser the composer uses.
        .attachFilePicker(controller: controller)
        .environment(desktop.library)
        .environment(desktop.panelNavigation)
        .toolApprovalSheet(broker: desktop.approvals)
        // The panel is always the surface that presents the conversation's sheets while it is on screen.
        .environment(\.presentsConversationSheets, true)
        .tint(Color.dmBrandFill)
        .dmAnimation(value: desktop.routeNotice)
        .dmAnimation(value: desktop.showsFilesGuidance)
        // The panel has no sidebar and no source viewer; asking for either hands the conversation to the main window.
        .onChange(of: desktop.panelNavigation.section) { _, section in
            if section != .chat { desktop.expandToMainWindow() }
        }
        .onChange(of: desktop.panelNavigation.viewedCitation != nil) { _, isViewing in
            if isViewing { desktop.expandToMainWindow() }
        }
        .onChange(of: controller.conversationID) { desktop.routeNotice = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("DeskMate assistant")
    }
}

private struct PanelHeader: View {
    let desktop: DesktopAccess

    var body: some View {
        let panel = desktop.panel!
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: "sparkles")
                .font(.dmSection)
                .foregroundStyle(Color.dmBrandText)
                .accessibilityHidden(true)
            Text("DeskMate")
                .font(.dmSection)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DS.Spacing.s)

            headerButton("New chat", symbol: "square.and.pencil", hint: "Clears the conversation and starts fresh") {
                if desktop.controller.hasConversation { desktop.controller.newChat() }
                desktop.routeNotice = nil
                desktop.showsFilesGuidance = false
                desktop.panel.focusComposer()
            }
            headerButton(
                panel.isPinned ? "Unpin" : "Pin",
                symbol: panel.isPinned ? "pin.fill" : "pin",
                hint: panel.isPinned
                    ? "The panel hides again when you switch to another app"
                    : "Keeps the panel above other windows while you work"
            ) {
                panel.setPinned(!panel.isPinned)
            }
            .accessibilityValue(panel.isPinned ? "Pinned" : "Not pinned")
            headerButton("Open in main window", symbol: "arrow.up.left.and.arrow.down.right", hint: "Shows this conversation in the full DeskMate window") {
                desktop.expandToMainWindow()
            }
            headerButton("Close", symbol: "xmark", hint: "Closes the panel. Escape does the same when no answer is being written") {
                panel.hide(returnFocus: true)
            }
        }
        .padding(.horizontal, DS.Spacing.m)
        .frame(height: 44)
        .background(.bar)
    }

    private func headerButton(_ title: String, symbol: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }
}

/// Shown after the Ask my files link: how to point DeskMate at files, without opening anything on its own.
private struct FilesGuidance: View {
    let desktop: DesktopAccess
    @Environment(AttachPicker.self) private var picker

    var body: some View {
        let library = desktop.library
        let hasFiles = library.hasSearchableContent
        DMNotice(
            symbol: "folder",
            tint: .dmBrandText,
            title: hasFiles ? "Ask about your files" : "Choose files for DeskMate",
            message: hasFiles
                ? "Type a question and DeskMate searches the folders and files in My files. You can also attach a file to this one question."
                : "DeskMate only reads what you choose. Attach a file to this question, or add folders and files in My files.",
            actionsBelow: true,
            onDismiss: { desktop.showsFilesGuidance = false }
        ) {
            HStack(spacing: DS.Spacing.m) {
                Button("Attach files…") { picker.chooseAndAttach(to: desktop.controller) }
                    .disabled(!desktop.controller.canAttachMore)
                Button("Open My files") { desktop.panelNavigation.section = .files }
            }
            .controlSize(.small)
        }
        .accessibilityLabel(hasFiles ? "Ask about your files" : "Choose files for DeskMate")
    }
}
