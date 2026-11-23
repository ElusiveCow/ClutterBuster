import AppKit
import SwiftUI

/// Lists and runs the user's Shortcuts with the `shortcuts` command-line tool. Arguments go
/// straight to the tool, never through a shell, so a name needs no quoting.
enum ShortcutsTool {
    static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
    static let listArguments = ["list"]

    static func runArguments(_ name: String) -> [String] {
        ["run", name]
    }

    /// One name per line, in the tool's order, without blanks or repeats.
    static func parseList(_ output: String) -> [String] {
        var seen: Set<String> = []
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// The names of the user's Shortcuts.
    static func list() async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = listArguments
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(reason: message.isEmpty ? "The shortcuts tool stopped with status \(process.terminationStatus)." : message)
            }
            return parseList(String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Runs a Shortcut without waiting for it. If it fails, says why in an alert.
    @MainActor
    static func run(_ name: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = runArguments(name)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { process in
            let status = process.terminationStatus
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                Log.write("shortcut: \"\(name)\" finished with status \(status)\(message.isEmpty ? "" : ": \(message)")")
                guard status != 0 else { return }
                showFailure(name, message.isEmpty ? "It stopped with status \(status)." : message)
            }
        }
        do {
            try process.run()
            Log.write("shortcut: running \"\(name)\"")
        } catch {
            Log.write("shortcut: couldn't run \"\(name)\": \(error.localizedDescription)")
            showFailure(name, error.localizedDescription)
        }
    }

    @MainActor
    private static func showFailure(_ name: String, _ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The shortcut \u{201C}\(name)\u{201D} didn't run"
        alert.informativeText = reason
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// The list in the Add Shortcut dialog.
@MainActor
final class ShortcutPickerModel: ObservableObject {
    let names: [String]
    @Published var query = ""
    @Published var selection: Set<String> = []
    /// Called when a name is double-clicked.
    var onChoose: () -> Void = {}

    init(names: [String]) {
        self.names = names
    }

    var shown: [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct ShortcutPickerView: View {
    @ObservedObject var model: ShortcutPickerModel

    var body: some View {
        VStack(spacing: 8) {
            TextField("Filter", text: $model.query)
                .textFieldStyle(.roundedBorder)
            List(model.shown, id: \.self, selection: $model.selection) { name in
                Label {
                    Text(name)
                } icon: {
                    ShortcutIcon(size: 18)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    model.selection = [name]
                    model.onChoose()
                })
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
        .frame(width: 320, height: 260)
    }
}
