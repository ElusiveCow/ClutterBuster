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
    private var interacting: Set<UUID> = []
    private var verifyTimer: Timer?

    init(store: FenceStore, desktop: DesktopIconService) {
        self.store = store
        self.desktop = desktop
    }

    var collapsedHeight: CGFloat { Self.titleHeight + desktop.footprint.height + 16 }

    var minimumSize: CGSize {
        CGSize(width: max(desktop.footprint.width + 30, 180), height: collapsedHeight)
    }

    func start() {
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
            iconsPerRow: AppSettings.defaultIconsPerRow
        )
        store.add(fence)
        openWindow(for: fence)
        return fence.id
    }

    func deleteFence(_ id: UUID) {
        guard let fence = store.fence(id) else { return }
        desktop.move(restorePositions(for: fence.items, leaving: fence))
        controllers.removeValue(forKey: id)?.close()
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

    func addItems(_ urls: [URL], to id: UUID) {
        guard store.fence(id) != nil else { return }
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
            store.update(id) { $0.items.append(FenceItem(path: path, originalDesktopPosition: original)) }
        }
        restack(id)
    }

    func removeItem(_ itemID: UUID, from id: UUID) {
        guard let fence = store.fence(id), let item = fence.items.first(where: { $0.id == itemID }) else { return }
        store.update(id) { $0.items.removeAll { $0.id == itemID } }
        desktop.move(restorePositions(for: [item], leaving: fence))
    }

    /// Called when an item tile is dropped at `point` (Cocoa screen coordinates). Over another
    /// fence it moves there; over open desktop it leaves the fence and its icon lands under
    /// the mouse. Anywhere else (its own fence, the toolbar, an app window) nothing changes.
    func itemDragEnded(_ itemID: UUID, from sourceID: UUID, at point: CGPoint) {
        guard let source = store.fence(sourceID),
              let item = source.items.first(where: { $0.id == itemID }),
              !displayFrame(for: source).contains(point) else { return }

        if let target = store.fences.first(where: { $0.id != sourceID && displayFrame(for: $0).contains(point) }) {
            addItems([item.url], to: target.id)
            return
        }

        if toolbarFrame()?.contains(point) == true || !isDesktopVisible(at: point) { return }

        store.update(sourceID) { $0.items.removeAll { $0.id == itemID } }
        if item.isOnDesktop {
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            desktop.move([item.finderName: CGPoint(x: point.x.rounded(), y: (mainHeight - point.y).rounded())])
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
    }

    /// Center of the fence body, where its hidden icon stack sits.
    private func stackCenter(for fence: Fence) -> CGPoint {
        let frame = displayFrame(for: fence)
        return CGPoint(x: frame.midX, y: frame.minY + (frame.height - Self.titleHeight) / 2)
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

    /// True when no other app's window (or the Dock or menu bar) covers `point`.
    private func isDesktopVisible(at point: CGPoint) -> Bool {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let topLeftPoint = CGPoint(x: point.x, y: mainHeight - point.y)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { continue }
            if bounds.contains(topLeftPoint) { return false }
        }
        return true
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
