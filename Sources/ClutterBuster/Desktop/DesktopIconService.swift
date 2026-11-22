import AppKit

/// Hides fenced Desktop files from Finder and reads and sets Desktop icon positions through
/// Finder, so icons go back where they were when they leave a fence. Files never leave the
/// Desktop folder.
@MainActor
final class DesktopIconService {
    nonisolated static let desktopURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop", isDirectory: true)

    nonisolated static func isOnDesktop(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == desktopURL.standardizedFileURL.path
    }

    let hiddenFiles = HiddenFiles()
    var onAccessDenied: () -> Void = {}

    private let queue = DispatchQueue(label: "com.elusivecow.ClutterBuster.finder")
    // MARK: Geometry

    var iconSize: CGFloat { finderViewSetting("iconSize") ?? 64 }
    var textSize: CGFloat { finderViewSetting("textSize") ?? 12 }

    /// Screen area a Desktop icon and its two-line label can occupy.
    var footprint: CGSize {
        CGSize(width: max(iconSize + 76, 140), height: iconSize + 12 + textSize * 2.8 + 8)
    }

    /// Screen area (Cocoa coordinates) an icon at a Finder position occupies.
    func footprintRect(atFinderPosition position: CGPoint) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let size = footprint
        // Finder positions mark the icon's center; the footprint starts 8 pt above the icon.
        let top = position.y - iconSize / 2 - 8
        return CGRect(x: position.x - size.width / 2, y: mainHeight - top - size.height, width: size.width, height: size.height)
    }

    // MARK: Finder calls

    /// Applies moves before returning. Finder moves hidden icons too, so an icon can be placed
    /// before it's unhidden and show up right there.
    func moveNow(_ moves: [String: CGPoint]) {
        guard !moves.isEmpty else { return }
        let failure = queue.sync { FinderScript.setPositions(moves) }
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
