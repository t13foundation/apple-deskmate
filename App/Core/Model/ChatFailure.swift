import Foundation
import FoundationModels

/// What the person can do next after a problem. The UI renders these as buttons.
public enum ChatFailureAction: Equatable, Sendable {
    case retry
    case editQuestion
    case newChat
    case newChatKeepingQuestion
    case checkAgain
    case openSystemSettings
}

public enum ChatFailureKind: Equatable, Sendable {
    case promptTooLong
    case conversationFull
    case guardrail
    case unsupportedLanguage
    case busy
    case rateLimited
    case assetsUnavailable
    case other
}

/// A recoverable problem, phrased for a nonprogrammer, always with a next step.
/// The person's question is never discarded by any failure.
public struct ChatFailure: Equatable, Sendable {
    public var kind: ChatFailureKind
    public var title: String
    public var message: String
    public var actions: [ChatFailureAction]
    /// Short code for support and diagnostics. Never contains prompts or answers.
    public var code: String

    public init(kind: ChatFailureKind, title: String, message: String, actions: [ChatFailureAction], code: String) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actions = actions
        self.code = code
    }

    // MARK: Pre-flight failures (the message never left the composer)

    public static func context(_ decision: ContextDecision) -> ChatFailure? {
        switch decision {
        case .fits:
            return nil
        case .promptTooLong:
            return ChatFailure(
                kind: .promptTooLong,
                title: "That message is too long for the on-device model",
                message: "The model can read only a limited amount of text at once, and DeskMate won’t silently cut your text. Shorten the message or split it into parts and ask about one part at a time.",
                actions: [],
                code: "promptTooLong"
            )
        case .conversationFull:
            return ChatFailure(
                kind: .conversationFull,
                title: "This conversation is full",
                message: "The model can remember only a limited amount of text, and this chat has used it up. Start a new chat to continue. Your message will be waiting in the new chat.",
                actions: [.newChatKeepingQuestion],
                code: "conversationFull"
            )
        }
    }

    // MARK: Failures while generating (the question is already in the transcript)

    public static func from(error: any Error) -> ChatFailure {
        if let staged = error as? ComparisonStageError {
            // The user-facing wording stays that of the underlying error; the code names the stage, the error case and its NSError domain and code.
            var failure = from(error: staged.underlying)
            failure.code = "comparison:\(staged.diagnostic)"
            return failure
        }
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            // The error type name identifies the problem for support without exposing any content.
            let detail = error as NSError
            return generic(code: "unknownError:\(type(of: error)):\(detail.domain)#\(detail.code)")
        }
        switch generationError {
        case .exceededContextWindowSize:
            return ChatFailure(
                kind: .conversationFull,
                title: "This conversation is too long for the model",
                message: "The model reached the limit of what it can hold in one chat. Nothing was cut. Start a new chat to continue with your question.",
                actions: [.newChatKeepingQuestion],
                code: "exceededContextWindowSize"
            )
        case .guardrailViolation:
            return ChatFailure(
                kind: .guardrail,
                title: "The model can’t help with that request",
                message: "Apple’s on-device safety checks stopped this answer. Try rewording your question, or start a new chat if the conversation took a turn you didn’t intend.",
                actions: [.editQuestion, .newChat],
                code: "guardrailViolation"
            )
        case .refusal:
            return ChatFailure(
                kind: .guardrail,
                title: "The model declined to answer",
                message: "Try rewording your question or asking for something more specific.",
                actions: [.editQuestion, .newChat],
                code: "refusal"
            )
        case .unsupportedLanguageOrLocale:
            return ChatFailure(
                kind: .unsupportedLanguage,
                title: "DeskMate works in English",
                message: "The model didn’t recognize the language of your message. Write your question in English and try again.",
                actions: [.editQuestion],
                code: "unsupportedLanguageOrLocale"
            )
        case .concurrentRequests:
            return ChatFailure(
                kind: .busy,
                title: "The model is busy with another request",
                message: "Wait a moment for the other request to finish, then try again.",
                actions: [.retry],
                code: "concurrentRequests"
            )
        case .rateLimited:
            return ChatFailure(
                kind: .rateLimited,
                title: "The model needs a short break",
                message: "macOS is limiting how often the on-device model can be used right now. Wait a little, then try again.",
                actions: [.retry],
                code: "rateLimited"
            )
        case .assetsUnavailable:
            return ChatFailure(
                kind: .assetsUnavailable,
                title: "The model files aren’t available right now",
                message: "macOS could not load the on-device model. It may still be downloading, or storage may be low. Check again in a moment, then try your question again.",
                actions: [.checkAgain, .retry],
                code: "assetsUnavailable"
            )
        case .unsupportedGuide, .decodingFailure:
            return generic(code: "internalGenerationError")
        @unknown default:
            return generic(code: "unknownGenerationError")
        }
    }

    public static func generic(code: String) -> ChatFailure {
        ChatFailure(
            kind: .other,
            title: "Something went wrong",
            message: "DeskMate couldn’t finish this answer. Your question is still here. Try again, or reword it.",
            actions: [.retry, .editQuestion],
            code: code
        )
    }
}
