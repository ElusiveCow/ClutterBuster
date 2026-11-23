import AppKit
import SwiftUI

private final class SetupPanel: NSPanel {
    init(width: CGFloat) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: width, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
}

/// Floats a newly created fence above app windows with a card for its settings (see
/// `FenceSettingsForm`), starting with whether it holds files or is a sticky note.
/// Finishing settles the fence back to desktop level.
@MainActor
final class FenceSetupController {
    let fenceID: UUID
    var onFinish: (() -> Void)?
    /// After `onFinish`, when the card was closed with Done rather than a click elsewhere.
    var onDone: (() -> Void)?

    private let width: CGFloat = 300
    private let gap: CGFloat = 8
    private var height: CGFloat = 300
    private let panel: SetupPanel
    private let fenceWindow: NSWindow
    private var finished = false
    private lazy var outsideClicks = OutsideClickMonitor(
        inside: { [weak self] in [self?.fenceWindow, self?.panel].compactMap { $0 } },
        onOutsideClick: { [weak self] in self?.finish() }
    )

    init(fenceID: UUID, fenceWindow: NSWindow, coordinator: FenceCoordinator) {
        self.fenceID = fenceID
        self.fenceWindow = fenceWindow
        panel = SetupPanel(width: width)
        let view = FenceSetupCard(
            fenceID: fenceID,
            onDone: { [weak self] in
                guard let self, !self.finished else { return }
                self.finish()
                self.onDone?()
            },
            onHeight: { [weak self] height in
                self?.height = height
                self?.reposition()
            }
        )
        .environmentObject(coordinator.store)
        .environmentObject(coordinator)
        panel.contentView = FirstMouseHostingView(rootView: view)
    }

    func begin() {
        fenceWindow.level = .floating
        reposition()
        NSApp.activate(ignoringOtherApps: true)
        fenceWindow.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        outsideClicks.start()
    }

    /// Keeps the card attached below the fence, or above it when there's no room.
    func reposition() {
        let fence = fenceWindow.frame
        let screen = fenceWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? fence
        let x = min(max(fence.minX, screen.minX), screen.maxX - width)
        var y = fence.minY - gap - height
        if y < screen.minY {
            y = fence.maxY + gap + height <= screen.maxY ? fence.maxY + gap : screen.minY
        }
        panel.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
    }

    func finish() {
        guard !finished else { return }
        finished = true
        outsideClicks.stop()
        panel.orderOut(nil)
        fenceWindow.level = DesktopLevelWindow.desktopLevel
        onFinish?()
    }
}

private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct FenceSetupCard: View {
    let fenceID: UUID
    let onDone: () -> Void
    let onHeight: (CGFloat) -> Void

    @EnvironmentObject private var store: FenceStore
    @State private var showsMore = false

    var body: some View {
        VStack(spacing: 0) {
            if store.fence(fenceID) != nil {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: CardHeightKey.self, value: geo.size.height)
                    })
            }
            Spacer(minLength: 0)
        }
        .onPreferenceChange(CardHeightKey.self) { onHeight($0) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            FenceSettingsForm(fenceID: fenceID, showsMore: showsMore, showsStyle: true, focusesName: true, onSubmit: onDone)

            HStack {
                Button {
                    showsMore.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showsMore ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Text(showsMore ? "Fewer Options" : "More Options")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
            Text("Later, point at the fence and click its gear to change these.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.13)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12)))
        .onExitCommand(perform: onDone)
    }
}
