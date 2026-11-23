import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ResizeEdges: OptionSet, Hashable {
    let rawValue: Int
    static let left = ResizeEdges(rawValue: 1 << 0)
    static let right = ResizeEdges(rawValue: 1 << 1)
    static let top = ResizeEdges(rawValue: 1 << 2)
    static let bottom = ResizeEdges(rawValue: 1 << 3)
}

/// Owns the fence windows and hides each fence's Desktop files from Finder while they're in it.
@MainActor
final class FenceCoordinator: ObservableObject {
    let store: FenceStore
    let desktop: DesktopIconService
    var toolbarFrame: () -> CGRect? = { nil }

    private var controllers: [UUID: FenceWindowController] = [:]
    private var liveFrames: [UUID: CGRect] = [:]
    /// Fences being moved or resized. Their theme animations pause meanwhile.
    @Published private(set) var interacting: Set<UUID> = []
    /// The item tile last clicked once, shown highlighted like a selected Finder icon.
    @Published var selectedItemID: UUID?
    /// The folder tile a drag is over, highlighted like a Finder drop target.
    @Published var folderDropTargetID: UUID?
    /// Fence items just dropped on a folder tile, which `itemDragEnded` leaves alone.
    private var droppedIntoFolder: Set<UUID> = []
    private var setup: FenceSetupController?
    private var settingsPopover: NSPopover?
    private var settingsCloseObserver: NSObjectProtocol?
    /// The fence whose settings popover is open. Its hover controls stay up meanwhile.
    @Published private(set) var settingsFenceID: UUID?
    /// Fences whose custom corner picture is being made.
    @Published private(set) var cornerArtInProgress: Set<UUID> = []
    /// Why the last picture chosen for a fence couldn't be used.
    @Published private(set) var cornerArtErrors: [UUID: String] = [:]
    /// The fence brought above app windows by clicking it. It drops back to desktop level on
    /// the next click anywhere else.
    private(set) var raisedFenceID: UUID?
    private lazy var raisedOutsideClicks = OutsideClickMonitor(
        inside: { [weak self] in
            // Its menus and popovers count as inside; other fences don't.
            NSApp.windows.filter { window in
                !(window is DesktopLevelWindow) || window === self?.raisedFenceID.flatMap { self?.controllers[$0]?.window }
            }
        },
        onOutsideClick: { [weak self] in self?.lowerRaisedFence() }
    )

    /// True while Show/Hide Fences has every fence hidden and the Desktop showing its files
    /// as usual. Kept across launches.
    @Published private(set) var fencesHidden = UserDefaults.standard.bool(forKey: FenceCoordinator.fencesHiddenKey)
    private static let fencesHiddenKey = "CBFencesHidden"
    /// False after `restoreAllToDesktop` until `hideAllFencedFiles`. Items added meanwhile
    /// stay visible on the Desktop.
    private(set) var hidesFencedFiles = true
    /// Fenced Desktop files unhidden for Show in Finder, hidden again by `rehideRevealed`.
    private var revealed: Set<String> = []
    private var revealedAt = Date.distantPast
    private var rehideTimer: Timer?
    private static let migratedKey = "CBMigratedToHiddenFlag"
    /// Each item's tile, for popovers that point at it.
    let tileViews = NSMapTable<NSUUID, NSView>.strongToWeakObjects()
    var notePopover: NSPopover?
    var noteCloseObserver: NSObjectProtocol?

    init(store: FenceStore, desktop: DesktopIconService) {
        self.store = store
        self.desktop = desktop
    }

    /// A collapsed fence is just its title bar.
    func collapsedHeight(_ fence: Fence) -> CGFloat { FenceMetrics(fence).titleHeight }

    func minimumSize(for fence: Fence) -> CGSize {
        let metrics = FenceMetrics(fence)
        return CGSize(width: 180, height: metrics.titleHeight + metrics.tabStripHeight(fence) + metrics.minimumGridHeight)
    }

    /// The most tab rows a fence this tall can show: the strip takes at most half the space
    /// under the title, and the grid keeps its minimum.
    func maxTabRows(_ fence: Fence, forHeight height: CGFloat) -> Int {
        let metrics = FenceMetrics(fence)
        var rows = 1
        while rows < FenceMetrics.maxTabRows {
            let strip = metrics.tabStripHeight(rows: rows + 1, collapsed: false)
            guard metrics.titleHeight + strip + metrics.minimumGridHeight <= height,
                  strip <= (height - metrics.titleHeight) / 2 else { break }
            rows += 1
        }
        return rows
    }

    /// Where each fence's tabs and visible tiles are, in window content coordinates (top-left
    /// origin), so drops can be matched to a tab or a position in the grid.
    var tabFrames: [UUID: [UUID: CGRect]] = [:]
    /// The visible part of each fence's tab strip. Tabs scrolled out of it don't take drops.
    var tabStripFrames: [UUID: CGRect] = [:]
    var tileFrames: [UUID: [UUID: CGRect]] = [:]

