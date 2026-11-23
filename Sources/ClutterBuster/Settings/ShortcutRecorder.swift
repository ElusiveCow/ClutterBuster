import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A field showing a shortcut. Click it and press keys to change it; Esc keeps the old one
/// and Delete clears it.
struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: KeyShortcut?
    let onChange: (KeyShortcut?) -> Void
    var onRecording: (Bool) -> Void = { _ in }
    /// Called with why keys pressed can't be a shortcut.
    var onRejected: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        update(view)
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) { update(view) }

    private func update(_ view: ShortcutRecorderView) {
        view.shortcut = shortcut
        view.onChange = onChange
        view.onRecording = onRecording
        view.onRejected = onRejected
    }
}

final class ShortcutRecorderView: NSView {
    var shortcut: KeyShortcut? { didSet { if shortcut != oldValue { needsDisplay = true } } }
    var onChange: (KeyShortcut?) -> Void = { _ in }
    var onRecording: (Bool) -> Void = { _ in }
    var onRejected: (String) -> Void = { _ in }

    private var recording = false {
        didSet {
            guard recording != oldValue else { return }
            held = []
            needsDisplay = true
            onRecording(recording)
        }
    }
    /// Modifiers held so far while recording.
    private var held: NSEvent.ModifierFlags = []

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if recording {
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        recording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    private var resignObserver: NSObjectProtocol?

    // Closing Settings or switching apps stops recording, which puts the old shortcut back.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        recording = false
        resignObserver.map(NotificationCenter.default.removeObserver)
        resignObserver = nil
        if let newWindow {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: newWindow, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.recording else { return }
                    self.window?.makeFirstResponder(nil)
                    self.recording = false
                }
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func flagsChanged(with event: NSEvent) {
        guard recording else { return super.flagsChanged(with: event) }
        held = event.modifierFlags.intersection([.control, .option, .shift, .command])
        needsDisplay = true
    }

    // Command and Control keys come here before keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        record(event)
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        switch Int(event.keyCode) {
        case kVK_Escape where modifiers.isEmpty:
            window?.makeFirstResponder(nil)
            return
        case kVK_Delete where modifiers.isEmpty, kVK_ForwardDelete where modifiers.isEmpty:
            window?.makeFirstResponder(nil)
            onChange(nil)
            return
        default:
            break
        }
        let new = KeyShortcut(keyCode: event.keyCode, flags: modifiers)
        if let problem = new.problem {
            NSSound.beep()
            onRejected(problem)
            return
        }
        window?.makeFirstResponder(nil)
        onChange(new)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        shape.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let text: String
        let color: NSColor
        if recording {
            text = held.isEmpty ? "Type shortcut\u{2026}" : KeyShortcut.symbols(for: KeyShortcut(keyCode: 0, flags: held).modifiers)
            color = .secondaryLabelColor
        } else if let shortcut {
            text = shortcut.displayName
            color = .labelColor
        } else {
            text = "Click to set"
            color = .tertiaryLabelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: shortcut == nil || recording ? .regular : .medium),
            .foregroundColor: color,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

/// Settings for the Peek at Fences shortcut.
struct KeyboardSection: View {
    @ObservedObject var peek: PeekShortcut
    @State private var rejected: String?

    var body: some View {
        Section {
            LabeledContent("Peek at fences") {
                HStack(spacing: 6) {
                    ShortcutRecorder(
                        shortcut: peek.shortcut,
                        onChange: { new in
                            rejected = nil
                            peek.shortcut = new
                        },
                        onRecording: { recording in
                            if recording { rejected = nil }
                            peek.setRecording(recording)
                        },
                        onRejected: { rejected = $0 }
                    )
                    .frame(width: 150, height: 24)
                    // In line with the label, which the form lines up by text baseline.
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                    .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                    if peek.shortcut != .controlSpace {
                        Button("Use \(KeyShortcut.controlSpace.displayName)") {
                            rejected = nil
                            peek.shortcut = .controlSpace
                        }
                        .controlSize(.small)
                    }
                }
            }
            if let rejected {
                Text(rejected)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let problem = peek.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Press the shortcut in any app to bring every fence and the toolbar above your windows. Press it again, press Esc or click outside the fences to put them back; opening an item does too. Hidden fences come out just for the peek.\n\nClick the shortcut and press new keys to change it. Esc keeps the old one, and Delete clears it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
