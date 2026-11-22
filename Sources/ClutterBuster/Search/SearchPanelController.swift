import AppKit
import SwiftUI

private final class SearchPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
}

/// Spotlight-style search panel that opens next to the toolbar and closes when it loses focus.
@MainActor
final class SearchPanelController: NSObject, NSWindowDelegate {
    private let size = CGSize(width: 560, height: 460)
    private let panel: SearchPanel
    private let service: SearchService
    private let anchor: () -> CGRect?
    /// Off only for scripted demos, where the app launches without becoming active.
    var closesWhenInactive = true

    init(store: FenceStore, anchor: @escaping () -> CGRect?) {
        panel = SearchPanel(size: size)
        service = SearchService(store: store)
        self.anchor = anchor
        super.init()
        panel.delegate = self
    }

    func show(query: String = "") {
        service.reset()
        service.query = query
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let anchorFrame = anchor() ?? CGRect(x: screen.midX, y: screen.maxY - 60, width: 0, height: 44)
        let opensBelow = anchorFrame.minY - size.height - 8 >= screen.minY
        let x = min(max(anchorFrame.midX - size.width / 2, screen.minX), screen.maxX - size.width)
        let y = opensBelow ? anchorFrame.minY - size.height - 8 : anchorFrame.maxY + 8
        panel.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: false)

        let view = SearchView(service: service, opensBelow: opensBelow, onOpen: { [weak self] result in
            NSWorkspace.shared.open(result.url)
            self?.close()
        }, onClose: { [weak self] in self?.close() })
        panel.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
        service.reset()
    }

    func windowDidResignKey(_ notification: Notification) {
        if closesWhenInactive { close() }
    }
}

private struct SearchView: View {
    @ObservedObject var service: SearchService
    let opensBelow: Bool
    let onOpen: (SearchResult) -> Void
    let onClose: () -> Void

    @State private var selection = 0
    /// Set only by the arrow keys, so hovering never scrolls the list under the mouse.
    @State private var scrollTarget: Int?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !opensBelow { Spacer(minLength: 0) }
            card
            if opensBelow { Spacer(minLength: 0) }
        }
        .onAppear { fieldFocused = true }
        .onChange(of: service.query) {
            selection = 0
            scrollTarget = nil
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.6))
                TextField("Search fences, the desktop and your Mac", text: $service.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .focused($fieldFocused)
                    .onSubmit(openSelection)
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                    .onExitCommand(perform: onClose)
                if service.isSearchingMac {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)

            if !service.results.isEmpty {
                Divider().overlay(Color.white.opacity(0.1))
                resultList
            } else if !service.query.trimmingCharacters(in: .whitespaces).isEmpty && !service.isSearchingMac {
                Divider().overlay(Color.white.opacity(0.1))
                Text("No matches")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(service.results.enumerated()), id: \.element.id) { index, result in
                        if index == 0 || service.results[index - 1].section != result.section {
                            Text(result.section.rawValue.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.horizontal, 16)
                                .padding(.top, index == 0 ? 8 : 12)
                                .padding(.bottom, 4)
                        }
                        row(result, selected: index == selection)
                            .id(index)
                            .onTapGesture { onOpen(result) }
                            .onHover { if $0 { selection = index } }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 400)
            .onChange(of: scrollTarget) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
    }

    private func row(_ result: SearchResult, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: result.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.45) : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func moveSelection(_ delta: Int) {
        guard !service.results.isEmpty else { return }
        selection = min(max(selection + delta, 0), service.results.count - 1)
        scrollTarget = selection
    }

    private func openSelection() {
        guard service.results.indices.contains(selection) else { return }
        onOpen(service.results[selection])
    }
}
