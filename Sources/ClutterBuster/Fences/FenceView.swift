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

    private let corner: CGFloat = 12

    var body: some View {
        if let fence = store.fence(fenceID) {
            let style = ThemeStyle.resolve(fence, global: themes.globalTheme).collapsed(fence.isCollapsed)
            let animate = themes.animates && !coordinator.interacting.contains(fenceID)
            let tab = fence.currentTab
            VStack(spacing: 0) {
                titleBar(fence, style: style, animate: animate)
                if !fence.isCollapsed { tabBar(fence, style: style) }
                GeometryReader { geo in
                    let patch = coordinator.patchSize
                    ZStack(alignment: .bottomTrailing) {
                        ThemeBody(style: style, animate: animate)
                        // The body already hides the icon stack when it's solid.
                        if style.isSeeThrough {
                            CornerPlate(style: style, patch: patch)
                                .padding(FenceCoordinator.patchInset)
                        }
                        if fence.isCollapsed {
                            collapsedBody(fence)
                        } else {
                            ItemGrid(
                                fence: fence,
                                style: style,
                                items: coordinator.displayedItems(fence, tab: tab),
                                reservedBottom: cornerBand(style, area: geo.size)
                            )
                        }
                        CornerArt(style: style, patch: patch, area: geo.size, animate: animate)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
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
            .overlay { ResizeHandles(fenceID: fenceID, isCollapsed: fence.isCollapsed) }
            .dropDestination(for: URL.self) { urls, _ in
                coordinator.addItems(urls, to: fenceID)
                return true
            } isTargeted: { isDropTargeted = $0 }
        }
    }

    // The buttons sit beside the drag surface rather than inside it: a menu swallows its
    // mouse-up, which would leave the move gesture mid-press and lose the next drag.
    private func titleBar(_ fence: Fence, style: ThemeStyle, animate: Bool) -> some View {
        ZStack {
            titleDragSurface(fence, style: style, animate: animate)
            titleButtons(fence, style: style)
        }
        .frame(maxWidth: .infinity)
        .frame(height: FenceCoordinator.titleHeight)
    }

    private func titleDragSurface(_ fence: Fence, style: ThemeStyle, animate: Bool) -> some View {
        ZStack {
            if isRenaming {
                TextField("Fence name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13, weight: .semibold, design: style.titleDesign))
                    .foregroundStyle(style.titleText)
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
                        .foregroundStyle(style.titleText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(" \u{00B7} \(count)")
                        .fontWeight(.regular)
                        .foregroundStyle(style.titleSecondary)
                        .fixedSize()
                }
                .font(.system(size: 13, weight: .semibold, design: style.titleDesign))
                .shadow(color: style.textShadow, radius: 2, y: 1)
                .padding(.horizontal, 34)
                .help(count == 1 ? "1 item" : "\(count) items")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .contextMenu { FenceMenu(fence: fence, onRename: { startRename(fence) }, onNewTab: addTab) }
    }

    private func titleButtons(_ fence: Fence, style: ThemeStyle) -> some View {
        HStack {
            Menu {
                FenceMenu(fence: fence, onRename: { startRename(fence) }, onNewTab: addTab)
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

    private func tabBar(_ fence: Fence, style: ThemeStyle) -> some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(fence.tabs) { tab in
                        tabButton(fence, tab, style: style)
                    }
                    Button(action: addTab) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(style.tabText)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New tab")
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.never)
            .onPreferenceChange(TabFramesKey.self) { coordinator.tabFrames[fenceID] = $0 }

            Menu {
                SortMenuContent(fenceID: fenceID, tab: fence.currentTab)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 8, weight: .bold))
                    Text(fence.currentTab.sort.label)
                        .lineLimit(1)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(style.tabText)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(style.tabControl))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort this tab")
            .padding(.trailing, 6)
        }
        .frame(height: FenceCoordinator.tabBarHeight)
        .background(style.tabStrip)
    }

    private func tabButton(_ fence: Fence, _ tab: FenceTab, style: ThemeStyle) -> some View {
        let selected = tab.id == fence.currentTab.id
        return Group {
            if editingTabID == tab.id {
                TextField("Tab name", text: $tabDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.tabSelectedText)
                    .frame(width: max(50, CGFloat(tabDraft.count) * 8 + 10))
                    .focused($tabFieldFocused)
                    .onSubmit(commitTabRename)
                    .onExitCommand { editingTabID = nil }
                    .onChange(of: tabFieldFocused) { _, focused in
                        if !focused { commitTabRename() }
                    }
            } else {
                Text(tab.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? style.tabSelectedText : style.tabText)
                    .shadow(color: style.textShadow, radius: 1.5, y: 1)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 21)
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
        guard let id = coordinator.addTab(fenceID), let tab = store.fence(fenceID)?.tabs.first(where: { $0.id == id }) else { return }
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

    private func collapsedBody(_ fence: Fence) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { coordinator.toggleCollapse(fenceID) }
            .contextMenu { FenceMenu(fence: fence, onRename: { startRename(fence) }, onNewTab: addTab) }
    }

    /// Height along the bottom that tiles stay above: the corner art, or the plate over the
    /// patch on see-through fences without art. Solid fences without art use the full height.
    private func cornerBand(_ style: ThemeStyle, area: CGSize) -> CGFloat {
        let margin: CGFloat = 4
        if let art = CornerArt.size(for: style, patch: coordinator.patchSize, area: area) {
            return art.height + CornerArt.padding + margin
        }
        guard style.isSeeThrough else { return 0 }
        return coordinator.patchSize.height + FenceCoordinator.patchInset + CornerPlate.spill(style) + margin
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

    @EnvironmentObject private var coordinator: FenceCoordinator
    @ObservedObject private var themes = ThemeSettings.shared

    var body: some View {
        // Color and transparency belong to Classic; other themes set their own.
        let isClassic = (fence.theme ?? themes.globalTheme) == .classic
        Button("Rename…", action: onRename)
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

struct TileFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
