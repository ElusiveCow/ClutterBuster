import Foundation

/// Source of truth for fences and their items, saved as JSON in Application Support.
/// Where the fences and the toolbar sit is kept for each set of displays; `fences` and the
/// toolbar fields always hold the layout for the displays in use.
@MainActor
final class FenceStore: ObservableObject {
    private struct Layout: Codable {
        var fences: [Fence]
        var toolbarOrigin: CGPoint?
        var toolbarShape: ToolbarShape?
        /// The display set `fences` and the toolbar are laid out for. Layouts saved before
        /// per-display layouts have neither this nor `displayLayouts`.
        var displayKey: String?
        var displayLayouts: [String: DisplayLayout]?

        init(fences: [Fence], toolbarOrigin: CGPoint?, toolbarShape: ToolbarShape?, displayKey: String?, displayLayouts: [String: DisplayLayout]) {
            self.fences = fences
            self.toolbarOrigin = toolbarOrigin
            self.toolbarShape = toolbarShape
            self.displayKey = displayKey
            self.displayLayouts = displayLayouts
        }

        /// A display layout that can't be read is dropped rather than losing the fences.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fences = try container.decode([Fence].self, forKey: .fences)
            toolbarOrigin = try container.decodeIfPresent(CGPoint.self, forKey: .toolbarOrigin)
            toolbarShape = try container.decodeIfPresent(ToolbarShape.self, forKey: .toolbarShape)
            displayKey = try? container.decodeIfPresent(String.self, forKey: .displayKey)
            displayLayouts = try? container.decodeIfPresent([String: DisplayLayout].self, forKey: .displayLayouts)
        }
    }

    /// What `useDisplayLayout` changed.
    struct DisplayChange {
        let from: String?
        let to: String
        /// No layout was saved for these displays, so the current one was carried over.
        let isNew: Bool
        /// The screens the fences' frames were laid out on.
        let savedScreens: [ScreenInfo]
        /// Fences the loaded layout has no frame for, made with other displays connected.
        /// Their frames are still the ones laid out on `previousScreens`.
        let unsaved: Set<UUID>
        let previousScreens: [ScreenInfo]

        var switched: Bool { from != to }
    }

    @Published private(set) var fences: [Fence] = []
    /// Where the toolbar's full shape sits, even while it's collapsed to a bubble.
    var toolbarOrigin: CGPoint? { didSet { scheduleSave() } }
    var toolbarShape: ToolbarShape? { didSet { scheduleSave() } }
    /// The display set in use, nil until `useDisplayLayout` first runs.
    private(set) var displayKey: String?
    @Published private(set) var displayLayouts: [String: DisplayLayout] = [:]

    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ClutterBuster", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.fileURL = support.appendingPathComponent("layout.json")
        }
        load()
    }

    func fence(_ id: UUID) -> Fence? {
        fences.first { $0.id == id }
    }

    func add(_ fence: Fence) {
        fences.append(fence)
        scheduleSave()
    }

    func remove(_ id: UUID) {
        fences.removeAll { $0.id == id }
        for key in displayLayouts.keys { displayLayouts[key]?.frames[id.uuidString] = nil }
        scheduleSave()
    }

    func update(_ id: UUID, _ mutate: (inout Fence) -> Void) {
        guard let index = fences.firstIndex(where: { $0.id == id }) else { return }
        mutate(&fences[index])
        scheduleSave()
    }

    // MARK: Display layouts

    /// Switches to the layout for the display set `key`, first saving the one in use. A set
    /// seen before gets its fences and toolbar back where they were; a new one starts from
    /// the current layout. Fitting frames onto `screens` is up to the caller, which then
    /// calls `layoutFits`.
    @discardableResult
    func useDisplayLayout(_ key: String, screens: [ScreenInfo]) -> DisplayChange {
        snapshotDisplayLayout()
        let previousScreens = displayKey.flatMap { displayLayouts[$0]?.screens } ?? []
        let from = displayKey
        guard key != displayKey else {
            return DisplayChange(from: from, to: key, isNew: false, savedScreens: previousScreens, unsaved: [], previousScreens: previousScreens)
        }
        displayKey = key
        guard let saved = displayLayouts[key] else {
            snapshotDisplayLayout()
            displayLayouts[key]?.screens = previousScreens
            pruneDisplayLayouts()
            scheduleSave()
            return DisplayChange(from: from, to: key, isNew: true, savedScreens: previousScreens, unsaved: [], previousScreens: previousScreens)
        }
        var unsaved: Set<UUID> = []
        var loaded = fences
        for index in loaded.indices {
            if let frame = saved.frames[loaded[index].id.uuidString] {
                loaded[index].frame = frame
            } else {
                unsaved.insert(loaded[index].id)
            }
        }
        fences = loaded
        if let origin = saved.toolbarOrigin { toolbarOrigin = origin }
        if let shape = saved.toolbarShape { toolbarShape = shape }
        scheduleSave()
        return DisplayChange(from: from, to: key, isNew: false, savedScreens: saved.screens, unsaved: unsaved, previousScreens: previousScreens)
    }

    /// Records that the layout in use now fits `screens`.
    func layoutFits(_ screens: [ScreenInfo]) {
        guard let displayKey else { return }
        snapshotDisplayLayout()
        displayLayouts[displayKey]?.screens = screens
        scheduleSave()
    }

    /// Copies where everything sits now into the layout for the displays in use.
    private func snapshotDisplayLayout() {
        guard let displayKey else { return }
        var layout = displayLayouts[displayKey] ?? DisplayLayout(screens: [], frames: [:], usedAt: Date())
        layout.frames = Dictionary(fences.map { ($0.id.uuidString, $0.frame) }, uniquingKeysWith: { first, _ in first })
        layout.toolbarOrigin = toolbarOrigin
        layout.toolbarShape = toolbarShape
        layout.usedAt = Date()
        displayLayouts[displayKey] = layout
    }

    private func pruneDisplayLayouts() {
        guard displayLayouts.count > DisplaySet.maxLayouts else { return }
        let oldest = displayLayouts.filter { $0.key != displayKey }.sorted { $0.value.usedAt < $1.value.usedAt }
        for (key, _) in oldest.prefix(displayLayouts.count - DisplaySet.maxLayouts) {
            displayLayouts[key] = nil
            Log.write("displays: forgot the layout for \(key), the least recently used")
        }
    }

    // MARK: Saving

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        snapshotDisplayLayout()
        let layout = Layout(fences: fences, toolbarOrigin: toolbarOrigin, toolbarShape: toolbarShape, displayKey: displayKey, displayLayouts: displayLayouts)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(layout).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Clutter Buster: failed to save layout: \(error)")
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let layout = try JSONDecoder().decode(Layout.self, from: data)
            fences = layout.fences
            toolbarOrigin = layout.toolbarOrigin
            toolbarShape = layout.toolbarShape
            displayKey = layout.displayKey
            displayLayouts = layout.displayLayouts ?? [:]
            if layout.displayLayouts == nil {
                Log.write("layout: from before per-display layouts; it becomes the layout for the displays connected now")
            }
            saveWork?.cancel()
        } catch {
            // Kept aside, since the next save would otherwise replace it with no fences.
            let aside = fileURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: aside)
            Log.write("layout: couldn't read \(fileURL.lastPathComponent), kept a copy as \(aside.lastPathComponent): \(error)")
            NSLog("Clutter Buster: failed to read layout: \(error)")
        }
    }
}
