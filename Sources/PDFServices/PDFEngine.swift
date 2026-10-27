import Foundation
@preconcurrency import PDFKit
import CoreGraphics
import AppKit
import ReaderCore
import os

public enum PDFServiceError: LocalizedError, Sendable {
    case unreadable, locked, noPages, forbidden, renderFailed, changed
    public var errorDescription: String? {
        switch self {
        case .unreadable: "The file could not be opened as a PDF. It may be damaged, unavailable, or unreadable."
        case .locked: "This PDF needs a valid password."
        case .noPages: "This PDF has no readable pages."
        case .forbidden: "The PDF's permissions do not allow this operation."
        case .renderFailed: "The page could not be rendered within the available bitmap budget."
        case .changed: "The PDF changed during this operation. Reload it and try again."
        }
    }
}
public struct DocumentSource: Sendable {
    public var identity: DocumentIdentity; public var url: URL; public var password: String?
    public init(identity: DocumentIdentity, url: URL, password: String? = nil) { self.identity = identity; self.url = url; self.password = password }
}
public enum FileIdentity {
    public static func revision(of url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        return "\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(String(describing: values.fileResourceIdentifier))"
    }
    public static func resourceID(of url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .volumeIdentifierKey]), let file = values.fileResourceIdentifier else { return "" }
        return "\(String(describing: values.volumeIdentifier)):\(file)"
    }
    public static func resolve(_ document: RecentDocument) -> (url: URL, stale: Bool)? {
        if let bookmark = document.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) { return (url, stale) }
        }
        return FileManager.default.fileExists(atPath: document.url.path) ? (document.url, true) : nil
    }
}

public struct RenderedTile: @unchecked Sendable {
    // CGImage is immutable after creation; each image is published once.
    public let image: CGImage
    public let rect: CGRect
    public var bytes: Int { image.bytesPerRow * image.height }
    public init(image: CGImage, rect: CGRect) { self.image = image; self.rect = rect }
}

public actor RasterWorker {
    private var documents: [DocumentIdentity: PDFDocument] = [:]
    private var order: [DocumentIdentity] = []
    private let signposter = OSSignposter(subsystem: "app.swiftsioyek", category: "Rendering")
    public init() {}
    public func clear() { documents.removeAll(); order.removeAll() }
    public func render(_ request: RenderRequest, source: DocumentSource) throws -> RenderedTile {
        let state = signposter.beginInterval("Render tile"); defer { signposter.endInterval("Render tile", state) }
        let document: PDFDocument
        if let cached = documents[source.identity] { document = cached }
        else {
            guard let opened = PDFDocument(url: source.url) else { throw PDFServiceError.unreadable }
            if opened.isLocked, !opened.unlock(withPassword: source.password ?? "") { throw PDFServiceError.locked }
            documents[source.identity] = opened; document = opened
            order.append(source.identity)
            while order.count > 4 { documents.removeValue(forKey: order.removeFirst()) }
        }
        guard let page = document.page(at: request.key.pageIndex) else { throw PDFServiceError.noPages }
        let baseRotation = page.rotation
        page.rotation = (baseRotation + request.key.rotation) % 360
        defer { page.rotation = baseRotation }
        let scale = request.key.scale, rect = request.rect
        let width = max(1, Int(ceil(rect.width * scale))), height = max(1, Int(ceil(rect.height * scale)))
        guard width <= 4096, height <= 4096, width * height <= 8_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PDFServiceError.renderFailed }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let crop = page.bounds(for: .cropBox)
        let geometry = PageGeometry(index: request.key.pageIndex, cropBox: crop, rotation: page.rotation)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -(geometry.size().height - rect.maxY))
        page.displaysAnnotations = true
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw PDFServiceError.renderFailed }
        return RenderedTile(image: image, rect: rect)
    }
}

private struct TextCacheKey: Hashable { var document: DocumentIdentity; var page: Int }
private final class SharedTextCache: @unchecked Sendable {
    static let shared = SharedTextCache()
    private let lock = NSLock()
    private var cache = CostCache<TextCacheKey, PageText>(limit: 64 * 1024 * 1024)
    func value(_ key: TextCacheKey) -> PageText? { lock.withLock { cache.value(for: key) } }
    func insert(_ value: PageText, key: TextCacheKey) { lock.withLock { cache.insert(value, for: key, cost: value.estimatedBytes) } }
    func trim() { lock.withLock { cache.removeAll() } }
}

