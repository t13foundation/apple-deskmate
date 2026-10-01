import AppKit
import DeskMateCore
import SwiftUI

/// The conversation surface: readiness banner, transcript (or the empty state), problem card, composer.
struct ChatView: View {
    let controller: ConversationController
    let history: ConversationHistory

    var body: some View {
        VStack(spacing: 0) {
            if !controller.readiness.isReady {
                ReadinessBanner(controller: controller)
                    .dmReadingColumn()
                    .padding(.top, DS.Spacing.l)
                    .transition(.opacity)
            }

            if !history.notices.isEmpty {
                HistoryNotice(history: history)
                    .dmReadingColumn()
                    .padding(.top, DS.Spacing.l)
                    .transition(.opacity)
            }

            if controller.saveProblem != nil, !(controller.presentedResultID != nil && controller.currentConversationUnsaved) {
                // While the result sheet is open and shows the same notice, this one is left out so it is not announced twice.
                SaveProblemNotice(controller: controller)
                    .dmReadingColumn()
                    .padding(.top, DS.Spacing.l)
                    .transition(.opacity)
            }

            Group {
                if controller.hasConversation {
                    TranscriptView(controller: controller)
                } else {
                    EmptyStateView(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let failure = controller.failure {
                FailureCard(failure: failure, controller: controller)
                    .dmReadingColumn()
                    .padding(.bottom, DS.Spacing.s)
                    .transition(.opacity)
            }

            if let failure = controller.resultFailure {
                DMNotice(
                    symbol: "exclamationmark.triangle",
                    tint: .dmWarning,
                    title: failure.title,
                    message: failure.message,
                    onDismiss: { controller.dismissResultFailure() }
                )
                .accessibilityLabel("Problem: \(failure.title)")
                .onAppear { Announcer.post("\(failure.title). \(failure.message)") }
                .dmReadingColumn()
                .padding(.bottom, DS.Spacing.s)
                .transition(.opacity)
            }

            ComposerView(controller: controller)
                .dmReadingColumn()
                .padding(.top, DS.Spacing.xs)
                .padding(.bottom, DS.Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .attachFilePicker(controller: controller)
        .dmAnimation(value: controller.readiness.isReady)
        .dmAnimation(value: controller.failure)
        .dmAnimation(value: controller.resultFailure)
        .dmAnimation(value: history.notices)
        .dmAnimation(value: controller.saveProblem)
        .onChange(of: controller.saveProblem) { old, new in
            if old != nil, new == nil { Announcer.post("Saved. The conversation is on your Mac again.") }
        }
        .sheet(isPresented: Binding(
            get: { controller.presentedResultID != nil },
            set: { if !$0 { controller.presentedResultID = nil } }
        )) {
            if let id = controller.presentedResultID {
                ResultSheet(controller: controller, resultID: id)
            }
        }
        .onChange(of: controller.phase) { old, new in
            if old == .creatingResult, new == .idle {
                if let id = controller.presentedResultID, let result = controller.result(id) {
                    Announcer.post("\(result.kind.title) ready")
                }
                return
            }
            guard old != .idle, new == .idle, let last = controller.messages.last, last.role == .assistant else { return }
            switch last.status {
            case .complete: Announcer.post("Answer ready")
            case .stopped: Announcer.post("Generation stopped")
            case .failed: Announcer.post("DeskMate could not finish the answer")
            case .streaming: break
            }
        }
    }
}

/// Saved conversations that could not be read and were moved aside, in plain words. The others are not affected.
struct HistoryNotice: View {
    let history: ConversationHistory

    var body: some View {
        let count = history.notices.count
        DMNotice(
            symbol: "archivebox",
            tint: .dmWarning,
            title: count == 1 ? "A saved conversation was set aside" : "\(count) saved conversations were set aside",
            message: count == 1
                ? history.notices[0]
                : "DeskMate could not read them, so it moved them aside in its Conversations folder and left them unchanged. Your other conversations are not affected.",
            onDismiss: { history.dismissNotices() }
        )
        .accessibilityLabel("Notice: saved conversations set aside")
        .onAppear { Announcer.post("\(count == 1 ? "A saved conversation was" : "\(count) saved conversations were") set aside because it could not be read.") }
    }
}

@MainActor
enum Announcer {
    /// VoiceOver announcement that does not move focus.
    static func post(_ message: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: message,
                NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
