import AppKit
import XCTest
@testable import ClutterBuster

@MainActor
final class ItemDragPayloadTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var target: DragTarget = .app("Safari")
    private var folder: URL!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ItemDragPayloadTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ItemDragPayloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: folder)
    }

    private func payload(_ item: FenceItem) -> ItemDragPayload {
        ItemDragPayload(item: item) { [unowned self] in self.target }
    }

    private func write(_ payload: ItemDragPayload) {
        pasteboard.clearContents()
        pasteboard.writeObjects([payload.makePasteboardItem()])
    }

    private var types: [NSPasteboard.PasteboardType] { pasteboard.pasteboardItems?.first?.types ?? [] }

    private func hiddenFile(_ name: String) throws -> URL {
        var url = folder.appendingPathComponent(name)
        try Data("test".utf8).write(to: url)
        var values = URLResourceValues()
        values.isHidden = true
        try url.setResourceValues(values)
        return url
    }

    // MARK: Contents by kind

    func testFileGivesItsURLAfterTheItemID() throws {
        let url = try hiddenFile("Report.pdf")
        let item = FenceItem(path: url.path)
        let payload = payload(item)
        write(payload)
        XCTAssertEqual(types, [.clutterBusterItem, .fileURL])
        XCTAssertEqual(pasteboard.string(forType: .clutterBusterItem), item.id.uuidString)
        let read = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(read?.map(\.standardizedFileURL), [url.standardizedFileURL])
        XCTAssertTrue(payload.provided)
        XCTAssertTrue(HiddenFiles.isHidden(url), "reading the URL doesn't touch the file")
    }

    func testLinkGivesItsURLTitleAndText() {
        let item = FenceItem.link(URL(string: "https://example.com/page")!, title: "Example", tabID: nil)
        write(payload(item))
        XCTAssertEqual(types, [.clutterBusterItem, .URL, ItemDragPayload.urlNameType, .string])
        XCTAssertEqual(pasteboard.string(forType: .URL), "https://example.com/page")
        XCTAssertEqual(pasteboard.string(forType: ItemDragPayload.urlNameType), "Example")
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/page")
        XCTAssertEqual(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], [URL(string: "https://example.com/page")!])
    }

    func testNoteGivesItsText() {
        let item = FenceItem.note("Buy milk\nand eggs", tabID: nil)
        write(payload(item))
        XCTAssertEqual(types, [.clutterBusterItem, .string])
        XCTAssertEqual(pasteboard.string(forType: .string), "Buy milk\nand eggs")
    }

    func testShortcutGivesOnlyTheItemID() {
        let item = FenceItem.shortcut("Morning", tabID: nil)
        let payload = payload(item)
        write(payload)
        XCTAssertEqual(types, [.clutterBusterItem])
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertFalse(payload.provided)
    }

    // MARK: Finder and Clutter Buster get nothing

    func testNothingIsGivenOverFinder() throws {
        let url = try hiddenFile("Secret.txt")
        let item = FenceItem(path: url.path)
        for place in [DragTarget.finder("the desktop"), .finder("a Finder window"), .finder("the Dock"), .clutterBuster] {
            target = place
            let payload = payload(item)
            write(payload)
            XCTAssertNil(pasteboard.string(forType: .fileURL), "\(place)")
            XCTAssertEqual(pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [], [], "\(place)")
            XCTAssertEqual(pasteboard.string(forType: .clutterBusterItem), item.id.uuidString, "fences still read the ID over \(place)")
            XCTAssertFalse(payload.provided)
        }
    }

    func testDataGivenToAnAppIsTakenBackBeforeFinderCanRead() throws {
        let url = try hiddenFile("Moving.txt")
        let item = FenceItem(path: url.path)
        let payload = payload(item)
        write(payload)
        target = .app("Google Chrome")
        XCTAssertNotNil(pasteboard.string(forType: .fileURL))

        let count = pasteboard.changeCount
        payload.pointerMoved(on: pasteboard)
        XCTAssertEqual(pasteboard.changeCount, count, "still over the app, so nothing's rewritten")

        target = .finder("the desktop")
        payload.pointerMoved(on: pasteboard)
        XCTAssertFalse(payload.provided)
        XCTAssertEqual(types, [.clutterBusterItem, .fileURL])
        XCTAssertNil(pasteboard.string(forType: .fileURL), "Finder can't read what Chrome had")
        XCTAssertEqual(pasteboard.string(forType: .clutterBusterItem), item.id.uuidString)

        XCTAssertTrue(payload.refused)
        target = .app("Mail")
        payload.pointerMoved(on: pasteboard)
        XCTAssertFalse(payload.refused)
        XCTAssertEqual(pasteboard.string(forType: .fileURL), url.absoluteString)
    }

    /// The usual path: out of the fence, across the desktop, where Finder may look, and on to
    /// a browser.
    func testAppAfterTheDesktopStillGetsTheFile() throws {
        let url = try hiddenFile("Upload.png")
        let payload = payload(FenceItem(path: url.path))
        write(payload)
        target = .finder("the desktop")
        XCTAssertNil(pasteboard.string(forType: .fileURL))
        payload.pointerMoved(on: pasteboard)
        XCTAssertFalse(payload.refused, "written again while still over the desktop")
        target = .app("Safari")
        payload.pointerMoved(on: pasteboard)
        let read = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(read?.map(\.standardizedFileURL), [url.standardizedFileURL])
    }

    func testOperationMask() {
        let payload = payload(FenceItem(path: "/tmp/x"))
        XCTAssertEqual(payload.operationMask(for: .withinApplication), [.generic, .move, .copy])
        // AppKit asks once, while the pointer is still over the fence, so the answer can't
        // depend on where it is; Finder is refused the data instead.
        for place in [DragTarget.clutterBuster, .finder("the desktop"), .finder("a Finder window"), .app("Slack")] {
            target = place
            XCTAssertEqual(payload.operationMask(for: .outsideApplication), .copy, "\(place)")
        }
        let shortcut = self.payload(.shortcut("Take a Break", tabID: nil))
        XCTAssertEqual(shortcut.operationMask(for: .outsideApplication), [], "a Shortcut has nothing to give")
    }

    // MARK: Ending the drag

    func testOnlyACopyIntoAnotherAppLeavesTheItemAlone() {
        XCTAssertEqual(DragTargets.appReceivingDrop(operation: .copy, target: .app("Safari")), "Safari")
        XCTAssertEqual(DragTargets.appReceivingDrop(operation: [.copy, .generic], target: .app("Mail")), "Mail")
        XCTAssertNil(DragTargets.appReceivingDrop(operation: [], target: .app("Safari")))
        XCTAssertNil(DragTargets.appReceivingDrop(operation: .copy, target: .finder("the desktop")))
        XCTAssertNil(DragTargets.appReceivingDrop(operation: .copy, target: .clutterBuster))
    }
}

