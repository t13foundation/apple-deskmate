import AppKit
import DeskMateCore
import SwiftUI

/// The conversation surface: readiness banner, transcript (or the empty state), problem card, composer.
struct ChatView: View {
    let controller: ConversationController

    var body: some View {
        VStack(spacing: 0) {
            if !controller.readiness.isReady {
                ReadinessBanner(controller: controller)
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
        .onChange(of: controller.phase) { old, new in
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
