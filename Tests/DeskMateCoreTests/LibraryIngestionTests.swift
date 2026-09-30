import Foundation
import PDFKit
import Testing
@testable import DeskMateCore

@Suite("Reading files")
struct DocumentReaderTests {
    @Test func utf8TextIsAcceptedAndOtherEncodingsAreRejected() {
        let good = DocumentReader.decodeText(Data("Budget is 48,000 — approved.".utf8), kind: .text)
        #expect(good == .document(ExtractedDocument(kind: .text, body: .text("Budget is 48,000 — approved."))))

        // "café" in Latin-1 is not valid UTF-8: rejected, never guessed.
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9])
        #expect(DocumentReader.decodeText(latin1, kind: .text) == .skipped(.notUTF8))
        // UTF-16 text contains NUL bytes.
        #expect(DocumentReader.decodeText(Data("hi".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }), kind: .text) == .skipped(.notUTF8))
        #expect(DocumentReader.decodeText(Data("  \n ".utf8), kind: .markdown) == .skipped(.empty))
    }

    @Test func oversizeTextIsRejectedBeforeReading() throws {
        let folder = try ScratchFolder()
        let url = try folder.write("big.txt", "x")
        #expect(DocumentReader.read(url: url, kind: .text, byteCount: LibraryLimits.maxTextBytes + 1) == .skipped(.textTooLarge(bytes: LibraryLimits.maxTextBytes + 1)))
    }

    @Test func textLayerPDFIsReadPageByPage() throws {
        let folder = try ScratchFolder()
        let url = try folder.write("a.pdf", data: TestPDF.textLayer(pages: [
            ["First page has the retention period of 90 days."],
            ["Second page lists the incident contact."],
        ]))
        guard case .document(let document) = DocumentReader.read(url: url, kind: .pdf, byteCount: 10_000),
              case .pages(let pages) = document.body else {
            Issue.record("expected a readable PDF")
            return
        }
        #expect(pages.count == 2)
        #expect(pages[0].contains("90 days"))
        #expect(document.pageCount == 2)
    }

    @Test func scannedPDFNeedsOCRWithAnActionableMessage() throws {
        let folder = try ScratchFolder()
        let url = try folder.write("scan.pdf", data: TestPDF.imageOnly())
        let outcome = DocumentReader.read(url: url, kind: .pdf, byteCount: 10_000)
        #expect(outcome == .skipped(.needsOCR))
        #expect(SkipReason.needsOCR.explanation.contains("OCR"))
    }

    @Test func pdfOverFiftyPagesAndOverTenMegabytesAreRejectedWithTheReason() throws {
        let folder = try ScratchFolder()
        let long = try folder.write("long.pdf", data: TestPDF.pages(LibraryLimits.maxPDFPages + 1))
        #expect(DocumentReader.read(url: long, kind: .pdf, byteCount: 50_000) == .skipped(.pdfTooManyPages(pages: LibraryLimits.maxPDFPages + 1)))

        let fifty = try folder.write("fifty.pdf", data: TestPDF.pages(LibraryLimits.maxPDFPages))
        if case .skipped = DocumentReader.read(url: fifty, kind: .pdf, byteCount: 50_000) { Issue.record("exactly 50 pages is allowed") }

        let huge = LibraryLimits.maxPDFBytes + 1
        #expect(DocumentReader.read(url: fifty, kind: .pdf, byteCount: huge) == .skipped(.pdfTooLarge(bytes: huge)))
        #expect(SkipReason.pdfTooLarge(bytes: huge).explanation.contains("10 MB"))
    }

    @Test func partlyScannedPDFKeepsPageNumbersAndSaysWhatWasLeftOut() {
        let document = PDFDocument(data: TestPDF.textLayer(pages: [
            ["This page has plenty of readable text in its text layer."],
            ["."],
        ]))!
        guard case .document(let extracted) = DocumentReader.extract(from: document), case .pages(let pages) = extracted.body else {
            Issue.record("expected a document")
            return
        }
        #expect(pages.count == 2)
        #expect(pages[1].isEmpty)
        #expect(extracted.note?.contains("1 of 2 pages") == true)
    }
}

@Suite("Chunking")
struct ChunkerTests {
    @Test func chunksStayBoundedAndNeverSpanPagesOrSections() {
        let sentence = "The sensors report presence only and store nothing personal. "
        let pageText = String(repeating: sentence, count: 40)
        let pdf = ExtractedDocument(kind: .pdf, body: .pages([pageText, pageText]), pageCount: 2)
        let chunks = Chunker.chunks(for: pdf, fileID: "f", fileName: "a.pdf", relativePath: "a.pdf")
        #expect(chunks.count > 2)
        #expect(chunks.allSatisfy { $0.text.count <= LibraryLimits.maxChunkCharacters })
        #expect(chunks.allSatisfy { $0.page == 1 || $0.page == 2 })
        #expect(Set(chunks.compactMap(\.page)) == [1, 2])
        // Page order is preserved and ordinals are consecutive.
        #expect(chunks.map(\.ordinal) == Array(0..<chunks.count))
        #expect(chunks.firstIndex { $0.page == 2 }! > chunks.lastIndex { $0.page == 1 }!)
        // Joined chunk text loses no sentence: nothing is silently dropped.
        let joined = chunks.filter { $0.page == 1 }.map(\.text).joined(separator: " ")
        #expect(joined.components(separatedBy: "presence only").count - 1 == 40)
    }

