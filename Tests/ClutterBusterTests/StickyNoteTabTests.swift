import XCTest
@testable import ClutterBuster

final class StickyNoteTabTests: XCTestCase {
    /// A sticky note saved before sticky notes had tabs: its note is on the fence, and its
    /// only tab, never shown, is "General".
    private func legacySticky(note: String, paper: String = "blue") -> String {
        """
        {
          "color" : "slate", "frame" : [[1200, 600], [280, 300]], "iconsPerRow" : 4,
          "id" : "B5F388D1-3E27-4111-B9EA-58E130AE4093", "title" : "Sticky Note",
          "items" : [], "isCollapsed" : false, "opacity" : 1, "spaces" : "all",
          "style" : "stickyNote", "note" : \(String(data: try! JSONEncoder().encode(note), encoding: .utf8)!), "paper" : "\(paper)",
          "tabs" : [ { "id" : "7A3E8F0C-1111-4E2B-9C1D-0A1B2C3D4E5F", "name" : "General", "sort" : { "ascending" : true, "key" : "manual" } } ],
          "tabRows" : 1, "tabsCollapsed" : false, "textScale" : 1
        }
        """
    }

    private func sticky(_ title: String = "CB TEST Sticky Tabs") -> Fence {
        var fence = Fence(title: title, frame: CGRect(x: 0, y: 0, width: 280, height: 300), color: .slate, iconsPerRow: 4)
        fence.changeStyle(to: .stickyNote)
        return fence
    }

    // MARK: Migration

    func testLegacyNoteMovesIntoTheFirstTab() throws {
        let fence = try JSONDecoder().decode(Fence.self, from: Data(legacySticky(note: "Groceries\n- [ ] eggs").utf8))
        XCTAssertEqual(fence.tabs.count, 1)
        XCTAssertEqual(fence.tabs[0].note, "Groceries\n- [ ] eggs")
        XCTAssertEqual(fence.tabs[0].name, "Note", "the never-shown General tab is renamed")
        XCTAssertEqual(fence.tabs[0].id.uuidString, "7A3E8F0C-1111-4E2B-9C1D-0A1B2C3D4E5F")
        XCTAssertEqual(fence.paper, .blue)
        XCTAssertNil(fence.tabs[0].paper)
    }

    /// The user's own sticky note, whose text is empty, loads with that empty text in its first tab.
    func testUsersEmptyStickyNoteLoads() throws {
        let fence = try JSONDecoder().decode(Fence.self, from: Data(legacySticky(note: "").utf8))
        XCTAssertEqual(fence.id.uuidString, "B5F388D1-3E27-4111-B9EA-58E130AE4093")
        XCTAssertEqual(fence.title, "Sticky Note")
        XCTAssertEqual(fence.tabs.map(\.name), ["Note"])
        XCTAssertEqual(fence.tabs[0].note, "")
        XCTAssertEqual(fence.currentTab.id, fence.tabs[0].id)
        XCTAssertEqual(fence.currentPaper, .blue)
    }

    func testMigratedNoteRoundTripsAndStaysReadableWithoutTabs() throws {
        var fence = try JSONDecoder().decode(Fence.self, from: Data(legacySticky(note: "first").utf8))
        let second = FenceTab(name: fence.nextTabName(), note: "second")
        fence.tabs.append(second)
        let data = try JSONEncoder().encode(fence)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["note"] as? String, "first", "versions without tabs read the first tab's note")

