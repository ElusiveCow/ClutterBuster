import AppKit
import SwiftUI

/// Where the toolbar is and its shape, for placing cards beside it.
struct ToolbarPlacement {
    var frame: CGRect
    var shape: ToolbarShape
    var collapsed: Bool
}

private final class PromptPanel: NSPanel {
    init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: NewFilePromptController.width, height: 160),
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

    // Typing in another app carries on while the card is up.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NewFilePromptModel: ObservableObject {
    @Published var files: [FileFacts] = []
    @Published var remember = false
    @Published var hovering = false
}

/// A small card beside the toolbar asking which fence new Desktop files go in. Files that
/// arrive while it's up join it ("3 new files"). It never takes focus, and ignoring it
/// leaves the files on the Desktop.
@MainActor
final class NewFilePromptController {
    nonisolated static let width: CGFloat = 340
    /// How long the card waits for an answer, not counting time with the pointer over it.
    static let timeout: TimeInterval = 120

    var placement: () -> ToolbarPlacement? = { nil }
    var onChoose: (_ urls: [URL], _ fenceID: UUID, _ tabID: UUID?, _ remember: RememberTarget?) -> Void = { _, _, _, _ in }
    var onLeave: (_ urls: [URL], _ reason: String) -> Void = { _, _ in }

    private let model = NewFilePromptModel()
    private let store: FenceStore
    private let panel = PromptPanel()
    private var height: CGFloat = 160
    private var lastActivity = Date()
    private var timer: Timer?

    init(store: FenceStore) {
        self.store = store
        let view = NewFilePromptView(
            model: model,
            onChoose: { [weak self] fenceID, tabID in self?.choose(fenceID: fenceID, tabID: tabID) },
            onTabMenu: { [weak self] fenceID in self?.showTabMenu(fenceID) },
            onLeave: { [weak self] in self?.leave(reason: "chosen in the popup") },
            onHeight: { [weak self] height in
                guard let self, abs(self.height - height) > 0.5 else { return }
                self.height = height
                self.reposition()
            }
        )
        .environmentObject(store)
        panel.contentView = FirstMouseHostingView(rootView: view)
    }

    /// Shows the card for `urls`, adding them to any files it's already asking about.
    func ask(_ urls: [URL]) {
        let asking = Set(model.files.map(\.url.path))
        let added = urls.filter { !asking.contains($0.path) }.map(FileFacts.of)
        guard !added.isEmpty else { return }
        model.files += added
        if RememberTarget.shared(by: model.files) == nil { model.remember = false }
        lastActivity = Date()
        let names = model.files.map { "\"\($0.name)\"" }.joined(separator: ", ")
        Log.write("new files: popup asking about \(model.files.count) file(s): \(names)")
        reposition()
        if !panel.isVisible { panel.orderFrontRegardless() }
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// Files every file the card is asking about into the fence's tab, or the tab it's showing.
    func choose(fenceID: UUID, tabID: UUID?) {
        guard !model.files.isEmpty, let fence = store.fence(fenceID), fence.holdsItems else { return }
        let urls = model.files.map(\.url)
        let remember = model.remember ? RememberTarget.shared(by: model.files) : nil
        let tabID = tabID ?? fence.currentTab.id
        close()
        onChoose(urls, fenceID, tabID, remember)
    }

    func leave(reason: String) {
        guard !model.files.isEmpty else { return }
        let urls = model.files.map(\.url)
        close()
        onLeave(urls, reason)
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        model.files = []
        model.remember = false
    }

    /// Drops files that left the Desktop or went into a fence meanwhile, and gives up on an
    /// ignored card.
    private func tick() {
        let fenced = Set(store.fences.flatMap { $0.items.map(\.path) })
        let remaining = model.files.filter { facts in
            let gone = !FileManager.default.fileExists(atPath: facts.url.path)
            if gone || fenced.contains(facts.url.path) {
                Log.write("new files: popup no longer asking about \"\(facts.name)\", \(gone ? "it's gone" : "it's in a fence now")")
                return false
            }
            return true
        }
        if remaining.count != model.files.count { model.files = remaining }
        guard !model.files.isEmpty else {
            close()
            return
        }
        if model.hovering { lastActivity = Date() }
        if Date().timeIntervalSince(lastActivity) > Self.timeout {
            leave(reason: "the popup was ignored for \(Int(Self.timeout)) seconds")
        } else {
            reposition()
        }
    }

    private func showTabMenu(_ fenceID: UUID) {
        guard let fence = store.fence(fenceID), let content = panel.contentView else { return }
        let menu = NSMenu()
        for tab in fence.tabs {
            let item = ClosureMenuItem(title: tab.name) { [weak self] in self?.choose(fenceID: fenceID, tabID: tab.id) }
            item.state = tab.id == fence.currentTab.id ? .on : .off
            menu.addItem(item)
        }
        let point = content.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: content)
    }