    @Test func markdownHeadingsBecomeTheSectionPathAndCodeFencesAreRespected() {
        let markdown = """
        # Plan
        Intro text about the plan.

        ## Budget
        The budget is EUR 48,000.

        ```
        # not a heading
        ```

        ## Timeline
        Launch on 14 June.
        """
        let chunks = Chunker.chunks(for: ExtractedDocument(kind: .markdown, body: .markdown(markdown)), fileID: "f", fileName: "p.md", relativePath: "p.md")
        let sections = chunks.compactMap(\.section)
        #expect(sections.contains("Plan › Budget"))
        #expect(sections.contains("Plan › Timeline"))
        #expect(!sections.contains { $0.contains("not a heading") })
        let budget = chunks.first { $0.section == "Plan › Budget" }
        #expect(budget?.text.contains("48,000") == true)
        #expect(budget?.text.contains("14 June") == false)
    }

    @Test func idsAreStableAndChangeWithTheText() {
        let document = ExtractedDocument(kind: .text, body: .text("Alpha beta gamma."))
        let first = Chunker.chunks(for: document, fileID: "f", fileName: "a.txt", relativePath: "a.txt")
        let again = Chunker.chunks(for: document, fileID: "f", fileName: "a.txt", relativePath: "a.txt")
        let edited = Chunker.chunks(for: ExtractedDocument(kind: .text, body: .text("Alpha beta delta.")), fileID: "f", fileName: "a.txt", relativePath: "a.txt")
        #expect(first.map(\.id) == again.map(\.id))
        #expect(first.map(\.id) != edited.map(\.id))
    }

    @Test func oneHugeLineWithoutSpacesIsStillSplit() {
        let blob = String(repeating: "x", count: 4_500)
        let chunks = Chunker.chunks(for: ExtractedDocument(kind: .text, body: .text(blob)), fileID: "f", fileName: "a.txt", relativePath: "a.txt")
        #expect(chunks.allSatisfy { $0.text.count <= LibraryLimits.maxChunkCharacters })
        #expect(chunks.map(\.text).joined().count == 4_500)
    }
}

@Suite("Searching the index")
struct SearchIndexTests {
    private func chunk(_ id: String, file: String, _ text: String, section: String? = nil) -> SourceChunk {
        SourceChunk(id: id, fileID: file, fileName: file, relativePath: file, ordinal: 0, page: nil, section: section, text: text)
    }

    @Test func theRightExcerptRanksFirstAndNumbersStayWhole() {
        let index = SearchIndex(chunks: [
            chunk("a", file: "plan.md", "The total budget is EUR 48,000 with a contingency of 10 percent."),
            chunk("b", file: "notes.txt", "Launch is planned for 14 June 2026 in Lisbon."),
            chunk("c", file: "risks.txt", "Sensor delivery may take up to 6 weeks."),
        ])
        #expect(index.search("What is the budget of 48,000?", limit: 3).first?.chunk.id == "a")
        #expect(index.search("launch date", limit: 3).first?.chunk.id == "b")
        // "48,000" is one token, so 48 alone matches nothing.
        #expect(index.search("48", limit: 3).isEmpty)
        #expect(Tokenizer.tokens("EUR 48,000 and 3.5 percent") == ["eur", "48000", "3_5", "percent"])
    }

    @Test func stemmingAndFileNamesHelpAndUnrelatedQueriesFindNothing() {
        let index = SearchIndex(chunks: [
            chunk("a", file: "vendor-quotes.txt", "Brightway installed the sensors in four weeks."),
            chunk("b", file: "other.txt", "Weather was calm."),
        ])
        #expect(index.search("quotes", limit: 2).first?.chunk.id == "a")
        #expect(index.search("installing", limit: 2).first?.chunk.id == "a")
        #expect(index.search("zebra", limit: 2).isEmpty)
        #expect(index.search("   ", limit: 2).isEmpty)
    }

    @Test func allowListKeepsExcludedFilesOutOfResults() {
        let index = SearchIndex(chunks: [
            chunk("a", file: "keep.txt", "budget approved"),
            chunk("b", file: "gone.txt", "budget approved and more budget"),
        ])
        let results = index.search("budget", limit: 5) { $0.fileID == "keep.txt" }
        #expect(results.map(\.chunk.id) == ["a"])
    }
}
