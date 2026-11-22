import AppKit
import SwiftUI

extension NSPasteboard.PasteboardType {
    /// Only Clutter Buster understands this type, so Finder never moves, copies or aliases
    /// the file when an item is dragged out of a fence.
    static let clutterBusterItem = NSPasteboard.PasteboardType("com.elusivecow.clutterbuster.item")
}

/// Handles clicks, drags and the context menu for one item tile. A click selects the item
/// and a double-click opens it; a drag carries it to the desktop or to another fence. A
/// folder's tile also takes drops into the folder.
struct ItemDragSource: NSViewRepresentable {
    let item: FenceItem
    let fenceID: UUID
    let iconSize: CGFloat
    let toolTip: String
    let coordinator: FenceCoordinator

    func makeNSView(context: Context) -> ItemDragView {
        let view = ItemDragView()
        update(view)
        return view
    }

    func updateNSView(_ view: ItemDragView, context: Context) {
        update(view)
    }

    private func update(_ view: ItemDragView) {
        view.item = item
        view.fenceID = fenceID
        view.iconSize = iconSize
        view.coordinator = coordinator
        view.toolTip = toolTip
        view.isFolder = FolderDrop.isFolder(item.path)
    }
}

final class ItemDragView: NSView, NSDraggingSource {
    var item: FenceItem?
    var fenceID: UUID?
    var iconSize: CGFloat = 48
    weak var coordinator: FenceCoordinator?
    /// Only folder tiles take drops. Anywhere else in the fence a drop adds to the fence.
    var isFolder = false {
        didSet {
            guard isFolder != oldValue else { return }
            if isFolder { registerForDraggedTypes([.fileURL, .clutterBusterItem]) } else { unregisterDraggedTypes() }
        }
    }

    private var mouseDownEvent: NSEvent?
    private var isDragging = false
    private var springTimer: Timer?
    /// How long a drag rests on a folder tile before the folder opens in Finder.
    private static let springDelay: TimeInterval = 1

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let down = mouseDownEvent, let item else { return }
        let distance = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
        guard distance > 4 else { return }
        isDragging = true
        Log.write("drag start: \"\(item.finderName)\"")

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.id.uuidString, forType: .clutterBusterItem)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let point = convert(down.locationInWindow, from: nil)
        let frame = NSRect(x: point.x - iconSize / 2, y: point.y - iconSize / 2, width: iconSize, height: iconSize)
        let scale = window?.backingScaleFactor ?? 2
        draggingItem.setDraggingFrame(frame, contents: IconProvider.shared.currentIcon(for: item.path, pointSize: iconSize, scale: scale))

        let session = beginDraggingSession(with: [draggingItem], event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard !isDragging, let item else { return }
        if event.clickCount >= 2 {
            coordinator?.open(item)
        } else {
            coordinator?.selectedItemID = item.id
        }
    }

    // Move and copy are for folder tiles, which are the only views that accept this drag.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.generic, .move, .copy] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        mouseDownEvent = nil
        guard let item, let fenceID else { return }
        let mouse = NSEvent.mouseLocation
        coordinator?.itemDragEnded(item.id, from: fenceID, at: mouse, operation: operation)
    }

    // MARK: Dropping into the folder

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hover(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hover(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endHover()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        endHover()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        endHover()
        let operation = dropOperation(sender)
        guard let item, let coordinator, operation != [], let dragged = draggedItems(sender) else { return false }
        self.dragged = nil
        coordinator.dropIntoFolder(dragged.urls, folder: item.url, copy: operation == .copy, draggedItemID: dragged.itemID)
        return true
    }

    /// Highlights the tile while it would take the drop, and opens the folder in Finder once
    /// the drag has rested on it for `springDelay`.
    private func hover(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = dropOperation(sender)
        guard operation != [], let item else {
            endHover()
            return []
        }
        if coordinator?.folderDropTargetID != item.id {
            coordinator?.folderDropTargetID = item.id
            springTimer?.invalidate()
            let timer = Timer(timeInterval: Self.springDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let item = self.item, self.coordinator?.folderDropTargetID == item.id else { return }
                    self.coordinator?.springOpen(item)
                }
            }
            // A drag that started in a fence runs the event-tracking run loop mode.
            RunLoop.main.add(timer, forMode: .common)
            springTimer = timer
        }
        return operation
    }

    private func endHover() {
        springTimer?.invalidate()
        springTimer = nil
        if let item, coordinator?.folderDropTargetID == item.id { coordinator?.folderDropTargetID = nil }
    }

    /// Move, or copy with Option held or across volumes, as Finder decides. A folder dropped
    /// on its own tile isn't taken.
    private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let item, isFolder, let dragged = draggedItems(sender), !dragged.urls.isEmpty,
              dragged.itemID != item.id, !dragged.urls.contains(where: { $0.standardizedFileURL.path == item.path })
        else { return [] }
        // Holding Option narrows the mask to copy; Command narrows it to generic, a move.
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.move), !NSEvent.modifierFlags.contains(.option), dragged.sameVolume { return .move }
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) || mask.contains(.move) { return .move }
        return []
    }

    private struct DraggedItems {
        let sequence: Int
        let urls: [URL]
        /// Set when a fence item is dragged from a tile.
        let itemID: UUID?
        let sameVolume: Bool
    }

    /// Read once per drag, since AppKit asks for the operation over and over during a hover.
    private var dragged: DraggedItems?

    /// Files from Finder, or a fence item dragged from a tile.
    private func draggedItems(_ sender: NSDraggingInfo) -> DraggedItems? {
        if let dragged, dragged.sequence == sender.draggingSequenceNumber { return dragged }
        let pasteboard = sender.draggingPasteboard
        var urls: [URL] = []
        var itemID: UUID?
        if let id = pasteboard.string(forType: .clutterBusterItem).flatMap(UUID.init(uuidString:)) {
            guard let fenced = coordinator?.fencedItem(id) else { return nil }
            urls = [fenced.url]
            itemID = id
        } else {
            urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }
        let folder = item?.url ?? URL(fileURLWithPath: "/")
        let read = DraggedItems(
            sequence: sender.draggingSequenceNumber, urls: urls, itemID: itemID,
            sameVolume: urls.allSatisfy { FolderDrop.onSameVolume($0, folder) }
        )
        dragged = read
        return read
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openItem), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(revealItem), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove from Fence", action: #selector(removeItem), keyEquivalent: "").target = self
        return menu
    }

    @objc private func openItem() {
        guard let item else { return }
        coordinator?.open(item)
    }

    @objc private func revealItem() {
        guard let item else { return }
        coordinator?.revealInFinder(item)
    }

    @objc private func removeItem() {
        guard let item, let fenceID else { return }
        coordinator?.removeItem(item.id, from: fenceID)
    }
}
