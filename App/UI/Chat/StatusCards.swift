import AppKit
import DeskMateCore
import SwiftUI

enum SystemSettingsLink {
    /// Opens System Settings. It never changes a setting itself.
    @MainActor
    static func open() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Persistent model status shown while the on-device model cannot answer. The draft stays in the composer.
/// A compact inline notice (see `DMNotice`); when the model is ready nothing is shown here, and the window
/// subtitle says "Runs on your Mac".
struct ReadinessBanner: View {
    let controller: ConversationController
    @State private var highlighted = false

    var body: some View {
        let readiness = controller.readiness
        DMNotice(
            symbol: symbol(for: readiness),
            tint: .dmWarning,
            title: readiness.title,
            message: readiness.message,
            highlighted: highlighted
        ) {
            if readiness.suggestsSystemSettings {
                Button("Open System Settings") { SystemSettingsLink.open() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Check again") { controller.refreshReadiness() }
                .buttonStyle(.bordered)
        }
        .accessibilityLabel("Model status: \(readiness.title)")
        .onChange(of: controller.readinessNudge) {
            // The person tried to send while the model is unavailable: draw attention and announce.
            Announcer.post("\(readiness.title). Your message is kept.")
            highlighted = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                highlighted = false
            }
        }
        .dmAnimation(value: highlighted)
    }

    private func symbol(for readiness: ModelReadiness) -> String {
        switch readiness {
        case .ready: "checkmark.circle"
        case .appleIntelligenceOff: "sparkles"
        case .modelNotReady: "arrow.down.circle"
        case .englishUnsupported: "globe"
        case .deviceNotEligible, .unknown: "exclamationmark.triangle"
        }
    }
}

/// A recoverable problem with its next steps. Tone is calm; the question is never lost.
struct FailureCard: View {
    let failure: ChatFailure
    let controller: ConversationController

    var body: some View {
        DMNotice(
            symbol: "exclamationmark.triangle",
            tint: .dmWarning,
            title: failure.title,
            message: failure.message,
            actionsBelow: true,
            onDismiss: { controller.dismissFailure() }
        ) {
            ForEach(Array(failure.actions.enumerated()), id: \.offset) { index, action in
                if index == 0 {
                    Button(label(for: action)) { run(action) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(label(for: action)) { run(action) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .accessibilityLabel("Problem: \(failure.title)")
        .onAppear { Announcer.post("\(failure.title). \(failure.message)") }
    }

    private func run(_ action: ChatFailureAction) {
        if action == .openSystemSettings {
            SystemSettingsLink.open()
        } else {
            controller.perform(action)
        }
    }

    private func label(for action: ChatFailureAction) -> String {
        switch action {
        case .retry: "Try again"
        case .editQuestion: "Edit question"
        case .newChat: "New chat"
        case .newChatKeepingQuestion: "New chat with my message"
        case .checkAgain: "Check again"
        case .openSystemSettings: "Open System Settings"
        }
    }
}
