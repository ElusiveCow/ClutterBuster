import AppKit
import UniformTypeIdentifiers

struct SearchResult: Identifiable {
    enum Section: String, CaseIterable {
        case fences = "In Fences"
        case desktop = "On the Desktop"
        case mac = "On This Mac"
    }

    let section: Section
    /// The file, or a link's address. Notes and Shortcuts have none.
    let url: URL?
    let name: String
    let subtitle: String
    let icon: NSImage
    /// Set for links, notes and Shortcuts, which open and show through their fence.
    var itemID: UUID?
    /// Set for a line of a sticky note fence's note.
    var noteMatch: NoteMatch?

    var id: String {
        if let noteMatch { return section.rawValue + noteMatch.fenceID.uuidString + noteMatch.tabID.uuidString + ":\(noteMatch.line)" }
        return section.rawValue + (itemID?.uuidString ?? url?.path ?? name)
    }
    var isFile: Bool { itemID == nil && noteMatch == nil }
}

/// Where search text was found in a sticky note: the fence and tab, which line, and the
/// text to select.
struct NoteMatch {
    let fenceID: UUID
    let tabID: UUID
    let line: Int
    let range: NSRange

    /// One match per line of the note that contains `query`, ignoring checklist markers.
    static func find(_ query: String, in note: String, fenceID: UUID, tabID: UUID) -> [(match: NoteMatch, text: String)] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let text = note as NSString
        return NoteEditing.lineRanges(in: text).enumerated().compactMap { index, line in
            let start = NoteEditing.markerRange(in: text, line: line).map(NSMaxRange) ?? line.location
            let content = NSRange(location: start, length: NSMaxRange(line) - start)
            let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: content)
            guard found.location != NSNotFound else { return nil }
            let shown = text.substring(with: content).trimmingCharacters(in: .whitespaces)
            return (NoteMatch(fenceID: fenceID, tabID: tabID, line: index, range: found), shown)
        }
    }
}

extension SearchResult {
    /// A result for each line of each of a sticky note's tabs that contains `query`.
    static func noteResults(_ query: String, in fence: Fence) -> [SearchResult] {
        guard fence.isStickyNote else { return [] }
        return fence.tabs.flatMap { tab in
            let icon = StickyNoteIcon.image(paper: fence.paper(for: tab))
            return NoteMatch.find(query, in: tab.note ?? "", fenceID: fence.id, tabID: tab.id).map { match, line in
                SearchResult(
                    section: .fences, url: nil, name: String(line.prefix(200)),
                    subtitle: "Sticky note \u{00B7} \u{201C}\(fence.title)\u{201D} \u{203A} \(tab.name)",
                    icon: icon, noteMatch: match
                )
            }
        }
    }
}

