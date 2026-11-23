import AppKit
import SwiftUI

/// The picture on an item's tile: a file's Finder icon, a link's site icon, a note's text or
/// a Shortcut's symbol. The new kinds draw a rounded square inset like an app icon, so they
/// line up with file icons of the same size.
struct TileIcon: View {
    let item: FenceItem
    let size: CGFloat

    var body: some View {
        switch item.kind {
        case .file: ItemIcon(path: item.path, size: size)
        case .link: LinkIcon(url: item.webURL, size: size)
        case .note: NoteIcon(text: item.text ?? "", size: size)
        case .shortcut: ShortcutIcon(size: size)
        }
    }

    /// The tile's picture as an image, for drag images and search results.
    @MainActor
    static func image(for item: FenceItem, size: CGFloat, scale: CGFloat) -> NSImage {
        if item.isFile { return IconProvider.shared.currentIcon(for: item.path, pointSize: size, scale: scale) }
        let renderer = ImageRenderer(content: TileIcon(item: item, size: size))
        renderer.scale = scale
        return renderer.nsImage ?? NSImage(size: CGSize(width: size, height: size))
    }
}

/// The rounded square the new kinds are drawn on.
private struct KindTile<Background: ShapeStyle, Content: View>: View {
    let size: CGFloat
    let background: Background
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        let side = (size * 0.84).rounded()
        let shape = RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
        content(side)
            .frame(width: side, height: side)
            .background(shape.fill(background))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: max(size * 0.02, 0.5), y: max(size * 0.015, 0.5))
            .frame(width: size, height: size)
    }
}

struct LinkIcon: View {
    let url: URL?
    let size: CGFloat

    @State private var fetched: NSImage?

    var body: some View {
        let favicon = fetched ?? url.flatMap { Favicons.shared.cachedIcon(for: $0) }
        KindTile(size: size, background: Color.white) { side in
            if let favicon {
                // Touch icons are drawn to fill a tile; small favicons sit in the middle.
                let fills = (favicon.representations.map(\.pixelsWide).max() ?? 0) >= 120
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: fills ? .fill : .fit)
                    .frame(width: side * (fills ? 1 : 0.62), height: side * (fills ? 1 : 0.62))
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .fontWeight(.light)
                    .foregroundStyle(Color(red: 0.16, green: 0.45, blue: 0.85))
                    .frame(width: side * 0.6, height: side * 0.6)
            }
        }
        .task(id: url) {
            guard let url, fetched == nil else { return }
            fetched = await Favicons.shared.icon(for: url)
        }
    }
}

struct NoteIcon: View {
    let text: String
    let size: CGFloat

    static let paper = Color(red: 1.0, green: 0.92, blue: 0.55)

    var body: some View {
        KindTile(size: size, background: Self.paper) { side in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                Image(systemName: "note.text")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color.black.opacity(0.3))
                    .frame(width: side * 0.5, height: side * 0.5)
            } else {
                Text(trimmed)
                    .font(.system(size: max(side * 0.12, 5), weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.75))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(side * 0.1)
            }
        }
    }
}

struct ShortcutIcon: View {
    let size: CGFloat

    /// The layered squares of the Shortcuts app, where the system has them.
    private static let symbol = NSImage(systemSymbolName: "square.2.layers.3d.fill", accessibilityDescription: nil) != nil
        ? "square.2.layers.3d.fill" : "bolt.fill"

    var body: some View {
        let gradient = LinearGradient(
            colors: [Color(red: 0.98, green: 0.33, blue: 0.52), Color(red: 0.55, green: 0.33, blue: 0.95), Color(red: 0.22, green: 0.55, blue: 0.98)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        KindTile(size: size, background: gradient) { side in
            Image(systemName: Self.symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: side * 0.02, y: side * 0.01)
                .frame(width: side * 0.56, height: side * 0.56)
        }
    }
}
