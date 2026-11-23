import AppKit
import SwiftUI

/// Where a dragged fence will land if it's let go now: a faint dashed outline of the snapped
/// frame, like the toolbar's, with thin lines along what it has snapped to. One click-through
/// window covers the screen being dragged on, just below the dragged fence.
@MainActor
final class SnapPreviewWindow: NSWindow {
    private let model = SnapPreviewModel()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SnapPreviewView(model: model))
        // The window covers the screen; its content mustn't resize it.
        hosting.sizingOptions = []
        contentView = hosting
    }

    /// Shows `outline` (a display frame) and `guides` on `screen`, below `fence`.
    func show(outline: CGRect, guides: [SnapEngine.Guide], on screen: CGRect, below fence: NSWindow) {
        model.origin = CGPoint(x: screen.minX, y: screen.maxY)
        model.outline = outline
        model.guides = guides
        if frame != screen { setFrame(screen, display: false) }
        level = fence.level
        alphaValue = 1
        if !isVisible || orderedIndex <= fence.orderedIndex { order(.below, relativeTo: fence.windowNumber) }
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
        model.outline = nil
        model.guides = []
    }

    /// Fades out while the fence settles into the outline.
    func fadeOut() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.hide()
            }
        }
    }
}

@MainActor
private final class SnapPreviewModel: ObservableObject {
    @Published var outline: CGRect?
    @Published var guides: [SnapEngine.Guide] = []
    /// The window's top-left corner in screen coordinates.
    var origin: CGPoint = .zero
}

private struct SnapPreviewView: View {
    @ObservedObject var model: SnapPreviewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for guide in model.guides {
                    let (from, to) = ends(of: guide)
                    var line = Path()
                    line.move(to: from)
                    line.addLine(to: to)
                    context.stroke(line, with: .color(.black.opacity(0.25)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    context.stroke(line, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                }
            }
            if let outline = model.outline {
                DropOutline(shape: RoundedRectangle(cornerRadius: FenceView.cornerRadius))
                    .frame(width: outline.width, height: outline.height)
                    .offset(x: outline.minX - model.origin.x, y: model.origin.y - outline.maxY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// The guide's ends in the view's top-left coordinates, a little past the fences it spans.
    private func ends(of guide: SnapEngine.Guide) -> (CGPoint, CGPoint) {
        let overhang: CGFloat = 8
        let origin = model.origin
        switch guide.axis {
        case .x:
            let x = guide.position - origin.x
            return (CGPoint(x: x, y: origin.y - guide.end - overhang), CGPoint(x: x, y: origin.y - guide.start + overhang))
        case .y:
            let y = origin.y - guide.position
            return (CGPoint(x: guide.start - origin.x - overhang, y: y), CGPoint(x: guide.end - origin.x + overhang, y: y))
        }
    }
}
