import Foundation

/// Appends timestamped lines to ~/Library/Logs/ClutterBuster.log for bug reports.
enum Log {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClutterBuster.log")

    private static let queue = DispatchQueue(label: "com.elusivecow.ClutterBuster.log")
    private static let maxBytes = 1_000_000

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])) \(message)\n"
        queue.async {
            let manager = FileManager.default
            if let size = (try? manager.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > maxBytes {
                let old = fileURL.deletingPathExtension().appendingPathExtension("old.log")
                try? manager.removeItem(at: old)
                try? manager.moveItem(at: fileURL, to: old)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
