import CoreGraphics
import CoreText
import Foundation
import Synchronization
@testable import DeskMateCore

/// A scratch folder with synthetic files, removed when the test process exits. Nothing outside it is touched.
/// It is not removed on deinit: Swift may end a local's lifetime before an awaited call that still reads the folder.
final class ScratchFolder: Sendable {
    let url: URL

    private static let created = Mutex<[String]>([])

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("deskmate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.resolvingSymlinksInPath()
        Self.created.withLock { paths in
            if paths.isEmpty {
                atexit {
                    for path in ScratchFolder.created.withLock({ $0 }) { try? FileManager.default.removeItem(atPath: path) }
                }
            }
            paths.append(base.path)
        }
    }

    @discardableResult
    func write(_ name: String, _ text: String) throws -> URL {
        try write(name, data: Data(text.utf8))
    }

    @discardableResult
    func write(_ name: String, data: Data) throws -> URL {
        let target = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }

    func path(_ name: String) -> URL { url.appendingPathComponent(name) }
}

enum TestPDF {
    /// A PDF whose pages carry a real text layer.
    static func textLayer(pages: [[String]]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        let key = NSAttributedString.Key(kCTFontAttributeName as String)
        for lines in pages {
            context.beginPDFPage(nil)
            var y: CGFloat = 720
            for line in lines {
                let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [key: font]))
                context.textPosition = CGPoint(x: 72, y: y)
                CTLineDraw(ctLine, context)
                y -= 22
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A PDF that holds only a picture: no text layer, like a scan.
    static func imageOnly() -> Data {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let bitmap = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return Data() }
        bitmap.setFillColor(gray: 0.8, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        guard let image = bitmap.makeImage() else { return Data() }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static func pages(_ count: Int) -> Data {
        textLayer(pages: (1...count).map { ["Page \($0) of a long synthetic report with enough readable words to count as text."] })
    }
}

/// A synthetic project library used across the library tests.
enum SyntheticLibrary {
    static let budgetNote = "# Budget\nThe approved budget is EUR 48,000. The finance approver is Ana Costa.\n\n# Timeline\nLaunch is planned for 14 June.\n"

    static func populate(_ folder: ScratchFolder) throws {
        try folder.write("notes/budget.md", budgetNote)
        try folder.write("notes/meeting.txt", "Kickoff meeting. Priya Raman leads the project. Firmware is due on 30 April.")
        try folder.write("reports/security.pdf", data: TestPDF.textLayer(pages: [
            ["Security review", "Reviewer: Nadia Okafor", "Sensor data is stored for 90 days and then deleted."],
            ["Incident handling", "Report incidents to the security desk within 24 hours of discovery."],
        ]))
    }
}

@MainActor
func makeStore(persistence: LibraryPersistence? = nil) -> LibraryStore {
    LibraryStore(persistence: persistence, scopedBookmarks: false)
}
