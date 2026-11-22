import AppKit
import SwiftUI

enum ScreenCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

enum ScreenEdge {
    case top, bottom, left, right
}

/// The toolbar's shape: a bar along the top or bottom edge or anywhere else, a column along
/// the left or right edge, or a quarter circle tucked into a corner. Every shape has the
/// same buttons.
enum ToolbarShape: Equatable, Codable {
    case horizontal, vertical, cornerArc(ScreenCorner)

    /// Saved as "horizontal", "vertical" or "arc:" and the corner.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw.hasPrefix("arc:"), let corner = ScreenCorner(rawValue: String(raw.dropFirst("arc:".count))) {
            self = .cornerArc(corner)
        } else {
            self = raw == "vertical" ? .vertical : .horizontal
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .horizontal: try container.encode("horizontal")
        case .vertical: try container.encode("vertical")
        case .cornerArc(let corner): try container.encode("arc:" + corner.rawValue)
        }
    }
}

/// Where a dragged toolbar would land: free, along an edge, or in a corner.
enum ToolbarZone: Equatable {
    case free, edge(ScreenEdge), corner(ScreenCorner)

    var shape: ToolbarShape {
        switch self {
        case .free, .edge(.top), .edge(.bottom): .horizontal
        case .edge(.left), .edge(.right): .vertical
        case .corner(let corner): .cornerArc(corner)
        }
    }
}

/// Sizes, snap zones and the corner quarter circle's geometry, in points. Frames are in
/// Cocoa screen coordinates; positions inside a shape are in SwiftUI's top-left coordinates.
enum ToolbarLayout {
    static let thickness: CGFloat = 44
    static let horizontalLength: CGFloat = 480
    static let arcRadius: CGFloat = 260
    static let bubbleSize: CGFloat = 44
    static let buttonSize: CGFloat = 30
    static let buttonSpacing: CGFloat = 6
    /// Gap between a bar and the screen edge it's snapped to. Corners sit flush.
    static let edgeMargin: CGFloat = 8
    /// How close the pointer has to come to a corner, along both edges, to snap there.
    static let cornerZone: CGFloat = 90
    /// How close the pointer has to come to an edge to snap there.
    static let edgeZone: CGFloat = 48
    /// The search field a column grows sideways when its magnifier is clicked.
    static let columnFieldWidth: CGFloat = 230

    /// The shape's size with `buttons` buttons besides search.
    static func size(_ shape: ToolbarShape, buttons: Int) -> CGSize {
        switch shape {
        case .horizontal:
            return CGSize(width: horizontalLength, height: thickness)
        case .vertical:
            let slots = CGFloat(buttons + 1)
            return CGSize(width: thickness, height: slots * buttonSize + (slots - 1) * buttonSpacing + 16)
        case .cornerArc:
            return CGSize(width: arcRadius, height: arcRadius)
        }
    }

    static func zone(at point: CGPoint, in visible: CGRect) -> ToolbarZone {
        let left = point.x - visible.minX
        let right = visible.maxX - point.x
        let bottom = point.y - visible.minY
        let top = visible.maxY - point.y
        if min(left, right) < cornerZone, min(top, bottom) < cornerZone {
            switch (top < bottom, left < right) {
            case (true, true): return .corner(.topLeft)
            case (true, false): return .corner(.topRight)
            case (false, true): return .corner(.bottomLeft)
            case (false, false): return .corner(.bottomRight)
            }
        }
        let nearest = min(left, right, top, bottom)
        guard nearest < edgeZone else { return .free }
        switch nearest {
        case top: return .edge(.top)
        case bottom: return .edge(.bottom)
        case left: return .edge(.left)
        default: return .edge(.right)
        }
    }

    /// Where a toolbar `proposed` in `zone` lands: flush in a corner, pushed against an edge
    /// keeping its place along it, or left where it is. Always inside `visible`.
    static func frame(for zone: ToolbarZone, proposed: CGRect, in visible: CGRect) -> CGRect {
        let size = proposed.size
        var origin = proposed.origin
        switch zone {
        case .free: break
        case .edge(.top): origin.y = visible.maxY - size.height - edgeMargin
        case .edge(.bottom): origin.y = visible.minY + edgeMargin
        case .edge(.left): origin.x = visible.minX + edgeMargin
        case .edge(.right): origin.x = visible.maxX - size.width - edgeMargin
        case .corner(let corner):
            origin.x = corner.isLeft ? visible.minX : visible.maxX - size.width
            origin.y = corner.isTop ? visible.maxY - size.height : visible.minY
        }
        return clamped(CGRect(origin: origin, size: size), to: visible)
    }

    static func clamped(_ frame: CGRect, to visible: CGRect) -> CGRect {
        var frame = frame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }

    /// Whether the bubble rests at a bar's start (left or bottom end) rather than its far end:
    /// whichever end is nearer the screen's edge.
    static func bubbleAtStart(for frame: CGRect, shape: ToolbarShape, in visible: CGRect) -> Bool {
        shape == .vertical ? frame.midY <= visible.midY : frame.midX <= visible.midX
    }

