import AppKit

enum FenceColor: String, Codable, CaseIterable, Identifiable {
    case slate, ocean, forest, plum, sunset, graphite

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var body: NSColor {
        switch self {
        case .slate: NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.31, alpha: 1)
        case .ocean: NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.45, alpha: 1)
        case .forest: NSColor(calibratedRed: 0.14, green: 0.32, blue: 0.24, alpha: 1)
        case .plum: NSColor(calibratedRed: 0.33, green: 0.20, blue: 0.40, alpha: 1)
        case .sunset: NSColor(calibratedRed: 0.55, green: 0.27, blue: 0.20, alpha: 1)
        case .graphite: NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.23, alpha: 1)
        }
    }

    var titleBar: NSColor { body.blended(withFraction: 0.25, of: .black) ?? body }
}

/// What a fence item is. Only files are on disk; the rest live in the layout.
enum FenceItemKind: String, Codable, CaseIterable {
    case file, link, note, shortcut

    /// The order "Kind" sorts them in, files first.
    var sortRank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

struct FenceItem: Codable, Identifiable {
    var id = UUID()
    var kind: FenceItemKind = .file
    /// The file's path. Empty for links, notes and Shortcuts.
    var path = ""
    /// Finder position the icon had when it joined a fence, where it goes back when it leaves
    /// or the app quits. Nil for items that aren't on the Desktop.
    var originalDesktopPosition: CGPoint?
    var addedAt = Date()
    /// The tab the item is shown in. Older layouts lack it; `Fence` assigns the first tab.
    var tabID: UUID?
    /// A link's title, or a Shortcut's name.
    var title: String?
    /// A link's address.
    var link: String?
    /// A note's text.
    var text: String?
    /// When a note's text last changed.
    var editedAt: Date?

    static func link(_ url: URL, title: String?, tabID: UUID?) -> FenceItem {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return FenceItem(kind: .link, tabID: tabID, title: title?.isEmpty == false ? title : url.host(), link: url.absoluteString)
    }

    static func note(_ text: String = "", tabID: UUID?) -> FenceItem {
        FenceItem(kind: .note, tabID: tabID, text: text, editedAt: Date())
    }

    static func shortcut(_ name: String, tabID: UUID?) -> FenceItem {
        FenceItem(kind: .shortcut, tabID: tabID, title: name)
    }

    var isFile: Bool { kind == .file }
    var url: URL { URL(fileURLWithPath: path) }
    var webURL: URL? { kind == .link ? link.flatMap(URL.init(string:)) : nil }

    var displayName: String {
        switch kind {
        case .file: FileManager.default.displayName(atPath: path)
        case .link: title ?? webURL?.host() ?? link ?? "Link"
        case .note: Self.firstLine(of: text ?? "") ?? "Note"
        case .shortcut: title ?? "Shortcut"
        }
    }

    /// The name Finder uses for the item on the Desktop.
    var finderName: String { isFile ? url.lastPathComponent : displayName }
    /// Only Desktop files are ever hidden, so nothing else may claim to be on the Desktop.
    var isOnDesktop: Bool { isFile && !path.isEmpty && DesktopIconService.isOnDesktop(url) }

    /// What "Kind" calls the new kinds. Files use Finder's description of their type.
    var kindName: String? {
        switch kind {
        case .file: nil
        case .link: "Link"
        case .note: "Note"
        case .shortcut: "Shortcut"
        }
    }

    /// Whether search text finds this item: a file by its name, a link by its title or
    /// address, a note by its text and a Shortcut by its name.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        switch kind {
        case .file, .shortcut: return displayName.localizedCaseInsensitiveContains(query)
        case .link: return [title, link].contains { $0?.localizedCaseInsensitiveContains(query) == true }
        case .note: return (text ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    static func firstLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// A web address from pasted or typed text. Strictly, only text starting with http(s)://
    /// or www. counts, so a pasted file name isn't mistaken for one; otherwise anything that
    /// looks like a host name, such as "apple.com", gets https:// added.
    static func webURL(from text: String, strict: Bool) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let lower = text.lowercased()
        let candidate: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            candidate = text
        } else if lower.hasPrefix("www.") {
            candidate = "https://" + text
        } else if !strict, !text.contains(":"), !text.contains("@"),
                  let dot = text.firstIndex(of: "."), dot < (text.firstIndex(of: "/") ?? text.endIndex) {
            candidate = "https://" + text
        } else {
            return nil
        }
        guard let url = URL(string: candidate), let host = url.host(), host.contains(".") || host == "localhost" else { return nil }
        return url
    }
}

