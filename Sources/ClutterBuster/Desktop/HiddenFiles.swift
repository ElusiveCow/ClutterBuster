import Foundation

extension Notification.Name {
    /// Posted after Clutter Buster marks Desktop files hidden. `userInfo[HiddenFiles.pathsKey]`
    /// holds the paths as `[String]`.
    static let clutterBusterDidHideFiles = Notification.Name("ClutterBusterDidHideFiles")
    /// Posted after Clutter Buster unhides Desktop files it had hidden, so a Desktop watcher
    /// can tell them apart from files the user just added. Same `userInfo` as above.
    static let clutterBusterDidUnhideFiles = Notification.Name("ClutterBusterDidUnhideFiles")
}

/// Hides fenced Desktop files from Finder with the Finder hidden flag (`chflags hidden`).
/// Every path it hides goes into a ledger in Application Support before the flag is set, so
/// files left hidden by a crash can be put back at the next launch. Files it didn't hide,
/// such as `.localized` or the user's own hidden files, are never unhidden.
@MainActor
final class HiddenFiles {
    static let pathsKey = "paths"

    /// Paths Clutter Buster has hidden and not yet unhidden.
    private(set) var paths: Set<String> = []

    private let fileURL: URL
    private var recentChanges: [String: Date] = [:]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClutterBuster", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("hidden.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([String].self, from: data) {
            paths = Set(saved)
        }
    }

    nonisolated static func isHidden(_ url: URL) -> Bool {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true
    }

    /// Clears the hidden flag a copy inherits from a file Clutter Buster hid. The copy isn't
    /// fenced, so it never goes in the ledger.
    nonisolated static func showCopy(_ url: URL) {
        guard isHidden(url) else { return }
        var url = url
        var values = URLResourceValues()
        values.isHidden = false
        do {
            try url.setResourceValues(values)
        } catch {
            Log.write("hidden flag: couldn't unhide the copy \"\(url.lastPathComponent)\": \(error.localizedDescription)")
        }
    }

    /// Hides files that are visible now and records them. A file that's already hidden stays
    /// out of the ledger unless Clutter Buster hid it. Returns the paths it newly hid.
    @discardableResult
    func hide(_ urls: [URL]) -> [String] {
        let candidates = urls.map(\.standardizedFileURL).filter { url in
            !paths.contains(url.path) && FileManager.default.fileExists(atPath: url.path) && !Self.isHidden(url)
        }
        guard !candidates.isEmpty else { return [] }
        // Recorded first so a crash between the two steps can't leave an unrecorded hidden file.
        paths.formUnion(candidates.map(\.path))
        save()
        var hidden: [String] = []
        for url in candidates {
            if setHidden(url, true) {
                hidden.append(url.path)
            } else {
                paths.remove(url.path)
            }
        }
        if hidden.count != candidates.count { save() }
        finish(hidden, notification: .clutterBusterDidHideFiles)
        return hidden
    }

    /// Unhides files Clutter Buster hid and forgets them. Other files are left alone.
    /// Returns the paths it unhid.
    @discardableResult
    func unhide(_ urls: [URL]) -> [String] {
        let candidates = urls.map(\.standardizedFileURL).filter { paths.contains($0.path) }
        guard !candidates.isEmpty else { return [] }
        var unhidden: [String] = []
        for url in candidates {
            // A file that's gone has nothing to unhide; it just leaves the ledger.
            if FileManager.default.fileExists(atPath: url.path), setHidden(url, false) {
                unhidden.append(url.path)
            }
            paths.remove(url.path)
        }
        save()
        finish(unhidden, notification: .clutterBusterDidUnhideFiles)
        return unhidden
    }

    /// True for a few seconds after Clutter Buster hides or unhides `path`, for watchers that
    /// see the change after the notification.
    func changedRecently(_ path: String, within interval: TimeInterval = 5) -> Bool {
        guard let date = recentChanges[URL(fileURLWithPath: path).standardizedFileURL.path] else { return false }
        return Date().timeIntervalSince(date) < interval
    }

    private func setHidden(_ url: URL, _ hidden: Bool) -> Bool {
        var url = url
        var values = URLResourceValues()
        values.isHidden = hidden
        do {
            try url.setResourceValues(values)
            return true
        } catch {
            Log.write("hidden flag: couldn't \(hidden ? "hide" : "unhide") \"\(url.lastPathComponent)\": \(error.localizedDescription)")
            return false
        }
    }

    private func finish(_ changed: [String], notification: Notification.Name) {
        guard !changed.isEmpty else { return }
        let now = Date()
        recentChanges = recentChanges.filter { now.timeIntervalSince($0.value) < 60 }
        for path in changed { recentChanges[path] = now }
        NotificationCenter.default.post(name: notification, object: self, userInfo: [Self.pathsKey: changed])
    }

    private func save() {
        do {
            try JSONEncoder().encode(paths.sorted()).write(to: fileURL, options: .atomic)
        } catch {
            Log.write("hidden flag: failed to save the ledger: \(error.localizedDescription)")
        }
    }
}
