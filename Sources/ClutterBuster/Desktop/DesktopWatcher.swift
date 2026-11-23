import CoreServices
import Foundation

extension Notification.Name {
    /// Posted after Clutter Buster moves or copies files into a folder for a drop on a folder
    /// tile, so a Desktop watcher doesn't take the results for new files. Same `userInfo` as
    /// `clutterBusterDidHideFiles`.
    static let clutterBusterDidPlaceFiles = Notification.Name("ClutterBusterDidPlaceFiles")
}

/// Watches the Desktop folder for items that are new to it: saved, downloaded, moved or
/// copied there while Clutter Buster runs. Each one is reported once, after it has finished
/// saving.
///
/// Presence in the folder is what counts, hidden or not, so hiding and unhiding fenced
/// files never looks like a new file. Items there at launch, renamed in place, saved over,
/// already in a fence, or just put there by Clutter Buster don't count either.
@MainActor
final class DesktopWatcher {
    /// Whether a path is in a fence already.
    var isFenced: (String) -> Bool = { _ in false }
    /// New items that have finished saving, a batch at a time.
    var onNewFiles: ([URL]) -> Void = { _ in }

    /// How long a path counts as put there by Clutter Buster after it hides, unhides or
    /// places it.
    static let ownChangeWindow: TimeInterval = 15
    /// How long an item's size and date have to stay the same before it counts as saved.
    static let settleTime: TimeInterval = 1
    /// Time for Finder to give a new icon its spot, which is recorded when it joins a fence.
    static let iconPlacementDelay: TimeInterval = 0.5
    /// A name that's gone and comes back within this time is the same file saved over.
    static let goneGrace: TimeInterval = 30
    static let giveUpAfter: TimeInterval = 15 * 60

    private let folder = DesktopIconService.desktopURL.standardizedFileURL

    private struct Entry {
        var inode: UInt64
        /// A download, temporary file or unnamed new folder. Renaming it makes a new file.
        var transient: Bool
        var goneSince: Date?
    }

    private struct Pending {
        let firstSeen: Date
        var state: FileState
        var stableSince: Date
        var loggedCopying = false
    }

    /// Every item in the folder, hidden or not, and items gone for less than `goneGrace`.
    private var known: [String: Entry] = [:]
    /// New items still being saved.
    private var pending: [String: Pending] = [:]
    /// Paths Clutter Buster hid, unhid or placed, and when.
    private var ownChanges: [String: Date] = [:]
    private var stream: FSEventStreamRef?
    private var scanWork: DispatchWorkItem?
    private var scanDue: Date?
    private var observers: [NSObjectProtocol] = []
    private var loggedListingError = false