extension FenceItem {
    /// Layouts from before links, notes and Shortcuts have no kind; their items are files.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let kindName = try? container.decodeIfPresent(String.self, forKey: .kind)
        kind = kindName.flatMap(FenceItemKind.init(rawValue:)) ?? .file
        if let kindName, FenceItemKind(rawValue: kindName) == nil {
            Log.write("an item has the kind \"\(kindName)\", which this version doesn't have; it's treated as a file")
        }
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        originalDesktopPosition = try container.decodeIfPresent(CGPoint.self, forKey: .originalDesktopPosition)
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        tabID = try container.decodeIfPresent(UUID.self, forKey: .tabID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        link = try container.decodeIfPresent(String.self, forKey: .link)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        editedAt = try container.decodeIfPresent(Date.self, forKey: .editedAt)
    }
}

struct Fence: Codable, Identifiable {
    var id = UUID()
    var title: String
    /// Expanded frame in Cocoa screen coordinates. Collapsed fences keep their top edge.
    var frame: CGRect
    var isCollapsed = false
    var color: FenceColor
    var iconsPerRow: Int
    /// Opacity of the fence background, 0 (clear) to 1 (solid). Like `color`, only Classic
    /// uses it.
    var opacity: Double = 1
    /// Nil follows the global theme in Settings.
    var theme: FenceTheme?
    /// In manual order: the order items appear in when their tab is sorted manually.
    var items: [FenceItem] = []
    /// Never empty.
    var tabs: [FenceTab] = [FenceTab(name: FenceTab.defaultName)]
    var selectedTabID: UUID?
    /// Rows of tabs the strip is tall enough to show. One row scrolls sideways; more wrap.
    var tabRows = 1
    /// Shrinks the tab strip to a thin bar showing just the current tab.
    var tabsCollapsed = false
    /// Scales all of the fence's text together: title, tabs, sort button and item labels.
    var textScale: Double = 1
    /// Overrides the theme's title font, size, weight, alignment and color.
    var titleStyle = TitleStyle()
    /// The picture in the body's corner. Nil shows the theme's.
    var cornerArt: CornerArtChoice?
    /// The Spaces the fence shows on. See `showsOnAllSpaces`.
    var spaces: FenceSpaces = .all

    /// The Finder desktop is the same on every Space, so a fence holding Desktop files shows
    /// on all of them whatever `spaces` says; otherwise its files couldn't be reached from
    /// the other Spaces.
    var holdsDesktopFiles: Bool { items.contains(where: \.isOnDesktop) }
    var showsOnAllSpaces: Bool { spaces == .all || holdsDesktopFiles }

    static let textScaleRange = 0.8...1.8
    static let textScaleStep = 0.1

    static func clampedTextScale(_ scale: Double) -> Double {
        let stepped = (scale / textScaleStep).rounded() * textScaleStep
        return min(max(stepped, textScaleRange.lowerBound), textScaleRange.upperBound)
    }

    /// The tab currently shown, falling back to the first tab.
    var currentTab: FenceTab {
        tabs.first { $0.id == selectedTabID } ?? tabs[0]
    }

    func items(in tabID: UUID) -> [FenceItem] {
        items.filter { $0.tabID == tabID }
    }

    /// Makes sure there's at least one tab and every item belongs to an existing tab.
    mutating func normalizeTabs() {
        if tabs.isEmpty { tabs = [FenceTab(name: FenceTab.defaultName)] }
        let tabIDs = Set(tabs.map(\.id))
        for index in items.indices where items[index].tabID.map(tabIDs.contains) != true {
            items[index].tabID = tabs[0].id
        }
        if let selectedTabID, !tabIDs.contains(selectedTabID) { self.selectedTabID = nil }
    }
}

