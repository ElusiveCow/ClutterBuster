import AppKit
import SwiftUI

/// Links, notes and Shortcuts, and the Add menu. None of these touch the Desktop, so none
/// of them hide or unhide anything.
extension FenceCoordinator {
    /// The tab new items go in: `tab` if the fence still has it, else the one showing.
    private func tabID(in fence: Fence, _ tab: UUID?) -> UUID {
        tab.flatMap { tab in fence.tabs.contains { $0.id == tab } ? tab : nil } ?? fence.currentTab.id
    }

    /// Adds what was dropped on a fence: files and apps by reference, web addresses as links.
    func addDropped(_ urls: [URL], to id: UUID, tab: UUID? = nil) {
        guard store.fence(id)?.holdsItems == true else { return }
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { addItems(files, to: id, tab: tab) }
        for url in urls where !url.isFileURL {
            guard let web = FenceItem.webURL(from: url.absoluteString, strict: true) else {
                Log.write("drop: \"\(url.absoluteString)\" isn't a file or a web address, skipped")
                continue
            }
            addLink(web, title: nil, to: id, tab: tab)
        }
    }

    /// Adds a link and fetches its page for a title (unless one was given) and its site's icon.
    @discardableResult
    func addLink(_ url: URL, title: String?, to id: UUID, tab: UUID? = nil) -> UUID? {
        guard let fence = store.fence(id) else { return nil }
        if let existing = fence.items.first(where: { $0.kind == .link && $0.link == url.absoluteString }) {
            Log.write("link: \(url.absoluteString) is already in \"\(fence.title)\"")
            selectedItemID = existing.id
            return existing.id
        }
        let item = FenceItem.link(url, title: title, tabID: tabID(in: fence, tab))
        store.update(id) { $0.items.append(item) }
        selectedItemID = item.id
        Log.write("link: added \(url.absoluteString) to \"\(fence.title)\" as \"\(item.displayName)\"")
        let wantsTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        Task { [weak self] in
            let pageTitle = await Favicons.shared.fetchPage(url)
            guard wantsTitle, let pageTitle, let self, let fenceID = self.fenceID(holding: item.id) else { return }
            var renamed = false
            self.store.update(fenceID) { fence in
                // Unless it was renamed meanwhile.
                guard let index = fence.items.firstIndex(where: { $0.id == item.id }), fence.items[index].title == item.title else { return }
                fence.items[index].title = pageTitle
                renamed = true
            }
            if renamed { Log.write("link: titled \(url.absoluteString) \"\(pageTitle)\"") }
        }
        return item.id
    }

