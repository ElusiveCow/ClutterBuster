import AppKit
import SwiftUI

/// A fence's settings, changed live: name, theme, Classic's color and transparency, and
/// icons per row. With `showsMore`, also text size and the tab strip. Drawn light on dark,
/// for the setup card and the settings popover.
struct FenceSettingsForm: View {
    let fenceID: UUID
    var showsMore = false
    var focusesName = false
    var onSubmit: () -> Void = {}

    @EnvironmentObject private var store: FenceStore
    @EnvironmentObject private var coordinator: FenceCoordinator
    @ObservedObject private var themes = ThemeSettings.shared
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        if let fence = store.fence(fenceID) {
            content(fence)
        }
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
                .onSubmit(onSubmit)
                .onChange(of: name) { _, newName in coordinator.rename(fenceID, to: newName) }

            SettingsSection(fence.theme.map { "Theme \u{00B7} \($0.name)" } ?? "Theme \u{00B7} Global (\(themes.globalTheme.name))") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 2), count: 7), alignment: .leading, spacing: 4) {
                    ThemeSwatch(
                        style: ThemeStyle.of(themes.globalTheme, for: fence),
                        selected: fence.theme == nil,
                        badge: "globe"
                    ) { coordinator.setTheme(fenceID, nil) }
                        .help("Use Global (\(themes.globalTheme.name))")
                    ForEach(FenceTheme.allCases) { theme in
                        ThemeSwatch(style: ThemeStyle.of(theme, for: fence), selected: fence.theme == theme) {
                            coordinator.setTheme(fenceID, theme)
                        }
                            .help(theme.name)
                    }
                }
            }

            // Other themes set their own colors and transparency.
            if (fence.theme ?? themes.globalTheme) == .classic {
                SettingsSection("Color") {
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

                SettingsSection("Transparency") {
                    let current = OpacityPreset.nearest(to: fence.opacity)
                    HStack(spacing: 5) {
                        ForEach(OpacityPreset.allCases) { preset in
                            Chip(title: preset.name, selected: preset == current) {
                                coordinator.setOpacity(fenceID, preset.value)
                            }
                        }
                    }
                }
            }

            SettingsSection("Icons per row") {
                HStack(spacing: 5) {
                    ForEach(Array(AppSettings.iconsPerRowRange), id: \.self) { count in
                        Chip(title: "\(count)", selected: count == fence.iconsPerRow) {
                            coordinator.setIconsPerRow(fenceID, count)
                        }
                    }
                }
            }

            if showsMore {
                textSizeSection(fence)
                tabsSection(fence)
            }
        }
        .onAppear {
            name = fence.title
            if focusesName { DispatchQueue.main.async { nameFocused = true } }
        }
        // A rename from the title bar shows here too, unless it's being typed here.
        .onChange(of: fence.title) { _, title in
            if !nameFocused, title != name { name = title }
        }
    }

    private func textSizeSection(_ fence: Fence) -> some View {
        SettingsSection("Text size \u{00B7} \(Int((fence.textScale * 100).rounded()))%") {
            HStack(spacing: 5) {
                Chip(systemImage: "textformat.size.smaller", selected: false) { coordinator.adjustTextScale(fenceID, by: -1) }
                    .disabled(fence.textScale <= Fence.textScaleRange.lowerBound)
                    .help("Smaller text")
                Chip(systemImage: "textformat.size.larger", selected: false) { coordinator.adjustTextScale(fenceID, by: 1) }
                    .disabled(fence.textScale >= Fence.textScaleRange.upperBound)
                    .help("Bigger text")
                Chip(title: "Reset", selected: false) { coordinator.setTextScale(fenceID, 1) }
                    .disabled(fence.textScale == 1)
            }
        }
    }

    private func tabsSection(_ fence: Fence) -> some View {
        let available = coordinator.maxTabRows(fence, forHeight: fence.frame.height)
        return SettingsSection("Tab rows") {
            HStack(spacing: 5) {
                ForEach(1...FenceMetrics.maxTabRows, id: \.self) { rows in
                    Chip(title: "\(rows)", selected: !fence.tabsCollapsed && fence.tabRows == rows) {
                        coordinator.setTabStrip(fenceID, rows: rows, collapsed: false)
                    }
                    .disabled(rows > available)
                    .help(rows > available ? "Make the fence taller for \(rows) rows" : (rows == 1 ? "1 row" : "\(rows) rows"))
                }
                Chip(title: "Tucked Away", selected: fence.tabsCollapsed) {
                    coordinator.setTabStrip(fenceID, rows: fence.tabRows, collapsed: !fence.tabsCollapsed)
                }
                .help("Shrink the tabs to a thin bar showing the current tab")
            }
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            content
        }
    }
}

struct ThemeSwatch: View {
    let style: ThemeStyle
    let selected: Bool
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ThemePreview(style: style)
                .frame(width: 32, height: 24)
                .overlay(alignment: .bottomLeading) {
                    if let badge {
                        Image(systemName: badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(2)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                            .offset(x: -3, y: 3)
                    }
                }
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Chip: View {
    var title: String?
    var systemImage: String?
    let selected: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(title ?? "")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(selected ? .white : .white.opacity(0.75))
            .frame(minWidth: 22)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(Capsule().fill(selected ? Color.accentColor : Color.white.opacity(0.1)))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
    }
}

/// Everything about one fence in a popover, opened from its gear or ⋯ menu.
struct FenceSettingsPopover: View {
    let fenceID: UUID

    var body: some View {
        FenceSettingsForm(fenceID: fenceID, showsMore: true)
            .padding(14)
            .frame(width: 300)
            .fixedSize(horizontal: false, vertical: true)
            // Darkens the see-through popover so the light controls read over any desktop.
            .background(Color.black.opacity(0.45))
    }
}

/// Records the AppKit view behind a SwiftUI control so a popover can point at it.
final class PopoverAnchor {
    weak var view: NSView?
}

struct PopoverAnchorView: NSViewRepresentable {
    let anchor: PopoverAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }

    /// Never takes the clicks meant for the control it sits behind.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
