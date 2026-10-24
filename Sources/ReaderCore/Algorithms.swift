import Foundation
import CoreGraphics

public struct CostCache<Key: Hashable, Value> {
    private struct Entry { var value: Value; var cost: Int; var stamp: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    public private(set) var cost = 0
    public var limit: Int { didSet { evict() } }
    public init(limit: Int) { self.limit = limit }
    public var count: Int { entries.count }
    public mutating func value(for key: Key) -> Value? { guard var entry = entries[key] else { return nil }; clock &+= 1; entry.stamp = clock; entries[key] = entry; return entry.value }
    public mutating func insert(_ value: Value, for key: Key, cost newCost: Int) {
        if let old = entries.removeValue(forKey: key) { cost -= old.cost }
        guard newCost <= limit else { return }
        clock &+= 1; entries[key] = Entry(value: value, cost: max(0, newCost), stamp: clock); cost += max(0, newCost); evict()
    }
    public mutating func removeAll() { entries.removeAll(); cost = 0 }
    private mutating func evict() { while cost > limit, let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp }) { cost -= oldest.value.cost; entries.removeValue(forKey: oldest.key) } }
}

public struct NavigationHistory: Sendable {
    public private(set) var entries: [DocumentLocation] = []
    public private(set) var index = -1
    public init() {}
    public mutating func visit(_ location: DocumentLocation) {
        if index >= 0, entries[index] == location { return }
        if index + 1 < entries.count { entries.removeSubrange((index + 1)..<entries.count) }
        entries.append(location); if entries.count > 500 { entries.removeFirst() }; index = entries.count - 1
    }
    /// Save the displayed position within the current visit. Scrolling and
    /// viewport constraints must not create new steps or discard forward history.
    public mutating func updateCurrent(_ location: DocumentLocation) {
        guard index >= 0 else { visit(location); return }
        entries[index] = location
    }
    public mutating func back(from current: DocumentLocation) -> DocumentLocation? {
        updateCurrent(current)
        guard index > 0 else { return nil }; index -= 1; return entries[index]
    }
    public mutating func forward(from current: DocumentLocation? = nil) -> DocumentLocation? {
        if let current { updateCurrent(current) }
        guard index + 1 < entries.count else { return nil }; index += 1; return entries[index]
    }
}

public struct PageLayout: Sendable {
    public private(set) var frames: [CGRect] = []
    public private(set) var contentSize = CGSize.zero
    private var isSinglePage = false
    public init(pages: [PageGeometry], zoom: Double, rotation: Int, viewportWidth: Double, singlePage: Int? = nil) {
        isSinglePage = singlePage != nil
        let width = max(viewportWidth, (pages.map { $0.size(adding: rotation).width * zoom }.max() ?? 0) + 32)
        var y = 16.0
        for page in pages {
            let size = page.size(adding: rotation)
            if let selected = singlePage, selected != page.index { frames.append(.null); continue }
            let frame = CGRect(x: (width - size.width * zoom) / 2, y: y, width: size.width * zoom, height: size.height * zoom)
            frames.append(frame); y = frame.maxY + 16
        }
        contentSize = CGSize(width: width, height: y)
    }
    public func visible(in rect: CGRect) -> [Int] {
        // Binary search over the continuous layout; single-page null frames use a tiny fallback.
        if isSinglePage { return frames.indices.filter { !frames[$0].isNull && frames[$0].intersects(rect) } }
        var lo = 0, hi = frames.count
        while lo < hi { let mid = (lo + hi) / 2; if frames[mid].maxY < rect.minY { lo = mid + 1 } else { hi = mid } }
        var result: [Int] = [], index = lo
        while index < frames.count, frames[index].minY <= rect.maxY { if frames[index].intersects(rect) { result.append(index) }; index += 1 }
        return result
    }
}

public struct SearchQuery: Sendable {
    public var text: String; public var pages: Range<Int>
    public init(_ input: String, pageCount: Int, chapter: Range<Int>? = nil) {
        text = input; pages = chapter ?? 0..<max(0, pageCount)
        if input.first == "<", let close = input.firstIndex(of: ">") {
            let values = input[input.index(after: input.startIndex)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if values.count == 2, values[0] > 0, values[1] >= values[0], values[0] <= pageCount {
                pages = (values[0] - 1)..<min(pageCount, values[1]); text = String(input[input.index(after: close)...])
            }
        }
    }
    public func matches(in string: String, page: Int) -> [SearchHit] {
        guard !text.isEmpty else { return [] }
        let source = string as NSString
        var offset = 0, result: [SearchHit] = []
        while offset < source.length {
            let range = source.range(of: text, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: offset, length: source.length - offset))
            guard range.location != NSNotFound, range.length > 0 else { break }
            let start = max(0, range.location - 45), end = min(source.length, NSMaxRange(range) + 65)
            result.append(SearchHit(pageIndex: page, range: TextRange(range), excerpt: source.substring(with: NSRange(location: start, length: end - start)).replacingOccurrences(of: "\n", with: " ")))
            offset = NSMaxRange(range)
        }
        return result
    }
}

public struct ReferenceTarget: Sendable {
    public var label: String; public var pageIndex: Int; public var point: CGPoint
    public init(label: String, pageIndex: Int, point: CGPoint) { self.label = label; self.pageIndex = pageIndex; self.point = point }
}
public enum ReferenceResolver {
    public static func key(in text: String) -> String? {
        let patterns = [#"(?i)\b(fig(?:ure)?\.?|table|eq(?:uation)?\.?)\s*\(?([A-Z]?\d+(?:[.\-]\d+)*[a-z]?)\)?"#, #"\[(\d+)\]"#, #"^\s*\((\d+(?:\.\d+)*)\)\s*$"#]
        for (index, pattern) in patterns.enumerated() {
            guard let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { continue }
            let string = text as NSString
            if index == 0 {
                let kind = string.substring(with: match.range(at: 1)).lowercased()
                return "\(kind.hasPrefix("fig") ? "figure" : kind.hasPrefix("eq") ? "equation" : "table"):\(string.substring(with: match.range(at: 2)).lowercased())"
            }
            return "\(index == 1 ? "reference" : "equation"):\(string.substring(with: match.range(at: 1)))"
        }
        return nil
    }
    public static func nearestPortal(in records: [LibraryRecord], to location: DocumentLocation) -> LibraryRecord? {
        records.filter { $0.kind == .portal && $0.location.document.id == location.document.id && $0.location.document.revision == location.document.revision }.min {
            func distance(_ record: LibraryRecord) -> Double { abs(Double(record.location.pageIndex - location.pageIndex) * 100_000 + location.point.y - record.location.point.y) }
            return distance($0) < distance($1)
        }
    }
}
