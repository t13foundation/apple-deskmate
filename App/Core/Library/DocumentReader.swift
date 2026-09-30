import Foundation
import PDFKit

/// Reads one supported file into text. Rejections are explicit and actionable, never silent.
/// Reading never logs or prints file content.
public enum DocumentReader {
    public enum Outcome: Equatable, Sendable {
        case document(ExtractedDocument)
        case skipped(SkipReason)
    }

    /// `byteCount` is the size already read from the file attributes, so oversize files are rejected before any read.
    public static func read(url: URL, kind: FileKind, byteCount: Int) -> Outcome {
        switch kind {
        case .text, .markdown:
            return readText(url: url, kind: kind, byteCount: byteCount)
        case .pdf:
            return readPDF(url: url, byteCount: byteCount)
        }
    }

    // MARK: Text and Markdown

    static func readText(url: URL, kind: FileKind, byteCount: Int) -> Outcome {
        guard byteCount <= LibraryLimits.maxTextBytes else { return .skipped(.textTooLarge(bytes: byteCount)) }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .skipped(.unreadable) }
        return decodeText(data, kind: kind)
    }

    /// Strict UTF-8 only: no guessing of other encodings, which could silently garble the text.
    public static func decodeText(_ data: Data, kind: FileKind) -> Outcome {
        if data.count > LibraryLimits.maxTextBytes { return .skipped(.textTooLarge(bytes: data.count)) }
        // UTF-8 byte order mark is valid; UTF-16/32 marks and NUL bytes mean this is not UTF-8 text.
        var payload = data
        if payload.starts(with: [0xEF, 0xBB, 0xBF]) { payload = payload.dropFirst(3) }
        if payload.contains(0) { return .skipped(.notUTF8) }
        guard let text = String(data: payload, encoding: .utf8) else { return .skipped(.notUTF8) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .skipped(.empty) }
        return .document(ExtractedDocument(kind: kind, body: kind == .markdown ? .markdown(text) : .text(text)))
    }

    // MARK: PDF

    static func readPDF(url: URL, byteCount: Int) -> Outcome {
        guard byteCount <= LibraryLimits.maxPDFBytes else { return .skipped(.pdfTooLarge(bytes: byteCount)) }
        guard let document = PDFDocument(url: url) else { return .skipped(.unreadablePDF) }
        return extract(from: document)
    }

    /// Text-layer extraction. A page counts as readable when it has at least `minimumPageCharacters`
    /// non-whitespace characters. A document with no readable page needs OCR and is rejected.
    static func extract(from document: PDFDocument) -> Outcome {
        if document.isEncrypted && document.isLocked { return .skipped(.encryptedPDF) }
        let pageCount = document.pageCount
        guard pageCount > 0 else { return .skipped(.unreadablePDF) }
        guard pageCount <= LibraryLimits.maxPDFPages else { return .skipped(.pdfTooManyPages(pages: pageCount)) }

        var pages: [String] = []
        var emptyPages = 0
        for index in 0..<pageCount {
            let raw = document.page(at: index)?.string ?? ""
            let visible = raw.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
            if visible >= LibraryLimits.minimumPageCharacters {
                pages.append(raw)
            } else {
                // Keep the position so later page numbers stay correct; such a page has no searchable text.
                pages.append("")
                emptyPages += 1
            }
        }
        if emptyPages == pageCount { return .skipped(.needsOCR) }

        var note: String?
        if emptyPages > 0 {
            note = "\(emptyPages) of \(pageCount) pages have no text layer and were left out (needs OCR)."
        }
        return .document(ExtractedDocument(kind: .pdf, body: .pages(pages), pageCount: pageCount, note: note))
    }
}
