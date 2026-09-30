import Foundation
@testable import DeskMateCore

/// Scripted engine used ONLY by tests to exercise conversation logic deterministically.
/// It is not part of the app and never stands in for model output anywhere the user can see.
@MainActor
final class ScriptedEngine: ConversationEngine {
    enum Behavior {
        /// Yields cumulative snapshots and finishes.
        case chunks([String])
        /// Yields some snapshots, then throws.
        case failing([String], any Error)
        /// The test drives the stream through `manual`.
        case manual
    }

    var snapshot = ModelReadinessSnapshot(availability: .available, supportsEnglish: true, contextSize: 4096, hasExactTokenCounting: true)
    var usage = ContextUsage(sessionTokens: 120, baselineTokens: 120, promptTokens: 20, contextSize: 4096, isExact: true)
    var behaviors: [Behavior] = []

    private(set) var prompts: [String] = []
    private(set) var resets: [[ConversationTurn]] = []
    private(set) var manual: AsyncThrowingStream<String, any Error>.Continuation?

    func readiness() -> ModelReadinessSnapshot { snapshot }

    func contextUsage(adding prompt: String) async -> ContextUsage { usage }

    func reset(history: [ConversationTurn]) { resets.append(history) }

    func streamReply(to prompt: String) -> AsyncThrowingStream<String, any Error> {
        prompts.append(prompt)
        let behavior = behaviors.isEmpty ? Behavior.chunks(["ok"]) : behaviors.removeFirst()
        return AsyncThrowingStream { continuation in
            switch behavior {
            case .chunks(let parts):
                parts.forEach { continuation.yield($0) }
                continuation.finish()
            case .failing(let parts, let error):
                parts.forEach { continuation.yield($0) }
                continuation.finish(throwing: error)
            case .manual:
                self.manual = continuation
            }
        }
    }
}

@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
