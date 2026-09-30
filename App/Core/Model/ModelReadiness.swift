import Foundation
import FoundationModels

/// Plain mirror of `SystemLanguageModel.Availability` so readiness logic is testable without the OS model.
public enum ModelAvailability: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unknown
    }

    case available
    case unavailable(Reason)
}

/// What the system reported at one moment. Contains no user content.
public struct ModelReadinessSnapshot: Equatable, Sendable {
    public var availability: ModelAvailability
    /// Whether the model supports English (en_US). DeskMate only processes English.
    public var supportsEnglish: Bool
    public var contextSize: Int
    /// True when exact token counting (macOS 26.4+) is available; otherwise budgets are estimates.
    public var hasExactTokenCounting: Bool

    public init(availability: ModelAvailability, supportsEnglish: Bool, contextSize: Int, hasExactTokenCounting: Bool) {
        self.availability = availability
        self.supportsEnglish = supportsEnglish
        self.contextSize = contextSize
        self.hasExactTokenCounting = hasExactTokenCounting
    }

    public var readiness: ModelReadiness { ModelReadiness(snapshot: self) }
}

/// The user-facing model state. Each non-ready case carries an explanation and a next step.
public enum ModelReadiness: Equatable, Sendable {
    case ready(contextSize: Int)
    case appleIntelligenceOff
    case modelNotReady
    case deviceNotEligible
    case englishUnsupported
    case unknown

    public init(snapshot: ModelReadinessSnapshot) {
        switch snapshot.availability {
        case .available:
            self = snapshot.supportsEnglish ? .ready(contextSize: snapshot.contextSize) : .englishUnsupported
        case .unavailable(.appleIntelligenceNotEnabled):
            self = .appleIntelligenceOff
        case .unavailable(.modelNotReady):
            self = .modelNotReady
        case .unavailable(.deviceNotEligible):
            self = .deviceNotEligible
        case .unavailable(.unknown):
            self = .unknown
        }
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Short label for status chips.
    public var statusLabel: String {
        switch self {
        case .ready: "On-device model ready"
        case .appleIntelligenceOff: "Apple Intelligence is off"
        case .modelNotReady: "Model is not ready yet"
        case .deviceNotEligible: "Model not supported on this Mac"
        case .englishUnsupported: "English is not supported"
        case .unknown: "Model unavailable"
        }
    }

    public var title: String {
        switch self {
        case .ready: "On-device model ready"
        case .appleIntelligenceOff: "Turn on Apple Intelligence to start"
        case .modelNotReady: "The on-device model is still getting ready"
        case .deviceNotEligible: "This Mac can’t run the on-device model"
        case .englishUnsupported: "The on-device model can’t work in English here"
        case .unknown: "The on-device model isn’t available"
        }
    }

    /// Explanation plus the next step. Never blames the person and never suggests a cloud fallback.
    public var message: String {
        switch self {
        case .ready:
            "Answers are written by Apple’s model running on your Mac."
        case .appleIntelligenceOff:
            "DeskMate answers with Apple’s on-device model, which needs Apple Intelligence. Open System Settings, choose Apple Intelligence & Siri, and turn on Apple Intelligence. Apple Intelligence also needs a supported Mac, a supported Siri language such as English, and a supported region. Your message stays here until then."
        case .modelNotReady:
            "macOS is still downloading or preparing the model. This can take a while after turning on Apple Intelligence. Keep your Mac connected to power and the internet, then choose Check again. Your message stays here."
        case .deviceNotEligible:
            "Apple’s on-device model isn’t supported on this Mac, and DeskMate doesn’t switch to a cloud model. You can still read and edit your text here."
        case .englishUnsupported:
            "The installed model doesn’t report English support. Check System Settings > Apple Intelligence & Siri, then choose Check again."
        case .unknown:
            "macOS reported the model as unavailable for an unknown reason. Choose Check again in a moment. Your message stays here."
        }
    }

    /// Whether opening System Settings is a helpful next step.
    public var suggestsSystemSettings: Bool {
        switch self {
        case .appleIntelligenceOff, .englishUnsupported: true
        default: false
        }
    }
}

/// Reads the real system model. No content is involved.
public enum SystemModelProbe {
    public static func snapshot(model: SystemLanguageModel = .default) -> ModelReadinessSnapshot {
        let availability: ModelAvailability
        switch model.availability {
        case .available:
            availability = .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: availability = .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: availability = .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady: availability = .unavailable(.modelNotReady)
            @unknown default: availability = .unavailable(.unknown)
            }
        }
        var exactCounting = false
        if #available(macOS 26.4, *) { exactCounting = true }
        return ModelReadinessSnapshot(
            availability: availability,
            supportsEnglish: model.supportsLocale(Locale(identifier: "en_US")),
            contextSize: model.contextSize,
            hasExactTokenCounting: exactCounting
        )
    }
}
