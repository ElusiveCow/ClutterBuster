import XCTest
@testable import ClutterBuster

final class ItemKindTests: XCTestCase {
    // MARK: Decoding

    /// A fence saved before items had kinds, as in the layouts already on disk.
    private let oldLayoutFence = """
    {
      "color" : "slate",
      "frame" : [[100, 200], [420, 300]],
      "iconsPerRow" : 4,
      "id" : "654F643E-6FE1-4608-B4DB-C585DB56368B",
      "items" : [
        {
          "addedAt" : 785000000,
          "id" : "0F9255D9-A38D-4CA1-B79D-F85383F20A76",
          "originalDesktopPosition" : [120, 340],
          "path" : "/Users/someone/Desktop/Report.pdf",
          "tabID" : "95E2C9D5-A677-4B87-AA3A-F5E2CA33F28E"
        },
        {
          "addedAt" : 785000100,
          "id" : "30E1C1CC-25D7-4B10-8685-DEE73DB76ADE",
          "path" : "/Applications/Safari.app",
          "tabID" : "95E2C9D5-A677-4B87-AA3A-F5E2CA33F28E"
        }
      ],
      "tabs" : [ { "id" : "95E2C9D5-A677-4B87-AA3A-F5E2CA33F28E", "name" : "General", "sort" : { "ascending" : true, "key" : "manual" } } ],
      "title" : "AI Tools"
    }
    """

    func testOldItemsDecodeAsFiles() throws {
        let fence = try JSONDecoder().decode(Fence.self, from: Data(oldLayoutFence.utf8))
        XCTAssertEqual(fence.title, "AI Tools")
        XCTAssertEqual(fence.items.count, 2)
        XCTAssertEqual(fence.items.map(\.kind), [.file, .file])
        XCTAssertEqual(fence.items[0].path, "/Users/someone/Desktop/Report.pdf")
        XCTAssertEqual(fence.items[0].originalDesktopPosition, CGPoint(x: 120, y: 340))
        XCTAssertEqual(fence.items[0].id.uuidString, "0F9255D9-A38D-4CA1-B79D-F85383F20A76")
        XCTAssertEqual(fence.items[1].tabID, fence.tabs[0].id)
        XCTAssertNil(fence.items[0].title)
        XCTAssertNil(fence.items[0].link)
        XCTAssertNil(fence.items[0].text)
    }

    func testNewKindsRoundTrip() throws {
        var fence = Fence(title: "Test", frame: CGRect(x: 0, y: 0, width: 300, height: 200), color: .slate, iconsPerRow: 4)
        let tab = fence.tabs[0].id
        fence.items = [
            FenceItem(path: "/tmp/a.txt", tabID: tab),
            .link(URL(string: "https://www.apple.com/mac/")!, title: "Mac - Apple", tabID: tab),
            .note("Buy milk\nand eggs", tabID: tab),
            .shortcut("Take a Break", tabID: tab),
        ]
        let data = try JSONEncoder().encode(fence)
        let decoded = try JSONDecoder().decode(Fence.self, from: data)
        XCTAssertEqual(decoded.items.map(\.kind), [.file, .link, .note, .shortcut])
        XCTAssertEqual(decoded.items[1].link, "https://www.apple.com/mac/")
        XCTAssertEqual(decoded.items[1].title, "Mac - Apple")
        XCTAssertEqual(decoded.items[2].text, "Buy milk\nand eggs")
        XCTAssertEqual(decoded.items[3].title, "Take a Break")
        XCTAssertEqual(decoded.items.map(\.id), fence.items.map(\.id))
    }

    func testUnknownKindFallsBackToFile() throws {
        let json = #"{"id":"0F9255D9-A38D-4CA1-B79D-F85383F20A76","kind":"hologram","path":"/tmp/x"}"#
        let item = try JSONDecoder().decode(FenceItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.path, "/tmp/x")
    }

    // MARK: Never on the Desktop

    func testOnlyFilesAreOnTheDesktop() {
        let desktop = DesktopIconService.desktopURL.appendingPathComponent("Report.pdf").path
        XCTAssertTrue(FenceItem(path: desktop).isOnDesktop)
        XCTAssertFalse(FenceItem(path: "/Applications/Safari.app").isOnDesktop)
        XCTAssertFalse(FenceItem.link(URL(string: "https://apple.com")!, title: nil, tabID: nil).isOnDesktop)
        XCTAssertFalse(FenceItem.note("hi", tabID: nil).isOnDesktop)
        XCTAssertFalse(FenceItem.shortcut("Take a Break", tabID: nil).isOnDesktop)
        // Even a non-file item that somehow has a Desktop path.
        var odd = FenceItem.note("hi", tabID: nil)
        odd.path = desktop
        XCTAssertFalse(odd.isOnDesktop)
    }

