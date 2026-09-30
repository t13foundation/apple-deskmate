import Foundation
import FoundationModels

/// Session instructions. English only, short: the context window is small.
public enum DeskMateInstructions {
    public static let general = """
    You are DeskMate, a calm and helpful assistant on the user's Mac. \
    Always answer in English, in clear plain language for people who are not programmers. \
    Be concise and direct. Use short paragraphs, and Markdown lists or headings only when they help. \
    In this conversation you answer from your general knowledge. \
    You cannot see the user's files or the internet unless text is included in the conversation. \
    If you are unsure or cannot know something, say so instead of guessing. \
    Never invent file names, links, sources, quotations, or facts about the user's own data.
    """
}

/// Apple's on-device model through Foundation Models (`SystemLanguageModel`).
/// This is the only inference path in DeskMate. It never falls back to another model.
@MainActor
public final class SystemModelEngine: ConversationEngine {
    private let model: SystemLanguageModel
    private let instructions: String
    /// Extension point for later packages (library retrieval, approved MCP tools).
    private let tools: [any Tool]
    private var session: LanguageModelSession

    public init(model: SystemLanguageModel = .default, instructions: String = DeskMateInstructions.general, tools: [any Tool] = []) {
        self.model = model
        self.instructions = instructions
        self.tools = tools
        self.session = Self.makeSession(model: model, instructions: instructions, tools: tools, history: [])
    }

    public func readiness() -> ModelReadinessSnapshot {
        SystemModelProbe.snapshot(model: model)
    }

    public func reset(history: [ConversationTurn]) {
        session = Self.makeSession(model: model, instructions: instructions, tools: tools, history: history)
    }

    public func prewarm() {
        guard model.isAvailable else { return }
        session.prewarm()
    }

    public func streamReply(to prompt: String) -> AsyncThrowingStream<String, any Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await snapshot in session.streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Context measurement

    public func contextUsage(adding prompt: String) async -> ContextUsage {
        let contextSize = model.contextSize
        if #available(macOS 26.4, *) {
            if let exact = await exactUsage(adding: prompt, contextSize: contextSize) {
                return exact
            }
        }
        return estimatedUsage(adding: prompt, contextSize: contextSize)
    }

    @available(macOS 26.4, *)
    private func exactUsage(adding prompt: String, contextSize: Int) async -> ContextUsage? {
        do {
            var baseline = try await model.tokenCount(for: Instructions(instructions))
            if !tools.isEmpty {
                baseline += try await model.tokenCount(for: tools)
            }
            let session = try await model.tokenCount(for: self.session.transcript)
            let promptTokens = try await model.tokenCount(for: prompt)
            return ContextUsage(
                sessionTokens: max(session, baseline),
                baselineTokens: baseline,
                promptTokens: promptTokens,
                contextSize: contextSize,
                isExact: true
            )
        } catch {
            return nil
        }
    }

    private func estimatedUsage(adding prompt: String, contextSize: Int) -> ContextUsage {
        let baseline = ContextBudget.estimateTokens(instructions)
        var sessionTokens = baseline
        for entry in session.transcript {
            switch entry {
            case .prompt(let value): sessionTokens += Self.estimate(value.segments)
            case .response(let value): sessionTokens += Self.estimate(value.segments)
            case .instructions, .toolCalls, .toolOutput: break
            @unknown default: break
            }
        }
        return ContextUsage(
            sessionTokens: sessionTokens,
            baselineTokens: baseline,
            promptTokens: ContextBudget.estimateTokens(prompt),
            contextSize: contextSize,
            isExact: false
        )
    }

    private static func estimate(_ segments: [Transcript.Segment]) -> Int {
        segments.reduce(0) { total, segment in
            switch segment {
            case .text(let text): total + ContextBudget.estimateTokens(text.content)
            case .structure: total
            @unknown default: total
            }
        }
    }

    // MARK: Session construction

    private static func makeSession(model: SystemLanguageModel, instructions: String, tools: [any Tool], history: [ConversationTurn]) -> LanguageModelSession {
        guard !history.isEmpty else {
            return LanguageModelSession(model: model, tools: tools, instructions: instructions)
        }
        // Restore finished turns as a transcript. Instructions must be the first entry.
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
            ))
        ]
        for turn in history {
            entries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: turn.prompt))])))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: turn.response))])))
        }
        return LanguageModelSession(model: model, tools: tools, transcript: Transcript(entries: entries))
    }
}
