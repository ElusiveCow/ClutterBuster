import AppKit

struct ResizeEdges: OptionSet, Hashable {
    let rawValue: Int
    static let left = ResizeEdges(rawValue: 1 << 0)
    static let right = ResizeEdges(rawValue: 1 << 1)
    static let top = ResizeEdges(rawValue: 1 << 2)
    static let bottom = ResizeEdges(rawValue: 1 << 3)
}

/// Owns the fence windows and keeps each fence's real Desktop icons stacked underneath it.
@MainActor
final class FenceCoordinator: ObservableObject {
    static let titleHeight: CGFloat = 30

    let store: FenceStore
    let desktop: DesktopIconService
    var toolbarFrame: () -> CGRect? = { nil }

    private var controllers: [UUID: FenceWindowController] = [:]
    private var liveFrames: [UUID: CGRect] = [:]
    /// Fences being moved or resized. Their theme animations pause meanwhile.
    @Published private(set) var interacting: Set<UUID> = []
    private var verifyTimer: Timer?
    private var setup: FenceSetupController?

    init(store: FenceStore, desktop: DesktopIconService) {
        self.store = store
        self.desktop = desktop
    }

    /// Gap between the solid patch and the fence's edges.
    static let patchInset: CGFloat = 6

    /// Solid patch in the body's bottom-trailing corner that hides the real desktop icon
    /// stack. It stays opaque at any fence transparency.
    var patchSize: CGSize {
        CGSize(width: desktop.footprint.width + 12, height: desktop.footprint.height + 12)
    }

    var collapsedHeight: CGFloat { Self.titleHeight + patchSize.height + Self.patchInset * 2 }

    static let tabBarHeight: CGFloat = 26
    /// Room for a row of icons above the band kept clear for the corner.
    static let minimumGridHeight: CGFloat = 72

    var minimumSize: CGSize {
        CGSize(
            width: max(patchSize.width + Self.patchInset * 2, 180),
            height: collapsedHeight + Self.tabBarHeight + Self.minimumGridHeight
        )
    }

    /// Where each fence's tabs and visible tiles are, in window content coordinates (top-left
    /// origin), so drops can be matched to a tab or a position in the grid.
    var tabFrames: [UUID: [UUID: CGRect]] = [:]
    var tileFrames: [UUID: [UUID: CGRect]] = [:]

