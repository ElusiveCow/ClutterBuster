import SwiftUI

/// Icon sizes for a fence. The number of icons per row is fixed, so icons grow and shrink
/// with the fence's width, within a minimum and maximum size.
struct GridMetrics {
    static let padding: CGFloat = 10

    let columns: Int
    let cell: CGFloat
    let icon: CGFloat
    let label: CGFloat
    let showLabels: Bool

    init(width: CGFloat, columns: Int) {
        self.columns = max(1, columns)
        cell = max(1, (width - Self.padding * 2) / CGFloat(self.columns))
        icon = min(max(cell * 0.62, 20), 128, cell)
        label = min(max(icon * 0.19, 9), 15)
        showLabels = icon >= 30
    }
}

struct ItemGrid: View {
    let fence: Fence

    var body: some View {
        GeometryReader { geo in
            let metrics = GridMetrics(width: geo.size.width, columns: fence.iconsPerRow)
            if fence.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 22))
                    Text("Drag files here")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(metrics.cell), spacing: 0), count: metrics.columns),
                        spacing: 4
                    ) {
                        ForEach(fence.items) { item in
                            ItemTile(item: item, fenceID: fence.id, metrics: metrics)
                        }
                    }
                    .padding(.horizontal, GridMetrics.padding)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.automatic)
            }
        }
    }
}

struct ItemTile: View {
    let item: FenceItem
    let fenceID: UUID
    let metrics: GridMetrics

    @EnvironmentObject private var coordinator: FenceCoordinator

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: item.path)
        Button {
            coordinator.open(item)
        } label: {
            VStack(spacing: 3) {
                Image(nsImage: IconCache.icon(for: item.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: metrics.icon, height: metrics.icon)
                if metrics.showLabels {
                    Text(item.displayName)
                        .font(.system(size: metrics.label))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                }
            }
            .frame(width: metrics.cell)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .opacity(exists ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .help(exists ? item.displayName : "\(item.displayName) can't be found")
        .contextMenu {
            Button("Open") { coordinator.open(item) }
            Button("Show in Finder") { coordinator.revealInFinder(item) }
            Divider()
            Button("Remove from Fence") { coordinator.removeItem(item.id, from: fenceID) }
        }
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let icon = cache[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}
