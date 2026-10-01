import Testing
import Foundation
@testable import DeskMateCore

/// The shortcut model: Option+Space by default, a recorded one that survives a restart, off that survives a restart,
/// and a plain explanation when the system says the combination is taken. The Carbon registration itself is not tested.
@MainActor
@Suite struct ShortcutSettingsTests {
    private func isolatedDefaults() -> (UserDefaults, () -> Void) {
        let name = "deskmate-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test func theDefaultIsOptionSpace() {
        let (defaults, cleanUp) = isolatedDefaults()
        defer { cleanUp() }
        let settings = ShortcutSettings(defaults: defaults)
        #expect(settings.shortcut == .standard)
        #expect(settings.shortcut?.display == "⌥Space")
        #expect(settings.shortcut?.spoken == "Option Space")
        #expect(settings.isOn)
    }

    @Test func aChosenShortcutSurvivesARestart() {
        let (defaults, cleanUp) = isolatedDefaults()
        defer { cleanUp() }
        let chosen = Shortcut(keyCode: 40, modifiers: [.command, .option], keyName: "K")
        #expect(ShortcutSettings(defaults: defaults).choose(chosen))
        #expect(ShortcutSettings(defaults: defaults).shortcut == chosen)
        #expect(chosen.display == "⌥⌘K")
    }

    @Test func turningItOffSurvivesARestartAndRestoringBringsBackTheStandardOne() {
        let (defaults, cleanUp) = isolatedDefaults()
        defer { cleanUp() }
        let settings = ShortcutSettings(defaults: defaults)
        settings.choose(Shortcut(keyCode: 40, modifiers: [.control], keyName: "K"))
        settings.turnOff()
        #expect(settings.shortcut == nil)
        #expect(settings.isOn == false)
        #expect(ShortcutSettings(defaults: defaults).shortcut == nil)

        settings.restoreStandard()
        #expect(ShortcutSettings(defaults: defaults).shortcut == .standard)
    }

    @Test func aShortcutThatWouldSwallowOrdinaryTypingIsRefused() {
        let (defaults, cleanUp) = isolatedDefaults()
        defer { cleanUp() }
        let settings = ShortcutSettings(defaults: defaults)
        #expect(settings.choose(Shortcut(keyCode: 0, modifiers: [], keyName: "A")) == false)
        #expect(settings.choose(Shortcut(keyCode: 0, modifiers: [.shift], keyName: "A")) == false)
        #expect(settings.shortcut == .standard, "a refused choice changes nothing")
    }

    @Test func unreadableSavedDataFallsBackToTheStandardShortcut() {
        let (defaults, cleanUp) = isolatedDefaults()
        defer { cleanUp() }
        defaults.set(Data("garbage".utf8), forKey: ShortcutSettings.defaultsKey)
        #expect(ShortcutSettings(defaults: defaults).shortcut == .standard)
        let unusable = try! JSONEncoder().encode(Shortcut(keyCode: 0, modifiers: [], keyName: "A"))
        defaults.set(unusable, forKey: ShortcutSettings.defaultsKey)
        #expect(ShortcutSettings(defaults: defaults).shortcut == .standard)
    }

    @Test func aConflictIsExplainedPlainlyWithANextStep() {
        let (defaults, cleanUp) = isolatedDefaults()
        defer { cleanUp() }
        let settings = ShortcutSettings(defaults: defaults)
        #expect(settings.problem == nil)
        settings.registration = .registered
        #expect(settings.problem == nil)

        settings.registration = .inUse
        let message = settings.problem ?? ""
        #expect(message.contains("⌥Space"))
        #expect(message.contains("another app"))
        #expect(message.contains("different shortcut"))
        #expect(message.contains("menu bar"))

        settings.registration = .invalid
        #expect(settings.problem != nil)
        settings.registration = .failed
        #expect(settings.problem != nil)
        settings.turnOff()
        #expect(settings.problem == nil, "turned off is not a problem")
    }
}
