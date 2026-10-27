import Foundation
import CoreGraphics
import CoreText
@preconcurrency import PDFKit

public enum FixtureFactory {
    public static func generate(in directory: URL, quick: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try makeDocument(at: directory.appendingPathComponent("paper.pdf"), pages: 30, title: "Research Paper Fixture", columns: true, scanned: false)
        try makeDocument(at: directory.appendingPathComponent("textbook.pdf"), pages: quick ? 50 : 1_000, title: "Textbook Fixture", columns: false, scanned: false)
        try makeDocument(at: directory.appendingPathComponent("scans.pdf"), pages: quick ? 12 : 300, title: "Scanned Book Fixture", columns: false, scanned: true)
        try Data("%PDF-1.7\nThis deliberately malformed fixture has no objects.\n".utf8).write(to: directory.appendingPathComponent("malformed.pdf"))
        if let document = PDFDocument(url: directory.appendingPathComponent("paper.pdf")) {
            guard document.write(to: directory.appendingPathComponent("encrypted.pdf"), withOptions: [.ownerPasswordOption: "fixture-owner", .userPasswordOption: "fixture-reader"]) else { throw PDFServiceError.unreadable }
        }
    }
    public static func makeDocument(at url: URL, pages: Int, title: String, columns: Bool, scanned: Bool) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &mediaBox, [kCGPDFContextTitle: title, kCGPDFContextCreator: "Swift Sioyek deterministic fixture generator"] as CFDictionary) else { throw PDFServiceError.unreadable }
        for index in 0..<pages {
            let wide = index > 0 && index % 19 == 0
            let box = wide ? CGRect(x: 0, y: 0, width: 792, height: 612) : mediaBox
            let boxData = withUnsafeBytes(of: box) { Data($0) }
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            context.addDestination("page-\(index)" as CFString, at: CGPoint(x: 42, y: box.height - 62))
            if index == 0, !scanned { context.setDestination("page-\(min(5, pages - 1))" as CFString, for: CGRect(x: 42, y: 690, width: 220, height: 14)) }
            if scanned {
                guard let raster = CGContext(data: nil, width: 918, height: 1188, bitsPerComponent: 8, bytesPerRow: 918 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw PDFServiceError.renderFailed }
                raster.scaleBy(x: 1.5, y: 1.5); drawPage(raster, index: index, box: mediaBox, columns: false)
                if let image = raster.makeImage() { context.draw(image, in: box) }
            } else { drawPage(context, index: index, box: box, columns: columns) }
            context.endPDFPage()
        }
        if !scanned {
            let chapterSize = columns ? 5 : 50
            let children: [[String: Any]] = stride(from: 0, to: pages, by: chapterSize).map { index in [kCGPDFOutlineTitle as String: "Chapter \(index / chapterSize + 1)", kCGPDFOutlineDestination as String: index + 1] }
            CGPDFContextSetOutline(context, [kCGPDFOutlineChildren as String: children] as CFDictionary)
        }
        context.closePDF()
        guard !scanned, let document = PDFDocument(url: url) else { return }
        if let page = document.page(at: 0) {
            let highlight = PDFAnnotation(bounds: CGRect(x: 42, y: 646, width: 150, height: 12), forType: .highlight, withProperties: nil); highlight.color = .systemYellow; page.addAnnotation(highlight)
        }
        for (index, rotation) in [(1, 90), (2, 180), (3, 270)] where index < pages { document.page(at: index)?.rotation = rotation }
        if pages > 3 { document.page(at: 3)?.setBounds(CGRect(x: 25, y: 21, width: 558, height: 740), for: .cropBox) }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".fixture-\(UUID().uuidString).pdf")
        guard document.write(to: temporary) else { throw PDFServiceError.unreadable }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
    public static func makeFigurePreviewDocument(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: "Long Caption Preview Fixture"] as CFDictionary) else { throw PDFServiceError.unreadable }
        context.beginPDFPage(nil)
        draw("Open linked diagram", at: CGPoint(x: 42, y: 690), size: 12, in: context)
        context.setDestination("figure-caption" as CFString, for: CGRect(x: 42, y: 687, width: 180, height: 16))
        draw("Open linked table", at: CGPoint(x: 42, y: 660), size: 12, in: context)
        context.setDestination("table-caption" as CFString, for: CGRect(x: 42, y: 657, width: 180, height: 16))
        draw("See Figure 1 for details.", at: CGPoint(x: 42, y: 630), size: 12, in: context)
        context.endPDFPage()
        context.beginPDFPage(nil)
        context.addDestination("figure-caption" as CFString, at: CGPoint(x: 310, y: 264))
        context.addDestination("table-caption" as CFString, at: CGPoint(x: 42, y: 694))
        draw("Table 1. An ordinary preview destination.", at: CGPoint(x: 42, y: 680), size: 11, in: context)
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 310, y: 280, width: 250, height: 280))
        draw("Artwork top", at: CGPoint(x: 325, y: 540), size: 14, in: context)
        draw("Artwork bottom", at: CGPoint(x: 325, y: 295), size: 14, in: context)
        draw("Figure 1. A diagram with a long caption.", at: CGPoint(x: 310, y: 250), size: 11, in: context)
        for line in 1...16 {
            draw("Caption continuation \(line): detailed explanation.", at: CGPoint(x: 310, y: 250 - Double(line) * 12), size: 10, in: context)
        }
        context.endPDFPage(); context.closePDF()
    }
    private static func drawPage(_ context: CGContext, index: Int, box: CGRect, columns: Bool) {
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
        // Orientation fiducials survive PDF rotations and crop offsets.
        context.setFillColor(CGColor(red: 0.85, green: 0.12, blue: 0.12, alpha: 1)); context.fill(CGRect(x: 32, y: box.height - 36, width: 18, height: 18))
        context.setFillColor(CGColor(red: 0.12, green: 0.25, blue: 0.85, alpha: 1)); context.fill(CGRect(x: box.width - 50, y: 22, width: 18, height: 18))
        draw("Native Research Reader — page \(index + 1)", at: CGPoint(x: 58, y: box.height - 43), size: 16, in: context)
        draw("Reading Figure 1.1 and references [1] without losing context.", at: CGPoint(x: 42, y: box.height - 96), size: 10, in: context)
        let columnCount = columns ? 2 : 1, width = (box.width - 100) / Double(columnCount)
        for column in 0..<columnCount {
            for line in 0..<(Int(box.height - 220) / 13) {
                let text = columns ? "\(line + 1). Efficient native rendering keeps reading fluid." : "\(line + 1). A bounded cache and isolated workers keep a long textbook responsive."
                draw(text, at: CGPoint(x: 42 + Double(column) * (width + 16), y: box.height - 130 - Double(line) * 13), size: columns ? 8.5 : 10, in: context)
            }
        }
        if index == 5 { draw("Figure 1.1. Priority scheduling of native PDF tiles.", at: CGPoint(x: 42, y: 91), size: 11, in: context) }
        if index == 4 || index == 12 { draw("Figure 2.1. An intentionally ambiguous caption.", at: CGPoint(x: 42, y: 91), size: 11, in: context) }
        if index == 6 { draw("Table 3.1. Measured rendering intervals.", at: CGPoint(x: 42, y: 91), size: 11, in: context) }
        if index == 29 { draw("[1] Native Rendering. A Research Reference. 2026.", at: CGPoint(x: 42, y: 91), size: 11, in: context) }
        draw("Unicode: café naïve α β γ ∑ ∫ — typography and mathematics.", at: CGPoint(x: 42, y: 67), size: 10, in: context)
        draw("(2.1)", at: CGPoint(x: box.width - 88, y: 106), size: 11, in: context)
        context.setStrokeColor(CGColor(gray: 0.35, alpha: 1)); context.setLineWidth(0.5)
        for i in 0..<14 { let x = 50 + Double(i) * 12; context.move(to: CGPoint(x: x, y: 113)); context.addLine(to: CGPoint(x: x + 18, y: 124 + Double(i % 5) * 5)); context.strokePath() }
    }
    private static func draw(_ string: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("TimesNewRomanPSMT" as CFString, size, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.08, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes)); context.textMatrix = .identity; context.textPosition = point; CTLineDraw(line, context)
    }
}
