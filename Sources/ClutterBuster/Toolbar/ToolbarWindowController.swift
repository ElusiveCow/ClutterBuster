import AppKit
import Combine
import SwiftUI

struct ToolbarActions {
    var newFence: () -> Void
    var collapseAll: () -> Void
    var expandAll: () -> Void
    var toggleFences: () -> Void
    var openSettings: () -> Void
}

/// The toolbar's buttons besides search, the same in every shape.
enum ToolbarItem: CaseIterable {
    case newFence, collapseAll, expandAll, toggleFences, snap, settings
}

/// What the toolbar shows. The window controller changes it and sizes the window to match.
@MainActor
final class ToolbarModel: ObservableObject {
    @Published var shape: ToolbarShape = .horizontal
    /// Resting as the bubble rather than the full shape.
    @Published var collapsed = false
    /// A column's search field, grown sideways from its magnifier.
    @Published var columnSearchOpen = false
    /// Where content stays pinned while the window grows or shrinks around it: the corner
    /// for a quarter circle, otherwise the end the bubble rests at.
    @Published var anchor: Alignment = .center
    /// A column's field opens toward the middle of the screen.
    var fieldOnRight: Bool { anchor.horizontal == .leading }
}

/// The toolbar's callbacks into its window controller.
struct ToolbarEvents {
    var dragChanged: () -> Void
    var dragEnded: () -> Void
    var hoverChanged: (Bool) -> Void
    var bubbleClicked: () -> Void
    var openColumnSearch: () -> Void
}

/// Floating bar on the desktop with quick actions. Dragging it to a screen edge or corner
/// snaps it there and changes its shape: horizontal along the top or bottom, a column along
/// the sides, a quarter circle in a corner. Anywhere else it stays a horizontal bar. It can
/// also rest as a small bubble that opens on hover or click.
@MainActor
final class ToolbarWindowController {
    let window = DesktopLevelWindow()
    private let store: FenceStore
    private let search: SearchController
    private let model = ToolbarModel()
    private let settings = ToolbarSettings.shared
    private let outline = SnapOutlineWindow()
    /// The full shape's frame, also while the window shows the bubble or a column's field.
    private var barFrame: CGRect
    /// The bubble rests at the bar's left or bottom end rather than its far end.
    private var bubbleAtStart = true
    private var drag: (mouse: CGPoint, frame: CGRect)?
    private var dragZone: ToolbarZone?
    private var hovering = false
    private var collapseWork: DispatchWorkItem?
    private var bubbleObserver: AnyCancellable?

    private static let buttons = ToolbarItem.allCases.count

