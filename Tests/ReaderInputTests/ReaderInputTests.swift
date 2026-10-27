import XCTest
import AppKit
import ReaderCore

// NSEvent has no public factory for magnification events. Override only the
// documented fields consumed by the reader; no system input is posted.
private final class PinchEvent: NSEvent {
    private let amount: CGFloat
    private let point: CGPoint
    private let eventPhase: NSEvent.Phase
    private weak var targetWindow: NSWindow?
    private let eventType: NSEvent.EventType
    init(_ amount: CGFloat, at point: CGPoint, phase: NSEvent.Phase = .changed, window: NSWindow? = nil, type: NSEvent.EventType = .magnify) {
        self.amount = amount; self.point = point; self.eventPhase = phase
        self.targetWindow = window
        self.eventType = type
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var type: NSEvent.EventType { eventType }
    override var magnification: CGFloat { amount }
    override var locationInWindow: NSPoint { point }
    override var phase: NSEvent.Phase { eventPhase }
    override var window: NSWindow? { targetWindow }
    override var windowNumber: Int { targetWindow?.windowNumber ?? 0 }
}

@MainActor
final class ReaderInputTests: XCTestCase {
    private func makeViewport(zoom: Double = 2) -> (NSWindow, ReaderViewport) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 680)); window.contentView = root
        let viewport = ReaderViewport(renderer: RenderCoordinator())
        viewport.frame = CGRect(x: 17, y: 31, width: 760, height: 600); root.addSubview(viewport)
        let identity = DocumentIdentity(id: UUID(), revision: "input-test")
        let pages = (0..<5).map { PageGeometry(index: $0, cropBox: CGRect(x: 0, y: 0, width: 612, height: 792)) }
        let info = DocumentInfo(identity: identity, url: URL(fileURLWithPath: "/nonexistent-input-fixture.pdf"), title: "Input Test", pageCount: pages.count, pages: pages, outline: [], allowsCopying: true, allowsPrinting: true)
        viewport.show(info: info, location: DocumentLocation(document: identity, pageIndex: 0, point: pages[0].pdfPoint(.zero), zoom: zoom))
        viewport.layoutSubtreeIfNeeded()
        return (window, viewport)
    }
    private func windowPoint(in viewport: ReaderViewport, offset: CGPoint) -> CGPoint {
        viewport.contentView.convert(CGPoint(x: viewport.contentView.bounds.minX + offset.x, y: viewport.contentView.bounds.minY + offset.y), to: nil)
    }
    private func hitView(in window: NSWindow, at point: CGPoint) throws -> NSView {
        let root = try XCTUnwrap(window.contentView)
        return try XCTUnwrap(root.hitTest(root.convert(point, from: nil)))
    }
    private func pdfPoint(in viewport: ReaderViewport, page: Int, at windowPoint: CGPoint) -> CGPoint {
        let documentPoint = viewport.canvas.convert(windowPoint, from: nil), frame = viewport.layoutModel.frames[page]
        return viewport.pages[page].pdfPoint(CGPoint(x: (documentPoint.x - frame.minX) / viewport.zoom, y: (documentPoint.y - frame.minY) / viewport.zoom), adding: viewport.rotation)
    }
    private func wheel(dy: Int32, dx: Int32 = 0) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }
    func testHighlightShortcutsRenderTheirNamedColors() throws {
        _ = NSApplication.shared
        let viewport = ReaderViewport(renderer: RenderCoordinator())
        let page = PageCanvas(viewport: viewport, index: 0)
        let expected: [(String, NSColor)] = [("g", .systemGreen), ("r", .systemRed), ("b", .systemBlue), ("y", .systemYellow), ("o", .systemOrange), ("p", .systemPurple), ("k", .systemPink)]
        var keys = KeySequenceMachine()
        page.highlightRects = try expected.enumerated().map { index, entry in
            XCTAssertNil(keys.feed("h"))
            let invocation = try XCTUnwrap(keys.feed(entry.0))
            XCTAssertEqual(invocation.command, .addHighlight)
            return (CGRect(x: 40, y: 700 - index * 20, width: 100, height: 12), try XCTUnwrap(invocation.argument))
        }
        page.drawOverlays()
        let layers = (page.layer?.sublayers ?? []).flatMap { $0.sublayers ?? [] }.compactMap { $0 as? CAShapeLayer }.filter { $0.compositingFilter as? String == "multiplyBlendMode" }
        XCTAssertEqual(layers.count, expected.count)
        for (layer, entry) in zip(layers, expected) {
            let actual = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(layer.fillColor))?.usingColorSpace(.sRGB))
            let color = try XCTUnwrap(entry.1.usingColorSpace(.sRGB))
            XCTAssertEqual(actual.redComponent, color.redComponent, accuracy: 0.001, "h\(entry.0)")
            XCTAssertEqual(actual.greenComponent, color.greenComponent, accuracy: 0.001, "h\(entry.0)")
            XCTAssertEqual(actual.blueComponent, color.blueComponent, accuracy: 0.001, "h\(entry.0)")
            XCTAssertEqual(actual.alphaComponent, 0.3, accuracy: 0.001)
        }
    }
    func testPinchOverPDFKeepsPointUnderPointerAfterScrollingAndRotation() throws {
        let (window, viewport) = makeViewport(); defer { window.close() }
        for nativeRotation in [0, 90, 180, 270] {
            let page = PageGeometry(index: 1, cropBox: CGRect(x: 25, y: 21, width: 558, height: 740), rotation: nativeRotation)
            viewport.replaceGeometry([page])
            for rotation in [0, 90, 180, 270] {
                viewport.navigate(to: DocumentLocation(document: try XCTUnwrap(viewport.identity), pageIndex: 1, point: page.pdfPoint(CGPoint(x: 80, y: 100), adding: rotation), zoom: 2, rotation: rotation))
                let point = windowPoint(in: viewport, offset: CGPoint(x: 270, y: 140))
                let before = pdfPoint(in: viewport, page: 1, at: point)
                let hit = try hitView(in: window, at: point)
                XCTAssertTrue(hit is PageCanvas)
                hit.magnify(with: PinchEvent(0.25, at: point))
                XCTAssertEqual(viewport.zoom, 2.5, accuracy: 0.0001)
                let after = pdfPoint(in: viewport, page: 1, at: point)
                XCTAssertEqual(after.x, before.x, accuracy: 0.01)
                XCTAssertEqual(after.y, before.y, accuracy: 0.01)
                XCTAssertEqual(viewport.magnification, 1, "Use the reader's tile zoom without a second AppKit scale")
            }
        }
    }
    func testWindowDispatchDeliversPinchToReader() throws {
        let (window, viewport) = makeViewport(); defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let point = windowPoint(in: viewport, offset: CGPoint(x: 270, y: 140))
        window.sendEvent(PinchEvent(0, at: point, phase: .began, window: window, type: .beginGesture))
        window.sendEvent(PinchEvent(0, at: point, phase: .began, window: window))
        window.sendEvent(PinchEvent(0.25, at: point, window: window))
        window.sendEvent(PinchEvent(0, at: point, phase: .ended, window: window))
        window.sendEvent(PinchEvent(0, at: point, phase: .ended, window: window, type: .endGesture))
        XCTAssertEqual(viewport.zoom, 2.5, accuracy: 0.0001)
        XCTAssertEqual(viewport.magnification, 1)
    }
    func testSustainedPinchContinuesWhilePageViewsChange() throws {
        let (window, viewport) = makeViewport(); defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        viewport.scrollToPage(4)
        let point = windowPoint(in: viewport, offset: CGPoint(x: 270, y: 140))
        window.sendEvent(PinchEvent(0, at: point, phase: .began, window: window, type: .beginGesture))
        window.sendEvent(PinchEvent(0, at: point, phase: .began, window: window))
        for _ in 0..<30 {
            let previousZoom = viewport.zoom
            window.sendEvent(PinchEvent(0.03, at: point, window: window))
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            XCTAssertGreaterThan(viewport.zoom, previousZoom, "Every update in a sustained pinch must reach the reader")
        }
        let pinch = try XCTUnwrap(viewport.canvas.gestureRecognizers.first as? NSMagnificationGestureRecognizer)
        XCTAssertEqual(pinch.state, .changed, "Exercise gesture recognition, not only raw responder callbacks")
        window.sendEvent(PinchEvent(0, at: point, phase: .ended, window: window))
        window.sendEvent(PinchEvent(0, at: point, phase: .ended, window: window, type: .endGesture))
        XCTAssertGreaterThan(viewport.zoom, 4)
        XCTAssertEqual(viewport.magnification, 1)
    }
    func testPinchOverCanvasMarginZoomsInAndOut() throws {
        let (window, viewport) = makeViewport(); defer { window.close() }
        viewport.contentView.scroll(to: CGPoint(x: 0, y: viewport.contentView.bounds.minY))
        let point = viewport.canvas.convert(CGPoint(x: 5, y: viewport.contentView.bounds.midY), to: nil)
        let hit = try hitView(in: window, at: point)
        XCTAssertTrue(hit is DocumentCanvas)
        hit.magnify(with: PinchEvent(0.25, at: point))
        XCTAssertEqual(viewport.zoom, 2.5, accuracy: 0.0001)
        viewport.canvas.magnify(with: PinchEvent(-0.2, at: point))
        XCTAssertEqual(viewport.zoom, 2, accuracy: 0.0001)
    }
    func testPinchZoomsSinglePageWithoutChangingPages() throws {
        let (window, viewport) = makeViewport(); defer { window.close() }
        viewport.scrollToPage(2); viewport.toggleSinglePage()
        let point = windowPoint(in: viewport, offset: CGPoint(x: 200, y: 250))
        try XCTUnwrap(viewport.pageViews[2]).magnify(with: PinchEvent(0.1, at: point))
        XCTAssertEqual(viewport.zoom, 2.2, accuracy: 0.0001)
        XCTAssertEqual(viewport.currentLocation?.pageIndex, 2)
    }
    func testPinchHonorsLimitsAndPublishesDisplayedZoom() throws {
        let (window, viewport) = makeViewport(); defer { window.close() }
        let point = windowPoint(in: viewport, offset: CGPoint(x: 200, y: 200))
        var published: DocumentLocation?; viewport.onLocation = { published = $0 }
        viewport.setZoom(7)
        viewport.magnify(with: PinchEvent(2, at: point))
        XCTAssertEqual(viewport.zoom, 8); XCTAssertEqual(published?.zoom, 8)
        viewport.setZoom(0.12)
        viewport.magnify(with: PinchEvent(-0.9, at: point))
        XCTAssertEqual(viewport.zoom, 0.1); XCTAssertEqual(published?.zoom, 0.1)
    }
    func testPinchBeginsInterruptMotionAndIgnoresCancelledOrInvalidEvents() throws {
        let (window, viewport) = makeViewport(); defer { window.close() }
        let point = windowPoint(in: viewport, offset: CGPoint(x: 200, y: 200))
        var interruptions = 0; viewport.onMagnify = { interruptions += 1 }
        viewport.magnify(with: PinchEvent(0, at: point, phase: .began))
        XCTAssertEqual(interruptions, 1); XCTAssertEqual(viewport.zoom, 2)
        viewport.magnify(with: PinchEvent(0.25, at: point))
        XCTAssertEqual(viewport.zoom, 2.5)
        for event in [PinchEvent(0, at: point, phase: .ended), PinchEvent(0.5, at: point, phase: .cancelled), PinchEvent(.nan, at: point), PinchEvent(.infinity, at: point), PinchEvent(-1, at: point)] { viewport.magnify(with: event) }
        XCTAssertEqual(viewport.zoom, 2.5); XCTAssertEqual(interruptions, 2)
        viewport.setZoom(.nan); XCTAssertEqual(viewport.zoom, 2.5)
    }
    func testScrollingThroughPageAndCanvasPreservesZoom() throws {
        let (window, viewport) = makeViewport(); defer { window.close() }
        let y = viewport.contentView.bounds.minY
        try XCTUnwrap(viewport.pageViews[0]).scrollWheel(with: wheel(dy: -50))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThan(viewport.contentView.bounds.minY, y)
        let x = viewport.contentView.bounds.minX
        viewport.canvas.scrollWheel(with: try wheel(dy: 0, dx: -50))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThan(viewport.contentView.bounds.minX, x)
        XCTAssertEqual(viewport.zoom, 2)
    }
    func testMiddleClickModifiersChooseSearchOrLocalJump() throws {
        let (window, viewport) = makeViewport(); defer { window.close() }
        let page = try XCTUnwrap(viewport.pageViews[0])
        var actions: [ReaderViewport.PointerAction] = []
        viewport.onPointer = { _, _, action in actions.append(action) }
        for flags: CGEventFlags in [[], .maskShift, .maskControl] {
            let cg = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
            cg.flags = flags
            page.otherMouseDown(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        }
        XCTAssertEqual(actions.count, 3)
        guard actions.count == 3 else { return }
        XCTAssertTrue(actions[0] == .externalSearch)
        XCTAssertTrue(actions[1] == .alternateExternalSearch)
        XCTAssertTrue(actions[2] == .jump)
    }
}
