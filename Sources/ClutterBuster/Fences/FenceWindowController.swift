import AppKit
import SwiftUI

/// Borderless window that sits just above the Desktop icons and below every app window.
final class DesktopLevelWindow: NSWindow {
    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        level = Self.desktopLevel
        collectionBehavior = Self.allSpaces
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
    }

    private static let allSpaces: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    /// `.managed` ties the window to one Space. A window at any level but the normal one is
    /// otherwise transient, and floats along to whichever Space is active.
    private static let oneSpace: NSWindow.CollectionBehavior = [.managed, .ignoresCycle]

    /// On every Space, or only on the one it was last ordered onto.
    var showsOnAllSpaces: Bool {
        get { collectionBehavior.contains(.canJoinAllSpaces) }
        set { collectionBehavior = newValue ? Self.allSpaces : Self.oneSpace }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Called for every mouse-down in the fence, before it's handled.
    var onMouseDown: (() -> Void)?
    /// Called for Command-V while no text is being edited. Returns false if nothing was pasted.
    var onPaste: (() -> Bool)?
    /// Called for Command-Z while no text is being edited, which undoes its own typing
    /// instead. Returns false if there was nothing to undo.
    var onUndo: (() -> Bool)?

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
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "z", !(firstResponder is NSText), let onUndo {
            if !onUndo() { NSSound.beep() }
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
        window.onUndo = { [weak coordinator] in coordinator?.undoLast() ?? false }
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