    init(store: FenceStore, fences: FenceCoordinator, search: SearchController, actions: ToolbarActions) {
        self.store = store
        self.search = search
        let shape = store.toolbarShape ?? .horizontal
        let size = ToolbarLayout.size(shape, buttons: Self.buttons)
        barFrame = CGRect(origin: store.toolbarOrigin ?? Self.defaultOrigin(size), size: size)
        model.shape = shape
        model.collapsed = settings.collapsesToBubble
        barFrame = settled(barFrame, shape: shape)
        bubbleAtStart = ToolbarLayout.bubbleAtStart(for: barFrame, shape: shape, in: Self.visibleFrame(at: CGPoint(x: barFrame.midX, y: barFrame.midY)))
        updateAnchor()

        let events = ToolbarEvents(
            dragChanged: { [weak self] in self?.dragChanged(at: NSEvent.mouseLocation) },
            dragEnded: { [weak self] in self?.dragEnded(at: NSEvent.mouseLocation) },
            hoverChanged: { [weak self] in self?.hoverChanged($0) },
            bubbleClicked: { [weak self] in self?.expand() },
            openColumnSearch: { [weak self] in self?.openColumnSearch() }
        )
        window.contentView = FirstMouseHostingView(rootView: ToolbarView(model: model, fences: fences, search: search, actions: actions, events: events))
        applyFrame(animated: false)

        search.prepareField = { [weak self] in self?.prepareForSearch() ?? false }
        search.onClose = { [weak self] in self?.searchClosed() }
        // @Published sends before the value changes; act once it has.
        bubbleObserver = settings.$collapsesToBubble.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] on in
            MainActor.assumeIsolated { self?.bubbleSettingChanged(on) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen() }
        }
        Log.write("toolbar: \(shape)\(model.collapsed ? ", collapsed to a bubble" : "") at \(barFrame.origin)")
    }

    var isVisible: Bool { window.isVisible }

    func show() { window.orderFrontRegardless() }

    func hide() {
        outline.fadeOut()
        window.orderOut(nil)
    }

    // MARK: Dragging and snapping

    func dragChanged(at mouse: CGPoint) {
        if drag == nil {
            drag = (mouse, window.frame)
            collapseWork?.cancel()
            if model.columnSearchOpen { search.close() }
        }
        guard let drag else { return }
        window.setFrameOrigin(CGPoint(x: drag.frame.minX + mouse.x - drag.mouse.x, y: drag.frame.minY + mouse.y - drag.mouse.y))
        let visible = Self.visibleFrame(at: mouse)
        let zone = ToolbarLayout.zone(at: mouse, in: visible)
        if zone == .free {
            if dragZone != .free { outline.fadeOut() }
        } else {
            outline.show(zone.shape, frame: snappedFrame(zone, at: mouse, in: visible).frame, below: window)
        }
        dragZone = zone
    }

    func dragEnded(at mouse: CGPoint) {
        guard drag != nil else { return }
        let visible = Self.visibleFrame(at: mouse)
        let zone = ToolbarLayout.zone(at: mouse, in: visible)
        let snapped = snappedFrame(zone, at: mouse, in: visible)
        drag = nil
        dragZone = nil
        outline.fadeOut()
        Log.write("toolbar: dropped in \(zone), now \(zone.shape) at \(snapped.frame.origin)")
        setBar(snapped.frame, shape: zone.shape, bubbleAtStart: snapped.bubbleAtStart)
        if !hovering { scheduleCollapse() }
    }

    /// Where the toolbar lands for a drop at `mouse`, and which end its bubble rests at.
    /// Keeping its shape, it stays where it was dragged, pushed against the edge; changing
    /// shape, it centers on the pointer first. A bubble stays where it was dropped.
    private func snappedFrame(_ zone: ToolbarZone, at mouse: CGPoint, in visible: CGRect) -> (frame: CGRect, bubbleAtStart: Bool) {
        if model.collapsed {
            let around = ToolbarLayout.frame(around: window.frame, shape: zone.shape, buttons: Self.buttons, in: visible)
            return (ToolbarLayout.frame(for: zone, proposed: around.frame, in: visible), around.atStart)
        }
        let size = ToolbarLayout.size(zone.shape, buttons: Self.buttons)
        var proposed = CGRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2, width: size.width, height: size.height)
        if zone.shape == model.shape, !model.columnSearchOpen {
            proposed.origin = window.frame.origin
        }
        let frame = ToolbarLayout.frame(for: zone, proposed: proposed, in: visible)
        return (frame, ToolbarLayout.bubbleAtStart(for: frame, shape: zone.shape, in: visible))
    }

    private func setBar(_ frame: CGRect, shape: ToolbarShape, bubbleAtStart: Bool) {
        barFrame = frame
        self.bubbleAtStart = bubbleAtStart
        withAnimation(.easeInOut(duration: 0.22)) {
            model.shape = shape
            updateAnchor()
        }
        store.toolbarOrigin = frame.origin
        store.toolbarShape = shape
        applyFrame(animated: true)
    }

    // MARK: Bubble

    func hoverChanged(_ inside: Bool) {
        hovering = inside
        guard settings.collapsesToBubble else { return }
        if inside {
            collapseWork?.cancel()
            if model.collapsed { expand() }
        } else {
            scheduleCollapse()
        }
    }

    func expand() {
        collapseWork?.cancel()
        guard model.collapsed else { return }
        withAnimation(.easeOut(duration: 0.18)) { model.collapsed = false }
        applyFrame(animated: true)
        Log.write("toolbar: opened from the bubble")
        // A click that expands it with the pointer already away still collapses again.
        if !hovering { scheduleCollapse() }
    }

    private func scheduleCollapse() {
        guard settings.collapsesToBubble, !model.collapsed, drag == nil else { return }
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapseIfIdle() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func collapseIfIdle() {
        guard settings.collapsesToBubble, !model.collapsed, !hovering, drag == nil, !search.isOpen else { return }
        withAnimation(.easeIn(duration: 0.18)) {
            model.columnSearchOpen = false
            model.collapsed = true
        }
        applyFrame(animated: true)
        Log.write("toolbar: collapsed to the bubble")
    }

    private func bubbleSettingChanged(_ on: Bool) {
        Log.write("toolbar: collapse to bubble \(on ? "on" : "off")")
        if on {
            scheduleCollapse()
        } else if model.collapsed {
            withAnimation(.easeOut(duration: 0.18)) { model.collapsed = false }
            applyFrame(animated: true)
        }
    }

    // MARK: Search

    func openColumnSearch() {
        guard model.shape == .vertical, !model.columnSearchOpen else {
            search.focus()
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { model.columnSearchOpen = true }
        applyFrame(animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.search.focus() }
    }

    /// Makes the search field show before it takes focus. True when it had to appear first.
    private func prepareForSearch() -> Bool {
        var changed = false
        if model.collapsed {
            collapseWork?.cancel()
            model.collapsed = false
            changed = true
        }
        if model.shape == .vertical, !model.columnSearchOpen {
            model.columnSearchOpen = true
            changed = true
        }
        if changed { applyFrame(animated: false) }
        return changed
    }

    private func searchClosed() {
        if model.columnSearchOpen {
            withAnimation(.easeIn(duration: 0.12)) { model.columnSearchOpen = false }
            applyFrame(animated: false)
        }
        if !hovering { scheduleCollapse() }
    }

    // MARK: Frames

    /// The window's frame for the current state: the bubble, the shape, or a column with its
    /// search field beside it.
    private func windowFrame() -> CGRect {
        if model.collapsed {
            return ToolbarLayout.bubbleFrame(for: barFrame, shape: model.shape, atStart: bubbleAtStart)
        }
        guard model.shape == .vertical, model.columnSearchOpen else { return barFrame }
        var frame = barFrame
        let extra = ToolbarLayout.columnFieldWidth + ToolbarLayout.buttonSpacing
        frame.size.width += extra
        if !model.fieldOnRight { frame.origin.x -= extra }
        return frame
    }

    private func applyFrame(animated: Bool) {
        let target = windowFrame()
        guard animated, window.isVisible else {
            window.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.window.invalidateShadow() }
        }
    }

    private func updateAnchor() {
        let visible = Self.visibleFrame(at: CGPoint(x: barFrame.midX, y: barFrame.midY))
        switch model.shape {
        case .horizontal:
            model.anchor = bubbleAtStart ? .leading : .trailing
        case .vertical:
            let onLeft = barFrame.midX < visible.midX
            model.anchor = Alignment(horizontal: onLeft ? .leading : .trailing, vertical: bubbleAtStart ? .bottom : .top)
        case .cornerArc(let corner):
            model.anchor = Alignment(horizontal: corner.isLeft ? .leading : .trailing, vertical: corner.isTop ? .top : .bottom)
        }
    }

    /// Puts a quarter circle back in its corner and keeps every other shape on screen.
    private func settled(_ frame: CGRect, shape: ToolbarShape) -> CGRect {
        let visible = Self.visibleFrame(at: CGPoint(x: frame.midX, y: frame.midY))
        if case .cornerArc(let corner) = shape {
            return ToolbarLayout.frame(for: .corner(corner), proposed: frame, in: visible)
        }
        return ToolbarLayout.clamped(frame, to: visible)
    }

    private func keepOnScreen() {
        let frame = settled(barFrame, shape: model.shape)
        guard frame != barFrame else { return }
        barFrame = frame
        updateAnchor()
        store.toolbarOrigin = frame.origin
        applyFrame(animated: false)
    }

    /// The visible frame of the screen under `point`, or the main screen's.
    private static func visibleFrame(at point: CGPoint) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
    }

    private static func defaultOrigin(_ size: CGSize) -> CGPoint {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return CGPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 12)
    }
}