        let decoded = try JSONDecoder().decode(Fence.self, from: data)
        XCTAssertEqual(decoded.tabs.map(\.name), ["Note", "Note 2"])
        XCTAssertEqual(decoded.tabs.map(\.note), ["first", "second"])
    }

    /// Tab notes, once there, win over a stale fence note, and a layout saved by a version
    /// without tabs (which drops tab notes) gets its note back in the first tab.
    func testMigrationOnlyWhenNoTabHasANote() throws {
        var fence = sticky()
        fence.setNote("tab text", in: fence.tabs[0].id)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fence)) as? [String: Any])
        json["note"] = "stale"
        var decoded = try JSONDecoder().decode(Fence.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.tabs[0].note, "tab text")

        var tabs = try XCTUnwrap(json["tabs"] as? [[String: Any]])
        tabs[0]["note"] = nil
        tabs.append(["id": UUID().uuidString, "name": "Note 2"])
        json["tabs"] = tabs
        json["note"] = "kept by an older version"
        decoded = try JSONDecoder().decode(Fence.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.tabs.map(\.note), ["kept by an older version", nil])
        XCTAssertEqual(decoded.tabs.map(\.name), ["Note", "Note 2"], "names of tabs the user made stay")
    }

    /// A layout from before sticky notes had tabs, with item fences and a sticky note, loads
    /// with every item, tab and the note in place.
    @MainActor
    func testOldLayoutLoads() throws {
        let item = """
        { "color" : "slate", "frame" : [[100, 200], [420, 300]], "iconsPerRow" : 4,
          "id" : "654F643E-6FE1-4608-B4DB-C585DB56368B", "title" : "AI Tools",
          "items" : [ { "addedAt" : 785000000, "id" : "0F9255D9-A38D-4CA1-B79D-F85383F20A76", "kind" : "file",
                        "path" : "/Users/someone/Desktop/Cursor.app", "tabID" : "95E2C9D5-A677-4B87-AA3A-F5E2CA33F28E" } ],
          "tabs" : [ { "id" : "95E2C9D5-A677-4B87-AA3A-F5E2CA33F28E", "name" : "General" },
                     { "id" : "A5E2C9D5-A677-4B87-AA3A-F5E2CA33F28E", "name" : "Chat Bots" } ],
          "style" : "items", "note" : "" }
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StickyNoteTabTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layout.json")
        try Data("{ \"fences\" : [ \(item), \(legacySticky(note: "- [x] call mum")) ] }".utf8).write(to: url)

        let store = FenceStore(fileURL: url)
        XCTAssertEqual(store.fences.count, 2)
        let files = try XCTUnwrap(store.fences.first { $0.title == "AI Tools" })
        XCTAssertEqual(files.tabs.map(\.name), ["General", "Chat Bots"])
        XCTAssertEqual(files.tabs.map(\.note), [nil, nil])
        XCTAssertEqual(files.items.count, 1)
        let note = try XCTUnwrap(store.fences.first { $0.isStickyNote })
        XCTAssertEqual(note.tabs.map(\.note), ["- [x] call mum"])
        XCTAssertTrue(note.items.isEmpty)

        store.saveNow()
        let reloaded = FenceStore(fileURL: url)
        XCTAssertEqual(reloaded.fences.first { $0.isStickyNote }?.tabs.map(\.note), ["- [x] call mum"])
        XCTAssertEqual(reloaded.fences.first { $0.title == "AI Tools" }?.items.count, 1)
    }

    // MARK: Naming

    func testDefaultTabNames() {
        var note = sticky()
        XCTAssertEqual(note.tabs.map(\.name), ["Note"])
        XCTAssertEqual(note.tabs[0].note, "", "a sticky note's tabs always have a note")
        XCTAssertEqual(note.nextTabName(), "Note 2")
        note.tabs.append(FenceTab(name: note.nextTabName(), note: ""))
        XCTAssertEqual(note.nextTabName(), "Note 3")
        note.tabs.append(FenceTab(name: "Note 4", note: ""))
        XCTAssertEqual(note.nextTabName(), "Note 5", "names already taken are skipped")

        var files = Fence(title: "Files", frame: .zero, color: .slate, iconsPerRow: 4)
        XCTAssertEqual(files.tabs.map(\.name), ["General"])
        XCTAssertEqual(files.nextTabName(), "Tab 2")

        files.changeStyle(to: .stickyNote)
        XCTAssertEqual(files.tabs.map(\.name), ["Note"])
        files.changeStyle(to: .items)
        XCTAssertEqual(files.tabs.map(\.name), ["General"])

        var renamed = sticky()
        renamed.tabs[0].name = "Shopping"
        renamed.changeStyle(to: .items)
        XCTAssertEqual(renamed.tabs.map(\.name), ["Shopping"], "a tab the user named keeps its name")
    }

    // MARK: Paper

    func testTabPaperFallsBackToTheFence() throws {
        var fence = sticky()
        fence.paper = .yellow
        fence.tabs.append(FenceTab(name: "Note 2", note: ""))
        fence.tabs.append(FenceTab(name: "Note 3", note: ""))
        fence.tabs[1].paper = .color(.pink)
        fence.tabs[2].paper = .theme
        XCTAssertEqual(fence.paper(for: fence.tabs[0]), .yellow, "no paper of its own is the fence's")
        XCTAssertEqual(fence.paper(for: fence.tabs[1]), .pink)
        XCTAssertNil(fence.paper(for: fence.tabs[2]), "Use Theme even on a fence with paper")

        fence.paper = nil
        XCTAssertNil(fence.paper(for: fence.tabs[0]))
        XCTAssertEqual(fence.paper(for: fence.tabs[1]), .pink, "a tab's own paper on a fence using its theme")

        // The fence is drawn in the paper of the tab shown.
        fence.theme = .space
        XCTAssertEqual(ThemeStyle.resolve(fence, global: .classic).theme, .space)
        fence.selectedTabID = fence.tabs[1].id
        XCTAssertTrue(ThemeStyle.resolve(fence, global: .classic).isLight)
        XCTAssertNil(ThemeStyle.resolve(fence, global: .classic).cornerArt)

        // Item fences never use paper.
        var files = Fence(title: "Files", frame: .zero, color: .slate, iconsPerRow: 4)
        files.paper = .yellow
        files.tabs[0].paper = .color(.blue)
        XCTAssertNil(files.currentPaper)

        let decoded = try JSONDecoder().decode(Fence.self, from: JSONEncoder().encode(fence))
        XCTAssertEqual(decoded.tabs.map(\.paper), [nil, .color(.pink), .theme])

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fence)) as? [String: Any])
        var tabs = try XCTUnwrap(json["tabs"] as? [[String: Any]])
        XCTAssertEqual(tabs.map { $0["paper"] as? String }, [nil, "pink", "theme"])
        tabs[1]["paper"] = "plaid"
        json["tabs"] = tabs
        let odd = try JSONDecoder().decode(Fence.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(odd.tabs[1].paper, "an unknown paper goes back to the fence's")
    }

    // MARK: Deleting

    func testOnlyTabsWithTextAskBeforeDeleting() {
        var fence = sticky()
        fence.tabs.append(FenceTab(name: "Note 2", note: "keep me"))
        fence.tabs.append(FenceTab(name: "Note 3", note: " \n "))
        XCTAssertFalse(FenceCoordinator.deletingTabNeedsConfirmation(fence, fence.tabs[0].id))
        XCTAssertTrue(FenceCoordinator.deletingTabNeedsConfirmation(fence, fence.tabs[1].id))
        XCTAssertFalse(FenceCoordinator.deletingTabNeedsConfirmation(fence, fence.tabs[2].id), "spaces alone are empty")
        let files = Fence(title: "Files", frame: .zero, color: .slate, iconsPerRow: 4)
        XCTAssertFalse(FenceCoordinator.deletingTabNeedsConfirmation(files, files.tabs[0].id))
    }

    // MARK: Search

    func testSearchResultsCarryTheTab() throws {
        var fence = sticky("Sticky Note")
        fence.setNote("Milk\nbread", in: fence.tabs[0].id)
        fence.tabs.append(FenceTab(name: "Note 2", note: "- [ ] oat milk\nnothing here"))
        fence.tabs[1].paper = .color(.green)
        let results = SearchResult.noteResults("milk", in: fence)
        XCTAssertEqual(results.map(\.name), ["Milk", "oat milk"])
        XCTAssertEqual(results.map(\.subtitle), [
            "Sticky note \u{00B7} \u{201C}Sticky Note\u{201D} \u{203A} Note",
            "Sticky note \u{00B7} \u{201C}Sticky Note\u{201D} \u{203A} Note 2",
        ])
        let match = try XCTUnwrap(results[1].noteMatch)
        XCTAssertEqual(match.tabID, fence.tabs[1].id)
        XCTAssertEqual(match.fenceID, fence.id)
        XCTAssertEqual(match.line, 0)
        XCTAssertEqual(match.range, NSRange(location: 10, length: 4))
        XCTAssertEqual(Set(results.map(\.id)).count, 2, "the same line of two tabs is two results")
        XCTAssertTrue(SearchResult.noteResults("milk", in: Fence(title: "Files", frame: .zero, color: .slate, iconsPerRow: 4)).isEmpty)
    }
}
