// Regenerates the synthetic PDF fixtures in Fixtures/Library. Run from the repository root:
//   swift Fixtures/make-library-pdfs.swift
// Text PDFs carry a real text layer. The "scan" PDF contains only a bitmap, so it has no text layer.
// All content is fictional.
import CoreGraphics
import CoreText
import Foundation

let outputDirectory = URL(fileURLWithPath: "Fixtures/Library", isDirectory: true)
let pageBox = CGRect(x: 0, y: 0, width: 612, height: 792)
let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)

func makeTextPDF(named name: String, pages: [[String]]) {
    let url = outputDirectory.appendingPathComponent(name)
    var box = pageBox
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { fatalError("cannot create \(name)") }
    let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
    let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 18, nil)
    for lines in pages {
        context.beginPDFPage(nil)
        var y: CGFloat = 720
        for (index, line) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [fontKey: index == 0 ? titleFont : font]
            let attributed = NSAttributedString(string: line, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(ctLine, context)
            y -= index == 0 ? 36 : 24
        }
        context.endPDFPage()
    }
    context.closePDF()
}

func makeScannedPDF(named name: String, lines: [String]) {
    // Render the text into a bitmap, then place only the bitmap on the page: no text layer.
    let width = 1224
    let height = 1584
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { fatalError("bitmap") }
    bitmap.setFillColor(gray: 1, alpha: 1)
    bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
    bitmap.setFillColor(gray: 0, alpha: 1)
    let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
    var y: CGFloat = 1440
    for line in lines {
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [fontKey: font]))
        bitmap.textPosition = CGPoint(x: 144, y: y)
        CTLineDraw(ctLine, bitmap)
        y -= 56
    }
    guard let image = bitmap.makeImage() else { fatalError("image") }

    let url = outputDirectory.appendingPathComponent(name)
    var box = pageBox
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { fatalError("cannot create \(name)") }
    context.beginPDFPage(nil)
    context.draw(image, in: pageBox)
    context.endPDFPage()
    context.closePDF()
}

makeTextPDF(named: "lumen-security-review.pdf", pages: [
    [
        "Project Lumen - Security review",
        "Reviewer: Nadia Okafor",
        "Review completed: 2 May 2026",
        "Sensor data is stored for 90 days and then deleted.",
        "No personal names are stored; the sensors report presence only.",
    ],
    [
        "Incident handling",
        "Report incidents to security-desk@lumen.example within 24 hours.",
        "The privacy review was approved on 6 May 2026 with two conditions:",
        "encrypt the gateway, and keep the retention period at 90 days.",
    ],
])

makeTextPDF(named: "lumen-budget-summary.pdf", pages: [
    [
        "Project Lumen - Budget summary (version 1)",
        "Hardware: EUR 26,000",
        "Software and setup: EUR 12,000",
        "Training: EUR 4,000",
        "Contingency: EUR 6,000",
        "Total: EUR 48,000",
    ],
    [
        "Spend plan by quarter",
        "Q2 2026: EUR 30,000",
        "Q3 2026: EUR 18,000",
        "Invoices are paid within 30 days.",
    ],
])

makeScannedPDF(named: "lumen-site-survey-scan.pdf", lines: [
    "Project Lumen - Site survey (scanned)",
    "Third floor, Lisbon office: 38 desks.",
    "This page is a picture of text, so it has no text layer.",
])

print("Wrote PDFs to \(outputDirectory.path)")