/// A faint outline of the shape the toolbar would snap to, shown while it's dragged into an
/// edge or corner zone. Never takes clicks.
private final class SnapOutlineWindow: NSWindow {
    private let outline = OutlineModel()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        level = DesktopLevelWindow.desktopLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        alphaValue = 0
        contentView = NSHostingView(rootView: OutlineView(outline: outline))
    }

    func show(_ shape: ToolbarShape, frame: CGRect, below toolbar: NSWindow) {
        outline.shape = shape
        setFrame(frame, display: true)
        order(.below, relativeTo: toolbar.windowNumber)
        guard alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func fadeOut() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.orderOut(nil)
            }
        }
    }
}

@MainActor
private final class OutlineModel: ObservableObject {
    @Published var shape: ToolbarShape = .horizontal
}

private struct OutlineView: View {
    @ObservedObject var outline: OutlineModel

    var body: some View {
        DropOutline(shape: ToolbarOutlineShape(shape: outline.shape))
    }
}

/// The faint dashed outline of where something lands when it's let go: the toolbar in a
/// snap zone, or a fence that has snapped.
struct DropOutline<S: Shape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(Color.white.opacity(0.12))
            .overlay(shape.stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
            .shadow(color: .black.opacity(0.35), radius: 2)
            .padding(2)
            .allowsHitTesting(false)
    }
}

