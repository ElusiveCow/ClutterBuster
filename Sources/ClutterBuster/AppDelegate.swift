import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = FenceStore()
    private let desktop = DesktopIconService()
    private lazy var coordinator = FenceCoordinator(store: store, desktop: desktop)
    private var toolbar: ToolbarWindowController?
    private var search: SearchController?
    private var statusItem: NSStatusItem?
    private var fencesMenuItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var shownAccessAlert = false
    private var sigterm: DispatchSourceSignal?
    private let watcher = DesktopWatcher()
    private var autoFiler: AutoFiler?
    private lazy var newFilePrompt = NewFilePromptController(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched with \(store.fences.count) fences")
        LoginItem.shared.registerAtLaunch()
        desktop.onAccessDenied = { [weak self] in self?.showAccessAlert() }
        coordinator.start()
        quitOnSIGTERM()

        let search = SearchController(store: store) { [weak self] in self?.toolbar?.window }
        search.reveal = { [weak self] url in self?.coordinator.revealInFinder(url) }
        search.openItem = { [weak self] id in
            guard let self, let item = self.coordinator.fencedItem(id) else { return }
            self.coordinator.open(item)
        }
        search.showItem = { [weak self] id in self?.coordinator.showInFence(id) }
        search.showNote = { [weak self] match in
            Log.write("search: showing line \(match.line + 1) of sticky note \(match.fenceID)")
            self?.coordinator.focusStickyNote(match.fenceID, select: match.range)
        }
        self.search = search
        NSApp.mainMenu = Self.editMenu()
        let toolbar = ToolbarWindowController(store: store, fences: coordinator, search: search, actions: ToolbarActions(
            newFence: { [weak self] in self?.coordinator.createFenceWithSetup() },
            newStickyNote: { [weak self] in self?.coordinator.createFenceWithSetup(style: .stickyNote) },
            collapseAll: { [weak self] in self?.coordinator.setAllCollapsed(true) },
            expandAll: { [weak self] in self?.coordinator.setAllCollapsed(false) },
            toggleFences: { [weak self] in self?.toggleFences() },
            openSettings: { [weak self] in self?.openSettings() }
        ))
        toolbar.show()
        self.toolbar = toolbar
        coordinator.toolbarFrame = { [weak toolbar] in
            guard let toolbar, toolbar.isVisible else { return nil }
            return toolbar.window.frame
        }
        coordinator.onDisplayLayoutChanged = { [weak toolbar] in toolbar?.applyStoredPlacement() }
        buildStatusItem()

        // Ask for Finder access up front rather than on the first drop.
        _ = desktop.positionsNow()

        newFilePrompt.placement = { [weak toolbar] in toolbar?.placement }
        let autoFiler = AutoFiler(coordinator: coordinator, prompt: newFilePrompt)
        self.autoFiler = autoFiler
        watcher.isFenced = { [weak self] path in
            self?.store.fences.contains { $0.items.contains { $0.path == path } } ?? false
        }
        watcher.onNewFiles = { [weak autoFiler] urls in autoFiler?.handle(urls) }
        watcher.start()

        if let demoPath = UserDefaults.standard.string(forKey: "CBDemoPath") {
            let id = coordinator.createFence(title: "Demo")
            coordinator.addItems([URL(fileURLWithPath: demoPath)], to: id)
        }

        if UserDefaults.standard.bool(forKey: "CBDemoNewFence") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let id = self?.coordinator.createFenceWithSetup() else { return }
                Log.write("demo: created fence \(id) with setup card")
            }
        }

        if let demoSearch = UserDefaults.standard.string(forKey: "CBDemoSearch") {
            // Long enough for a screenshot; after that it closes like any other search.
            search.holdsOpenUntil = Date().addingTimeInterval(8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.search?.focus(query: demoSearch)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        watcher.stop()
        newFilePrompt.leave(reason: "Clutter Buster quit")
        coordinator.saveStickyNotes()
        coordinator.restoreAllToDesktop()
        store.saveNow()
        return .terminateNow
    }

    /// `kill` and `killall` quit like the Quit command, so fenced files don't stay hidden
    /// until the next launch.
    private func quitOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Log.write("SIGTERM: quitting")
            NSApp.terminate(nil)
        }
        source.resume()
        sigterm = source
    }

    // MARK: Menu bar

    /// Never shown, since Clutter Buster has no menu bar of its own, but its shortcuts make
    /// Copy, Paste, Undo and Select All work in notes and text fields.
    private static func editMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Clutter Buster", action: nil, keyEquivalent: ""))
        let editItem = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        return main
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Clutter Buster")
        let menu = NSMenu()
        menu.addItem(withTitle: "Search…", action: #selector(openSearch), keyEquivalent: "f").target = self
        menu.addItem(withTitle: "New Fence", action: #selector(newFence), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "New Sticky Note", action: #selector(newStickyNote), keyEquivalent: "").target = self
        let fencesItem = menu.addItem(withTitle: "Hide Fences", action: #selector(toggleFences), keyEquivalent: "")
        fencesItem.target = self
        fencesMenuItem = fencesItem
        menu.addItem(withTitle: "Show or Hide Toolbar", action: #selector(toggleToolbar), keyEquivalent: "t").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clutter Buster", action: #selector(quit), keyEquivalent: "q").target = self
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        fencesMenuItem?.title = coordinator.fencesHidden ? "Show Fences" : "Hide Fences"
    }

    @objc private func openSearch() {
        toolbar?.show()
        // Let the status menu finish closing before taking focus.
        DispatchQueue.main.async { [weak self] in self?.search?.focus() }
    }

    @objc private func newFence() {
        // Let the status menu finish closing so its click doesn't dismiss the setup card.
        DispatchQueue.main.async { [weak self] in self?.coordinator.createFenceWithSetup() }
    }

    @objc private func newStickyNote() {
        DispatchQueue.main.async { [weak self] in self?.coordinator.createFenceWithSetup(style: .stickyNote) }
    }

    @objc private func toggleFences() {
        coordinator.setFencesHidden(!coordinator.fencesHidden)
    }

    @objc private func toggleToolbar() {
        guard let toolbar else { return }
        if toolbar.isVisible { toolbar.hide() } else { toolbar.show() }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(onQuit: { NSApp.terminate(nil) }).environmentObject(store)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Clutter Buster Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showAccessAlert() {
        guard !shownAccessAlert else { return }
        shownAccessAlert = true
        let alert = NSAlert()
        alert.messageText = "Clutter Buster needs permission to control Finder"
        alert.informativeText = "It uses Finder to put desktop icons back where they were when they leave a fence. Turn on Finder for Clutter Buster in System Settings > Privacy & Security > Automation, then reopen the app."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
