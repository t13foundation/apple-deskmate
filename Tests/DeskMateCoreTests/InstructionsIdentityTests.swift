import Testing
@testable import DeskMateCore

/// The model once answered "I'm powered by GPT-4". The instructions must tell it what it really runs on,
/// in both the general and the library variant, and must not mention any other vendor's model.
@Suite struct InstructionsIdentityTests {
    private var variants: [(name: String, text: String)] {
        [("general", DeskMateInstructions.general), ("library", DeskMateInstructions.library)]
    }

    @Test func bothVariantsStateTheRealRuntime() {
        for (name, text) in variants {
            let lowered = text.lowercased()
            #expect(lowered.contains("on-device foundation model that apple provides in macos"), "\(name): names Apple's on-device model")
            #expect(lowered.contains("apple develops that model"), "\(name): says Apple develops it")
            #expect(lowered.contains("foundation models framework"), "\(name): names the framework")
            #expect(lowered.contains("locally on this mac"), "\(name): says it runs locally")
            #expect(lowered.contains("no internet access"), "\(name): says there is no internet access")
            #expect(lowered.contains("no cloud model"), "\(name): says there is no cloud model")
        }
    }

    /// The model once invented "I am an open-source model and not owned by any company". DeskMate is told no
    /// version, size, training data or licence, so the instructions must say so and forbid stating them.
    @Test func bothVariantsAdmitWhatTheModelIsNotToldAndForbidInventing() {
        for (name, text) in variants {
            let lowered = text.lowercased()
            #expect(lowered.contains("not told your exact version, parameter count, training data or licence"), "\(name): lists what is unknown")
            #expect(lowered.contains("never call yourself open-source"), "\(name): forbids the open-source claim")
            #expect(lowered.contains("do not know those details"), "\(name): says what to answer instead")
            #expect(lowered.contains("do not say they are secret or undisclosed"), "\(name): does not dress ignorance up as secrecy")
        }
    }

    @Test func noVariantClaimsASpecificVersionSizeOrLicence() {
        // The only mentions allowed are the negated ones above: no digits followed by a size, no named licence.
        for (name, text) in variants {
            let lowered = text.lowercased()
            for word in ["apache", "mit licen", "gpl", " billion", "b parameters", "version 1", "version 2"] {
                #expect(!lowered.contains(word), "\(name) states \(word)")
            }
        }
    }

    @Test func noVariantNamesAnotherVendorOrModel() {
        let foreign = ["gpt", "openai", "chatgpt", "claude", "anthropic", "gemini", "google", "llama", "meta ", "mistral", "copilot", "microsoft"]
        for (name, text) in variants {
            let lowered = text.lowercased()
            for word in foreign {
                #expect(!lowered.contains(word), "\(name) mentions \(word)")
            }
        }
    }

    @Test func libraryVariantKeepsFilesBehindTheSearchTool() {
        #expect(DeskMateInstructions.library.contains("only through the searchMyFiles tool"))
        #expect(DeskMateInstructions.library.hasPrefix(DeskMateInstructions.general))
    }

    @Test func instructionsStayShortForTheFourThousandTokenContext() {
        // Roughly four characters per token: the library variant must stay well under a fifth of the window.
        #expect(DeskMateInstructions.library.count < 4096 * 4 / 5)
    }
}
