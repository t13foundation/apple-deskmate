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
struct ReadinessBanner: View {
    let controller: ConversationController
    @State private var highlighted = false

    var body: some View {
        let readiness = controller.readiness
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            Image(systemName: symbol(for: readiness))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.dmAccent)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text(readiness.title)
                    .font(.dmSection)
                Text(readiness.message)
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Spacing.s) {
                    if readiness.suggestsSystemSettings {
                        Button("Open System Settings") { SystemSettingsLink.open() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Check again") { controller.refreshReadiness() }
                        .buttonStyle(.bordered)
                }
                .controlSize(.regular)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.l)
        .dmSurface(radius: DS.Radius.surface, highlighted: highlighted)
        .accessibilityElement(children: .contain)
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
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text(failure.title)
                    .font(.dmSection)
                Text(failure.message)
                    .font(.dmBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !failure.actions.isEmpty {
                    HStack(spacing: DS.Spacing.s) {
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
                }
            }
            Spacer(minLength: 0)

            Button {
                controller.dismissFailure()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Dismiss")
            .accessibilityLabel("Dismiss message")
        }
        .padding(DS.Spacing.l)
        .dmSurface(radius: DS.Radius.surface, emphasis: .orange)
        .accessibilityElement(children: .contain)
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