    private func reposition() {
        let size = CGSize(width: Self.width, height: height)
        let toolbar = placement()
        let anchor = toolbar.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = Self.cardFrame(size: size, toolbar: toolbar, screen: screen)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Where the card goes: beside the toolbar on its side toward the middle of the screen.
    /// Below or above a bar, beside a column, and diagonally out from a corner, just past
    /// the quarter circle's curve or the bubble. Top right of the screen without a toolbar.
    nonisolated static func cardFrame(size: CGSize, toolbar: ToolbarPlacement?, screen: CGRect, gap: CGFloat = 10) -> CGRect {
        var origin: CGPoint
        if let toolbar {
            let bar = toolbar.frame
            switch toolbar.shape {
            case .horizontal:
                let below = bar.midY > screen.midY
                origin = CGPoint(x: bar.midX - size.width / 2, y: below ? bar.minY - gap - size.height : bar.maxY + gap)
            case .vertical:
                let onRight = bar.midX < screen.midX
                origin = CGPoint(x: onRight ? bar.maxX + gap : bar.minX - gap - size.width, y: bar.midY - size.height / 2)
            case .cornerArc(let corner):
                // The card's nearest corner sits on the diagonal, `gap` clear of the toolbar.
                let reach = toolbar.collapsed ? bar.width + gap : (bar.width + gap) / 2.squareRoot()
                let x = corner.isLeft ? bar.minX + reach : bar.maxX - reach - size.width
                let y = corner.isTop ? bar.maxY - reach - size.height : bar.minY + reach
                origin = CGPoint(x: x, y: y)
            }
        } else {
            origin = CGPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16)
        }
        let margin: CGFloat = 8
        origin.x = min(max(origin.x, screen.minX + margin), screen.maxX - size.width - margin)
        origin.y = min(max(origin.y, screen.minY + margin), screen.maxY - size.height - margin)
        return CGRect(origin: origin, size: size)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

private struct PromptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct NewFilePromptView: View {
    @ObservedObject var model: NewFilePromptModel
    let onChoose: (UUID, UUID?) -> Void
    let onTabMenu: (UUID) -> Void
    let onLeave: () -> Void
    let onHeight: (CGFloat) -> Void

    @EnvironmentObject private var store: FenceStore
    @ObservedObject private var themes = ThemeSettings.shared

    var body: some View {
        let style = ThemeStyle.chrome(themes.globalTheme)
        VStack(spacing: 0) {
            if let first = model.files.first {
                card(first, style: style)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: PromptHeightKey.self, value: geo.size.height)
                    })
            }
            Spacer(minLength: 0)
        }
        .onPreferenceChange(PromptHeightKey.self) { onHeight($0) }
        .onHover { model.hovering = $0 }
    }

    private func card(_ first: FileFacts, style: ThemeStyle) -> some View {
        let count = model.files.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first.url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 1 ? "New file: \(first.name)" : "\(count) new files")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(style.bodyText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(count == 1 ? "On the Desktop" : names)
                        .font(.system(size: 11))
                        .foregroundStyle(style.bodySecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Button(action: onLeave) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(style.bodySecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Leave on Desktop")
            }

            Text(count == 1 ? "Put it in" : "Put them in")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style.bodySecondary)
            // Sticky notes don't hold files.
            let targets = store.fences.filter(\.holdsItems)
            if targets.isEmpty {
                Text("There aren't any fences yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(style.bodySecondary)
            } else {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(targets) { fence in
                        fenceChoice(fence, style: style)
                    }
                }
            }

            HStack(spacing: 8) {
                if let target = RememberTarget.shared(by: model.files) {
                    Button { model.remember.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: model.remember ? "checkmark.square.fill" : "square")
                                .foregroundStyle(model.remember ? style.accent : style.bodySecondary)
                            Text(target.label)
                                .foregroundStyle(style.bodyText)
                                .lineLimit(1)
                        }
                        .font(.system(size: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Adds a rule in Settings \u{203A} New Desktop Files, so these go to the fence you pick from now on")
                }
                Spacer(minLength: 0)
                Button(action: onLeave) {
                    Text("Leave on Desktop")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(style.bodyText)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .overlay(Capsule().strokeBorder(style.bodyText.opacity(0.3)))
                        .contentShape(Capsule())
                        .padding(.horizontal, 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(style.solidBody))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(ThemeBorderView(border: style.border, cornerRadius: 12))
    }

    private var names: String {
        let shown = model.files.prefix(3).map(\.name)
        let more = model.files.count - shown.count
        return shown.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
    }

    /// A fence's button files into the tab it's showing; its arrow lists the other tabs.
    private func fenceChoice(_ fence: Fence, style: ThemeStyle) -> some View {
        HStack(spacing: 0) {
            Button { onChoose(fence.id, nil) } label: {
                Text(fence.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(style.bodyText)
                    .lineLimit(1)
                    .padding(.leading, 10)
                    .padding(.trailing, fence.tabs.count > 1 ? 6 : 10)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Put in \(fence.title) \u{203A} \(fence.currentTab.name)")
            if fence.tabs.count > 1 {
                Rectangle()
                    .fill(style.bodyText.opacity(0.2))
                    .frame(width: 1, height: 14)
                Button { onTabMenu(fence.id) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(style.bodyText.opacity(0.8))
                        .frame(width: 22, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Choose a tab in \(fence.title)")
            }
        }
        .background(Capsule().fill(style.bodyText.opacity(style.isLight ? 0.08 : 0.14)))
    }
}
