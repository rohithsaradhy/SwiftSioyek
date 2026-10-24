import Foundation
import CoreGraphics

public struct DocumentIdentity: Codable, Hashable, Sendable {
    public var id: UUID
    public var revision: String
    public init(id: UUID, revision: String) { self.id = id; self.revision = revision }
}

public struct DocumentLocation: Codable, Equatable, Sendable {
    public var document: DocumentIdentity
    public var pageIndex: Int
    public var point: CGPoint
    public var zoom: Double
    public var rotation: Int
    public init(document: DocumentIdentity, pageIndex: Int, point: CGPoint = .zero, zoom: Double = 1, rotation: Int = 0) {
        self.document = document; self.pageIndex = max(0, pageIndex); self.point = point
        self.zoom = zoom; self.rotation = rotation
    }
}

public struct PageGeometry: Codable, Equatable, Sendable {
    public var index: Int
    public var cropBox: CGRect
    public var rotation: Int
    public var label: String
    public init(index: Int, cropBox: CGRect, rotation: Int = 0, label: String? = nil) {
        self.index = index; self.cropBox = cropBox; self.rotation = rotation; self.label = label ?? "\(index + 1)"
    }
    public func angle(adding extra: Int = 0) -> Int { ((rotation + extra) % 360 + 360) % 360 }
    public func size(adding extra: Int = 0) -> CGSize {
        [90, 270].contains(angle(adding: extra)) ? CGSize(width: cropBox.height, height: cropBox.width) : cropBox.size
    }
    // Unrotated PDF user space (bottom left) <-> displayed page space (top left).
    public func displayPoint(_ point: CGPoint, adding extra: Int = 0) -> CGPoint {
        let x = point.x - cropBox.minX, y = point.y - cropBox.minY
        switch angle(adding: extra) {
        case 90: return CGPoint(x: y, y: x)
        case 180: return CGPoint(x: cropBox.width - x, y: y)
        case 270: return CGPoint(x: cropBox.height - y, y: cropBox.width - x)
        default: return CGPoint(x: x, y: cropBox.height - y)
        }
    }
    public func pdfPoint(_ point: CGPoint, adding extra: Int = 0) -> CGPoint {
        let p: CGPoint
        switch angle(adding: extra) {
        case 90: p = CGPoint(x: point.y, y: point.x)
        case 180: p = CGPoint(x: cropBox.width - point.x, y: point.y)
        case 270: p = CGPoint(x: cropBox.width - point.y, y: cropBox.height - point.x)
        default: p = CGPoint(x: point.x, y: cropBox.height - point.y)
        }
        return CGPoint(x: p.x + cropBox.minX, y: p.y + cropBox.minY)
    }
    public func displayRect(_ rect: CGRect, adding extra: Int = 0) -> CGRect {
        let points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].map { displayPoint($0, adding: extra) }
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
    /// Position a match below the viewport's top edge in display space, then
    /// convert back to the unrotated PDF coordinates used by saved locations.
    public func readingAnchor(revealing rect: CGRect, viewport: CGSize, zoom: Double, adding extra: Int = 0) -> CGPoint {
        let scale = max(0.1, zoom), visibleWidth = viewport.width / scale
        let target = displayRect(rect, adding: extra), pageWidth = size(adding: extra).width
        let x = pageWidth <= visibleWidth ? (pageWidth - visibleWidth) / 2 : max(0, min(target.midX - visibleWidth / 2, pageWidth - visibleWidth))
        return pdfPoint(CGPoint(x: x, y: target.minY - min(50, viewport.height * 0.15) / scale), adding: extra)
    }
}

public struct DocumentInfo: Sendable {
    public var identity: DocumentIdentity
    public var url: URL
    public var title: String
    public var pageCount: Int
    public var pages: [PageGeometry]
    public var outline: [OutlineEntry]
    public var allowsCopying: Bool
    public var allowsPrinting: Bool
    public init(identity: DocumentIdentity, url: URL, title: String, pageCount: Int, pages: [PageGeometry], outline: [OutlineEntry], allowsCopying: Bool, allowsPrinting: Bool) {
        self.identity = identity; self.url = url; self.title = title; self.pageCount = pageCount; self.pages = pages
        self.outline = outline; self.allowsCopying = allowsCopying; self.allowsPrinting = allowsPrinting
    }
}

public struct OutlineEntry: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var pageIndex: Int
    public var point: CGPoint
    public var depth: Int
    public init(id: String, title: String, pageIndex: Int, point: CGPoint, depth: Int) { self.id = id; self.title = title; self.pageIndex = pageIndex; self.point = point; self.depth = depth }
}

