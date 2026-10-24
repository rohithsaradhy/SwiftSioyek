import Foundation

public enum ReaderCommand: String, CaseIterable, Codable, Sendable {
    case open, recent, palette, search, chapterSearch, externalSearch, nextMatch, previousMatch, firstPage, lastPage, goToPage
    case screenDown, screenUp, moveDown, moveUp, moveLeft, moveRight, zoomIn, zoomOut, fitWidth, fitPage, smartFit, rotateRight, rotateLeft
    case outline, thumbnails, bookmarks, allBookmarks, highlights, allHighlights, addBookmark, deleteBookmark, addHighlight, deleteHighlight
    case setMark, goToMark, portal, goToPortal, deletePortal, togglePortal, preview, smartJump, back, forward
    case nextChapter, previousChapter, rulerDown, rulerUp, setRuler, linkHints, keyboardSelect, copy, selectAll, toggleSidebar, toggleSinglePage, exportPDF, settings
    public var title: String {
        switch self {
        case .open: "Open PDF…"; case .recent: "Open Recent Document"; case .palette: "Commands"
        case .search: "Find in Document"; case .chapterSearch: "Find in Chapter"; case .nextMatch: "Next Search Match"; case .previousMatch: "Previous Search Match"
        case .externalSearch: "External Search (then a–z)"
        case .firstPage: "First Page / Numbered Page"; case .lastPage: "Last Page"; case .goToPage: "Go to Page…"
        case .screenDown: "Scroll One Screen Down"; case .screenUp: "Scroll One Screen Up"; case .moveDown: "Scroll Down"; case .moveUp: "Scroll Up"; case .moveLeft: "Scroll Left"; case .moveRight: "Scroll Right"
        case .zoomIn: "Zoom In"; case .zoomOut: "Zoom Out"; case .fitWidth: "Fit Width"; case .fitPage: "Fit Page"; case .smartFit: "Fit Content Width"; case .rotateRight: "Rotate Clockwise"; case .rotateLeft: "Rotate Counterclockwise"
        case .outline: "Table of Contents"; case .thumbnails: "Page Thumbnails"; case .bookmarks: "Document Bookmarks"; case .allBookmarks: "All Bookmarks"; case .highlights: "Document Highlights"; case .allHighlights: "All Highlights"
        case .addBookmark: "Add Bookmark…"; case .deleteBookmark: "Delete Nearest Bookmark"; case .addHighlight: "Highlight Selection (then a–z)"; case .deleteHighlight: "Delete Selected Highlight"
        case .setMark: "Set Mark (then a–z / A–Z)"; case .goToMark: "Go to Mark (then a–z / A–Z)"
        case .portal: "Set Portal Source / Destination"; case .goToPortal: "Go to Nearest Portal"; case .deletePortal: "Delete Nearest Portal"; case .togglePortal: "Show / Hide Portal Window"
        case .preview: "Preview Reference"; case .smartJump: "Jump to Reference"; case .back: "Back"; case .forward: "Forward"
        case .nextChapter: "Next Chapter"; case .previousChapter: "Previous Chapter"; case .rulerDown: "Reading Ruler: Next Line"; case .rulerUp: "Reading Ruler: Previous Line"; case .setRuler: "Set Reading Ruler"
        case .linkHints: "Follow Link with Keyboard"; case .keyboardSelect: "Select Text with Keyboard"; case .copy: "Copy"; case .selectAll: "Select All Text"; case .toggleSidebar: "Show Contents Palette"; case .toggleSinglePage: "Toggle Single Page"; case .exportPDF: "Export Annotated Copy…"; case .settings: "Settings…"
        }
    }
}
public struct CommandInvocation: Equatable, Sendable {
    public var command: ReaderCommand; public var count: Int; public var argument: String?
    public init(_ command: ReaderCommand, count: Int = 1, argument: String? = nil) { self.command = command; self.count = count; self.argument = argument }
}
public struct KeyBindings: Codable, Sendable {
    public var version: Int = 2
    public var bindings: [String: ReaderCommand]
    public init(bindings: [String: ReaderCommand] = KeyBindings.defaults) { self.bindings = bindings }
    private enum CodingKeys: String, CodingKey { case version, bindings }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        bindings = try values.decode([String: ReaderCommand].self, forKey: .bindings)
        // Add the new default to older maps only when it does not conflict with
        // a custom sequence. Version 2 maps can explicitly leave it unbound.
        if version == 1 {
            if !bindings.values.contains(.externalSearch), !bindings.keys.contains(where: { $0.hasPrefix("s") }) { bindings["s"] = .externalSearch }
            version = 2
        }
    }
    public static let defaults: [String: ReaderCommand] = [
        "o": .open, "O": .recent, ":": .palette, "/": .search, "c/": .chapterSearch, "s": .externalSearch, "n": .nextMatch, "N": .previousMatch,
        "gg": .firstPage, "G": .lastPage, "<home>": .goToPage, "<space>": .screenDown, "<S-space>": .screenUp, "<pagedown>": .screenDown, "<pageup>": .screenUp,
        "<down>": .moveDown, "<up>": .moveUp, "<left>": .moveLeft, "<right>": .moveRight,
        "+": .zoomIn, "-": .zoomOut, "=": .fitWidth, "<f9>": .fitWidth, "<f10>": .smartFit, "r": .rotateRight, "R": .rotateLeft,
        "t": .outline, "b": .addBookmark, "db": .deleteBookmark, "gb": .bookmarks, "gB": .allBookmarks, "h": .addHighlight, "dh": .deleteHighlight, "gh": .highlights, "gH": .allHighlights,
        "m": .setMark, "`": .goToMark, "p": .portal, "gp": .goToPortal, "dp": .deletePortal, "<tab>": .goToPortal, "<f12>": .togglePortal,
        "l": .preview, "]": .smartJump, "<backspace>": .back, "<S-backspace>": .forward, "gc": .nextChapter, "gC": .previousChapter,
        "j": .rulerDown, "k": .rulerUp, "v": .keyboardSelect, "f": .linkHints
    ]
    public func validate() throws {
        guard version == 2 else { throw BindingError.invalid("Unsupported bindings version \(version).") }
        for key in bindings.keys {
            guard !key.isEmpty, key.count <= 64, !key.first!.isNumber, key != "<escape>" else { throw BindingError.invalid("Invalid key sequence: \(key)") }
            guard !bindings.keys.contains(where: { $0 != key && $0.hasPrefix(key) }) else { throw BindingError.invalid("Ambiguous prefix: \(key)") }
            let supported: Set<String> = ["<home>", "<space>", "<S-space>", "<pagedown>", "<pageup>", "<down>", "<up>", "<left>", "<right>", "<f9>", "<f10>", "<f12>", "<tab>", "<backspace>", "<S-backspace>"]
            var remainder = key[...]
            while !remainder.isEmpty {
                if remainder.first == "<", let close = remainder.firstIndex(of: ">") {
                    let token = String(remainder[...close]); guard supported.contains(token) else { throw BindingError.invalid("Unsupported named key: \(token)") }; remainder = remainder[remainder.index(after: close)...]
                } else { remainder.removeFirst() }
            }
        }
    }
    public enum BindingError: LocalizedError { case invalid(String); public var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } } }
}
public struct KeySequenceMachine: Sendable {
    public var bindings: KeyBindings
    public private(set) var pending = ""
    private var number = ""
    private var argumentCommand: ReaderCommand?
    private var argumentCount = 1
    private static let argumentCommands: Set<ReaderCommand> = [.setMark, .goToMark, .addHighlight, .externalSearch]
    public init(bindings: KeyBindings = KeyBindings()) { self.bindings = bindings }
    public mutating func reset() { pending = ""; number = ""; argumentCommand = nil; argumentCount = 1 }
    public mutating func expectArgument(for command: ReaderCommand, count: Int = 1) {
        reset(); guard Self.argumentCommands.contains(command) else { return }
        argumentCommand = command; argumentCount = count
    }
    public var status: String { number + pending + (argumentCommand == nil ? "" : " …") }
    public mutating func feed(_ token: String) -> CommandInvocation? {
        if token == "<escape>" { reset(); return nil }
        if let command = argumentCommand {
            let count = argumentCount; reset()
            guard token.count == 1, token.first?.isASCII == true, token.first?.isLetter == true else { return nil }
            if command == .externalSearch, token != token.lowercased() { return nil }
            return CommandInvocation(command, count: count, argument: token)
        }
        if pending.isEmpty, token.count == 1, token.first?.isNumber == true { if number.count < 6 { number += token }; return nil }
        pending += token
        if let command = bindings.bindings[pending] {
            let count = max(1, min(100_000, Int(number) ?? 1))
            if Self.argumentCommands.contains(command) { argumentCommand = command; argumentCount = count; pending = ""; number = ""; return nil }
            let resolved = command == .lastPage && !number.isEmpty ? ReaderCommand.firstPage : command
            reset(); return CommandInvocation(resolved, count: count)
        }
        if !bindings.bindings.keys.contains(where: { $0.hasPrefix(pending) }) { reset() }
        return nil
    }
}
