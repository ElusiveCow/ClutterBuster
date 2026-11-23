import Foundation

/// File details used for sorting, cached briefly so redrawing a fence doesn't hit the disk.
@MainActor
final class FileInfoCache {
    struct Info {
        var kind: String
        var modified: Date
        var size: Int64
        var fetchedAt: Date
    }

    static let shared = FileInfoCache()
    private let lifetime: TimeInterval = 30
    private var entries: [String: Info] = [:]

    func info(for path: String) -> Info {
        if let entry = entries[path], Date().timeIntervalSince(entry.fetchedAt) < lifetime { return entry }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
            .localizedTypeDescriptionKey, .contentModificationDateKey, .fileSizeKey, .isDirectoryKey,
        ])
        let info = Info(
            kind: values?.localizedTypeDescription ?? "",
            modified: values?.contentModificationDate ?? .distantPast,
            size: Int64(values?.fileSize ?? 0),
            fetchedAt: Date()
        )
        entries[path] = info
        return info
    }

    /// The same details for any item. Links, notes and Shortcuts aren't files: a note was
    /// modified when its text last changed, the others when they were added, and only a
    /// note has a size, its text's.
    func info(for item: FenceItem) -> Info {
        switch item.kind {
        case .file:
            return info(for: item.path)
        case .link, .shortcut:
            return Info(kind: item.kindName ?? "", modified: item.addedAt, size: 0, fetchedAt: Date())
        case .note:
            return Info(kind: item.kindName ?? "", modified: item.editedAt ?? item.addedAt, size: Int64(item.text?.utf8.count ?? 0), fetchedAt: Date())
        }
    }

    func invalidate() {
        entries.removeAll()
    }
}

extension TabSort {
    var label: String {
        key == .manual ? key.name : "\(key.name) \(ascending ? "\u{2191}" : "\u{2193}")"
    }

    /// Items in display order. Manual keeps the stored order. "Kind" groups files (by their
    /// type), then links, notes and Shortcuts.
    @MainActor
    func apply(to items: [FenceItem]) -> [FenceItem] {
        guard key != .manual else { return items }
        let cache = FileInfoCache.shared
        let byName: (FenceItem, FenceItem) -> Bool = {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        let sorted = items.sorted { a, b in
            switch key {
            case .manual, .name:
                return byName(a, b)
            case .kind:
                if a.kind != b.kind { return a.kind.sortRank < b.kind.sortRank }
                let (ka, kb) = (cache.info(for: a).kind, cache.info(for: b).kind)
                return ka == kb ? byName(a, b) : ka.localizedStandardCompare(kb) == .orderedAscending
            case .dateAdded:
                return a.addedAt == b.addedAt ? byName(a, b) : a.addedAt < b.addedAt
            case .dateModified:
                let (ma, mb) = (cache.info(for: a).modified, cache.info(for: b).modified)
                return ma == mb ? byName(a, b) : ma < mb
            case .size:
                let (sa, sb) = (cache.info(for: a).size, cache.info(for: b).size)
                return sa == sb ? byName(a, b) : sa < sb
            }
        }
        return ascending ? sorted : sorted.reversed()
    }
}
