import Foundation
import FoundationModels
import Synchronization

/// Lets the stream report what DeskMate is doing while the model works, e.g. while it searches the files.
final class ActivityRelay: Sendable {
    private let handler = Mutex<(@Sendable (String?) -> Void)?>(nil)

    func install(_ newHandler: (@Sendable (String?) -> Void)?) {
        handler.withLock { $0 = newHandler }
    }

    func emit(_ activity: String?) {
        let current = handler.withLock { $0 }
        current?(activity)
    }
}

/// The model's only way into the user's files: a read-only keyword search over My files.
/// It takes no paths and no file names, so the model cannot ask for anything outside the indexed, authorized library.
struct SearchMyFilesTool: Tool {
    let name = "searchMyFiles"
    let description = "Searches the user's own files in My files (notes, plans, documents, PDFs) and returns the most relevant excerpts. Each excerpt has an ID like S1, a file name and a page or section. Use a few specific keywords from the question."

    let retrieval: LibraryRetrieval
    let relay: ActivityRelay

    @Generable
    struct Arguments {
        @Guide(description: "Two to six specific keywords that would appear in the relevant passage, such as names, numbers, dates or topics.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        relay.emit("Searching your files…")
        let output = await retrieval.run(query: arguments.query)
        relay.emit(nil)
        return output
    }
}
