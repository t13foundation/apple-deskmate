import DeskMateCore
import Foundation

/// Reproducible command-line evidence, run as `DeskMate --diagnose-model` or `DeskMate --ask "<question>"`.
/// Exit codes: 0 success, 1 generation failed, 3 model not ready, 64 usage error.
/// `--diagnose-model` prints readiness only (no prompts or content). `--ask` runs one real generation on the
/// on-device model and fails clearly when it is unavailable; it never produces substitute output.
enum HeadlessCommand {
    case diagnoseModel
    case ask(String)
    case askAboutFiles(HeadlessFilesRequest)
    case result(ResultKind, String)
    case resumeDemo
    case usage(String?)

    init?(arguments: [String]) {
        guard let first = arguments.first else { return nil }
        switch first {
        case "--diagnose-model":
            self = .diagnoseModel
        case "--brief", "--tasks":
            let text = arguments.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            self = text.isEmpty ? .usage("\(first) needs the text of an answer, e.g. \(first) \"The venue is booked.\"") : .result(first == "--brief" ? .brief : .tasks, text)
        case "--resume-demo":
            self = .resumeDemo
        case "--ask", "--compare":
            let rest = first == "--ask" ? Array(arguments.dropFirst()) : arguments
            switch HeadlessFilesRequest.parse(rest) {
            case .success(let request)?:
                self = .askAboutFiles(request)
            case .failure(let problem)?:
                self = .usage(problem.message)
            case nil:
                let question = rest.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                self = question.isEmpty ? .usage("--ask needs a question, e.g. --ask \"What is a budget?\"") : .ask(question)
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
            usage: DeskMate [--diagnose-model | --ask "<question>" [file options] | --brief "<text>" | --tasks "<text>" | --resume-demo | --help]
              --diagnose-model  print model availability, English support and context size, then exit
              --ask "<q>"       run one real on-device generation and print timing and answer
              --brief "<text>"  save a synthetic conversation whose answer is <text>, reopen it, create a brief
              --tasks "<text>"  the same, with a task list (Task / Owner / Due date / Evidence)
              --resume-demo     save a long synthetic conversation, simulate a restart, ask one real follow-up
            file options (real on-device answers about files you name; nothing is saved):
              --library <folder>         index this folder in memory and let the model search it
              --attach <file>            attach a file to the question (repeat, up to 5)
              --compare <fileA> <fileB>  compare two documents (the question is optional)
              --follow-up "<q>"          ask another question in the same chat (repeatable)
              --show-excerpts            also print the cited excerpts (never other document text)
              --show-searches            print each search the model ran and which excerpts it received
            connected service options (in memory; every tool call asks "Allow? [y/N]" and reads your answer from stdin):
              --connection <address>     connect this Streamable HTTP MCP endpoint (HTTPS, or http on 127.0.0.1)
              --enable-tool <name>       turn this tool on (repeatable; none are on by default)
              DESKMATE_MCP_TOKEN         environment variable with the bearer token, if the endpoint needs one
              No answer or end of input denies the call. There is no option that approves for you.
            Without arguments DeskMate opens its window.
            """)
            return problem == nil ? 0 : 64

        case .askAboutFiles(let request):
            return await HeadlessFilesAsk.run(request)

        case .result(let kind, let text):
            return await HeadlessConversations.result(kind: kind, text: text)

        case .resumeDemo:
            return await HeadlessConversations.resumeDemo()

        case .diagnoseModel:
            let snapshot = SystemModelProbe.snapshot()
            print(ModelDiagnostics.report(snapshot: snapshot))
            return snapshot.readiness.isReady ? 0 : 3

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
