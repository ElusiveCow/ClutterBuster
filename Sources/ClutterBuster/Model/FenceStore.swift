import Foundation

/// Source of truth for fences and their items, saved as JSON in Application Support.
@MainActor
final class FenceStore: ObservableObject {
    private struct Layout: Codable {
        var fences: [Fence]
        var toolbarOrigin: CGPoint?
    }

    @Published private(set) var fences: [Fence] = []
    var toolbarOrigin: CGPoint? { didSet { scheduleSave() } }

    private let fileURL: URL
    private var saveWork: DispatchWorkItem?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClutterBuster", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("layout.json")
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
        scheduleSave()
    }

    func update(_ id: UUID, _ mutate: (inout Fence) -> Void) {
        guard let index = fences.firstIndex(where: { $0.id == id }) else { return }
        mutate(&fences[index])
        scheduleSave()
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let layout = Layout(fences: fences, toolbarOrigin: toolbarOrigin)
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
        } catch {
            NSLog("Clutter Buster: failed to read layout: \(error)")
        }
    }
}