/// Window lists modeled on a real one: the overlays macOS keeps above everything, fences at
/// desktop icon level plus one, Finder's desktop below them.
final class DragTargetTests: XCTestCase {
    private let own: pid_t = 100
    private let finder: pid_t = 200
    private let dock: pid_t = 300
    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    /// The Dock is on the left, the menu bar 39 points tall.
    private let open = CGRect(x: 43, y: 39, width: 1757, height: 1130)
    private let desktopIcons = Int(CGWindowLevelForKey(.desktopIconWindow))

    private var overlays: [DragWindow] {
        [
            DragWindow(pid: 400, owner: "Monosnap", layer: 1001, bounds: CGRect(x: 0, y: 1157, width: 1800, height: 1169), alpha: 0),
            DragWindow(pid: 401, owner: "Screenshot", layer: 24, bounds: screen),
            DragWindow(pid: 402, owner: "Window Server", layer: 24, bounds: CGRect(x: 0, y: 0, width: 1800, height: 39)),
            DragWindow(pid: dock, owner: "Dock", layer: 20, bounds: screen),
            DragWindow(pid: 403, owner: "WindowManager", layer: 18, bounds: screen),
        ]
    }

    private var desktop: [DragWindow] {
        [
            DragWindow(pid: own, owner: "Clutter Buster", layer: desktopIcons + 1, bounds: CGRect(x: 147, y: 426, width: 420, height: 456)),
            DragWindow(pid: 402, owner: "Window Server", layer: desktopIcons + 1, bounds: CGRect(x: 0, y: 0, width: 1800, height: 99)),
            DragWindow(pid: 404, owner: "Notification Center", layer: desktopIcons + 2, bounds: CGRect(x: 1500, y: 47, width: 180, height: 180)),
            DragWindow(pid: finder, owner: "Finder", layer: desktopIcons, bounds: screen),
            DragWindow(pid: 403, owner: "WindowManager", layer: Int(CGWindowLevelForKey(.desktopWindow)) + 1, bounds: screen),
        ]
    }

    private func classify(_ point: CGPoint, _ windows: [DragWindow]) -> DragTarget {
        DragTargets.classify(point, windows: windows, ownPID: own, finderPIDs: [finder], dockPIDs: [dock], screens: [screen], openAreas: [open])
    }

