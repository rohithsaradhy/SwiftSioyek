import Foundation
import CoreGraphics

public struct ExternalSearchSettings: Codable, Equatable, Sendable {
    public var searchURLs: [String: String]
    public var middleClickSearchEngine: String
    public var shiftMiddleClickSearchEngine: String

    public init(searchURLs: [String: String] = Self.defaultURLs, middleClickSearchEngine: String = "s", shiftMiddleClickSearchEngine: String = "l") {
        self.searchURLs = searchURLs
        self.middleClickSearchEngine = middleClickSearchEngine
        self.shiftMiddleClickSearchEngine = shiftMiddleClickSearchEngine
    }

    // The same URL prefixes and engine letters as Sioyek's prefs.config.
    public static let defaultURLs = [
        "s": "https://scholar.google.com/scholar?q=",
        "l": "http://gen.lib.rus.ec/scimag/?q=",
        "g": "https://www.google.com/search?q="
    ]

    public func validate() throws {
        for (letter, prefix) in searchURLs {
            guard Self.isEngineLetter(letter) else { throw SearchError.invalid("Search engine keys must be single lowercase letters a–z.") }
            guard let url = URL(string: prefix), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.fragment == nil,
                  !prefix.contains(where: { $0.isWhitespace }) else {
                throw SearchError.invalid("Engine \(letter) needs an HTTP or HTTPS URL prefix without spaces or a fragment.")
            }
        }
        for letter in [middleClickSearchEngine, shiftMiddleClickSearchEngine] {
            guard Self.isEngineLetter(letter), searchURLs[letter] != nil else {
                throw SearchError.invalid("Each middle-click engine must name a configured letter in searchURLs.")
            }
        }
    }

    public func url(for text: String, engine: String) throws -> URL {
        guard Self.isEngineLetter(engine), let prefix = searchURLs[engine] else { throw SearchError.missingEngine(engine) }
        let query = Self.normalizedQuery(text)
        guard !query.isEmpty else { throw SearchError.emptySelection }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = URL(string: prefix + encoded), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.fragment == nil else {
            throw SearchError.invalid("Engine \(engine) has an invalid search URL. Check Settings → External Search.")
        }
        return url
    }

    public static func normalizedQuery(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00ad}", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func isEngineLetter(_ value: String) -> Bool { value.utf8.count == 1 && value.utf8.first.map { (97...122).contains($0) } == true }

    public enum SearchError: LocalizedError {
        case invalid(String), missingEngine(String), emptySelection
        public var errorDescription: String? {
            switch self {
            case .invalid(let message): message
            case .missingEngine(let letter): "No external search engine for '\(letter)'. Add it in Settings → External Search."
            case .emptySelection: "Select text before searching externally."
            }
        }
    }
}

extension PageText {
    /// A bounded, local guess for middle-click searches. Keep wrapped reference
    /// lines together, without crossing columns or the next numbered entry.
    public func externalSearchText(at point: CGPoint, geometry: PageGeometry) -> String? {
        let point = geometry.displayPoint(point)
        let candidates = lines.filter { !$0.bounds.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { (line: $0, rect: geometry.displayRect($0.bounds)) }
        guard let hit = candidates.filter({ $0.rect.insetBy(dx: -3, dy: -3).contains(point) }).min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) else { return nil }
        let column = candidates.filter {
            abs($0.rect.minX - hit.rect.minX) <= max(hit.rect.height * 3, 24) &&
            $0.rect.intersection(hit.rect.insetBy(dx: 0, dy: -2_000)).width > min($0.rect.width, hit.rect.width) * 0.5
        }.sorted { $0.rect.minY < $1.rect.minY }
        guard let index = column.firstIndex(where: { $0.line.range == hit.line.range }) else { return nil }
        func startsEntry(_ text: String) -> Bool { text.range(of: #"^\s*(?:\[\d+\]|\d+[.)])\s+"#, options: .regularExpression) != nil }
        func adjacent(_ a: Int, _ b: Int) -> Bool {
            let gap = column[b].rect.minY - column[a].rect.maxY
            let height = max(column[a].rect.height, column[b].rect.height)
            return gap >= -height * 0.25 && gap <= height * 0.9 && abs(column[a].rect.height - column[b].rect.height) <= height * 0.3
        }
        var lower = index, upper = index
        while lower > 0, index - lower < 3, !startsEntry(column[lower].line.text), adjacent(lower - 1, lower) { lower -= 1 }
        while upper + 1 < column.count, upper - lower < 5, !startsEntry(column[upper + 1].line.text), adjacent(upper, upper + 1) { upper += 1 }
        var query = column[lower...upper].map(\.line.text).joined(separator: "\n")
        query = query.replacingOccurrences(of: #"^\s*(?:\[\d+\]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        query = query.replacingOccurrences(of: #"(?<=\p{L})-\s*\n\s*(?=\p{L})"#, with: "", options: .regularExpression)
        query = ExternalSearchSettings.normalizedQuery(query)
        // Quoted titles are more useful than the surrounding citation metadata.
        if let range = query.range(of: #"[“\"]([^”\"\n]{4,})[”\"]"#, options: .regularExpression) { query = String(query[range].dropFirst().dropLast()) }
        return query.isEmpty ? nil : String(query.prefix(1_000))
    }
}
