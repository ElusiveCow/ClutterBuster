import SwiftUI

/// Invisible strips along each edge and corner that resize the fence when dragged.
/// Collapsed fences only resize horizontally.
struct ResizeHandles: View {
    let fenceID: UUID
    let isCollapsed: Bool

    private let edge: CGFloat = 6
    private let corner: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                handle(.left).frame(width: edge, height: max(0, h - corner * 2)).position(x: edge / 2, y: h / 2)
                handle(.right).frame(width: edge, height: max(0, h - corner * 2)).position(x: w - edge / 2, y: h / 2)
                if !isCollapsed {
                    handle(.top).frame(width: max(0, w - corner * 2), height: 4).position(x: w / 2, y: 2)
                    handle(.bottom).frame(width: max(0, w - corner * 2), height: edge).position(x: w / 2, y: h - edge / 2)
                    handle([.top, .left]).frame(width: corner, height: corner).position(x: corner / 2, y: corner / 2)
                    handle([.top, .right]).frame(width: corner, height: corner).position(x: w - corner / 2, y: corner / 2)
                    handle([.bottom, .left]).frame(width: corner, height: corner).position(x: corner / 2, y: h - corner / 2)
                    handle([.bottom, .right]).frame(width: corner, height: corner).position(x: w - corner / 2, y: h - corner / 2)
                }
            }
        }
    }

    private func handle(_ edges: ResizeEdges) -> some View {
        ResizeHandle(fenceID: fenceID, edges: edges)
    }
}

private struct ResizeHandle: View {
    let fenceID: UUID
    let edges: ResizeEdges

    @EnvironmentObject private var coordinator: FenceCoordinator
    @State private var start: (mouse: CGPoint, frame: CGRect)?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { cursor.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        let mouse = NSEvent.mouseLocation
                        if start == nil {
                            start = (mouse, coordinator.expandedFrame(fenceID))
                            coordinator.beginInteraction(fenceID)
                        }
                        guard let start else { return }
                        let delta = CGSize(width: mouse.x - start.mouse.x, height: mouse.y - start.mouse.y)
                        coordinator.updateLiveFrame(fenceID, coordinator.resizedFrame(from: start.frame, edges: edges, delta: delta))
                    }
                    .onEnded { _ in
                        start = nil
                        coordinator.endInteraction(fenceID)
                    }
            )
    }

    private var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: position, directions: .all)
        }
        return edges == .left || edges == .right ? .resizeLeftRight : .resizeUpDown
    }

    @available(macOS 15.0, *)
    private var position: NSCursor.FrameResizePosition {
        switch edges {
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        case [.top, .left]: .topLeft
        case [.top, .right]: .topRight
        case [.bottom, .left]: .bottomLeft
        default: .bottomRight
        }
    }
}
