import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.defaultColorKey) private var defaultColor: FenceColor = .slate
    @AppStorage(AppSettings.defaultIconsPerRowKey) private var defaultIconsPerRow = 4
    @AppStorage(AppSettings.defaultOpacityKey) private var defaultOpacity = 1.0

    @EnvironmentObject private var store: FenceStore
    @ObservedObject private var themes = ThemeSettings.shared
    @ObservedObject private var toolbar = ToolbarSettings.shared
    @ObservedObject private var snapping = SnapSettings.shared
    let onQuit: () -> Void

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
                    ForEach(FenceTheme.allCases) { theme in
                        ThemeGalleryItem(
                            theme: theme,
                            style: theme == .classic ? .classic(color: defaultColor, opacity: defaultOpacity) : theme.style,
                            selected: themes.globalTheme == theme
                        ) { themes.globalTheme = theme }
                    }
                }
                .padding(.vertical, 4)
                Toggle("Animate themes", isOn: $themes.animateThemes)
                if themes.animateThemes && !themes.motionAllowed {
                    Text("Paused while Reduce Motion or Low Power Mode is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Every fence uses this theme unless you pick another one from its \u{22EF} menu. The toolbar and search follow it too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker("Color", selection: $defaultColor) {
                    ForEach(FenceColor.allCases) { color in
                        Text(color.name).tag(color)
                    }
                }
                Stepper("Icons per row: \(defaultIconsPerRow)", value: $defaultIconsPerRow, in: AppSettings.iconsPerRowRange)
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: $defaultOpacity, in: 0...1)
                        Text(defaultOpacity >= 0.995 ? "Solid" : "\(Int((defaultOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("New fences")
            } footer: {
                Text("Color and opacity apply to the Classic theme.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Snap while moving and resizing", isOn: $snapping.enabled)
                Stepper("Gap between fences: \(snapping.gap) pt", value: $snapping.gap, in: AppSettings.snapGapRange)
                    .disabled(!snapping.enabled)
            } header: {
                Text("Snapping")
            } footer: {
                Text("A fence you drag or resize lines up with the others, sits the gap away from its neighbors and stops at the screen's edges. An outline shows where it will land when you let go. Hold \u{2325} Option while dragging to do the opposite for that drag. The magnet in the toolbar turns snapping on and off too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Collapse to bubble", isOn: $toolbar.collapsesToBubble)
            } header: {
                Text("Toolbar")
            } footer: {
                Text("Drag the toolbar to a screen edge to stand it on its side, or into a corner for a quarter circle. As a bubble it opens when you point at it or click it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("About") {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clutter Buster").font(.headline)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Fences", value: "\(store.fences.count)")
                LabeledContent("Items", value: "\(store.fences.reduce(0) { $0 + $1.items.count })")
                Text("Files in fences stay in your Desktop folder. Clutter Buster hides their icons underneath the bottom-right corner of each fence, and quitting puts every icon back where it was.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Quit Clutter Buster", action: onQuit)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ThemeGalleryItem: View {
    let theme: FenceTheme
    let style: ThemeStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ThemePreview(style: style)
                    .aspectRatio(1.4, contentMode: .fit)
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(theme.name)
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(theme.name)
    }
}
