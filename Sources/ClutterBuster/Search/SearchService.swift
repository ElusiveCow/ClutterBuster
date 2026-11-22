import AppKit
import UniformTypeIdentifiers

struct SearchResult: Identifiable {
    enum Section: String, CaseIterable {
        case fences = "In Fences"
        case desktop = "On the Desktop"
        case mac = "On This Mac"
    }

    let section: Section
    let url: URL
    let name: String
    let subtitle: String
    let icon: NSImage

    var id: String { section.rawValue + url.path }
}

/// Searches fence items, Desktop files that aren't in a fence, and the rest of the Mac
/// through Spotlight.
@MainActor
final class SearchService: ObservableObject {
    @Published var query = "" {
        didSet {
            Log.write("search query \"\(oldValue)\" -> \"\(query)\"")
            scheduleSearch()
        }
    }
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var isSearchingMac = false

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
        stopMacSearch()
        localResults = []
        results = []
    }

    private func scheduleSearch() {
        pendingSearch?.cancel()
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
            for item in fence.items {
                fencedPaths.insert(item.path)
                guard item.displayName.localizedCaseInsensitiveContains(text) else { continue }
                fenceResults.append(SearchResult(
                    section: .fences, url: item.url, name: item.displayName,
                    subtitle: "In fence \u{201C}\(fence.title)\u{201D}",
                    icon: NSWorkspace.shared.icon(forFile: item.path)
                ))
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
        excludedPaths = Set(localResults.map { $0.url.standardizedFileURL.path })
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
        isSearchingMac = true
        query.start()
    }

    private func stopMacSearch() {
        metadataQuery?.stop()
        metadataQuery = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        isSearchingMac = false
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
        if query.isGathering == false { isSearchingMac = false }
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
