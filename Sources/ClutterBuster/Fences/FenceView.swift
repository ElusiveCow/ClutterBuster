import SwiftUI

struct FenceView: View {
    let fenceID: UUID

    @EnvironmentObject private var store: FenceStore
    @EnvironmentObject private var coordinator: FenceCoordinator
    @ObservedObject private var themes = ThemeSettings.shared

    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var isDropTargeted = false
    @State private var dragStart: (mouse: CGPoint, frame: CGRect)?
    @GestureState private var moving = false
    @FocusState private var titleFocused: Bool
    @State private var editingTabID: UUID?
    @State private var tabDraft = ""
    @FocusState private var tabFieldFocused: Bool
    @State private var hovered = false
    @State private var badge: String?
    @State private var badgeHide: DispatchWorkItem?
    @State private var gearAnchor = PopoverAnchor()
    @State private var menuAnchor = PopoverAnchor()

    private let corner: CGFloat = 12

    var body: some View {
        if let fence = store.fence(fenceID) {
            let style = ThemeStyle.resolve(fence, global: themes.globalTheme)
            let animate = themes.animates && !coordinator.interacting.contains(fenceID)
            let tab = fence.currentTab
            let metrics = FenceMetrics(fence)
            VStack(spacing: 0) {
                titleBar(fence, style: style, metrics: metrics, animate: animate)
                if !fence.isCollapsed {
                    tabBar(fence, style: style, metrics: metrics)
                    GeometryReader { geo in
                        ZStack(alignment: .bottomTrailing) {
                            ThemeBody(style: style, animate: animate)
                            ItemGrid(
                                fence: fence,
                                style: style,
                                items: coordinator.displayedItems(fence, tab: tab),
                                reservedBottom: cornerBand(style, area: geo.size, metrics: metrics)
                            )
                            CornerArt(style: style, area: geo.size, animate: animate, minimumGrid: metrics.minimumGridHeight)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .overlay {
                ThemeBorderView(border: style.border, cornerRadius: corner, live: true, animate: animate)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: corner)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                ResizeHandles(
                    fenceID: fenceID,
                    isCollapsed: fence.isCollapsed,
                    showGrip: hovered || coordinator.interacting.contains(fenceID),
                    gripColor: style.bodySecondary
                )
            }
            // Above the resize handles so the pill takes its clicks while it shows.
            .overlay(alignment: .bottomLeading) {
                if !fence.isCollapsed {
                    hoverControls(fence, style: style)
                }
            }
            .overlay {
                if let badge {
                    Text(badge)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(style.titleText)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(ThemeFillView(fill: style.titleBar).opacity(0.94).clipShape(Capsule()))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovered = $0 }
            .onChange(of: fence.textScale) { _, scale in
                showBadge("\(Int((scale * 100).rounded()))%")
            }
            .dropDestination(for: URL.self) { urls, _ in
                coordinator.addItems(urls, to: fenceID)
                return true
            } isTargeted: { isDropTargeted = $0 }
        }
    }

    /// Text size and settings buttons that fade in along the bottom left while the pointer is
    /// over the fence, clear of the corner art and resize grip at the bottom right. Collapsed
    /// fences don't show them; their ⋯ menu has the same choices.
    private func hoverControls(_ fence: Fence, style: ThemeStyle) -> some View {
        let visible = hovered || coordinator.settingsFenceID == fenceID
        return HStack(spacing: 0) {
            pillButton("textformat.size.smaller", help: "Smaller text", style: style) {
                coordinator.adjustTextScale(fenceID, by: -1)
            }
            .disabled(fence.textScale <= Fence.textScaleRange.lowerBound)
            pillButton("textformat.size.larger", help: "Bigger text", style: style) {
                coordinator.adjustTextScale(fenceID, by: 1)
            }
            .disabled(fence.textScale >= Fence.textScaleRange.upperBound)
            Rectangle()
                .fill(style.titleText.opacity(0.2))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 2)
            pillButton("gearshape", help: "Fence settings", style: style) {
                coordinator.showSettings(fenceID, from: gearAnchor.view)
            }
            .background(PopoverAnchorView(anchor: gearAnchor))
        }
        .padding(.horizontal, 3)
        .frame(height: 26)
        .background(ThemeFillView(fill: style.titleBar).opacity(0.92).clipShape(Capsule()))
        .overlay(Capsule().strokeBorder(style.titleText.opacity(0.14)))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .padding(8)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: visible)
        .allowsHitTesting(visible)
    }

    private func pillButton(_ systemImage: String, help: String, style: ThemeStyle, action: @escaping () -> Void) -> some View {
        PillButton(systemImage: systemImage, color: style.titleText, action: action)
            .help(help)
    }

    /// Briefly shows a value, such as the new text size, over the middle of the fence.
    private func showBadge(_ text: String) {
        badgeHide?.cancel()
        withAnimation(.easeOut(duration: 0.12)) { badge = text }
        let hide = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.35)) { badge = nil }
        }
        badgeHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: hide)
    }

    // The buttons sit beside the drag surface rather than inside it: a menu swallows its
    // mouse-up, which would leave the move gesture mid-press and lose the next drag.
    private func titleBar(_ fence: Fence, style: ThemeStyle, metrics: FenceMetrics, animate: Bool) -> some View {
        ZStack {
            titleDragSurface(fence, style: style, metrics: metrics, animate: animate)
            titleButtons(fence, style: style)
        }
        .frame(maxWidth: .infinity)
        .frame(height: metrics.titleHeight)
    }

    private func titleDragSurface(_ fence: Fence, style: ThemeStyle, metrics: FenceMetrics, animate: Bool) -> some View {
        let title = fence.titleStyle.resolved(on: style, scale: metrics.scale)
        let alignment: Alignment = title.alignment == .leading ? .leading : .center
        return ZStack(alignment: alignment) {
            if isRenaming {
                TextField("Fence name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(title.alignment == .leading ? .leading : .center)
                    .font(title.font)
                    .foregroundStyle(title.color)
                    .focused($titleFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { commitRename() }
                    }
                    .padding(.horizontal, 34)
            } else {
                // Collapsed fences count everything they hold; expanded ones count the tab shown.
                let count = fence.isCollapsed ? fence.items.count : fence.items(in: fence.currentTab.id).count
                HStack(spacing: 0) {
                    Text(fence.title)
                        .font(title.font)
                        .foregroundStyle(title.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(" \u{00B7} \(count)")
                        .font(title.countFont)
                        .foregroundStyle(title.secondary)
                        .fixedSize()
                }
                .shadow(color: style.textShadow, radius: 2, y: 1)
                .padding(.horizontal, 34)
                .help(count == 1 ? "1 item" : "\(count) items")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .background {
            ZStack {
                ThemeFillView(fill: style.titleBar)
                TitleAccentView(accent: style.titleAccent, animate: animate)
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        // A cancelled drag never calls onEnded, but its gesture state still resets.
        .onChange(of: moving) { _, active in
            if !active, dragStart != nil {
                dragStart = nil
                coordinator.endInteraction(fenceID)
            }
        }
        .gesture(moveGesture)
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(fence) })
        .contextMenu { fenceMenu(fence) }
    }

    private func fenceMenu(_ fence: Fence) -> some View {
        FenceMenu(
            fence: fence,
            onRename: { startRename(fence) },
            onNewTab: addTab,
            onSettings: { coordinator.showSettings(fenceID, from: menuAnchor.view, edge: .maxY) },
            onTitleStyle: { coordinator.showSettings(fenceID, page: .titleStyle, from: menuAnchor.view, edge: .maxY) }
        )
    }

    private func titleButtons(_ fence: Fence, style: ThemeStyle) -> some View {
        HStack {
            Menu {
                fenceMenu(fence)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(style.titleText.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .background(PopoverAnchorView(anchor: menuAnchor))
            .help("Fence options")
            Spacer()
            Button {
                coordinator.toggleCollapse(fenceID)
            } label: {
                Image(systemName: fence.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(style.titleText.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(fence.isCollapsed ? "Expand" : "Collapse")
        }
        .padding(.horizontal, 6)
    }

    private func tabBar(_ fence: Fence, style: ThemeStyle, metrics: FenceMetrics) -> some View {
        Group {
            if fence.tabsCollapsed {
                collapsedTabBar(fence, style: style, metrics: metrics)
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 4) {
                        tabList(fence, style: style, metrics: metrics)
                            .onPreferenceChange(TabFramesKey.self) { coordinator.tabFrames[fenceID] = $0 }
                        sortButton(fence, style: style, metrics: metrics)
                            .frame(height: metrics.tabBarHeight)
                            .padding(.trailing, 6)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    TabStripGrip(fenceID: fenceID, rows: fence.tabRows, metrics: metrics, style: style)
                }
            }
        }
        .frame(height: metrics.tabStripHeight(fence))
        .background(style.tabStrip)
        .background(GeometryReader { geo in
            Color.clear.preference(key: TabStripFrameKey.self, value: geo.frame(in: .global))
        })
        .onPreferenceChange(TabStripFrameKey.self) { coordinator.tabStripFrames[fenceID] = $0 }
    }

    /// One row scrolls sideways. Taller strips wrap the tabs and scroll down when they overflow.
    @ViewBuilder
    private func tabList(_ fence: Fence, style: ThemeStyle, metrics: FenceMetrics) -> some View {
        if fence.tabRows > 1 {
            ScrollView(.vertical) {
                FlowLayout(spacing: 2, lineSpacing: metrics.tabRowHeight - metrics.tabPillHeight) {
                    ForEach(fence.tabs) { tab in
                        tabButton(fence, tab, style: style, metrics: metrics)
                    }
                    addTabButton(style, metrics: metrics)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, (metrics.tabBarHeight - metrics.tabPillHeight) / 2)
            }
            .scrollIndicators(.automatic)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(fence.tabs) { tab in
                        tabButton(fence, tab, style: style, metrics: metrics)
                    }
                    addTabButton(style, metrics: metrics)
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.never)
            .frame(height: metrics.tabBarHeight)
        }
    }

    private func addTabButton(_ style: ThemeStyle, metrics: FenceMetrics) -> some View {
        Button(action: addTab) {
            Image(systemName: "plus")
                .font(.system(size: metrics.font(10), weight: .bold))
                .foregroundStyle(style.tabText)
                .frame(width: metrics.tabPillHeight - 1, height: metrics.tabPillHeight - 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New tab")
    }

    private func sortButton(_ fence: Fence, style: ThemeStyle, metrics: FenceMetrics) -> some View {
        Menu {
            SortMenuContent(fenceID: fenceID, tab: fence.currentTab)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: metrics.font(8), weight: .bold))
                Text(fence.currentTab.sort.label)
                    .lineLimit(1)
            }
            .font(.system(size: metrics.font(10), weight: .medium))
            .foregroundStyle(style.tabText)
            .padding(.horizontal, metrics.font(7))
            .frame(height: metrics.sortPillHeight)
            .background(Capsule().fill(style.tabControl))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort this tab")
    }

    /// The tucked-away strip: the current tab's name opens a menu of tabs, and the chevron
    /// brings the strip back.
    private func collapsedTabBar(_ fence: Fence, style: ThemeStyle, metrics: FenceMetrics) -> some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(fence.tabs) { tab in
                    Button {
                        coordinator.selectTab(fenceID, tab.id)
                    } label: {
                        if tab.id == fence.currentTab.id { Label(tab.name, systemImage: "checkmark") } else { Text(tab.name) }
                    }
                }
                Divider()
                Button("New Tab", action: addTab)
            } label: {
                HStack(spacing: 4) {
                    Text(fence.currentTab.name)
                        .font(.system(size: metrics.font(11), weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: metrics.font(7), weight: .bold))
                }
                .foregroundStyle(style.tabText)
                .shadow(color: style.textShadow, radius: 1.5, y: 1)
                .padding(.horizontal, 9)
                .frame(height: metrics.collapsedTabBarHeight)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch tabs")
            Spacer(minLength: 0)
            Button {
                coordinator.setTabStrip(fenceID, rows: fence.tabRows, collapsed: false)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: metrics.font(9), weight: .bold))
                    .foregroundStyle(style.tabText)
                    .frame(width: 24, height: metrics.collapsedTabBarHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show tabs")
            .padding(.trailing, 4)
        }
    }

    private func tabButton(_ fence: Fence, _ tab: FenceTab, style: ThemeStyle, metrics: FenceMetrics) -> some View {
        let selected = tab.id == fence.currentTab.id
        return Group {
            if editingTabID == tab.id {
                TextField("Tab name", text: $tabDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: metrics.font(12), weight: .semibold))
                    .foregroundStyle(style.tabSelectedText)
                    .frame(width: max(50, CGFloat(tabDraft.count) * 8 + 10) * metrics.scale)
                    .focused($tabFieldFocused)
                    .onSubmit(commitTabRename)
                    .onExitCommand { editingTabID = nil }
                    .onChange(of: tabFieldFocused) { _, focused in
                        if !focused { commitTabRename() }
                    }
            } else {
                Text(tab.name)
                    .font(.system(size: metrics.font(12), weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? style.tabSelectedText : style.tabText)
                    .shadow(color: style.textShadow, radius: 1.5, y: 1)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, metrics.font(9))
        .frame(height: metrics.tabPillHeight)
        .background {
            if selected {
                Capsule()
                    .fill(style.tabPill)
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
            }
        }
        .contentShape(Capsule())
        .background(GeometryReader { geo in
            Color.clear.preference(key: TabFramesKey.self, value: [tab.id: geo.frame(in: .global)])
        })
        .onTapGesture(count: 2) { startTabRename(tab.id, name: tab.name) }
        .simultaneousGesture(TapGesture().onEnded { coordinator.selectTab(fenceID, tab.id) })
        .contextMenu {
            Button("Rename…") { startTabRename(tab.id, name: tab.name) }
            Button("Delete Tab", role: .destructive) { coordinator.deleteTab(fenceID, tab.id) }
                .disabled(fence.tabs.count <= 1)
        }
    }

    private func addTab() {
        guard let id = coordinator.addTab(fenceID), let fence = store.fence(fenceID),
              let tab = fence.tabs.first(where: { $0.id == id }) else { return }
        // The new tab's name is edited in the strip, so it has to be showing.
        if fence.tabsCollapsed { coordinator.setTabStrip(fenceID, rows: fence.tabRows, collapsed: false) }
        startTabRename(id, name: tab.name)
    }

    private func startTabRename(_ tabID: UUID, name: String) {
        tabDraft = name
        editingTabID = tabID
        coordinator.selectTab(fenceID, tabID)
        coordinator.focus(fenceID)
        DispatchQueue.main.async { tabFieldFocused = true }
    }

    private func commitTabRename() {
        guard let tabID = editingTabID else { return }
        editingTabID = nil
        coordinator.renameTab(fenceID, tabID, to: tabDraft)
    }

    /// Height along the bottom that tiles stay above so they never sit behind the corner art.
    /// Without art the grid uses the full height.
    private func cornerBand(_ style: ThemeStyle, area: CGSize, metrics: FenceMetrics) -> CGFloat {
        guard let art = CornerArt.size(for: style, area: area, minimumGrid: metrics.minimumGridHeight) else { return 0 }
        return art.height + CornerArt.padding + 4
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($moving) { _, state, _ in state = true }
            .onChanged { _ in
                let mouse = NSEvent.mouseLocation
                if dragStart == nil {
                    dragStart = (mouse, coordinator.expandedFrame(fenceID))
                    coordinator.beginInteraction(fenceID)
                }
                guard let start = dragStart else { return }
                var frame = start.frame
                frame.origin.x += mouse.x - start.mouse.x
                frame.origin.y += mouse.y - start.mouse.y
                coordinator.updateLiveFrame(fenceID, frame)
            }
            .onEnded { _ in
                dragStart = nil
                coordinator.endInteraction(fenceID)
            }
    }

    private func startRename(_ fence: Fence) {
        draftTitle = fence.title
        isRenaming = true
        coordinator.focus(fenceID)
        DispatchQueue.main.async { titleFocused = true }
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        coordinator.rename(fenceID, to: draftTitle)
    }
}

struct FenceMenu: View {
    let fence: Fence
    let onRename: () -> Void
    let onNewTab: () -> Void
    let onSettings: () -> Void
    let onTitleStyle: () -> Void

    @EnvironmentObject private var coordinator: FenceCoordinator
    @ObservedObject private var themes = ThemeSettings.shared

    var body: some View {
        // Color and transparency belong to Classic; other themes set their own.
        let isClassic = (fence.theme ?? themes.globalTheme) == .classic
        Button("Fence Settings…", action: onSettings)
        Divider()
        Button("Rename…", action: onRename)
        Button("Title Style…", action: onTitleStyle)
        Button("New Tab", action: onNewTab)
        Menu("Sort \u{201C}\(fence.currentTab.name)\u{201D}") {
            SortMenuContent(fenceID: fence.id, tab: fence.currentTab)
        }
        Divider()
        Menu("Theme") {
            Button {
                coordinator.setTheme(fence.id, nil)
            } label: {
                let title = "Use Global (\(themes.globalTheme.name))"
                if fence.theme == nil { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
            Divider()
            ForEach(FenceTheme.allCases) { theme in
                Button {
                    coordinator.setTheme(fence.id, theme)
                } label: {
                    if theme == fence.theme { Label(theme.name, systemImage: "checkmark") } else { Text(theme.name) }
                }
            }
        }
        Menu("Color") {
            ForEach(FenceColor.allCases) { color in
                Button {
                    coordinator.setColor(fence.id, color)
                } label: {
                    if color == fence.color { Label(color.name, systemImage: "checkmark") } else { Text(color.name) }
                }
            }
        }
        .disabled(!isClassic)
        Menu("Icons per Row") {
            ForEach(Array(AppSettings.iconsPerRowRange), id: \.self) { count in
                Button {
                    coordinator.setIconsPerRow(fence.id, count)
                } label: {
                    if count == fence.iconsPerRow { Label("\(count)", systemImage: "checkmark") } else { Text("\(count)") }
                }
            }
        }
        Menu("Transparency") {
            let current = OpacityPreset.nearest(to: fence.opacity)
            ForEach(OpacityPreset.allCases) { preset in
                Button {
                    coordinator.setOpacity(fence.id, preset.value)
                } label: {
                    if preset == current { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
                }
            }
        }
        .disabled(!isClassic)
        Menu("Text Size \u{00B7} \(Int((fence.textScale * 100).rounded()))%") {
            Button("Bigger") { coordinator.adjustTextScale(fence.id, by: 1) }
                .disabled(fence.textScale >= Fence.textScaleRange.upperBound)
            Button("Smaller") { coordinator.adjustTextScale(fence.id, by: -1) }
                .disabled(fence.textScale <= Fence.textScaleRange.lowerBound)
            Divider()
            Button("Reset to 100%") { coordinator.setTextScale(fence.id, 1) }
                .disabled(fence.textScale == 1)
        }
        Button(fence.tabsCollapsed ? "Show Tabs" : "Tuck Tabs Away") {
            coordinator.setTabStrip(fence.id, rows: fence.tabRows, collapsed: !fence.tabsCollapsed)
        }
        .disabled(fence.isCollapsed)
        Button(fence.isCollapsed ? "Expand" : "Collapse") { coordinator.toggleCollapse(fence.id) }
        Divider()
        Button("Delete Fence…", role: .destructive) { coordinator.confirmDelete(fence.id) }
    }
}

/// Sort choices for one tab, shared by the tab bar's sort button and the fence menu.
struct SortMenuContent: View {
    let fenceID: UUID
    let tab: FenceTab

    @EnvironmentObject private var coordinator: FenceCoordinator

    var body: some View {
        ForEach(SortKey.allCases) { key in
            Button {
                var sort = tab.sort
                sort.key = key
                coordinator.setSort(fenceID, tab.id, sort)
            } label: {
                if key == tab.sort.key { Label(key.name, systemImage: "checkmark") } else { Text(key.name) }
            }
        }
        Divider()
        ForEach([true, false], id: \.self) { ascending in
            Button {
                var sort = tab.sort
                sort.ascending = ascending
                coordinator.setSort(fenceID, tab.id, sort)
            } label: {
                let title = ascending ? "Ascending" : "Descending"
                if tab.sort.key != .manual && tab.sort.ascending == ascending {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
            .disabled(tab.sort.key == .manual)
        }
    }
}

/// Frames reported by tabs and tiles, keyed by ID, in window content coordinates.
struct TabFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The tab strip's frame, in window content coordinates.
struct TabStripFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        // Views that don't report a frame pass along the empty default.
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The bar under the tabs. Dragging it down shows more rows of tabs, snapping to whole
/// rows; dragging it up past the first row tucks the strip away.
private struct TabStripGrip: View {
    let fenceID: UUID
    let rows: Int
    let metrics: FenceMetrics
    let style: ThemeStyle

    @EnvironmentObject private var coordinator: FenceCoordinator
    @State private var startRows: Int?
    @State private var hovering = false
    @GestureState private var dragging = false

    var body: some View {
        Capsule()
            .fill(style.tabText.opacity(hovering || dragging ? 0.6 : 0.3))
            .frame(width: 28, height: 3)
            .frame(maxWidth: .infinity)
            .frame(height: FenceMetrics.tabGripHeight)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            // Tucking the strip away removes the grip mid-hover.
            .onDisappear { if hovering { NSCursor.pop() } }
            .onChange(of: dragging) { _, active in
                if !active { startRows = nil }
            }
            .help("Drag down for more rows of tabs, or up to tuck them away")
            .gesture(
                // Global coordinates: the grip moves as the strip grows.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { value in
                        let start = startRows ?? rows
                        if startRows == nil { startRows = rows }
                        let height = metrics.tabStripHeight(rows: start, collapsed: false) + value.translation.height
                        let oneRow = metrics.tabStripHeight(rows: 1, collapsed: false)
                        if height < oneRow - metrics.tabBarHeight / 2 {
                            coordinator.setTabStrip(fenceID, rows: start, collapsed: true)
                        } else {
                            let wanted = Int(((height - oneRow) / metrics.tabRowHeight).rounded()) + 1
                            coordinator.setTabStrip(fenceID, rows: wanted, collapsed: false)
                        }
                    }
            )
    }
}

/// An icon button in a fence's hover controls, highlighted under the pointer.
private struct PillButton: View {
    let systemImage: String
    let color: Color
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color.opacity(isEnabled ? 0.95 : 0.35))
                .frame(width: 26, height: 22)
                .background(Capsule().fill(color.opacity(hovering && isEnabled ? 0.16 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct TileFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
