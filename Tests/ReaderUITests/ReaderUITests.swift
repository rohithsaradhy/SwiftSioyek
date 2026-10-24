import XCTest
import PDFServices

@MainActor
final class ReaderUITests: XCTestCase {
    private var directory: URL!
    private var app: XCUIApplication!
    private func startReader() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftSioyek-UI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FixtureFactory.makeDocument(at: directory.appendingPathComponent("paper.pdf"), pages: 30, title: "UI Research Paper", columns: true, scanned: false)
        app = XCUIApplication(); app.launchEnvironment["SWIFTSIOYEK_LIBRARY_ROOT"] = directory.appendingPathComponent("Library").path
        app.launchEnvironment["SWIFTSIOYEK_METRICS_OUTPUT"] = directory.appendingPathComponent("performance.json").path
        app.launchArguments = [directory.appendingPathComponent("paper.pdf").path]
        app.launch()
        XCTAssertTrue(app.windows["UI Research Paper"].waitForExistence(timeout: 15))
    }
    private func closeReader() { app?.terminate(); try? FileManager.default.removeItem(at: directory) }
    func testLinkBackAndForwardWithToolbarAndKeyboard() throws {
        try startReader(); defer { closeReader() }
        func expectPage(_ page: Int) {
            let position = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "\(page) / 30")).firstMatch
            XCTAssertTrue(position.waitForExistence(timeout: 5), "Expected page \(page)")
        }
        expectPage(1)
        let link = app.links["Go to page 6"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        let sourceFrame = link.frame
        func expectSource() {
            expectPage(1)
            XCTAssertEqual(link.frame.minX, sourceFrame.minX, accuracy: 1)
            XCTAssertEqual(link.frame.minY, sourceFrame.minY, accuracy: 1)
        }
        link.click()
        expectPage(6)
        app.toolbars.buttons["Back"].click()
        expectSource()
        app.toolbars.buttons["Forward"].click()
        expectPage(6)
        app.typeKey(.delete, modifierFlags: [])
        expectSource()
        app.typeKey(.delete, modifierFlags: .shift)
        expectPage(6)
        app.typeKey(.leftArrow, modifierFlags: .control)
        expectSource()
        app.typeKey(.rightArrow, modifierFlags: .control)
        expectPage(6)
        app.typeKey(.delete, modifierFlags: [])
        expectSource()
        app.typeText("faa")
        expectPage(6)
        app.typeKey(.delete, modifierFlags: [])
        expectSource()
    }
    func testSearchCommandsAndMultipleWindows() throws {
        try startReader(); defer { closeReader() }
        app.typeText("/")
        let palette = app.windows["Find in Document"]; XCTAssertTrue(palette.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows["UI Research Paper"].splitGroups.count, 0)
        let search = app.searchFields["palette.search"]; XCTAssertTrue(search.waitForExistence(timeout: 5)); search.click(); search.typeText("native")
        let row = app.tables["palette.results"].cells.firstMatch; XCTAssertTrue(row.waitForExistence(timeout: 10))
        let hittable = NSPredicate(format: "hittable == YES")
        expectation(for: hittable, evaluatedWith: row); waitForExpectations(timeout: 10)
        row.doubleClick()
        XCTAssertFalse(palette.exists)
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.windows["Commands"].waitForExistence(timeout: 5)); app.typeKey(.escape, modifierFlags: [])
        app.typeKey("n", modifierFlags: .command); XCTAssertEqual(app.windows.count, 2)
    }
    func testExternalSearchCommandsAndSettings() throws {
        try startReader(); defer { closeReader() }
        app.typeText("ss")
        XCTAssertTrue(app.staticTexts["Select text before searching externally"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Research"].click(); app.menuItems["External Search (then a–z)"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Search engine:'")).firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.typeText("v")
        for _ in 0..<12 { app.typeKey(.rightArrow, modifierFlags: []) }
        app.typeText("sx")
        XCTAssertTrue(app.staticTexts["No external search engine for 'x'. Add it in Settings → External Search."].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["Settings — Swift Sioyek"]; XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.radioButtons["External Search"].click()
        let editor = settings.textViews["settings.editor"]; XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click(); editor.typeKey("a", modifierFlags: .command)
        editor.typeText(#"{"searchURLs":{"x":"https://example.com/?q="},"middleClickSearchEngine":"x","shiftMiddleClickSearchEngine":"x"}"#)
        settings.buttons["Apply"].click()
        XCTAssertTrue(settings.staticTexts["Saved. All reader windows updated."].waitForExistence(timeout: 5))
        let saved = directory.appendingPathComponent("Library/ExternalSearch.json")
        let savedData = try Data(contentsOf: saved)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
        XCTAssertEqual(json["middleClickSearchEngine"] as? String, "x")
        editor.click(); editor.typeKey("a", modifierFlags: .command)
        editor.typeText(#"{"searchURLs":{"x":"file:///tmp/"},"middleClickSearchEngine":"x","shiftMiddleClickSearchEngine":"x"}"#)
        settings.buttons["Apply"].click()
        XCTAssertTrue(settings.staticTexts.matching(NSPredicate(format: "value CONTAINS 'needs an HTTP or HTTPS URL'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: saved), savedData)
        settings.buttons["Restore Defaults"].click(); settings.buttons["Apply"].click()
        XCTAssertTrue(settings.staticTexts["Saved. All reader windows updated."].waitForExistence(timeout: 5))
        settings.typeKey("w", modifierFlags: .command)
    }
    func testWheelScrollOverPagePreservesZoom() throws {
        try startReader(); defer { closeReader() }
        let reader = app.scrollViews["reader.viewport"]; XCTAssertTrue(reader.waitForExistence(timeout: 5))
        let line = app.staticTexts["Native Research Reader — page 1"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        let originalY = line.frame.minY
        let initialPosition = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH '1 / 30'")).firstMatch.value as? String
        line.scroll(byDeltaX: 0, deltaY: -150)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH '1 / 30'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThan(line.frame.minY, originalY - 20)
        reader.scroll(byDeltaX: 0, deltaY: -900)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH '2 / 30'")).firstMatch.waitForExistence(timeout: 5))
        let finalPosition = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH '2 / 30'")).firstMatch.value as? String
        XCTAssertEqual(initialPosition?.split(separator: "%").first?.split(separator: " ").last, finalPosition?.split(separator: "%").first?.split(separator: " ").last)
    }
    func testMarksHighlightsBookmarksAndPortal() throws {
        try startReader(); defer { closeReader() }
        app.typeText("ma5gg`a")
        app.typeText("v")
        for _ in 0..<12 { app.typeKey(.rightArrow, modifierFlags: []) }
        app.typeText("ha")
        app.typeText("b")
        let sheet = app.sheets.firstMatch; XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.textFields.firstMatch.typeText("Reading checkpoint"); sheet.buttons["OK"].click()
        app.typeText("p6ggp")
        app.menuBars.menuBarItems["Research"].click(); app.menuItems["Show / Hide Portal Window"].click()
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title BEGINSWITH 'Portal'")).firstMatch.waitForExistence(timeout: 5))
        app.windows["UI Research Paper"].click(); app.typeText("gb")
        XCTAssertTrue(app.tables.staticTexts["Reading checkpoint"].waitForExistence(timeout: 5))
    }
    func testSearchHighlightAlignment() throws {
        try startReader(); defer { closeReader() }
        let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftSioyek-validation")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        for (query, name) in [("<1,1>fluid", "fluid"), ("<1,1>typography", "typography"), ("<4,4>typography", "rotated-cropped")] {
            app.typeText("/")
            XCTAssertTrue(app.windows["Find in Document"].waitForExistence(timeout: 5))
            let field = app.searchFields["palette.search"]
            field.typeKey("a", modifierFlags: .command); field.typeText(query)
            XCTAssertTrue(app.tables["palette.results"].cells.firstMatch.waitForExistence(timeout: 10))
            app.typeKey(.return, modifierFlags: [])
            let match = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Match 1 of '")).firstMatch
            XCTAssertTrue(match.waitForExistence(timeout: 5))
            if name == "fluid" {
                app.typeText("n")
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Match 2 of '")).firstMatch.waitForExistence(timeout: 5))
                app.typeText("N"); XCTAssertTrue(match.waitForExistence(timeout: 5))
            }
            try app.windows["UI Research Paper"].screenshot().pngRepresentation.write(to: artifacts.appendingPathComponent("search-highlight-\(name).png"))
        }
    }
    func testSessionRestoration() throws {
        try startReader(); defer { closeReader() }
        app.typeText("8ggma")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launchArguments = []; app.launch()
        XCTAssertTrue(app.windows["UI Research Paper"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS '8 / 30'")).firstMatch.waitForExistence(timeout: 5))
    }
    func testPerformanceAndIdleWindow() throws {
        try startReader(); defer { closeReader() }
        for _ in 0..<4 { app.typeKey(.space, modifierFlags: []); app.typeKey(.space, modifierFlags: .shift) }
        for _ in 0..<8 { app.typeKey(.space, modifierFlags: []); app.typeKey(.space, modifierFlags: .shift) }
        app.typeText("gg")
        let data = try Data(contentsOf: directory.appendingPathComponent("performance.json"))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftSioyek-validation/UI-performance.json")
        print("SWIFTSIOYEK_ARTIFACTS=\(output.deletingLastPathComponent().path)")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.name = "Native reading performance"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThan(try XCTUnwrap(report["frameSamples"] as? Int), 50)
        XCTAssertLessThanOrEqual(try XCTUnwrap(report["peakRasterCacheMiB"] as? Double), 256)
        XCTAssertLessThan(try XCTUnwrap(report["maxActivePageViews"] as? Int), 10)
    }
    func testVisibleReaderLayout() throws {
        try startReader(); defer { closeReader() }
        app.typeKey("f", modifierFlags: .command)
        let palette = app.windows["Find in Document"]; XCTAssertTrue(palette.waitForExistence(timeout: 5))
        app.searchFields["palette.search"].typeText("native")
        XCTAssertTrue(app.tables["palette.results"].tableRows.firstMatch.waitForExistence(timeout: 10))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftSioyek-validation", isDirectory: true)
        print("SWIFTSIOYEK_ARTIFACTS=\(directory.path)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(app.searchFields["palette.search"].isHittable)
        try palette.screenshot().pngRepresentation.write(to: directory.appendingPathComponent("search-palette.png"))
        try app.debugDescription.write(to: directory.appendingPathComponent("reader-accessibility.txt"), atomically: true, encoding: .utf8)
        // Capturing the parent can make it key, dismissing the transient palette.
        try app.windows["UI Research Paper"].screenshot().pngRepresentation.write(to: directory.appendingPathComponent("reader-window.png"))
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.windows["Commands"].waitForExistence(timeout: 5))
        app.searchFields["palette.search"].typeText("zoom")
        try app.windows["Commands"].screenshot().pngRepresentation.write(to: directory.appendingPathComponent("command-palette.png"))
    }
    func testPaletteKeyboardNavigationAndFocus() throws {
        try startReader(); defer { closeReader() }
        app.typeKey("k", modifierFlags: .command)
        let commands = app.windows["Commands"]; XCTAssertTrue(commands.waitForExistence(timeout: 5))
        let diagnostics = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftSioyek-validation")
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        try app.debugDescription.write(to: diagnostics.appendingPathComponent("palette-accessibility.txt"), atomically: true, encoding: .utf8)
        try commands.screenshot().pngRepresentation.write(to: diagnostics.appendingPathComponent("palette-initial.png"))
        app.searchFields["palette.search"].typeText("Fit Page")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(commands.exists)
        app.typeText("/")
        let search = app.windows["Find in Document"]; XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.searchFields["palette.search"].typeText("native")
        XCTAssertTrue(app.tables["palette.results"].tableRows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(.downArrow, modifierFlags: []); app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(search.exists)
        app.typeText("t")
        XCTAssertTrue(app.windows["Contents"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.typeText("/")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(search.exists)
    }
}
