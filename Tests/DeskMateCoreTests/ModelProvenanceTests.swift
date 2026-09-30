import Testing
@testable import DeskMateCore

/// The screens say what produced an answer in the engine's words, and only true things.
@Suite struct ModelProvenanceTests {
    private var provenance: ModelProvenance { SystemModelEngine.provenance }

    @Test func theEngineNamesAppleOnDeviceModelOnThisMac() {
        #expect(provenance.shortLabel == "Apple on-device model · On this Mac")
        #expect(provenance.detail.contains("Apple's on-device foundation model through the Foundation Models framework"))
        #expect(provenance.detail.contains("Model inference stays on this Mac; no cloud model is used"))
        #expect(provenance.detail.contains("Connected services you approve may receive the details shown before each call"))
        #expect(!provenance.detail.contains("Nothing is sent"))
        #expect(provenance.detail.contains("Apple does not expose the exact model version to apps"))
    }

    @Test func noTextNamesAnotherModelOrClaimsAVersion() {
        let all = [provenance.shortLabel, provenance.detail, provenance.footnote].joined(separator: " ").lowercased()
        for word in ["gpt", "openai", "pcc", "private cloud", "macos 27", "gemini", "claude", "remote"] {
            #expect(!all.contains(word), "provenance mentions \(word)")
        }
    }

    @Test func footnoteStaysConsistentWithTheLabel() {
        #expect(provenance.footnote.lowercased().contains("apple"))
        #expect(provenance.footnote.lowercased().contains("on-device"))
        #expect(provenance.footnote.lowercased().contains("can be wrong"))
    }

    /// The engine appends this note when a reply stops at its cap. The transcript must show it, not drop it.
    @Test @MainActor func aCappedAnswerKeepsItsLengthLimitNoteInTheTranscript() async {
        let engine = ScriptedEngine()
        let controller = ConversationController(engine: engine)
        let partial = "Nie mam pojęcia, jak duży jest."
        engine.behaviors = [.chunks([partial, partial + SystemModelEngine.chatLimitNote])]
        controller.draft = "Jaki model tu jest podłączony teraz?"
        controller.send()
        await controller.waitUntilIdle()
        let answer = controller.messages.last
        #expect(answer?.role == .assistant)
        #expect(answer?.status == .complete)
        #expect(answer?.text.contains("reached the length limit and may be incomplete") == true)
    }
}
