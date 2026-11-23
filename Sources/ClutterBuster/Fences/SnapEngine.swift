import CoreGraphics

/// Works out where a moved or resized fence snaps to: flush against a neighbor with a small
/// gap, lined up with another fence's edges or center, or against the screen's visible
/// edges. Pure geometry in Cocoa screen coordinates with no state between calls, so a snap
/// lets go as soon as the pointer takes the fence past the threshold.
struct SnapEngine {
    enum Mode: Equatable {
        case move
        /// Only these edges follow the pointer, so only they snap.
        case resize(ResizeEdges)
    }

    /// `.x` snaps and guides are vertical lines at an x position; `.y` ones are horizontal.
    enum Axis: Equatable {
        case x, y
    }

    enum Reason: Equatable {
        case screenEdge
        /// `gap` away from the facing edge of `others[index]`.
        case flush(index: Int)
        /// Lined up with the same edge, or the center, of `others[index]`.
        case aligned(index: Int)
    }

    /// A line shown while a snap holds, at `position` on `axis`, running from `start` to `end`
    /// along the other axis. Snaps that share a line share one guide.
    struct Guide: Equatable {
        let axis: Axis
        let position: CGFloat
        var start: CGFloat
        var end: CGFloat
        var reasons: [Reason]
    }

    struct Result: Equatable {
        var frame: CGRect
        var guides: [Guide]
    }

    /// How close an edge or center has to come to a target to snap to it.
    var threshold: CGFloat = 10
    /// The space left between fences that sit side by side.
    var gap: CGFloat = 6
    /// A resized fence never snaps smaller than this. Moving doesn't check it.
    var minimumSize: CGSize = .zero

    /// Snaps `frame` to `others` (the other fences on the same screen) and `screen` (its
    /// visible frame). Each axis snaps on its own to the nearest target within the threshold.
    func snap(_ frame: CGRect, mode: Mode, others: [CGRect], screen: CGRect) -> Result {
        var snapped = frame
        for axis in [Axis.x, .y] {
            let best = candidates(for: snapped, axis: axis, mode: mode, others: others, screen: screen)
                .filter { abs($0.delta) <= threshold && (mode == .move || fits(apply($0, to: snapped, mode: mode))) }
                .min { abs($0.delta) < abs($1.delta) }
            if let best { snapped = apply(best, to: snapped, mode: mode) }
        }
        return Result(frame: snapped, guides: guides(for: snapped, mode: mode, others: others, screen: screen))
    }

    // MARK: Candidates

    private enum Feature {
        case min, mid, max
    }

    private struct Candidate {
        let axis: Axis
        let feature: Feature
        let target: CGFloat
        let reason: Reason
        /// How far the feature has to move to reach the target.
        let delta: CGFloat
    }

    /// The edges and center that can snap on `axis`: all three when moving, just the dragged
    /// edge when resizing.
    private func features(_ axis: Axis, mode: Mode) -> [Feature] {
        switch mode {
        case .move:
            return [.min, .mid, .max]
        case .resize(let edges):
            var features: [Feature] = []
            if edges.contains(axis == .x ? .left : .bottom) { features.append(.min) }
            if edges.contains(axis == .x ? .right : .top) { features.append(.max) }
            return features
        }
    }

    /// Every target on `axis` the frame's features could snap to. Flush targets come first
    /// so they win ties with alignments.
    private func candidates(for frame: CGRect, axis: Axis, mode: Mode, others: [CGRect], screen: CGRect) -> [Candidate] {
        let features = features(axis, mode: mode)
        var result: [Candidate] = []
        func add(_ feature: Feature, _ target: CGFloat, _ reason: Reason) {
            guard features.contains(feature) else { return }
            result.append(Candidate(axis: axis, feature: feature, target: target, reason: reason, delta: target - value(feature, of: frame, axis)))
        }
        for (index, other) in others.enumerated() where beside(frame, other, axis: axis) {
            add(.max, low(other, axis) - gap, .flush(index: index))
            add(.min, high(other, axis) + gap, .flush(index: index))
        }
        add(.min, low(screen, axis), .screenEdge)
        add(.max, high(screen, axis), .screenEdge)
        for (index, other) in others.enumerated() {
            add(.min, low(other, axis), .aligned(index: index))
            add(.max, high(other, axis), .aligned(index: index))
            add(.mid, middle(other, axis), .aligned(index: index))
        }
        return result
    }

