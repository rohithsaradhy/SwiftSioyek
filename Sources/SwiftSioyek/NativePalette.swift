import AppKit

@MainActor
struct ListChoice {
    var id: String
    var title: String
    var detail: String
    var shortcut: String
    var image: NSImage?
    var action: @MainActor () -> Void
    init(_ title: String, detail: String = "", shortcut: String = "", image: NSImage? = nil, id: String? = nil, action: @escaping @MainActor () -> Void) {
        self.id = id ?? title + "\n" + detail; self.title = title; self.detail = detail; self.shortcut = shortcut; self.image = image; self.action = action
    }
}

@MainActor
final class ChoiceTable: NSTableView {
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onEnter?()
        case 53: onEscape?()
        case 51, 117: if let onDelete { onDelete() } else { super.keyDown(with: event) }
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
private final class PaletteSurface: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
final class ListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let search = NSSearchField(frame: CGRect(x: 0, y: 0, width: 560, height: 40))
    let table = ChoiceTable(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
    let detailLabel = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "Type to search")
    private let modeIcon = NSImageView()
    private let scroll = NSScrollView()
    private var filtered: [Int] = []
    var choices: [ListChoice] = [] {
        didSet {
            let oldID = filtered.indices.contains(table.selectedRow) && oldValue.indices.contains(filtered[table.selectedRow]) ? oldValue[filtered[table.selectedRow]].id : nil
            filter(preserving: oldID)
        }
    }
    var onSearch: ((String) -> Void)?
    var onDeleteChoice: ((Int) -> Void)?
    var onEscape: (() -> Void)?
    var onDisplay: ((Int, NSTableCellView) -> Void)?
    var onResultCountChanged: ((Int) -> Void)?
    var titleText = "Search commands…" { didSet { search.placeholderString = titleText; search.setAccessibilityLabel(titleText) } }
    var symbol = "command" { didSet { updateSymbol() } }
    var filterLocally = true
    var emptyMessage = "No matches. Try another search." { didSet { empty.stringValue = emptyMessage } }
    override func loadView() {
        let surface = PaletteSurface(frame: CGRect(x: 0, y: 0, width: 620, height: 408))
        surface.wantsLayer = true; surface.layer?.cornerRadius = 14; surface.layer?.masksToBounds = true; surface.layer?.borderWidth = 0.5
        view = surface
        search.delegate = self; search.sendsSearchStringImmediately = true; search.sendsWholeSearchString = false
        search.font = .systemFont(ofSize: 19, weight: .regular); search.controlSize = .large
        search.focusRingType = .none; search.isBezeled = false; search.drawsBackground = false
        search.placeholderString = titleText; search.setAccessibilityLabel(titleText)
        search.setAccessibilityIdentifier("palette.search")
        if let cell = search.cell as? NSSearchFieldCell { cell.searchButtonCell = nil }
        modeIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular); modeIcon.contentTintColor = .secondaryLabelColor; updateSymbol()
        let escape = NSButton(title: "esc", target: self, action: #selector(dismissPaletteButton)); escape.bezelStyle = .inline; escape.font = .monospacedSystemFont(ofSize: 11, weight: .medium); escape.setAccessibilityLabel("Close palette")
        let separator = NSBox(); separator.boxType = .separator
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")); column.width = 640; column.minWidth = 160; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 50; table.intercellSpacing = CGSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.autoresizingMask = [.width]
        table.delegate = self; table.dataSource = self; table.backgroundColor = .clear; table.style = .inset
        table.selectionHighlightStyle = .regular; table.target = self; table.doubleAction = #selector(choose)
        table.setAccessibilityLabel("Palette results")
        table.setAccessibilityIdentifier("palette.results")
        table.onEnter = { [weak self] in self?.choose() }; table.onEscape = { [weak self] in self?.onEscape?() }
        table.onDelete = { [weak self] in guard let self, filtered.indices.contains(table.selectedRow) else { return }; onDeleteChoice?(filtered[table.selectedRow]) }
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.drawsBackground = false; scroll.borderType = .noBorder
        detailLabel.font = .systemFont(ofSize: 11); detailLabel.textColor = .secondaryLabelColor; detailLabel.lineBreakMode = .byTruncatingTail
        let keys = NSTextField(labelWithString: "↑↓  Navigate     ↩  Open"); keys.font = .systemFont(ofSize: 10); keys.textColor = .tertiaryLabelColor
        empty.font = .systemFont(ofSize: 14); empty.textColor = .secondaryLabelColor; empty.alignment = .center; empty.maximumNumberOfLines = 3
        for child in [modeIcon, search, escape, separator, scroll, empty, detailLabel, keys] { child.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(child) }
        NSLayoutConstraint.activate([
            modeIcon.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20), modeIcon.topAnchor.constraint(equalTo: surface.topAnchor, constant: 20), modeIcon.widthAnchor.constraint(equalToConstant: 22), modeIcon.heightAnchor.constraint(equalToConstant: 24),
            search.leadingAnchor.constraint(equalTo: modeIcon.trailingAnchor, constant: 10), search.centerYAnchor.constraint(equalTo: modeIcon.centerYAnchor), search.trailingAnchor.constraint(equalTo: escape.leadingAnchor, constant: -12), search.heightAnchor.constraint(equalToConstant: 34),
            escape.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20), escape.centerYAnchor.constraint(equalTo: search.centerYAnchor), escape.widthAnchor.constraint(equalToConstant: 32),
            separator.leadingAnchor.constraint(equalTo: surface.leadingAnchor), separator.trailingAnchor.constraint(equalTo: surface.trailingAnchor), separator.topAnchor.constraint(equalTo: surface.topAnchor, constant: 63),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 6), scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -6), scroll.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -8),
            detailLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 22), detailLabel.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -13), detailLabel.heightAnchor.constraint(equalToConstant: 16),
            keys.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20), keys.centerYAnchor.constraint(equalTo: detailLabel.centerYAnchor), detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor), empty.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40)
        ])
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scroll.contentSize.width
        guard width > 0, abs(table.frame.width - width) > 0.5 else { return }
        table.setFrameSize(CGSize(width: width, height: table.frame.height))
        table.sizeLastColumnToFit()
    }
    private func updateSymbol() { modeIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    func controlTextDidChange(_ obj: Notification) { if filterLocally { filter() }; onSearch?(search.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): choose(); return true
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.cancelOperation(_:)): onEscape?(); return true
        default: return false
        }
    }
    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let row = max(0, min(filtered.count - 1, table.selectedRow + delta)); table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    private func filter(preserving selectedID: String? = nil) {
        loadViewIfNeeded()
        let words = filterLocally ? search.stringValue.split(whereSeparator: \.isWhitespace).map(String.init) : []
        filtered = choices.indices.filter { index in words.allSatisfy { (choices[index].title + " " + choices[index].detail).localizedCaseInsensitiveContains($0) } }
        table.reloadData()
        if !filtered.isEmpty {
            let selected = selectedID.flatMap { id in filtered.firstIndex(where: { choices[$0].id == id }) } ?? 0
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
        empty.isHidden = !filtered.isEmpty
        empty.stringValue = search.stringValue.isEmpty && choices.isEmpty ? "Type to search this document" : emptyMessage
        detailLabel.stringValue = "\(filtered.count) result\(filtered.count == 1 ? "" : "s")"
        onResultCountChanged?(filtered.count)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }; let choice = choices[filtered[row]]
        let identifier = NSUserInterfaceItemIdentifier("palette-row")
        let cell: NSTableCellView
        if let existing = table.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView { cell = existing }
        else {
            cell = NSTableCellView(); cell.identifier = identifier
            let title = NSTextField(labelWithString: ""); title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail; title.tag = 1
            let detail = NSTextField(labelWithString: ""); detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingTail; detail.tag = 2
            let image = NSImageView(); image.tag = 3; image.imageScaling = .scaleProportionallyUpOrDown; image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular); image.contentTintColor = .secondaryLabelColor
            let shortcut = NSTextField(labelWithString: ""); shortcut.tag = 4; shortcut.font = .monospacedSystemFont(ofSize: 11, weight: .regular); shortcut.textColor = .secondaryLabelColor; shortcut.alignment = .right
            shortcut.setContentHuggingPriority(.required, for: .horizontal); shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
            for child in [title, detail, image, shortcut] { child.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(child) }
            NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 22), image.heightAnchor.constraint(equalToConstant: 30), title.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 12), title.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -12), title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 7), detail.leadingAnchor.constraint(equalTo: title.leadingAnchor), detail.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -12), detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2), shortcut.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14), shortcut.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            cell.textField = title; cell.imageView = image
        }
        (cell.viewWithTag(1) as? NSTextField)?.stringValue = choice.title; (cell.viewWithTag(2) as? NSTextField)?.stringValue = choice.detail
        (cell.viewWithTag(3) as? NSImageView)?.image = choice.image ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        (cell.viewWithTag(4) as? NSTextField)?.stringValue = choice.shortcut
        cell.setAccessibilityLabel(choice.title + ". " + choice.detail); onDisplay?(filtered[row], cell); return cell
    }
    @objc func choose() { guard filtered.indices.contains(table.selectedRow) else { return }; choices[filtered[table.selectedRow]].action() }
    @objc private func dismissPaletteButton() { onEscape?() }
    func focusSearch(selectAll: Bool = false) { view.window?.makeFirstResponder(search); if selectAll { search.selectText(nil) } }
}

