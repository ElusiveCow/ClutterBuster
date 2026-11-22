import AppKit

/// Reports mouse-downs outside a set of windows: in other apps, on the Finder desktop, or in
/// Clutter Buster's other windows. Clicking the desktop doesn't reliably change the key
/// window, so this watches the clicks themselves.
@MainActor
final class OutsideClickMonitor {
    private let inside: () -> [NSWindow]
    private let onOutsideClick: () -> Void
    private var monitors: [Any] = []

    init(inside: @escaping () -> [NSWindow], onOutsideClick: @escaping () -> Void) {
        self.inside = inside
        self.onOutsideClick = onOutsideClick
    }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.onOutsideClick() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.inside().contains(where: { $0 === event.window }) { self.onOutsideClick() }
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}
