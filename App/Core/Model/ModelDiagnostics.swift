import Foundation

/// Reproducible, content-free evidence for the headless commands `--diagnose-model` and `--ask`.
public enum ModelDiagnostics {
    /// Human-readable readiness report. Contains no prompts, answers or file content.
    public static func report(snapshot: ModelReadinessSnapshot) -> String {
        let readiness = snapshot.readiness
        let availability: String
        switch snapshot.availability {
        case .available: availability = "available"
        case .unavailable(let reason): availability = "unavailable (\(reasonName(reason)))"
        }
        return """
        DeskMate model readiness
        os: \(ProcessInfo.processInfo.operatingSystemVersionString)
        model: SystemLanguageModel.default (on-device, Foundation Models)
        availability: \(availability)
        english (en_US) supported: \(snapshot.supportsEnglish ? "yes" : "no")
        context size: \(snapshot.contextSize) tokens
        token counting: \(snapshot.hasExactTokenCounting ? "exact (macOS 26.4+)" : "estimate only (macOS earlier than 26.4)")
        response reserve: \(ContextBudget.responseReserve(contextSize: snapshot.contextSize)) tokens
        ready: \(readiness.isReady ? "yes" : "no")
        status: \(readiness.title)
        """
    }

    private static func reasonName(_ reason: ModelAvailability.Reason) -> String {
        switch reason {
        case .deviceNotEligible: "deviceNotEligible"
        case .appleIntelligenceNotEnabled: "appleIntelligenceNotEnabled"
        case .modelNotReady: "modelNotReady"
        case .unknown: "unknown"
        }
    }

    public struct AskResult: Sendable {
        public var answer: String
        public var timeToFirstText: Duration?
        public var total: Duration
    }

    /// Runs one real streamed generation. Throws if the model is unavailable or generation fails; never fakes output.
    @MainActor
    public static func ask(_ question: String, engine: some ConversationEngine) async throws -> AskResult {
        let clock = ContinuousClock()
        let start = clock.now
        var first: Duration?
        var latest = ""
        for try await text in engine.streamReply(to: question) {
            if first == nil { first = clock.now - start }
            latest = text
        }
        return AskResult(answer: latest, timeToFirstText: first, total: clock.now - start)
    }
}