    /// Adds an empty note and opens it for typing.
    func addNote(to id: UUID) {
        guard let fence = store.fence(id) else { return }
        let item = FenceItem.note(tabID: fence.currentTab.id)
        store.update(id) { $0.items.append(item) }
        selectedItemID = item.id
        Log.write("note: added one to \"\(fence.title)\"")
        // Once its tile is on screen to point at.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.editNote(item.id, in: id, isNew: true)
        }
    }

    func addShortcuts(_ names: [String], to id: UUID) {
        guard let fence = store.fence(id) else { return }
        let existing = Set(fence.items.filter { $0.kind == .shortcut }.compactMap(\.title))
        let items = names.filter { !existing.contains($0) }.map { FenceItem.shortcut($0, tabID: fence.currentTab.id) }
        guard !items.isEmpty else { return }
        store.update(id) { $0.items.append(contentsOf: items) }
        selectedItemID = items.last?.id
        Log.write("shortcut: added \(items.map { "\"\($0.displayName)\"" }.joined(separator: ", ")) to \"\(fence.title)\"")
    }

    /// Moves a link, note or Shortcut to another fence. Files go through `addItems`, which
    /// also looks after their Desktop icons.
    func moveNonFileItem(_ item: FenceItem, from sourceID: UUID, to targetID: UUID, tab: UUID?) {
        guard !item.isFile, let target = store.fence(targetID), target.holdsItems else { return }
        if noteEditor?.itemID == item.id { closeNoteEditor() }
        var moved = item
        moved.tabID = tabID(in: target, tab)
        store.update(sourceID) { $0.items.removeAll { $0.id == item.id } }
        store.update(targetID) { $0.items.append(moved) }
    }

    func setNoteText(_ itemID: UUID, in fenceID: UUID, _ text: String) {
        store.update(fenceID) { fence in
            guard let index = fence.items.firstIndex(where: { $0.id == itemID }), fence.items[index].text != text else { return }
            fence.items[index].text = text
            fence.items[index].editedAt = Date()
        }
    }

    // MARK: Pasting

    /// Adds what's on the clipboard to a fence: copied files and apps, or web addresses; or
    /// text to the end of a sticky note. Returns false when there's nothing to add.
    func paste(into id: UUID, from pasteboard: NSPasteboard = .general) -> Bool {
        guard let fence = store.fence(id) else { return false }
        if fence.isStickyNote { return pasteIntoStickyNote(id, from: pasteboard) }
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            Log.write("paste: \(files.count) file(s) into \"\(fence.title)\"")
            addItems(files, to: id)
            return true
        }
        var links = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [])
            .compactMap { FenceItem.webURL(from: $0.absoluteString, strict: true) }
        if links.isEmpty, let text = pasteboard.string(forType: .string) {
            links = text.split(whereSeparator: \.isNewline).compactMap { FenceItem.webURL(from: String($0), strict: true) }
        }
        guard !links.isEmpty else {
            Log.write("paste: nothing on the clipboard to add to \"\(fence.title)\"")
            return false
        }
        // Safari and others put the page's title next to a copied link.
        let title = links.count == 1 ? pasteboard.string(forType: NSPasteboard.PasteboardType("public.url-name")) : nil
        Log.write("paste: \(links.count) link(s) into \"\(fence.title)\"")
        for link in links { addLink(link, title: title, to: id) }
        return true
    }

    // MARK: The Add menu

    /// Asks for a web address, and optionally a title, and adds it as a link. The address
    /// starts out as the clipboard's, if it holds one.
    func promptForLink(_ id: UUID) {
        let clipboard = NSPasteboard.general.string(forType: .string).flatMap { FenceItem.webURL(from: $0, strict: true) }
        guard let fence = store.fence(id),
              let (url, title) = askForLink(message: "Add a link to \u{201C}\(fence.title)\u{201D}", address: clipboard?.absoluteString ?? "", title: "", button: "Add")
        else { return }
        addLink(url, title: title, to: id)
    }

    func editLink(_ itemID: UUID, in id: UUID) {
        guard let item = store.fence(id)?.items.first(where: { $0.id == itemID }), item.kind == .link,
              let (url, title) = askForLink(message: "Edit link", address: item.link ?? "", title: item.title ?? "", button: "Save")
        else { return }
        store.update(id) { fence in
            guard let index = fence.items.firstIndex(where: { $0.id == itemID }) else { return }
            fence.items[index].link = url.absoluteString
            fence.items[index].title = title.isEmpty ? url.host() : title
        }
        Log.write("link: edited to \(url.absoluteString)")
        // A new site gets its icon.
        Task { _ = await Favicons.shared.icon(for: url) }
    }

    /// Asks again until the address is one, or the dialog is cancelled.
    private func askForLink(message: String, address: String, title: String, button: String) -> (URL, String)? {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "Paste or type a web address. Leave the title empty to use the page\u{2019}s own."
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let addressField = NSTextField(string: address)
        addressField.placeholderString = "https://example.com"
        let titleField = NSTextField(string: title)
        titleField.placeholderString = "Title (optional)"
        let stack = NSStackView(views: [addressField, titleField])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = CGRect(x: 0, y: 0, width: 300, height: 52)
        for field in [addressField, titleField] {
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        alert.accessoryView = stack
        alert.window.initialFirstResponder = addressField
        addressField.nextKeyView = titleField
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            if let url = FenceItem.webURL(from: addressField.stringValue, strict: false) {
                return (url, titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            alert.informativeText = "\u{201C}\(addressField.stringValue)\u{201D} isn\u{2019}t a web address. Try something like apple.com or https://apple.com."
            NSSound.beep()
        }
        return nil
    }

    /// Lists the user's Shortcuts and adds the ones chosen.
    func chooseShortcuts(_ id: UUID) {
        Task { [weak self] in
            let names: [String]
            do {
                names = try await ShortcutsTool.list()
            } catch {
                Log.write("shortcut: couldn't list Shortcuts: \(error.localizedDescription)")
                self?.showShortcutsProblem("Couldn\u{2019}t list your Shortcuts", error.localizedDescription)
                return
            }
            Log.write("shortcut: \(names.count) Shortcut(s) to choose from")
            guard let self, let fence = self.store.fence(id) else { return }
            guard !names.isEmpty else {
                self.showShortcutsProblem("You don\u{2019}t have any Shortcuts yet", "Make one in the Shortcuts app, then add it here.")
                return
            }
            let model = ShortcutPickerModel(names: names)
            let alert = NSAlert()
            alert.messageText = "Add Shortcuts to \u{201C}\(fence.title)\u{201D}"
            alert.informativeText = "Double-click a Shortcut\u{2019}s tile in the fence to run it."
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            let picker = NSHostingView(rootView: ShortcutPickerView(model: model))
            picker.frame = CGRect(x: 0, y: 0, width: 320, height: 260)
            alert.accessoryView = picker
            model.onChoose = { NSApp.stopModal(withCode: .alertFirstButtonReturn) }
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.addShortcuts(names.filter(model.selection.contains), to: id)
        }
    }

    private func showShortcutsProblem(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Adds files, folders or apps chosen in an Open panel. They're added by reference, like
    /// a drop; only Desktop files get hidden while they're in the fence.
    func chooseFiles(_ id: UUID) {
        guard let fence = store.fence(id) else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose files, folders or apps to add to \u{201C}\(fence.title)\u{201D}. They stay where they are."
        panel.prompt = "Add"
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        Log.write("add: \(panel.urls.count) item(s) chosen for \"\(fence.title)\"")
        addItems(panel.urls, to: id)
    }

    // MARK: Notes

    var noteEditor: NoteEditorController? {
        notePopover?.contentViewController as? NoteEditorController
    }

    /// Opens a note in a popover pointing at its tile. The fence is raised meanwhile, like
    /// for its settings, and the popover closes on a click anywhere else.
    func editNote(_ itemID: UUID, in fenceID: UUID, isNew: Bool = false, retry: Bool = true) {
        guard fencesShowing, let fence = store.fence(fenceID),
              let item = fence.items.first(where: { $0.id == itemID }), item.kind == .note,
              let window = window(of: fenceID), let content = window.contentView else { return }
        if noteEditor?.itemID == itemID { return }
        closeNoteEditor()
        closeSettings()
        // Its tile has to be showing to point at.
        var revealed = false
        if fence.isCollapsed {
            toggleCollapse(fenceID)
            revealed = true
        }
        if let tab = item.tabID, tab != fence.currentTab.id {
            selectTab(fenceID, tab)
            revealed = true
        }
        let tile = tileViews.object(forKey: itemID as NSUUID).flatMap { $0.window === window ? $0 : nil }
        if retry, revealed || tile == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.editNote(itemID, in: fenceID, isNew: isNew, retry: false)
            }
            return
        }
        raise(fenceID)
        NSApp.activate(ignoringOtherApps: true)
        selectedItemID = itemID
        let editor = NoteEditorController(itemID: itemID, fenceID: fenceID, text: item.text ?? "", isNew: isNew) { [weak self] text in
            self?.setNoteText(itemID, in: fenceID, text)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = editor
        noteCloseObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: popover, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteEditorClosed(popover) }
        }
        notePopover = popover
        let anchor = tile ?? content
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        editor.focus()
        Log.write("note: editing \(itemID) in \"\(fence.title)\"")
    }

    /// Saves and closes the note being edited. The note is saved and forgotten here rather than
    /// when the popover's close notification arrives, which can come later or not at all.
    func closeNoteEditor() {
        guard let popover = notePopover else { return }
        popover.close()
        noteEditorClosed(popover)
    }

    private func noteEditorClosed(_ popover: NSPopover) {
        guard notePopover === popover, let editor = popover.contentViewController as? NoteEditorController else { return }
        noteCloseObserver.map(NotificationCenter.default.removeObserver)
        noteCloseObserver = nil
        notePopover = nil
        editor.save()
        if editor.isNew, editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.write("note: closed empty, so removed it")
            removeItem(editor.itemID, from: editor.fenceID, undoable: false)
        } else {
            Log.write("note: closed")
        }
    }

    // MARK: Search

    /// Shows an item in its fence: its tab comes forward and its tile is selected.
    func showInFence(_ itemID: UUID) {
        guard let fenceID = fenceID(holding: itemID), let fence = store.fence(fenceID),
              let item = fence.items.first(where: { $0.id == itemID }) else { return }
        setFencesHidden(false)
        if fence.isCollapsed { toggleCollapse(fenceID) }
        if let tab = item.tabID { selectTab(fenceID, tab) }
        raise(fenceID)
        selectedItemID = itemID
        Log.write("search: showing \"\(item.displayName)\" in \"\(fence.title)\"")
    }
}
