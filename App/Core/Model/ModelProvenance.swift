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

    /// The header of an answer for which a connected service was asked. It names only the model, because "On this Mac"
    /// would be wrong next to a request that left it; the remote label below says where the data went.
    public static let inferenceOnlyLabel = "Apple on-device model"

    /// The separate label for an answer that involved connected services, or nil when none did.
    /// `hosts` are the places a request may have reached (empty when every call was declined or refused).
    public static func remoteLabel(hosts: [String], usedServices: Bool) -> String? {
        if !hosts.isEmpty { return "Remote connection: sent data to \(hosts.joined(separator: ", "))" }
        if usedServices { return "Remote connection: nothing was sent" }
        return nil
    }

    /// For an answer that cites a service result retrieved in an earlier answer: where that result came from. It claims
    /// no new send, because this answer made none for it. Nil when no earlier result is cited.
    public static func earlierResultLabel(hosts: [String]) -> String? {
        hosts.isEmpty ? nil : "Uses a result retrieved earlier from \(hosts.joined(separator: ", "))"
    }
}
