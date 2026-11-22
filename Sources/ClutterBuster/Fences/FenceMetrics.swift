import CoreGraphics

/// Heights of a fence's title bar, tab strip and smallest grid. They grow with the fence's
/// text size so no text clips.
struct FenceMetrics {
    /// The bar under the tabs that's dragged to show more rows.
    static let tabGripHeight: CGFloat = 6
    static let maxTabRows = 4
    /// The title bar's height at the default text size, and the least it ever is.
    static let baseTitleHeight: CGFloat = 30
    /// Room for a row of icons at the default text size.
    static let baseMinimumGridHeight: CGFloat = 72

    let scale: CGFloat
    let titleHeight: CGFloat

    init(_ fence: Fence) {
        scale = CGFloat(fence.textScale)
        titleHeight = max(Self.baseTitleHeight, fence.titleStyle.lineHeight(scale: scale).rounded(.up) + 13)
    }

    /// A font size scaled by the fence's text size.
    func font(_ size: CGFloat) -> CGFloat { size * scale }

    /// One tab's capsule.
    var tabPillHeight: CGFloat { (font(12) * 1.25).rounded(.up) + 6 }
    /// Height of the tab strip's first row. Each further row adds `tabRowHeight`.
    var tabBarHeight: CGFloat { tabPillHeight + 5 }
    var tabRowHeight: CGFloat { tabPillHeight + 3 }
    var collapsedTabBarHeight: CGFloat { max(18, (font(11) * 1.25).rounded(.up) + 4) }
    var sortPillHeight: CGFloat { (font(10) * 1.25).rounded(.up) + 5 }
    var minimumGridHeight: CGFloat { Self.baseMinimumGridHeight + ((scale - 1) * 30).rounded() }

    func tabStripHeight(rows: Int, collapsed: Bool) -> CGFloat {
        guard !collapsed else { return collapsedTabBarHeight }
        return tabBarHeight + CGFloat(max(rows, 1) - 1) * tabRowHeight + Self.tabGripHeight
    }

    func tabStripHeight(_ fence: Fence) -> CGFloat {
        tabStripHeight(rows: fence.tabRows, collapsed: fence.tabsCollapsed)
    }
}
