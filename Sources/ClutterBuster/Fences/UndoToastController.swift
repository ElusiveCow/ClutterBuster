import AppKit
import Combine
import SwiftUI

private final class ToastPanel: NSPanel {
    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: UndoToastController.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    // Typing in another app carries on while the toast is up.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class UndoToastModel: ObservableObject {
    @Published var toast: UndoHistory.Toast?
    @Published var endsAt = Date()
    @Published var width = UndoToastController.size.width
}

/// A small dark toast beside the toolbar after a fence, a tab or an item is deleted or
/// removed, with an Undo button for that action and a bar counting down the seconds until
/// it goes. It never takes focus. Any newer action replaces it.
@MainActor
final class UndoToastController {
    /// The narrowest it gets. Longer messages widen it up to `maxWidth`, then truncate.
    nonisolated static let size = CGSize(width: 360, height: 78)
    nonisolated static let maxWidth: CGFloat = 520
    static let duration: TimeInterval = 8
    static let messageFont = NSFont.systemFont(ofSize: 14, weight: .medium)

    var placement: () -> ToolbarPlacement? = { nil }

    private let history: UndoHistory
    private let model = UndoToastModel()
    private let panel = ToastPanel()
    /// The action the toast is for.
    private(set) var entryID: UUID?
    private var hideWork: DispatchWorkItem?
    private var historyObserver: AnyCancellable?

    init(history: UndoHistory) {
        self.history = history
        let view = UndoToastView(model: model) { [weak self] in self?.undo() }
        panel.contentView = FirstMouseHostingView(rootView: view)
        // @Published sends before the value changes; check once it has.
        historyObserver = history.$entries.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.entryID, !self.history.contains(id) else { return }
                self.hide()
            }
        }
    }

    var isVisible: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }
    var message: String? { model.toast?.message }

    /// Shows the toast for a newly recorded action, or takes the old one away for an action
    /// without a toast.
    func show(_ entry: UndoHistory.Entry) {
        guard let toast = entry.toast else {
            hide()
            return
        }
        entryID = entry.id
        model.toast = toast
        model.endsAt = Date().addingTimeInterval(Self.duration)
        model.width = Self.width(for: toast.message)
        reposition()
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
        Log.write("undo toast: \(toast.message), at \(panel.frame.integral)")
    }

    /// The Undo button: undoes the toast's own action, even if it's no longer the newest.
    func undo() {
        guard let id = entryID else { return }
        hide()
        if !history.undo(id) { NSSound.beep() }
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        entryID = nil
        guard model.toast != nil || panel.isVisible else { return }
        panel.orderOut(nil)
        model.toast = nil
    }

    /// Wide enough for the message beside the icon and the Undo button.
    static func width(for message: String) -> CGFloat {
        let text = (message as NSString).size(withAttributes: [.font: messageFont]).width
        // Padding, icon and gap on the left; gaps, the Undo button and padding on the right.
        let width = (16 + 24 + 12 + text + 32 + 62 + 16).rounded(.up)
        return min(max(width, size.width), maxWidth)
    }

    /// Beside the toolbar toward the middle of the screen, as the new-file card goes.
    private func reposition() {
        let toolbar = placement()
        let anchor = toolbar.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let size = CGSize(width: model.width, height: Self.size.height)
        panel.setFrame(NewFilePromptController.cardFrame(size: size, toolbar: toolbar, screen: screen), display: true)
    }
}

private struct UndoToastView: View {
    @ObservedObject var model: UndoToastModel
    let onUndo: () -> Void

    var body: some View {
        if let toast = model.toast {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: toast.symbol)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 24)
                    Text(toast.message)
                        .font(Font(UndoToastController.messageFont))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button(action: onUndo) {
                        Text("Undo")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .systemBlue)))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Undo this")
                }
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let remaining = max(model.endsAt.timeIntervalSince(context.date), 0)
                    HStack(spacing: 10) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.18))
                                Capsule()
                                    .fill(Color(nsColor: .systemBlue))
                                    .frame(width: geo.size.width * remaining / UndoToastController.duration)
                            }
                        }
                        .frame(height: 4)
                        Text("\(Int(remaining.rounded(.up)))s")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 22, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(width: model.width, height: UndoToastController.size.height)
            .background(
                ZStack {
                    FrostedBackground()
                    Color.black.opacity(0.45)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.14)))
            .environment(\.colorScheme, .dark)
        }
    }
}

/// Dark frosted glass that blurs whatever is behind the window.
private struct FrostedBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
