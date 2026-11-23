import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.defaultColorKey) private var defaultColor: FenceColor = .slate
    @AppStorage(AppSettings.defaultIconsPerRowKey) private var defaultIconsPerRow = 4
    @AppStorage(AppSettings.defaultOpacityKey) private var defaultOpacity = 1.0

    @EnvironmentObject private var store: FenceStore
    @ObservedObject private var themes = ThemeSettings.shared
    @ObservedObject private var toolbar = ToolbarSettings.shared
    @ObservedObject private var snapping = SnapSettings.shared
    @ObservedObject private var newFiles = NewFileSettings.shared
    let onQuit: () -> Void

    /// The form scrolls rather than growing past the screen.
    private static var height: CGFloat {
        min(860, (NSScreen.main?.visibleFrame.height ?? 900) - 60)
    }

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
            newFilesSection
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
        .frame(width: 520, height: Self.height)
    }

    private var newFilesSection: some View {
        Section {
            Picker("When a new file appears on the Desktop", selection: $newFiles.mode) {
                ForEach(NewFileMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            ForEach($newFiles.rules) { $rule in
                let index = newFiles.rules.firstIndex { $0.id == rule.id } ?? 0
                AutoFileRuleRow(
                    rule: $rule,
                    fences: store.fences,
                    canMoveUp: index > 0,
                    canMoveDown: index < newFiles.rules.count - 1,
                    onMove: { moveRule(rule.id, by: $0) },
                    onDropRule: { moveRule($0, onto: rule.id) },
                    onDelete: { deleteRule(rule.id) }
                )
            }
            HStack {
                Button("Add Rule", action: addRule)
                    .disabled(store.fences.isEmpty)
                Spacer()
                if !newFiles.rules.isEmpty && !newFiles.mode.usesRules {
                    Text("Rules aren't used with \u{201C}\(newFiles.mode.title)\u{201D}.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("New Desktop Files")
        } footer: {
            Text("Clutter Buster can put files you save, download or move to the Desktop into a fence. Rules are checked from the top and the first match wins; drag a rule by its handle to change the order. Leave the name or extension empty to match any. A rule whose fence or tab was deleted is skipped. Asking shows a card by the toolbar; ignoring it leaves the file on the Desktop.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addRule() {
        let fence = store.fences.first
        newFiles.rules.append(AutoFileRule(kind: .pdf, fenceID: fence?.id, tabID: fence?.tabs.first?.id))
        Log.write("new files: added rule \(newFiles.rules.count)")
    }

    private func deleteRule(_ id: UUID) {
        guard let index = newFiles.rules.firstIndex(where: { $0.id == id }) else { return }
        let rule = newFiles.rules.remove(at: index)
        Log.write("new files: deleted rule \(index + 1) (\(rule.summary))")
    }

    private func moveRule(_ id: UUID, by offset: Int) {
        guard let index = newFiles.rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard newFiles.rules.indices.contains(target) else { return }
        moveRule(id, onto: newFiles.rules[target].id)
    }

    /// Puts the rule in the place of the one it's dropped on, which moves aside.
    private func moveRule(_ id: UUID, onto targetID: UUID) {
        guard id != targetID, let from = newFiles.rules.firstIndex(where: { $0.id == id }),
              let to = newFiles.rules.firstIndex(where: { $0.id == targetID }) else { return }
        var rules = newFiles.rules
        let rule = rules.remove(at: from)
        rules.insert(rule, at: to)
        newFiles.rules = rules
        Log.write("new files: moved rule \(from + 1) (\(rule.summary)) to \(to + 1)")
    }
}

/// "If [kind] [name contains] [extension] put in [fence] › [tab]".
private struct AutoFileRuleRow: View {
    @Binding var rule: AutoFileRule
    let fences: [Fence]
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (Int) -> Void
    let onDropRule: (UUID) -> Void
    let onDelete: () -> Void

    @State private var dropTargeted = false

    private var fence: Fence? { fences.first { $0.id == rule.fenceID } }

    var body: some View {
        let problem = rule.problem(in: fences)
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 40)
                .contentShape(Rectangle())
                .draggable(rule.id.uuidString) {
                    Text(rule.summary)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                }
                .help("Drag to change the order")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("If")
                        .frame(width: 44, alignment: .leading)
                    Picker("Kind", selection: $rule.kind) {
                        ForEach(FileKind.allCases) { kind in
                            Text(kind.name).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 128, alignment: .leading)
                    TextField("Name contains", text: $rule.nameContains, prompt: Text("name contains"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    TextField("Extension", text: $rule.fileExtension, prompt: Text("extension"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 78)
                }
                HStack(spacing: 6) {
                    Text("put in")
                        .frame(width: 44, alignment: .leading)
                    Picker("Fence", selection: fenceSelection) {
                        if rule.fenceID == nil {
                            Text("Choose a fence").tag(UUID?.none)
                        } else if fence == nil {
                            Text("Deleted fence").tag(rule.fenceID)
                        }
                        ForEach(fences) { fence in
                            Text(fence.title).tag(Optional(fence.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("\u{203A}")
                        .foregroundStyle(.secondary)
                    Picker("Tab", selection: $rule.tabID) {
                        Text("Tab that's showing").tag(UUID?.none)
                        if let fence {
                            if let tabID = rule.tabID, !fence.tabs.contains(where: { $0.id == tabID }) {
                                Text("Deleted tab").tag(rule.tabID)
                            }
                            ForEach(fence.tabs) { tab in
                                Text(tab.name).tag(Optional(tab.id))
                            }
                        } else if rule.tabID != nil {
                            Text("Deleted tab").tag(rule.tabID)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(fence == nil)
                    Spacer(minLength: 0)
                }
                if let problem {
                    Label("\(problem), so this rule is skipped", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this rule")
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(dropTargeted ? 0.15 : 0)))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)), id != rule.id else { return false }
            onDropRule(id)
            return true
        } isTargeted: { dropTargeted = $0 }
        .contextMenu {
            Button("Move Up") { onMove(-1) }.disabled(!canMoveUp)
            Button("Move Down") { onMove(1) }.disabled(!canMoveDown)
            Divider()
            Button("Delete Rule", action: onDelete)
        }
    }

    /// Choosing another fence starts at its first tab.
    private var fenceSelection: Binding<UUID?> {
        Binding(
            get: { rule.fenceID },
            set: { id in
                guard id != rule.fenceID else { return }
                rule.fenceID = id
                rule.tabID = fences.first { $0.id == id }?.tabs.first?.id
            }
        )
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
