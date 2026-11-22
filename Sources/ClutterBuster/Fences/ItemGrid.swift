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
    /// The selected tab's items, in display order.
    let items: [FenceItem]
    /// Extra scrollable space below the last row so no tile stays stuck under the solid patch.
    let bottomInset: CGFloat

    @EnvironmentObject private var coordinator: FenceCoordinator

    var body: some View {
        GeometryReader { geo in
            let metrics = GridMetrics(width: geo.size.width, columns: fence.iconsPerRow)
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 22))
                    Text("Drag files here")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.7))
                .shadow(color: .black.opacity(fence.opacity < 1 ? 0.6 : 0), radius: 2, y: 1)
                .frame(width: geo.size.width, height: max(geo.size.height - bottomInset, 44))
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(metrics.cell), spacing: 0), count: metrics.columns),
                        spacing: 4
                    ) {
                        ForEach(items) { item in
                            ItemTile(item: item, fenceID: fence.id, metrics: metrics)
                                .background(GeometryReader { tile in
                                    Color.clear.preference(key: TileFramesKey.self, value: [item.id: tile.frame(in: .global)])
                                })
                        }
                    }
                    .padding(.horizontal, GridMetrics.padding)
                    .padding(.top, 8)
                    .padding(.bottom, bottomInset + 8)
                }
                .scrollIndicators(.automatic)
                .onPreferenceChange(TileFramesKey.self) { coordinator.tileFrames[fence.id] = $0 }
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
        VStack(spacing: 3) {
            ItemIcon(path: item.path, size: metrics.icon)
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
        .opacity(exists ? 1 : 0.35)
        .overlay {
            ItemDragSource(
                item: item,
                fenceID: fenceID,
                iconSize: metrics.icon,
                toolTip: exists ? item.displayName : "\(item.displayName) can't be found",
                coordinator: coordinator
            )
        }
    }
}