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

/// Floats a newly created fence above app windows with a card for its name, color,
/// transparency and icons per row. Finishing settles the fence back to desktop level.
@MainActor
final class FenceSetupController {
    let fenceID: UUID
    var onFinish: (() -> Void)?

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
            onDone: { [weak self] in self?.finish() },
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
    @EnvironmentObject private var coordinator: FenceCoordinator
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let fence = store.fence(fenceID) {
                content(fence)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: CardHeightKey.self, value: geo.size.height)
                    })
            }
            Spacer(minLength: 0)
        }
        .onPreferenceChange(CardHeightKey.self) { onHeight($0) }
    }

    private func content(_ fence: Fence) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Fence name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(nameFocused ? 0.8 : 0), lineWidth: 1.5))
                .focused($nameFocused)
                .onSubmit(onDone)
                .onChange(of: name) { _, newName in coordinator.rename(fenceID, to: newName) }

            section("Color") {
                HStack(spacing: 8) {
                    ForEach(FenceColor.allCases) { color in
                        Button { coordinator.setColor(fenceID, color) } label: {
                            Circle()
                                .fill(Color(nsColor: color.body))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color.white.opacity(color == fence.color ? 0.95 : 0.15), lineWidth: color == fence.color ? 2 : 1))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(color.name)
                    }
                }
            }

            section("Transparency") {
                let current = OpacityPreset.nearest(to: fence.opacity)
                HStack(spacing: 5) {
                    ForEach(OpacityPreset.allCases) { preset in
                        Chip(title: preset.name, selected: preset == current) {
                            coordinator.setOpacity(fenceID, preset.value)
                        }
                    }
                }
            }

            section("Icons per row") {
                HStack(spacing: 5) {
                    ForEach(Array(AppSettings.iconsPerRowRange), id: \.self) { count in
                        Chip(title: "\(count)", selected: count == fence.iconsPerRow) {
                            coordinator.setIconsPerRow(fenceID, count)
                        }
                    }
                }
            }

            HStack {
                Text("Change these anytime from the \u{22EF} menu.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.13)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12)))
        .onExitCommand(perform: onDone)
        .onAppear {
            name = fence.title
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            content()
        }
    }
}

private struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? .white : .white.opacity(0.75))
                .frame(minWidth: 22)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(Capsule().fill(selected ? Color.accentColor : Color.white.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