    /// A bar of `shape` with its bubble resting at `bubble`, reaching toward the middle of
    /// the screen. For dropping the bubble without it jumping away from the pointer.
    static func frame(around bubble: CGRect, shape: ToolbarShape, buttons: Int, in visible: CGRect) -> (frame: CGRect, atStart: Bool) {
        let size = size(shape, buttons: buttons)
        switch shape {
        case .horizontal:
            let atStart = bubble.midX <= visible.midX
            let x = atStart ? bubble.minX : bubble.maxX - size.width
            return (CGRect(x: x, y: bubble.midY - size.height / 2, width: size.width, height: size.height), atStart)
        case .vertical:
            let atStart = bubble.midY <= visible.midY
            let y = atStart ? bubble.minY : bubble.maxY - size.height
            return (CGRect(x: bubble.midX - size.width / 2, y: y, width: size.width, height: size.height), atStart)
        case .cornerArc:
            return (CGRect(origin: bubble.origin, size: size), true)
        }
    }

    /// Where the bubble rests for a toolbar at `frame`: in the corner for a quarter circle,
    /// otherwise at one end of the bar.
    static func bubbleFrame(for frame: CGRect, shape: ToolbarShape, atStart: Bool) -> CGRect {
        let side = bubbleSize
        switch shape {
        case .horizontal:
            let x = atStart ? frame.minX : frame.maxX - side
            return CGRect(x: x, y: frame.midY - side / 2, width: side, height: side)
        case .vertical:
            let y = atStart ? frame.minY : frame.maxY - side
            return CGRect(x: frame.midX - side / 2, y: y, width: side, height: side)
        case .cornerArc(let corner):
            return CGRect(
                x: corner.isLeft ? frame.minX : frame.maxX - side,
                y: corner.isTop ? frame.maxY - side : frame.minY,
                width: side, height: side
            )
        }
    }

    // MARK: Quarter circle

    /// A point `inward` from the corner of an `arcRadius` square: x away from the vertical
    /// edge, y away from the horizontal one. Mirrors the layout for each corner.
    static func arcPoint(_ corner: ScreenCorner, inward: CGPoint) -> CGPoint {
        let r = arcRadius
        return CGPoint(
            x: corner.isLeft ? inward.x : r - inward.x,
            y: corner.isTop ? inward.y : r - inward.y
        )
    }

    /// The square's corner that sits in the screen's corner.
    static func arcCenter(_ corner: ScreenCorner) -> CGPoint { arcPoint(corner, inward: .zero) }

    /// Radius of the ring the buttons sit on, and the inner edge of that ring.
    static let arcButtonRadius = arcRadius - 28
    static let arcInnerRadius = arcRadius - 52

    /// Buttons spaced evenly around the arc, from the horizontal edge to the vertical one.
    static func arcButtonCenters(_ corner: ScreenCorner, count: Int) -> [CGPoint] {
        let first = 13.0, last = 77.0
        return (0..<count).map { index in
            let degrees = count > 1 ? first + (last - first) * Double(index) / Double(count - 1) : (first + last) / 2
            let angle = degrees * .pi / 180
            return arcPoint(corner, inward: CGPoint(x: arcButtonRadius * cos(angle), y: arcButtonRadius * sin(angle)))
        }
    }

    /// The search field: level, across the inside of the curve, clear of the button ring.
    static func arcFieldFrame(_ corner: ScreenCorner) -> CGRect {
        let height: CGFloat = 28
        let fromEdge: CGFloat = 94
        let start: CGFloat = 16
        // The far end stays inside the ring with room to spare.
        let top = fromEdge + height / 2
        let end = (pow(arcInnerRadius - 8, 2) - top * top).squareRoot()
        let a = arcPoint(corner, inward: CGPoint(x: start, y: fromEdge - height / 2))
        let b = arcPoint(corner, inward: CGPoint(x: end, y: fromEdge + height / 2))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Where the app's glyph sits, near the corner.
    static func arcGlyphCenter(_ corner: ScreenCorner) -> CGPoint { arcPoint(corner, inward: CGPoint(x: 36, y: 36)) }
}

/// A quarter disc with its center in `corner`, filling an `arcRadius` square.
struct QuarterDisc: Shape {
    let corner: ScreenCorner
    var radius = ToolbarLayout.arcRadius

    func path(in rect: CGRect) -> Path {
        let scale = rect.width / ToolbarLayout.arcRadius
        let r = radius * scale
        let center = CGPoint(x: corner.isLeft ? rect.minX : rect.maxX, y: corner.isTop ? rect.minY : rect.maxY)
        let sx: CGFloat = corner.isLeft ? 1 : -1
        let sy: CGFloat = corner.isTop ? 1 : -1
        var path = Path()
        path.move(to: center)
        path.addLine(to: CGPoint(x: center.x + sx * r, y: center.y))
        path.addArc(
            tangent1End: CGPoint(x: center.x + sx * r, y: center.y + sy * r),
            tangent2End: CGPoint(x: center.x, y: center.y + sy * r),
            radius: r
        )
        path.closeSubpath()
        return path
    }
}

/// The shape of the toolbar in a frame, for outlines and hit areas.
struct ToolbarOutlineShape: Shape {
    let shape: ToolbarShape

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .horizontal, .vertical:
            Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2)
        case .cornerArc(let corner):
            QuarterDisc(corner: corner).path(in: rect)
        }
    }
}

/// The "Collapse to bubble" setting.
@MainActor
final class ToolbarSettings: ObservableObject {
    static let shared = ToolbarSettings()
    static let bubbleKey = "toolbarBubble"

    @Published var collapsesToBubble: Bool {
        didSet { UserDefaults.standard.set(collapsesToBubble, forKey: Self.bubbleKey) }
    }

    private init() {
        collapsesToBubble = UserDefaults.standard.bool(forKey: Self.bubbleKey)
    }
}