public struct TextRange: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int
    public init(_ location: Int, _ length: Int) { self.location = location; self.length = length }
    public init(_ range: NSRange) { self.init(range.location, range.length) }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
    public var end: Int { location + length }
}
public struct TextGlyph: Sendable { public var index: Int; public var bounds: CGRect; public init(index: Int, bounds: CGRect) { self.index = index; self.bounds = bounds } }
public struct TextLine: Sendable {
    public var text: String; public var range: TextRange; public var bounds: CGRect
    public init(text: String, range: TextRange, bounds: CGRect) { self.text = text; self.range = range; self.bounds = bounds }
}
public struct PDFLink: Sendable, Identifiable {
    public var id: Int; public var bounds: CGRect; public var destinationPage: Int?; public var destinationPoint: CGPoint?; public var url: URL?
    public init(id: Int, bounds: CGRect, destinationPage: Int? = nil, destinationPoint: CGPoint? = nil, url: URL? = nil) { self.id = id; self.bounds = bounds; self.destinationPage = destinationPage; self.destinationPoint = destinationPoint; self.url = url }
}
public struct PageText: Sendable {
    public var pageIndex: Int; public var text: String; public var glyphs: [TextGlyph]; public var lines: [TextLine]; public var links: [PDFLink]
    public init(pageIndex: Int, text: String, glyphs: [TextGlyph], lines: [TextLine], links: [PDFLink]) { self.pageIndex = pageIndex; self.text = text; self.glyphs = glyphs; self.lines = lines; self.links = links }
    public var estimatedBytes: Int { text.utf16.count * 2 + glyphs.count * 48 + lines.reduce(0) { $0 + $1.text.utf16.count * 2 + 80 } + links.count * 160 }
    public func nearestIndex(to point: CGPoint) -> Int? {
        glyphs.filter { !$0.bounds.isEmpty }.min { a, b in
            func distance(_ rect: CGRect) -> Double { let dx = max(rect.minX - point.x, 0, point.x - rect.maxX), dy = max(rect.minY - point.y, 0, point.y - rect.maxY); return dx * dx + dy * dy * 9 }
            return distance(a.bounds) < distance(b.bounds)
        }?.index
    }
    public func rects(for range: TextRange) -> [CGRect] {
        lines.compactMap { line in
            let intersect = NSIntersectionRange(range.nsRange, line.range.nsRange)
            guard intersect.length > 0 else { return nil }
            return glyphs.filter { NSLocationInRange($0.index, intersect) && !$0.bounds.isEmpty }.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        }.filter { !$0.isNull }
    }
}
public struct SelectionPart: Codable, Equatable, Sendable {
    public var pageIndex: Int; public var range: TextRange; public var rects: [CGRect]; public var text: String
    public init(pageIndex: Int, range: TextRange, rects: [CGRect], text: String) { self.pageIndex = pageIndex; self.range = range; self.rects = rects; self.text = text }
}
public struct TextSelectionSnapshot: Sendable {
    public var document: DocumentIdentity; public var parts: [SelectionPart]
    public init(document: DocumentIdentity, parts: [SelectionPart]) { self.document = document; self.parts = parts }
    public var string: String { parts.map(\.text).joined(separator: "\n") }
}
public struct SearchHit: Sendable, Identifiable {
    public var id: String; public var pageIndex: Int; public var range: TextRange; public var excerpt: String; public var rects: [CGRect]
    public init(pageIndex: Int, range: TextRange, excerpt: String, rects: [CGRect] = []) { id = "\(pageIndex):\(range.location):\(range.length)"; self.pageIndex = pageIndex; self.range = range; self.excerpt = excerpt; self.rects = rects }
}
public enum RecordKind: String, Codable, Sendable { case mark, bookmark, highlight, portal }
public struct LibraryRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID; public var kind: RecordKind; public var location: DocumentLocation; public var title: String
    public var destination: DocumentLocation?; public var selection: [SelectionPart]; public var style: String; public var created: Date
    public init(id: UUID = UUID(), kind: RecordKind, location: DocumentLocation, title: String, destination: DocumentLocation? = nil, selection: [SelectionPart] = [], style: String = "a", created: Date = Date()) {
        self.id = id; self.kind = kind; self.location = location; self.title = title; self.destination = destination; self.selection = selection; self.style = style; self.created = created
    }
}
public struct RecentDocument: Codable, Sendable, Identifiable {
    public var id: UUID; public var url: URL; public var bookmark: Data?; public var resourceID: String; public var title: String; public var revision: String; public var location: DocumentLocation?; public var accessed: Date
    public init(id: UUID, url: URL, bookmark: Data?, resourceID: String, title: String, revision: String, location: DocumentLocation? = nil, accessed: Date = Date()) { self.id = id; self.url = url; self.bookmark = bookmark; self.resourceID = resourceID; self.title = title; self.revision = revision; self.location = location; self.accessed = accessed }
}
public struct RenderKey: Hashable, Sendable {
    public var document: DocumentIdentity; public var pageIndex: Int; public var rotation: Int; public var scaleStep: Int; public var column: Int; public var row: Int; public var preview: Bool
    public init(document: DocumentIdentity, pageIndex: Int, rotation: Int, scaleStep: Int, column: Int = 0, row: Int = 0, preview: Bool = false) { self.document = document; self.pageIndex = pageIndex; self.rotation = rotation; self.scaleStep = scaleStep; self.column = column; self.row = row; self.preview = preview }
    public var scale: Double { pow(2, Double(scaleStep) / 2) }
    public static func scaleStep(for scale: Double) -> Int { Int(ceil(log2(max(0.125, min(16, scale))) * 2)) }
}
public struct RenderRequest: Sendable {
    public var key: RenderKey; public var rect: CGRect; public var priority: Int
    public init(key: RenderKey, rect: CGRect, priority: Int) { self.key = key; self.rect = rect; self.priority = priority }
}
