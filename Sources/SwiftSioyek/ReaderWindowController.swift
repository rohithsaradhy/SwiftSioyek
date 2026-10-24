import AppKit
import QuartzCore
import UniformTypeIdentifiers
import ReaderCore
import ReaderPersistence
import PDFServices
import os

@MainActor
final class KeyboardScroller: NSObject {
    weak var viewport: ReaderViewport?
    private var link: CADisplayLink?
    private var remaining = CGPoint.zero
    private var timestamp = 0.0
    init(viewport: ReaderViewport) { self.viewport = viewport }
    func scroll(dx: Double = 0, dy: Double) {
        guard let viewport else { return }
        PerformanceDiagnostics.shared.beginMotion(viewport: viewport)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { viewport.scrollBy(dx: dx, dy: dy); return }
        remaining.x += dx; remaining.y += dy
        if link == nil {
            timestamp = 0
            let link = viewport.displayLink(target: self, selector: #selector(tick(_:)))
            let rate = Float(viewport.window?.screen?.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            link.add(to: .main, forMode: .common); self.link = link
        }
    }
    @objc private func tick(_ sender: CADisplayLink) {
        let rate = Float(viewport?.window?.screen?.maximumFramesPerSecond ?? 60)
        if sender.preferredFrameRateRange.maximum != rate { sender.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate) }
        if timestamp > 0 { PerformanceDiagnostics.shared.frame(seconds: sender.timestamp - timestamp) }
        let elapsed = timestamp == 0 ? 1.0 / 120 : min(0.05, sender.timestamp - timestamp); timestamp = sender.timestamp
        let portion = 1 - exp(-elapsed * 22), dx = remaining.x * portion, dy = remaining.y * portion
        viewport?.scrollBy(dx: dx, dy: dy); remaining.x -= dx; remaining.y -= dy
        if abs(remaining.x) + abs(remaining.y) < 0.5 { viewport?.scrollBy(dx: remaining.x, dy: remaining.y); stop() }
    }
    func stop() { link?.invalidate(); link = nil; remaining = .zero; timestamp = 0; if let viewport { PerformanceDiagnostics.shared.flush(cacheBytes: viewport.renderer.cacheBytes, views: viewport.pageViews.count) } }
}

@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    unowned let environment: ReaderEnvironment
    let viewport: ReaderViewport
    private var resultsList = ListController()
    private let status = NSTextField(labelWithString: "Open a PDF to begin")
    private let position = NSTextField(labelWithString: "")
    private let welcome = NSStackView()
    private let readerUndo = UndoManager()
    private var keys: KeySequenceMachine
    private lazy var scroller = KeyboardScroller(viewport: viewport)
    private var service = PDFTextService()
    private(set) var info: DocumentInfo?
    private var source: DocumentSource?
    private var recent: RecentDocument?
    private var scopedURL: URL?
    private var scopeStarted = false
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var fileObserver: DispatchSourceFileSystemObject?
    private var records: [LibraryRecord] = []
    private var searchHits: [SearchHit] = []
    private var searchIndex = -1
    private var searchInput = ""
    private var searchChapter: Range<Int>?
    private var paletteMode: ReaderCommand = .outline
    private var history = NavigationHistory()
    private var selectionAnchor: (Int, Int)?
    private var selectionCaret: (Int, Int)?
    private var keyboardSelecting = false
    private var hintInput = ""
    private var portalSource: DocumentLocation?
    private var selectedHighlight: UUID?
    private var panel: ChoicePanel?
    private var previewPopover: NSPopover?
    private var previewViewport: ReaderViewport?
    private var portalWindow: NSWindow?
    private var portalViewport: ReaderViewport?
    private var lastPortalID: UUID?
    private var portalScopedURL: URL?
    private var portalScopeStarted = false
    private var thumbnailsOwner = UUID()
    private let signposter = OSSignposter(subsystem: "app.swiftsioyek", category: "Interaction")
    private var openingInterval: OSSignpostIntervalState?
    private var firstPaint = false

