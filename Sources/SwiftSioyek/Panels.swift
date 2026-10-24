import AppKit
import ReaderCore

@MainActor
final class SettingsWindowController: NSWindowController {
    weak var environment: ReaderEnvironment?
    private let editor = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private let section = NSSegmentedControl(labels: ["Keyboard Bindings", "External Search"], trackingMode: .selectOne, target: nil, action: nil)
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private var drafts = ["", ""]
    private var selectedSection = 0
    init(environment: ReaderEnvironment) {
        self.environment = environment
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 580), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings — Swift Sioyek"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = NSView(); window.contentView = content
        section.selectedSegment = 0; section.target = self; section.action = #selector(changeSection)
        section.setAccessibilityIdentifier("settings.section")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = editor
        editor.isRichText = false; editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false; editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityIdentifier("settings.editor")
        let apply = NSButton(title: "Apply", target: self, action: #selector(apply)); apply.bezelStyle = .rounded; apply.keyEquivalent = "\r"
        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(reset)); reset.bezelStyle = .rounded
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11)
        for view in [section, descriptionLabel, scroll, status, apply, reset] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([section.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), section.centerXAnchor.constraint(equalTo: content.centerXAnchor), descriptionLabel.topAnchor.constraint(equalTo: section.bottomAnchor, constant: 16), descriptionLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), descriptionLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), scroll.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 16), scroll.leadingAnchor.constraint(equalTo: descriptionLabel.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: descriptionLabel.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: apply.topAnchor, constant: -16), apply.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), apply.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16), reset.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), reset.centerYAnchor.constraint(equalTo: apply.centerYAnchor), status.leadingAnchor.constraint(equalTo: reset.trailingAnchor, constant: 16), status.trailingAnchor.constraint(lessThanOrEqualTo: apply.leadingAnchor, constant: -16), status.centerYAnchor.constraint(equalTo: apply.centerYAnchor)])
        drafts = [json(environment.bindings), json(environment.externalSearch)]; showSection(); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func json(_ value: some Encodable) -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "" }
    @objc private func changeSection() {
        drafts[selectedSection] = editor.string; selectedSection = section.selectedSegment; showSection()
    }
    private func showSection() {
        editor.string = drafts[selectedSection]; status.stringValue = ""
        descriptionLabel.stringValue = selectedSection == 0
            ? "Edit key sequences and command IDs. Mac shortcuts remain available. Escape cancels a sequence; bindings pause while typing. s then a–z searches selected text externally. j/k move the reading ruler."
            : "Map letters a–z in searchURLs to URL prefixes; selected text is URL-encoded and appended. ss: Scholar, sl: Library Genesis, sg: Google. Middle-click guesses the title under the pointer; Shift-middle-click uses the alternate engine. Apply saves this section for all windows."
    }
    @objc private func reset() { editor.string = selectedSection == 0 ? json(KeyBindings()) : json(ExternalSearchSettings()); status.stringValue = "Defaults loaded. Apply to save this section." }
    @objc private func apply() {
        guard let environment else { return }
        do {
            let data = Data(editor.string.utf8), index = selectedSection
            let bindings = index == 0 ? try JSONDecoder().decode(KeyBindings.self, from: data) : nil
            let search = index == 1 ? try JSONDecoder().decode(ExternalSearchSettings.self, from: data) : nil
            try bindings?.validate(); try search?.validate()
            let url = index == 0 ? environment.configurationURL : environment.externalSearchConfigurationURL
            Task {
                do {
                    try await Task.detached { try data.write(to: url, options: .atomic) }.value
                    if let bindings { environment.bindings = bindings; for window in environment.windows { window.updateBindings(bindings) } }
                    if let search { environment.externalSearch = search }
                    drafts[index] = String(decoding: data, as: UTF8.self)
                    status.stringValue = "Saved. All reader windows updated."
                } catch { status.stringValue = error.localizedDescription }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
}
