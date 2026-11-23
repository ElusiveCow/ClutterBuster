import AppKit
import SwiftUI

/// Borderless window that sits just above the Desktop icons and below every app window.
final class DesktopLevelWindow: NSWindow {
    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        level = Self.desktopLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Called for every mouse-down in the fence, before it's handled.
    var onMouseDown: (() -> Void)?
    /// Called for Command-V while no text is being edited. Returns false if nothing was pasted.
    var onPaste: (() -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: onMouseDown?()
        default: break
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v", !(firstResponder is NSText) {
            if onPaste?() != true { NSSound.beep() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
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
        window.onMouseDown = { [weak coordinator] in coordinator?.raise(fenceID) }
        window.onPaste = { [weak coordinator] in coordinator?.paste(into: fenceID) ?? false }
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