    init(environment: ReaderEnvironment) {
        self.environment = environment; viewport = ReaderViewport(renderer: environment.renderer); keys = KeySequenceMachine(bindings: environment.bindings)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1060, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Swift Sioyek"; window.minSize = CGSize(width: 620, height: 440); window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed; window.titlebarAppearsTransparent = true; window.setFrameAutosaveName("ReaderWindow")
        super.init(window: window); window.delegate = self
        buildContent(); buildToolbar(); wireViewport()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func buildContent() {
        guard let window else { return }
        let root = NSView(); window.contentView = root
        let statusBar = NSStackView(views: [status, NSView(), position]); statusBar.orientation = .horizontal; statusBar.spacing = 12
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        position.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); position.textColor = .secondaryLabelColor; position.setContentHuggingPriority(.required, for: .horizontal)
        viewport.translatesAutoresizingMaskIntoConstraints = false; statusBar.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(viewport); root.addSubview(statusBar)
        NSLayoutConstraint.activate([viewport.topAnchor.constraint(equalTo: root.topAnchor), viewport.leadingAnchor.constraint(equalTo: root.leadingAnchor), viewport.trailingAnchor.constraint(equalTo: root.trailingAnchor), viewport.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -5), statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6), statusBar.heightAnchor.constraint(equalToConstant: 18)])
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil) ?? NSImage()); icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .light)
        let title = NSTextField(labelWithString: "A quieter place to read"); title.font = .systemFont(ofSize: 24, weight: .medium)
        let description = NSTextField(labelWithString: "Open a PDF or drop one into this window."); description.textColor = .secondaryLabelColor
        let open = NSButton(title: "Open PDF…", target: self, action: #selector(openFromWelcome)); open.bezelStyle = .rounded; open.keyEquivalent = ""
        let tips = NSTextField(labelWithString: "⌘O Open   ·   / Find   ·   : Commands   ·   t Contents"); tips.font = .systemFont(ofSize: 11); tips.textColor = .tertiaryLabelColor
        welcome.orientation = .vertical; welcome.alignment = .centerX; welcome.spacing = 18
        for view in [icon, title, description, open, tips] { welcome.addArrangedSubview(view) }
        welcome.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(welcome)
        NSLayoutConstraint.activate([welcome.centerXAnchor.constraint(equalTo: viewport.centerXAnchor), welcome.centerYAnchor.constraint(equalTo: viewport.centerYAnchor)])
    }
    @objc private func openFromWelcome() { environment.openPanel(in: self) }
    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ReaderToolbarV2"); toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = true
        window?.toolbar = toolbar; window?.toolbarStyle = .unifiedCompact
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let commands: [ReaderCommand] = [.outline, .back, .forward, .search, .palette, .fitWidth, .fitPage, .zoomOut, .zoomIn, .addBookmark, .togglePortal, .exportPDF]
        return [.flexibleSpace] + commands.map { NSToolbarItem.Identifier($0.rawValue) }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let left: [ReaderCommand] = [.back, .forward, .outline, .search, .palette]
        let right: [ReaderCommand] = [.fitWidth, .zoomOut, .zoomIn, .togglePortal]
        return left.map { NSToolbarItem.Identifier($0.rawValue) } + [.flexibleSpace] + right.map { NSToolbarItem.Identifier($0.rawValue) }
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let command = ReaderCommand(rawValue: identifier.rawValue) else { return nil }
        let images: [ReaderCommand: String] = [.outline: "list.bullet", .back: "chevron.left", .forward: "chevron.right", .search: "magnifyingglass", .palette: "command", .fitWidth: "arrow.left.and.right", .fitPage: "arrow.up.left.and.arrow.down.right", .zoomOut: "minus.magnifyingglass", .zoomIn: "plus.magnifyingglass", .addBookmark: "bookmark", .togglePortal: "macwindow.on.rectangle", .exportPDF: "square.and.arrow.up"]
        let item = NSToolbarItem(itemIdentifier: identifier); item.label = command.title; item.toolTip = command.title; item.image = NSImage(systemSymbolName: images[command] ?? "circle", accessibilityDescription: command.title); item.target = self; item.action = #selector(toolbarCommand(_:)); return item
    }
    @objc private func toolbarCommand(_ sender: NSToolbarItem) { if let command = ReaderCommand(rawValue: sender.itemIdentifier.rawValue) { perform(CommandInvocation(command)) } }
    private func wireViewport() {
        viewport.onOpen = { [weak self] url in self?.open(url) }
        viewport.onKey = { [weak self] event in self?.handleKey(event) }
        viewport.onNativeCommand = { [weak self] command in self?.perform(CommandInvocation(command)) }
        viewport.onLocation = { [weak self] location in self?.locationChanged(location) }
        viewport.onPageNeeded = { [weak self] index, canvas in self?.loadText(index, into: canvas) }
        viewport.onPointer = { [weak self] page, point, action in self?.pointer(page: page, point: point, action: action) }
        viewport.onSelectionDrag = { [weak self] page, point, initial, clicks in self?.select(page: page, point: point, initial: initial, clicks: clicks) }
        viewport.onFirstTile = { [weak self] in guard let self, !self.firstPaint else { return }; self.firstPaint = true; if let interval = self.openingInterval { self.signposter.endInterval("Open to first paint", interval); self.openingInterval = nil }; PerformanceDiagnostics.shared.firstPaint(cacheBytes: self.environment.renderer.cacheBytes, views: self.viewport.pageViews.count) }
        viewport.onRenderError = { [weak self] page, error in self?.status.stringValue = "Page \(page + 1): \(error.localizedDescription)" }
        viewport.onMagnify = { [weak self] in self?.scroller.stop() }
    }
    func updateBindings(_ bindings: KeyBindings) { keys = KeySequenceMachine(bindings: bindings) }
    func open(_ url: URL, location: DocumentLocation? = nil, recordHistory: Bool = true) {
        dismissPalette()
        if recordHistory, let current = viewport.currentLocation { history.updateCurrent(current) }
        let oldRecent = recent, oldLocation = viewport.currentLocation
        if var oldRecent, let oldLocation { oldRecent.location = oldLocation; Task { try? await environment.library.saveDocument(oldRecent) } }
        cancelDocumentTasks(); generation = UUID(); let token = generation
        scroller.stop(); keys.reset(); service = PDFTextService(); info = nil; source = nil; recent = nil; records = []; searchHits = []; readerUndo.removeAllActions()
        viewport.selection = nil; viewport.highlights = []; viewport.searchRects = [:]; welcome.isHidden = true
        viewport.reset()
        status.stringValue = "Opening \(url.lastPathComponent)…"; window?.title = url.deletingPathExtension().lastPathComponent
        firstPaint = false; openingInterval = signposter.beginInterval("Open to first paint")
        PerformanceDiagnostics.shared.beginOpen()
        if scopeStarted { scopedURL?.stopAccessingSecurityScopedResource() }; scopedURL = url; scopeStarted = url.startAccessingSecurityScopedResource()
        let service = self.service
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await Task.detached {
                    let revision = try FileIdentity.revision(of: url), resource = FileIdentity.resourceID(of: url)
                    let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: [.fileResourceIdentifierKey], relativeTo: nil)
                    return (revision, resource, bookmark)
                }.value
                let existing = try await environment.library.document(resourceID: file.1, url: url)
                let identity = DocumentIdentity(id: existing?.id ?? location?.document.id ?? UUID(), revision: file.0)
                var source = DocumentSource(identity: identity, url: url)
                var loaded: DocumentInfo
                do { loaded = try await service.open(source) }
                catch PDFServiceError.locked {
                    guard !Task.isCancelled, generation == token, let password = await passwordPrompt(url.lastPathComponent) else { return }
                    source.password = password; loaded = try await service.open(source)
                }
                guard !Task.isCancelled, generation == token else { return }
                self.source = source; info = loaded; environment.renderer.register(source)
                var restore = location ?? existing?.location
                if var anchor = restore { anchor.document = identity; anchor.pageIndex = min(loaded.pageCount - 1, anchor.pageIndex); restore = anchor }
                recent = RecentDocument(id: identity.id, url: url, bookmark: file.2, resourceID: file.1, title: loaded.title, revision: identity.revision, location: restore)
                try await environment.library.saveDocument(recent!)
                records = try await environment.library.records(document: identity.id)
                window?.title = loaded.title; window?.representedURL = url
                viewport.show(info: loaded, location: restore, provisionalGeometry: true); viewport.highlights = records.filter { $0.kind == .highlight }
                if recordHistory, let current = viewport.currentLocation { history.visit(current) }
                let stale = records.contains { $0.location.document.revision != identity.revision }
                status.stringValue = stale ? "Document changed. Older annotation anchors need review in Notes." : "Ready · : commands"
                watch(url); beginMetadata(service: service, token: token, count: loaded.pageCount); beginIndexing(service: service, token: token, count: loaded.pageCount)
                Task { await environment.saveSession() }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                status.stringValue = "Unable to open PDF"; welcome.isHidden = false; environment.showError(error, in: window)
            }
        }
    }
    private func passwordPrompt(_ name: String) async -> String? {
        guard let window else { return nil }
        let alert = NSAlert(); alert.messageText = "Unlock \(name)"; alert.informativeText = "The password is kept in memory for this session only."
        let field = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 300, height: 24)); alert.accessoryView = field; alert.addButton(withTitle: "Unlock"); alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { response in continuation.resume(returning: response == .alertFirstButtonReturn ? field.stringValue : nil) }; alert.window.initialFirstResponder = field }
    }
    private func beginMetadata(service: PDFTextService, token: UUID, count: Int) {
        metadataTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let outline = try await service.outline(); guard generation == token, !Task.isCancelled else { return }; info?.outline = outline
                for start in stride(from: 0, to: count, by: 16) {
                    try Task.checkCancellation(); let pages = try await service.geometry(pages: start..<min(count, start + 16))
                    guard generation == token else { return }
                    for page in pages { info?.pages[page.index] = page }; viewport.replaceGeometry(pages)
                    try await Task.sleep(for: .milliseconds(2))
                }
                if paletteMode == .outline, panel?.window?.isVisible == true { populateOutline() }
            } catch is CancellationError {} catch { if generation == token { status.stringValue = error.localizedDescription } }
        }
    }
    private func beginIndexing(service: PDFTextService, token: UUID, count: Int) {
        indexTask = Task(priority: .background) { [weak self] in
            guard let self, let identity = info?.identity else { return }
            do {
                try await environment.library.invalidateText(document: identity.id, keeping: identity.revision)
                for page in 0..<count {
                    try Task.checkCancellation(); guard generation == token else { return }
                    let text = try await service.text(page: page, detailed: false)
                    try await environment.library.cacheText(text.text, document: identity, page: page)
                    try await Task.sleep(for: .milliseconds(3))
                }
            } catch is CancellationError {} catch { if generation == token { status.stringValue = "Indexing paused: \(error.localizedDescription)" } }
        }
    }
    private func loadText(_ index: Int, into canvas: PageCanvas) {
        let service = service, token = generation
        Task { [weak self, weak canvas] in
            do {
                let geometry = try await service.geometry(pages: index..<(index + 1))
                if let self, generation == token { for page in geometry { info?.pages[page.index] = page }; viewport.replaceGeometry(geometry) }
                let snapshot = try await service.text(page: index)
                guard let self, let canvas, generation == token, viewport.pageViews[index] === canvas else { return }
                canvas.text = snapshot
                if snapshot.text.isEmpty, viewport.currentLocation?.pageIndex == index { status.stringValue = "No selectable text on this page · OCR is not enabled" }
                if viewport.hintMode { viewport.hintMode = true }
            } catch { if let self, generation == token { status.stringValue = error.localizedDescription } }
        }
    }
    private func watch(_ url: URL) {
        fileObserver?.cancel(); fileObserver = nil
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let observer = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke], queue: .main)
        observer.setCancelHandler { Darwin.close(descriptor) }
        observer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleReload() } }
        observer.resume(); fileObserver = observer
    }
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard let self, let recent else { return }
            let resolved = FileIdentity.resolve(recent)
            guard let url = resolved?.url, FileManager.default.fileExists(atPath: url.path) else { status.stringValue = "PDF moved or unavailable · Open Recent to locate it"; return }
            guard let revision = try? await Task.detached(operation: { try FileIdentity.revision(of: url) }).value, revision != info?.identity.revision else { return }
            open(url, location: viewport.currentLocation)
        }
    }
    private func cancelDocumentTasks() {
        for task in [loadTask, metadataTask, indexTask, searchTask, selectionTask, saveTask, reloadTask] { task?.cancel() }
        fileObserver?.cancel(); fileObserver = nil
        for page in viewport.pageViews.values { page.cancel() }
        environment.renderer.cancel(owner: thumbnailsOwner)
    }
    func windowWillClose(_ notification: Notification) {
        let lastRecent = recent, location = viewport.currentLocation
        cancelDocumentTasks(); scroller.stop(); previewPopover?.close(); portalWindow?.close(); panel?.close()
        if scopeStarted { scopedURL?.stopAccessingSecurityScopedResource() }; if portalScopeStarted { portalScopedURL?.stopAccessingSecurityScopedResource() }
        if var lastRecent, let location { lastRecent.location = location; Task { try? await environment.library.saveDocument(lastRecent) } }
        environment.close(self)
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { readerUndo }
    func flushPosition() async {
        await mutationTask?.value
        guard var recent, let location = viewport.currentLocation, let identity = info?.identity, location.document == identity else { return }
        recent.location = location; self.recent = recent
        do { try await environment.library.saveDocument(recent) } catch { status.stringValue = error.localizedDescription }
    }
    private func locationChanged(_ location: DocumentLocation) {
        guard let info else { return }
        position.stringValue = "\(location.pageIndex + 1) / \(info.pageCount)   \(Int(viewport.zoom * 100))%"
        saveTask?.cancel(); saveTask = Task { [weak self] in do { try await Task.sleep(for: .milliseconds(500)) } catch { return }; await self?.flushPosition() }
        updatePortal()
    }
    func perform(_ invocation: CommandInvocation) {
        let command = invocation.command, count = invocation.count
        signposter.emitEvent("Command")
        switch command {
        case .open: environment.openPanel(in: self)
        case .recent: showRecent()
        case .palette: showCommands()
        case .settings: environment.showSettings()
        case .toggleSidebar: if info != nil { showListPalette(.outline) }
        default:
            guard info != nil else { status.stringValue = "Open a PDF first · ⌘O"; return }
            switch command {
            case .search, .chapterSearch: searchChapter = command == .chapterSearch ? chapterRange() : nil; showListPalette(.search)
            case .externalSearch:
                if let engine = invocation.argument { externalSearch(engine: engine) }
                else { keys.expectArgument(for: .externalSearch); status.stringValue = "Search engine: s Scholar · l Library Genesis · g Google · Escape cancels" }
            case .nextMatch: goToSearch(delta: count)
            case .previousMatch: goToSearch(delta: -count)
            case .firstPage: jumpPage(count > 1 ? count - 1 : 0)
            case .lastPage: jumpPage(count > 1 ? count - 1 : info!.pageCount - 1)
            case .goToPage: prompt("Go to page", placeholder: "1–\(info!.pageCount) or a printed page label") { [weak self] value in guard let self else { return }; if let index = info?.pages.firstIndex(where: { $0.label == value }) { jumpPage(index) } else if let number = Int(value), number > 0, number <= info!.pageCount { jumpPage(number - 1) } else { status.stringValue = "Page not found" } }
            case .screenDown: scroller.scroll(dy: viewport.contentSize.height * 0.88 * Double(count))
            case .screenUp: scroller.scroll(dy: -viewport.contentSize.height * 0.88 * Double(count))
            case .moveDown: scroller.scroll(dy: 42 * Double(count))
            case .moveUp: scroller.scroll(dy: -42 * Double(count))
            case .moveLeft: scroller.scroll(dx: -42 * Double(count), dy: 0)
            case .moveRight: scroller.scroll(dx: 42 * Double(count), dy: 0)
            case .zoomIn: viewport.setZoom(viewport.zoom * pow(1.15, Double(min(20, count))))
            case .zoomOut: viewport.setZoom(viewport.zoom / pow(1.15, Double(min(20, count))))
            case .fitWidth: viewport.fit(widthOnly: true)
            case .fitPage: viewport.fit(widthOnly: false)
            case .smartFit: smartFit()
            case .rotateRight: viewport.rotate(90)
            case .rotateLeft: viewport.rotate(-90)
            case .outline, .thumbnails, .bookmarks, .allBookmarks, .highlights, .allHighlights: showListPalette(command)
            case .addBookmark: prompt("Add bookmark", placeholder: "A name for this location") { [weak self] title in guard let self, let location = viewport.currentLocation else { return }; saveRecord(LibraryRecord(kind: .bookmark, location: location, title: title)) }
            case .deleteBookmark: deleteNearest(kind: .bookmark)
            case .addHighlight:
                if let symbol = invocation.argument { addHighlight(style: symbol) }
                else { status.stringValue = "Highlight type: press a–z"; keys.expectArgument(for: .addHighlight) }
            case .deleteHighlight: if let id = selectedHighlight, let record = records.first(where: { $0.id == id }) { deleteRecord(record) } else { status.stringValue = "Click a highlight first" }
            case .setMark:
                if let symbol = invocation.argument, let location = viewport.currentLocation { saveRecord(LibraryRecord(kind: .mark, location: location, title: symbol)) }
                else { keys.expectArgument(for: .setMark); status.stringValue = "Mark name: press a–z (local) or A–Z (global)" }
            case .goToMark:
                if let symbol = invocation.argument, let document = info?.identity.id { Task { do { if let mark = try await environment.library.mark(symbol, document: document) { navigate(mark.location) } else { status.stringValue = "Mark \(symbol) is not set" } } catch { environment.showError(error, in: window) } } }
                else { keys.expectArgument(for: .goToMark); status.stringValue = "Go to mark: press its letter" }
            case .portal: createPortal()
            case .goToPortal: if let location = viewport.currentLocation, let portal = ReferenceResolver.nearestPortal(in: records, to: location), let destination = portal.destination { navigate(destination) } else { status.stringValue = "No portal in this document" }
            case .deletePortal: deleteNearest(kind: .portal)
            case .togglePortal: togglePortalWindow()
            case .preview, .smartJump: resolveCurrentReference(preview: command == .preview)
            case .back: if let current = viewport.currentLocation, let previous = history.back(from: current) { navigate(previous, recordHistory: false) }
            case .forward: if let current = viewport.currentLocation, let next = history.forward(from: current) { navigate(next, recordHistory: false) }
            case .nextChapter, .previousChapter:
                let current = viewport.currentLocation?.pageIndex ?? 0
                let candidates = info!.outline.map(\.pageIndex).sorted()
                if let page = command == .nextChapter ? candidates.first(where: { $0 > current }) : candidates.last(where: { $0 < current }) { jumpPage(page) }
            case .rulerDown: moveRuler(count)
            case .rulerUp: moveRuler(-count)
            case .setRuler: moveRuler(0)
            case .linkHints: viewport.hintMode.toggle(); hintInput = ""; status.stringValue = viewport.hintMode ? "Enter a link label · Escape to cancel" : "Ready"
            case .keyboardSelect: beginKeyboardSelection()
            case .copy: copySelection()
            case .selectAll: selectAll()
            case .toggleSinglePage: viewport.toggleSinglePage()
            case .exportPDF: exportPDF()
            default: break
            }
        }
    }
    private func handleKey(_ event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else { return }
        if event.keyCode == 53 { keys.reset(); hintInput = ""; viewport.hintMode = false; keyboardSelecting = false; scroller.stop(); previewPopover?.close(); viewport.selection = nil; status.stringValue = "Ready"; return }
        if viewport.hintMode {
            guard let chars = event.charactersIgnoringModifiers, chars.count == 1 else { return }; hintInput += chars.lowercased()
            if let hint = viewport.hintLinks.first(where: { $0.0 == hintInput }) { viewport.hintMode = false; follow(hint.2, page: hint.1, preview: false); hintInput = "" }
            else if !viewport.hintLinks.contains(where: { $0.0.hasPrefix(hintInput) }) { hintInput = "" }
            return
        }
        if keyboardSelecting, [123, 124, 125, 126].contains(event.keyCode) { extendKeyboardSelection(event); return }
        if event.modifierFlags.contains(.control) {
            if event.keyCode == 123 { perform(CommandInvocation(.back)); return }; if event.keyCode == 124 { perform(CommandInvocation(.forward)); return }
            if event.charactersIgnoringModifiers == "f" { perform(CommandInvocation(.search)); return }
            if event.charactersIgnoringModifiers == "]" { perform(CommandInvocation(.smartJump)); return }
            return
        }
        let shift = event.modifierFlags.contains(.shift)
        let token: String
        switch event.keyCode {
        case 123: token = "<left>"; case 124: token = "<right>"; case 125: token = "<down>"; case 126: token = "<up>"
        case 49: token = shift ? "<S-space>" : "<space>"
        case 51: token = shift ? "<S-backspace>" : "<backspace>"
        case 48: token = "<tab>"; case 115: token = "<home>"; case 116: token = "<pageup>"; case 121: token = "<pagedown>"
        case 101: token = "<f9>"; case 109: token = "<f10>"; case 111: token = "<f12>"
        default: guard let characters = event.characters, !characters.isEmpty else { return }; token = characters
        }
        if let invocation = keys.feed(token) { perform(invocation) }
        else if !keys.status.isEmpty { status.stringValue = keys.status }
    }
    private func jumpPage(_ index: Int) { guard let current = viewport.currentLocation else { return }; history.updateCurrent(current); viewport.scrollToPage(index); if let location = viewport.currentLocation { history.visit(location) }; viewport.focusReader() }
    private func navigate(_ location: DocumentLocation, recordHistory: Bool = true) {
        if recordHistory, let current = viewport.currentLocation { history.updateCurrent(current); history.visit(location) }
        if info?.identity.id == location.document.id {
            if info?.identity.revision != location.document.revision { status.stringValue = "This saved anchor belongs to an older revision. Review its position." }
            var target = location; target.document = info!.identity; viewport.navigate(to: target); viewport.focusReader()
        } else {
            Task { do { if let document = try await environment.library.document(id: location.document.id) { openRecent(document, location: location, recordHistory: false) } else { status.stringValue = "The destination document is missing from the library" } } catch { environment.showError(error, in: window) } }
        }
    }
    private func showCommands() {
        let bindings = environment.bindings.bindings
        let choices = ReaderCommand.allCases.filter { $0 != .toggleSidebar }.map { command in
            let keys = bindings.filter { $0.value == command }.map(\.key).sorted().map(Self.displayKey).joined(separator: "  ")
            return ListChoice(command.title, detail: command.paletteCategory, shortcut: command.macShortcut ?? keys, image: NSImage(systemSymbolName: command.paletteSymbol, accessibilityDescription: nil), id: command.rawValue) { [weak self] in self?.perform(CommandInvocation(command)) }
        }
        showChoices("Commands", choices: choices)
    }
    private static func displayKey(_ key: String) -> String {
        let names = ["<space>": "Space", "<S-space>": "⇧Space", "<backspace>": "⌫", "<S-backspace>": "⇧⌫", "<tab>": "⇥", "<up>": "↑", "<down>": "↓", "<left>": "←", "<right>": "→", "<pagedown>": "⇟", "<pageup>": "⇞", "<home>": "↖", "<f9>": "F9", "<f10>": "F10", "<f12>": "F12"]
        return names.reduce(key) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
    private func dismissPalette() {
        let old = panel; panel = nil; old?.close()
        environment.renderer.cancel(owner: thumbnailsOwner)
        if NSApp.isActive { window?.makeKeyAndOrderFront(nil); viewport.focusReader() }
    }
    private func makePalette(_ title: String) -> ChoicePanel {
        dismissPalette()
        let palette = ChoicePanel(title: title, choices: []); panel = palette; resultsList = palette.list
        palette.onClose = { [weak self, weak palette] in
            guard let self, self.panel === palette else { return }; self.panel = nil
            environment.renderer.cancel(owner: thumbnailsOwner)
            if NSApp.isActive, NSApp.keyWindow == nil || NSApp.keyWindow === window { window?.makeKeyAndOrderFront(nil); viewport.focusReader() }
        }
        return palette
    }
    private func showChoices(_ title: String, choices: [ListChoice]) {
        let palette = makePalette(title); paletteMode = .palette
        resultsList.titleText = title == "Commands" ? "Search commands…" : "Search \(title.lowercased())…"
        resultsList.choices = choices.map { choice in ListChoice(choice.title, detail: choice.detail, shortcut: choice.shortcut, image: choice.image, id: choice.id) { [weak self] in self?.dismissPalette(); choice.action() } }
        palette.present(relativeTo: window)
    }
    private func showRecent() {
        Task { [weak self] in guard let self else { return }; do {
            let documents = try await environment.library.recentDocuments()
            showChoices("Recent Documents", choices: documents.map { document in ListChoice(document.title, detail: document.url.path) { [weak self] in self?.openRecent(document, location: document.location) } })
        } catch { environment.showError(error, in: window) } }
    }
    private func openRecent(_ document: RecentDocument, location: DocumentLocation?, recordHistory: Bool = true) {
        if let resolved = FileIdentity.resolve(document) { open(resolved.url, location: location, recordHistory: recordHistory); return }
        let alert = NSAlert(); alert.messageText = "Locate \(document.title)"; alert.informativeText = "The PDF has moved or is unavailable. Choose its new location to reconnect saved reading data."; alert.addButton(withTitle: "Locate…"); alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.beginSheetModal(for: window) { [weak self] response in guard response == .OK, let url = panel.url else { return }; var anchor = location ?? DocumentLocation(document: DocumentIdentity(id: document.id, revision: document.revision), pageIndex: 0); anchor.document.id = document.id; self?.open(url, location: anchor) }
        }
    }
    private func prompt(_ title: String, placeholder: String, completion: @escaping (String) -> Void) {
        guard let window else { return }; let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 360, height: 24)); field.placeholderString = placeholder; alert.accessoryView = field
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); if response == .alertFirstButtonReturn, !value.isEmpty { completion(value) } }; alert.window.initialFirstResponder = field
    }
    private func chapterRange() -> Range<Int>? {
        guard let info else { return nil }; let current = viewport.currentLocation?.pageIndex ?? 0
        let entries = info.outline.filter { $0.pageIndex <= current }; guard let chapter = entries.max(by: { $0.pageIndex == $1.pageIndex ? $0.depth < $1.depth : $0.pageIndex < $1.pageIndex }) else { return 0..<info.pageCount }
        let end = info.outline.first { $0.pageIndex > chapter.pageIndex && $0.depth <= chapter.depth }?.pageIndex ?? info.pageCount
        return chapter.pageIndex..<end
    }
    private func showListPalette(_ mode: ReaderCommand, focus: Bool = true) {
        guard let info else { return }
        let title: String
        switch mode { case .search: title = searchChapter == nil ? "Find in Document" : "Find in Chapter"; case .outline: title = "Contents"; case .thumbnails: title = "Pages"; case .highlights: title = "Highlights"; case .allHighlights: title = "All Highlights"; case .allBookmarks: title = "All Bookmarks"; default: title = "Bookmarks" }
        let palette = makePalette(title); paletteMode = mode; thumbnailsOwner = UUID()
        switch mode {
        case .search:
            resultsList.titleText = searchChapter == nil ? "Find in document…" : "Find in this chapter…"; resultsList.symbol = "magnifyingglass"
            resultsList.filterLocally = false; resultsList.onSearch = { [weak self] value in self?.startSearch(value) }; resultsList.search.stringValue = searchInput; updateSearchList()
        case .outline:
            resultsList.titleText = "Jump to a chapter…"; resultsList.symbol = "list.bullet"; populateOutline()
        case .thumbnails:
            resultsList.titleText = "Jump to a page…"; resultsList.symbol = "doc"
            resultsList.choices = info.pages.map { page in ListChoice("Page \(page.label)", detail: "\(Int(page.size().width)) × \(Int(page.size().height)) pt", id: "page-\(page.index)") { [weak self] in self?.dismissPalette(); self?.jumpPage(page.index) } }
            let owner = thumbnailsOwner
            resultsList.onDisplay = { [weak self] index, cell in
                guard let self, info.pages.indices.contains(index) else { return }
                let page = info.pages[index], full = CGRect(origin: .zero, size: page.size())
                let key = RenderKey(document: info.identity, pageIndex: index, rotation: 0, scaleStep: RenderKey.scaleStep(for: 60 / max(full.width, full.height)), preview: true)
                environment.renderer.request(RenderRequest(key: key, rect: full, priority: 4), owner: owner) { [weak self, weak cell] result in
                    guard let self, thumbnailsOwner == owner, let cell, case .success(let tile) = result else { return }
                    if (cell.viewWithTag(1) as? NSTextField)?.stringValue == "Page \(page.label)" { (cell.viewWithTag(3) as? NSImageView)?.image = NSImage(cgImage: tile.image, size: .zero) }
                }
            }
        default: loadRecordList(mode)
        }
        palette.present(relativeTo: window)
        if focus { resultsList.focusSearch(selectAll: true) }
    }
    private func populateOutline() {
        guard let info else { return }
        resultsList.emptyMessage = "This PDF has no embedded table of contents."
        resultsList.choices = info.outline.map { entry in ListChoice(String(repeating: "  ", count: entry.depth) + entry.title, detail: "Page \(entry.pageIndex + 1)", id: entry.id) { [weak self] in guard let self else { return }; dismissPalette(); navigate(DocumentLocation(document: info.identity, pageIndex: entry.pageIndex, point: entry.point, zoom: viewport.zoom, rotation: viewport.rotation)) } }
    }
    private func loadRecordList(_ mode: ReaderCommand) {
        guard let info else { return }
        let kind: RecordKind = [.highlights, .allHighlights].contains(mode) ? .highlight : .bookmark
        let global = [.allBookmarks, .allHighlights].contains(mode)
        resultsList.titleText = "Search \(global ? "all " : "")\(kind == .highlight ? "highlights" : "bookmarks")…"; resultsList.symbol = kind == .highlight ? "highlighter" : "bookmark"
        let token = generation
        Task { [weak self] in guard let self else { return }; do {
            let items = try await environment.library.records(document: global ? nil : info.identity.id, kind: kind)
            guard generation == token, paletteMode == mode else { return }
            resultsList.choices = items.map { item in ListChoice(item.title, detail: "Page \(item.location.pageIndex + 1)\(item.location.document.revision == info.identity.revision ? "" : " · different document/revision")", image: NSImage(systemSymbolName: kind == .highlight ? "highlighter" : "bookmark", accessibilityDescription: nil), id: item.id.uuidString) { [weak self] in self?.dismissPalette(); self?.navigate(item.location) } }
            resultsList.onDeleteChoice = { [weak self] index in guard items.indices.contains(index) else { return }; self?.deleteRecord(items[index]) }
        } catch { environment.showError(error, in: window) } }
    }
    private func startSearch(_ input: String) {
        searchTask?.cancel(); searchInput = input; searchHits.removeAll(); searchIndex = -1; viewport.searchRects = [:]; updateSearchList()
        guard let info, !input.isEmpty else { return }
        let query = SearchQuery(input, pageCount: info.pageCount, chapter: searchChapter), service = service, token = generation
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(160)); guard let self else { return }
                var collected: [SearchHit] = []
                for page in query.pages {
                    try Task.checkCancellation(); let hits = try await service.matches(query: query, page: page)
                    guard generation == token, searchInput == input else { return }; collected.append(contentsOf: hits)
                    if page % 8 == 0 || page == query.pages.upperBound - 1 || collected.count >= 20_000 {
                        searchHits = Array(collected.prefix(20_000)); updateSearchList(); if paletteMode == .search { resultsList.detailLabel.stringValue = "\(searchHits.count) matches · searching page \(page + 1)" }
                    }
                    if collected.count >= 20_000 { if paletteMode == .search { resultsList.detailLabel.stringValue = "First 20,000 matches · narrow your search" }; break }
                    await Task.yield()
                }
                if paletteMode == .search { resultsList.detailLabel.stringValue = "\(searchHits.count) matches" + (searchHits.isEmpty ? " · scanned pages require OCR" : "") }
            } catch is CancellationError {} catch { self?.status.stringValue = error.localizedDescription }
        }
    }
    private func updateSearchList() {
        guard paletteMode == .search, panel != nil else { return }
        resultsList.choices = searchHits.enumerated().map { index, hit in ListChoice(hit.excerpt, detail: "Page \(hit.pageIndex + 1) · \(searchInput)", image: NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil), id: hit.id) { [weak self] in self?.dismissPalette(); self?.showSearchHit(index) } }
    }
    private func goToSearch(delta: Int) { guard !searchHits.isEmpty else { status.stringValue = "No search matches"; return }; let base = searchIndex >= 0 ? searchIndex : (delta > 0 ? -1 : 0); showSearchHit((base + delta + searchHits.count * 100_001) % searchHits.count) }
    private func showSearchHit(_ index: Int) {
        guard searchHits.indices.contains(index), let identity = info?.identity else { return }; searchIndex = index
        let hit = searchHits[index], service = service, token = generation
        Task { do {
            let geometry = try await service.geometry(pages: hit.pageIndex..<(hit.pageIndex + 1)).first
            let rects = try await service.selectionRects(page: hit.pageIndex, range: hit.range)
            guard generation == token, searchIndex == index, searchHits.indices.contains(index), searchHits[index].id == hit.id, let geometry else { return }
            info?.pages[hit.pageIndex] = geometry; viewport.replaceGeometry([geometry])
            viewport.searchRects = [hit.pageIndex: rects]
            let point = rects.first.map { geometry.readingAnchor(revealing: $0, viewport: viewport.contentSize, zoom: viewport.zoom, adding: viewport.rotation) } ?? geometry.pdfPoint(.zero, adding: viewport.rotation)
            navigate(DocumentLocation(document: identity, pageIndex: hit.pageIndex, point: point, zoom: viewport.zoom, rotation: viewport.rotation))
            status.stringValue = "Match \(index + 1) of \(searchHits.count)"
        } catch { environment.showError(error, in: window) } }
    }
    private func select(page: Int, point: CGPoint, initial: Bool, clicks: Int) {
        guard info?.allowsCopying == true, let snapshot = viewport.pageViews[page]?.text, let index = snapshot.nearestIndex(to: point) else { return }
        selectedHighlight = records.first(where: { $0.kind == .highlight && $0.location.document == info?.identity && $0.selection.contains(where: { $0.pageIndex == page && $0.rects.contains(where: { $0.contains(point) }) }) })?.id
        if initial {
            keyboardSelecting = false; selectionAnchor = (page, index); selectionCaret = (page, index)
            if clicks >= 3, let line = snapshot.lines.first(where: { NSLocationInRange(index, $0.range.nsRange) }) { selectionAnchor = (page, line.range.location); selectionCaret = (page, max(line.range.location, line.range.end - 1)) }
            else if clicks == 2 {
                let string = snapshot.text as NSString; var lo = index, hi = index
                func word(_ position: Int) -> Bool { guard position >= 0, position < string.length, let scalar = UnicodeScalar(string.character(at: position)) else { return false }; return CharacterSet.alphanumerics.contains(scalar) }
                while lo > 0, word(lo - 1) { lo -= 1 }; while hi + 1 < string.length, word(hi + 1) { hi += 1 }
                selectionAnchor = (page, lo); selectionCaret = (page, hi)
            }
        } else { selectionCaret = (page, index) }
        updateSelection()
    }
    private func updateSelection() {
        guard let anchor = selectionAnchor, let caret = selectionCaret else { return }
        selectionTask?.cancel(); let service = service, token = generation
        selectionTask = Task { [weak self] in do {
            let selection = try await service.selection(from: anchor.0, index: anchor.1, to: caret.0, index: caret.1)
            guard let self, generation == token, !Task.isCancelled else { return }; viewport.selection = selection
            NSAccessibility.post(element: viewport.canvas, notification: .selectedTextChanged)
        } catch { self?.status.stringValue = error.localizedDescription } }
    }
    private func beginKeyboardSelection() {
        guard let page = viewport.currentLocation?.pageIndex, let text = viewport.pageViews[page]?.text, let first = text.glyphs.first else { status.stringValue = "Text is still loading, or this page has no selectable text"; return }
        keyboardSelecting = true; selectionAnchor = (page, first.index); selectionCaret = selectionAnchor; updateSelection(); status.stringValue = "Arrow keys extend selection · ⌘C copy · h then a–z highlights · Escape exits"
    }
    private func extendKeyboardSelection(_ event: NSEvent) {
        guard var caret = selectionCaret, let info else { return }
        let delta = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : event.keyCode == 125 ? 70 : -70
        caret.1 += delta
        if caret.1 < 0, caret.0 > 0 { caret.0 -= 1; caret.1 = max(0, ((viewport.pageViews[caret.0]?.text?.text as NSString?)?.length ?? 1) - 1) }
        else if let length = (viewport.pageViews[caret.0]?.text?.text as NSString?)?.length, caret.1 >= length, caret.0 + 1 < info.pageCount { caret.0 += 1; caret.1 = 0 }
        selectionCaret = (caret.0, max(0, caret.1)); updateSelection()
        if viewport.pageViews[caret.0] == nil { viewport.scrollToPage(caret.0) }
    }
    private func copySelection() {
        guard info?.allowsCopying == true, let selection = viewport.selection, !selection.string.isEmpty else { status.stringValue = "Select text first"; return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selection.string, forType: .string); status.stringValue = "Copied \(selection.string.count) characters"
    }
    private func externalSearch(engine: String, text: String? = nil) {
        guard info?.allowsCopying == true else { status.stringValue = "This PDF does not allow text copying or external search"; return }
        guard let query = text ?? viewport.selection?.string, !ExternalSearchSettings.normalizedQuery(query).isEmpty else { status.stringValue = "Select text before searching externally"; return }
        do {
            let url = try environment.externalSearch.url(for: query, engine: engine)
            status.stringValue = NSWorkspace.shared.open(url) ? "Opened external search in your browser" : "Could not open your browser"
        } catch { status.stringValue = error.localizedDescription }
    }
    private func selectAll() {
        guard let info, info.allowsCopying else { return }; selectionAnchor = (0, 0); selectionCaret = (info.pageCount - 1, Int.max - 1); updateSelection()
    }
    private func addHighlight(style: String) {
        guard let selection = viewport.selection, !selection.parts.isEmpty, let location = viewport.currentLocation else { status.stringValue = "Select text before highlighting"; return }
        var anchor = location; anchor.pageIndex = selection.parts[0].pageIndex; anchor.point = selection.parts[0].rects.first.map { CGPoint(x: $0.minX, y: $0.maxY) } ?? anchor.point
        saveRecord(LibraryRecord(kind: .highlight, location: anchor, title: String(selection.string.prefix(180)), selection: selection.parts, style: style.lowercased()))
    }
    private func saveRecord(_ record: LibraryRecord, undo: Bool = true) {
        if record.kind == .mark {
            Task { do { let previous = try await environment.library.mark(record.title, document: record.location.document.id); applyRecordChange(before: previous.map { [$0] } ?? [], after: [record], name: "Set Mark", registerUndo: undo) } catch { environment.showError(error, in: window) } }
        } else { applyRecordChange(before: records.filter { $0.id == record.id }, after: [record], name: "Add \(record.kind.rawValue)", registerUndo: undo) }
    }
    private func deleteRecord(_ record: LibraryRecord, undo: Bool = true) {
        applyRecordChange(before: [record], after: [], name: "Delete \(record.kind.rawValue)", registerUndo: undo)
    }
    private func applyRecordChange(before: [LibraryRecord], after: [LibraryRecord], name: String, registerUndo: Bool = true) {
        if registerUndo {
            readerUndo.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { target.applyRecordChange(before: after, after: before, name: name) } }
            readerUndo.setActionName(name)
        }
        let previousTask = mutationTask
        mutationTask = Task { [weak self] in
            guard let self else { return }; await previousTask?.value
            do { try await environment.library.changeRecords(removing: before.map(\.id), saving: after); await refreshRecords(); status.stringValue = name }
            catch { readerUndo.removeAllActions(); environment.showError(error, in: window) }
        }
    }
    private func refreshRecords() async {
        guard let identity = info?.identity else { return }
        do { let loaded = try await environment.library.records(document: identity.id); guard info?.identity == identity else { return }; records = loaded; viewport.highlights = records.filter { $0.kind == .highlight }; if panel?.window?.isVisible == true, [.bookmarks, .allBookmarks, .highlights, .allHighlights].contains(paletteMode) { loadRecordList(paletteMode) }; lastPortalID = nil; updatePortal() } catch { status.stringValue = error.localizedDescription }
    }
    private func deleteNearest(kind: RecordKind) {
        guard let current = viewport.currentLocation else { return }
        if let record = records.filter({ $0.kind == kind && $0.location.document == current.document }).min(by: { abs($0.location.pageIndex - current.pageIndex) < abs($1.location.pageIndex - current.pageIndex) }) { deleteRecord(record) }
    }
    private func moveRuler(_ delta: Int) {
        guard let page = viewport.ruler?.0 ?? viewport.currentLocation?.pageIndex, let text = viewport.pageViews[page]?.text, !text.lines.isEmpty else { status.stringValue = "No text lines available"; return }
        let existing = viewport.ruler.flatMap { ruler in text.lines.firstIndex(where: { $0.bounds == ruler.1 }) } ?? -1
        let index = max(0, min(text.lines.count - 1, existing + delta)); viewport.ruler = (page, text.lines[index].bounds)
        if let view = viewport.pageViews[page] { view.scrollToVisible(view.screenRect(for: text.lines[index].bounds).insetBy(dx: 0, dy: -30)) }
    }
    private func pointer(page: Int, point: CGPoint, action: ReaderViewport.PointerAction) {
        guard let snapshot = viewport.pageViews[page]?.text else { return }
        if action == .externalSearch || action == .alternateExternalSearch {
            let engine = action == .externalSearch ? environment.externalSearch.middleClickSearchEngine : environment.externalSearch.shiftMiddleClickSearchEngine
            guard let geometry = info?.pages[page], let query = snapshot.externalSearchText(at: point, geometry: geometry) else { status.stringValue = "Middle-click a paper or book title to search externally"; return }
            externalSearch(engine: engine, text: query); return
        }
        if let link = snapshot.links.first(where: { $0.bounds.contains(point) }) { follow(link, page: page, preview: action == .preview); return }
        if let line = snapshot.lines.min(by: { abs($0.bounds.midY - point.y) < abs($1.bounds.midY - point.y) }) {
            viewport.ruler = (page, line.bounds)
            if action != .click { resolveReference(line.text, sourcePage: page, point: point, preview: action == .preview) }
        }
    }
    private func follow(_ link: PDFLink, page: Int, preview: Bool) {
        if let target = link.destinationPage, let info, info.pages.indices.contains(target) {
            let point = link.destinationPoint ?? info.pages[target].pdfPoint(.zero)
            let location = DocumentLocation(document: info.identity, pageIndex: target, point: point, zoom: viewport.zoom, rotation: viewport.rotation)
            if preview { showPreview(location, sourcePage: page, point: CGPoint(x: link.bounds.midX, y: link.bounds.midY)) } else { navigate(location) }
        } else if let url = link.url {
            guard ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { status.stringValue = "This link uses an unsupported URL scheme"; return }; NSWorkspace.shared.open(url)
        }
    }
    private func resolveCurrentReference(preview: Bool) {
        guard let current = viewport.currentLocation else { return }
        let text = viewport.selection?.string ?? viewport.ruler.flatMap { ruler in viewport.pageViews[ruler.0]?.text?.lines.first(where: { $0.bounds == ruler.1 })?.text }
        guard let text, !text.isEmpty else { status.stringValue = "Select a reference or place the reading ruler on its line"; return }
        resolveReference(text, sourcePage: viewport.ruler?.0 ?? current.pageIndex, point: viewport.ruler?.1.origin ?? current.point, preview: preview)
    }
    private func resolveReference(_ text: String, sourcePage: Int, point: CGPoint, preview: Bool) {
        let service = service, token = generation
        Task {
            let targets = await service.resolve(text); guard token == generation, let identity = info?.identity else { return }
            @MainActor func go(_ target: ReferenceTarget) { let location = DocumentLocation(document: identity, pageIndex: target.pageIndex, point: target.point, zoom: viewport.zoom, rotation: viewport.rotation); if preview { showPreview(location, sourcePage: sourcePage, point: point) } else { navigate(location) } }
            if targets.count == 1 { go(targets[0]) }
            else if !targets.isEmpty { showChoices("Reference Destinations", choices: targets.map { target in ListChoice(target.label, detail: "Page \(target.pageIndex + 1)") { go(target) } }) }
            else { status.stringValue = "Reference unresolved\((await service.indexedPageCount()) < (info?.pageCount ?? 0) ? " · indexing is still in progress" : "") · searching instead"; showListPalette(.search); resultsList.search.stringValue = text; startSearch(text) }
        }
    }
    private func smartFit() {
        guard let page = viewport.currentLocation?.pageIndex else { return }; let service = service, token = generation
        Task { do { let snapshot = try await service.text(page: page); guard generation == token else { return }; let bounds = snapshot.lines.map(\.bounds).reduce(CGRect.null) { $0.union($1) }; if !bounds.isNull { viewport.fit(widthOnly: true, contentBounds: bounds.insetBy(dx: -12, dy: -12)) } else { viewport.fit(widthOnly: true) } } catch { status.stringValue = error.localizedDescription } }
    }
    private func showPreview(_ location: DocumentLocation, sourcePage: Int, point: CGPoint) {
        guard let info, let page = viewport.pageViews[sourcePage] else { return }
        previewPopover?.close()
        let popover = NSPopover(); popover.behavior = .semitransient; popover.contentSize = CGSize(width: 620, height: 380)
        let controller = NSViewController(); let reader = ReaderViewport(renderer: environment.renderer); reader.pagePriority = 1; controller.view = reader
        reader.show(info: info, location: location); reader.onKey = { [weak self] event in if event.keyCode == 53 { self?.previewPopover?.close() } }
        popover.contentViewController = controller; previewViewport = reader; previewPopover = popover
        popover.show(relativeTo: page.screenRect(for: CGRect(x: point.x, y: point.y, width: 1, height: 1)), of: page, preferredEdge: .maxX)
    }
    private func createPortal() {
        guard let current = viewport.currentLocation else { return }
        if let source = portalSource { saveRecord(LibraryRecord(kind: .portal, location: source, title: "Portal to page \(current.pageIndex + 1)", destination: current)); portalSource = nil; status.stringValue = "Portal saved" }
        else { portalSource = current; status.stringValue = "Portal source set · navigate to its destination, then press p again" }
    }
    private func togglePortalWindow() {
        if let portalWindow { if portalWindow.isVisible { portalWindow.orderOut(nil); return }; portalWindow.makeKeyAndOrderFront(nil); lastPortalID = nil; updatePortal(); return }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 640), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false); window.title = "Portal — Swift Sioyek"; window.isReleasedWhenClosed = false
        let reader = ReaderViewport(renderer: environment.renderer); reader.pagePriority = 1; window.contentView = reader; portalViewport = reader; portalWindow = window
        reader.onKey = { [weak reader] event in if event.keyCode == 49 { reader?.scrollBy(dy: 300) } }
        window.center(); window.makeKeyAndOrderFront(nil); updatePortal()
    }
    private func updatePortal() {
        guard portalWindow?.isVisible == true, let current = viewport.currentLocation, let portal = ReferenceResolver.nearestPortal(in: records, to: current), let destination = portal.destination, portal.id != lastPortalID else { return }
        lastPortalID = portal.id
        if destination.document == info?.identity, let info { portalViewport?.show(info: info, location: destination); portalWindow?.title = "Portal · \(info.title) · page \(destination.pageIndex + 1)" }
        else {
            Task { do {
                guard let document = try await environment.library.document(id: destination.document.id), let resolved = FileIdentity.resolve(document) else { return }
                if portalScopeStarted { portalScopedURL?.stopAccessingSecurityScopedResource() }; portalScopedURL = resolved.url; portalScopeStarted = resolved.url.startAccessingSecurityScopedResource()
                let service = PDFTextService(), source = DocumentSource(identity: DocumentIdentity(id: document.id, revision: try FileIdentity.revision(of: resolved.url)), url: resolved.url)
                var otherInfo = try await service.open(source); let geometries = try await service.geometry(pages: 0..<otherInfo.pageCount); otherInfo.pages = geometries
                guard lastPortalID == portal.id else { return }; environment.renderer.register(source); portalViewport?.show(info: otherInfo, location: destination); portalWindow?.title = "Portal · \(otherInfo.title)"
            } catch { status.stringValue = "Portal: \(error.localizedDescription)" } }
        }
    }
    private func exportPDF() {
        guard let source, let window else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = source.url.deletingPathExtension().lastPathComponent + " — annotated.pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            let highlights = records.filter { $0.kind == .highlight }; status.stringValue = "Exporting annotated copy…"
            Task { do { try await PDFExporter().export(source: source, highlights: highlights, to: destination); status.stringValue = "Exported \(destination.lastPathComponent)" } catch { environment.showError(error, in: window) } }
        }
    }
}