// MARK: Views

private struct ToolbarView: View {
    @ObservedObject var model: ToolbarModel
    @ObservedObject var fences: FenceCoordinator
    let search: SearchController
    let actions: ToolbarActions
    let events: ToolbarEvents

    @ObservedObject private var themes = ThemeSettings.shared
    @ObservedObject private var snapping = SnapSettings.shared

    var body: some View {
        let style = ThemeStyle.chrome(themes.globalTheme)
        ZStack(alignment: model.anchor) {
            if model.collapsed {
                bubble(style)
                    .transition(.opacity)
            } else {
                switch model.shape {
                case .horizontal: horizontal(style).transition(.opacity)
                case .vertical: vertical(style).transition(.opacity)
                case .cornerArc(let corner): arc(corner, style: style).transition(.opacity)
                }
            }
        }
        // Content keeps its size and stays pinned to the anchor while the window animates.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.anchor)
        .onHover { events.hoverChanged($0) }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in events.dragChanged() }
            .onEnded { _ in events.dragEnded() }
    }

    // MARK: Shapes

    private func horizontal(_ style: ThemeStyle) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2.fill")
                .foregroundStyle(style.titleText.opacity(0.7))
                .help("Clutter Buster")
            searchField(style)
            ForEach(ToolbarItem.allCases, id: \.self) { button($0, style: style) }
        }
        .padding(.horizontal, 12)
        .frame(width: ToolbarLayout.horizontalLength, height: ToolbarLayout.thickness)
        .background(ThemeFillView(fill: style.titleBar).clipShape(Capsule()))
        .overlay {
            ThemeBorderView(border: style.border, cornerRadius: 22, live: true, animate: themes.animates)
        }
        .contentShape(Capsule())
        .gesture(dragGesture)
    }

    private func vertical(_ style: ThemeStyle) -> some View {
        let size = ToolbarLayout.size(.vertical, buttons: ToolbarItem.allCases.count)
        let column = VStack(spacing: ToolbarLayout.buttonSpacing) {
            ToolbarButton(systemImage: "magnifyingglass", help: "Search", round: true, active: model.columnSearchOpen, style: style) {
                events.openColumnSearch()
            }
            ForEach(ToolbarItem.allCases, id: \.self) { button($0, style: style, round: true) }
        }
        .frame(width: size.width, height: size.height)
        .background(ThemeFillView(fill: style.titleBar).clipShape(Capsule()))
        .overlay {
            ThemeBorderView(border: style.border, cornerRadius: 22, live: true, animate: themes.animates)
        }
        .contentShape(Capsule())
        .gesture(dragGesture)
        return HStack(alignment: .top, spacing: ToolbarLayout.buttonSpacing) {
            if model.columnSearchOpen && !model.fieldOnRight { columnField(style) }
            column
            if model.columnSearchOpen && model.fieldOnRight { columnField(style) }
        }
    }

    /// The column's search field, level with its magnifier.
    private func columnField(_ style: ThemeStyle) -> some View {
        searchField(style)
            .padding(4)
            .frame(width: ToolbarLayout.columnFieldWidth, height: ToolbarLayout.buttonSize + 8)
            .background(ThemeFillView(fill: style.titleBar).clipShape(Capsule()))
            .overlay(ThemeBorderView(border: style.border, cornerRadius: (ToolbarLayout.buttonSize + 8) / 2))
            .padding(.top, 8 - 4)
            .transition(.opacity)
    }

    private func arc(_ corner: ScreenCorner, style: ThemeStyle) -> some View {
        let disc = QuarterDisc(corner: corner)
        let field = ToolbarLayout.arcFieldFrame(corner)
        let centers = ToolbarLayout.arcButtonCenters(corner, count: ToolbarItem.allCases.count)
        return ZStack(alignment: .topLeading) {
            ThemeFillView(fill: style.titleBar)
                .clipShape(disc)
                .contentShape(disc)
                .gesture(dragGesture)
            QuarterArc(corner: corner, radius: ToolbarLayout.arcInnerRadius)
                .stroke(style.titleText.opacity(0.1), lineWidth: 1)
                .allowsHitTesting(false)
            ShapeBorder(border: style.border, shape: disc)
            Image(systemName: "square.grid.2x2.fill")
                .foregroundStyle(style.titleText.opacity(0.7))
                .help("Clutter Buster")
                .position(ToolbarLayout.arcGlyphCenter(corner))
                .allowsHitTesting(false)
            searchField(style)
                .frame(width: field.width, height: field.height)
                .position(x: field.midX, y: field.midY)
            ForEach(Array(ToolbarItem.allCases.enumerated()), id: \.element) { index, item in
                button(item, style: style, round: true)
                    .position(centers[index])
            }
        }
        .frame(width: ToolbarLayout.arcRadius, height: ToolbarLayout.arcRadius)
    }

    private func bubble(_ style: ThemeStyle) -> some View {
        let side = ToolbarLayout.bubbleSize
        return Image(systemName: "magnifyingglass")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(style.titleText)
            .frame(width: side, height: side)
            .background(ThemeFillView(fill: style.titleBar).clipShape(Circle()))
            .overlay(ThemeBorderView(border: style.border, cornerRadius: side / 2, live: true, animate: themes.animates))
            .contentShape(Circle())
            .help("Clutter Buster")
            .onTapGesture { events.bubbleClicked() }
            .gesture(dragGesture)
    }

    // MARK: Parts

    private func searchField(_ style: ThemeStyle) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(style.titleText.opacity(0.7))
            ToolbarSearchField(search: search, textColor: NSColor(style.titleText))
                .frame(height: 16)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .background(Capsule().fill(style.titleText.opacity(0.1)))
        .contentShape(Capsule())
        .onTapGesture { search.focus() }
    }

    private func button(_ item: ToolbarItem, style: ThemeStyle, round: Bool = false) -> some View {
        switch item {
        case .newFence:
            ToolbarButton(systemImage: "plus", help: "New fence", round: round, style: style, action: actions.newFence)
        case .collapseAll:
            ToolbarButton(systemImage: "rectangle.compress.vertical", help: "Collapse all fences", round: round, style: style, action: actions.collapseAll)
        case .expandAll:
            ToolbarButton(systemImage: "rectangle.expand.vertical", help: "Expand all fences", round: round, style: style, action: actions.expandAll)
        case .toggleFences:
            ToolbarButton(
                systemImage: fences.fencesHidden ? "eye.slash" : "eye",
                help: fences.fencesHidden ? "Show fences" : "Hide fences and show the Desktop as usual",
                round: round,
                active: fences.fencesHidden,
                style: style,
                action: actions.toggleFences
            )
        case .snap:
            ToolbarButton(
                icon: .magnet,
                help: snapping.enabled ? "Snapping is on: fences line up as you drag them. Click to turn it off." : "Snapping is off. Click to turn it on.",
                round: round,
                active: snapping.enabled,
                style: style
            ) { snapping.enabled.toggle() }
        case .settings:
            ToolbarButton(systemImage: "gearshape", help: "Settings", round: round, style: style, action: actions.openSettings)
        }
    }
}

