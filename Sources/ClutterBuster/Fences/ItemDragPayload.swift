import AppKit

/// What's under the pointer while a fence item is dragged.
enum DragTarget: Equatable {
    /// One of Clutter Buster's own windows.
    case clutterBuster
    /// Somewhere a drop would have Finder copy or move the file: the bare desktop, a Finder
    /// window, the Dock or the menu bar. A Finder copy would keep the hidden flag.
    case finder(String)
    /// Another app's window, by the app's name.
    case app(String)

    var name: String {
        switch self {
        case .clutterBuster: "Clutter Buster"
        case .finder(let place): place
        case .app(let name): name
        }
    }
}

/// One entry of the window list. Only the owner, layer and bounds are read, which needs no
/// Screen Recording permission.
struct DragWindow: Equatable {
    let pid: pid_t
    let owner: String
    let layer: Int
    /// Points, origin at the top-left of the main display, as the window list gives them.
    let bounds: CGRect
    var alpha: Double = 1
}

/// Works out which app a drop at a point would go to, from the window list.
enum DragTargets {
    /// Drag images, the cursor and screen savers sit at this level and above.
    static let draggingLayer = Int(CGWindowLevelForKey(.draggingWindow))

    /// The mask outside the app: copy for another app, nothing for Finder, so Finder never
    /// takes the file.
    static func outsideMask(for target: DragTarget) -> NSDragOperation {
        if case .app = target { return .copy }
        return []
    }

    /// The app that took a drop which ended with `operation`, or nil if it wasn't another app.
    static func appReceivingDrop(operation: NSDragOperation, target: DragTarget) -> String? {
        guard operation.contains(.copy), case .app(let name) = target else { return nil }
        return name
    }

    /// Classifies `point` against `windows`, listed front to back. All geometry is in points
    /// with the origin at the top-left of the main display.
    /// - `screens`: each display's frame.
    /// - `openAreas`: where app windows can be, so not the menu bar or the Dock.
    static func classify(
        _ point: CGPoint, windows: [DragWindow], ownPID: pid_t, finderPIDs: Set<pid_t>, dockPIDs: Set<pid_t>,
        screens: [CGRect], openAreas: [CGRect]
    ) -> DragTarget {
        guard openAreas.contains(where: { $0.contains(point) }) else { return .finder("the Dock or menu bar") }
        for window in windows where window.bounds.contains(point) && window.alpha > 0 {
            if window.layer >= draggingLayer || window.owner == "Window Server" { continue }
            // The Dock, Stage Manager and the screenshot tools own invisible full-screen
            // windows above app windows that drops pass through.
            if window.layer > 0, screens.contains(where: { window.bounds.contains($0) }) { continue }
            if window.pid == ownPID { return .clutterBuster }
            // The desktop picture, Finder's desktop icons and desktop widgets.
            if window.layer < 0 { return .finder("the desktop") }
            if finderPIDs.contains(window.pid) { return .finder("a Finder window") }
            if dockPIDs.contains(window.pid) { return .finder("the Dock") }
            return .app(window.owner)
        }
        return .finder("the desktop")
    }

    /// What's under `point`, in Cocoa screen coordinates.
    @MainActor
    static func at(_ point: CGPoint) -> DragTarget {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let flip = { (rect: CGRect) in CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height) }
        let dock = DockPreferences.current()
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        let open = NSScreen.screens.map { screen in
            flip(dock.openArea(frame: screen.frame, visible: screen.visibleFrame, leftmost: screen.frame.minX == minX, rightmost: screen.frame.maxX == maxX))
        }
        return classify(
            CGPoint(x: point.x, y: mainHeight - point.y), windows: windowList(),
            ownPID: ProcessInfo.processInfo.processIdentifier,
            finderPIDs: pids("com.apple.finder"), dockPIDs: pids("com.apple.dock"),
            screens: NSScreen.screens.map { flip($0.frame) }, openAreas: open
        )
    }

    private static func pids(_ bundleID: String) -> Set<pid_t> {
        Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
    }

    static func windowList() -> [DragWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return DragWindow(
                pid: pid, owner: info[kCGWindowOwnerName as String] as? String ?? "another app", layer: layer,
                bounds: bounds, alpha: info[kCGWindowAlpha as String] as? Double ?? 1
            )
        }
    }
}

/// Where the Dock is and how big it can get, from its preferences. The window list can't
/// tell the Dock's icons apart from its invisible full-screen window, so a band along its
/// edge counts as the Dock, also while it's hidden.
struct DockPreferences: Equatable {
    var edge: NSRectEdge = .minY
    var thickness: CGFloat = 64

    static func current() -> DockPreferences {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let tile = dock?.object(forKey: "tilesize") as? Double ?? 48
        let large = dock?.bool(forKey: "magnification") == true ? dock?.object(forKey: "largesize") as? Double ?? 128 : 0
        let edge: NSRectEdge = switch dock?.string(forKey: "orientation") {
        case "left": .minX
        case "right": .maxX
        default: .minY
        }
        return DockPreferences(edge: edge, thickness: CGFloat(max(tile, large)) + 16)
    }