    /// Whether two fences overlap, or nearly, across `axis`, so they can sit side by side on it.
    private func beside(_ frame: CGRect, _ other: CGRect, axis: Axis) -> Bool {
        let across: Axis = axis == .x ? .y : .x
        return low(frame, across) < high(other, across) + threshold && high(frame, across) > low(other, across) - threshold
    }

    private func apply(_ candidate: Candidate, to frame: CGRect, mode: Mode) -> CGRect {
        var frame = frame
        let delta = candidate.delta
        switch (mode, candidate.axis, candidate.feature) {
        case (.move, .x, _): frame.origin.x += delta
        case (.move, .y, _): frame.origin.y += delta
        case (.resize, .x, .min): frame.origin.x += delta; frame.size.width -= delta
        case (.resize, .x, _): frame.size.width += delta
        case (.resize, .y, .min): frame.origin.y += delta; frame.size.height -= delta
        case (.resize, .y, _): frame.size.height += delta
        }
        return frame
    }

    private func fits(_ frame: CGRect) -> Bool {
        frame.width >= minimumSize.width - 0.001 && frame.height >= minimumSize.height - 0.001
    }

    // MARK: Guides

    /// A guide for every target the snapped frame now sits on, whether it snapped there or
    /// was already there. A center line, which runs through the fences, only shows when no
    /// edge lines up on that axis.
    private func guides(for frame: CGRect, mode: Mode, others: [CGRect], screen: CGRect) -> [Guide] {
        var guides: [Guide] = []
        for axis in [Axis.x, .y] {
            var holding = candidates(for: frame, axis: axis, mode: mode, others: others, screen: screen).filter { abs($0.delta) < 0.5 }
            if holding.contains(where: { $0.feature != .mid }) { holding.removeAll { $0.feature == .mid } }
            for candidate in holding {
                let guide = guide(for: candidate, frame: frame, others: others)
                if let index = guides.firstIndex(where: { $0.axis == axis && abs($0.position - guide.position) < 0.5 }) {
                    guides[index].start = min(guides[index].start, guide.start)
                    guides[index].end = max(guides[index].end, guide.end)
                    guides[index].reasons += guide.reasons
                } else {
                    guides.append(guide)
                }
            }
        }
        return guides
    }

    /// Along a screen edge the guide runs the length of the fence. Between fences it spans
    /// both, and a flush guide runs down the middle of the gap.
    private func guide(for candidate: Candidate, frame: CGRect, others: [CGRect]) -> Guide {
        let axis = candidate.axis
        let across: Axis = axis == .x ? .y : .x
        var start = low(frame, across)
        var end = high(frame, across)
        var position = candidate.target
        switch candidate.reason {
        case .screenEdge:
            break
        case .flush(let index), .aligned(let index):
            let other = others[index]
            start = min(start, low(other, across))
            end = max(end, high(other, across))
            if case .flush = candidate.reason {
                position += candidate.feature == .max ? gap / 2 : -gap / 2
            }
        }
        return Guide(axis: axis, position: position, start: start, end: end, reasons: [candidate.reason])
    }

    // MARK: Geometry

    private func value(_ feature: Feature, of rect: CGRect, _ axis: Axis) -> CGFloat {
        switch feature {
        case .min: low(rect, axis)
        case .mid: middle(rect, axis)
        case .max: high(rect, axis)
        }
    }

    private func low(_ rect: CGRect, _ axis: Axis) -> CGFloat { axis == .x ? rect.minX : rect.minY }
    private func middle(_ rect: CGRect, _ axis: Axis) -> CGFloat { axis == .x ? rect.midX : rect.midY }
    private func high(_ rect: CGRect, _ axis: Axis) -> CGFloat { axis == .x ? rect.maxX : rect.maxY }
}
