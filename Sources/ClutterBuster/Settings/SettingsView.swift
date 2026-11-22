import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.defaultColorKey) private var defaultColor: FenceColor = .slate
    @AppStorage(AppSettings.defaultIconsPerRowKey) private var defaultIconsPerRow = 4

    @EnvironmentObject private var store: FenceStore
    let onQuit: () -> Void

    var body: some View {
        Form {
            Section("New fences") {
                Picker("Color", selection: $defaultColor) {
                    ForEach(FenceColor.allCases) { color in
                        Text(color.name).tag(color)
                    }
                }
                Stepper("Icons per row: \(defaultIconsPerRow)", value: $defaultIconsPerRow, in: AppSettings.iconsPerRowRange)
            }
            Section("About") {
                LabeledContent("Fences", value: "\(store.fences.count)")
                LabeledContent("Items", value: "\(store.fences.reduce(0) { $0 + $1.items.count })")
                Text("Files in fences stay in your Desktop folder. Clutter Buster hides their icons underneath the fence, and quitting puts every icon back where it was.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Quit Clutter Buster", action: onQuit)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