    func testInstalledAppsAreNeverMovedIntoFolders() {
        let folder = URL(fileURLWithPath: "/tmp/Somewhere", isDirectory: true)
        XCTAssertTrue(FolderDrop.isInstalledApp(URL(fileURLWithPath: "/Applications/Safari.app")))
        XCTAssertTrue(FolderDrop.isInstalledApp(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        XCTAssertFalse(FolderDrop.isInstalledApp(DesktopIconService.desktopURL.appendingPathComponent("Gmail.app")))
        XCTAssertFalse(FolderDrop.isInstalledApp(URL(fileURLWithPath: "/Applications/Utilities")))
        XCTAssertNotNil(FolderDrop.problem(putting: URL(fileURLWithPath: "/Applications/Safari.app"), into: folder))
    }

    // MARK: Names and search

    func testDisplayNames() {
        XCTAssertEqual(FenceItem.link(URL(string: "https://www.apple.com/mac/")!, title: nil, tabID: nil).displayName, "www.apple.com")
        XCTAssertEqual(FenceItem.link(URL(string: "https://apple.com")!, title: "  Apple  ", tabID: nil).displayName, "Apple")
        XCTAssertEqual(FenceItem.note("\n  Groceries \nmilk", tabID: nil).displayName, "Groceries")
        XCTAssertEqual(FenceItem.note("", tabID: nil).displayName, "Note")
        XCTAssertEqual(FenceItem.shortcut("Take a Break", tabID: nil).displayName, "Take a Break")
        XCTAssertEqual(FenceItem(path: "/tmp/Report.pdf").displayName, "Report.pdf")
    }

    func testSearchMatching() {
        let link = FenceItem.link(URL(string: "https://developer.apple.com/documentation/")!, title: "Apple Developer Documentation", tabID: nil)
        XCTAssertTrue(link.matches("developer"))
        XCTAssertTrue(link.matches("DOCUMENTATION"))
        XCTAssertTrue(link.matches("developer.apple.com"), "the address counts")
        XCTAssertFalse(link.matches("google"))

        let note = FenceItem.note("Call the dentist\nTuesday at 3", tabID: nil)
        XCTAssertTrue(note.matches("tuesday"), "any line of the text counts")
        XCTAssertTrue(note.matches("dentist"))
        XCTAssertFalse(note.matches("Wednesday"))

        let shortcut = FenceItem.shortcut("Take a Break", tabID: nil)
        XCTAssertTrue(shortcut.matches("break"))
        XCTAssertFalse(shortcut.matches("shazam"))

        XCTAssertTrue(FenceItem(path: "/tmp/Quarterly Report.pdf").matches("report"))
        XCTAssertFalse(FenceItem(path: "/tmp/Quarterly Report.pdf").matches("tmp"), "a file's folder doesn't count")
        XCTAssertFalse(note.matches("   "))
    }

    // MARK: Sorting

    @MainActor
    func testSortingHandlesEveryKind() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var file = FenceItem(path: "/tmp/does-not-exist/Banana.txt")
        file.addedAt = base
        var link = FenceItem.link(URL(string: "https://apple.com")!, title: "Cherry", tabID: nil)
        link.addedAt = base.addingTimeInterval(10)
        var note = FenceItem.note("Apple pie recipe", tabID: nil)
        note.addedAt = base.addingTimeInterval(20)
        note.editedAt = base.addingTimeInterval(100)
        var shortcut = FenceItem.shortcut("Date night", tabID: nil)
        shortcut.addedAt = base.addingTimeInterval(30)
        let items = [shortcut, note, link, file]

        func sorted(_ key: SortKey, ascending: Bool = true) -> [String] {
            var sort = TabSort()
            sort.key = key
            sort.ascending = ascending
            return sort.apply(to: items).map(\.displayName)
        }

        XCTAssertEqual(sorted(.manual), ["Date night", "Apple pie recipe", "Cherry", "Banana.txt"])
        XCTAssertEqual(sorted(.name), ["Apple pie recipe", "Banana.txt", "Cherry", "Date night"])
        XCTAssertEqual(sorted(.name, ascending: false), ["Date night", "Cherry", "Banana.txt", "Apple pie recipe"])
        XCTAssertEqual(sorted(.kind), ["Banana.txt", "Cherry", "Apple pie recipe", "Date night"], "files, links, notes, Shortcuts")
        XCTAssertEqual(sorted(.dateAdded), ["Banana.txt", "Cherry", "Apple pie recipe", "Date night"])
        // A missing file has no date; the note was edited after everything was added.
        XCTAssertEqual(sorted(.dateModified), ["Banana.txt", "Cherry", "Date night", "Apple pie recipe"])
        XCTAssertEqual(sorted(.size).last, "Apple pie recipe", "only a note has a size among these")
    }

    @MainActor
    func testKindSortsFilesByTypeThenNewKindsByName() {
        let items = [
            FenceItem.shortcut("B shortcut", tabID: nil),
            FenceItem.link(URL(string: "https://b.com")!, title: "B link", tabID: nil),
            FenceItem.shortcut("A shortcut", tabID: nil),
            FenceItem.link(URL(string: "https://a.com")!, title: "A link", tabID: nil),
        ]
        var sort = TabSort()
        sort.key = .kind
        XCTAssertEqual(sort.apply(to: items).map(\.displayName), ["A link", "B link", "A shortcut", "B shortcut"])
    }

    // MARK: Links

    func testWebAddressesFromText() {
        XCTAssertEqual(FenceItem.webURL(from: " https://www.apple.com/mac/ \n", strict: true)?.absoluteString, "https://www.apple.com/mac/")
        XCTAssertEqual(FenceItem.webURL(from: "www.apple.com", strict: true)?.absoluteString, "https://www.apple.com")
        XCTAssertNil(FenceItem.webURL(from: "apple.com", strict: true), "pasted text needs a scheme or www.")
        XCTAssertNil(FenceItem.webURL(from: "Report.pdf", strict: true))
        XCTAssertNil(FenceItem.webURL(from: "hello world", strict: false))
        XCTAssertNil(FenceItem.webURL(from: "file:///etc/hosts", strict: false))
        XCTAssertNil(FenceItem.webURL(from: "javascript:alert(1)", strict: false))
        XCTAssertNil(FenceItem.webURL(from: "someone@example.com", strict: false))
        XCTAssertEqual(FenceItem.webURL(from: "apple.com", strict: false)?.absoluteString, "https://apple.com")
        XCTAssertEqual(FenceItem.webURL(from: "apple.com/mac", strict: false)?.absoluteString, "https://apple.com/mac")
        XCTAssertNil(FenceItem.webURL(from: "https://", strict: false))
    }

    func testPageTitleAndIcons() {
        let html = """
        <html><head>
        <TITLE>
          Apple &amp; Friends &#8211; Home
        </TITLE>
        <link rel="icon" href="/favicon-16.png" sizes="16x16">
        <link rel='icon' type='image/png' href='https://cdn.example.com/icon-64.png' sizes='64x64'>
        <link href="/apple-touch-icon.png" rel="apple-touch-icon">
        <link rel="stylesheet" href="/style.css">
        <link rel="mask-icon" href="/mask.svg">
        </head></html>
        """
        let page = LinkPage.parse(html: html, base: URL(string: "https://www.example.com/some/page")!)
        XCTAssertEqual(page.title, "Apple & Friends \u{2013} Home")
        XCTAssertEqual(page.iconURLs.map(\.absoluteString), [
            "https://www.example.com/apple-touch-icon.png",
            "https://cdn.example.com/icon-64.png",
            "https://www.example.com/favicon-16.png",
        ])
        XCTAssertNil(LinkPage.parse(html: "<html><title>  </title></html>", base: URL(string: "https://a.com")!).title)
    }

    // MARK: Shortcuts

    func testShortcutCommands() {
        XCTAssertEqual(ShortcutsTool.executable.path, "/usr/bin/shortcuts")
        XCTAssertEqual(ShortcutsTool.listArguments, ["list"])
        // The name is one argument as it is, quotes and all; no shell is involved.
        XCTAssertEqual(ShortcutsTool.runArguments("What\u{2019}s a shortcut?"), ["run", "What\u{2019}s a shortcut?"])
        XCTAssertEqual(ShortcutsTool.runArguments("Say \"hi\"; rm -rf ~"), ["run", "Say \"hi\"; rm -rf ~"])
        XCTAssertEqual(ShortcutsTool.parseList("Take a Break\n\nShazam shortcut\r\n  Take a Break  \n"), ["Take a Break", "Shazam shortcut"])
    }
}
