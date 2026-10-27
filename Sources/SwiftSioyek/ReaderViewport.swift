import AppKit
import QuartzCore
import ReaderCore
import PDFServices
import Darwin

@MainActor
final class DocumentCanvas: NSView {
    weak var viewport: ReaderViewport?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { viewport?.onKey?(event) }
    @objc func copy(_ sender: Any?) { viewport?.onNativeCommand?(.copy) }
    @objc override func selectAll(_ sender: Any?) { viewport?.onNativeCommand?(.selectAll) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    override func magnify(with event: NSEvent) { viewport?.magnify(with: event) }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let url = urls.first else { return false }; viewport?.onOpen?(url); return true
    }
}

@MainActor
final class ReaderViewport: NSScrollView {
    let canvas = DocumentCanvas()
    let renderer: RenderCoordinator
    private(set) var pages: [PageGeometry] = []
    private(set) var layoutModel = PageLayout(pages: [], zoom: 1, rotation: 0, viewportWidth: 800)
    private(set) var identity: DocumentIdentity?
    private(set) var pageViews: [Int: PageCanvas] = [:]
    private(set) var zoom = 1.0
    private(set) var rotation = 0
    private(set) var singlePage = false
    private var selectedPage = 0
    private var knownGeometry = Set<Int>()
    private var performingLayout = false
    private var lastWidth = 0.0
    var pagePriority = 0
    var onKey: ((NSEvent) -> Void)?
    var onNativeCommand: ((ReaderCommand) -> Void)?
    var onOpen: ((URL) -> Void)?
    var onLocation: ((DocumentLocation) -> Void)?
    var onPageNeeded: ((Int, PageCanvas) -> Void)?
    var onPointer: ((Int, CGPoint, PointerAction) -> Void)?
    var onSelectionDrag: ((Int, CGPoint, Bool, Int) -> Void)?
    var onFirstTile: (() -> Void)?
    var onRenderError: ((Int, Error) -> Void)?
    var onMagnify: (() -> Void)?
    var highlights: [LibraryRecord] = [] { didSet { updateOverlays() } }
    var selection: TextSelectionSnapshot? { didSet { updateOverlays() } }
    var searchRects: [Int: [CGRect]] = [:] { didSet { updateOverlays() } }
    var ruler: (Int, CGRect)? { didSet { updateOverlays() } }
    var hintMode = false { didSet { updateHints() } }
    private(set) var hintLinks: [(String, Int, PDFLink)] = []
    enum PointerAction { case click, preview, jump, externalSearch, alternateExternalSearch }
    init(renderer: RenderCoordinator) {
        self.renderer = renderer; super.init(frame: .zero)
        canvas.viewport = self; canvas.wantsLayer = true; canvas.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        canvas.registerForDraggedTypes([.fileURL]); documentView = canvas
        // Own the entire pinch on a stable view, including when zoom replaces
        // visible page views. AppKit can stop forwarding raw magnify events
        // once a gesture recognizer takes ownership of the sequence.
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delaysMagnificationEvents = true
        canvas.addGestureRecognizer(pinch)
        hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        drawsBackground = true; backgroundColor = .windowBackgroundColor; borderType = .noBorder
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
        setAccessibilityLabel("PDF document")
        setAccessibilityIdentifier("reader.viewport")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func reset() {
        for view in pageViews.values { view.cancelAndRemove() }; pageViews.removeAll(); pages.removeAll(); identity = nil; knownGeometry.removeAll()
        layoutModel = PageLayout(pages: [], zoom: 1, rotation: 0, viewportWidth: contentSize.width)
        canvas.frame.size = contentSize; selection = nil; searchRects = [:]; ruler = nil
    }
    func show(info: DocumentInfo, location: DocumentLocation?, provisionalGeometry: Bool = false) {
        for view in pageViews.values { view.cancel() }; pageViews.removeAll(); canvas.subviews.forEach { $0.removeFromSuperview() }
        pages = info.pages; knownGeometry = provisionalGeometry ? [0] : Set(info.pages.indices); identity = info.identity; selectedPage = min(max(0, location?.pageIndex ?? 0), pages.count - 1)
        rotation = location?.rotation ?? 0; zoom = location.map { max(0.1, min(8, $0.zoom)) } ?? 1
        selection = nil; ruler = nil; searchRects = [:]
        if location == nil { zoom = max(0.1, min(8, (contentSize.width - 40) / pages[selectedPage].size(adding: rotation).width)) }
        rebuild(anchor: nil)
        if let location { navigate(to: location) } else { scrollToPage(selectedPage) }
        window?.makeFirstResponder(canvas)
    }
    func showPreview(info: DocumentInfo, location: DocumentLocation, figureCaption: CGRect?) {
        var target = location
        if let caption = figureCaption, info.pages.indices.contains(target.pageIndex) {
            let page = info.pages[target.pageIndex]
            target.zoom = min(target.zoom, max(0.1, (contentSize.width - 32) / page.size(adding: target.rotation).width))
            target.point = page.figurePreviewAnchor(caption: caption, viewport: contentSize, zoom: target.zoom, adding: target.rotation)
        }
        show(info: info, location: target)
    }
    func replaceGeometry(_ new: [PageGeometry]) {
        let anchor = currentLocation
        var changed = false
        for page in new where pages.indices.contains(page.index) { if knownGeometry.insert(page.index).inserted || pages[page.index] != page { pages[page.index] = page; changed = true } }
        if changed { rebuild(anchor: anchor) }
    }
    override func layout() {
        super.layout()
        if abs(contentSize.width - lastWidth) > 0.5 { lastWidth = contentSize.width; rebuild(anchor: currentLocation) }
        else { updateVisible() }
    }
    var currentLocation: DocumentLocation? {
        guard let identity, !pages.isEmpty else { return nil }
        let visible = contentView.bounds
        let candidates = layoutModel.visible(in: visible)
        let index = candidates.max { a, b in layoutModel.frames[a].intersection(visible).height < layoutModel.frames[b].intersection(visible).height } ?? selectedPage
        guard pages.indices.contains(index), layoutModel.frames.indices.contains(index) else { return nil }
        let frame = layoutModel.frames[index]
        let local = CGPoint(x: max(0, (visible.minX - frame.minX) / zoom), y: max(0, (visible.minY - frame.minY) / zoom))
        return DocumentLocation(document: identity, pageIndex: index, point: pages[index].pdfPoint(local, adding: rotation), zoom: zoom, rotation: rotation)
    }
    private func rebuild(anchor: DocumentLocation?) {
        guard !performingLayout else { return }; performingLayout = true
        layoutModel = PageLayout(pages: pages, zoom: zoom, rotation: rotation, viewportWidth: contentSize.width, singlePage: singlePage ? selectedPage : nil)
        canvas.frame = CGRect(origin: .zero, size: CGSize(width: max(contentSize.width, layoutModel.contentSize.width), height: max(contentSize.height, layoutModel.contentSize.height)))
        if let anchor, pages.indices.contains(anchor.pageIndex) {
            let frame = layoutModel.frames[anchor.pageIndex]
            if !frame.isNull {
                let local = pages[anchor.pageIndex].displayPoint(anchor.point, adding: rotation)
                contentView.scroll(to: constrained(CGPoint(x: max(0, frame.minX + local.x * zoom), y: frame.minY + local.y * zoom)))
            }
        }
        performingLayout = false; reflectScrolledClipView(contentView); updateVisible()
    }
    private func constrained(_ point: CGPoint) -> CGPoint { CGPoint(x: max(0, min(point.x, canvas.frame.width - contentSize.width)), y: max(0, min(point.y, canvas.frame.height - contentSize.height))) }
    @objc private func scrolled() {
        guard !performingLayout else { return }
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        updateVisible()
        if let location = currentLocation { selectedPage = location.pageIndex; onLocation?(location) }
        PerformanceDiagnostics.shared.scrollWork(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
    }
    func updateVisible() {
        guard let identity, !performingLayout, !pages.isEmpty else { return }
        let visible = contentView.bounds
        let buffered = visible.insetBy(dx: 0, dy: -min(visible.height * 0.6, 500))
        let indices = Set(layoutModel.visible(in: buffered))
        for index in Array(pageViews.keys) where !indices.contains(index) { pageViews.removeValue(forKey: index)?.cancelAndRemove() }
        for index in indices.sorted() {
            let page = pages[index]
            let view: PageCanvas
            if let existing = pageViews[index] { view = existing }
            else {
                view = PageCanvas(viewport: self, index: index); pageViews[index] = view; canvas.addSubview(view)
                onPageNeeded?(index, view)
            }
            view.frame = layoutModel.frames[index]; view.geometry = page; view.zoom = zoom; view.extraRotation = rotation
            let intersection = view.frame.intersection(visible)
            let local = intersection.isNull ? CGRect.null : CGRect(x: (intersection.minX - view.frame.minX) / zoom, y: (intersection.minY - view.frame.minY) / zoom, width: intersection.width / zoom, height: intersection.height / zoom)
            if knownGeometry.contains(index) { view.updateTiles(document: identity, visible: local, priority: intersection.isNull ? 5 : pagePriority) }
        }
        updateOverlays(); updateHints()
    }
    func updateOverlays() {
        for (index, view) in pageViews {
            view.selectionRects = selection?.parts.filter { $0.pageIndex == index }.flatMap(\.rects) ?? []
            view.highlightRects = highlights.filter { $0.location.document == identity }.flatMap { record in record.selection.filter { $0.pageIndex == index }.flatMap { part in part.rects.map { ($0, record.style) } } }
            view.searchRects = searchRects[index] ?? []
            view.rulerRect = ruler?.0 == index ? ruler?.1 : nil
            view.drawOverlays()
        }
    }
    func navigate(to location: DocumentLocation) {
        guard pages.indices.contains(location.pageIndex) else { return }
        selectedPage = location.pageIndex; rotation = location.rotation; zoom = max(0.1, min(8, location.zoom)); rebuild(anchor: location)
        if let currentLocation { onLocation?(currentLocation) }
    }
    func scrollToPage(_ page: Int) {
        guard let identity, !pages.isEmpty else { return }
        let index = max(0, min(pages.count - 1, page)); selectedPage = index
        let location = DocumentLocation(document: identity, pageIndex: index, point: pages[index].pdfPoint(.zero, adding: rotation), zoom: zoom, rotation: rotation)
        navigate(to: location)
    }
    func setZoom(_ value: Double, around point: CGPoint? = nil) {
        guard value.isFinite else { return }
        let value = max(0.1, min(8, value))
        let screenPoint = point ?? CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
        let documentPoint = CGPoint(x: contentView.bounds.minX + screenPoint.x, y: contentView.bounds.minY + screenPoint.y)
        let index = layoutModel.visible(in: CGRect(origin: documentPoint, size: CGSize(width: 1, height: 1))).first ?? currentLocation?.pageIndex ?? 0
        guard pages.indices.contains(index), let identity else { return }
        let frame = layoutModel.frames[index]
        let local = CGPoint(x: (documentPoint.x - frame.minX) / zoom, y: (documentPoint.y - frame.minY) / zoom)
        let location = DocumentLocation(document: identity, pageIndex: index, point: pages[index].pdfPoint(local, adding: rotation), zoom: value, rotation: rotation)
        zoom = value; rebuild(anchor: nil)
        let newFrame = layoutModel.frames[index]
        contentView.scroll(to: constrained(CGPoint(x: newFrame.minX + local.x * zoom - screenPoint.x, y: newFrame.minY + local.y * zoom - screenPoint.y)))
        reflectScrolledClipView(contentView); updateVisible(); onLocation?(location)
    }
    override func magnify(with event: NSEvent) {
        guard !pages.isEmpty, !event.phase.contains(.cancelled), event.magnification.isFinite, event.magnification > -1 else { return }
        if event.phase.contains(.began) || event.magnification != 0 { onMagnify?() }
        guard event.magnification != 0 else { return }
        // The clip view uses the document's flipped coordinates. setZoom takes
        // an offset from the visible top-left, independent of scroll position.
        let point = contentView.convert(event.locationInWindow, from: nil)
        let anchor = CGPoint(x: point.x - contentView.bounds.minX, y: point.y - contentView.bounds.minY)
        setZoom(zoom * (1 + event.magnification), around: anchor)
    }
    @objc private func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed || gesture.state == .ended else { return }
        let amount = gesture.magnification
        gesture.magnification = 0
        guard !pages.isEmpty, amount.isFinite, amount > -1 else { return }
        if gesture.state == .began || amount != 0 { onMagnify?() }
        guard amount != 0 else { return }
        let point = gesture.location(in: contentView)
        setZoom(zoom * (1 + amount), around: CGPoint(x: point.x - contentView.bounds.minX, y: point.y - contentView.bounds.minY))
    }
    func fit(widthOnly: Bool, contentBounds: CGRect? = nil) {
        guard let index = currentLocation?.pageIndex else { return }
        let bounds = contentBounds.map { pages[index].displayRect($0, adding: rotation) } ?? CGRect(origin: .zero, size: pages[index].size(adding: rotation))
        let fit = (contentSize.width - 40) / max(1, bounds.width)
        setZoom(widthOnly ? fit : min(fit, (contentSize.height - 32) / max(1, bounds.height)))
        if let contentBounds, let identity { navigate(to: DocumentLocation(document: identity, pageIndex: index, point: CGPoint(x: contentBounds.minX, y: contentBounds.maxY), zoom: zoom, rotation: rotation)) }
    }
    func rotate(_ angle: Int) { let anchor = currentLocation; rotation = ((rotation + angle) % 360 + 360) % 360; rebuild(anchor: anchor.map { var a = $0; a.rotation = rotation; return a }) }
    func toggleSinglePage() { let anchor = currentLocation; singlePage.toggle(); rebuild(anchor: anchor) }
    func scrollBy(dx: Double = 0, dy: Double) {
        if singlePage, dy > 0, contentView.bounds.maxY >= canvas.frame.height - 1 { scrollToPage(selectedPage + 1); return }
        if singlePage, dy < 0, contentView.bounds.minY <= 1 { scrollToPage(selectedPage - 1); return }
        contentView.scroll(to: constrained(CGPoint(x: contentView.bounds.minX + dx, y: contentView.bounds.minY + dy))); reflectScrolledClipView(contentView)
    }
    func focusReader() { window?.makeFirstResponder(canvas) }
    private func updateHints() {
        hintLinks.removeAll()
        guard hintMode else { pageViews.values.forEach { $0.setHints([]) }; return }
        let alphabet = Array("asdfghjklqwertyuiopzxcvbnm")
        for index in pageViews.keys.sorted() {
            guard let view = pageViews[index] else { continue }
            var hints: [(String, CGRect)] = []
            for link in view.text?.links ?? [] {
                let linkRect = view.convert(view.screenRect(for: link.bounds), to: canvas)
                guard linkRect.intersects(contentView.bounds) else { continue }
                let number = hintLinks.count
                let label = String(alphabet[(number / alphabet.count) % alphabet.count]) + String(alphabet[number % alphabet.count])
                hintLinks.append((label, index, link)); hints.append((label, link.bounds))
            }
            view.setHints(hints)
        }
    }
}

@MainActor
final class PageCanvas: NSView {
    weak var viewport: ReaderViewport?
    let index: Int
    let owner = UUID()
    var geometry = PageGeometry(index: 0, cropBox: CGRect(x: 0, y: 0, width: 612, height: 792))
    var zoom = 1.0
    var extraRotation = 0
    var text: PageText? { didSet { rebuildAccessibility(); drawOverlays() } }
    var selectionRects: [CGRect] = []
    var highlightRects: [(CGRect, String)] = []
    var searchRects: [CGRect] = []
    var rulerRect: CGRect?
    private let previewLayer = CALayer()
    private let overlay = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let searchLayer = CAShapeLayer()
    private let rulerLayer = CAShapeLayer()
    private let hintsLayer = CALayer()
    private var tiles: [RenderKey: (CALayer, CGRect)] = [:]
    private var pending = Set<RenderKey>()
    private var previewKey: RenderKey?
    private var requestedScaleStep: Int?
    private var textElements: [PageTextAccessibility] = []
    private var linkElements: [PageLinkAccessibility] = []
    private var hoverTracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func magnify(with event: NSEvent) { viewport?.magnify(with: event) }
    init(viewport: ReaderViewport, index: Int) {
        self.viewport = viewport; self.index = index; super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.white.cgColor
        layer?.masksToBounds = true
        for sublayer in [previewLayer, overlay, selectionLayer, searchLayer, rulerLayer, hintsLayer] { layer?.addSublayer(sublayer) }
        previewLayer.contentsGravity = .resize
        setAccessibilityElement(false); setAccessibilityRole(.group); setAccessibilityLabel("Page \(index + 1)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func cancel() { viewport?.renderer.cancel(owner: owner); pending.removeAll() }
    func cancelAndRemove() { cancel(); removeFromSuperview() }
    func updateTiles(document: DocumentIdentity, visible: CGRect, priority: Int) {
        guard let viewport else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let scaleStep = RenderKey.scaleStep(for: zoom * (window?.backingScaleFactor ?? 2))
        if let previousScale = requestedScaleStep, previousScale != scaleStep {
            viewport.renderer.cancel(owner: owner); pending.removeAll()
            if previewLayer.contents == nil { previewKey = nil }
        }
        requestedScaleStep = scaleStep
        previewLayer.frame = bounds
        let full = CGRect(origin: .zero, size: geometry.size(adding: extraRotation))
        let previewScale = min(0.5, 1024 / max(full.width, full.height))
        let preview = RenderKey(document: document, pageIndex: index, rotation: extraRotation, scaleStep: RenderKey.scaleStep(for: previewScale), preview: true)
        if previewKey != preview {
            previewKey = preview
            viewport.renderer.request(RenderRequest(key: preview, rect: full, priority: priority), owner: owner) { [weak self] result in
                guard let self, self.previewKey == preview else { return }
                switch result {
                case .success(let tile): self.previewLayer.contents = tile.image; self.viewport?.onFirstTile?()
                case .failure(let error): self.viewport?.onRenderError?(self.index, error)
                }
            }
        }
        let tileSize = 512 / pow(2, Double(scaleStep) / 2)
        var wanted = Set<RenderKey>()
        if !visible.isNull {
            let covered = visible.insetBy(dx: -tileSize * 0.3, dy: -tileSize * 0.3).intersection(full)
            if !covered.isNull {
                for row in max(0, Int(floor(covered.minY / tileSize)))..<max(1, Int(ceil(covered.maxY / tileSize))) {
                    for column in max(0, Int(floor(covered.minX / tileSize)))..<max(1, Int(ceil(covered.maxX / tileSize))) {
                        let key = RenderKey(document: document, pageIndex: index, rotation: extraRotation, scaleStep: scaleStep, column: column, row: row)
                        let rect = CGRect(x: Double(column) * tileSize, y: Double(row) * tileSize, width: tileSize, height: tileSize).intersection(full)
                        guard !rect.isNull, !rect.isEmpty else { continue }; wanted.insert(key)
                        if tiles[key] == nil, !pending.contains(key) {
                            pending.insert(key)
                            viewport.renderer.request(RenderRequest(key: key, rect: rect, priority: priority + 1), owner: owner) { [weak self] result in
                                guard let self else { return }; self.pending.remove(key)
                                guard self.previewKey?.document == key.document, self.extraRotation == key.rotation, self.requestedScaleStep == key.scaleStep else { return }
                                if case .success(let tile) = result {
                                    let imageLayer = CALayer(); imageLayer.contents = tile.image; imageLayer.contentsGravity = .resize
                                    imageLayer.frame = self.scaled(tile.rect); self.layer?.insertSublayer(imageLayer, below: self.overlay)
                                    self.tiles[key] = (imageLayer, tile.rect); self.viewport?.onFirstTile?()
                                }
                            }
                        }
                    }
                }
            }
        }
        for key in Array(tiles.keys) {
            if key.rotation != extraRotation || (!wanted.contains(key) && (key.scaleStep == scaleStep || tiles.count > wanted.count + 28)) {
                tiles.removeValue(forKey: key)?.0.removeFromSuperlayer()
            } else if let entry = tiles[key] { entry.0.frame = scaled(entry.1) }
        }
        CATransaction.commit()
    }
    private func scaled(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom) }
    func screenRect(for pdfRect: CGRect) -> CGRect { scaled(geometry.displayRect(pdfRect, adding: extraRotation)) }
    func drawOverlays() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        func path(_ rects: [CGRect]) -> CGPath { let path = CGMutablePath(); for rect in rects where !rect.isNull { path.addRect(screenRect(for: rect)) }; return path }
        // Individual highlight layers preserve the user's a–z color types.
        overlay.sublayers?.forEach { $0.removeFromSuperlayer() }
        for (rect, style) in highlightRects {
            let shape = CAShapeLayer(); shape.path = path([rect]); shape.fillColor = HighlightPalette.color(for: style).withAlphaComponent(0.3).cgColor; shape.compositingFilter = "multiplyBlendMode"; overlay.addSublayer(shape)
        }
        selectionLayer.path = path(selectionRects); selectionLayer.fillColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35).cgColor
        searchLayer.path = path(searchRects); searchLayer.fillColor = NSColor.systemOrange.withAlphaComponent(0.35).cgColor
        rulerLayer.path = path(rulerRect.map { [$0] } ?? []); rulerLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor; rulerLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.7).cgColor; rulerLayer.lineWidth = 1
        CATransaction.commit()
    }
    func setHints(_ hints: [(String, CGRect)]) {
        hintsLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        for (label, rect) in hints {
            let point = screenRect(for: rect).origin
            let text = CATextLayer(); text.string = label; text.fontSize = 12; text.alignmentMode = .center; text.foregroundColor = NSColor.black.cgColor; text.backgroundColor = NSColor.systemYellow.cgColor; text.cornerRadius = 3
            text.contentsScale = window?.backingScaleFactor ?? 2; text.frame = CGRect(x: point.x, y: point.y, width: 25, height: 17); hintsLayer.addSublayer(text)
        }
    }
    private func pdfPoint(_ event: NSEvent) -> CGPoint { let point = convert(event.locationInWindow, from: nil); return geometry.pdfPoint(CGPoint(x: point.x / zoom, y: point.y / zoom), adding: extraRotation) }
    override func mouseDown(with event: NSEvent) {
        viewport?.focusReader()
        let point = pdfPoint(event)
        if let link = text?.links.first(where: { $0.bounds.contains(point) }), event.clickCount == 1 { viewport?.onPointer?(index, point, .click); _ = link; return }
        viewport?.onSelectionDrag?(index, point, true, event.clickCount)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let viewport else { return }
        let documentPoint = viewport.canvas.convert(event.locationInWindow, from: nil)
        if let page = viewport.pageViews.values.first(where: { $0.frame.contains(documentPoint) }) { viewport.onSelectionDrag?(page.index, page.pdfPoint(event), false, 1) }
        _ = autoscroll(with: event)
    }
    override func rightMouseDown(with event: NSEvent) { viewport?.onPointer?(index, pdfPoint(event), .preview) }
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        viewport?.focusReader()
        if event.modifierFlags.contains(.control) { viewport?.onPointer?(index, pdfPoint(event), .jump) }
        else { viewport?.onPointer?(index, pdfPoint(event), event.modifierFlags.contains(.shift) ? .alternateExternalSearch : .externalSearch) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam); for link in text?.links ?? [] { addCursorRect(screenRect(for: link.bounds), cursor: .pointingHand) } }
    func rebuildAccessibility() {
        textElements = text?.lines.map { PageTextAccessibility(page: self, line: $0) } ?? []
        linkElements = text?.links.map { PageLinkAccessibility(page: self, link: $0) } ?? []
        setAccessibilityChildren(textElements + linkElements)
        window?.invalidateCursorRects(for: self)
    }
}