/// Just the curved edge of a quarter disc, for the line between the button ring and the middle.
private struct QuarterArc: Shape {
    let corner: ScreenCorner
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: corner.isLeft ? rect.minX : rect.maxX, y: corner.isTop ? rect.minY : rect.maxY)
        let sx: CGFloat = corner.isLeft ? 1 : -1
        let sy: CGFloat = corner.isTop ? 1 : -1
        var path = Path()
        path.move(to: CGPoint(x: center.x + sx * radius, y: center.y))
        path.addArc(
            tangent1End: CGPoint(x: center.x + sx * radius, y: center.y + sy * radius),
            tangent2End: CGPoint(x: center.x, y: center.y + sy * radius),
            radius: radius
        )
        return path
    }
}

/// A theme's border drawn along any shape, kept inside it. The quarter circle uses it; bars
/// and the bubble use `ThemeBorderView`.
private struct ShapeBorder<S: Shape>: View {
    let border: ThemeBorder
    let shape: S

    var body: some View {
        Group {
            switch border {
            case .line(let color):
                shape.stroke(color, lineWidth: 2)
            case .glow(let color):
                ZStack {
                    shape.stroke(color.opacity(0.5), lineWidth: 12).blur(radius: 4)
                    shape.stroke(color.opacity(0.9), lineWidth: 3)
                }
            case .rainbow:
                let gradient = AngularGradient(colors: ThemeBorderView.rainbow, center: .center)
                ZStack {
                    shape.stroke(gradient, lineWidth: 18).blur(radius: 6).opacity(0.8)
                    shape.stroke(gradient, lineWidth: 5)
                }
            }
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}

/// A button's glyph: an SF Symbol, or one drawn here where SF Symbols has none.
private enum ToolbarIcon {
    case symbol(String)
    case magnet
}

private struct ToolbarButton: View {
    let icon: ToolbarIcon
    var title: String?
    var help: String?
    /// A circle, for the column and the quarter circle.
    var round = false
    /// Drawn pressed, for a toggle that's on.
    var active = false
    let style: ThemeStyle
    let action: () -> Void

    init(
        systemImage: String, title: String? = nil, help: String? = nil, round: Bool = false, active: Bool = false,
        style: ThemeStyle, action: @escaping () -> Void
    ) {
        self.init(icon: .symbol(systemImage), title: title, help: help, round: round, active: active, style: style, action: action)
    }

    init(
        icon: ToolbarIcon, title: String? = nil, help: String? = nil, round: Bool = false, active: Bool = false,
        style: ThemeStyle, action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.help = help
        self.round = round
        self.active = active
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                switch icon {
                case .symbol(let name):
                    Image(systemName: name)
                case .magnet:
                    MagnetShape()
                        .stroke(style.titleText, style: StrokeStyle(lineWidth: 2.6))
                        .frame(width: 12, height: 13)
                }
                if let title { Text(title).lineLimit(1).fixedSize() }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(style.titleText)
            .padding(.horizontal, round ? 0 : (title == nil ? 7 : 10))
            .frame(width: round ? ToolbarLayout.buttonSize : nil, height: round ? ToolbarLayout.buttonSize : 26)
            .background(Capsule().fill(active ? style.titleText.opacity(0.32) : style.titleControl))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help ?? title ?? "")
    }
}

/// A horseshoe magnet opening upward, with its two pole tips set apart from the bend.
/// Meant to be stroked.
private struct MagnetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let inset: CGFloat = 1.3
        let rect = rect.insetBy(dx: inset, dy: inset)
        let radius = rect.width / 2
        let tip = rect.height * 0.28
        let gap: CGFloat = 1.6
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + tip + gap))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addArc(center: CGPoint(x: rect.midX, y: rect.maxY - radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + tip + gap))
        for x in [rect.minX, rect.maxX] {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.minY + tip))
        }
        return path
    }
}
