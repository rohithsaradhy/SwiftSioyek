import XCTest
import CoreGraphics
@testable import ReaderCore

final class CoreTests: XCTestCase {
    func testCoordinateRoundTrips() {
        for rotation in [0, 90, 180, 270] {
            let geometry = PageGeometry(index: 0, cropBox: CGRect(x: 37, y: 19, width: 612, height: 792), rotation: rotation)
            for extra in [0, 90, 180, 270] {
                let point = CGPoint(x: 123, y: 487)
                let restored = geometry.pdfPoint(geometry.displayPoint(point, adding: extra), adding: extra)
                XCTAssertEqual(restored.x, point.x, accuracy: 0.0001); XCTAssertEqual(restored.y, point.y, accuracy: 0.0001)
            }
        }
    }
    func testRotatedDisplayCornersAndCropOrigin() {
        let crop = CGRect(x: 25, y: 21, width: 558, height: 740)
        let page = PageGeometry(index: 0, cropBox: crop, rotation: 90)
        XCTAssertEqual(page.size(), CGSize(width: 740, height: 558))
        XCTAssertEqual(page.displayPoint(CGPoint(x: crop.minX, y: crop.maxY)), CGPoint(x: 740, y: 0))
        XCTAssertEqual(page.displayRect(crop), CGRect(x: 0, y: 0, width: 740, height: 558))
    }
    func testSearchAnchorRevealsMatchAfterRotationAndCropping() {
        let viewport = CGSize(width: 900, height: 600)
        let word = CGRect(x: 174, y: 65, width: 46, height: 12)
        for nativeRotation in [0, 90, 180, 270] {
            let geometry = PageGeometry(index: 3, cropBox: CGRect(x: 25, y: 21, width: 558, height: 740), rotation: nativeRotation)
            for rotation in [0, 90, 180, 270] {
                for zoom in [0.75, 1.0, 2.0] {
                    let anchor = geometry.readingAnchor(revealing: word, viewport: viewport, zoom: zoom, adding: rotation)
                    let origin = geometry.displayPoint(anchor, adding: rotation)
                    let visible = CGRect(origin: origin, size: CGSize(width: viewport.width / zoom, height: viewport.height / zoom))
                    XCTAssertTrue(visible.contains(geometry.displayRect(word, adding: rotation)))
                }
            }
        }
    }
    func testFigurePreviewAnchorHandlesRotationCropAndPageTop() {
        let viewport = CGSize(width: 620, height: 380)
        for nativeRotation in [0, 90, 180, 270] {
            let geometry = PageGeometry(index: 0, cropBox: CGRect(x: 25, y: 21, width: 558, height: 740), rotation: nativeRotation)
            for rotation in [0, 90, 180, 270] {
                for zoom in [0.75, 1.0, 2.0] {
                    let caption = CGRect(x: 300, y: 220, width: 200, height: 12)
                    let anchor = geometry.figurePreviewAnchor(caption: caption, viewport: viewport, zoom: zoom, adding: rotation)
                    let origin = geometry.displayPoint(anchor, adding: rotation)
                    let target = geometry.displayRect(caption, adding: rotation)
                    let visible = CGRect(origin: origin, size: CGSize(width: viewport.width / zoom, height: viewport.height / zoom))
                    XCTAssertGreaterThanOrEqual(origin.y, 0, "Do not scroll into the preceding page")
                    XCTAssertTrue(visible.contains(CGPoint(x: target.midX, y: target.minY)))
                    XCTAssertTrue(visible.contains(CGPoint(x: target.midX, y: max(0, target.minY - 200 / zoom))), "Reveal artwork above the caption after rotation")
                }
            }
        }
    }
    func testPageLayoutVirtualization() {
        let pages = (0..<1_000).map { PageGeometry(index: $0, cropBox: CGRect(x: 0, y: 0, width: 612, height: 792)) }
        let layout = PageLayout(pages: pages, zoom: 1, rotation: 0, viewportWidth: 900)
        let visible = layout.visible(in: CGRect(x: 0, y: layout.frames[500].minY, width: 900, height: 1_000))
        XCTAssertEqual(visible, [500, 501]); XCTAssertEqual(layout.frames.count, 1_000)
        let single = PageLayout(pages: pages, zoom: 1, rotation: 0, viewportWidth: 900, singlePage: 600)
        XCTAssertEqual(single.visible(in: CGRect(x: 0, y: 0, width: 900, height: 1_000)), [600])
    }
    func testCacheEvictsByCostAndRecency() {
        var cache = CostCache<String, String>(limit: 10)
        cache.insert("one", for: "a", cost: 4); cache.insert("two", for: "b", cost: 4)
        XCTAssertEqual(cache.value(for: "a"), "one")
        cache.insert("three", for: "c", cost: 4)
        XCTAssertNil(cache.value(for: "b")); XCTAssertLessThanOrEqual(cache.cost, 10)
        cache.insert("too big", for: "huge", cost: 11); XCTAssertNil(cache.value(for: "huge"))
        cache.limit = 3; XCTAssertEqual(cache.cost, 0)
    }
    func testKeysCountsArgumentsAndEscape() throws {
        try KeyBindings().validate()
        var keys = KeySequenceMachine()
        XCTAssertNil(keys.feed("1")); XCTAssertNil(keys.feed("5")); XCTAssertNil(keys.feed("0")); XCTAssertNil(keys.feed("g"))
        XCTAssertEqual(keys.feed("g"), CommandInvocation(.firstPage, count: 150))
        XCTAssertNil(keys.feed("m")); XCTAssertEqual(keys.feed("A"), CommandInvocation(.setMark, argument: "A"))
        XCTAssertNil(keys.feed("h")); XCTAssertEqual(keys.feed("a"), CommandInvocation(.addHighlight, argument: "a"))
        XCTAssertNil(keys.feed("g")); XCTAssertNil(keys.feed("<escape>")); XCTAssertEqual(keys.status, "")
        XCTAssertEqual(keys.feed("n"), CommandInvocation(.nextMatch))
    }
    func testInvalidAndAmbiguousBindingsAreRejected() {
        XCTAssertThrowsError(try KeyBindings(bindings: ["g": .palette, "gg": .firstPage]).validate())
        XCTAssertThrowsError(try KeyBindings(bindings: ["1g": .palette]).validate())
        XCTAssertThrowsError(try KeyBindings(bindings: ["<escape>": .palette]).validate())
    }
    func testMenuArgumentCommandsDoNotDependOnUserBindings() {
        var keys = KeySequenceMachine(bindings: KeyBindings(bindings: ["q": .setMark]))
        keys.expectArgument(for: .addHighlight)
        XCTAssertEqual(keys.feed("c"), CommandInvocation(.addHighlight, argument: "c"))
        keys.expectArgument(for: .setMark)
        XCTAssertNil(keys.feed("<escape>"))
        XCTAssertEqual(keys.status, "")
        keys.expectArgument(for: .goToMark)
        XCTAssertNil(keys.feed("é"))
        XCTAssertEqual(keys.status, "")
        XCTAssertNil(keys.feed("q"))
        XCTAssertEqual(keys.feed("Z"), CommandInvocation(.setMark, argument: "Z"))
    }
    func testExternalSearchKeysAndCancellation() {
        var keys = KeySequenceMachine()
        for engine in ["s", "l", "g", "x"] {
            XCTAssertNil(keys.feed("s"))
            XCTAssertEqual(keys.feed(engine), CommandInvocation(.externalSearch, argument: engine))
        }
        XCTAssertNil(keys.feed("s")); XCTAssertNil(keys.feed("<escape>"))
        XCTAssertEqual(keys.feed("n"), CommandInvocation(.nextMatch))
        XCTAssertNil(keys.feed("s")); XCTAssertNil(keys.feed("G"))
        XCTAssertNil(keys.feed("s")); XCTAssertNil(keys.feed("é"))
        keys = KeySequenceMachine(bindings: KeyBindings(bindings: ["q": .externalSearch]))
        XCTAssertNil(keys.feed("q")); XCTAssertEqual(keys.feed("s"), CommandInvocation(.externalSearch, argument: "s"))
        keys.expectArgument(for: .externalSearch)
        XCTAssertEqual(keys.feed("g"), CommandInvocation(.externalSearch, argument: "g"))
    }
    func testOlderKeyMapsGainExternalSearchWithoutOverwritingCustomKeys() throws {
        for (map, expected) in [(#"{"version":1,"bindings":{"n":"nextMatch"}}"#, ReaderCommand.externalSearch),
                                (#"{"version":1,"bindings":{"s":"search"}}"#, .search)] {
            let decoded = try JSONDecoder().decode(KeyBindings.self, from: Data(map.utf8))
            try decoded.validate(); XCTAssertEqual(decoded.version, 2); XCTAssertEqual(decoded.bindings["s"], expected)
        }
        let custom = try JSONDecoder().decode(KeyBindings.self, from: Data(#"{"version":1,"bindings":{"ss":"search"}}"#.utf8))
        try custom.validate(); XCTAssertNil(custom.bindings["s"])
        let unbound = KeyBindings(bindings: ["n": .nextMatch])
        XCTAssertNil(try JSONDecoder().decode(KeyBindings.self, from: JSONEncoder().encode(unbound)).bindings["s"])
    }
    func testExternalSearchURLsEncodeSelectionAsOneQueryValue() throws {
        let settings = ExternalSearchSettings(); try settings.validate()
        let text = "  C++ & café / α?\n x=y#z + 100% 😀  "
        for engine in ["s", "l", "g"] {
            let url = try settings.url(for: text, engine: engine)
            let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.queryItems?.count, 1)
            XCTAssertEqual(parts.queryItems?.first?.name, "q")
            XCTAssertEqual(parts.queryItems?.first?.value, "C++ & café / α? x=y#z + 100% 😀")
            XCTAssertNil(parts.fragment)
            XCTAssertFalse(url.absoluteString.contains("+"))
        }
        let custom = ExternalSearchSettings(searchURLs: ["x": "https://example.com/find?language=en&term="], middleClickSearchEngine: "x", shiftMiddleClickSearchEngine: "x")
        try custom.validate()
        XCTAssertEqual(URLComponents(url: try custom.url(for: "a&b", engine: "x"), resolvingAgainstBaseURL: false)?.queryItems?.last?.value, "a&b")
        XCTAssertEqual(try JSONDecoder().decode(ExternalSearchSettings.self, from: JSONEncoder().encode(custom)), custom)
        XCTAssertThrowsError(try settings.url(for: "\n  ", engine: "s"))
        XCTAssertThrowsError(try settings.url(for: "title", engine: "x"))
        XCTAssertThrowsError(try settings.url(for: "title", engine: "S"))
    }
    func testInvalidExternalSearchSettingsAreRejected() {
        for prefix in ["file:///tmp/", "javascript:alert(1)", "https://example.com/#q=", "https://", "https://example.com/?q= "] {
            XCTAssertThrowsError(try ExternalSearchSettings(searchURLs: ["s": prefix], shiftMiddleClickSearchEngine: "s").validate(), prefix)
        }
        XCTAssertThrowsError(try ExternalSearchSettings(searchURLs: ["S": "https://example.com/?q="]).validate())
        XCTAssertThrowsError(try ExternalSearchSettings(middleClickSearchEngine: "x").validate())
    }
    func testMiddleClickSearchGuessesWrappedTitleWithinItsColumnAndEntry() throws {
        let geometry = PageGeometry(index: 0, cropBox: CGRect(x: 0, y: 0, width: 612, height: 792))
        let lines = [
            TextLine(text: "[1] A. Author. “A wrapped", range: TextRange(0, 25), bounds: CGRect(x: 40, y: 700, width: 220, height: 12)),
            TextLine(text: "paper title”. Journal, 2026.", range: TextRange(26, 28), bounds: CGRect(x: 52, y: 683, width: 200, height: 12)),
            TextLine(text: "[2] Another reference", range: TextRange(55, 22), bounds: CGRect(x: 40, y: 666, width: 200, height: 12)),
            TextLine(text: "Unrelated right column", range: TextRange(78, 22), bounds: CGRect(x: 330, y: 700, width: 220, height: 12))
        ]
        let page = PageText(pageIndex: 0, text: "", glyphs: [], lines: lines, links: [])
        XCTAssertEqual(page.externalSearchText(at: CGPoint(x: 100, y: 689), geometry: geometry), "A wrapped paper title")
        XCTAssertEqual(page.externalSearchText(at: CGPoint(x: 400, y: 705), geometry: geometry), "Unrelated right column")
        XCTAssertNil(page.externalSearchText(at: CGPoint(x: 300, y: 705), geometry: geometry))
        XCTAssertNil(page.externalSearchText(at: CGPoint(x: 100, y: 200), geometry: geometry))
    }
    func testSearchRangesAndUnicodeOffsets() {
        let query = SearchQuery("<2,4>cafe", pageCount: 10)
        XCTAssertEqual(query.pages, 1..<4); XCTAssertEqual(query.text, "cafe")
        let source = "😀 CAFÉ and café"
        let hits = query.matches(in: source, page: 2)
        XCTAssertEqual(hits.count, 2); XCTAssertEqual(hits[0].range.location, 3)
        for hit in hits { XCTAssertTrue((source as NSString).substring(with: hit.range.nsRange).localizedCaseInsensitiveContains("café")) }
        XCTAssertEqual(SearchQuery("word", pageCount: 10, chapter: 3..<6).pages, 3..<6)
        XCTAssertTrue(SearchQuery("", pageCount: 10).matches(in: source, page: 0).isEmpty)
    }
    func testHistoryBranchesAfterGoingBack() {
        let identity = DocumentIdentity(id: UUID(), revision: "1")
        let a = DocumentLocation(document: identity, pageIndex: 0), b = DocumentLocation(document: identity, pageIndex: 10), c = DocumentLocation(document: identity, pageIndex: 20)
        var history = NavigationHistory(); history.visit(a); history.visit(b)
        XCTAssertEqual(history.back(from: b), a); XCTAssertEqual(history.forward(), b)
        XCTAssertEqual(history.back(from: b), a); history.visit(c); XCTAssertNil(history.forward()); XCTAssertEqual(history.entries, [a, c])
    }
    func testHistoryReturnsToSourceWhenLinkDestinationIsConstrained() {
        let identity = DocumentIdentity(id: UUID(), revision: "1")
        let source = DocumentLocation(document: identity, pageIndex: 0, point: CGPoint(x: 0, y: 640), zoom: 1.7)
        let target = DocumentLocation(document: identity, pageIndex: 5, point: CGPoint(x: 42, y: 730), zoom: 1.7)
        var displayed = target
        displayed.point.x = 0 // The viewport constrains horizontal scrolling to the page width.
        var history = NavigationHistory(); history.visit(source); history.visit(target)

        XCTAssertEqual(history.back(from: displayed), source)
        XCTAssertEqual(history.entries, [source, displayed])
        XCTAssertEqual(history.forward(), displayed)
        // Restoring a position can also round coordinates to backing pixels.
        displayed.point.y += 0.25
        XCTAssertEqual(history.back(from: displayed), source)
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.forward(), displayed)
    }
    func testHistoryBackAfterReadingDoesNotCreateAnotherJump() {
        let identity = DocumentIdentity(id: UUID(), revision: "1")
        let source = DocumentLocation(document: identity, pageIndex: 0, point: CGPoint(x: 0, y: 650))
        let target = DocumentLocation(document: identity, pageIndex: 5)
        let reading = DocumentLocation(document: identity, pageIndex: 6, point: CGPoint(x: 0, y: 450), zoom: 2, rotation: 90)
        var history = NavigationHistory(); history.visit(source); history.visit(target)

        XCTAssertEqual(history.back(from: reading), source)
        XCTAssertNil(history.back(from: source))
        XCTAssertEqual(history.forward(), reading)
    }
    func testHistoryPreservesReadingPositionAcrossForwardAndBranches() {
        let identity = DocumentIdentity(id: UUID(), revision: "1")
        let a = DocumentLocation(document: identity, pageIndex: 0)
        let b = DocumentLocation(document: identity, pageIndex: 5)
        let c = DocumentLocation(document: identity, pageIndex: 10)
        var reading = b; reading.point = CGPoint(x: 0, y: 450)
        var history = NavigationHistory(); history.visit(a); history.visit(b)
        history.updateCurrent(reading); history.visit(c)
        XCTAssertEqual(history.entries, [a, reading, c])
        XCTAssertEqual(history.back(from: c), reading)
        reading.zoom = 2
        XCTAssertEqual(history.forward(from: reading), c)
        XCTAssertEqual(history.back(from: c), reading)
        XCTAssertEqual(history.back(from: reading), a)
        XCTAssertEqual(history.forward(from: a), reading)
        history.updateCurrent(reading); history.visit(a)
        XCTAssertNil(history.forward())
        XCTAssertEqual(history.entries, [a, reading, a])
    }
    func testReferenceKeys() {
        XCTAssertEqual(ReferenceResolver.key(in: "See Fig. 2.19 for details"), "figure:2.19")
        XCTAssertEqual(ReferenceResolver.key(in: "Equation (3.2)"), "equation:3.2")
        XCTAssertEqual(ReferenceResolver.key(in: "Table A2.1"), "table:a2.1")
        XCTAssertEqual(ReferenceResolver.key(in: "[42] A citation"), "reference:42")
        XCTAssertNil(ReferenceResolver.key(in: "Some ordinary prose"))
    }
    func testNearestPortalExcludesOtherDocumentsAndRevisions() {
        let identity = DocumentIdentity(id: UUID(), revision: "1"), other = DocumentIdentity(id: UUID(), revision: "1")
        let location = DocumentLocation(document: identity, pageIndex: 10, point: CGPoint(x: 10, y: 500))
        let near = LibraryRecord(kind: .portal, location: DocumentLocation(document: identity, pageIndex: 10, point: CGPoint(x: 10, y: 520)), title: "near")
        let far = LibraryRecord(kind: .portal, location: DocumentLocation(document: identity, pageIndex: 15), title: "far")
        let unrelated = LibraryRecord(kind: .portal, location: DocumentLocation(document: other, pageIndex: 10), title: "other")
        XCTAssertEqual(ReferenceResolver.nearestPortal(in: [far, unrelated, near], to: location)?.id, near.id)
        var updated = location; updated.document.revision = "2"
        XCTAssertNil(ReferenceResolver.nearestPortal(in: [near], to: updated))
    }
    func testLocationsAndHighlightGeometryRoundTripThroughJSON() throws {
        let identity = DocumentIdentity(id: UUID(), revision: "pdf-revision")
        let part = SelectionPart(pageIndex: 7, range: TextRange(10, 12), rects: [CGRect(x: 45, y: 112, width: 100, height: 14)], text: "Café αβγ")
        let record = LibraryRecord(kind: .highlight, location: DocumentLocation(document: identity, pageIndex: 7, point: CGPoint(x: 45, y: 126)), title: "Example", selection: [part], style: "c")
        XCTAssertEqual(try JSONDecoder().decode(LibraryRecord.self, from: JSONEncoder().encode(record)), record)
    }
}
