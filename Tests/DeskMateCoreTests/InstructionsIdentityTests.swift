import FoundationModels
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

    /// The model once claimed it could analyse images. DeskMate on macOS 26 is text only, and both variants must say
    /// what it can read, what it cannot, and that other services are reached only through approved tools.
    @Test func bothVariantsStateTheTextOnlyCapabilities() {
        for (name, text) in variants {
            let lowered = text.lowercased()
            #expect(lowered.contains("deskmate is text only"), "\(name): says it is text only")
            #expect(lowered.contains("utf-8 txt or markdown files and pdfs with a text layer"), "\(name): lists readable files")
            #expect(lowered.contains("you cannot see or hear images, photos, screenshots, scans, audio or video"), "\(name): denies image and audio input")
            #expect(lowered.contains("scanned or image-only pdfs because there is no ocr"), "\(name): denies OCR")
            #expect(lowered.contains("cannot browse the web or open links, act in other apps, or change files"), "\(name): denies web and actions")
            #expect(
                lowered.contains("only through tools deskmate offers you in this chat, and only after the user approves each call"),
                "\(name): tools need approval"
            )
            #expect(lowered.contains("never imply that you looked at an image"), "\(name): forbids pretending to see images")
        }
    }

    @Test func capabilityFactsAreStatedOnceAndInheritedByTheLibraryVariant() {
        let marker = "DeskMate is text only"
        #expect(DeskMateInstructions.general.components(separatedBy: marker).count == 2)
        #expect(DeskMateInstructions.library.components(separatedBy: marker).count == 2)
    }

    /// Exact count with the model's own tokenizer, where the platform offers it (macOS 26.4+ with the model ready).
    /// The context window is 4096 tokens, so the session instructions must stay a small share of it.
    @Test func instructionsFitASmallShareOfTheContextWindowByExactCount() async throws {
        guard #available(macOS 26.4, *) else { return }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return }
        let general = try await model.tokenCount(for: Instructions(DeskMateInstructions.general))
        let library = try await model.tokenCount(for: Instructions(DeskMateInstructions.library))
        print("DeskMate instruction tokens (exact): general=\(general) library=\(library) of context \(model.contextSize)")
        #expect(general < 450)
        #expect(library < 800)
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
