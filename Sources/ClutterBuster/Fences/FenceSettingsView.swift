import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A fence's settings, changed live: name, theme, Classic's color and transparency, and
/// icons per row. With `showsMore`, also text size, title style and the tab strip. Drawn light on dark,
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
                SettingsSection("Corner picture") {
                    CornerPicturePicker(fence: fence)
                }
                SettingsSection("Title style") {
                    TitleStyleEditor(fenceID: fenceID)
                }
                tabsSection(fence)
                spacesSection(fence)
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

    private func spacesSection(_ fence: Fence) -> some View {
        let locked = fence.holdsDesktopFiles
        return SettingsSection("Show on") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    ForEach(FenceSpaces.allCases) { spaces in
                        Chip(title: spaces.name, selected: (locked ? .all : fence.spaces) == spaces) {
                            coordinator.setSpaces(fenceID, spaces)
                        }
                        .disabled(locked && spaces == .current)
                    }
                }
                Text(locked
                     ? "It holds Desktop files, which are on every Space, so it shows on all of them."
                     : fence.spaces == .current ? "Shows on the Space it's on now. After a restart it opens on the Space you're on." : "Shows on every Space.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The theme's corner picture, none, or one of the user's own with its background removed.
/// Choosing a picture opens a file panel; dropping one on the row works too.
private struct CornerPicturePicker: View {
    let fence: Fence

    @EnvironmentObject private var coordinator: FenceCoordinator
    @State private var dropTargeted = false

    private enum Option: Hashable { case theme, none, custom }

    var body: some View {
        let working = coordinator.cornerArtInProgress.contains(fence.id)
        let saved = CustomCornerArt.exists(for: fence.id) ? CustomCornerArt.image(CustomCornerArt.fileName(for: fence.id)) : nil
        VStack(alignment: .leading, spacing: 8) {
            Picker("Corner picture", selection: selection) {
                Text("Theme").tag(Option.theme)
                Text("None").tag(Option.none)
                Text("Custom").tag(Option.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(working)
            HStack(spacing: 10) {
                thumbnail(saved, working: working)
                VStack(alignment: .leading, spacing: 4) {
                    Chip(title: "Choose Picture\u{2026}", selected: false) { coordinator.chooseCornerArt(fence.id) }
                        .disabled(working)
                        .help("Pick a photo; its background is removed automatically")
                    Text(status(working: working, saved: saved != nil))
                        .font(.system(size: 10))
                        .foregroundStyle(coordinator.cornerArtErrors[fence.id] == nil ? .white.opacity(0.5) : Color(hex: 0xFF9A8A))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(dropTargeted ? 0.9 : 0), lineWidth: 1.5))
        .padding(-6)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { (try? $0.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true }) else { return false }
            coordinator.makeCornerArt(fence.id, from: url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var selection: Binding<Option> {
        Binding(
            get: {
                switch fence.cornerArt ?? .theme {
                case .theme: .theme
                case .none: .none
                case .custom: .custom
                }
            },
            set: { option in
                switch option {
                case .theme: coordinator.setCornerArt(fence.id, .theme)
                case .none: coordinator.setCornerArt(fence.id, CornerArtChoice.none)
                // Let the segmented control finish its click before a file panel opens.
                case .custom: DispatchQueue.main.async { coordinator.useCustomCornerArt(fence.id) }
                }
            }
        )
    }

    private func thumbnail(_ image: NSImage?, working: Bool) -> some View {
        ZStack {
            Checkerboard()
            if working {
                ProgressView().controlSize(.small)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(3)
            } else {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.15)))
    }

    private func status(working: Bool, saved: Bool) -> String {
        if working { return "Removing the background\u{2026}" }
        if let error = coordinator.cornerArtErrors[fence.id] { return error }
        return saved ? "Or drop another picture here." : "Or drop a picture here."
    }
}

/// The gray squares that stand for transparency behind a picture.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.32)))
            let square: CGFloat = 6
            for row in 0..<Int(size.height / square) + 1 {
                for column in 0..<Int(size.width / square) + 1 where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square)), with: .color(Color(white: 0.42)))
                }
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

/// The font, size, weight, alignment and color of a fence's title. Each starts at the
/// theme's default, and picking the default again goes back to following the theme.
struct TitleStyleEditor: View {
    let fenceID: UUID

    @EnvironmentObject private var store: FenceStore
    @EnvironmentObject private var coordinator: FenceCoordinator
    @ObservedObject private var themes = ThemeSettings.shared

    var body: some View {
        if let fence = store.fence(fenceID) {
            let theme = ThemeStyle.resolve(fence, global: themes.globalTheme)
            let style = fence.titleStyle
            let size = style.pointSize
            let weight = style.weight ?? theme.titleWeight
            VStack(alignment: .leading, spacing: 8) {
                fontMenu(style, theme: theme)
                HStack(spacing: 5) {
                    Chip(systemImage: "minus", selected: false) { update { $0.size = sizeValue(size - 1) } }
                        .disabled(size <= TitleStyle.sizeRange.lowerBound)
                        .help("Smaller title")
                    Text("\(Int(size)) pt")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(minWidth: 36)
                    Chip(systemImage: "plus", selected: false) { update { $0.size = sizeValue(size + 1) } }
                        .disabled(size >= TitleStyle.sizeRange.upperBound)
                        .help("Bigger title")
                    Spacer(minLength: 8)
                    Chip(systemImage: "text.alignleft", selected: style.alignment == .leading) { update { $0.alignment = .leading } }
                        .help("Title on the left")
                    Chip(systemImage: "text.aligncenter", selected: style.alignment != .leading) { update { $0.alignment = nil } }
                        .help("Title in the middle")
                }
                HStack(spacing: 5) {
                    ForEach(TitleWeight.allCases) { option in
                        Chip(title: option.name, selected: option == weight) {
                            update { $0.weight = option == theme.titleWeight ? nil : option }
                        }
                    }
                }
                HStack(spacing: 5) {
                    Chip(title: "Theme Color", selected: style.color == nil) { update { $0.color = nil } }
                    ColorPicker("Title color", selection: colorBinding(style, theme: theme), supportsOpacity: false)
                        .labelsHidden()
                        .help("Pick a title color")
                    Spacer(minLength: 0)
                    Chip(title: "Reset", selected: false) { coordinator.setTitleStyle(fenceID, TitleStyle()) }
                        .disabled(style.isDefault)
                        .help("Use the theme's title style")
                }
            }
        }
    }

    private func fontMenu(_ style: TitleStyle, theme: ThemeStyle) -> some View {
        let themeFont = theme.titleFont
        return Menu {
            Button {
                update { $0.font = nil }
            } label: {
                let title = "Theme Default (\(themeFont.name))"
                if style.font == nil { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
            Divider()
            ForEach(TitleFont.builtIn, id: \.self) { font in
                Button {
                    update { $0.font = font }
                } label: {
                    if style.font == font { Label(font.name, systemImage: "checkmark") } else { Text(font.name) }
                }
            }
            Divider()
            InstalledFontsMenu(selected: style.font) { family in update { $0.font = .family(family) } }
                .equatable()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "textformat")
                    .font(.system(size: 10, weight: .semibold))
                Text(style.font?.name ?? "\(themeFont.name) (Theme)")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Title font")
    }

    private func colorBinding(_ style: TitleStyle, theme: ThemeStyle) -> Binding<Color> {
        Binding(
            get: { style.color.flatMap { Color(rgbHex: $0) } ?? theme.titleText },
            set: { color in update { $0.color = color.rgbHex } }
        )
    }

    /// Nil at the theme's size, so the title follows the theme again.
    private func sizeValue(_ size: Double) -> Double? {
        let size = min(max(size, TitleStyle.sizeRange.lowerBound), TitleStyle.sizeRange.upperBound)
        return size == TitleStyle.defaultSize ? nil : size
    }

    /// Changes the stored style, not the one this view last drew, so quick changes from the
    /// color panel don't undo each other.
    private func update(_ change: (inout TitleStyle) -> Void) {
        guard var style = store.fence(fenceID)?.titleStyle else { return }
        change(&style)
        coordinator.setTitleStyle(fenceID, style)
    }
}

/// Every installed font family, in a submenu. Only redrawn when the selection changes, since
/// there can be hundreds.
private struct InstalledFontsMenu: View, Equatable {
    let selected: TitleFont?
    let onPick: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.selected == rhs.selected }

    var body: some View {
        Menu("Installed Fonts") {
            ForEach(TitleFont.installedFamilies, id: \.self) { family in
                Button {
                    onPick(family)
                } label: {
                    if selected == .family(family) { Label(family, systemImage: "checkmark") } else { Text(family) }
                }
            }
        }
    }
}

enum FenceSettingsPage: String {
    case all, titleStyle
}

/// A fence's settings in a popover, opened from its gear or ⋯ menu: all of them, or just the
/// title style.
struct FenceSettingsPopover: View {
    let fenceID: UUID
    var page: FenceSettingsPage = .all

    var body: some View {
        Group {
            switch page {
            case .all:
                FenceSettingsForm(fenceID: fenceID, showsMore: true)
            case .titleStyle:
                SettingsSection("Title Style") {
                    TitleStyleEditor(fenceID: fenceID)
                }
            }
        }
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
