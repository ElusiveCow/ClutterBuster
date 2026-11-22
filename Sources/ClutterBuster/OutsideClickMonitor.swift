import AppKit

/// Reports mouse-downs outside a set of windows: in other apps, on the Finder desktop, or in
/// Clutter Buster's other windows. Clicking the desktop doesn't reliably change the key
/// window, so this watches the clicks themselves. Opening a menu from the menu bar counts
/// too, since those clicks never reach the mouse monitors.
@MainActor
final class OutsideClickMonitor {
    private let inside: () -> [NSWindow]
    private let onOutsideClick: () -> Void
    private var monitors: [Any] = []
    private var menuObserver: NSObjectProtocol?

    init(inside: @escaping () -> [NSWindow], onOutsideClick: @escaping () -> Void) {
        self.inside = inside
        self.onOutsideClick = onOutsideClick
    }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.report("click in another app") }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.isInside(event.window) else { return }
                self.report("click in \(event.window.map { String(describing: type(of: $0)) } ?? "no window")")
            }
            return event
        }) {
            monitors.append(local)
        }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Context menus opened inside (a right-click in a text field) aren't outside.
                guard let self, !self.isInside(NSApp.currentEvent?.window) else { return }
                self.report("menu opened")
            }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        menuObserver = nil
    }

    private func isInside(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return inside().contains { $0 === window }
    }

    private func report(_ reason: String) {
        Log.write("outside click: \(reason)")
        onOutsideClick()
    }
}
