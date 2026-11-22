import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = FenceStore()
    private let desktop = DesktopIconService()
    private lazy var coordinator = FenceCoordinator(store: store, desktop: desktop)
    private var toolbar: ToolbarWindowController?
    private var search: SearchController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var shownAccessAlert = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched with \(store.fences.count) fences")
        desktop.onAccessDenied = { [weak self] in self?.showAccessAlert() }
        coordinator.start()

        let search = SearchController(store: store) { [weak self] in self?.toolbar?.window }
        search.reveal = { [weak self] url in self?.coordinator.revealInFinder(url) }
        self.search = search
        let toolbar = ToolbarWindowController(store: store, search: search, actions: ToolbarActions(
            newFence: { [weak self] in self?.coordinator.createFenceWithSetup() },
            collapseAll: { [weak self] in self?.coordinator.setAllCollapsed(true) },
            expandAll: { [weak self] in self?.coordinator.setAllCollapsed(false) },
            openSettings: { [weak self] in self?.openSettings() }
        ))
        toolbar.show()
        self.toolbar = toolbar
        coordinator.toolbarFrame = { [weak toolbar] in
            guard let toolbar, toolbar.isVisible else { return nil }
            return toolbar.window.frame
        }
        buildStatusItem()

        // Ask for Finder access up front rather than on the first drop.
        _ = desktop.positionsNow()

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
        coordinator.restoreAllToDesktop()
        store.saveNow()
        return .terminateNow
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Clutter Buster")
        let menu = NSMenu()
        menu.addItem(withTitle: "Search…", action: #selector(openSearch), keyEquivalent: "f").target = self
        menu.addItem(withTitle: "New Fence", action: #selector(newFence), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "Show or Hide Toolbar", action: #selector(toggleToolbar), keyEquivalent: "t").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clutter Buster", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
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