// AppKit's Objective-C accessibility overrides lack actor annotations. Store
// explicit Sendable UI callbacks instead of capturing an unisolated AX element.
final class PageTextAccessibility: NSAccessibilityElement {
    let line: TextLine
    private let frameProvider: @MainActor @Sendable () -> NSRect
    private let selectionProvider: @MainActor @Sendable () -> NSRange
    @MainActor init(page: PageCanvas, line: TextLine) {
        self.line = line
        frameProvider = { [weak page] in guard let page, let window = page.window else { return .zero }; return window.convertToScreen(page.convert(page.screenRect(for: line.bounds), to: nil)) }
        selectionProvider = { [weak page] in
            guard let page, let part = page.viewport?.selection?.parts.first(where: { $0.pageIndex == page.index }) else { return NSRange(location: 0, length: 0) }
            let intersection = NSIntersectionRange(part.range.nsRange, line.range.nsRange)
            return intersection.length > 0 ? NSRange(location: intersection.location - line.range.location, length: intersection.length) : NSRange(location: 0, length: 0)
        }
        super.init(); setAccessibilityRole(.staticText); setAccessibilityParent(page); setAccessibilityValue(line.text); setAccessibilityLabel(line.text)
    }
    override func accessibilityFrame() -> NSRect { MainActor.assumeIsolated(frameProvider) }
    override func accessibilityString(for range: NSRange) -> String? { let text = line.text as NSString; guard range.location <= text.length else { return nil }; return text.substring(with: NSIntersectionRange(range, NSRange(location: 0, length: text.length))) }
    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: (line.text as NSString).length) }
    override func accessibilityFrame(for range: NSRange) -> NSRect { accessibilityFrame() }
    override func accessibilitySelectedTextRange() -> NSRange { MainActor.assumeIsolated(selectionProvider) }
}
final class PageLinkAccessibility: NSAccessibilityElement {
    private let frameProvider: @MainActor @Sendable () -> NSRect
    private let pressHandler: @MainActor @Sendable () -> Bool
    @MainActor init(page: PageCanvas, link: PDFLink) {
        frameProvider = { [weak page] in guard let page, let window = page.window else { return .zero }; return window.convertToScreen(page.convert(page.screenRect(for: link.bounds), to: nil)) }
        pressHandler = { [weak page] in guard let page else { return false }; page.viewport?.onPointer?(page.index, CGPoint(x: link.bounds.midX, y: link.bounds.midY), .click); return true }
        super.init(); setAccessibilityRole(.link); setAccessibilityParent(page); setAccessibilityLabel(link.url?.absoluteString ?? "Go to page \((link.destinationPage ?? 0) + 1)")
    }
    override func accessibilityFrame() -> NSRect { MainActor.assumeIsolated(frameProvider) }
    override func accessibilityPerformPress() -> Bool { MainActor.assumeIsolated(pressHandler) }
}
