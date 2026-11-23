import CoreGraphics
import XCTest
@testable import ClutterBuster

@MainActor
final class DisplayLayoutTests: XCTestCase {
    private let builtIn = ScreenInfo(
        id: "37D8832A-2D66-02CA-B9F7-8F30A301B230", name: "Built-in",
        frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130)
    )
    private let external = ScreenInfo(
        id: "9A59E8B7-6A8D-4B8F-992B-FA0B53DE1D4D", name: "Studio Display",
        frame: CGRect(x: 1800, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 1800, y: 0, width: 2560, height: 1415)
    )
    private let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DisplayLayoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("layout.json") }

    // MARK: Keys

    func testKeyIgnoresOrderAndCase() {
        let a = DisplaySet.key(for: [builtIn.id, external.id])
        let b = DisplaySet.key(for: [external.id.lowercased(), builtIn.id])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "37D8832A-2D66-02CA-B9F7-8F30A301B230+9A59E8B7-6A8D-4B8F-992B-FA0B53DE1D4D")
    }

    func testKeyTellsDisplaySetsApart() {
        let alone = DisplaySet.key(for: [builtIn.id])
        let docked = DisplaySet.key(for: [builtIn.id, external.id])
        let clamshell = DisplaySet.key(for: [external.id])
        XCTAssertEqual(Set([alone, docked, clamshell]).count, 3)
        XCTAssertEqual(alone, builtIn.id)
        // A screen listed twice, as while macOS is still rearranging, is one display.
        XCTAssertEqual(DisplaySet.key(for: [builtIn.id, builtIn.id]), alone)
    }

    // MARK: Migration

    /// A layout as saved before per-display layouts: just fences and the toolbar.
    private var singleLayoutJSON: String {
        """
        {
          "fences" : [
            {
              "color" : "slate", "frame" : [[460.12890625, 820.296875], [431, 311.6796875]], "iconsPerRow" : 4,
              "id" : "654F643E-6FE1-4608-B4DB-C585DB56368B", "title" : "AI Tools", "textScale" : 1.2,
              "items" : [
                { "addedAt" : 785000000, "id" : "0F9255D9-A38D-4CA1-B79D-F85383F20A76", "kind" : "file",
                  "originalDesktopPosition" : [120, 340], "path" : "\(desktop)/Cursor.app",
                  "tabID" : "95E2C9D5-A677-4B87-AA3A-F5E2CA33F28E" }
              ],
              "tabs" : [ { "id" : "95E2C9D5-A677-4B87-AA3A-F5E2CA33F28E", "name" : "General", "sort" : { "ascending" : true, "key" : "manual" } } ]
            },
            {
              "color" : "plum", "frame" : [[720.40234375, 377.01953125], [648.796875, 421.4140625]], "iconsPerRow" : 5,
              "id" : "2574EAE4-34CF-4064-963E-1AFB33C35D49", "title" : "MISC FILES", "theme" : "robot",
              "items" : [
                { "addedAt" : 785000100, "id" : "30E1C1CC-25D7-4B10-8685-DEE73DB76ADE", "kind" : "link",
                  "link" : "https://www.apple.com", "title" : "Apple", "tabID" : "C77C20E2-12F6-4CF4-A5C2-C67F4EA0EF19" }
              ],
              "tabs" : [ { "id" : "C77C20E2-12F6-4CF4-A5C2-C67F4EA0EF19", "name" : "Docs" } ]
            }
          ],
          "toolbarOrigin" : [1540, 0],
          "toolbarShape" : "arc:bottomRight"
        }
        """
    }

    func testSingleLayoutBecomesTheLayoutForTheCurrentDisplays() throws {
        try Data(singleLayoutJSON.utf8).write(to: fileURL)
        let original = try JSONDecoder().decode(OldLayout.self, from: Data(singleLayoutJSON.utf8))
        let store = FenceStore(fileURL: fileURL)
        XCTAssertNil(store.displayKey)
        XCTAssertTrue(store.displayLayouts.isEmpty)

        let key = DisplaySet.key(for: [builtIn.id])
        let change = store.useDisplayLayout(key, screens: [builtIn])
        XCTAssertNil(change.from)
        XCTAssertTrue(change.isNew)
        XCTAssertTrue(change.savedScreens.isEmpty)
        // The fences were shown on these screens, so fitting them changes nothing.
        for fence in store.fences {
            let placed = ScreenPlacement.place(fence.frame, titleHeight: FenceMetrics(fence).titleHeight, minimumSize: CGSize(width: 180, height: 140), savedOn: change.savedScreens, onto: [builtIn])
            XCTAssertEqual(placed, fence.frame, fence.title)
        }
        store.layoutFits([builtIn])
        store.saveNow()

        let reloaded = FenceStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.displayKey, key)
        XCTAssertEqual(reloaded.fences.map(\.id), original.fences.map(\.id))
        XCTAssertEqual(reloaded.fences.map(\.title), ["AI Tools", "MISC FILES"])
        XCTAssertEqual(reloaded.fences.map(\.frame), original.fences.map(\.frame))
        XCTAssertEqual(reloaded.fences.map { $0.items.map(\.id) }, original.fences.map { $0.items.map(\.id) })
        XCTAssertEqual(reloaded.fences[0].items[0].path, "\(desktop)/Cursor.app")
        XCTAssertEqual(reloaded.fences[0].items[0].originalDesktopPosition, CGPoint(x: 120, y: 340))
        XCTAssertEqual(reloaded.fences[0].textScale, 1.2, accuracy: 0.001)
        XCTAssertEqual(reloaded.fences[1].theme, .robot)
        XCTAssertEqual(reloaded.fences[1].items[0].link, "https://www.apple.com")
        XCTAssertEqual(reloaded.fences.map(\.spaces), [.all, .all])
        XCTAssertEqual(reloaded.toolbarOrigin, CGPoint(x: 1540, y: 0))
        XCTAssertEqual(reloaded.toolbarShape, .cornerArc(.bottomRight))

        let layout = try XCTUnwrap(reloaded.displayLayouts[key])
        XCTAssertEqual(layout.screens, [builtIn])
        XCTAssertEqual(layout.frames.count, 2)
        for fence in original.fences {
            XCTAssertEqual(layout.frames[fence.id.uuidString], fence.frame)
        }
        XCTAssertEqual(layout.toolbarOrigin, CGPoint(x: 1540, y: 0))
        XCTAssertEqual(layout.toolbarShape, .cornerArc(.bottomRight))

        // Older versions still read the fences and toolbar at the top level.
        let saved = try JSONDecoder().decode(OldLayout.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(saved.fences.map(\.frame), original.fences.map(\.frame))
        XCTAssertEqual(saved.toolbarShape, .cornerArc(.bottomRight))
    }

    private struct OldLayout: Decodable {
        var fences: [Fence]
        var toolbarOrigin: CGPoint?
        var toolbarShape: ToolbarShape?
    }

    func testUnreadableLayoutIsKeptAside() throws {
        try Data("{ not json".utf8).write(to: fileURL)
        let store = FenceStore(fileURL: fileURL)
        XCTAssertTrue(store.fences.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("layout.unreadable-") }, "\(names)")
    }

    // MARK: Switching

    func testEachDisplaySetKeepsItsOwnFramesAndToolbar() throws {
        try Data(singleLayoutJSON.utf8).write(to: fileURL)
        let store = FenceStore(fileURL: fileURL)
        let alone = DisplaySet.key(for: [builtIn.id])
        let docked = DisplaySet.key(for: [builtIn.id, external.id])
        store.useDisplayLayout(alone, screens: [builtIn])
        store.layoutFits([builtIn])
        let aloneFrames = store.fences.map(\.frame)
        let id = store.fences[0].id

        // A new display set starts from the current layout.
        let plugged = store.useDisplayLayout(docked, screens: [builtIn, external])
        XCTAssertTrue(plugged.isNew)
        XCTAssertEqual(plugged.from, alone)
        XCTAssertEqual(plugged.savedScreens, [builtIn])
        XCTAssertEqual(store.fences.map(\.frame), aloneFrames)
        store.layoutFits([builtIn, external])

        // Moved around while docked.
        let dockedFrame = CGRect(x: 2400, y: 600, width: 500, height: 400)
        store.update(id) { $0.frame = dockedFrame }
        store.toolbarOrigin = CGPoint(x: 1800, y: 1380)
        store.toolbarShape = .horizontal

        let unplugged = store.useDisplayLayout(alone, screens: [builtIn])
        XCTAssertFalse(unplugged.isNew)
        XCTAssertEqual(unplugged.savedScreens, [builtIn])
        XCTAssertTrue(unplugged.unsaved.isEmpty)
        XCTAssertEqual(store.fences.map(\.frame), aloneFrames, "back exactly where they were")
        XCTAssertEqual(store.toolbarOrigin, CGPoint(x: 1540, y: 0))
        XCTAssertEqual(store.toolbarShape, .cornerArc(.bottomRight))

        let replugged = store.useDisplayLayout(docked, screens: [builtIn, external])
        XCTAssertEqual(replugged.savedScreens, [builtIn, external])
        XCTAssertEqual(store.fence(id)?.frame, dockedFrame)
        XCTAssertEqual(store.toolbarShape, .horizontal)
        XCTAssertEqual(store.toolbarOrigin, CGPoint(x: 1800, y: 1380))

        // The same displays again changes nothing.
        let same = store.useDisplayLayout(docked, screens: [builtIn, external])
        XCTAssertFalse(same.switched)
        XCTAssertEqual(store.fence(id)?.frame, dockedFrame)
    }

    func testFenceMadeWithOtherDisplaysKeepsItsFrameToBeFitted() throws {
        try Data(singleLayoutJSON.utf8).write(to: fileURL)
        let store = FenceStore(fileURL: fileURL)
        let alone = DisplaySet.key(for: [builtIn.id])
        let docked = DisplaySet.key(for: [builtIn.id, external.id])
        store.useDisplayLayout(alone, screens: [builtIn])
        store.layoutFits([builtIn])
        store.useDisplayLayout(docked, screens: [builtIn, external])
        store.layoutFits([builtIn, external])
        let made = Fence(title: "Made Docked", frame: CGRect(x: 3000, y: 500, width: 400, height: 300), color: .slate, iconsPerRow: 4)
        store.add(made)

        let change = store.useDisplayLayout(alone, screens: [builtIn])
        XCTAssertEqual(change.unsaved, [made.id])
        XCTAssertEqual(change.previousScreens, [builtIn, external])
        XCTAssertEqual(store.fence(made.id)?.frame, made.frame)

        store.remove(made.id)
        XCTAssertTrue(store.displayLayouts.values.allSatisfy { $0.frames[made.id.uuidString] == nil })
    }

    func testOnlyTheMostRecentLayoutsAreKept() {
        let store = FenceStore(fileURL: fileURL)
        for index in 0..<(DisplaySet.maxLayouts + 5) {
            store.useDisplayLayout("PROJECTOR-\(index)", screens: [builtIn])
        }
        XCTAssertEqual(store.displayLayouts.count, DisplaySet.maxLayouts)
        XCTAssertNotNil(store.displayLayouts["PROJECTOR-\(DisplaySet.maxLayouts + 4)"])
        XCTAssertNil(store.displayLayouts["PROJECTOR-0"])
    }

    // MARK: Fitting onto screens

    private let minimum = CGSize(width: 180, height: 140)

    private func place(_ frame: CGRect, from old: [ScreenInfo], to new: [ScreenInfo]) -> CGRect {
        ScreenPlacement.place(frame, titleHeight: 30, minimumSize: minimum, savedOn: old, onto: new)
    }

    func testFenceOnTheSameScreenStaysPut() {
        let frame = CGRect(x: 460, y: 820, width: 431, height: 311)
        XCTAssertEqual(place(frame, from: [builtIn], to: [builtIn]), frame)
        // Partly past the edge but with its title bar in reach, as the user left it.
        let pastEdge = CGRect(x: 1700, y: 400, width: 400, height: 300)
        XCTAssertEqual(place(pastEdge, from: [builtIn], to: [builtIn]), pastEdge)
    }

    func testFenceOnAScreenThatsGoneMovesOntoTheMainScreen() {
        // Flush with the external display's right edge, halfway up.
        let frame = CGRect(x: 4360 - 500, y: 1415 / 2 - 200, width: 500, height: 400)
        let placed = place(frame, from: [builtIn, external], to: [builtIn])
        XCTAssertTrue(builtIn.visibleFrame.contains(placed), "\(placed)")
        XCTAssertEqual(placed.size, frame.size)
        XCTAssertEqual(placed.maxX, builtIn.visibleFrame.maxX, accuracy: 0.5, "stays against the right edge")
        XCTAssertEqual(placed.midY, builtIn.visibleFrame.midY, accuracy: 1, "stays halfway up")
    }

    func testFenceFollowsItsScreenWhenItMoves() {
        // The external display became the main one, so the built-in one moved to its left.
        let externalMain = ScreenInfo(id: external.id, name: external.name, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415))
        let builtInLeft = ScreenInfo(id: builtIn.id, name: builtIn.name, frame: CGRect(x: -1800, y: 0, width: 1800, height: 1169), visibleFrame: CGRect(x: -1800, y: 0, width: 1800, height: 1130))
        let frame = CGRect(x: 300, y: 200, width: 400, height: 300)
        let placed = place(frame, from: [builtIn], to: [externalMain, builtInLeft])
        assertEqual(placed, frame.offsetBy(dx: -1800, dy: 0))
    }

    private func assertEqual(_ a: CGRect, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in [(a.minX, b.minX), (a.minY, b.minY), (a.width, b.width), (a.height, b.height)] {
            XCTAssertEqual(x, y, accuracy: 0.001, "\(a) is not \(b)", file: file, line: line)
        }
    }

    func testFenceTooBigForTheScreenShrinksButNotBelowItsMinimum() {
        let big = CGRect(x: 1900, y: 100, width: 2200, height: 1300)
        let placed = place(big, from: [builtIn, external], to: [builtIn])
        XCTAssertEqual(placed, builtIn.visibleFrame)

        let tiny = ScreenInfo(id: "TINY", name: nil, frame: CGRect(x: 0, y: 0, width: 160, height: 120), visibleFrame: CGRect(x: 0, y: 0, width: 160, height: 100))
        let squeezed = place(CGRect(x: 10, y: 10, width: 400, height: 300), from: [builtIn], to: [tiny])
        XCTAssertEqual(squeezed.size, minimum)
        XCTAssertEqual(squeezed.minX, 0)
        XCTAssertEqual(squeezed.maxY, 100, "the title bar stays on screen")
    }

    func testFenceOffEveryScreenComesBackOntoTheNearestOne() {
        let lost = CGRect(x: -900, y: 300, width: 400, height: 300)
        let placed = place(lost, from: [builtIn], to: [builtIn])
        XCTAssertEqual(placed, CGRect(x: 0, y: 300, width: 400, height: 300))
        XCTAssertTrue(ScreenPlacement.titleIsReachable(placed, titleHeight: 30, on: [builtIn.visibleFrame]))
    }

    func testLayoutWithoutSavedScreensKeepsReachableFences() {
        let frame = CGRect(x: 1377, y: 810, width: 421, height: 311)
        XCTAssertEqual(place(frame, from: [], to: [builtIn]), frame)
        let lost = CGRect(x: 5000, y: 300, width: 400, height: 300)
        XCTAssertTrue(builtIn.visibleFrame.contains(place(lost, from: [], to: [builtIn])))
    }

    func testTitleBarUnderTheMenuBarIsNotReachable() {
        let underMenuBar = CGRect(x: 100, y: 1160 - 330, width: 400, height: 330)
        XCTAssertFalse(ScreenPlacement.titleIsReachable(underMenuBar, titleHeight: 30, on: [builtIn.visibleFrame]))
        XCTAssertTrue(builtIn.visibleFrame.contains(place(underMenuBar, from: [builtIn], to: [builtIn])))
    }

    // MARK: Hidden files

    private func fence(_ title: String, at frame: CGRect, paths: [String], spaces: FenceSpaces = .all) -> Fence {
        var fence = Fence(title: title, frame: frame, color: .slate, iconsPerRow: 4)
        fence.items = paths.map { FenceItem(path: $0, tabID: fence.tabs[0].id) }
        fence.spaces = spaces
        return fence
    }

    func testHiddenFileInAFenceOnScreenIsReachable() {
        let report = "\(desktop)/Report.pdf"
        let fences = [fence("Work", at: CGRect(x: 100, y: 100, width: 400, height: 300), paths: [report])]
        XCTAssertTrue(HiddenFileReachability.unreachable(hidden: [report], fences: fences, visibleFrames: [builtIn.visibleFrame]).isEmpty)
    }

    func testHiddenFileInNoFenceIsUnreachable() {
        let report = "\(desktop)/Report.pdf"
        let stray = "\(desktop)/Stray.png"
        let fences = [fence("Work", at: CGRect(x: 100, y: 100, width: 400, height: 300), paths: [report])]
        XCTAssertEqual(HiddenFileReachability.unreachable(hidden: [report, stray], fences: fences, visibleFrames: [builtIn.visibleFrame]), [stray])
    }

    func testHiddenFileInAFenceOffScreenIsUnreachable() {
        let report = "\(desktop)/Report.pdf"
        let fences = [fence("Docked", at: CGRect(x: 3000, y: 300, width: 400, height: 300), paths: [report])]
        XCTAssertEqual(HiddenFileReachability.unreachable(hidden: [report], fences: fences, visibleFrames: [builtIn.visibleFrame]), [report])
        // With the display it's on, it's reachable again.
        XCTAssertTrue(HiddenFileReachability.unreachable(hidden: [report], fences: fences, visibleFrames: [builtIn.visibleFrame, external.visibleFrame]).isEmpty)
    }

    func testFileInTwoFencesIsReachableWhileEitherIsOnScreen() {
        let report = "\(desktop)/Report.pdf"
        let fences = [
            fence("Off", at: CGRect(x: 3000, y: 300, width: 400, height: 300), paths: [report]),
            fence("On", at: CGRect(x: 100, y: 100, width: 400, height: 300), paths: [report]),
        ]
        XCTAssertTrue(HiddenFileReachability.unreachable(hidden: [report], fences: fences, visibleFrames: [builtIn.visibleFrame]).isEmpty)
    }

    // MARK: Spaces

    func testFenceWithDesktopFilesShowsOnAllSpaces() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let withFile = fence("Work", at: frame, paths: ["\(desktop)/Report.pdf"], spaces: .current)
        XCTAssertTrue(withFile.holdsDesktopFiles)
        XCTAssertTrue(withFile.showsOnAllSpaces, "This Space Only can't hide Desktop files from the other Spaces")
        XCTAssertTrue(HiddenFileReachability.unreachable(hidden: ["\(desktop)/Report.pdf"], fences: [withFile], visibleFrames: [builtIn.visibleFrame]).isEmpty)

        var links = fence("Links", at: frame, paths: [], spaces: .current)
        links.items = [.link(URL(string: "https://www.apple.com")!, title: "Apple", tabID: links.tabs[0].id), .note("Hi", tabID: links.tabs[0].id)]
        links.items.append(FenceItem(path: "/Applications/Safari.app", tabID: links.tabs[0].id))
        links.items.append(FenceItem(path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Plan.pdf").path, tabID: links.tabs[0].id))
        XCTAssertFalse(links.holdsDesktopFiles)
        XCTAssertFalse(links.showsOnAllSpaces)
    }

    func testOlderFencesShowOnAllSpaces() throws {
        let fence = try JSONDecoder().decode(FenceStoreFixture.self, from: Data(singleLayoutJSON.utf8)).fences[0]
        XCTAssertEqual(fence.spaces, .all)
        var current = fence
        current.spaces = .current
        let decoded = try JSONDecoder().decode(Fence.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(decoded.spaces, .current)
    }

    private struct FenceStoreFixture: Decodable { var fences: [Fence] }

    // MARK: Login item

    func testOnlyAnInstalledCopyIsALoginItem() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(LoginItem.isInstalled(home.appendingPathComponent("Applications/Clutter Buster.app")))
        XCTAssertTrue(LoginItem.isInstalled(URL(fileURLWithPath: "/Applications/Clutter Buster.app")))
        XCTAssertFalse(LoginItem.isInstalled(home.appendingPathComponent("Projects/ClutterBuster/build/Clutter Buster.app")))
        XCTAssertFalse(LoginItem.isInstalled(URL(fileURLWithPath: "/Users/someone/Projects/ClutterBuster/.build/release")))
    }
}
