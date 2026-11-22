import SwiftUI

/// Invisible strips along each edge and corner that resize the fence when dragged, plus a
/// grip in the bottom-right corner while the fence is hovered. Collapsed fences only resize
/// horizontally.
struct ResizeHandles: View {
    let fenceID: UUID
    let isCollapsed: Bool
    var showGrip = false
    var gripColor: Color = .white.opacity(0.7)

    private let edge: CGFloat = 10
    /// Kept thin so it doesn't eat into the title bar, which moves the fence.
    private let topEdge: CGFloat = 5
    private let corner: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                if !isCollapsed {
                    ResizeGrip(color: gripColor)
                        .opacity(showGrip ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: showGrip)
                        .position(x: w - 9, y: h - 9)
                        .allowsHitTesting(false)
                }
                handle(.left).frame(width: edge, height: max(0, h - corner * 2)).position(x: edge / 2, y: h / 2)
                handle(.right).frame(width: edge, height: max(0, h - corner * 2)).position(x: w - edge / 2, y: h / 2)
                if !isCollapsed {
                    handle(.top).frame(width: max(0, w - corner * 2), height: topEdge).position(x: w / 2, y: topEdge / 2)
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

/// Three diagonal strokes, like a window's resize corner.
private struct ResizeGrip: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            for inset in [3.0, 7.0, 11.0] {
                var path = Path()
                path.move(to: CGPoint(x: size.width - 1, y: inset))
                path.addLine(to: CGPoint(x: inset, y: size.height - 1))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .frame(width: 14, height: 14)
        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
    }
}

private struct ResizeHandle: View {
    let fenceID: UUID
    let edges: ResizeEdges

    @EnvironmentObject private var coordinator: FenceCoordinator
    @State private var start: (mouse: CGPoint, frame: CGRect)?
    @GestureState private var resizing = false
    @State private var inside = false
    @State private var cursorPushed = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { hovering in
                inside = hovering
                // The pointer often slips off the strip mid-drag; keep the resize cursor until the drag ends.
                if hovering { pushCursor() } else if start == nil { popCursor() }
            }
            .onDisappear(perform: popCursor)
            // A cancelled drag never calls onEnded, but its gesture state still resets.
            .onChange(of: resizing) { _, active in
                if !active, start != nil {
                    start = nil
                    coordinator.endInteraction(fenceID)
                    if !inside { popCursor() }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($resizing) { _, state, _ in state = true }
                    .onChanged { _ in
                        let mouse = NSEvent.mouseLocation
                        if start == nil {
                            start = (mouse, coordinator.expandedFrame(fenceID))
                            coordinator.beginInteraction(fenceID)
                        }
                        guard let start else { return }
                        let delta = CGSize(width: mouse.x - start.mouse.x, height: mouse.y - start.mouse.y)
                        coordinator.updateLiveFrame(fenceID, coordinator.resizedFrame(fenceID, from: start.frame, edges: edges, delta: delta))
                    }
                    .onEnded { _ in
                        start = nil
                        coordinator.endInteraction(fenceID)
                        if !inside { popCursor() }
                    }
            )
    }

    private func pushCursor() {
        guard !cursorPushed else { return }
        cursor.push()
        cursorPushed = true
    }

    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
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
