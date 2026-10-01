import Foundation
import FoundationModels

extension SystemModelEngine {
    /// Restores a reopened conversation using the model's own token counts (macOS 26.4+), else the conservative estimate.
    public func restoreHistory(_ turns: [ConversationTurn]) async -> Int {
        await HistoryRestore.run(engine: self, turns: turns, meter: SystemModelMeter(model: model))
    }

    /// Creates a brief or task list with guided generation in a new one-shot session. The chat session is not used, so
    /// nothing here enters its context. The conversation must fit with room for the schema and a response cap; if it
    /// does not, it is refused before anything is sent, and never cut.
    public func makeResult(_ request: ResultRequest) async throws -> ResultOutcome {
        let meter = SystemModelMeter(model: model)
        let instructions = ResultWording.instructions(for: request.kind)
        let prompt = ResultWording.prompt(for: request.kind, material: request.material)
        let instructionsTokens = await meter.tokens(in: instructions)
        let promptTokens = await meter.tokens(in: prompt)
        guard let cap = ResultBudget.responseCap(contextSize: model.contextSize, instructionsTokens: instructionsTokens, promptTokens: promptTokens) else {
            return .refused(ResultBudget.tooLong(kind: request.kind))
        }
        var options = GenerationOptions()
        options.temperature = 0.2
        options.maximumResponseTokens = cap
        let session = Self.stageSession(model: model, instructions: instructions)

        switch request.kind {
        case .brief:
            let response = try await session.respond(to: prompt, generating: BriefDraft.self, options: options)
            let limited = await Self.hitLimit(response.rawContent.jsonString, cap: cap, meter: meter)
            return .generated(.brief(response.content), hitLimit: limited)
        case .tasks:
            let response = try await session.respond(to: prompt, generating: TaskListDraft.self, options: options)
            let limited = await Self.hitLimit(response.rawContent.jsonString, cap: cap, meter: meter)
            return .generated(.tasks(response.content), hitLimit: limited)
        }
    }
}
