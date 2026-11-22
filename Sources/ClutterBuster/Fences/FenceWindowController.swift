import AppKit
import SwiftUI

/// Borderless window that sits just above the Desktop icons and below every app window.
final class DesktopLevelWindow: NSWindow {
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets clicks land on the first try even though Clutter Buster is a background app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        // Window frames are set explicitly. Letting the content resize its window can loop
        // forever while a window is still at its initial size.
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class FenceWindowController {
    let window = DesktopLevelWindow()

    init(fenceID: UUID, coordinator: FenceCoordinator) {
        let root = FenceView(fenceID: fenceID)
            .environmentObject(coordinator.store)
            .environmentObject(coordinator)
        window.contentView = FirstMouseHostingView(rootView: root)
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