public actor PDFTextService {
    private var document: PDFDocument?
    private var source: DocumentSource?
    private var referenceIndex: [String: [ReferenceTarget]] = [:]
    private var indexedPages = Set<Int>()
    public init() {}
    public func open(_ source: DocumentSource) throws -> DocumentInfo {
        guard let document = PDFDocument(url: source.url) else { throw PDFServiceError.unreadable }
        if document.isLocked, !document.unlock(withPassword: source.password ?? "") { throw PDFServiceError.locked }
        guard document.pageCount > 0, let first = document.page(at: 0) else { throw PDFServiceError.noPages }
        self.document = document; self.source = source; indexedPages.removeAll(); referenceIndex.removeAll()
        let crop = first.bounds(for: .cropBox)
        guard crop.width.isFinite, crop.height.isFinite, crop.width > 0, crop.height > 0 else { throw PDFServiceError.unreadable }
        // Initial paint is independent of a full-document metadata scan.
        let pages = (0..<document.pageCount).map { PageGeometry(index: $0, cropBox: crop, rotation: first.rotation) }
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return DocumentInfo(identity: source.identity, url: source.url, title: title?.isEmpty == false ? title! : source.url.deletingPathExtension().lastPathComponent, pageCount: document.pageCount, pages: pages, outline: [], allowsCopying: document.allowsCopying, allowsPrinting: document.allowsPrinting)
    }
    public func geometry(pages range: Range<Int>) throws -> [PageGeometry] {
        guard let document else { throw PDFServiceError.unreadable }
        return range.compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let crop = page.bounds(for: .cropBox)
            guard crop.width.isFinite, crop.height.isFinite, crop.width > 0, crop.height > 0, crop.width < 100_000, crop.height < 100_000 else { return PageGeometry(index: index, cropBox: CGRect(x: 0, y: 0, width: 612, height: 792)) }
            return PageGeometry(index: index, cropBox: crop, rotation: page.rotation, label: page.label)
        }
    }
    public func outline() throws -> [OutlineEntry] {
        guard let document else { throw PDFServiceError.unreadable }
        var result: [OutlineEntry] = []
        func walk(_ item: PDFOutline, depth: Int, path: String) {
            guard depth < 64, result.count < 50_000 else { return }
            let destination = item.destination ?? (item.action as? PDFActionGoTo)?.destination
            if let destination, let page = destination.page {
                result.append(OutlineEntry(id: path, title: item.label ?? "Untitled", pageIndex: document.index(for: page), point: destination.point, depth: max(0, depth - 1)))
            }
            for index in 0..<item.numberOfChildren { if let child = item.child(at: index) { walk(child, depth: depth + 1, path: "\(path).\(index)") } }
        }
        if let root = document.outlineRoot { walk(root, depth: 0, path: "root") }; return result
    }
    public func text(page index: Int, detailed: Bool = true) throws -> PageText {
        guard let source else { throw PDFServiceError.unreadable }
        let cacheKey = TextCacheKey(document: source.identity, page: index)
        if detailed, let cached = SharedTextCache.shared.value(cacheKey) { return cached }
        guard let document, let page = document.page(at: index) else { throw PDFServiceError.noPages }
        let text = page.string ?? ""
        guard document.allowsCopying else { return PageText(pageIndex: index, text: "", glyphs: [], lines: [], links: links(page, document: document)) }
        var lines: [TextLine] = []
        if let selection = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)) {
            for line in selection.selectionsByLine() {
                guard line.numberOfTextRanges(on: page) > 0 else { continue }
                lines.append(TextLine(text: line.string ?? "", range: TextRange(line.range(at: 0, on: page)), bounds: line.bounds(for: page)))
            }
        }
        if !indexedPages.contains(index) {
            for line in lines {
                let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Only caption/entry-like line starts are definitions; body mentions are excluded.
                let caption = trimmed.range(of: #"(?i)^(?:fig(?:ure)?\.?|table|eq(?:uation)?\.?)\s+\(?[A-Z]?\d"#, options: .regularExpression) != nil
                let bibliography = trimmed.range(of: #"^\[\d+\]\s+"#, options: .regularExpression) != nil
                let equation = trimmed.range(of: #"^\(\d+(?:\.\d+)*\)$"#, options: .regularExpression) != nil
                if (caption || bibliography || equation), let key = ReferenceResolver.key(in: trimmed) {
                    referenceIndex[key, default: []].append(ReferenceTarget(label: trimmed, pageIndex: index, point: CGPoint(x: line.bounds.minX, y: line.bounds.maxY)))
                }
            }
            indexedPages.insert(index)
        }
        // Keep geometry in the same UTF-16 index space as page.string and
        // selection(for:). characterBounds(at:) can drift from that space in
        // PDFs containing expanded ligatures and inferred whitespace.
        let glyphs: [TextGlyph] = detailed ? try (0..<page.numberOfCharacters).map { offset in
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            let bounds = page.selection(for: NSRange(location: offset, length: 1))?.bounds(for: page) ?? .zero
            return TextGlyph(index: offset, bounds: bounds)
        } : []
        let snapshot = PageText(pageIndex: index, text: text, glyphs: glyphs, lines: lines, links: links(page, document: document))
        if detailed { SharedTextCache.shared.insert(snapshot, key: cacheKey) }
        return snapshot
    }
    private func links(_ page: PDFPage, document: PDFDocument) -> [PDFLink] {
        page.annotations.enumerated().compactMap { index, annotation in
            guard annotation.type == "Link" else { return nil }
            let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
            return PDFLink(id: index, bounds: annotation.bounds, destinationPage: destination?.page.map { document.index(for: $0) }, destinationPoint: destination?.point, url: annotation.url ?? (annotation.action as? PDFActionURL)?.url)
        }
    }
    /// Exact native selection geometry; no full-page glyph extraction is needed
    /// when navigating a search hit. Results stay in unrotated PDF coordinates.
    public func selectionRects(page index: Int, range: ReaderCore.TextRange) throws -> [CGRect] {
        try Task.checkCancellation()
        guard let document, document.allowsCopying else { throw PDFServiceError.forbidden }
        guard let page = document.page(at: index) else { throw PDFServiceError.noPages }
        guard range.location >= 0, range.length > 0, range.location < page.numberOfCharacters else { return [] }
        let clamped = NSRange(location: range.location, length: min(range.length, page.numberOfCharacters - range.location))
        guard let selection = page.selection(for: clamped) else { return [] }
        return selection.selectionsByLine().map { $0.bounds(for: page) }.filter {
            !$0.isEmpty && !$0.isNull && $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite
        }
    }
    public func selection(from startPage: Int, index startIndex: Int, to endPage: Int, index endIndex: Int) async throws -> TextSelectionSnapshot {
        guard let source, let document, document.allowsCopying else { throw PDFServiceError.forbidden }
        let start = (startPage, startIndex), end = (endPage, endIndex)
        let a = start <= end ? start : end, b = start <= end ? end : start
        var parts: [SelectionPart] = []
        for index in a.0...b.0 {
            try Task.checkCancellation()
            let snapshot = try text(page: index)
            let length = (snapshot.text as NSString).length
            let lower = index == a.0 ? min(length, max(0, a.1)) : 0, upper = index == b.0 ? min(length, max(0, b.1 + 1)) : length
            let range = TextRange(lower, max(0, upper - lower))
            parts.append(SelectionPart(pageIndex: index, range: range, rects: try selectionRects(page: index, range: range), text: (snapshot.text as NSString).substring(with: range.nsRange)))
            await Task.yield()
        }
        return TextSelectionSnapshot(document: source.identity, parts: parts)
    }
    public func matches(query: SearchQuery, page: Int) throws -> [SearchHit] { query.matches(in: try text(page: page, detailed: false).text, page: page) }
    public func resolve(_ text: String) -> [ReferenceTarget] { guard let key = ReferenceResolver.key(in: text) else { return [] }; return referenceIndex[key] ?? [] }
    public func indexedPageCount() -> Int { indexedPages.count }
    public func trim() { SharedTextCache.shared.trim() }
    public nonisolated static func trimSharedCache() { SharedTextCache.shared.trim() }
}

public actor PDFExporter {
    public init() {}
    public func export(source: DocumentSource, highlights: [LibraryRecord], to destination: URL) throws {
        guard try FileIdentity.revision(of: source.url) == source.identity.revision else { throw PDFServiceError.changed }
        guard source.url.standardizedFileURL != destination.standardizedFileURL else { throw PDFServiceError.forbidden }
        guard let document = PDFDocument(url: source.url) else { throw PDFServiceError.unreadable }
        if document.isLocked, !document.unlock(withPassword: source.password ?? "") { throw PDFServiceError.locked }
        guard document.allowsCommenting, document.allowsPrinting else { throw PDFServiceError.forbidden }
        for highlight in highlights where highlight.kind == .highlight && highlight.location.document == source.identity {
            for part in highlight.selection {
                guard let page = document.page(at: part.pageIndex) else { continue }
                for rect in part.rects where !rect.isEmpty {
                    let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                    annotation.color = HighlightPalette.color(for: highlight.style).withAlphaComponent(0.38)
                    annotation.contents = part.text; annotation.userName = "Swift Sioyek"
                    annotation.quadrilateralPoints = [NSValue(point: CGPoint(x: 0, y: rect.height)), NSValue(point: CGPoint(x: rect.width, y: rect.height)), NSValue(point: .zero), NSValue(point: CGPoint(x: rect.width, y: 0))]
                    page.addAnnotation(annotation)
                }
            }
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard document.write(to: temporary) else { throw PDFServiceError.unreadable }
        guard try FileIdentity.revision(of: source.url) == source.identity.revision else { throw PDFServiceError.changed }
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: destination) }
    }
}