    func start() {
        let minimum = minimumSize
        for fence in store.fences where fence.frame.width < minimum.width || fence.frame.height < minimum.height {
            store.update(fence.id) { fence in
                let top = fence.frame.maxY
                fence.frame.size.width = max(fence.frame.width, minimum.width)
                fence.frame.size.height = max(fence.frame.height, minimum.height)
                fence.frame.origin.y = top - fence.frame.height
            }
        }
        for fence in store.fences { openWindow(for: fence) }
        restackAll()
        verifyTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.verifyStacks() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    // MARK: Fences

    @discardableResult
    func createFence(title: String = "New Fence") -> UUID {
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
        if setup?.fenceID == id { setup?.finish() }
        desktop.move(restorePositions(for: fence.items, leaving: fence))
        controllers.removeValue(forKey: id)?.close()
        tabFrames[id] = nil
        tileFrames[id] = nil
        store.remove(id)
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

    func setIconsPerRow(_ id: UUID, _ count: Int) {
        store.update(id) { $0.iconsPerRow = count }
    }

    func toggleCollapse(_ id: UUID) {
        store.update(id) { $0.isCollapsed.toggle() }
        applyFrame(id)
        restack(id)
    }

    func setAllCollapsed(_ collapsed: Bool) {
        for fence in store.fences where fence.isCollapsed != collapsed {
            toggleCollapse(fence.id)
        }
    }

    /// Makes a fence's window key so its title can be edited.
    func focus(_ id: UUID) {
        NSApp.activate(ignoringOtherApps: true)
        controllers[id]?.window.makeKey()
    }

    // MARK: Items

    /// Adds items to a tab of a fence (its selected tab by default), taking them out of any
    /// other fence.
    func addItems(_ urls: [URL], to id: UUID, tab: UUID? = nil) {
        guard let fence = store.fence(id) else { return }
        let tabID = tab ?? fence.currentTab.id
        let positions = desktop.positionsNow() ?? [:]
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
            store.update(id) { $0.items.append(FenceItem(path: path, originalDesktopPosition: original, tabID: tabID)) }
        }
        restack(id)
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
        store.update(id) { $0.items.removeAll { $0.id == itemID } }
        desktop.move(restorePositions(for: [item], leaving: fence))
    }

    /// Called when an item tile is dropped at `point` (Cocoa screen coordinates). Over another
    /// fence it moves there; over open desktop it leaves the fence and its icon lands under
    /// the mouse. Anywhere else (its own fence, the toolbar, an app window) nothing changes.
    func itemDragEnded(_ itemID: UUID, from sourceID: UUID, at point: CGPoint, operation: NSDragOperation) {
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
            addItems([item.url], to: target.id, tab: tab?.id)
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

        store.update(sourceID) { $0.items.removeAll { $0.id == itemID } }
        guard item.isOnDesktop else {
            Log.write("  decision: removed from fence (not a Desktop file, nothing placed)")
            return
        }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let dropped = CGPoint(x: point.x.rounded(), y: (mainHeight - point.y).rounded())
        let target = openDesktopSpot(near: dropped, for: name)
        Log.write("  decision: back to desktop, Finder position \(target)\(target == dropped ? "" : " (nudged from \(dropped) to avoid other icons)")")
        desktop.move([name: target])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                self?.desktop.positions { positions in
                    Log.write("  result: Finder reports \"\(name)\" at \(positions?[name].map { "\($0)" } ?? "unknown")")
                }
            }
        }
    }

    func open(_ item: FenceItem) {
        NSWorkspace.shared.open(item.url)
    }

    func revealInFinder(_ item: FenceItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// Puts every hidden icon back where it was. Called when the app quits.
    func restoreAllIcons() {
        var moves: [String: CGPoint] = [:]
        for fence in store.fences {
            moves.merge(restorePositions(for: fence.items, leaving: fence)) { $1 }
        }
        desktop.moveNow(moves)
    }

    // MARK: Moving and resizing

    func expandedFrame(_ id: UUID) -> CGRect {
        liveFrames[id] ?? store.fence(id)?.frame ?? .zero
    }

    func beginInteraction(_ id: UUID) {
        interacting.insert(id)
    }

    func updateLiveFrame(_ id: UUID, _ frame: CGRect) {
        liveFrames[id] = frame
        applyFrame(id)
        restack(id)
    }

    func endInteraction(_ id: UUID) {
        if let frame = liveFrames.removeValue(forKey: id) {
            store.update(id) { $0.frame = frame }
        }
        interacting.remove(id)
        clampToScreens(id)
        applyFrame(id)
        restack(id)
    }

    func resizedFrame(from start: CGRect, edges: ResizeEdges, delta: CGSize) -> CGRect {
        let minimum = minimumSize
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

    // MARK: Windows and stacks

    private func openWindow(for fence: Fence) {
        let controller = FenceWindowController(fenceID: fence.id, coordinator: self)
        controllers[fence.id] = controller
        controller.window.setFrame(displayFrame(for: fence), display: true)
        controller.window.orderFrontRegardless()
    }

    private func displayFrame(for fence: Fence) -> CGRect {
        let frame = liveFrames[fence.id] ?? fence.frame
        guard fence.isCollapsed else { return frame }
        return CGRect(x: frame.minX, y: frame.maxY - collapsedHeight, width: frame.width, height: collapsedHeight)
    }

    private func applyFrame(_ id: UUID) {
        guard let fence = store.fence(id) else { return }
        controllers[id]?.window.setFrame(displayFrame(for: fence), display: true)
        if setup?.fenceID == id { setup?.reposition() }
    }

    /// Center of the solid patch, where the fence's hidden icon stack sits.
    private func stackCenter(for fence: Fence) -> CGPoint {
        let frame = displayFrame(for: fence)
        let size = patchSize
        return CGPoint(x: frame.maxX - Self.patchInset - size.width / 2, y: frame.minY + Self.patchInset + size.height / 2)
    }

    private func stackMoves(for fence: Fence) -> [String: CGPoint] {
        let target = desktop.finderPosition(centeredOn: stackCenter(for: fence))
        var moves: [String: CGPoint] = [:]
        for item in fence.items where item.isOnDesktop {
            moves[item.finderName] = target
        }
        return moves
    }

    private func restack(_ id: UUID) {
        guard let fence = store.fence(id) else { return }
        desktop.move(stackMoves(for: fence))
    }

    private func restackAll() {
        var moves: [String: CGPoint] = [:]
        for fence in store.fences { moves.merge(stackMoves(for: fence)) { $1 } }
        desktop.move(moves)
    }

    private func restorePositions(for items: [FenceItem], leaving fence: Fence) -> [String: CGPoint] {
        let frame = displayFrame(for: fence)
        let fallback = desktop.finderPosition(centeredOn: CGPoint(x: frame.maxX + desktop.footprint.width / 2 + 10, y: frame.maxY - 80))
        var moves: [String: CGPoint] = [:]
        for item in items where item.isOnDesktop {
            moves[item.finderName] = item.originalDesktopPosition ?? fallback
        }
        return moves
    }

    /// Finder can drop icons back into place (Finder restarts, Clean Up, display changes),
    /// so periodically put any stray icon back into its stack.
    private func verifyStacks() {
        guard interacting.isEmpty, !store.fences.isEmpty else { return }
        desktop.positions { [weak self] positions in
            guard let self, let positions, self.interacting.isEmpty else { return }
            var fixes: [String: CGPoint] = [:]
            for fence in self.store.fences {
                for (name, target) in self.stackMoves(for: fence) {
                    guard let current = positions[name] else { continue }
                    if hypot(current.x - target.x, current.y - target.y) > 3 { fixes[name] = target }
                }
            }
            self.desktop.move(fixes)
        }
    }

    private func screensChanged() {
        for fence in store.fences {
            clampToScreens(fence.id)
            applyFrame(fence.id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.restackAll() }
        }
    }

    /// Converts a rect in a fence window's content coordinates (top-left origin) to the screen.
    private func screenRect(_ rect: CGRect, in id: UUID) -> CGRect? {
        guard let window = controllers[id]?.window else { return nil }
        return CGRect(x: window.frame.minX + rect.minX, y: window.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The tab whose name is under `point`, if the fence is showing its tabs.
    private func tab(at point: CGPoint, in fence: Fence) -> FenceTab? {
        guard !fence.isCollapsed, let frames = tabFrames[fence.id] else { return nil }
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
        let title = CGRect(x: fence.frame.minX, y: fence.frame.maxY - Self.titleHeight, width: fence.frame.width, height: Self.titleHeight)
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersection(title).width >= 60 }
        guard !visible, let screen = NSScreen.main?.visibleFrame else { return }
        store.update(id) { fence in
            fence.frame.origin = CGPoint(x: screen.midX - fence.frame.width / 2, y: screen.midY - fence.frame.height / 2)
        }
    }
}
