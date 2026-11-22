import SwiftUI

/// Icon sizes for a fence. The number of icons per row is fixed, so icons grow and shrink
/// with the fence's width, within a minimum and maximum size.
struct GridMetrics {
    static let padding: CGFloat = 10
    static let topPadding: CGFloat = 8
    static let rowSpacing: CGFloat = 4

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

    /// Every tile is this tall (room for a two-line label) so rows line up predictably.
    var tileHeight: CGFloat {
        icon + 8 + (showLabels ? 3 + (label * 1.25).rounded(.up) * 2 : 0)
    }
}

struct ItemGrid: View {
    let fence: Fence
    let style: ThemeStyle
    /// The selected tab's items, in display order.
    let items: [FenceItem]
    /// Height of the band along the bottom kept clear for the corner art. The grid stops
    /// above it, so tiles never scroll underneath.
    let reservedBottom: CGFloat

    @EnvironmentObject private var coordinator: FenceCoordinator

    var body: some View {
        GeometryReader { geo in
            let metrics = GridMetrics(width: geo.size.width, columns: fence.iconsPerRow)
            let height = max(geo.size.height - reservedBottom, 0)
            Group {
                if items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 22))
                        Text("Drag files here")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(style.bodySecondary)
                    .shadow(color: style.textShadow, radius: 2, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(metrics.cell), spacing: 0), count: metrics.columns),
                            spacing: GridMetrics.rowSpacing
                        ) {
                            ForEach(items) { item in
                                ItemTile(item: item, fenceID: fence.id, metrics: metrics, style: style)
                                    .background(GeometryReader { tile in
                                        Color.clear.preference(key: TileFramesKey.self, value: [item.id: tile.frame(in: .global)])
                                    })
                            }
                        }
                        .padding(.horizontal, GridMetrics.padding)
                        .padding(.top, GridMetrics.topPadding)
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.automatic)
                    .onPreferenceChange(TileFramesKey.self) { coordinator.tileFrames[fence.id] = $0 }
                }
            }
            .frame(width: geo.size.width, height: height)
            .clipped()
        }
    }
}

struct ItemTile: View {
    let item: FenceItem
    let fenceID: UUID
    let metrics: GridMetrics
    let style: ThemeStyle

    @EnvironmentObject private var coordinator: FenceCoordinator

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: item.path)
        VStack(spacing: 3) {
            ItemIcon(path: item.path, size: metrics.icon)
            if metrics.showLabels {
                Text(item.displayName)
                    .font(.system(size: metrics.label))
                    .foregroundStyle(style.bodyText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .shadow(color: style.isLight ? .white.opacity(0.6) : .black.opacity(0.4), radius: 1, y: 1)
            }
        }
        .frame(width: metrics.cell, height: metrics.tileHeight - 8, alignment: .top)
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
