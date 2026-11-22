import AppKit
import SwiftUI

extension NSPasteboard.PasteboardType {
    /// Only Clutter Buster understands this type, so Finder never moves, copies or aliases
    /// the file when an item is dragged out of a fence.
    static let clutterBusterItem = NSPasteboard.PasteboardType("com.elusivecow.clutterbuster.item")
}

/// Handles clicks, drags and the context menu for one item tile. A click opens the item;
/// a drag carries it to the desktop or to another fence.
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
    }
}

final class ItemDragView: NSView, NSDraggingSource {
    var item: FenceItem?
    var fenceID: UUID?
    var iconSize: CGFloat = 48
    weak var coordinator: FenceCoordinator?

    private var mouseDownEvent: NSEvent?
    private var isDragging = false

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

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.id.uuidString, forType: .clutterBusterItem)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let point = convert(down.locationInWindow, from: nil)
        let frame = NSRect(x: point.x - iconSize / 2, y: point.y - iconSize / 2, width: iconSize, height: iconSize)
        draggingItem.setDraggingFrame(frame, contents: IconCache.icon(for: item.path))

        let session = beginDraggingSession(with: [draggingItem], event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard !isDragging, let item else { return }
        coordinator?.open(item)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .generic : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        mouseDownEvent = nil
        guard let item, let fenceID else { return }
        let mouse = NSEvent.mouseLocation
        coordinator?.itemDragEnded(item.id, from: fenceID, at: mouse)
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
