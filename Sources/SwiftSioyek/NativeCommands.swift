import ReaderCore

extension ReaderCommand {
    var paletteCategory: String {
        switch self {
        case .open, .recent, .exportPDF: "Documents"
        case .palette, .settings: "Application"
        case .search, .chapterSearch, .externalSearch, .nextMatch, .previousMatch: "Search"
        case .zoomIn, .zoomOut, .fitWidth, .fitPage, .smartFit, .rotateRight, .rotateLeft, .toggleSinglePage: "View"
        case .bookmarks, .allBookmarks, .addBookmark, .deleteBookmark: "Bookmarks"
        case .highlights, .allHighlights, .addHighlight, .deleteHighlight: "Highlights"
        case .portal, .goToPortal, .deletePortal, .togglePortal: "Portals"
        case .preview, .smartJump, .setRuler, .rulerDown, .rulerUp: "Research"
        case .keyboardSelect, .copy, .selectAll: "Selection"
        default: "Navigation"
        }
    }
    var paletteSymbol: String {
        switch self {
        case .open, .recent: "doc"
        case .exportPDF: "square.and.arrow.up"
        case .settings: "gearshape"
        case .palette: "command"
        case .search, .chapterSearch, .nextMatch, .previousMatch: "magnifyingglass"
        case .externalSearch: "globe"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .fitWidth, .smartFit: "arrow.left.and.right"
        case .fitPage: "arrow.up.left.and.arrow.down.right"
        case .rotateLeft, .rotateRight: "rotate.right"
        case .outline, .toggleSidebar: "list.bullet"
        case .thumbnails, .toggleSinglePage: "rectangle.on.rectangle"
        case .bookmarks, .allBookmarks, .addBookmark, .deleteBookmark: "bookmark"
        case .highlights, .allHighlights, .addHighlight, .deleteHighlight: "highlighter"
        case .portal, .goToPortal, .deletePortal, .togglePortal: "macwindow.on.rectangle"
        case .preview: "eye"
        case .smartJump, .linkHints: "link"
        case .back: "chevron.left"
        case .forward: "chevron.right"
        case .setMark, .goToMark: "mappin"
        case .setRuler, .rulerDown, .rulerUp: "ruler"
        case .keyboardSelect, .copy, .selectAll: "text.cursor"
        default: "arrow.up.arrow.down"
        }
    }
    var macShortcut: String? {
        switch self {
        case .open: "⌘O"
        case .recent: "⇧⌘O"
        case .palette: "⌘K"
        case .settings: "⌘,"
        case .search: "⌘F  /"
        case .nextMatch: "⌘G  n"
        case .previousMatch: "⇧⌘G  N"
        case .outline: "⌘T  t"
        case .fitPage: "⌘0"
        case .zoomIn: "⌘+"
        case .zoomOut: "⌘−"
        case .goToPage: "⌘L"
        case .exportPDF: "⇧⌘E"
        case .copy: "⌘C"
        case .selectAll: "⌘A"
        default: nil
        }
    }
}