    /// A screen's visible frame less the band the Dock can cover, in Cocoa coordinates. A
    /// bottom Dock can be on any screen; a side Dock only on the outermost screen that side.
    func openArea(frame: CGRect, visible: CGRect, leftmost: Bool, rightmost: Bool) -> CGRect {
        var allowed = frame
        switch edge {
        case .minX where leftmost: allowed.origin.x += thickness; allowed.size.width -= thickness
        case .maxX where rightmost: allowed.size.width -= thickness
        case .minY: allowed.origin.y += thickness; allowed.size.height -= thickness
        default: break
        }
        return visible.intersection(allowed)
    }
}

/// What a fence item puts on the drag pasteboard. Clutter Buster's own ID goes first, so
/// fences, tabs and folder tiles handle the drag as they always have. Other apps get the
/// file, link or text, but only through `pasteboard(_:item:provideDataForType:)`, which
/// gives it out only while the pointer is over another app. Over Finder they get nothing,
/// whatever AppKit's mask says.
@MainActor
final class ItemDragPayload: NSObject, NSPasteboardItemDataProvider {
    static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    let item: FenceItem
    private let target: @MainActor () -> DragTarget
    /// Whether another app has had the data since the pasteboard was last written. The
    /// pasteboard keeps what it's given, so it's written again before the pointer reaches
    /// Finder.
    private(set) var provided = false
    /// Whether a read was refused since the pasteboard was last written. The pasteboard
    /// asks once per type, so it's written again for the next app to ask.
    private(set) var refused = false
    private var lastMaskLine: String?
    private var maskRepeats = 0

    init(item: FenceItem, target: @escaping @MainActor () -> DragTarget = { DragTargets.at(NSEvent.mouseLocation) }) {
        self.item = item
        self.target = target
    }

    /// The types other apps can have, by item kind. Shortcuts have none.
    static func publicTypes(for item: FenceItem) -> [NSPasteboard.PasteboardType] {
        switch item.kind {
        case .file: item.path.isEmpty ? [] : [.fileURL]
        case .link: item.link == nil ? [] : [.URL, urlNameType, .string]
        case .note: [.string]
        case .shortcut: []
        }
    }

    func makePasteboardItem() -> NSPasteboardItem {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.id.uuidString, forType: .clutterBusterItem)
        let types = Self.publicTypes(for: item)
        if !types.isEmpty { pasteboardItem.setDataProvider(self, forTypes: types) }
        return pasteboardItem
    }

    /// The drag mask: everything inside the app, as before; outside, copy for another app and
    /// nothing over Finder. Repeats of the same answer are counted rather than each logged.
    func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        let line: String
        let mask: NSDragOperation
        if context == .withinApplication {
            mask = [.generic, .move, .copy]
            line = "drag: mask asked inside Clutter Buster, allowed move and copy"
        } else {
            let target = target()
            mask = DragTargets.outsideMask(for: target)
            line = "drag: mask asked outside the app, over \(target.name), \(mask.isEmpty ? "refused" : "allowed copy")"
        }
        if line == lastMaskLine {
            maskRepeats += 1
        } else {
            flushMaskLog()
            Log.write(line)
            lastMaskLine = line
        }
        return mask
    }

    /// Writes the pasteboard again once the pointer has left the app that had the data, so
    /// the next read, perhaps Finder's, comes back here to be checked; and after a refusal,
    /// so the next app to ask can have it.
    func pointerMoved(on pasteboard: NSPasteboard) {
        guard provided || refused else { return }
        let target = target()
        if !refused, case .app = target { return }
        pasteboard.clearContents()
        pasteboard.writeObjects([makePasteboardItem()])
        Log.write("drag: pointer over \(target.name), \"\(item.finderName)\" is back to being given out on request (after \(refused ? "a refusal" : "another app had it"))")
        provided = false
        refused = false
    }

    func dragEnded() {
        flushMaskLog()
    }

    private func flushMaskLog() {
        if maskRepeats > 0 { Log.write("  (asked \(maskRepeats) more time\(maskRepeats == 1 ? "" : "s") with the same answer)") }
        maskRepeats = 0
        lastMaskLine = nil
    }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item pasteboardItem: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { provide(type, on: pasteboardItem) }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { provide(type, on: pasteboardItem) } }
        }
    }

    private func provide(_ type: NSPasteboard.PasteboardType, on pasteboardItem: NSPasteboardItem) {
        let target = target()
        guard case .app = target else {
            refused = true
            Log.write("drag: \(type.rawValue) asked for over \(target.name), gave nothing")
            return
        }
        let value: String? = switch (item.kind, type) {
        case (.file, .fileURL): item.url.absoluteString
        case (.link, .URL), (.link, .string): item.link
        case (.link, Self.urlNameType): item.displayName
        case (.note, .string): item.text ?? ""
        default: nil
        }
        guard let value else { return }
        pasteboardItem.setString(value, forType: type)
        provided = true
        Log.write("drag: \(type.rawValue) asked for over \(target.name), gave \"\(item.finderName)\"")
    }
}
