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

    private let corner: CGFloat = 12

    var body: some View {
        if let fence = store.fence(fenceID) {
            VStack(spacing: 0) {
                titleBar(fence)
                if fence.isCollapsed {
                    collapsedBody(fence)
                } else {
                    ItemGrid(fence: fence)
                }
            }
            .background(Color(nsColor: fence.color.body))
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
                    .padding(.horizontal, 34)
            }
            HStack {
                Menu {
                    FenceMenu(fence: fence, onRename: { startRename(fence) })
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
        .background(Color(nsColor: fence.color.titleBar))
        .contentShape(Rectangle())
        .gesture(moveGesture)
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(fence) })
        .contextMenu { FenceMenu(fence: fence, onRename: { startRename(fence) }) }
    }

    private func collapsedBody(_ fence: Fence) -> some View {
        Text(fence.items.count == 1 ? "1 item" : "\(fence.items.count) items")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { coordinator.toggleCollapse(fenceID) }
            .contextMenu { FenceMenu(fence: fence, onRename: { startRename(fence) }) }
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

struct FenceMenu: View {
    let fence: Fence
    let onRename: () -> Void

    @EnvironmentObject private var coordinator: FenceCoordinator

    var body: some View {
        Button("Rename…", action: onRename)
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
        Button(fence.isCollapsed ? "Expand" : "Collapse") { coordinator.toggleCollapse(fence.id) }
        Divider()
        Button("Delete Fence…", role: .destructive) { coordinator.confirmDelete(fence.id) }
    }
}