    func testBareDesktopIsFinder() {
        XCTAssertEqual(classify(CGPoint(x: 1200, y: 1000), overlays + desktop), .finder("the desktop"))
        XCTAssertEqual(classify(CGPoint(x: 1200, y: 1000), []), .finder("the desktop"), "no window at all is the desktop too")
        XCTAssertEqual(classify(CGPoint(x: 1550, y: 100), overlays + desktop), .finder("the desktop"), "a desktop widget")
    }

    func testFinderWindowIsFinder() {
        let window = DragWindow(pid: finder, owner: "Finder", layer: 0, bounds: CGRect(x: 600, y: 600, width: 500, height: 400))
        XCTAssertEqual(classify(CGPoint(x: 800, y: 800), overlays + [window] + desktop), .finder("a Finder window"))
    }

    func testAppWindowIsThatApp() {
        let safari = DragWindow(pid: 500, owner: "Safari", layer: 0, bounds: CGRect(x: 100, y: 300, width: 900, height: 700))
        let finderBehind = DragWindow(pid: finder, owner: "Finder", layer: 0, bounds: CGRect(x: 600, y: 600, width: 500, height: 400))
        XCTAssertEqual(classify(CGPoint(x: 800, y: 800), overlays + [safari, finderBehind] + desktop), .app("Safari"))
        XCTAssertEqual(classify(CGPoint(x: 1050, y: 900), overlays + [safari, finderBehind] + desktop), .finder("a Finder window"))
    }

    func testFullScreenAppIsStillAnApp() {
        let chrome = DragWindow(pid: 501, owner: "Google Chrome", layer: 0, bounds: screen)
        XCTAssertEqual(classify(CGPoint(x: 900, y: 600), overlays + [chrome] + desktop), .app("Google Chrome"))
    }

    func testOwnWindowsAreClutterBuster() {
        XCTAssertEqual(classify(CGPoint(x: 300, y: 600), overlays + desktop), .clutterBuster)
        let peeking = DragWindow(pid: own, owner: "Clutter Buster", layer: 3, bounds: CGRect(x: 100, y: 300, width: 400, height: 300))
        let safari = DragWindow(pid: 500, owner: "Safari", layer: 0, bounds: CGRect(x: 100, y: 300, width: 900, height: 700))
        XCTAssertEqual(classify(CGPoint(x: 200, y: 400), overlays + [peeking, safari] + desktop), .clutterBuster)
    }

    func testDragImageIsSeenThrough() {
        let image = DragWindow(pid: own, owner: "Clutter Buster", layer: DragTargets.draggingLayer, bounds: CGRect(x: 770, y: 770, width: 60, height: 60))
        let slack = DragWindow(pid: 502, owner: "Slack", layer: 0, bounds: CGRect(x: 600, y: 600, width: 500, height: 400))
        XCTAssertEqual(classify(CGPoint(x: 800, y: 800), [image] + overlays + [slack] + desktop), .app("Slack"))
    }

    func testDockAndMenuBarAreRefused() {
        XCTAssertEqual(classify(CGPoint(x: 20, y: 600), overlays + desktop), .finder("the Dock or menu bar"))
        XCTAssertEqual(classify(CGPoint(x: 600, y: 10), overlays + desktop), .finder("the Dock or menu bar"))
        let stack = DragWindow(pid: dock, owner: "Dock", layer: 20, bounds: CGRect(x: 43, y: 700, width: 300, height: 400))
        XCTAssertEqual(classify(CGPoint(x: 100, y: 800), [stack] + overlays + desktop), .finder("the Dock"))
    }

    func testDockBand() {
        let frame = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let visible = CGRect(x: 0, y: 4, width: 1800, height: 1126)
        let bottom = DockPreferences(edge: .minY, thickness: 64)
        XCTAssertEqual(bottom.openArea(frame: frame, visible: visible, leftmost: false, rightmost: false), CGRect(x: 0, y: 64, width: 1800, height: 1066))
        let left = DockPreferences(edge: .minX, thickness: 60)
        XCTAssertEqual(left.openArea(frame: frame, visible: visible, leftmost: true, rightmost: false), CGRect(x: 60, y: 4, width: 1740, height: 1126))
        XCTAssertEqual(left.openArea(frame: frame, visible: visible, leftmost: false, rightmost: true), visible)
        let right = DockPreferences(edge: .maxX, thickness: 60)
        XCTAssertEqual(right.openArea(frame: frame, visible: visible, leftmost: false, rightmost: true), CGRect(x: 0, y: 4, width: 1740, height: 1126))
    }
}
