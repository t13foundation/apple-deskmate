import DeskMateCore
import Foundation

/// Reproducible command-line evidence, run as `DeskMate --diagnose-model` or `DeskMate --ask "<question>"`.
/// Exit codes: 0 success, 1 generation failed, 3 model not ready, 64 usage error.
/// `--diagnose-model` prints readiness only (no prompts or content). `--ask` runs one real generation on the
/// on-device model and fails clearly when it is unavailable; it never produces substitute output.
enum HeadlessCommand {
    case diagnoseModel
    case ask(String)
    case renderSnapshot(SnapshotRequest)
    case usage(String?)

    init?(arguments: [String]) {
        guard let first = arguments.first else { return nil }
        switch first {
        case "--diagnose-model":
            self = .diagnoseModel
        case "--ask":
            let question = arguments.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            self = question.isEmpty ? .usage("--ask needs a question, e.g. --ask \"What is a budget?\"") : .ask(question)
        case "--render-snapshot":
            switch SnapshotRequest.parse(Array(arguments.dropFirst())) {
            case .success(let request): self = .renderSnapshot(request)
            case .failure(let problem): self = .usage(problem.message)
            }
        case "--help", "-h":
            self = .usage(nil)
        default:
            return nil
        }
    }

    @MainActor
    func run() async -> Int32 {
        switch self {
        case .usage(let problem):
            if let problem { print("error: \(problem)") }
            print("""
            usage: DeskMate [--diagnose-model | --ask "<question>" | --render-snapshot <file> | --help]
              --diagnose-model  print model availability, English support and context size, then exit
              --ask "<q>"       run one real on-device generation and print timing and answer
              --render-snapshot <file.png> [--appearance light|dark] [--size 980x720]
                                development snapshot of the empty chat window; output must be inside .scratch/
            Without arguments DeskMate opens its window.
            """)
            return problem == nil ? 0 : 64

        case .diagnoseModel:
            let snapshot = SystemModelProbe.snapshot()
            print(ModelDiagnostics.report(snapshot: snapshot))
            return snapshot.readiness.isReady ? 0 : 3

        case .renderSnapshot(let request):
            return SnapshotRenderer.render(request)

        case .ask(let question):
            let engine = SystemModelEngine()
            let snapshot = engine.readiness()
            guard snapshot.readiness.isReady else {
                print(ModelDiagnostics.report(snapshot: snapshot))
                print("\nNot asking: the on-device model is not ready. No answer was produced.")
                return 3
            }
            do {
                let result = try await ModelDiagnostics.ask(question, engine: engine)
                print("engine: SystemLanguageModel.default (real on-device inference)")
                if let first = result.timeToFirstText { print("first text after: \(Self.seconds(first)) s") }
                print("total: \(Self.seconds(result.total)) s")
                print("--- answer ---")
                print(result.answer)
                return 0
            } catch {
                let failure = ChatFailure.from(error: error)
                print("Generation failed: \(failure.title) [\(failure.code)]")
                print(failure.message)
                return 1
            }
        }
    }

    private static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2f", value)
    }
}
