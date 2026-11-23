import CoreGraphics
import XCTest
@testable import ClutterBuster

@MainActor
final class UndoHistoryTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("UndoHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fence(_ title: String, x: CGFloat = 0) -> Fence {
        Fence(title: title, frame: CGRect(x: x, y: 100, width: 420, height: 300), color: .slate, iconsPerRow: 4)
    }

    // MARK: History

    func testKeepsTheLastTwentyAndDiscardsTheOldest() {
        let history = UndoHistory()
        XCTAssertEqual(history.limit, 20)
        var discarded: [Int] = []
        for number in 1...25 {
            history.record("Action \(number)", undo: {}, discard: { discarded.append(number) })
        }
        XCTAssertEqual(history.entries.count, 20)
        XCTAssertEqual(history.entries.first?.name, "Action 6")
        XCTAssertEqual(history.last?.name, "Action 25")
        XCTAssertEqual(discarded, [1, 2, 3, 4, 5], "each entry that drops off the end is discarded, oldest first")
    }

    func testUndoesNewestFirst() {
        let history = UndoHistory()
        var undone: [String] = []
        for name in ["A", "B", "C"] {
            history.record(name, undo: { undone.append(name) })
        }
        XCTAssertEqual(history.menuTitle, "Undo C")
        XCTAssertEqual(history.undoLast()?.name, "C")
        XCTAssertEqual(history.undoLast()?.name, "B")
        XCTAssertEqual(history.menuTitle, "Undo A")
        XCTAssertEqual(history.undoLast()?.name, "A")
        XCTAssertNil(history.undoLast(), "nothing left to undo")
        XCTAssertEqual(undone, ["C", "B", "A"])
        XCTAssertEqual(history.menuTitle, "Undo")
    }

    func testUndoingAnOlderEntryLeavesTheRest() {
        let history = UndoHistory()
        var undone: [String] = []
        let first = history.record("A", undo: { undone.append("A") })!
        history.record("B", undo: { undone.append("B") })
        XCTAssertTrue(history.undo(first.id))
        XCTAssertFalse(history.undo(first.id), "an entry is undone once")
        XCTAssertEqual(undone, ["A"])
        XCTAssertEqual(history.entries.map(\.name), ["B"])
    }

    func testUndoneEntriesAreNotDiscarded() {
        let history = UndoHistory(limit: 2)
        var discarded: [String] = []
        history.record("A", undo: {}, discard: { discarded.append("A") })
        history.undoLast()
        history.record("B", undo: {}, discard: { discarded.append("B") })
        history.record("C", undo: {}, discard: { discarded.append("C") })
        XCTAssertEqual(discarded, [], "A was undone, so it isn't discarded later; B and C still fit")
        history.record("D", undo: {}, discard: { discarded.append("D") })
        XCTAssertEqual(discarded, ["B"])
    }

    func testRemoveAllDiscardsEverything() {
        let history = UndoHistory()
        var discarded: [String] = []
        for name in ["A", "B"] { history.record(name, undo: {}, discard: { discarded.append(name) }) }
        history.removeAll()
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertEqual(discarded, ["A", "B"])
    }

    func testNothingIsRecordedWhileUndoing() {
        let history = UndoHistory()
        history.record("A", undo: { history.record("side effect", undo: {}) })
        history.undoLast()
        XCTAssertTrue(history.entries.isEmpty)
    }

    // MARK: Fences

    func testDeletedFenceGoesBackInItsPlaceWithItsOtherLayoutFrames() throws {
        let store = FenceStore(fileURL: directory.appendingPathComponent("layout.json"))
        let screen = ScreenInfo(id: "A", name: nil, frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130))
        let other = ScreenInfo(id: "B", name: nil, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415))
        for (index, title) in ["One", "Two", "Three"].enumerated() { store.add(fence(title, x: CGFloat(index) * 450)) }
        store.useDisplayLayout("A", screens: [screen])
        store.useDisplayLayout("B", screens: [other])
        var two = try XCTUnwrap(store.fences.first { $0.title == "Two" })
        store.update(two.id) { $0.frame.origin.x = 1900 }
        store.useDisplayLayout("A", screens: [screen])
        two = try XCTUnwrap(store.fence(two.id))
        two.tabs.append(FenceTab(name: "Second"))
        two.selectedTabID = two.tabs[1].id
        two.textScale = 1.3
        two.cornerArt = .custom(CustomCornerArt.fileName(for: two.id))
        store.update(two.id) { $0 = two }

        let index = try XCTUnwrap(store.fences.firstIndex { $0.id == two.id })
        let frames = store.savedFrames(of: two.id)
        XCTAssertEqual(frames["B"]?.minX, 1900)
        store.remove(two.id)
        XCTAssertNil(store.displayLayouts["B"]?.frames[two.id.uuidString])

        store.insert(two, at: index, savedFrames: frames)
        XCTAssertEqual(store.fences.map(\.title), ["One", "Two", "Three"])
        let back = try XCTUnwrap(store.fence(two.id))
        XCTAssertEqual(back.tabs.map(\.name), ["General", "Second"])
        XCTAssertEqual(back.currentTab.name, "Second")
        XCTAssertEqual(back.textScale, 1.3)
        XCTAssertEqual(back.cornerArt, two.cornerArt)
        XCTAssertEqual(store.displayLayouts["B"]?.frames[two.id.uuidString]?.minX, 1900, "its frame for the other displays is back")
        store.useDisplayLayout("B", screens: [other])
        XCTAssertEqual(store.fence(two.id)?.frame.minX, 1900)

        store.insert(two, at: 0)
        XCTAssertEqual(store.fences.count, 3, "a fence that's back already isn't added twice")
    }

    func testDeletedLastFenceGoesBackAtTheEnd() {
        let store = FenceStore(fileURL: directory.appendingPathComponent("layout.json"))
        let fences = ["One", "Two"].map { fence($0) }
        fences.forEach(store.add)
        store.remove(fences[1].id)
        store.insert(fences[1], at: 1)
        XCTAssertEqual(store.fences.map(\.title), ["One", "Two"])
    }

    // MARK: Tabs

    func testDeletedTabGoesBackInItsPlaceWithItsItems() throws {
        var fence = fence("Tabs")
        fence.tabs = [FenceTab(name: "General"), FenceTab(name: "Middle"), FenceTab(name: "Last")]
        let middle = fence.tabs[1].id
        fence.items = [
            FenceItem(path: "/tmp/a", tabID: fence.tabs[0].id),
            FenceItem(path: "/tmp/b", tabID: middle),
            FenceItem(path: "/tmp/c", tabID: fence.tabs[2].id),
            FenceItem(path: "/tmp/d", tabID: middle),
        ]
        fence.selectedTabID = middle
        let before = fence

        let removed = try XCTUnwrap(fence.removeTab(middle))
        XCTAssertEqual(fence.tabs.map(\.name), ["General", "Last"])
        XCTAssertEqual(fence.items(in: fence.tabs[0].id).map(\.path), ["/tmp/a", "/tmp/b", "/tmp/d"])
        XCTAssertEqual(fence.currentTab.name, "General")
        XCTAssertEqual(removed.index, 1)

        XCTAssertTrue(fence.restoreTab(removed))
        XCTAssertEqual(fence.tabs, before.tabs)
        XCTAssertEqual(fence.items.map(\.tabID), before.items.map(\.tabID))
        XCTAssertEqual(fence.selectedTabID, middle)
        XCTAssertFalse(fence.restoreTab(removed), "a tab that's back already isn't added twice")
    }

    func testDeletedStickyTabKeepsItsNoteAndPaper() throws {
        var fence = fence("Sticky")
        fence.changeStyle(to: .stickyNote)
        fence.tabs.append(FenceTab(name: "Note 2", note: "- [ ] eggs\n- [x] milk"))
        fence.tabs[1].paper = .color(.pink)
        let tabID = fence.tabs[1].id
        let removed = try XCTUnwrap(fence.removeTab(tabID))
        XCTAssertNil(fence.removeTab(fence.tabs[0].id), "the last tab stays")
        fence.restoreTab(removed)
        XCTAssertEqual(fence.tabs.last?.id, tabID)
        XCTAssertEqual(fence.note(in: tabID), "- [ ] eggs\n- [x] milk")
        XCTAssertEqual(fence.tabs.last?.paper, .color(.pink))
    }

    // MARK: Items

    func testRemovedItemGoesBackInItsPlaceAndTab() {
        var fence = fence("Items")
        fence.tabs.append(FenceTab(name: "Other"))
        let other = fence.tabs[1].id
        fence.items = ["a", "b", "c"].map { FenceItem(path: "/tmp/\($0)", tabID: other) }
        let removed = fence.items.remove(at: 1)
        fence.insertItem(removed, at: 1)
        XCTAssertEqual(fence.items.map(\.path), ["/tmp/a", "/tmp/b", "/tmp/c"])
        XCTAssertEqual(fence.items[1].tabID, other)

        fence.items.remove(at: 1)
        fence.tabs.removeLast()
        fence.insertItem(removed, at: 10)
        XCTAssertEqual(fence.items.last?.path, "/tmp/b", "past the end goes last")
        XCTAssertEqual(fence.items.last?.tabID, fence.tabs[0].id, "with its tab gone it goes in the first")
    }
}
