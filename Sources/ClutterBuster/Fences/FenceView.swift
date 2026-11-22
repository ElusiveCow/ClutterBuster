import SwiftUI

struct FenceView: View {
    let fenceID: UUID

    @EnvironmentObject private var store: FenceStore
    @EnvironmentObject private var coordinator: FenceCoordinator

    @State private var isRenaming = false
    @State private var draftTitle = ""
    @State private var isDropTargeted = false
    @State private var dragStart: (mouse: CGPoint, frame: CGRect)?
    @FocusState private var titleFocused: Bool
    @State private var editingTabID: UUID?
    @State private var tabDraft = ""
    @FocusState private var tabFieldFocused: Bool

    private let corner: CGFloat = 12

    var body: some View {
        if let fence = store.fence(fenceID) {
            let tab = fence.currentTab
            VStack(spacing: 0) {
                titleBar(fence)
                if !fence.isCollapsed { tabBar(fence) }
                ZStack(alignment: .bottomTrailing) {
                    if fence.isCollapsed {
                        collapsedBody(fence)
                    } else {
                        ItemGrid(
                            fence: fence,
                            items: coordinator.displayedItems(fence, tab: tab),
                            bottomInset: coordinator.patchSize.height + FenceCoordinator.patchInset
                        )
                    }
                    GeometryReader { geo in
                        StackPatch(
                            fence: fence,
                            // Collapsed fences count everything they hold; expanded ones count the tab shown.
                            count: fence.isCollapsed ? fence.items.count : fence.items(in: tab.id).count,
                            size: coordinator.patchSize,
                            labelSize: GridMetrics(width: geo.size.width, columns: fence.iconsPerRow).label
                        ) {
                            if fence.isCollapsed { coordinator.toggleCollapse(fenceID) }
                        }
                        .padding(FenceCoordinator.patchInset)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: fence.color.body).opacity(backgroundOpacity(fence)))
            }
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .overlay {
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Color.white.opacity(0.12), lineWidth: isDropTargeted ? 3 : 1)
            }
            .overlay { ResizeHandles(fenceID: fenceID, isCollapsed: fence.isCollapsed) }
            .dropDestination(for: URL.self) { urls, _ in
                coordinator.addItems(urls, to: fenceID)
                return true
            } isTargeted: { isDropTargeted = $0 }
        }
    }

    private func titleBar(_ fence: Fence) -> some View {
        ZStack {
            if isRenaming {
                TextField("Fence name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .focused($titleFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { commitRename() }
                    }
                    .padding(.horizontal, 34)
            } else {
                Text(fence.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: .black.opacity(fence.opacity < 1 ? 0.6 : 0), radius: 2, y: 1)
                    .padding(.horizontal, 34)
            }
            HStack {
                Menu {
                    FenceMenu(fence: fence, onRename: { startRename(fence) }, onNewTab: addTab)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
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
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(fence.isCollapsed ? "Expand" : "Collapse")
            }
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: FenceCoordinator.titleHeight)
        .background(Color(nsColor: fence.color.titleBar).opacity(backgroundOpacity(fence)))
        .contentShape(Rectangle())
        .gesture(moveGesture)
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(fence) })
        .contextMenu { FenceMenu(fence: fence, onRename: { startRename(fence) }, onNewTab: addTab) }
    }

    private func tabBar(_ fence: Fence) -> some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(fence.tabs) { tab in
                        tabButton(fence, tab)
                    }
                    Button(action: addTab) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
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
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(Color.white.opacity(0.12)))
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
        .background(Color(nsColor: fence.color.titleBar).opacity(backgroundOpacity(fence) * 0.6))
    }

    private func tabButton(_ fence: Fence, _ tab: FenceTab) -> some View {
        let selected = tab.id == fence.currentTab.id
        return Group {
            if editingTabID == tab.id {
                TextField("Tab name", text: $tabDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: max(50, CGFloat(tabDraft.count) * 7 + 10))
                    .focused($tabFieldFocused)
                    .onSubmit(commitTabRename)
                    .onExitCommand { editingTabID = nil }
                    .onChange(of: tabFieldFocused) { _, focused in
                        if !focused { commitTabRename() }
                    }
            } else {
                Text(tab.name)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.65))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 20)
        .background(Capsule().fill(Color.white.opacity(selected ? 0.2 : 0)))
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

    /// Fully transparent pixels let clicks and drops fall through to the desktop, so "Clear"
    /// keeps a barely visible tint.
    private func backgroundOpacity(_ fence: Fence) -> Double {
        max(fence.opacity, 0.03)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
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

/// The solid patch over the hidden desktop icon stack. Its size is fixed by the desktop icon
/// footprint; the item count matches the fence's label size so it scales with the fence.
struct StackPatch: View {
    let fence: Fence
    let count: Int
    let size: CGSize
    let labelSize: CGFloat
    let onTap: () -> Void

    var body: some View {
        Text(count == 1 ? "1 item" : "\(count) items")
            .font(.system(size: labelSize, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: fence.color.body)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: onTap)
    }
}

struct FenceMenu: View {
    let fence: Fence
    let onRename: () -> Void
    let onNewTab: () -> Void

    @EnvironmentObject private var coordinator: FenceCoordinator

    var body: some View {
        Button("Rename…", action: onRename)
        Button("New Tab", action: onNewTab)
        Menu("Sort \u{201C}\(fence.currentTab.name)\u{201D}") {
            SortMenuContent(fenceID: fence.id, tab: fence.currentTab)
        }
        Divider()
        Menu("Color") {
            ForEach(FenceColor.allCases) { color in
                Button {
                    coordinator.setColor(fence.id, color)
                } label: {
                    if color == fence.color { Label(color.name, systemImage: "checkmark") } else { Text(color.name) }
                }
            }
        }
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