@MainActor
private final class SpotlightWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ChoicePanel: NSWindowController, NSWindowDelegate {
    let list = ListController()
    var onClose: (() -> Void)?
    private var closing = false
    private var resultCount = 0
    private var preferredHeight: CGFloat { CGFloat(max(1, min(6, resultCount))) * 52 + 124 }
    init(title: String, choices: [ListChoice]) {
        let panel = SpotlightWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 408), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = title; panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
        super.init(window: panel); panel.delegate = self; panel.contentViewController = list
        list.onResultCountChanged = { [weak self] count in self?.resultCount = count; self?.resizeToResults() }
        list.titleText = title; list.loadViewIfNeeded(); list.choices = choices
        list.onEscape = { [weak self] in self?.close() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(relativeTo parent: NSWindow?) {
        guard let window else { return }
        let screen = parent?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 900)
        let width = min(620, max(460, (parent?.frame.width ?? screen.width) - 48), screen.width - 40)
        let height = min(preferredHeight, screen.height - 100)
        let centerX = parent?.frame.midX ?? screen.midX
        let top = min(screen.maxY - 48, (parent?.frame.maxY ?? screen.maxY) - 90)
        let origin = CGPoint(x: max(screen.minX + 20, min(centerX - width / 2, screen.maxX - width - 20)), y: max(screen.minY + 20, top - height))
        window.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: false)
        if let parent { parent.addChildWindow(window, ordered: .above) }
        window.makeKeyAndOrderFront(nil); list.focusSearch(selectAll: true)
    }
    private func resizeToResults() {
        guard let window, window.isVisible else { return }
        let screen = window.screen?.visibleFrame ?? window.frame
        let height = min(preferredHeight, screen.height - 100)
        guard abs(window.frame.height - height) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y = max(screen.minY + 20, frame.maxY - height); frame.size.height = height
        window.setFrame(frame, display: true, animate: false)
    }
    override func close() { guard !closing else { return }; closing = true; super.close() }
    func windowWillClose(_ notification: Notification) { if let window { window.parent?.removeChildWindow(window) }; onClose?() }
    func windowDidResignKey(_ notification: Notification) { if !closing { close() } }
}
