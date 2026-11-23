import Foundation

/// The last fence actions that can be taken back, newest last. Each entry's `undo` reverses
/// its action; its `discard` lets go of whatever was kept for it, such as a deleted fence's
/// corner picture, once it can't be undone any more: when it drops off the end of the
/// history, or when the history is emptied on quit.
@MainActor
final class UndoHistory: ObservableObject {
    /// What the toast says after an action. Actions without one show no toast.
    struct Toast: Equatable {
        var symbol: String
        var message: String
    }

    struct Entry: Identifiable {
        let id = UUID()
        /// What the action did, as in "Delete “Work Folders”". Menus put "Undo" before it.
        let name: String
        let toast: Toast?
        fileprivate let undo: () -> Void
        fileprivate let discard: () -> Void
    }

    nonisolated static let defaultLimit = 20

    let limit: Int
    /// Oldest first.
    @Published private(set) var entries: [Entry] = []
    /// True while an entry is being undone. Whatever it calls records nothing new.
    private(set) var isUndoing = false

    init(limit: Int = UndoHistory.defaultLimit) {
        self.limit = max(limit, 1)
    }

    var last: Entry? { entries.last }

    /// "Undo" and what the next undo would undo, or just "Undo" with nothing to undo.
    var menuTitle: String { last.map { "Undo \($0.name)" } ?? "Undo" }

    func contains(_ id: UUID) -> Bool { entries.contains { $0.id == id } }

    /// Adds an action. Past the limit the oldest one goes, and is discarded. Returns nil,
    /// recording nothing, while an undo is running.
    @discardableResult
    func record(_ name: String, toast: Toast? = nil, undo: @escaping () -> Void, discard: @escaping () -> Void = {}) -> Entry? {
        guard !isUndoing else { return nil }
        let entry = Entry(name: name, toast: toast, undo: undo, discard: discard)
        entries.append(entry)
        let overflow = entries.count - limit
        if overflow > 0 {
            let dropped = entries.prefix(overflow)
            entries.removeFirst(overflow)
            for old in dropped { old.discard() }
        }
        return entry
    }

    /// Undoes the newest action. Returns it, or nil with nothing to undo.
    @discardableResult
    func undoLast() -> Entry? {
        guard let entry = entries.last, undo(entry.id) else { return nil }
        return entry
    }

    /// Undoes one action, even with newer ones after it, as the toast's Undo button does.
    /// Its entry goes, without being discarded. False if it's no longer in the history.
    @discardableResult
    func undo(_ id: UUID) -> Bool {
        guard !isUndoing, let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let entry = entries.remove(at: index)
        isUndoing = true
        defer { isUndoing = false }
        entry.undo()
        return true
    }

    /// Forgets every action, discarding each, oldest first.
    func removeAll() {
        let dropped = entries
        entries = []
        for entry in dropped { entry.discard() }
    }
}

/// A tab taken out of a fence, with what it takes to put it back as it was.
struct RemovedTab {
    let tab: FenceTab
    /// Where it was among the fence's tabs.
    let index: Int
    /// The items that were in it, which moved to the first remaining tab.
    let itemIDs: [UUID]
    let wasSelected: Bool
}

extension Fence {
    /// Removes a tab and moves its items into the first remaining tab. The last tab stays,
    /// and gives nil.
    mutating func removeTab(_ tabID: UUID) -> RemovedTab? {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let tab = tabs.remove(at: index)
        let destination = tabs[0].id
        var moved: [UUID] = []
        for itemIndex in items.indices where items[itemIndex].tabID == tabID {
            items[itemIndex].tabID = destination
            moved.append(items[itemIndex].id)
        }
        let wasSelected = selectedTabID == tabID
        if wasSelected { selectedTabID = destination }
        return RemovedTab(tab: tab, index: index, itemIDs: moved, wasSelected: wasSelected)
    }

    /// Puts a removed tab back in its place with its items, selected again if it was.
    /// False if the fence has the tab already.
    @discardableResult
    mutating func restoreTab(_ removed: RemovedTab) -> Bool {
        guard !tabs.contains(where: { $0.id == removed.tab.id }) else { return false }
        tabs.insert(removed.tab, at: min(removed.index, tabs.count))
        let itemIDs = Set(removed.itemIDs)
        for index in items.indices where itemIDs.contains(items[index].id) {
            items[index].tabID = removed.tab.id
        }
        if removed.wasSelected { selectedTabID = removed.tab.id }
        return true
    }

    /// Puts an item back at `index` in the manual order, in its own tab, or the first tab
    /// if that's gone.
    mutating func insertItem(_ item: FenceItem, at index: Int) {
        var item = item
        if !tabs.contains(where: { $0.id == item.tabID }) { item.tabID = tabs[0].id }
        items.insert(item, at: min(max(index, 0), items.count))
    }
}
