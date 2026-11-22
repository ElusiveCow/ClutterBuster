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

struct FenceItem: Codable, Identifiable {
    var id = UUID()
    var path: String
    /// Finder position the icon had when it joined a fence, where it goes back when it leaves
    /// or the app quits. Nil for items that aren't on the Desktop.
    var originalDesktopPosition: CGPoint?
    var addedAt = Date()
    /// The tab the item is shown in. Older layouts lack it; `Fence` assigns the first tab.
    var tabID: UUID?

    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { FileManager.default.displayName(atPath: path) }
    /// The name Finder uses for the item on the Desktop.
    var finderName: String { url.lastPathComponent }
    var isOnDesktop: Bool { DesktopIconService.isOnDesktop(url) }
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
        // A theme from a newer version falls back to the global theme.
        theme = (try? container.decodeIfPresent(FenceTheme.self, forKey: .theme)) ?? nil
        items = try container.decodeIfPresent([FenceItem].self, forKey: .items) ?? []
        tabs = try container.decodeIfPresent([FenceTab].self, forKey: .tabs) ?? []
        selectedTabID = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        tabRows = max(1, try container.decodeIfPresent(Int.self, forKey: .tabRows) ?? 1)
        tabsCollapsed = try container.decodeIfPresent(Bool.self, forKey: .tabsCollapsed) ?? false
        normalizeTabs()
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
