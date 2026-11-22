import AppKit
import SwiftUI

private final class DropdownPanel: NSPanel {
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    // Typing stays in the toolbar's field, so the results never take focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Drives the toolbar's search field and the results dropdown attached to the toolbar.
@MainActor
final class SearchController: NSObject, NSTextFieldDelegate {
    let service: SearchService
    weak var field: NSTextField?
    /// Scripted demos launch while another app is in front, and it takes focus straight back.
    /// Until this time passes, clicking elsewhere or switching apps leaves the dropdown open.
    var holdsOpenUntil = Date.distantPast
    /// Shows a result in Finder. Fenced Desktop files have to be unhidden first.
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    private let panel = DropdownPanel()
    private let width: CGFloat = 560
    private let maxHeight: CGFloat = 420
    private let gap: CGFloat = 6
    private var contentHeight: CGFloat = 44
    private let toolbarWindow: () -> NSWindow?
    private lazy var outsideClicks = OutsideClickMonitor(
        inside: { [weak self] in [self?.toolbarWindow(), self?.panel].compactMap { $0 } },
        onOutsideClick: { [weak self] in
            guard let self, !self.isHeldOpen else { return }
            self.close()
        }
    )

    init(store: FenceStore, toolbarWindow: @escaping () -> NSWindow?) {
        service = SearchService(store: store)
        self.toolbarWindow = toolbarWindow
        super.init()
        let view = SearchResultsView(
            service: service,
            onOpen: { [weak self] in self?.open($0, reveal: false) },
            onReveal: { [weak self] in self?.open($0, reveal: true) },
            onContentHeight: { [weak self] height in
                self?.contentHeight = height
                self?.updatePanel()
            }
        )
        panel.contentView = FirstMouseHostingView(rootView: view)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, !self.isHeldOpen else { return }
                Log.write("search: app deactivated")
                self.close()
            }
        }
    }

    /// Puts the cursor in the toolbar's field, optionally with text already typed.
    func focus(query: String? = nil) {
        guard let field, let window = field.window else { return }
        if let query {
            // Set before editing starts; an editor already open would write its old text back.
            if field.currentEditor() != nil { window.makeFirstResponder(nil) }
            field.stringValue = query
            setQuery(query)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        window.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    /// Called by the field when it gains focus.
    func fieldDidFocus() {
        Log.write("search: field focused")
        outsideClicks.start()
    }

    /// True while the field is being edited or the dropdown is showing.
    private var isOpen: Bool { panel.isVisible || field?.currentEditor() != nil }
    private var isHeldOpen: Bool { Date() < holdsOpenUntil }

    func close() {
        if isOpen { Log.write("search: closed") }
        outsideClicks.stop()
        panel.orderOut(nil)
        service.reset()
        guard let field else { return }
        field.stringValue = ""
        if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
    }

    private func setQuery(_ text: String) {
        service.query = text
        updatePanel()
    }

    private func open(_ result: SearchResult, reveal: Bool) {
        if reveal {
            self.reveal(result.url)
        } else {
            NSWorkspace.shared.open(result.url)
        }
        close()
    }

    private func updatePanel() {
        let hasQuery = !service.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasQuery, let toolbar = toolbarWindow(), toolbar.isVisible else {
            panel.orderOut(nil)
            return
        }
        let anchor = toolbar.frame
        let screen = toolbar.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
        let height = min(max(contentHeight, 44), maxHeight)
        // Decide with the tallest size so the dropdown doesn't flip sides while results load.
        let opensBelow = anchor.minY - gap - maxHeight >= screen.minY
        let x = min(max(anchor.midX - width / 2, screen.minX), screen.maxX - width)
        let y = opensBelow ? anchor.minY - gap - height : anchor.maxY + gap
        panel.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        setQuery(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            service.moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            service.moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            let reveal = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            if let result = service.selectedResult { open(result, reveal: reveal) }
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }
}

/// The search box inside the toolbar. Clicking it brings Clutter Buster forward so typing
/// works even though the toolbar sits at desktop level.
final class ToolbarSearchTextField: NSTextField {
    var onFocus: (() -> Void)?
    var tint: NSColor = .white {
        didSet {
            textColor = tint
            placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
                .foregroundColor: tint.withAlphaComponent(0.5),
                .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
            ])
            (currentEditor() as? NSTextView)?.insertionPointColor = tint
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            (currentEditor() as? NSTextView)?.insertionPointColor = tint
            onFocus?()
        }
        return became
    }
}

struct ToolbarSearchField: NSViewRepresentable {
    let search: SearchController
    let textColor: NSColor

    func makeNSView(context: Context) -> ToolbarSearchTextField {
        let field = ToolbarSearchTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.tint = textColor
        field.toolTip = "Search fences, the desktop and your Mac"
        field.delegate = search
        field.onFocus = { [weak search] in search?.fieldDidFocus() }
        search.field = field
        return field
    }

    func updateNSView(_ field: ToolbarSearchTextField, context: Context) {
        if field.tint != textColor { field.tint = textColor }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct SearchResultsView: View {
    @ObservedObject var service: SearchService
    let onOpen: (SearchResult) -> Void
    let onReveal: (SearchResult) -> Void
    let onContentHeight: (CGFloat) -> Void

    @ObservedObject private var themes = ThemeSettings.shared

    var body: some View {
        let style = ThemeStyle.chrome(themes.globalTheme)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if service.results.isEmpty {
                        Text(service.isSearching ? "Searching…" : "No matches")
                            .font(.system(size: 13))
                            .foregroundStyle(style.bodySecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(service.results.enumerated()), id: \.element.id) { index, result in
                            if index == 0 || service.results[index - 1].section != result.section {
                                Text(result.section.rawValue.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(style.bodySecondary.opacity(0.8))
                                    .padding(.horizontal, 16)
                                    .padding(.top, index == 0 ? 2 : 10)
                                    .padding(.bottom, 4)
                            }
                            row(result, selected: index == service.selection, style: style)
                                .id(index)
                                .onHover { if $0 { service.selection = index } }
                        }
                    }
                }
                .padding(.vertical, 8)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                })
            }
            .onPreferenceChange(ContentHeightKey.self) { onContentHeight($0) }
            .onChange(of: service.scrollTarget) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(style.solidBody))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(ThemeBorderView(border: style.border, cornerRadius: 12))
    }

    private func row(_ result: SearchResult, selected: Bool, style: ThemeStyle) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: result.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(style.bodyText)
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(style.bodySecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button { onReveal(result) } label: {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(style.bodyText.opacity(selected ? 0.9 : 0.55))
                    .frame(width: 28, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(style.bodyText.opacity(selected ? 0.12 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? style.accent.opacity(style.isLight ? 0.25 : 0.45) : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { onOpen(result) }
    }
}
