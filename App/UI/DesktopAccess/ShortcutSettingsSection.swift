import AppKit
import DeskMateCore
import Observation
import SwiftUI

/// Listens for one key combination while a person is choosing a new shortcut. It sees keys only while recording is on,
/// only inside DeskMate, and keeps nothing but the one combination that is chosen.
@MainActor
@Observable
final class ShortcutRecorder {
    private(set) var isRecording = false
    /// Why the last key press could not be used, in plain words. Cleared when recording starts or succeeds.
    private(set) var hint: String?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var onChoose: ((Shortcut) -> Void)?

    func start(onChoose: @escaping (Shortcut) -> Void) {
        stop()
        self.onChoose = onChoose
        hint = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Only plain values cross into the main actor; the event itself does not.
            let keyCode = UInt32(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            let characters = event.charactersIgnoringModifiers
            let consumed = MainActor.assumeIsolated { self.handle(keyCode: keyCode, flags: flags, characters: characters) }
            return consumed ? nil : event
        }
        Announcer.post("Press the new shortcut. Escape cancels.")
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onChoose = nil
        isRecording = false
    }

    /// Returns whether the key press was used up by the recorder.
    private func handle(keyCode: UInt32, flags rawFlags: UInt, characters: String?) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
        if keyCode == 53, flags.isEmpty {
            stop()
            return true
        }
        var modifiers: Shortcut.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        let name = Shortcut.keyName(forKeyCode: keyCode, characters: characters)
        let candidate = Shortcut(keyCode: keyCode, modifiers: modifiers, keyName: name)
        guard candidate.isUsable else {
            hint = name.isEmpty
                ? "That key can’t be used. Press a letter, number or Space together with Option, Control or Command."
                : "Include Option, Control or Command so the shortcut doesn’t get in the way of typing."
            return true
        }
        let choose = onChoose
        stop()
        hint = nil
        choose?(candidate)
        return true
    }
}

/// The "Keyboard shortcut" section of Settings.
struct ShortcutSettingsSection: View {
    let desktop: DesktopAccess
    @State private var recorder = ShortcutRecorder()

    var body: some View {
        let shortcuts = desktop.shortcuts
        Section("Keyboard shortcut") {
            LabeledContent("Open the assistant") {
                Text(shortcuts.shortcut?.display ?? "Off")
                    .monospaced()
                    .foregroundStyle(shortcuts.shortcut == nil ? .secondary : .primary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Open the assistant")
            .accessibilityValue(shortcuts.shortcut?.spoken ?? "Off")

            HStack(spacing: DS.Spacing.m) {
                if recorder.isRecording {
                    Text("Press the new shortcut…")
                        .foregroundStyle(Color.dmBrandText)
                        .accessibilityLabel("Recording. Press the new shortcut. Escape cancels.")
                    Button("Cancel") { recorder.stop() }
                } else {
                    Button("Change shortcut…") {
                        recorder.start { desktop.changeShortcut(to: $0) }
                    }
                    .accessibilityHint("Then press the keys you want, including Option, Control or Command")
                }
                Button("Use ⌥Space") { desktop.restoreStandardShortcut() }
                    .disabled(shortcuts.shortcut == .standard && shortcuts.problem == nil)
                    .accessibilityLabel("Use Option Space")
                Button("Turn off") { desktop.turnOffShortcut() }
                    .disabled(!shortcuts.isOn)
                    .accessibilityHint("The menu bar icon still opens the assistant")
            }

            if let hint = recorder.hint {
                Label(hint, systemImage: "info.circle")
                    .foregroundStyle(Color.dmWarning)
                    .dmFootnote()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = shortcuts.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.dmWarning)
                    .dmFootnote()
                    .fixedSize(horizontal: false, vertical: true)
                    .onAppear { Announcer.post(problem) }
            }
            Text("Works from any app, and needs no extra permission. The DeskMate icon in the menu bar always opens the assistant too.")
                .dmFootnote()
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { recorder.stop() }
    }
}
