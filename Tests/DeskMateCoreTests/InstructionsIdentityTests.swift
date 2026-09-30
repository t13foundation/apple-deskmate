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
            #expect(lowered.contains("apple's on-device foundation model"), "\(name): names Apple's on-device model")
            #expect(lowered.contains("foundation models framework"), "\(name): names the framework")
            #expect(lowered.contains("locally on this mac"), "\(name): says it runs locally")
            #expect(lowered.contains("no internet access"), "\(name): says there is no internet access")
            #expect(lowered.contains("no cloud model"), "\(name): says there is no cloud model")
            #expect(lowered.contains("do not know further details"), "\(name): admits it does not know the version")
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