    func start() {
        for fence in store.fences {
            let minimum = minimumSize(for: fence)
            guard fence.frame.width < minimum.width || fence.frame.height < minimum.height else { continue }
            store.update(fence.id) { fence in
                let top = fence.frame.maxY
                fence.frame.size.width = max(fence.frame.width, minimum.width)
                fence.frame.size.height = max(fence.frame.height, minimum.height)
                fence.frame.origin.y = top - fence.frame.height
            }
        }
        reconcileHiddenFiles()
        for fence in store.fences { openWindow(for: fence) }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.selectedItemID = nil
                self?.lowerRaisedFence()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Revealing can briefly bounce focus back here before Finder takes it.
                guard let self, Date().timeIntervalSince(self.revealedAt) > 2 else { return }
                self.rehideRevealed(because: "Clutter Buster became active")
            }
        }
    }

    // MARK: Fences

    @discardableResult
    func createFence(title: String = "New Fence") -> UUID {
        setFencesHidden(false)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let size = CGSize(width: 420, height: 300)
        let offset = CGFloat(store.fences.count % 8) * 28
        let origin = CGPoint(x: screen.midX - size.width / 2 + offset, y: screen.midY - size.height / 2 - offset)
        let fence = Fence(
            title: title,
            frame: CGRect(origin: origin, size: size),
            color: AppSettings.defaultColor,
            iconsPerRow: AppSettings.defaultIconsPerRow,
            opacity: AppSettings.defaultOpacity
        )
        store.add(fence)
        openWindow(for: fence)
        return fence.id
    }

    /// Creates a fence that floats above app windows with its setup card until the user is done.
    @discardableResult
    func createFenceWithSetup() -> UUID {
        setup?.finish()
        lowerRaisedFence()
        let id = createFence()
        guard let window = controllers[id]?.window else { return id }
        let controller = FenceSetupController(fenceID: id, fenceWindow: window, coordinator: self)
        controller.onFinish = { [weak self, weak controller] in
            if self?.setup === controller { self?.setup = nil }
        }
        setup = controller
        controller.begin()
        return id
    }

    func confirmDelete(_ id: UUID) {
        // Let the menu that triggered this finish closing before the alert takes over.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let fence = self.store.fence(id) else { return }
                let alert = NSAlert()
                alert.messageText = "Delete \"\(fence.title)\"?"
                alert.informativeText = "Its icons will go back to the desktop. Your files aren't affected."
                let delete = alert.addButton(withTitle: "Delete")
                delete.hasDestructiveAction = true
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    self.deleteFence(id)
                }
            }
        }
    }

    func deleteFence(_ id: UUID) {
        guard let fence = store.fence(id) else { return }
        Log.write("deleted fence \"\(fence.title)\" (\(id)) with \(fence.items.count) item(s)")
        if setup?.fenceID == id { setup?.finish() }
        if raisedFenceID == id { lowerRaisedFence() }
        if settingsFenceID == id { closeSettings() }
        if noteEditor?.fenceID == id { closeNoteEditor() }
        unhide(fence.items)
        controllers.removeValue(forKey: id)?.close()
        tabFrames[id] = nil
        tabStripFrames[id] = nil
        tileFrames[id] = nil
        store.remove(id)
        CustomCornerArt.delete(for: id)
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.update(id) { $0.title = trimmed }
    }

    func setColor(_ id: UUID, _ color: FenceColor) {
        store.update(id) { $0.color = color }
    }

    func setOpacity(_ id: UUID, _ opacity: Double) {
        store.update(id) { $0.opacity = min(max(opacity, 0), 1) }
    }

    /// Nil makes the fence follow the global theme.
    func setTheme(_ id: UUID, _ theme: FenceTheme?) {
        store.update(id) { $0.theme = theme }
    }

    // MARK: Corner pictures

    func setCornerArt(_ id: UUID, _ choice: CornerArtChoice) {
        guard let fence = store.fence(id), (fence.cornerArt ?? .theme) != choice else { return }
        store.update(id) { $0.cornerArt = choice == .theme ? nil : choice }
        Log.write("corner picture of \"\(fence.title)\" set to \(choice)")
    }

    /// Shows the fence's own picture again, or asks for one if it doesn't have one yet.
    func useCustomCornerArt(_ id: UUID) {
        if CustomCornerArt.exists(for: id) {
            setCornerArt(id, .custom(CustomCornerArt.fileName(for: id)))
        } else {
            chooseCornerArt(id)
        }
    }

    func chooseCornerArt(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture for the corner of the fence. Its background is removed automatically."
        panel.prompt = "Use Picture"
        // Above the fence, which floats while its settings are open.
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        makeCornerArt(id, from: url)
    }

    /// Cuts the subject of the picture at `url` out of its background in the background, then
    /// shows it in the fence's corner.
    func makeCornerArt(_ id: UUID, from url: URL) {
        guard store.fence(id) != nil, !cornerArtInProgress.contains(id) else { return }
        cornerArtInProgress.insert(id)
        cornerArtErrors[id] = nil
        Log.write("corner picture: making one for fence \(id) from \"\(url.lastPathComponent)\"")
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try CustomCornerArt.make(from: url, for: id) }
            await self?.cornerArtMade(id, result)
        }
    }

    private func cornerArtMade(_ id: UUID, _ result: Result<CustomCornerArt.Made, Error>) {
        cornerArtInProgress.remove(id)
        switch result {
        case .success(let made):
            Log.write("  \(made.cutOut ? "cut out the subject" : "no subject found, so framed the whole photo"); saved \(made.fileName)")
            guard store.fence(id) != nil else {
                // Deleted while the picture was being made.
                CustomCornerArt.delete(for: id)
                return
            }
            // The same file name may already be set; this redraws the fence with the new picture.
            store.update(id) { $0.cornerArt = .custom(made.fileName) }
        case .failure(let error):
            Log.write("  failed: \(error.localizedDescription)")
            cornerArtErrors[id] = error.localizedDescription
        }
    }

    /// Sets how many rows of tabs show, within what the fence's height allows, or tucks the
    /// strip away. Collapsing keeps the row count for when it's expanded again.
    func setTabStrip(_ id: UUID, rows: Int, collapsed: Bool) {
        guard let fence = store.fence(id) else { return }
        let rows = min(max(rows, 1), maxTabRows(fence, forHeight: expandedFrame(id).height))
        guard fence.tabRows != rows || fence.tabsCollapsed != collapsed else { return }
        if collapsed { tabFrames[id] = [:] }
        store.update(id) { fence in
            fence.tabRows = rows
            fence.tabsCollapsed = collapsed
        }
    }

    func setIconsPerRow(_ id: UUID, _ count: Int) {
        store.update(id) { $0.iconsPerRow = count }
    }

    /// Sets the size of all of a fence's text, in steps of 10% within `Fence.textScaleRange`.
    func setTextScale(_ id: UUID, _ scale: Double) {
        guard let fence = store.fence(id) else { return }
        let scale = Fence.clampedTextScale(scale)
        guard scale != fence.textScale else { return }
        store.update(id) { $0.textScale = scale }
        Log.write("text size of \"\(fence.title)\" set to \(Int((scale * 100).rounded()))%")
        fitToContent(id)
    }

    func setTitleStyle(_ id: UUID, _ style: TitleStyle) {
        guard let fence = store.fence(id), fence.titleStyle != style else { return }
        store.update(id) { $0.titleStyle = style }
        Log.write("title style of \"\(fence.title)\" set to \(style.isDefault ? "the theme's" : "\(style)")")
        fitToContent(id)
    }

    func adjustTextScale(_ id: UUID, by steps: Int) {
        guard let fence = store.fence(id) else { return }
        setTextScale(id, fence.textScale + Double(steps) * Fence.textScaleStep)
    }

    /// After the title or tabs grow: makes the fence at least its minimum size, keeping its
    /// top edge, and drops tab rows it no longer has room for.
    private func fitToContent(_ id: UUID) {
        guard let fence = store.fence(id) else { return }
        let minimum = minimumSize(for: fence)
        if fence.frame.height < minimum.height {
            Log.write("  grew \"\(fence.title)\" from \(Int(fence.frame.height))pt to \(Int(minimum.height))pt tall to fit its text")
            store.update(id) { fence in
                let top = fence.frame.maxY
                fence.frame.size.height = minimum.height
                fence.frame.origin.y = top - minimum.height
            }
        }
        if let fence = store.fence(id) {
            let rows = maxTabRows(fence, forHeight: fence.frame.height)
            if fence.tabRows > rows { store.update(id) { $0.tabRows = rows } }
        }
        applyFrame(id)
    }

    func toggleCollapse(_ id: UUID) {
        store.update(id) { $0.isCollapsed.toggle() }
        applyFrame(id)
    }

    func setAllCollapsed(_ collapsed: Bool) {
        for fence in store.fences where fence.isCollapsed != collapsed {
            toggleCollapse(fence.id)
        }
    }

    /// Hides every fence and puts their Desktop files back in their spots, so the Desktop looks
    /// as it would without Clutter Buster; or hides the files again and shows the fences.
    func setFencesHidden(_ hidden: Bool) {
        guard hidden != fencesHidden else { return }
        fencesHidden = hidden
        UserDefaults.standard.set(hidden, forKey: Self.fencesHiddenKey)
        if hidden {
            setup?.finish()
            lowerRaisedFence()
            closeSettings()
            selectedItemID = nil
            restoreAllToDesktop()
            for controller in controllers.values { controller.window.orderOut(nil) }
            Log.write("fences hidden; their Desktop files are back in their spots")
        } else {
            // Icons moved while the fences were away go back to where they were moved.
            hideAllFencedFiles(recordPositions: true)
            for fence in store.fences {
                applyFrame(fence.id)
                controllers[fence.id]?.window.orderFrontRegardless()
            }
            Log.write("fences shown")
        }
    }

    /// Brings a clicked fence above app windows until the next click elsewhere. A fence in
    /// its setup card already floats, and the card settles it.
    func raise(_ id: UUID) {
        // A click already on its way when the fences were hidden would bring one back.
        guard !fencesHidden, setup?.fenceID != id, let window = controllers[id]?.window else { return }
        if raisedFenceID != id {
            lowerRaisedFence()
            raisedFenceID = id
            window.level = .floating
            Log.write("raised fence \(id)")
        }
        window.orderFrontRegardless()
        raisedOutsideClicks.start()
    }

    func lowerRaisedFence() {
        guard let id = raisedFenceID else { return }
        raisedFenceID = nil
        raisedOutsideClicks.stop()
        if settingsFenceID == id { closeSettings() }
        if noteEditor?.fenceID == id { closeNoteEditor() }
        guard setup?.fenceID != id else { return }
        controllers[id]?.window.level = DesktopLevelWindow.desktopLevel
        Log.write("lowered fence \(id)")
    }

    /// Shows all of a fence's settings, or just its title style, in a popover pointing at
    /// `anchor` from its `edge`
    /// (`.minY` is below). Without room there it sits beside the fence instead, so the fence
    /// stays in view while it changes. The fence is raised meanwhile; the popover's window
    /// isn't a desktop-level window, so clicks in it count as inside the raised fence. It
    /// closes on a click in the fence or anywhere outside it.
    func showSettings(_ id: UUID, page: FenceSettingsPage = .all, from anchor: NSView?, edge: NSRectEdge = .minY) {
        // Let a menu that triggered this finish closing first.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.fencesHidden, self.store.fence(id) != nil, let window = self.controllers[id]?.window,
                      let content = window.contentView else { return }
                self.closeSettings()
                self.raise(id)
                NSApp.activate(ignoringOtherApps: true)
                let root = FenceSettingsPopover(fenceID: id, page: page)
                    .environmentObject(self.store)
                    .environmentObject(self)
                let hosting = NSHostingController(rootView: root)
                hosting.sizingOptions = [.preferredContentSize]
                let (view, edge) = Self.settingsPlacement(
                    size: hosting.view.fittingSize, window: window, content: content,
                    anchor: anchor?.window === window ? anchor : nil, edge: edge
                )
                let popover = NSPopover()
                popover.behavior = .semitransient
                popover.appearance = NSAppearance(named: .darkAqua)
                popover.contentViewController = hosting
                self.settingsCloseObserver = NotificationCenter.default.addObserver(
                    forName: NSPopover.didCloseNotification, object: popover, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.settingsClosed(popover) }
                }
                self.settingsPopover = popover
                self.settingsFenceID = id
                popover.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
                // Otherwise the name field takes focus with its text selected, and a stray key
                // renames the fence.
                hosting.view.window?.makeFirstResponder(nil)
                Log.write("settings: opened \(page) for fence \(id)")
            }
        }
    }

    /// Where the settings popover goes: off `anchor`'s `edge` if it fits on screen there,
    /// else right or left of the fence, else off the opposite edge.
    private static func settingsPlacement(
        size: CGSize, window: NSWindow, content: NSView, anchor: NSView?, edge: NSRectEdge
    ) -> (NSView, NSRectEdge) {
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let fence = window.frame
        let anchorView = anchor ?? content
        let anchorRect = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
        let margin: CGFloat = 16
        func fits(_ edge: NSRectEdge, _ rect: CGRect) -> Bool {
            switch edge {
            case .minY: rect.minY - screen.minY >= size.height + margin
            case .maxY: screen.maxY - rect.maxY >= size.height + margin
            case .maxX: screen.maxX - rect.maxX >= size.width + margin
            default: rect.minX - screen.minX >= size.width + margin
            }
        }
        if fits(edge, anchorRect) { return (anchorView, edge) }
        if fits(.maxX, fence) { return (content, .maxX) }
        if fits(.minX, fence) { return (content, .minX) }
        return (anchorView, edge == .minY ? .maxY : .minY)
    }

    func closeSettings() {
        settingsPopover?.close()
    }

    private func settingsClosed(_ popover: NSPopover) {
        guard settingsPopover === popover else { return }
        settingsCloseObserver.map(NotificationCenter.default.removeObserver)
        settingsCloseObserver = nil
        settingsPopover = nil
        settingsFenceID = nil
        // A title color picker left open has nothing to change once the popover is gone.
        if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible { NSColorPanel.shared.orderOut(nil) }
        Log.write("settings: closed")
    }

    /// Makes a fence's window key so its title can be edited.
    func focus(_ id: UUID) {
        NSApp.activate(ignoringOtherApps: true)
        controllers[id]?.window.makeKey()
    }

    // MARK: Items

    /// Adds items to a tab of a fence (its selected tab by default, or when `tab` is gone),
    /// taking them out of any other fence, and hides the Desktop ones from Finder.
    func addItems(_ urls: [URL], to id: UUID, tab: UUID? = nil) {
        guard let fence = store.fence(id) else { return }
        let tabID = tab.flatMap { tab in fence.tabs.contains { $0.id == tab } ? tab : nil } ?? fence.currentTab.id
        let positions = desktop.positionsNow() ?? [:]
        var added: [FenceItem] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            var originalFromOtherFence: CGPoint?
            for other in store.fences where other.id != id {
                guard let item = other.items.first(where: { $0.path == path }) else { continue }
                originalFromOtherFence = item.originalDesktopPosition
                store.update(other.id) { $0.items.removeAll { $0.path == path } }
            }
            guard store.fence(id)?.items.contains(where: { $0.path == path }) == false else { continue }
            let original = DesktopIconService.isOnDesktop(url)
                ? (originalFromOtherFence ?? positions[url.lastPathComponent])
                : nil
            let item = FenceItem(path: path, originalDesktopPosition: original, tabID: tabID)
            store.update(id) { $0.items.append(item) }
            added.append(item)
        }
        hide(added)
    }

    // MARK: Tabs

    func selectTab(_ id: UUID, _ tabID: UUID) {
        store.update(id) { $0.selectedTabID = tabID }
    }

    /// Adds a tab after the last one, selects it and returns its ID.
    @discardableResult
    func addTab(_ id: UUID) -> UUID? {
        guard let fence = store.fence(id) else { return nil }
        let names = Set(fence.tabs.map(\.name))
        var number = fence.tabs.count + 1
        while names.contains("Tab \(number)") { number += 1 }
        let tab = FenceTab(name: "Tab \(number)")
        store.update(id) { fence in
            fence.tabs.append(tab)
            fence.selectedTabID = tab.id
        }
        return tab.id
    }

    func renameTab(_ id: UUID, _ tabID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.update(id) { fence in
            guard let index = fence.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            fence.tabs[index].name = trimmed
        }
    }

    /// Removes a tab and moves its items into the first remaining tab. The last tab stays.
    func deleteTab(_ id: UUID, _ tabID: UUID) {
        store.update(id) { fence in
            guard fence.tabs.count > 1 else { return }
            fence.tabs.removeAll { $0.id == tabID }
            let destination = fence.tabs[0].id
            for index in fence.items.indices where fence.items[index].tabID == tabID {
                fence.items[index].tabID = destination
            }
            if fence.selectedTabID == tabID { fence.selectedTabID = destination }
        }
    }

    func setSort(_ id: UUID, _ tabID: UUID, _ sort: TabSort) {
        FileInfoCache.shared.invalidate()
        store.update(id) { fence in
            guard let index = fence.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            fence.tabs[index].sort = sort
        }
    }

    /// Items of a tab in the order they're shown.
    func displayedItems(_ fence: Fence, tab: FenceTab) -> [FenceItem] {
        tab.sort.apply(to: fence.items(in: tab.id))
    }

    func moveItem(_ itemID: UUID, in id: UUID, toTab tabID: UUID) {
        store.update(id) { fence in
            guard let index = fence.items.firstIndex(where: { $0.id == itemID }) else { return }
            var item = fence.items.remove(at: index)
            item.tabID = tabID
            fence.items.append(item)
        }
    }

    /// Moves an item next to another in its tab's displayed order and switches the tab to
    /// manual sorting so the order sticks.
    func reorder(_ itemID: UUID, in id: UUID, nextTo targetID: UUID, after: Bool) {
        guard itemID != targetID, let fence = store.fence(id),
              let item = fence.items.first(where: { $0.id == itemID }),
              let tab = fence.tabs.first(where: { $0.id == item.tabID }) else { return }
        var order = displayedItems(fence, tab: tab)
        order.removeAll { $0.id == itemID }
        guard let targetIndex = order.firstIndex(where: { $0.id == targetID }) else { return }
        order.insert(item, at: after ? targetIndex + 1 : targetIndex)
        store.update(id) { fence in
            var remaining = order.makeIterator()
            fence.items = fence.items.map { $0.tabID == tab.id ? (remaining.next() ?? $0) : $0 }
            if let index = fence.tabs.firstIndex(where: { $0.id == tab.id }) {
                fence.tabs[index].sort = TabSort()
            }
        }
    }

    func removeItem(_ itemID: UUID, from id: UUID) {
        guard let fence = store.fence(id), let item = fence.items.first(where: { $0.id == itemID }) else { return }
        if noteEditor?.itemID == itemID { closeNoteEditor() }
        store.update(id) { $0.items.removeAll { $0.id == itemID } }
        Log.write("removed \"\(item.finderName)\" from \"\(fence.title)\"")
        unhide([item])
    }

    /// Called when an item tile is dropped at `point` (Cocoa screen coordinates). Over another
    /// fence it moves there; over open desktop it leaves the fence and its icon lands under
    /// the mouse. Anywhere else (its own fence, the toolbar, an app window) nothing changes.
    func itemDragEnded(_ itemID: UUID, from sourceID: UUID, at point: CGPoint, operation: NSDragOperation) {
        if droppedIntoFolder.remove(itemID) != nil {
            Log.write("drag end: item \(itemID) was dropped on a folder tile")
            return
        }
        guard let source = store.fence(sourceID),
              let item = source.items.first(where: { $0.id == itemID }) else {
            Log.write("drag end: item \(itemID) no longer in fence \(sourceID)")
            return
        }
        let name = item.finderName
        Log.write("drag end: \"\(name)\" from \"\(source.title)\" at \(point) operation=\(operation.rawValue)")

        if displayFrame(for: source).contains(point) {
            if let tab = tab(at: point, in: source) {
                if tab.id != item.tabID {
                    Log.write("  decision: move to tab \"\(tab.name)\"")
                    moveItem(itemID, in: sourceID, toTab: tab.id)
                } else {
                    Log.write("  decision: dropped on its own tab, no change")
                }
            } else if let (targetID, after) = tile(at: point, in: source), targetID != itemID {
                Log.write("  decision: reorder \(after ? "after" : "before") another item")
                reorder(itemID, in: sourceID, nextTo: targetID, after: after)
            } else {
                Log.write("  decision: dropped on its own fence, no change")
            }
            return
        }

        if let target = store.fences.first(where: { $0.id != sourceID && displayFrame(for: $0).contains(point) }) {
            let tab = tab(at: point, in: target)
            Log.write("  decision: move to fence \"\(target.title)\"\(tab.map { ", tab \"\($0.name)\"" } ?? "")")
            if item.isFile {
                addItems([item.url], to: target.id, tab: tab?.id)
            } else {
                moveNonFileItem(item, from: sourceID, to: target.id, tab: tab?.id)
            }
            return
        }

        if toolbarFrame()?.contains(point) == true {
            Log.write("  decision: dropped on toolbar, no change")
            return
        }
        if let blocker = desktopBlocker(at: point) {
            Log.write("  decision: covered by \(blocker), no change")
            return
        }
        // A link, note or Shortcut has nowhere to go on the Desktop, and a note dragged off
        // by accident would lose its text. Remove from Fence takes them out.
        guard item.isFile else {
            Log.write("  decision: a \(item.kind.rawValue) has no Desktop icon, so it stays in its fence")
            return
        }

        store.update(sourceID) { $0.items.removeAll { $0.id == itemID } }
        guard item.isOnDesktop else {
            Log.write("  decision: removed from fence (not a Desktop file, nothing placed)")
            return
        }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let dropped = CGPoint(x: point.x.rounded(), y: (mainHeight - point.y).rounded())
        let target = openDesktopSpot(near: dropped, for: name)
        Log.write("  decision: back to desktop, Finder position \(target)\(target == dropped ? "" : " (nudged from \(dropped) to avoid other icons)")")
        unhide([item], at: [name: target])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.desktop.positions { positions in
                    Log.write("  result: Finder reports \"\(name)\" at \(positions?[name].map { "\($0)" } ?? "unknown")")
                }
            }
        }
    }

    // MARK: Dropping into folders

    /// The fenced item with this ID, in whichever fence holds it.
    func fencedItem(_ itemID: UUID) -> FenceItem? {
        store.fences.lazy.compactMap { $0.items.first { $0.id == itemID } }.first
    }

    func fenceID(holding itemID: UUID) -> UUID? {
        store.fences.first { $0.items.contains { $0.id == itemID } }?.id
    }

    private struct FolderDropJob {
        let source: URL
        /// Fence items for the source path, from any fence.
        let fenced: [FenceItem]
        /// Clutter Buster hid the source, so a copy inherits a flag that isn't its own.
        let wasHidden: Bool
    }

    /// Moves files dropped on a folder tile into its folder, or with `copy` copies them, as
    /// Finder does. A moved file leaves every fence it was in; a fenced Desktop file is
    /// unhidden first, which also takes it out of the ledger. A copy of a fenced file shows
    /// on its own and the original stays put. Problems are shown together in one alert.
    func dropIntoFolder(_ urls: [URL], folder: URL, copy: Bool, draggedItemID: UUID? = nil) {
        if let draggedItemID { droppedIntoFolder.insert(draggedItemID) }
        let folder = folder.standardizedFileURL
        Log.write("folder drop: \(copy ? "copy" : "move") \(urls.count) item(s) into \"\(folder.path)\"")
        var failures: [String] = []
        var jobs: [FolderDropJob] = []
        for url in urls.map(\.standardizedFileURL) {
            if let problem = FolderDrop.problem(putting: url, into: folder) {
                Log.write("  refused: \(problem)")
                failures.append(problem)
                continue
            }
            if !copy, url.deletingLastPathComponent().path == folder.path {
                Log.write("  \"\(url.lastPathComponent)\" is already in that folder, no change")
                continue
            }
            let fenced = store.fences.flatMap(\.items).filter { $0.path == url.path }
            let job = FolderDropJob(source: url, fenced: fenced, wasHidden: desktop.hiddenFiles.paths.contains(url.path))
            // Otherwise the file would stay hidden in its new folder. Its icon is leaving the
            // Desktop, so it isn't put back in its spot first.
            if !copy { unhide(fenced, placing: false) }
            jobs.append(job)
        }
        guard !jobs.isEmpty else {
            showFolderDropFailures(failures, folder: folder, copy: copy)
            return
        }
        // Copying a big folder takes a while; the fences stay responsive meanwhile.
        Task.detached(priority: .userInitiated) { [weak self] in
            let results = jobs.map { job in
                Result {
                    let destination = try FolderDrop.transfer(job.source, into: folder, copy: copy)
                    if copy, job.wasHidden { HiddenFiles.showCopy(destination) }
                    return destination
                }
            }
            await self?.folderDropFinished(jobs, results, folder: folder, copy: copy, failures: failures)
        }
    }

    private func folderDropFinished(_ jobs: [FolderDropJob], _ results: [Result<URL, Error>], folder: URL, copy: Bool, failures: [String]) {
        var failures = failures
        var placed: [String] = []
        for (job, result) in zip(jobs, results) {
            switch result {
            case .success(let destination):
                Log.write("  \(copy ? "copied" : "moved") \"\(job.source.path)\" to \"\(destination.path)\"")
                placed.append(destination.standardizedFileURL.path)
                if !copy { forgetMovedPath(job.source.path, now: destination.path) }
            case .failure(let error):
                Log.write("  couldn't \(copy ? "copy" : "move") \"\(job.source.lastPathComponent)\": \(error.localizedDescription)")
                failures.append(error.localizedDescription)
                // It's still where it was and still fenced.
                if !copy { hide(job.fenced) }
            }
        }
        if !placed.isEmpty {
            NotificationCenter.default.post(name: .clutterBusterDidPlaceFiles, object: self, userInfo: [HiddenFiles.pathsKey: placed])
        }
        showFolderDropFailures(failures, folder: folder, copy: copy)
    }

    /// After a move: the old path leaves every fence, and fenced files inside a moved folder
    /// follow it to its new place.
    private func forgetMovedPath(_ old: String, now new: String) {
        for fence in store.fences {
            let leaving = fence.items.filter { $0.path == old }
            let inside = fence.items.contains { $0.path.hasPrefix(old + "/") }
            guard !leaving.isEmpty || inside else { continue }
            if !leaving.isEmpty { Log.write("  removed \"\((old as NSString).lastPathComponent)\" from \"\(fence.title)\"") }
            if leaving.contains(where: { $0.id == selectedItemID }) { selectedItemID = nil }
            store.update(fence.id) { fence in
                fence.items.removeAll { $0.path == old }
                for index in fence.items.indices where fence.items[index].path.hasPrefix(old + "/") {
                    fence.items[index].path = new + fence.items[index].path.dropFirst(old.count)
                }
            }
        }
    }

    private func showFolderDropFailures(_ failures: [String], folder: URL, copy: Bool) {
        guard !failures.isEmpty else { return }
        let folderName = FileManager.default.displayName(atPath: folder.path)
        let what = failures.count == 1 ? "an item" : "\(failures.count) items"
        // Not inside the drop, which would keep the drag image on screen behind the alert.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't \(copy ? "copy" : "move") \(what) into \u{201C}\(folderName)\u{201D}"
            alert.informativeText = failures.joined(separator: "\n\n")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// Opens a folder tile's folder in Finder when a drag rests on it, so the drag can go on
    /// into a subfolder. The fence stays where it is, back under app windows.
    func springOpen(_ item: FenceItem) {
        Log.write("spring-loading: opening \"\(item.finderName)\" in Finder")
        lowerRaisedFence()
        NSWorkspace.shared.open(item.url)
    }

    /// Opens a file or app, opens a link in the default browser, edits a note or runs a
    /// Shortcut. `fenceID` is the fence showing the item, which a note's editor points into.
    func open(_ item: FenceItem, in fenceID: UUID? = nil) {
        switch item.kind {
        case .file:
            // The opened app comes forward; the fence goes back under it.
            lowerRaisedFence()
            NSWorkspace.shared.open(item.url)
        case .link:
            guard let url = item.webURL else {
                Log.write("link: \"\(item.link ?? "")\" isn't a web address it can open")
                NSSound.beep()
                return
            }
            lowerRaisedFence()
            Log.write("link: opening \(url.absoluteString)")
            NSWorkspace.shared.open(url)
        case .note:
            guard let holder = fenceID ?? self.fenceID(holding: item.id) else { return }
            editNote(item.id, in: holder)
        case .shortcut:
            guard let name = item.title else { return }
            lowerRaisedFence()
            ShortcutsTool.run(name)
        }
    }

    func revealInFinder(_ item: FenceItem) {
        guard item.isFile else { return }
        lowerRaisedFence()
        revealInFinder(item.url)
    }

    /// Selects a file in Finder. A fenced Desktop file is unhidden first so Finder can show
    /// it, and hidden again when Clutter Buster next becomes active, or after a minute.
    func revealInFinder(_ url: URL) {
        let url = url.standardizedFileURL
        guard desktop.hiddenFiles.paths.contains(url.path), !desktop.hiddenFiles.unhide([url]).isEmpty else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        Log.write("show in Finder: unhid \"\(url.lastPathComponent)\" until Clutter Buster is active again")
        revealed.insert(url.path)
        revealedAt = Date()
        rehideTimer?.invalidate()
        rehideTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rehideRevealed(because: "a minute passed") }
        }
        // A Finder window opened in the same instant can miss the file it was asked to select.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: Hiding Desktop files

    /// Hides the Desktop files of fenced items from Finder, unless everything is restored to
    /// the Desktop right now. Record each item's position before calling this.
    func hide(_ items: [FenceItem]) {
        guard hidesFencedFiles else { return }
        let hidden = desktop.hiddenFiles.hide(items.filter(\.isOnDesktop).map(\.url))
        guard !hidden.isEmpty else { return }
        Log.write("hid \(hidden.count) Desktop file(s): \(hidden.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
    }

    /// Puts the Desktop icons of items leaving a fence at `positions` (keyed by Finder name),
    /// or back at their original positions, then unhides them. Finder moves hidden icons, so
    /// each one shows up in its spot. With `placing` false the icons stay where they are, for
    /// files about to leave the Desktop. Posts `clutterBusterDidUnhideFiles`.
    func unhide(_ items: [FenceItem], at positions: [String: CGPoint] = [:], placing: Bool = true) {
        let items = items.filter(\.isOnDesktop)
        guard !items.isEmpty else { return }
        var moves: [String: CGPoint] = [:]
        for item in items where placing {
            let wasHidden = desktop.hiddenFiles.paths.contains(item.path) || revealed.contains(item.path)
            if let target = positions[item.finderName] ?? (wasHidden ? item.originalDesktopPosition : nil) {
                moves[item.finderName] = target
            }
        }
        desktop.moveNow(moves)
        revealed.subtract(items.map(\.path))
        let unhidden = desktop.hiddenFiles.unhide(items.map(\.url))
        guard !unhidden.isEmpty else { return }
        Log.write("unhid \(unhidden.count) Desktop file(s): \(unhidden.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
    }

    /// Puts every fenced Desktop file back on the Desktop at its original position and
    /// unhides it. Fences keep their items. Used when quitting, and to show the plain Desktop
    /// until `hideAllFencedFiles`.
    func restoreAllToDesktop() {
        rehideTimer?.invalidate()
        unhide(store.fences.flatMap(\.items))
        hidesFencedFiles = false
    }

    /// Hides every fenced Desktop file again after `restoreAllToDesktop`. With
    /// `recordPositions`, first remembers where each visible icon sits now, so that's where it
    /// goes back to.
    func hideAllFencedFiles(recordPositions: Bool) {
        hidesFencedFiles = true
        if recordPositions, let positions = desktop.positionsNow() {
            for fence in store.fences {
                store.update(fence.id) { fence in
                    for index in fence.items.indices where fence.items[index].isOnDesktop {
                        guard let position = positions[fence.items[index].finderName] else { continue }
                        fence.items[index].originalDesktopPosition = position
                    }
                }
            }
        }
        hide(store.fences.flatMap(\.items))
    }

    /// Runs at launch before any fence shows. Fenced Desktop files get hidden, which also
    /// moves layouts from versions that piled icons under each fence onto the hidden flag
    /// (their original positions are kept). Files Clutter Buster hid that are no longer in a
    /// fence, say after a crash, are unhidden where they are. With the fences hidden, fenced
    /// files stay visible, and any left hidden go back to their spots.
    private func reconcileHiddenFiles() {
        let fenced = store.fences.flatMap(\.items).filter(\.isOnDesktop)
        let orphans = desktop.hiddenFiles.paths.subtracting(fenced.map(\.path))
        if !orphans.isEmpty {
            let unhidden = desktop.hiddenFiles.unhide(orphans.map { URL(fileURLWithPath: $0) })
            Log.write("launch: unhid \(unhidden.count) file(s) no longer in a fence: \(unhidden.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
        }
        if !UserDefaults.standard.bool(forKey: Self.migratedKey) {
            Log.write("launch: moving \(fenced.count) fenced Desktop file(s) from icon stacks to the hidden flag")
            UserDefaults.standard.set(true, forKey: Self.migratedKey)
        }
        if fencesHidden {
            restoreAllToDesktop()
            Log.write("launch: fences are hidden, so their \(fenced.count) Desktop file(s) stay visible")
            return
        }
        hide(fenced)
        Log.write("launch: \(fenced.count) fenced Desktop file(s), \(desktop.hiddenFiles.paths.count) hidden by Clutter Buster")
    }

    /// Hides files unhidden for Show in Finder again, if they're still fenced.
    private func rehideRevealed(because reason: String) {
        rehideTimer?.invalidate()
        rehideTimer = nil
        guard !revealed.isEmpty else { return }
        Log.write("show in Finder: hiding revealed file(s) again, \(reason)")
        let items = store.fences.flatMap(\.items).filter { revealed.contains($0.path) }
        revealed = []
        hide(items)
    }

    // MARK: Moving and resizing

    func expandedFrame(_ id: UUID) -> CGRect {
        liveFrames[id] ?? store.fence(id)?.frame ?? .zero
    }

    func beginInteraction(_ id: UUID) {
        interacting.insert(id)
    }

    /// Shows `frame` while the fence is moved or resized. With `snapping`, and snapping on
    /// (holding Option does the opposite for as long as it's held), an outline shows where
    /// the fence snaps to; the fence itself follows the pointer until it's let go.
    func updateLiveFrame(_ id: UUID, _ frame: CGRect, snapping mode: SnapEngine.Mode? = nil) {
        liveFrames[id] = frame
        applyFrame(id)
        if let mode { previewSnap(id, frame, mode: mode) }
    }

    /// Keeps the fence where it was let go, or settles it into the snap outline.
    func endInteraction(_ id: UUID) {
        let snapped = snapPreview?.id == id ? snapPreview?.frame : nil
        if let frame = liveFrames.removeValue(forKey: id) {
            store.update(id) { $0.frame = snapped ?? frame }
        }
        interacting.remove(id)
        clampToScreens(id)
        applyFrame(id, animated: snapped != nil)
        endSnapping(id)
    }

    // MARK: Snapping

    private let snapThreshold: CGFloat = 10
    private lazy var snapOutline = SnapPreviewWindow()
    /// Timers gliding released fences into their snapped frames.
    private var settles: [UUID: Timer] = [:]
    /// Where the fence being dragged would snap to (its expanded frame), what it lines up
    /// with there, and the fences those guides refer to. Nil while nothing is in reach.
    private var snapPreview: (id: UUID, frame: CGRect, guides: [SnapEngine.Guide], others: [UUID])?
    /// Whether Option was held at the last update of the drag, so flipping it is logged once.
    private var snapOptionHeld: (id: UUID, held: Bool)?

    private func previewSnap(_ id: UUID, _ frame: CGRect, mode: SnapEngine.Mode) {
        let settings = SnapSettings.shared
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        if snapOptionHeld?.id != id || snapOptionHeld?.held != optionHeld {
            if optionHeld || snapOptionHeld?.id == id {
                Log.write("snap: Option \(optionHeld ? "held" : "released"), snapping \(settings.enabled != optionHeld ? "on" : "off") for this drag")
            }
            snapOptionHeld = (id, optionHeld)
        }
        snapPreview = nil
        guard settings.enabled != optionHeld, let fence = store.fence(id), let window = controllers[id]?.window else {
            snapOutline.hide()
            return
        }
        let display = displayFrame(of: frame, for: fence)
        let screen = Self.screen(for: display)
        let others = store.fences.filter { $0.id != id && displayFrame(for: $0).intersects(screen.frame) }
        var minimum = minimumSize(for: fence)
        if fence.isCollapsed { minimum.height = 0 }
        let engine = SnapEngine(threshold: snapThreshold, gap: CGFloat(settings.gap), minimumSize: minimum)
        let result = engine.snap(display, mode: mode, others: others.map { displayFrame(for: $0) }, screen: screen.visibleFrame)
        guard !result.guides.isEmpty else {
            snapOutline.hide()
            return
        }
        // A collapsed fence keeps its expanded height below its title bar.
        let snapped = fence.isCollapsed
            ? CGRect(x: result.frame.minX, y: result.frame.maxY - frame.height, width: result.frame.width, height: frame.height)
            : result.frame
        snapPreview = (id, snapped, result.guides, others.map(\.id))
        snapOutline.show(outline: result.frame, guides: result.guides, on: screen.frame, below: window)
    }

    /// Fades the outline out and logs what the fence settled against.
    private func endSnapping(_ id: UUID) {
        if snapOptionHeld?.id == id { snapOptionHeld = nil }
        guard let snap = snapPreview, snap.id == id else {
            snapOutline.hide()
            return
        }
        snapPreview = nil
        snapOutline.fadeOut()
        guard let fence = store.fence(id) else { return }
        let titles = snap.others.map { "\"\(store.fence($0)?.title ?? "?")\"" }
        let reasons = snap.guides.flatMap { guide in
            guide.reasons.map { reason -> String in
                let side = "\(guide.axis == .x ? "x" : "y") \(Int(guide.position))"
                switch reason {
                case .screenEdge: return "screen edge at \(side)"
                case .flush(let index): return "beside \(titles[index]) at \(side)"
                case .aligned(let index): return "lined up with \(titles[index]) at \(side)"
                }
            }
        }
        Log.write("snap: \"\(fence.title)\" settled at \(fence.frame.integral), \(reasons.joined(separator: ", "))")
    }

    /// The screen a fence is on: the one under the pointer while it's dragged, else the one
    /// holding most of it.
    private static func screen(for frame: CGRect) -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) { return screen }
        let area = { (screen: NSScreen) -> CGFloat in
            let overlap = screen.frame.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        return NSScreen.screens.max { area($0) < area($1) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func resizedFrame(_ id: UUID, from start: CGRect, edges: ResizeEdges, delta: CGSize) -> CGRect {
        guard let fence = store.fence(id) else { return start }
        let minimum = minimumSize(for: fence)
        var frame = start
        if edges.contains(.right) {
            frame.size.width = max(minimum.width, start.width + delta.width)
        }
        if edges.contains(.left) {
            let width = max(minimum.width, start.width - delta.width)
            frame.origin.x = start.maxX - width
            frame.size.width = width
        }
        if edges.contains(.top) {
            frame.size.height = max(minimum.height, start.height + delta.height)
        }
        if edges.contains(.bottom) {
            let height = max(minimum.height, start.height - delta.height)
            frame.origin.y = start.maxY - height
            frame.size.height = height
        }
        return frame
    }

    // MARK: Windows

    func window(of id: UUID) -> NSWindow? {
        controllers[id]?.window
    }

    private func openWindow(for fence: Fence) {
        let controller = FenceWindowController(fenceID: fence.id, coordinator: self)
        controllers[fence.id] = controller
        controller.window.setFrame(displayFrame(for: fence), display: true)
        if !fencesHidden { controller.window.orderFrontRegardless() }
    }

    private func displayFrame(for fence: Fence) -> CGRect {
        displayFrame(of: liveFrames[fence.id] ?? fence.frame, for: fence)
    }

    /// What shows of a fence at `frame`: all of it, or just the title bar when collapsed.
    private func displayFrame(of frame: CGRect, for fence: Fence) -> CGRect {
        guard fence.isCollapsed else { return frame }
        let height = collapsedHeight(fence)
        return CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    private func applyFrame(_ id: UUID, animated: Bool = false) {
        guard let fence = store.fence(id), let window = controllers[id]?.window else { return }
        settles.removeValue(forKey: id)?.invalidate()
        let frame = displayFrame(for: fence)
        if animated, window.isVisible, window.frame != frame {
            settle(id, window, from: window.frame, to: frame)
        } else {
            window.setFrame(frame, display: true)
        }
        if setup?.fenceID == id { setup?.reposition() }
    }

    /// Glides a released fence into its snapped frame. Driven by a timer that any later frame
    /// change cancels, rather than the window's animator, whose animation can land after a
    /// later frame change and undo it.
    private func settle(_ id: UUID, _ window: NSWindow, from start: CGRect, to target: CGRect) {
        let began = Date()
        let duration = 0.16
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let progress = min(Date().timeIntervalSince(began) / duration, 1)
                let eased = 1 - pow(1 - progress, 3)
                func mix(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from + (to - from) * eased }
                window.setFrame(CGRect(
                    x: mix(start.minX, target.minX), y: mix(start.minY, target.minY),
                    width: mix(start.width, target.width), height: mix(start.height, target.height)
                ), display: true)
                if self?.setup?.fenceID == id { self?.setup?.reposition() }
                if progress >= 1 {
                    timer.invalidate()
                    self?.settles[id] = nil
                }
            }
        }
        settles[id] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func screensChanged() {
        for fence in store.fences {
            clampToScreens(fence.id)
            applyFrame(fence.id)
        }
    }

    /// Converts a rect in a fence window's content coordinates (top-left origin) to the screen.
    private func screenRect(_ rect: CGRect, in id: UUID) -> CGRect? {
        guard let window = controllers[id]?.window else { return nil }
        return CGRect(x: window.frame.minX + rect.minX, y: window.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The tab whose name is under `point`, if the fence is showing its tabs.
    private func tab(at point: CGPoint, in fence: Fence) -> FenceTab? {
        guard !fence.isCollapsed, let frames = tabFrames[fence.id],
              let strip = tabStripFrames[fence.id].flatMap({ screenRect($0, in: fence.id) }), strip.contains(point)
        else { return nil }
        return fence.tabs.first { tab in
            frames[tab.id].flatMap { screenRect($0, in: fence.id) }?.contains(point) == true
        }
    }

    /// The visible tile under `point` and whether the point is on its trailing half.
    private func tile(at point: CGPoint, in fence: Fence) -> (UUID, Bool)? {
        guard !fence.isCollapsed, let frames = tileFrames[fence.id] else { return nil }
        let visible = Set(fence.items(in: fence.currentTab.id).map(\.id))
        for (itemID, rect) in frames where visible.contains(itemID) {
            guard let screen = screenRect(rect, in: fence.id), screen.contains(point) else { continue }
            return (itemID, point.x > screen.midX)
        }
        return nil
    }

    /// Nearest Finder position to `target` where an icon won't overlap another visible desktop
    /// icon, a fence, the toolbar, the menu bar or the Dock.
    private func openDesktopSpot(near target: CGPoint, for name: String) -> CGPoint {
        guard let positions = desktop.positionsNow() else { return target }
        let hidden = Set(store.fences.flatMap { $0.items.filter(\.isOnDesktop).map(\.finderName) })
        let others = positions.filter { $0.key != name && !hidden.contains($0.key) }.map(\.value)
        // Matches the spacing between neighboring icons on Finder's desktop grid.
        let minDX = desktop.iconSize + 32
        let minDY = desktop.iconSize + 22
        let step: CGFloat = 16
        var candidates: [CGPoint] = []
        for i in -30...30 {
            for j in -30...30 {
                candidates.append(CGPoint(x: target.x + CGFloat(i) * step, y: target.y + CGFloat(j) * step))
            }
        }
        candidates.sort { hypot($0.x - target.x, $0.y - target.y) < hypot($1.x - target.x, $1.y - target.y) }
        let toolbar = toolbarFrame()
        for candidate in candidates {
            let rect = desktop.footprintRect(atFinderPosition: candidate).insetBy(dx: 10, dy: 4)
            guard NSScreen.screens.contains(where: { $0.visibleFrame.contains(rect) }),
                  !store.fences.contains(where: { displayFrame(for: $0).intersects(rect) }),
                  toolbar?.intersects(rect) != true,
                  !others.contains(where: { abs($0.x - candidate.x) < minDX && abs($0.y - candidate.y) < minDY })
            else { continue }
            return candidate
        }
        return target
    }

    /// Describes what covers `point` (Cocoa screen coordinates), or nil if it's open desktop.
    /// The Dock and screenshot tools own invisible full-screen windows at level 20 and above,
    /// so only ordinary app window levels count; the Dock and menu bar are excluded by each
    /// screen's visible frame instead.
    private func desktopBlocker(at point: CGPoint) -> String? {
        guard NSScreen.screens.contains(where: { $0.visibleFrame.contains(point) }) else { return "the menu bar or Dock" }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let topLeftPoint = CGPoint(x: point.x, y: mainHeight - point.y)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let appLevels = Int(CGWindowLevelForKey(.normalWindow))..<Int(CGWindowLevelForKey(.dockWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows {
            guard let layer = info[kCGWindowLayer as String] as? Int, appLevels.contains(layer),
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.contains(topLeftPoint) else { continue }
            return "\(info[kCGWindowOwnerName as String] as? String ?? "another app")'s window (layer \(layer))"
        }
        return nil
    }

    /// Keeps at least part of each fence's title bar on a screen.
    private func clampToScreens(_ id: UUID) {
        guard let fence = store.fence(id) else { return }
        let titleHeight = FenceMetrics(fence).titleHeight
        let title = CGRect(x: fence.frame.minX, y: fence.frame.maxY - titleHeight, width: fence.frame.width, height: titleHeight)
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersection(title).width >= 60 }
        guard !visible, let screen = NSScreen.main?.visibleFrame else { return }
        store.update(id) { fence in
            fence.frame.origin = CGPoint(x: screen.midX - fence.frame.width / 2, y: screen.midY - fence.frame.height / 2)
        }
    }
}
