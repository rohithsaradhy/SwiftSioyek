import XCTest
import ReaderCore
import ReaderPersistence
import PDFServices
import CoreGraphics
@preconcurrency import PDFKit

final class IntegrationTests: XCTestCase {
    func testLibraryCreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("Library.sqlite"))
        let docs = try await store.recentDocuments(); XCTAssertTrue(docs.isEmpty)
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftSioyek-Test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory
    }
    private func source(in directory: URL, pages: Int = 8) throws -> DocumentSource {
        let url = directory.appendingPathComponent("fixture.pdf")
        try FixtureFactory.makeDocument(at: url, pages: pages, title: "Integration Fixture", columns: true, scanned: false)
        return DocumentSource(identity: DocumentIdentity(id: UUID(), revision: try FileIdentity.revision(of: url)), url: url)
    }
    func testDurableDocumentsRecordsAndMarkScopes() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("Library.sqlite"), store = try LibraryStore(url: database)
        let identity = DocumentIdentity(id: UUID(), revision: "1"), second = DocumentIdentity(id: UUID(), revision: "1")
        let location = DocumentLocation(document: identity, pageIndex: 12)
        let document = RecentDocument(id: identity.id, url: directory.appendingPathComponent("paper.pdf"), bookmark: Data([1, 2, 3]), resourceID: "resource", title: "Paper", revision: "1", location: location)
        try await store.saveDocument(document)
        try await store.saveRecord(LibraryRecord(kind: .mark, location: location, title: "a"))
        try await store.saveRecord(LibraryRecord(kind: .mark, location: DocumentLocation(document: second, pageIndex: 8), title: "a"))
        try await store.saveRecord(LibraryRecord(kind: .mark, location: location, title: "A"))
        try await store.saveRecord(LibraryRecord(kind: .mark, location: DocumentLocation(document: second, pageIndex: 9), title: "A"))
        let local = try await store.mark("a", document: identity.id), global = try await store.mark("A", document: identity.id)
        XCTAssertEqual(local?.location.pageIndex, 12); XCTAssertEqual(global?.location.document.id, second.id)
        let bookmark = LibraryRecord(kind: .bookmark, location: location, title: "Native rendering checkpoint")
        try await store.saveRecord(bookmark)
        let matches = try await store.records(kind: .bookmark, search: "rendering"); XCTAssertEqual(matches.map(\.id), [bookmark.id])
        let reopened = try LibraryStore(url: database), documents = try await reopened.recentDocuments()
        XCTAssertEqual(documents.first?.location, location); XCTAssertEqual(documents.first?.bookmark, Data([1, 2, 3]))
        try await reopened.deleteRecord(id: bookmark.id)
        let removed = try await reopened.records(kind: .bookmark, search: "rendering"); XCTAssertTrue(removed.isEmpty)
        try await store.saveState([identity.id], key: "openWindows"); let session = try await reopened.state([UUID].self, key: "openWindows"); XCTAssertEqual(session, [identity.id])
    }
    func testPDFMetadataTextLinksAndSelections() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try source(in: directory), service = PDFTextService()
        let info = try await service.open(source); XCTAssertEqual(info.pageCount, 8); XCTAssertEqual(info.title, "Integration Fixture")
        let geometry = try await service.geometry(pages: 0..<8)
        XCTAssertEqual(geometry[1].rotation, 90); XCTAssertEqual(geometry[3].cropBox.minX, 25)
        let text = try await service.text(page: 0)
        XCTAssertTrue(text.text.contains("Native Research Reader")); XCTAssertFalse(text.glyphs.isEmpty); XCTAssertFalse(text.lines.isEmpty)
        XCTAssertEqual(text.links.first?.destinationPage, 5)
        let matches = SearchQuery("native", pageCount: 8).matches(in: text.text, page: 0); XCTAssertFalse(matches.isEmpty)
        let range = matches[0].range; XCTAssertFalse(text.rects(for: range).isEmpty)
        let selection = try await service.selection(from: 0, index: range.location, to: 0, index: range.end - 1)
        XCTAssertEqual(selection.string.lowercased(), "native"); XCTAssertFalse(selection.parts[0].rects.isEmpty)
        let crossPage = try await service.selection(from: 0, index: max(0, (text.text as NSString).length - 12), to: 1, index: 12)
        XCTAssertEqual(crossPage.parts.map(\.pageIndex), [0, 1])
        let outline = try await service.outline(); XCTAssertGreaterThanOrEqual(outline.count, 2)
    }
    func testAnnotationUndoReplacementUpdatesSearchAtomically() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(url: directory.appendingPathComponent("Library.sqlite"))
        let location = DocumentLocation(document: DocumentIdentity(id: UUID(), revision: "1"), pageIndex: 2)
        let before = LibraryRecord(kind: .bookmark, location: location, title: "Original checkpoint")
        let after = LibraryRecord(kind: .bookmark, location: location, title: "Revised checkpoint")
        try await store.saveRecord(before)
        try await store.changeRecords(removing: [before.id], saving: [after])
        let original = try await store.records(kind: .bookmark, search: "Original")
        let revised = try await store.records(kind: .bookmark, search: "Revised")
        XCTAssertTrue(original.isEmpty); XCTAssertEqual(revised.map(\.id), [after.id])
        try await store.changeRecords(removing: [after.id], saving: [before])
        let restored = try await store.records(kind: .bookmark)
        XCTAssertEqual(restored.map(\.id), [before.id])
    }
    func testSearchRangesStayAlignedWithPDFSelections() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try source(in: directory), service = PDFTextService()
        _ = try await service.open(source)
        let document = try XCTUnwrap(PDFDocument(url: source.url))
        // Repeated ligatures, inserted whitespace, two columns, Unicode, and
        // rotated/cropped pages expose drift hidden by checking only the title.
        for index in 0..<4 {
            let page = try XCTUnwrap(document.page(at: index))
            let snapshot = try await service.text(page: index)
            for word in ["Efficient", "fluid", "Unicode", "cafe", "typography"] {
                let hits = try await service.matches(query: SearchQuery(word, pageCount: 8), page: index)
                XCTAssertFalse(hits.isEmpty)
                for hit in [hits.first, hits.last].compactMap({ $0 }) {
                    let native = try XCTUnwrap(page.selection(for: hit.range.nsRange))
                    let expected = native.selectionsByLine().map { $0.bounds(for: page) }
                    let actual = snapshot.rects(for: hit.range)
                    let searchRects = try await service.selectionRects(page: index, range: hit.range)
                    XCTAssertEqual(searchRects, expected)
                    let copied = try await service.selection(from: index, index: hit.range.location, to: index, index: hit.range.end - 1)
                    XCTAssertEqual(copied.parts.first?.rects, expected)
                    XCTAssertEqual(copied.string, native.string)
                    XCTAssertEqual(actual.count, expected.count, "\(word), page \(index)")
                    for (rect, target) in zip(actual, expected) {
                        XCTAssertEqual(rect.minX, target.minX, accuracy: 0.01, "\(word), page \(index)")
                        XCTAssertEqual(rect.minY, target.minY, accuracy: 0.01, "\(word), page \(index)")
                        XCTAssertEqual(rect.width, target.width, accuracy: 0.01, "\(word), page \(index)")
                        XCTAssertEqual(rect.height, target.height, accuracy: 0.01, "\(word), page \(index)")
                    }
                }
            }
        }
    }
    func testSmartJumpsOnlyIndexDefinitionsAndKeepAmbiguity() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try source(in: directory, pages: 30), service = PDFTextService(); _ = try await service.open(source)
        for page in 0..<30 { _ = try await service.text(page: page, detailed: false) }
        let unique = await service.resolve("See Figure 1.1"), ambiguous = await service.resolve("Figure 2.1"), bibliography = await service.resolve("[1]")
        XCTAssertEqual(unique.map(\.pageIndex), [5]); XCTAssertEqual(ambiguous.map(\.pageIndex), [4, 12]); XCTAssertEqual(bibliography.map(\.pageIndex), [29])
    }
    func testAllRotationsRenderAtExpectedFiducials() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try source(in: directory), service = PDFTextService(), worker = RasterWorker(); _ = try await service.open(source)
        let geometries = try await service.geometry(pages: 0..<4)
        for geometry in geometries {
            for extra in [0, 90, 180, 270] {
                let full = CGRect(origin: .zero, size: geometry.size(adding: extra))
                let key = RenderKey(document: source.identity, pageIndex: geometry.index, rotation: extra, scaleStep: 0, preview: true)
                let rendered = try await worker.render(RenderRequest(key: key, rect: full, priority: 0), source: source)
                XCTAssertEqual(rendered.image.width, Int(full.width)); XCTAssertEqual(rendered.image.height, Int(full.height))
                let red = CGRect(x: 32, y: 756, width: 18, height: 18).intersection(geometry.cropBox)
                guard !red.isNull else { continue }
                let expected = geometry.displayRect(red, adding: extra)
                let pixel = pixel(rendered.image, x: Int(expected.midX), y: Int(expected.midY))
                XCTAssertGreaterThan(pixel.0, 180, "page \(geometry.index), rotation \(extra)"); XCTAssertLessThan(pixel.1, 80)
            }
        }
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let data = image.dataProvider!.data!; let bytes = CFDataGetBytePtr(data)!
        let offset = max(0, min(image.height - 1, y)) * image.bytesPerRow + max(0, min(image.width - 1, x)) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }
    func testTiledRenderingMatchesWholePageCrop() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try source(in: directory), service = PDFTextService(), worker = RasterWorker(); _ = try await service.open(source)
        for geometry in try await service.geometry(pages: 0..<4) {
            let key = RenderKey(document: source.identity, pageIndex: geometry.index, rotation: 0, scaleStep: 0)
            let full = try await worker.render(RenderRequest(key: key, rect: CGRect(origin: .zero, size: geometry.size()), priority: 0), source: source)
            let rect = CGRect(x: 20, y: 20, width: 200, height: 200)
            let tile = try await worker.render(RenderRequest(key: key, rect: rect, priority: 0), source: source)
            for y in stride(from: 2, to: 198, by: 13) { for x in stride(from: 2, to: 198, by: 13) {
                let a = pixel(full.image, x: x + 20, y: y + 20), b = pixel(tile.image, x: x, y: y)
                XCTAssertEqual(Int(a.0), Int(b.0), accuracy: 2); XCTAssertEqual(Int(a.1), Int(b.1), accuracy: 2)
            } }
        }
    }
    func testExportPreservesSourceAndEmbedsHighlights() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try source(in: directory), service = PDFTextService(); _ = try await service.open(source)
        let originalData = try Data(contentsOf: source.url)
        let selection = try await service.selection(from: 0, index: 0, to: 0, index: 12)
        let record = LibraryRecord(kind: .highlight, location: DocumentLocation(document: source.identity, pageIndex: 0), title: "Highlight", selection: selection.parts)
        let destination = directory.appendingPathComponent("exported.pdf")
        try await PDFExporter().export(source: source, highlights: [record], to: destination)
        XCTAssertEqual(try Data(contentsOf: source.url), originalData)
        let exported = PDFDocument(url: destination)!, original = PDFDocument(url: source.url)!
        XCTAssertGreaterThan(exported.page(at: 0)!.annotations.count, original.page(at: 0)!.annotations.count)
        XCTAssertTrue(exported.page(at: 0)!.string!.contains("Native Research Reader"))
        try await PDFExporter().export(source: source, highlights: [record], to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        do { try await PDFExporter().export(source: source, highlights: [record], to: source.url); XCTFail("Source overwrite was allowed") } catch PDFServiceError.forbidden {}
    }
    func testScansHaveNoTextAndMalformedDocumentsFail() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scan.pdf")
        try FixtureFactory.makeDocument(at: url, pages: 2, title: "Scan", columns: false, scanned: true)
        let service = PDFTextService(); _ = try await service.open(DocumentSource(identity: DocumentIdentity(id: UUID(), revision: "1"), url: url))
        let text = try await service.text(page: 0); XCTAssertTrue(text.text.isEmpty)
        let invalid = directory.appendingPathComponent("invalid.pdf"); try Data("not a PDF".utf8).write(to: invalid)
        do { _ = try await service.open(DocumentSource(identity: DocumentIdentity(id: UUID(), revision: "2"), url: invalid)); XCTFail("Invalid PDF opened") } catch PDFServiceError.unreadable {}
    }
    func testPasswordUnlockAndRevisionProtection() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try source(in: directory), encrypted = directory.appendingPathComponent("encrypted.pdf")
        XCTAssertTrue(PDFDocument(url: source.url)!.write(to: encrypted, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "secret"]))
        let identity = DocumentIdentity(id: UUID(), revision: try FileIdentity.revision(of: encrypted)), service = PDFTextService()
        do { _ = try await service.open(DocumentSource(identity: identity, url: encrypted)); XCTFail("Locked document opened") } catch PDFServiceError.locked {}
        let info = try await service.open(DocumentSource(identity: identity, url: encrypted, password: "secret")); XCTAssertEqual(info.pageCount, 8)
        let stale = DocumentSource(identity: DocumentIdentity(id: source.identity.id, revision: "stale"), url: source.url)
        do { try await PDFExporter().export(source: stale, highlights: [], to: directory.appendingPathComponent("out.pdf")); XCTFail("Stale revision exported") } catch PDFServiceError.changed {}
    }
    func testFileBookmarkSurvivesRename() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = try source(in: directory), newURL = directory.appendingPathComponent("renamed.pdf")
        let resource = FileIdentity.resourceID(of: source.url)
        let bookmark = try source.url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let document = RecentDocument(id: source.identity.id, url: source.url, bookmark: bookmark, resourceID: resource, title: "Fixture", revision: source.identity.revision)
        try FileManager.default.moveItem(at: source.url, to: newURL)
        XCTAssertEqual(FileIdentity.resolve(document)?.url.standardizedFileURL, newURL.standardizedFileURL)
        XCTAssertEqual(FileIdentity.resourceID(of: newURL), resource)
    }
}
