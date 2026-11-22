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
    /// Finder position the icon had before it was hidden. Nil for items that aren't on the Desktop.
    var originalDesktopPosition: CGPoint?
    var addedAt = Date()

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
    var items: [FenceItem] = []
}
