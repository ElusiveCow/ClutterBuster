import XCTest
@testable import ClutterBuster

final class StickyNoteTests: XCTestCase {
    private func applying(_ edit: NoteEdit?, to text: String) -> String {
        guard let edit else { return text }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    // MARK: Decoding

    /// A fence as saved before sticky notes, like the five in the user's layout.
    private let oldFence = """
    {
      "color" : "slate", "frame" : [[100, 200], [420, 300]], "iconsPerRow" : 4,
      "id" : "654F643E-6FE1-4608-B4DB-C585DB56368B", "title" : "AI Tools", "textScale" : 1.2,
      "items" : [ { "addedAt" : 785000000, "id" : "0F9255D9-A38D-4CA1-B79D-F85383F20A76", "kind" : "file",
                    "path" : "/Users/someone/Desktop/Cursor.app", "tabID" : "95E2C9D5-A677-4B87-AA3A-F5E2CA33F28E" } ],
      "tabs" : [ { "id" : "95E2C9D5-A677-4B87-AA3A-F5E2CA33F28E", "name" : "General" } ],
      "spaces" : "all", "theme" : "space"
    }
    """

    func testOldFenceDecodesAsItems() throws {
        let fence = try JSONDecoder().decode(Fence.self, from: Data(oldFence.utf8))
        XCTAssertEqual(fence.style, .items)
        XCTAssertEqual(fence.note, "")
        XCTAssertNil(fence.paper)
        XCTAssertTrue(fence.holdsItems)
        XCTAssertFalse(fence.isStickyNote)
        XCTAssertEqual(fence.items.count, 1)
        XCTAssertEqual(fence.theme, .space)
        XCTAssertEqual(fence.textScale, 1.2, accuracy: 0.001)
    }

    func testStickyNoteRoundTrips() throws {
        var fence = Fence(title: "CB TEST Sticky", frame: CGRect(x: 0, y: 0, width: 280, height: 300), color: .slate, iconsPerRow: 4)
        fence.style = .stickyNote
        fence.paper = .pink
        fence.note = "Groceries\n- [ ] eggs\n- [x] milk"
        let decoded = try JSONDecoder().decode(Fence.self, from: JSONEncoder().encode(fence))
        XCTAssertEqual(decoded.style, .stickyNote)
        XCTAssertEqual(decoded.paper, .pink)
        XCTAssertEqual(decoded.note, fence.note)

        fence.paper = nil
        XCTAssertNil(try JSONDecoder().decode(Fence.self, from: JSONEncoder().encode(fence)).paper, "no paper is Use Theme")
    }

    func testUnknownStyleAndPaperFallBack() throws {
        var json = oldFence.replacingOccurrences(of: "\"spaces\" : \"all\"", with: "\"spaces\" : \"all\", \"style\" : \"whiteboard\"")
        XCTAssertEqual(try JSONDecoder().decode(Fence.self, from: Data(json.utf8)).style, .items)
        json = oldFence.replacingOccurrences(of: "\"spaces\" : \"all\"", with: "\"spaces\" : \"all\", \"style\" : \"stickyNote\", \"paper\" : \"plaid\", \"note\" : \"hi\"")
        let fence = try JSONDecoder().decode(Fence.self, from: Data(json.utf8))
        XCTAssertEqual(fence.style, .stickyNote)
        XCTAssertNil(fence.paper)
        XCTAssertEqual(fence.note, "hi")
    }

    // MARK: Files stay out

    func testStickyNotesNeverHoldDesktopFilesOrTakeRules() {
        var fence = Fence(title: "Note", frame: .zero, color: .slate, iconsPerRow: 4)
        fence.style = .stickyNote
        // Even a stray Desktop item, which can't be added, doesn't pin it to every Space.
        fence.items = [FenceItem(path: DesktopIconService.desktopURL.appendingPathComponent("Report.pdf").path)]
        XCTAssertFalse(fence.holdsDesktopFiles)
        XCTAssertFalse(fence.holdsItems)
        fence.spaces = .current
        XCTAssertFalse(fence.showsOnAllSpaces, "This Space Only is allowed")

        let rule = AutoFileRule(kind: .pdf, fenceID: fence.id)
        XCTAssertEqual(rule.problem(in: [fence]), "Its fence is a sticky note")
    }

    func testPaperStyleAndThemeStyle() {
        var fence = Fence(title: "Note", frame: .zero, color: .slate, iconsPerRow: 4)
        fence.theme = .space
        fence.style = .stickyNote
        fence.paper = .yellow
        let paper = ThemeStyle.resolve(fence, global: .classic)
        XCTAssertTrue(paper.isLight)
        XCTAssertNil(paper.cornerArt)
        fence.paper = nil
        XCTAssertEqual(ThemeStyle.resolve(fence, global: .classic).theme, .space)
        XCTAssertEqual(ThemeStyle.resolve(fence, global: .classic).cornerArt, "space_corner")
    }

    // MARK: Parsing and serializing

    func testChecklistParsing() {
        let lines = NoteLine.parse("Groceries\n- [ ] eggs\n- [x] milk\n- [X] tea\n-[ ] not one\n- [ ]\n")
        XCTAssertEqual(lines, [
            .text("Groceries"),
            .item(checked: false, text: "eggs"),
            .item(checked: true, text: "milk"),
            .item(checked: true, text: "tea"),
            .text("-[ ] not one"),
            .text("- [ ]"),
            .text(""),
        ])
        XCTAssertEqual(NoteLine.parse(""), [.text("")])
        XCTAssertEqual(NoteLine.parse("- [ ] "), [.item(checked: false, text: "")])
    }

    func testChecklistSerializing() {
        let note = "Groceries\n- [ ] eggs\n- [x] milk\n\nCall dentist"
        XCTAssertEqual(NoteLine.serialize(NoteLine.parse(note)), note)
        XCTAssertEqual(NoteLine.serialize([.item(checked: true, text: "done"), .text("plain"), .item(checked: false, text: "")]), "- [x] done\nplain\n- [ ] ")
        XCTAssertEqual(NoteLine.serialize(NoteLine.parse("- [X] tea")), "- [x] tea", "a capital X is saved as x")
    }

    // MARK: Return

    func testReturnOnItemStartsAnother() {
        let text = "- [ ] milk"
        let edit = NoteEditing.returnEdit(in: text as NSString, selection: caret(10))
        XCTAssertEqual(edit, NoteEdit(range: caret(10), replacement: "\n- [ ] ", selection: caret(17)))
        XCTAssertEqual(applying(edit, to: text), "- [ ] milk\n- [ ] ")
    }

    func testReturnInsideItemSplitsIt() {
        let text = "- [x] milkshake"
        let edit = NoteEditing.returnEdit(in: text as NSString, selection: caret(10))
        XCTAssertEqual(applying(edit, to: text), "- [x] milk\n- [ ] shake", "the new item starts unticked")
        // At the start of an item's text, an empty item goes in above.
        XCTAssertEqual(applying(NoteEditing.returnEdit(in: "- [ ] milk", selection: caret(6)), to: "- [ ] milk"), "- [ ] \n- [ ] milk")
    }

    func testReturnOnEmptyItemEndsTheList() {
        let text = "- [ ] milk\n- [ ] "
        let edit = NoteEditing.returnEdit(in: text as NSString, selection: caret(17))
        XCTAssertEqual(edit, NoteEdit(range: NSRange(location: 11, length: 6), replacement: "", selection: caret(11)))
        XCTAssertEqual(applying(edit, to: text), "- [ ] milk\n")
        // Spaces alone still count as empty.
        XCTAssertEqual(applying(NoteEditing.returnEdit(in: "- [ ]   ", selection: caret(8)), to: "- [ ]   "), "")
    }

    func testReturnOnPlainLineIsLeftAlone() {
        XCTAssertNil(NoteEditing.returnEdit(in: "milk", selection: caret(4)))
        XCTAssertNil(NoteEditing.returnEdit(in: "- [ ] a\nb", selection: caret(9)))
        XCTAssertNil(NoteEditing.returnEdit(in: "- [ ] a\nb", selection: NSRange(location: 6, length: 3)), "a selection across lines")
    }

    // MARK: Delete

    func testDeleteRemovesTheBoxNotTheText() {
        let text = "a\n- [ ] milk"
        let edit = NoteEditing.deleteBackwardEdit(in: text as NSString, selection: caret(8))
        XCTAssertEqual(edit?.selection, caret(2))
        XCTAssertEqual(applying(edit, to: text), "a\nmilk")
        XCTAssertNil(NoteEditing.deleteBackwardEdit(in: text as NSString, selection: caret(9)))
        XCTAssertNil(NoteEditing.deleteBackwardEdit(in: "milk", selection: caret(0)))
    }

    func testForwardDeleteJoinsWithoutTheMarker() {
        let text = "a\n- [ ] milk"
        XCTAssertEqual(applying(NoteEditing.deleteForwardEdit(in: text as NSString, selection: caret(1)), to: text), "amilk")
        XCTAssertNil(NoteEditing.deleteForwardEdit(in: "a\nb", selection: caret(1)))
    }

    // MARK: Toggling

    func testToggleChecklistOnOneLine() {
        var edit = NoteEditing.toggleChecklistEdit(in: "milk", selection: caret(2))
        XCTAssertEqual(applying(edit, to: "milk"), "- [ ] milk")
        XCTAssertEqual(edit.selection, caret(8), "the caret stays in the same spot of the text")

        edit = NoteEditing.toggleChecklistEdit(in: "- [x] milk", selection: caret(8))
        XCTAssertEqual(applying(edit, to: "- [x] milk"), "milk")
        XCTAssertEqual(edit.selection, caret(2))

        edit = NoteEditing.toggleChecklistEdit(in: "", selection: caret(0))
        XCTAssertEqual(applying(edit, to: ""), "- [ ] ", "an empty line becomes an empty item")
        XCTAssertEqual(edit.selection, caret(6))
    }

    func testToggleChecklistOnSelectedLines() {
        let text = "eggs\n\nmilk\ntea"
        let all = NSRange(location: 0, length: (text as NSString).length)
        let on = NoteEditing.toggleChecklistEdit(in: text as NSString, selection: all)
        let listed = applying(on, to: text)
        XCTAssertEqual(listed, "- [ ] eggs\n\n- [ ] milk\n- [ ] tea", "blank lines stay blank")

        let off = NoteEditing.toggleChecklistEdit(in: listed as NSString, selection: on.selection!)
        XCTAssertEqual(applying(off, to: listed), text, "toggling again undoes it")

        // Some items already: the rest join them; ticked ones stay ticked.
        let mixed = "- [x] eggs\nmilk"
        XCTAssertEqual(applying(NoteEditing.toggleChecklistEdit(in: mixed as NSString, selection: NSRange(location: 3, length: 10)), to: mixed), "- [x] eggs\n- [ ] milk")

        // A selection ending at the start of a line leaves that line out.
        XCTAssertEqual(applying(NoteEditing.toggleChecklistEdit(in: "a\nb", selection: NSRange(location: 0, length: 2)), to: "a\nb"), "- [ ] a\nb")
    }

    func testTickingABox() {
        let text = "x\n- [ ] milk"
        let tick = NoteEditing.toggleCheckEdit(in: text as NSString, lineStart: 2)
        XCTAssertEqual(tick, NoteEdit(range: NSRange(location: 5, length: 1), replacement: "x", selection: nil))
        let ticked = applying(tick, to: text)
        XCTAssertEqual(ticked, "x\n- [x] milk")
        XCTAssertEqual(applying(NoteEditing.toggleCheckEdit(in: ticked as NSString, lineStart: 2), to: ticked), text)
        XCTAssertNil(NoteEditing.toggleCheckEdit(in: text as NSString, lineStart: 0), "a plain line has no box")
        XCTAssertNil(NoteEditing.toggleCheckEdit(in: text as NSString, lineStart: 3), "not the start of a line")
    }

    // MARK: The caret

    func testCaretNeverSitsInsideAMarker() {
        let text = "x\n- [ ] milk" as NSString
        XCTAssertEqual(NoteEditing.allowedCaret(2, from: nil, in: text), 8, "before the box goes to the text")
        XCTAssertEqual(NoteEditing.allowedCaret(5, from: 0, in: text), 8)
        XCTAssertEqual(NoteEditing.allowedCaret(7, from: 8, in: text), 1, "left from the text goes to the line above")
        XCTAssertEqual(NoteEditing.allowedCaret(10, from: 8, in: text), 10)
        XCTAssertEqual(NoteEditing.allowedCaret(1, from: 8, in: text), 1)
        XCTAssertEqual(NoteEditing.allowedCaret(5, from: 6, in: "- [ ] a"), 6, "the first line has nowhere above to go")
    }

    // MARK: Search

    func testSearchFindsEachMatchingLine() {
        let id = UUID()
        let note = "Groceries\n- [x] Milk\nmilkshake\nnothing"
        let found = NoteMatch.find("milk", in: note, fenceID: id)
        XCTAssertEqual(found.map(\.text), ["Milk", "milkshake"])
        XCTAssertEqual(found.map(\.match.line), [1, 2])
        XCTAssertEqual(found[0].match.range, NSRange(location: 16, length: 4))
        XCTAssertEqual(found[1].match.range, NSRange(location: 21, length: 4))
        XCTAssertTrue(NoteMatch.find("[x]", in: "- [x] a", fenceID: id).isEmpty, "markers aren't searched")
        XCTAssertTrue(NoteMatch.find("  ", in: note, fenceID: id).isEmpty)
    }
}

@MainActor
final class StickyNoteLayoutTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StickyNoteLayoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Display layouts keep only where fences sit, so a note and its paper are the same with
    /// any displays, and survive saving and loading.
    func testStickyNoteKeepsItsNoteAcrossDisplayLayouts() {
        let url = directory.appendingPathComponent("layout.json")
        let screen = ScreenInfo(id: "A", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130))
        let store = FenceStore(fileURL: url)
        var fence = Fence(title: "CB TEST Sticky", frame: CGRect(x: 100, y: 100, width: 280, height: 300), color: .slate, iconsPerRow: 4)
        fence.style = .stickyNote
        fence.paper = .blue
        fence.note = "- [ ] one"
        store.add(fence)
        store.useDisplayLayout("A", screens: [screen])
        store.useDisplayLayout("B", screens: [screen])
        store.update(fence.id) {
            $0.frame.origin.x = 600
            $0.note = "- [x] one\ntwo"
        }
        store.useDisplayLayout("A", screens: [screen])
        XCTAssertEqual(store.fence(fence.id)?.frame.minX, 100, "layout A's position")
        XCTAssertEqual(store.fence(fence.id)?.note, "- [x] one\ntwo", "the note is the same in every layout")
        store.saveNow()

        let loaded = FenceStore(fileURL: url).fence(fence.id)
        XCTAssertEqual(loaded?.style, .stickyNote)
        XCTAssertEqual(loaded?.paper, .blue)
        XCTAssertEqual(loaded?.note, "- [x] one\ntwo")
    }
}
