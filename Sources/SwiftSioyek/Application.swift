import AppKit
import UniformTypeIdentifiers
import ReaderCore
import ReaderPersistence
import PDFServices

@main
struct SwiftSioyekMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class ReaderEnvironment {
    let library: LibraryStore
    let renderer = RenderCoordinator()
    var bindings: KeyBindings
    var externalSearch: ExternalSearchSettings
    var windows: [ReaderWindowController] = []
    var settingsWindow: SettingsWindowController?
    let configurationURL: URL
    let externalSearchConfigurationURL: URL
    init(library: LibraryStore, bindings: KeyBindings, externalSearch: ExternalSearchSettings, configurationURL: URL, externalSearchConfigurationURL: URL) {
        self.library = library; self.bindings = bindings; self.externalSearch = externalSearch
        self.configurationURL = configurationURL; self.externalSearchConfigurationURL = externalSearchConfigurationURL
    }
    static func load() async throws -> ReaderEnvironment {
        let config = LibraryStore.defaultURL().deletingLastPathComponent().appendingPathComponent("KeyBindings.json")
        let searchConfig = config.deletingLastPathComponent().appendingPathComponent("ExternalSearch.json")
        let (library, bindings, externalSearch) = try await Task.detached {
            let library = try LibraryStore(url: LibraryStore.defaultURL())
            let bindings: KeyBindings
            if FileManager.default.fileExists(atPath: config.path) { bindings = try JSONDecoder().decode(KeyBindings.self, from: Data(contentsOf: config)); try bindings.validate() }
            else { bindings = KeyBindings() }
            let externalSearch: ExternalSearchSettings
            if FileManager.default.fileExists(atPath: searchConfig.path) { externalSearch = try JSONDecoder().decode(ExternalSearchSettings.self, from: Data(contentsOf: searchConfig)); try externalSearch.validate() }
            else { externalSearch = ExternalSearchSettings() }
            return (library, bindings, externalSearch)
        }.value
        return ReaderEnvironment(library: library, bindings: bindings, externalSearch: externalSearch, configurationURL: config, externalSearchConfigurationURL: searchConfig)
    }
    @discardableResult func newWindow(url: URL? = nil, location: DocumentLocation? = nil) -> ReaderWindowController {
        let controller = ReaderWindowController(environment: self)
        windows.append(controller); controller.showWindow(nil)
        if let url { controller.open(url, location: location) }
        return controller
    }
    func close(_ controller: ReaderWindowController) { windows.removeAll { $0 === controller }; Task { await saveSession() } }
    func saveSession() async {
        for controller in windows { await controller.flushPosition() }
        let ids = windows.compactMap { $0.info?.identity.id }
        do { try await library.saveState(ids, key: "openWindows") } catch { showError(error) }
    }
    func restore() async {
        do {
            let ids = try await library.state([UUID].self, key: "openWindows") ?? []
            for id in ids {
                if let document = try await library.document(id: id), let resolved = FileIdentity.resolve(document) { newWindow(url: resolved.url, location: document.location) }
            }
        } catch { showError(error) }
        if windows.isEmpty { newWindow() }
    }
    func openPanel(in controller: ReaderWindowController? = nil) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = true
        panel.begin { [weak self, weak controller] response in
            guard response == .OK, let self else { return }
            for (index, url) in panel.urls.enumerated() {
                if index == 0, let controller { controller.open(url) } else { self.newWindow(url: url) }
            }
        }
    }
    func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(environment: self) }
        settingsWindow?.showWindow(nil); settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    func showError(_ error: Error, in window: NSWindow? = nil) {
        let alert = NSAlert(); alert.messageText = "Swift Sioyek"; alert.informativeText = error.localizedDescription; alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var environment: ReaderEnvironment?
    private var pendingURLs: [URL] = []
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenus()
        Task {
            do {
                let environment = try await ReaderEnvironment.load(); self.environment = environment
                let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && $0.lowercased().hasSuffix(".pdf") }.map { URL(fileURLWithPath: $0) }
                let urls = pendingURLs + arguments; pendingURLs.removeAll()
                if urls.isEmpty { await environment.restore() } else { for url in urls { environment.newWindow(url: url) } }
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                let alert = NSAlert(); alert.messageText = "Cannot open the reader library"; alert.informativeText = error.localizedDescription + "\n\nYour files have not been changed. If KeyBindings.json or ExternalSearch.json is invalid, correct it and relaunch."; alert.runModal(); NSApp.terminate(nil)
            }
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let environment else { pendingURLs.append(contentsOf: urls); return }
        for url in urls { if let blank = environment.windows.first(where: { $0.info == nil }) { blank.open(url) } else { environment.newWindow(url: url) } }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { environment?.newWindow() }; return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        Task { await environment?.saveSession(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    @objc func dispatchCommand(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let command = ReaderCommand(rawValue: value), let environment else { return }
        let controller = [NSApp.keyWindow, NSApp.keyWindow?.parent, NSApp.mainWindow].compactMap { $0?.windowController as? ReaderWindowController }.first ?? environment.windows.last
        switch command {
        case .settings: environment.showSettings()
        case .open: environment.openPanel(in: controller)
        default: controller?.perform(CommandInvocation(command))
        }
    }
    @objc func newWindow(_ sender: Any?) { environment?.newWindow() }
    private func makeMenus() {
        let main = NSMenu(); NSApp.mainMenu = main
        func menu(_ title: String) -> NSMenu { let item = NSMenuItem(); item.title = title; let menu = NSMenu(title: title); item.submenu = menu; main.addItem(item); return menu }
        func add(_ command: ReaderCommand, to menu: NSMenu, key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: command.title, action: #selector(dispatchCommand(_:)), keyEquivalent: key); item.target = self; item.representedObject = command.rawValue; item.keyEquivalentModifierMask = modifiers; menu.addItem(item)
        }
        let app = menu("Swift Sioyek")
        app.addItem(withTitle: "About Swift Sioyek", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        add(.settings, to: app, key: ","); app.addItem(.separator())
        app.addItem(withTitle: "Hide Swift Sioyek", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Swift Sioyek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = menu("File"); add(.open, to: file, key: "o"); add(.recent, to: file, key: "o", modifiers: [.command, .shift])
        let new = file.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n"); new.target = self
        file.addItem(.separator()); add(.exportPDF, to: file, key: "e", modifiers: [.command, .shift]); file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = menu("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(.search, to: edit, key: "f"); add(.nextMatch, to: edit, key: "g"); add(.previousMatch, to: edit, key: "g", modifiers: [.command, .shift])
        let view = menu("View"); add(.outline, to: view, key: "t", modifiers: [.command]); add(.thumbnails, to: view); add(.toggleSinglePage, to: view)
        view.addItem(.separator()); add(.zoomIn, to: view, key: "+"); add(.zoomOut, to: view, key: "-"); add(.fitPage, to: view, key: "0"); add(.fitWidth, to: view); add(.smartFit, to: view); add(.rotateRight, to: view)
        let navigate = menu("Navigate"); add(.goToPage, to: navigate, key: "l"); add(.back, to: navigate, key: "["); add(.forward, to: navigate, key: "]"); add(.nextChapter, to: navigate); add(.previousChapter, to: navigate); add(.palette, to: navigate, key: "k")
        let research = menu("Research")
        for command: ReaderCommand in [.externalSearch, .addBookmark, .bookmarks, .allBookmarks, .addHighlight, .highlights, .allHighlights, .setMark, .goToMark, .setRuler, .keyboardSelect, .linkHints, .preview, .smartJump, .portal, .goToPortal, .togglePortal] { add(command, to: research) }
        let window = menu("Window"); window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"); window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""); NSApp.windowsMenu = window
        let help = menu("Help"); let commands = help.addItem(withTitle: "Show Commands and Keyboard Shortcuts", action: #selector(dispatchCommand(_:)), keyEquivalent: "p"); commands.representedObject = ReaderCommand.palette.rawValue; commands.target = self; commands.keyEquivalentModifierMask = [.command, .shift]
    }
}
