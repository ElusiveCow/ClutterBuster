import Foundation

/// The file side of dropping items on a folder tile: moves or copies them into the folder
/// the way Finder does, under a free name, and never over an existing file.
enum FolderDrop {
    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// True for a folder that opens as a folder, not an app or other package.
    static func isFolder(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// Why `source` can't go into `folder`, or nil if it can. Finder refuses to put a folder
    /// into itself or one of its own subfolders, for a copy as well as a move.
    static func problem(putting source: URL, into folder: URL) -> String? {
        let from = source.standardizedFileURL.resolvingSymlinksInPath().path
        let to = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard to == from || to.hasPrefix(from + "/") else { return nil }
        return "\u{201C}\(source.lastPathComponent)\u{201D} can't go into itself or one of its own folders."
    }

    /// Finder copies rather than moves between volumes unless told otherwise.
    static func onSameVolume(_ source: URL, _ folder: URL) -> Bool {
        let a = try? source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let b = try? folder.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let a, let b else { return true }
        return a.isEqual(b)
    }

    /// Where `source` lands in `folder`: its own name if that's free, else Finder's
    /// "name 2.ext", "name 3.ext" and so on. Folders keep any dots in their names.
    static func freeDestination(for source: URL, in folder: URL) -> URL {
        let name = source.lastPathComponent
        var candidate = folder.appendingPathComponent(name)
        guard exists(candidate) else { return candidate }
        let splitsExtension = !isFolder(source.path)
        let ext = splitsExtension ? (name as NSString).pathExtension : ""
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var number = 2
        repeat {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        } while exists(candidate)
        return candidate
    }

    /// Moves or copies `source` into `folder` and returns where it ended up. FileManager fails
    /// rather than replace a file that appears at the destination in the meantime.
    static func transfer(_ source: URL, into folder: URL, copy: Bool) throws -> URL {
        if let problem = problem(putting: source, into: folder) { throw Failure(reason: problem) }
        let destination = freeDestination(for: source, in: folder)
        if copy {
            try FileManager.default.copyItem(at: source, to: destination)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        return destination
    }

    /// Also true for a broken symlink, which `fileExists` follows and misses.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