/// Searches fence items, Desktop files that aren't in a fence, and the rest of the Mac
/// through Spotlight.
@MainActor
final class SearchService: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            selection = 0
            scrollTarget = nil
            scheduleSearch()
        }
    }
    @Published private(set) var results: [SearchResult] = [] {
        didSet { if selection >= results.count { selection = 0 } }
    }
    /// True from the first keystroke until Spotlight finishes gathering.
    @Published private(set) var isSearching = false
    /// Index of the highlighted result.
    @Published var selection = 0
    /// Set only by the arrow keys, so hovering never scrolls the list under the mouse.
    @Published private(set) var scrollTarget: Int?

    var selectedResult: SearchResult? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
        scrollTarget = selection
    }

    private let store: FenceStore
    private let macResultLimit = 40
    private var localResults: [SearchResult] = []
    private var excludedPaths: Set<String> = []
    private var metadataQuery: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var pendingSearch: DispatchWorkItem?

    init(store: FenceStore) {
        self.store = store
    }

    func reset() {
        query = ""
        pendingSearch?.cancel()
        stopMacSearch()
        localResults = []
        results = []
    }

    private func scheduleSearch() {
        pendingSearch?.cancel()
        isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.search() }
        }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        stopMacSearch()
        guard !text.isEmpty else {
            localResults = []
            results = []
            return
        }

        var fenceResults: [SearchResult] = []
        var fencedPaths: Set<String> = []
        for fence in store.fences {
            if fence.isStickyNote {
                fenceResults += SearchResult.noteResults(text, in: fence)
                continue
            }
            for item in fence.items {
                if item.isFile { fencedPaths.insert(item.path) }
                guard item.matches(text) else { continue }
                let place = "In fence \u{201C}\(fence.title)\u{201D} \u{203A} \(fence.tabs.first { $0.id == item.tabID }?.name ?? fence.tabs[0].name)"
                if item.isFile {
                    fenceResults.append(SearchResult(
                        section: .fences, url: item.url, name: item.displayName, subtitle: place,
                        icon: IconProvider.shared.plainIcon(for: item.path)
                    ))
                } else {
                    let what: String = switch item.kind {
                    case .link: item.webURL?.host() ?? "Link"
                    case .note: "Note"
                    default: item.kindName ?? ""
                    }
                    fenceResults.append(SearchResult(
                        section: .fences, url: item.webURL, name: item.displayName,
                        subtitle: "\(what) \u{00B7} \(place)",
                        icon: TileIcon.image(for: item, size: 26, scale: 2), itemID: item.id
                    ))
                }
            }
        }

        let desktopFiles = (try? FileManager.default.contentsOfDirectory(
            at: DesktopIconService.desktopURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let desktopResults = desktopFiles
            .filter { !fencedPaths.contains($0.standardizedFileURL.path) }
            .map { (url: $0, name: FileManager.default.displayName(atPath: $0.path)) }
            .filter { $0.name.localizedCaseInsensitiveContains(text) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { SearchResult(section: .desktop, url: $0.url, name: $0.name, subtitle: "On the desktop", icon: NSWorkspace.shared.icon(forFile: $0.url.path)) }

        localResults = fenceResults + desktopResults
        excludedPaths = Set(localResults.filter(\.isFile).compactMap { $0.url?.standardizedFileURL.path })
        results = localResults
        startMacSearch(for: text)
    }

    // MARK: Spotlight

    private func startMacSearch(for text: String) {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemDisplayNameKey, "*\(escaped)*")
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collectMacResults() }
            })
        }
        metadataQuery = query
        isSearching = true
        query.start()
    }

    private func stopMacSearch() {
        metadataQuery?.stop()
        metadataQuery = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        isSearching = false
    }

    private func collectMacResults() {
        guard let query = metadataQuery else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        var macResults: [SearchResult] = []
        for index in 0..<query.resultCount {
            guard macResults.count < macResultLimit,
                  let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !excludedPaths.contains(path),
                  isUsefulLocation(path) else { continue }
            let url = URL(fileURLWithPath: path)
            let name = item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String ?? url.lastPathComponent
            let contentType = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
            macResults.append(SearchResult(
                section: .mac, url: url, name: name,
                subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                icon: icon(forPath: path, contentType: contentType)
            ))
        }
        results = localResults + macResults
        if query.isGathering == false { isSearching = false }
    }

    /// Skips system internals, caches and hidden folders so results stay about the user's things.
    private func isUsefulLocation(_ path: String) -> Bool {
        if path.contains("/.") || path.contains("/Library/") { return false }
        if path.hasPrefix("/System/") { return path.hasPrefix("/System/Applications/") }
        return !path.hasPrefix("/private/") && !path.hasPrefix("/usr/") && !path.hasPrefix("/opt/")
    }

    /// Apps get their real icon. Other files get their type's icon, which avoids reading files in
    /// protected folders (and the permission prompts that would trigger) just to draw a result.
    private func icon(forPath path: String, contentType: String?) -> NSImage {
        if path.hasSuffix(".app") { return NSWorkspace.shared.icon(forFile: path) }
        if let contentType, let type = UTType(contentType) { return NSWorkspace.shared.icon(for: type) }
        return NSWorkspace.shared.icon(for: .data)
    }
}
