/// Whether the fences are up for a peek, brought above app windows by the Peek at Fences
/// shortcut, and what each event does to it.
struct PeekState: Equatable {
    enum Trigger: String {
        case hotKey = "the shortcut"
        case escape = "Esc"
        case outsideClick = "a click outside the fences"
        case clickInFence = "a click in a fence"
        case openedItem = "opening an item"
        case revealedInFinder = "Show in Finder"
        case fencesShownOrHidden = "Show/Hide Fences"
    }

    enum Change: Equatable {
        /// `showingHiddenFences` when Show/Hide Fences has them hidden, so they come out
        /// for the peek alone.
        case start(showingHiddenFences: Bool)
        /// `hidingFencesAgain` puts away fences that were hidden before the peek.
        case end(hidingFencesAgain: Bool)
    }

    private(set) var isPeeking = false
    /// The fences were hidden when the peek began.
    private(set) var showsHiddenFences = false

    /// The shortcut starts a peek or ends it. Esc, a click outside, opening an item and
    /// Show in Finder end it; a click in a fence doesn't. Showing or hiding the fences ends
    /// it without hiding them again, since that decides whether they show.
    mutating func handle(_ trigger: Trigger, fencesHidden: Bool) -> Change? {
        guard isPeeking else {
            guard trigger == .hotKey else { return nil }
            isPeeking = true
            showsHiddenFences = fencesHidden
            return .start(showingHiddenFences: fencesHidden)
        }
        if trigger == .clickInFence { return nil }
        let hidingAgain = showsHiddenFences && trigger != .fencesShownOrHidden
        isPeeking = false
        showsHiddenFences = false
        return .end(hidingFencesAgain: hidingAgain)
    }
}