extension Fence {
    /// Decodes layouts saved by older versions, which lack newer keys.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        frame = try container.decode(CGRect.self, forKey: .frame)
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        color = try container.decodeIfPresent(FenceColor.self, forKey: .color) ?? .slate
        iconsPerRow = try container.decodeIfPresent(Int.self, forKey: .iconsPerRow) ?? 4
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        // A removed theme, or one from a newer version, falls back to the global theme.
        let themeName = try? container.decodeIfPresent(String.self, forKey: .theme)
        theme = themeName.flatMap(FenceTheme.init(rawValue:))
        if let themeName, theme == nil {
            Log.write("fence \"\(title)\" used the theme \"\(themeName)\", which this version doesn't have; it follows the global theme now")
        }
        items = try container.decodeIfPresent([FenceItem].self, forKey: .items) ?? []
        tabs = try container.decodeIfPresent([FenceTab].self, forKey: .tabs) ?? []
        selectedTabID = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        tabRows = max(1, try container.decodeIfPresent(Int.self, forKey: .tabRows) ?? 1)
        tabsCollapsed = try container.decodeIfPresent(Bool.self, forKey: .tabsCollapsed) ?? false
        textScale = Self.clampedTextScale(try container.decodeIfPresent(Double.self, forKey: .textScale) ?? 1)
        titleStyle = (try? container.decodeIfPresent(TitleStyle.self, forKey: .titleStyle)) ?? TitleStyle()
        cornerArt = (try? container.decodeIfPresent(CornerArtChoice.self, forKey: .cornerArt)) ?? nil
        spaces = (try? container.decodeIfPresent(FenceSpaces.self, forKey: .spaces)) ?? .all
        normalizeTabs()
    }
}

/// "Show on" in a fence's settings.
enum FenceSpaces: String, Codable, CaseIterable, Identifiable {
    case all, current

    var id: Self { self }

    var name: String {
        switch self {
        case .all: "All Spaces"
        case .current: "This Space Only"
        }
    }
}

/// What a fence draws in its body's corner.
enum CornerArtChoice: Codable, Equatable {
    /// The theme's illustration, if it has one.
    case theme
    case none
    /// A picture the user chose, cut out and saved by `CustomCornerArt` under this file name.
    case custom(String)

    /// Saved as one string: "theme", "none", or "custom:" and the file name.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "none": self = .none
        case _ where raw.hasPrefix("custom:"): self = .custom(String(raw.dropFirst("custom:".count)))
        default: self = .theme
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .theme: try container.encode("theme")
        case .none: try container.encode("none")
        case .custom(let fileName): try container.encode("custom:" + fileName)
        }
    }
}

struct FenceTab: Codable, Identifiable, Equatable {
    static let defaultName = "General"

    var id = UUID()
    var name: String
    var sort = TabSort()

    init(name: String) {
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? Self.defaultName
        sort = try container.decodeIfPresent(TabSort.self, forKey: .sort) ?? TabSort()
    }
}

enum SortKey: String, Codable, CaseIterable, Identifiable {
    case manual, name, kind, dateAdded, dateModified, size

    var id: Self { self }

    var name: String {
        switch self {
        case .manual: "Manual"
        case .name: "Name"
        case .kind: "Kind"
        case .dateAdded: "Date Added"
        case .dateModified: "Date Modified"
        case .size: "Size"
        }
    }
}

struct TabSort: Codable, Equatable {
    var key: SortKey = .manual
    var ascending = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = (try? container.decodeIfPresent(SortKey.self, forKey: .key)) ?? .manual
        ascending = try container.decodeIfPresent(Bool.self, forKey: .ascending) ?? true
    }
}

enum OpacityPreset: CaseIterable, Identifiable {
    case solid, threeQuarters, half, quarter, clear

    var id: Self { self }

    var value: Double {
        switch self {
        case .solid: 1
        case .threeQuarters: 0.75
        case .half: 0.5
        case .quarter: 0.25
        case .clear: 0
        }
    }

    var name: String {
        switch self {
        case .solid: "Solid"
        case .threeQuarters: "75%"
        case .half: "50%"
        case .quarter: "25%"
        case .clear: "Clear"
        }
    }

    static func nearest(to value: Double) -> OpacityPreset {
        allCases.min { abs($0.value - value) < abs($1.value - value) } ?? .solid
    }
}
