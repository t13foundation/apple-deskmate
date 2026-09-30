import Foundation

/// What produced an answer, in words the person sees. The engine owns this text so that every screen says the same
/// true thing, and no view names a model on its own.
///
/// This describes local inference only. A connected tool service that the person approves may receive the arguments
/// shown before the call; the detail says so and does not claim that nothing leaves the Mac.
public struct ModelProvenance: Equatable, Sendable {
    /// One short line for the answer header and the window subtitle.
    public let shortLabel: String
    /// A sentence or two for a help tip or popover.
    public let detail: String
    /// The line under the message field.
    public let footnote: String

    public init(shortLabel: String, detail: String, footnote: String) {
        self.shortLabel = shortLabel
        self.detail = detail
        self.footnote = footnote
    }

    /// Apple's system language model, used through Foundation Models. Apple does not report the model version to apps,
    /// so none is named.
    public static let appleOnDevice = ModelProvenance(
        shortLabel: "Apple on-device model · On this Mac",
        detail: "Answered by Apple's on-device foundation model through the Foundation Models framework. Model inference stays on this Mac; no cloud model is used. Connected services you approve may receive the details shown before each call. Apple does not expose the exact model version to apps.",
        footnote: "Answers come from Apple’s on-device model and can be wrong."
    )
}
