import AppKit

/// One connected screen, as a display layout remembers it.
struct ScreenInfo: Codable, Equatable {
    /// The display's UUID from `CGDisplayCreateUUIDFromDisplayID`, which stays the same when
    /// it's unplugged and plugged back in, and across restarts.
    var id: String
    var name: String?
    var frame: CGRect
    var visibleFrame: CGRect
}

/// Where the fences and the toolbar sit with one set of displays connected. What's in the
/// fences is shared by every layout; only where they sit changes.
struct DisplayLayout: Codable {
    /// The screens the frames were laid out on.
    var screens: [ScreenInfo]
    /// Each fence's expanded frame, keyed by its ID.
    var frames: [String: CGRect]
    var toolbarOrigin: CGPoint?
    var toolbarShape: ToolbarShape?
    var usedAt: Date
}

enum DisplaySet {
    /// How many layouts are kept. A laptop taken to meetings meets a new projector every
    /// week; the least recently used layouts go first.
    static let maxLayouts = 24

    /// The key for a set of displays: their UUIDs, uppercased and sorted, so the order macOS
    /// lists the screens in doesn't matter.
    static func key(for ids: [String]) -> String {
        Set(ids.map { $0.uppercased() }).sorted().joined(separator: "+")
    }

    /// The screens connected now, main screen first. A mirrored set counts once.
    @MainActor
    static func current() -> [ScreenInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let id = CFUUIDCreateString(nil, uuid) as String? else { return nil }
            return ScreenInfo(id: id, name: screen.localizedName, frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }

    static func describe(_ screens: [ScreenInfo]) -> String {
        screens.map { "\($0.name ?? "display") \(Int($0.frame.width))×\(Int($0.frame.height))" }.joined(separator: " + ")
    }
}

/// Fits a fence's frame, saved with one set of screens, onto another.
enum ScreenPlacement {
    /// How much of a fence's title bar has to be on a screen for it to be reachable.
    static let minimumVisibleTitle: CGFloat = 60

    /// Where a fence goes on `screens`. It follows the screen it was mostly on: on the same
    /// screen, at the same size and place, it stays put as long as its title bar can be
    /// reached; on a screen that moved or changed size, or on the main screen when its own is
    /// gone, it keeps its place relative to the screen's edges, and fits inside.
    /// `savedOn` empty (a layout from before per-display layouts) keeps reachable fences put.
    static func place(_ frame: CGRect, titleHeight: CGFloat, minimumSize: CGSize, savedOn old: [ScreenInfo], onto screens: [ScreenInfo]) -> CGRect {
        guard let main = screens.first else { return frame }
        if let source = old.max(by: { overlap($0.frame, frame) < overlap($1.frame, frame) }), overlap(source.frame, frame) > 0 {
            let target = screens.first { $0.id == source.id }
            if let target, target.frame == source.frame {
                return titleIsReachable(frame, titleHeight: titleHeight, on: screens.map(\.visibleFrame))
                    ? frame
                    : contain(frame, minimumSize: minimumSize, in: nearest(frame, screens).visibleFrame)
            }
            let destination = target ?? main
            return contain(map(frame, from: source.visibleFrame, to: destination.visibleFrame), minimumSize: minimumSize, in: destination.visibleFrame)
        }
        if titleIsReachable(frame, titleHeight: titleHeight, on: screens.map(\.visibleFrame)) { return frame }
        return contain(frame, minimumSize: minimumSize, in: nearest(frame, screens).visibleFrame)
    }

    static func titleBar(of frame: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    /// Whether enough of the title bar is on a screen to grab it.
    static func titleIsReachable(_ frame: CGRect, titleHeight: CGFloat, on visibleFrames: [CGRect]) -> Bool {
        let title = titleBar(of: frame, height: titleHeight)
        return visibleFrames.contains { visible in
            let shared = visible.intersection(title)
            return !shared.isNull && shared.height > 0 && shared.width >= minimumVisibleTitle
        }
    }

    /// Keeps the frame's share of the free space on each side, so a fence against an edge
    /// stays against it and one in the middle stays in the middle.
    static func map(_ frame: CGRect, from old: CGRect, to new: CGRect) -> CGRect {
        func position(_ value: CGFloat, _ size: CGFloat, _ oldMin: CGFloat, _ oldSize: CGFloat, _ newMin: CGFloat, _ newSize: CGFloat) -> CGFloat {
            let oldFree = oldSize - size
            let fraction = oldFree > 0 ? min(max((value - oldMin) / oldFree, 0), 1) : 0
            return newMin + fraction * max(newSize - size, 0)
        }
        return CGRect(
            x: position(frame.minX, frame.width, old.minX, old.width, new.minX, new.width),
            y: position(frame.minY, frame.height, old.minY, old.height, new.minY, new.height),
            width: frame.width, height: frame.height
        )
    }

    /// Shrinks the frame to fit `visible`, never below `minimumSize`, and moves it inside.
    /// One still too big keeps its top left corner, and so its title bar, on screen.
    static func contain(_ frame: CGRect, minimumSize: CGSize, in visible: CGRect) -> CGRect {
        let width = max(min(frame.width, visible.width), minimumSize.width)
        let height = max(min(frame.height, visible.height), minimumSize.height)
        let x = width > visible.width ? visible.minX : min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = height > visible.height ? visible.maxY - height : min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The screen showing most of the frame, or else the one closest to it.
    static func nearest(_ frame: CGRect, _ screens: [ScreenInfo]) -> ScreenInfo {
        if let best = screens.max(by: { overlap($0.visibleFrame, frame) < overlap($1.visibleFrame, frame) }),
           overlap(best.visibleFrame, frame) > 0 {
            return best
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return screens.min { distance(center, $0.visibleFrame) < distance(center, $1.visibleFrame) } ?? screens[0]
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        return shared.isNull ? 0 : shared.width * shared.height
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}

/// Every Desktop file Clutter Buster hides has to stay reachable: in a fence whose title bar
/// is on a screen and that shows on every Space, since the Finder desktop is the same on
/// all of them.
enum HiddenFileReachability {
    /// The hidden paths no such fence holds. Those should be unhidden.
    static func unreachable(hidden: Set<String>, fences: [Fence], visibleFrames: [CGRect]) -> Set<String> {
        let reachable = fences.filter { fence in
            fence.showsOnAllSpaces
                && ScreenPlacement.titleIsReachable(fence.frame, titleHeight: FenceMetrics(fence).titleHeight, on: visibleFrames)
        }
        return hidden.subtracting(reachable.flatMap { $0.items.map(\.path) })
    }
}
