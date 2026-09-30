import DeskMateCore
import Foundation

/// Options for `DeskMate --ask ... --library <folder>` and friends: real on-device questions about explicitly named files.
/// The folder is indexed in memory only (no bookmarks, nothing saved). Output is the answer, the cited excerpt IDs with
/// file name and page, and with `--show-excerpts` only the cited excerpts. Document text is never printed otherwise.
struct HeadlessFilesRequest {
    var question = ""
    var library: URL?
    var attachments: [URL] = []
    var followUps: [String] = []
    var compare: (URL, URL)?
    var showExcerpts = false
    var showSearches = false

    /// Returns nil when no file option is present, so plain `--ask "<question>"` keeps its simple path.
    static func parse(_ arguments: [String]) -> Result<HeadlessFilesRequest, UsageProblem>? {
        let fileOptions: Set<String> = ["--library", "--attach", "--follow-up", "--compare", "--show-excerpts", "--show-searches"]
        guard arguments.contains(where: { fileOptions.contains($0) }) else { return nil }

        var request = HeadlessFilesRequest()
        var words: [String] = []
        var index = 0
        func next(_ option: String) -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--library":
                guard let value = next(argument) else { return .failure(UsageProblem("--library needs a folder")) }
                request.library = URL(fileURLWithPath: value)
            case "--attach":
                guard let value = next(argument) else { return .failure(UsageProblem("--attach needs a file")) }
                request.attachments.append(URL(fileURLWithPath: value))
            case "--follow-up":
                guard let value = next(argument) else { return .failure(UsageProblem("--follow-up needs a question")) }
                request.followUps.append(value)
            case "--compare":
                guard let first = next(argument), let second = next(argument) else {
                    return .failure(UsageProblem("--compare needs two files"))
                }
                request.compare = (URL(fileURLWithPath: first), URL(fileURLWithPath: second))
            case "--show-excerpts":
                request.showExcerpts = true
            case "--show-searches":
                request.showSearches = true
            default:
                words.append(argument)
            }
            index += 1
        }
        request.question = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if request.question.isEmpty, request.compare != nil { request.question = ConversationController.comparisonPrompt }
        guard !request.question.isEmpty else { return .failure(UsageProblem("a question is required, e.g. --ask \"What is the budget?\" --library Fixtures/Library")) }
        if request.attachments.count > ConversationController.maxAttachments {
            return .failure(UsageProblem("at most \(ConversationController.maxAttachments) files can be attached"))
        }
        if request.compare != nil, !request.attachments.isEmpty {
            return .failure(UsageProblem("--compare cannot be combined with --attach"))
        }
        return .success(request)
    }
}

struct UsageProblem: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

enum HeadlessFilesAsk {
    /// Exit codes: 0 success, 1 generation or input problem, 3 model not ready.
    @MainActor
    static func run(_ request: HeadlessFilesRequest) async -> Int32 {
        let store = LibraryStore(persistence: nil, scopedBookmarks: false)
        if let folder = request.library {
            let outcome = await store.addSources(urls: [folder])
            for notice in outcome.notices { print("library: \(notice)") }
            printLibrarySummary(store)
            guard !outcome.added.isEmpty else {
                print("Nothing was indexed, so the model has no files to search.")
                return 1
            }
        }

        let engine = SystemModelEngine(library: store)
        let snapshot = engine.readiness()
        guard snapshot.readiness.isReady else {
            print(ModelDiagnostics.report(snapshot: snapshot))
            print("\nNot asking: the on-device model is not ready. No answer was produced.")
            return 3
        }
        print("engine: SystemLanguageModel.default (real on-device inference)")

        let controller = ConversationController(engine: engine)
        if let (first, second) = request.compare {
            await controller.attach(urls: [first, second])
            controller.beginComparison()
        } else if !request.attachments.isEmpty {
            await controller.attach(urls: request.attachments)
        }
        for notice in controller.attachmentNotices { print("attach: \(notice)") }

        var questions = [request.question] + request.followUps
        var status: Int32 = 0
        while !questions.isEmpty {
            let question = questions.removeFirst()
            print("\n=== question: \(question)")
            controller.draft = question
            let clock = ContinuousClock()
            let start = clock.now
            controller.send()
            await controller.waitUntilIdle()
            let elapsed = clock.now - start

            if let failure = controller.failure {
                print("Refused or failed: \(failure.title) [\(failure.code)]")
                print(failure.message)
                status = 1
                break
            }
            guard let answer = controller.messages.last, answer.role == .assistant else {
                print("No answer was produced.")
                status = 1
                break
            }
            print("total: \(seconds(elapsed)) s")
            if request.showSearches {
                let traces = engine.searchTraces
                print("searches: \(traces.count)")
                for trace in traces {
                    print("  query \"\(trace.query)\": \(trace.candidateCount) candidates, budget \(trace.budgetTokens) tokens, used \(trace.usedTokens), left out \(trace.omittedCount)")
                    for line in trace.given { print("    gave \(line)") }
                }
            }
            print("--- answer ---")
            print(answer.text)
            printSources(answer, showExcerpts: request.showExcerpts)
        }
        return status
    }

    @MainActor
    private static func printLibrarySummary(_ store: LibraryStore) {
        print("library: \(store.searchableFiles.count) files searchable, \(store.skippedFiles.count) skipped")
        for file in store.skippedFiles.sorted(by: { $0.relativePath < $1.relativePath }) {
            print("  skipped \(file.relativePath): \(file.skip?.label ?? "skipped")")
        }
        if let report = store.lastReport { print("library: \(report.summary)") }
    }

    private static func printSources(_ answer: ChatMessage, showExcerpts: Bool) {
        if answer.sources.isEmpty {
            print("--- sources: none cited (excerpts given to the model: \(answer.consultedCount)) ---")
        } else {
            print("--- sources cited ---")
            for source in answer.sources {
                print("[\(source.id)] \(source.title)\(source.truncated ? " (excerpt cut to fit)" : "")")
                if showExcerpts { print("    \"\(source.excerpt.replacingOccurrences(of: "\n", with: " "))\"") }
            }
        }
        if !answer.removedCitations.isEmpty {
            print("--- removed unknown citations: \(answer.removedCitations.joined(separator: ", ")) ---")
        }
    }

    private static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2f", value)
    }
}
