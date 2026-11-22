import AppKit

/// Moves real Desktop icons through Finder so each fence's icons sit in a stack hidden
/// underneath it. Files never leave the Desktop folder.
@MainActor
final class DesktopIconService {
    nonisolated static let desktopURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop", isDirectory: true)

    nonisolated static func isOnDesktop(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == desktopURL.standardizedFileURL.path
    }

    var onAccessDenied: () -> Void = {}

    private let queue = DispatchQueue(label: "com.elusivecow.ClutterBuster.finder")
    private var pending: [String: CGPoint] = [:]
    private var flushScheduled = false
    private var inFlight = false

    // MARK: Geometry

    var iconSize: CGFloat { finderViewSetting("iconSize") ?? 64 }
    var textSize: CGFloat { finderViewSetting("textSize") ?? 12 }

    /// Screen area a Desktop icon and its two-line label can occupy.
    var footprint: CGSize {
        CGSize(width: max(iconSize + 76, 140), height: iconSize + 12 + textSize * 2.8 + 8)
    }

    /// Finder position that centers an icon's footprint on `point` (Cocoa screen coordinates).
    func finderPosition(centeredOn point: CGPoint) -> CGPoint {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        // Finder positions mark the icon's center; the footprint starts 8 pt above the icon.
        let footprintCenterBelowPosition = footprint.height / 2 - iconSize / 2 - 8
        return CGPoint(x: point.x.rounded(), y: (mainHeight - point.y - footprintCenterBelowPosition).rounded())
    }

    /// Screen area (Cocoa coordinates) an icon at a Finder position occupies.
    func footprintRect(atFinderPosition position: CGPoint) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let size = footprint
        let top = position.y - iconSize / 2 - 8
        return CGRect(x: position.x - size.width / 2, y: mainHeight - top - size.height, width: size.width, height: size.height)
    }

    // MARK: Finder calls

    /// Queues icon moves. Rapid calls (such as while dragging a fence) are coalesced.
    func move(_ moves: [String: CGPoint]) {
        guard !moves.isEmpty else { return }
        pending.merge(moves) { $1 }
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.flushScheduled = false
                self?.flush()
            }
        }
    }

    /// Applies moves before returning. Used when quitting.
    func moveNow(_ moves: [String: CGPoint]) {
        let all = pending.merging(moves) { $1 }
        pending = [:]
        let failure = queue.sync { FinderScript.setPositions(all) }
        handle(failure)
    }

    func positions(completion: @escaping ([String: CGPoint]?) -> Void) {
        queue.async {
            let result = FinderScript.desktopPositions()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(self.unwrap(result)) }
            }
        }
    }

    func positionsNow() -> [String: CGPoint]? {
        unwrap(queue.sync { FinderScript.desktopPositions() })
    }

    private func flush() {
        guard !inFlight, !pending.isEmpty else { return }
        let moves = pending
        pending = [:]
        inFlight = true
        queue.async {
            let failure = FinderScript.setPositions(moves)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.inFlight = false
                    self.handle(failure)
                    self.flush()
                }
            }
        }
    }

    private func unwrap(_ result: Result<[String: CGPoint], FinderScript.Failure>) -> [String: CGPoint]? {
        switch result {
        case .success(let positions): return positions
        case .failure(let failure):
            handle(failure)
            return nil
        }
    }

    private func handle(_ failure: FinderScript.Failure?) {
        switch failure {
        case .notAuthorized:
            Log.write("Finder: not authorized (Automation permission missing)")
            onAccessDenied()
        case .failed(let message):
            Log.write("Finder: script failed: \(message)")
        case nil: break
        }
    }

    private func finderViewSetting(_ key: String) -> CGFloat? {
        let settings = CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, "com.apple.finder" as CFString) as? [String: Any]
        let iconView = settings?["IconViewSettings"] as? [String: Any]
        return (iconView?[key] as? NSNumber).map { CGFloat($0.doubleValue) }
    }
}
