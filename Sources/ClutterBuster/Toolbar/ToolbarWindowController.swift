import AppKit
import SwiftUI

struct ToolbarActions {
    var search: () -> Void
    var newFence: () -> Void
    var collapseAll: () -> Void
    var expandAll: () -> Void
    var openSettings: () -> Void
}

/// Floating bar on the desktop with quick actions. Drag its background to move it.
@MainActor
final class ToolbarWindowController {
    let window = DesktopLevelWindow()
    private let store: FenceStore
    private let size = CGSize(width: 480, height: 44)

    init(store: FenceStore, actions: ToolbarActions) {
        self.store = store
        let view = ToolbarView(actions: actions, onMove: { [weak window] delta, start in
            window?.setFrameOrigin(CGPoint(x: start.x + delta.width, y: start.y + delta.height))
        }, currentOrigin: { [weak window] in window?.frame.origin ?? .zero }, onMoveEnded: { [weak store, weak window] in
            store?.toolbarOrigin = window?.frame.origin
        })
        window.contentView = FirstMouseHostingView(rootView: view)
        window.setFrame(CGRect(origin: clamped(store.toolbarOrigin ?? defaultOrigin), size: size), display: true)
    }

    /// Keeps the whole toolbar on the screen it was saved on (or the main screen).
    private func clamped(_ origin: CGPoint) -> CGPoint {
        let rect = CGRect(origin: origin, size: size)
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(rect) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return CGPoint(
            x: min(max(origin.x, screen.minX), screen.maxX - size.width),
            y: min(max(origin.y, screen.minY), screen.maxY - size.height)
        )
    }

    var isVisible: Bool { window.isVisible }

    func show() { window.orderFrontRegardless() }
    func hide() { window.orderOut(nil) }

    private var defaultOrigin: CGPoint {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return CGPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 12)
    }
}

private struct ToolbarView: View {
    let actions: ToolbarActions
    let onMove: (CGSize, CGPoint) -> Void
    let currentOrigin: () -> CGPoint
    let onMoveEnded: () -> Void

    @State private var dragStart: (mouse: CGPoint, origin: CGPoint)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2.fill")
                .foregroundStyle(.white.opacity(0.7))
                .help("Clutter Buster")
            Button(action: actions.search) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Search").lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Search fences, the desktop and your Mac")
            ToolbarButton(systemImage: "plus", title: "New Fence", action: actions.newFence)
            ToolbarButton(systemImage: "rectangle.compress.vertical", help: "Collapse all fences", action: actions.collapseAll)
            ToolbarButton(systemImage: "rectangle.expand.vertical", help: "Expand all fences", action: actions.expandAll)
            ToolbarButton(systemImage: "gearshape", help: "Settings", action: actions.openSettings)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(Color(white: 0.12).opacity(0.94)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in
                    let mouse = NSEvent.mouseLocation
                    if dragStart == nil { dragStart = (mouse, currentOrigin()) }
                    guard let start = dragStart else { return }
                    onMove(CGSize(width: mouse.x - start.mouse.x, height: mouse.y - start.mouse.y), start.origin)
                }
                .onEnded { _ in
                    dragStart = nil
                    onMoveEnded()
                }
        )
    }
}

private struct ToolbarButton: View {
    let systemImage: String
    var title: String?
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                if let title { Text(title).lineLimit(1).fixedSize() }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, title == nil ? 7 : 10)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help ?? title ?? "")
    }
}