    func start() {
        guard stream == nil else { return }
        let now = Date()
        for name in listing() ?? [] {
            known[name] = Entry(inode: Self.inode(of: folder.appendingPathComponent(name)) ?? 0, transient: Self.transientReason(name) != nil)
        }
        let pathsKey = HiddenFiles.pathsKey
        for name in [Notification.Name.clutterBusterDidHideFiles, .clutterBusterDidUnhideFiles, .clutterBusterDidPlaceFiles] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let paths = note.userInfo?[pathsKey] as? [String] ?? []
                MainActor.assumeIsolated { self?.noteOwnChanges(paths) }
            })
        }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DesktopWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let flags = Array(UnsafeBufferPointer(start: flags, count: count))
            MainActor.assumeIsolated { watcher.eventsArrived(changed, flags: flags) }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags
        ) else {
            Log.write("new files: couldn't watch the Desktop folder")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        Log.write("new files: watching the Desktop, \(known.count) item(s) there at launch (\(Int(Date().timeIntervalSince(now) * 1000)) ms)")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        scanWork?.cancel()
        scanWork = nil
    }

    // MARK: Events

    private func eventsArrived(_ paths: [String], flags: [FSEventStreamEventFlags]) {
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        // Changes inside folders on the Desktop don't add anything to it.
        let relevant = zip(paths, flags).contains { path, flag in
            flag & rescan != 0 || URL(fileURLWithPath: path).standardizedFileURL.path == folder.path
        }
        if relevant { scheduleScan(after: 1) }
    }

    private func noteOwnChanges(_ paths: [String]) {
        let now = Date()
        for path in paths { ownChanges[URL(fileURLWithPath: path).standardizedFileURL.path] = now }
    }

    /// Scans after `delay`, or sooner if a scan is already due sooner.
    private func scheduleScan(after delay: TimeInterval) {
        let due = Date().addingTimeInterval(delay)
        if let scanDue, scanDue <= due { return }
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.scanWork = nil
                self?.scanDue = nil
                self?.scan()
            }
        }
        scanWork = work
        scanDue = due
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Scanning

    private func listing() -> [String]? {
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            loggedListingError = false
            return names
        } catch {
            if !loggedListingError { Log.write("new files: couldn't read the Desktop folder: \(error.localizedDescription)") }
            loggedListingError = true
            return nil
        }
    }

    private func scan() {
        guard stream != nil, let names = listing() else { return }
        let now = Date()
        let present = Set(names)
        for (name, entry) in known where entry.goneSince == nil && !present.contains(name) {
            known[name]?.goneSince = now
        }
        known = known.filter { $0.value.goneSince.map { now.timeIntervalSince($0) < Self.goneGrace } ?? true }
        ownChanges = ownChanges.filter { now.timeIntervalSince($0.value) < Self.ownChangeWindow }
        for name in pending.keys where !present.contains(name) {
            Log.write("new item \"\(name)\": gone before it finished saving")
            pending[name] = nil
        }

        var ready: [URL] = []
        for name in present.sorted() {
            if var entry = known[name] {
                if entry.goneSince != nil {
                    // Saved over: written to a temporary file and swapped in under the same name.
                    entry.goneSince = nil
                    entry.inode = Self.inode(of: folder.appendingPathComponent(name)) ?? entry.inode
                    known[name] = entry
                }
                continue
            }
            if let url = evaluate(name, now: now) { ready.append(url) }
        }
        if !pending.isEmpty { scheduleScan(after: 0.5) }
        guard !ready.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.iconPlacementDelay) { [weak self] in
            MainActor.assumeIsolated { self?.deliver(ready) }
        }
    }

    /// Looks at an item that isn't known yet. Returns its URL once it has finished saving.
    private func evaluate(_ name: String, now: Date) -> URL? {
        let url = folder.appendingPathComponent(name)
        guard let state = Self.state(of: url) else { return nil }

        guard var waiting = pending[name] else {
            if let reason = Self.transientReason(name) {
                known[name] = Entry(inode: state.inode, transient: true)
                Log.write("new item \"\(name)\": skipped, \(reason)")
                return nil
            }
            if let (oldName, old) = known.first(where: { $0.value.goneSince != nil && $0.value.inode == state.inode }) {
                known[oldName] = nil
                known[name] = Entry(inode: state.inode, transient: false)
                if !old.transient {
                    Log.write("new item \"\(name)\": skipped, renamed from \"\(oldName)\"")
                    return nil
                }
                Log.write("new item \"\(name)\": renamed from \"\(oldName)\", which was still saving")
            }
            if let reason = skipReason(url) {
                known[name] = Entry(inode: state.inode, transient: false)
                Log.write("new item \"\(name)\": skipped, \(reason)")
                return nil
            }
            known[name] = nil
            pending[name] = Pending(firstSeen: now, state: state, stableSince: now)
            Log.write("new item \"\(name)\": noticed, waiting for it to finish saving")
            return nil
        }

        if state != waiting.state {
            waiting.state = state
            waiting.stableSince = now
        }
        if state.finderCopying, !waiting.loggedCopying {
            waiting.loggedCopying = true
            Log.write("new item \"\(name)\": Finder is still copying it")
        }
        let stable = !state.finderCopying
            && now.timeIntervalSince(waiting.stableSince) >= Self.settleTime
            && now.timeIntervalSince(waiting.firstSeen) >= Self.settleTime
        if !stable {
            if now.timeIntervalSince(waiting.firstSeen) > Self.giveUpAfter {
                pending[name] = nil
                known[name] = Entry(inode: state.inode, transient: false)
                Log.write("new item \"\(name)\": skipped, still changing after \(Int(Self.giveUpAfter / 60)) minutes")
            } else {
                pending[name] = waiting
            }
            return nil
        }
        pending[name] = nil
        known[name] = Entry(inode: state.inode, transient: false)
        // Clutter Buster may have placed or fenced it while it was saving.
        if let reason = skipReason(url) {
            Log.write("new item \"\(name)\": skipped, \(reason)")
            return nil
        }
        Log.write("new item \"\(name)\": finished saving (\(state.size) bytes)")
        return url
    }

    private func skipReason(_ url: URL) -> String? {
        if ownChanges[url.path] != nil { return "put there by Clutter Buster" }
        if isFenced(url.path) { return "already in a fence" }
        if HiddenFiles.isHidden(url) { return "hidden" }
        return nil
    }

    private func deliver(_ urls: [URL]) {
        let urls = urls.filter { url in
            guard FileManager.default.fileExists(atPath: url.path) else {
                Log.write("new item \"\(url.lastPathComponent)\": gone before it could be sorted")
                return false
            }
            if let reason = skipReason(url) {
                Log.write("new item \"\(url.lastPathComponent)\": skipped, \(reason)")
                return false
            }
            return true
        }
        if !urls.isEmpty { onNewFiles(urls) }
    }

    // MARK: Files

    private nonisolated static let downloadExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]
    private nonisolated static let temporaryExtensions: Set<String> = ["tmp", "temp", "swp", "swx"]

    /// Why an item name is never new on its own: an in-progress download, a temporary or
    /// hidden file, or a new folder that hasn't been named yet. Nil for ordinary names.
    nonisolated static func transientReason(_ name: String) -> String? {
        if name.hasPrefix(".") { return "hidden file" }
        if name.hasPrefix("~$") || name.hasSuffix("~") || name == "Icon\r" { return "temporary file" }
        let ext = (name as NSString).pathExtension.lowercased()
        if downloadExtensions.contains(ext) { return "download in progress" }
        if temporaryExtensions.contains(ext) { return "temporary file" }
        if name == "untitled folder" || name.hasPrefix("untitled folder ") { return "new folder that isn't named yet" }
        return nil
    }

    struct FileState: Equatable {
        var inode: UInt64
        /// For a folder or package, the total of the files inside.
        var size: Int64
        var modified: TimeInterval
        /// Finder dates a file it's still copying 24 January 1984.
        var finderCopying: Bool
    }

    nonisolated static func inode(of url: URL) -> UInt64? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    nonisolated static func state(of url: URL) -> FileState? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        var size = Int64(info.st_size)
        var modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        if info.st_mode & S_IFMT == S_IFDIR {
            let contents = folderContents(url)
            size = contents.size
            modified = max(modified, contents.modified)
        }
        let birth = Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec))
        let components = Calendar(identifier: .gregorian).dateComponents(in: .current, from: birth)
        return FileState(
            inode: UInt64(info.st_ino), size: size, modified: modified,
            finderCopying: components.year == 1984 && components.month == 1
        )
    }

    /// Total size and latest change of what's inside a folder, looking at up to 5,000 items.
    private nonisolated static func folderContents(_ url: URL) -> (size: Int64, modified: TimeInterval) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return (0, 0) }
        var size: Int64 = 0
        var modified: TimeInterval = 0
        var count = 0
        for case let item as URL in enumerator {
            count += 1
            if count > 5000 { break }
            let values = try? item.resourceValues(forKeys: Set(keys))
            size += Int64(values?.fileSize ?? 0)
            modified = max(modified, values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        return (size + Int64(count), modified)
    }
}
