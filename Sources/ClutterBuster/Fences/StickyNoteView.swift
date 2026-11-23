import AppKit
import SwiftUI

/// How a sticky note's text is drawn: its size, and the colors of its text, boxes and ruled
/// lines. Colors are kept in sRGB so equal looks compare equal and the note isn't restyled
/// on every redraw of its fence.
struct StickyNoteLook: Equatable {
    static let baseFontSize: CGFloat = 14

    var fontSize: CGFloat
    var text: NSColor
    var secondary: NSColor
    var boxFill: NSColor?
    var rule: NSColor?
    var shadow: NSColor?

    init(style: ThemeStyle, paper: PaperColor?, textScale: Double) {
        func srgb(_ color: Color) -> NSColor {
            let color = NSColor(color)
            return color.usingColorSpace(.sRGB) ?? color
        }
        fontSize = Self.baseFontSize * CGFloat(textScale)
        text = srgb(style.bodyText)
        secondary = srgb(style.bodySecondary)
        if let paper {
            rule = srgb(paper.rule).withAlphaComponent(0.5)
            boxFill = NSColor.white.withAlphaComponent(0.55)
        } else {
            // Notebook rules its own paper.
            rule = style.pattern == .ruledPaper ? nil : secondary.withAlphaComponent(0.18)
            // Keeps the theme's pattern from showing through an empty box.
            boxFill = style.isLight ? NSColor.white.withAlphaComponent(0.5) : NSColor.black.withAlphaComponent(0.5)
        }
        let shadow = srgb(style.textShadow)
        self.shadow = shadow.alphaComponent > 0.01 ? shadow : nil
    }

    var font: NSFont { .systemFont(ofSize: fontSize) }
    /// Every line is this tall, so the ruled lines fall between them.
    var lineHeight: CGFloat { (fontSize * 1.6).rounded() }
    var boxSize: CGFloat { (fontSize * 1.05).rounded() }
    /// The room a checklist item's box takes before its text.
    var markerWidth: CGFloat { boxSize + (fontSize * 0.5).rounded() }
    /// Done items are struck through in this.
    var done: NSColor { text.withAlphaComponent(0.45) }
}

/// A sticky note fence's body: the selected tab's note filling the fence below its tabs.
/// The text is saved a moment after typing stops, when the note loses focus, before another
/// tab is shown, when it goes away and when the app quits.
struct StickyNoteView: NSViewRepresentable {
    let fenceID: UUID
    let tabID: UUID
    /// Every tab of the fence; notes of tabs that are gone are let go.
    let tabIDs: [UUID]
    let note: String
    let look: StickyNoteLook
    /// Room kept under the last line so it can scroll clear of the hover controls.
    let bottomInset: CGFloat
    let fences: FenceCoordinator

    func makeNSView(context: Context) -> StickyNotePages {
        let pages = StickyNotePages()
        update(pages)
        return pages
    }

    func updateNSView(_ pages: StickyNotePages, context: Context) {
        update(pages)
    }

    private func update(_ pages: StickyNotePages) {
        let textView = pages.show(tabID, bottomInset: bottomInset) { tabID in
            let textView = StickyNoteTextView(look: look)
            textView.tabID = tabID
            textView.string = note
            textView.restyle()
            textView.onSave = { [weak fences] text in fences?.setStickyNote(fenceID, tab: tabID, text) }
            return textView
        }
        textView.apply(look)
        textView.show(note)
        pages.removePages(notIn: Set(tabIDs))
        fences.stickyTextViews.setObject(textView, forKey: fenceID as NSUUID)
    }

    static func dismantleNSView(_ pages: StickyNotePages, coordinator: ()) {
        pages.saveAll()
    }
}

/// One note per tab, each in its own scroll view, so each keeps its own scroll position,
/// selection and undo history. Only the selected tab's note shows.
final class StickyNotePages: NSView {
    private var pages: [UUID: StickyNoteScrollView] = [:]
    private var currentTabID: UUID?

    override var isFlipped: Bool { true }

    /// Shows the note of `tabID`, made by `make` the first time. The note it replaces is
    /// saved first, and the caret follows to the new one if it was in the old.
    func show(_ tabID: UUID, bottomInset: CGFloat, make: (UUID) -> StickyNoteTextView) -> StickyNoteTextView {
        let scroll = pages[tabID] ?? makePage(make(tabID), bottomInset: bottomInset)
        pages[tabID] = scroll
        if scroll.contentInsets.bottom != bottomInset {
            scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }
        let textView = scroll.documentView as! StickyNoteTextView
        guard currentTabID != tabID else { return textView }
        let old = currentTabID.flatMap { pages[$0] }
        let oldText = old?.documentView as? StickyNoteTextView
        let hadFocus = oldText != nil && window?.firstResponder === oldText
        oldText?.saveNow()
        old?.isHidden = true
        scroll.isHidden = false
        currentTabID = tabID
        if hadFocus { window?.makeFirstResponder(textView) }
        return textView
    }

    func removePages(notIn tabIDs: Set<UUID>) {
        for (tabID, scroll) in pages where !tabIDs.contains(tabID) {
            (scroll.documentView as? StickyNoteTextView)?.saveNow()
            scroll.removeFromSuperview()
            pages[tabID] = nil
        }
    }

    func saveAll() {
        for scroll in pages.values { (scroll.documentView as? StickyNoteTextView)?.saveNow() }
    }

    private func makePage(_ textView: StickyNoteTextView, bottomInset: CGFloat) -> StickyNoteScrollView {
        let scroll = StickyNoteScrollView(frame: bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(origin: .zero, size: NSSize(width: scroll.contentSize.width, height: 0))
        scroll.documentView = textView
        scroll.isHidden = true
        addSubview(scroll)
        return scroll
    }
}

/// Keeps the note at least as tall as what shows of it, so the ruled lines reach the bottom
/// and a click below the last line still lands in the note.
final class StickyNoteScrollView: NSScrollView {
    /// Always overlay: with a mouse connected, AppKit switches to legacy scrollers, whose
    /// opaque track would cover the side of the note.
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    override func tile() {
        super.tile()
        guard let textView = documentView as? NSTextView else { return }
        // A note made for a tab while the fence is already showing never gets the resize
        // that would widen it from nothing.
        let width = contentView.bounds.width
        if textView.frame.width != width {
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        }
        let height = max(contentView.bounds.height - contentInsets.top - contentInsets.bottom, 0)
        if textView.minSize.height != height {
            textView.minSize = NSSize(width: 0, height: height)
            textView.sizeToFit()
        }
    }
}

/// The note's text view. The text is the note exactly as saved, checklist markers and all;
/// each marker is drawn invisible, as wide as a box, and a box is drawn over it.
final class StickyNoteTextView: NSTextView, NSTextViewDelegate {
    private(set) var look: StickyNoteLook
    /// The tab whose note this is.
    var tabID: UUID?
    var onSave: (String) -> Void = { _ in }
    private var saveWork: DispatchWorkItem?
    /// Its own, rather than the window's, so undo never reaches into another tab's note.
    private let undo = UndoManager()

    /// Typing that hasn't been saved yet, which a newer note from the store mustn't replace.
    var hasUnsavedChanges: Bool { saveWork != nil }

    init(look: StickyNoteLook) {
        self.look = look
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 4
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFontPanel = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        drawsBackground = false
        focusRingType = .none
        textContainerInset = NSSize(width: 8, height: 6)
        insertionPointColor = look.text
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Saving

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        onSave(string)
    }

    /// Shows a note that changed in the store, unless there's typing still to save.
    func show(_ note: String) {
        guard !hasUnsavedChanges, note != string else { return }
        string = note
        // Its undo steps were for the text just replaced.
        undo.removeAllActions()
        restyle()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { saveNow() }
        return resigned
    }

    // MARK: Styling

    func apply(_ look: StickyNoteLook) {
        guard look != self.look else { return }
        self.look = look
        insertionPointColor = look.text
        restyle()
    }

    private func paragraph(indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = look.lineHeight
        style.maximumLineHeight = look.lineHeight
        style.headIndent = indent
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// Lifts the text off the line below it. Lines taller than the font get their extra
    /// room above the text.
    private var baselineOffset: CGFloat {
        let font = look.font
        let natural = font.ascender - font.descender + font.leading
        return max(0, (look.lineHeight - natural) * 0.3).rounded()
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: look.font,
            .foregroundColor: look.text,
            .paragraphStyle: paragraph(indent: 0),
            .baselineOffset: baselineOffset,
        ]
        if let color = look.shadow {
            let shadow = NSShadow()
            shadow.shadowColor = color
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            attributes[.shadow] = shadow
        }
        return attributes
    }

    /// Hides checklist markers in the room of a box, indents wrapped item lines past the box
    /// and strikes out done items. Attributes aren't part of the note, so this isn't undoable.
    func restyle() {
        guard let storage = textStorage else { return }
        let text = storage.string as NSString
        let base = baseAttributes
        let item = paragraph(indent: look.markerWidth)
        storage.beginEditing()
        storage.setAttributes(base, range: NSRange(location: 0, length: text.length))
        for line in NoteEditing.lineRanges(in: text) {
            guard let marker = NoteEditing.markerRange(in: text, line: line) else { continue }
            let natural = (text.substring(with: marker) as NSString).size(withAttributes: [.font: look.font]).width
            storage.addAttributes([
                .foregroundColor: NSColor.clear,
                .kern: (look.markerWidth - natural) / CGFloat(marker.length),
            ], range: marker)
            storage.removeAttribute(.shadow, range: marker)
            storage.addAttribute(.paragraphStyle, value: item, range: line)
            if NoteEditing.isChecked(in: text, line: line) {
                let content = NSRange(location: NSMaxRange(marker), length: NSMaxRange(line) - NSMaxRange(marker))
                storage.addAttributes([
                    .foregroundColor: look.done,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: look.done,
                ], range: content)
            }
        }
        storage.endEditing()
        typingAttributes = base
        needsDisplay = true
    }

    // MARK: Drawing

    struct Checkbox {
        let lineStart: Int
        let checked: Bool
        let rect: CGRect
    }

    /// Each checklist item's box, in view coordinates, centered on its text's capitals.
    func checkboxes() -> [Checkbox] {
        guard let layoutManager else { return [] }
        let text = string as NSString
        let origin = textContainerOrigin
        let size = look.boxSize
        let capHeight = look.font.capHeight
        return NoteEditing.lineRanges(in: text).compactMap { line in
            guard let marker = NoteEditing.markerRange(in: text, line: line) else { return nil }
            let glyph = layoutManager.glyphIndexForCharacter(at: marker.location)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = layoutManager.location(forGlyphAt: glyph)
            let middle = origin.y + fragment.minY + location.y - capHeight / 2
            let rect = CGRect(x: origin.x + fragment.minX + location.x, y: (middle - size / 2).rounded(), width: size, height: size)
            return Checkbox(lineStart: line.location, checked: NoteEditing.isChecked(in: text, line: line), rect: rect)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let rule = look.rule {
            rule.setFill()
            let inset: CGFloat = 8
            var y = textContainerOrigin.y + look.lineHeight
            while y <= bounds.maxY {
                if y >= dirtyRect.minY, y - 1 <= dirtyRect.maxY {
                    CGRect(x: inset, y: y - 1, width: bounds.width - inset * 2, height: 1).fill(using: .sourceOver)
                }
                y += look.lineHeight
            }
        }
        super.draw(dirtyRect)
        for box in checkboxes() where box.rect.insetBy(dx: -2, dy: -2).intersects(dirtyRect) {
            drawCheckbox(box.rect, checked: box.checked)
        }
    }

    private func drawCheckbox(_ rect: CGRect, checked: Bool) {
        let radius = rect.width * 0.24
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
        if let fill = look.boxFill {
            fill.setFill()
            box.fill()
        }
        (checked ? look.text : look.secondary).setStroke()
        box.lineWidth = 1.4
        box.stroke()
        guard checked else { return }
        let check = NSBezierPath()
        check.move(to: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.52))
        check.line(to: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.71))
        check.line(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.29))
        check.lineWidth = max(1.6, rect.width * 0.13)
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        look.text.setStroke()
        check.stroke()
    }

    // MARK: Clicks and keys

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Text and links dropped on the note go in as text; files and fence items don't.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func mouseDown(with event: NSEvent) {
        // Clutter Buster sits in the background; typing needs it active and this window key.
        if let window, !window.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
        }
        let point = convert(event.locationInWindow, from: nil)
        if let box = checkboxes().first(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(point) }) {
            window?.makeFirstResponder(self)
            if let edit = NoteEditing.toggleCheckEdit(in: string as NSString, lineStart: box.lineStart) {
                apply(edit, actionName: box.checked ? "Untick" : "Tick")
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if window?.firstResponder === self, modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "l" {
            toggleChecklist()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Makes the current line, or every selected line, a checklist item, or plain again.
    func toggleChecklist() {
        apply(NoteEditing.toggleChecklistEdit(in: string as NSString, selection: selectedRange()), actionName: "Checklist")
    }

    /// Makes an edit the way typing does, so it can be undone.
    func apply(_ edit: NoteEdit, actionName: String? = nil) {
        guard let textStorage else { return }
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: typingAttributes))
        didChangeText()
        if let actionName { undoManager?.setActionName(actionName) }
        breakUndoCoalescing()
        if let selection = edit.selection { setSelectedRange(selection) }
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textDidChange(_ notification: Notification) {
        restyle()
        scheduleSave()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let text = string as NSString
        let edit: NoteEdit? = switch selector {
        case #selector(insertNewline(_:)): NoteEditing.returnEdit(in: text, selection: selectedRange())
        case #selector(deleteBackward(_:)): NoteEditing.deleteBackwardEdit(in: text, selection: selectedRange())
        case #selector(deleteForward(_:)): NoteEditing.deleteForwardEdit(in: text, selection: selectedRange())
        default: nil
        }
        guard let edit else { return false }
        apply(edit, actionName: selector == #selector(insertNewline(_:)) ? "Typing" : "Delete")
        return true
    }

    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRanges old: [NSValue], toCharacterRanges new: [NSValue]) -> [NSValue] {
        guard new.count == 1, new[0].rangeValue.length == 0 else { return new }
        let previous = old.count == 1 && old[0].rangeValue.length == 0 ? old[0].rangeValue.location : nil
        let location = NoteEditing.allowedCaret(new[0].rangeValue.location, from: previous, in: string as NSString)
        return [NSValue(range: NSRange(location: location, length: 0))]
    }

    /// New text never takes on a hidden marker's color or spacing.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes old: [String: Any], toAttributes new: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        baseAttributes
    }

    /// Line breaks from elsewhere become "\n", the only kind checklist lines are split on.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard let text, text.utf16.contains(13) else { return true }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        apply(NoteEdit(range: range, replacement: normalized, selection: NSRange(location: range.location + (normalized as NSString).length, length: 0)))
        return false
    }
}

// MARK: - Sticky note fences

extension FenceCoordinator {
    static func defaultTitle(for style: FenceStyle) -> String {
        style == .stickyNote ? "Sticky Note" : "New Fence"
    }

    func stickyTextView(_ id: UUID) -> StickyNoteTextView? {
        stickyTextViews.object(forKey: id as NSUUID)
    }

    func setStickyNote(_ id: UUID, tab tabID: UUID, _ text: String) {
        guard let fence = store.fence(id), fence.isStickyNote, fence.tabs.contains(where: { $0.id == tabID }),
              fence.note(in: tabID) != text else { return }
        store.update(id) { $0.setNote(text, in: tabID) }
    }

    /// Saves typing not yet saved in every note, as when quitting.
    func saveStickyNotes() {
        for case let textView as StickyNoteTextView in stickyTextViews.objectEnumerator()?.allObjects ?? [] {
            textView.saveNow()
        }
    }

    /// Nil draws the note in the fence's theme.
    func setPaper(_ id: UUID, _ paper: PaperColor?) {
        guard let fence = store.fence(id), fence.isStickyNote, fence.paper != paper else { return }
        store.update(id) { $0.paper = paper }
        Log.write("sticky note: \"\(fence.title)\" paper set to \(paper?.name ?? "the theme")")
    }

    /// Nil makes the tab use the fence's paper.
    func setTabPaper(_ id: UUID, _ tabID: UUID, _ paper: TabPaper?) {
        guard let fence = store.fence(id), fence.isStickyNote,
              let index = fence.tabs.firstIndex(where: { $0.id == tabID }), fence.tabs[index].paper != paper else { return }
        store.update(id) { $0.tabs[index].paper = paper }
        let name = switch paper {
        case nil: "the fence's"
        case .color(let color): color.name
        case .theme: "the theme"
        }
        Log.write("sticky note: tab \"\(fence.tabs[index].name)\" of \"\(fence.title)\" paper set to \(name)")
    }

    /// Switches a fence between items and a note, as the setup card does. A fence holding
    /// items keeps them. A default title follows the style.
    func setStyle(_ id: UUID, _ style: FenceStyle) {
        guard let fence = store.fence(id), fence.style != style else { return }
        if style == .stickyNote, !fence.items.isEmpty {
            Log.write("sticky note: \"\(fence.title)\" holds \(fence.items.count) item(s), so it stays a fence of files")
            NSSound.beep()
            return
        }
        store.update(id) { fence in
            if fence.title == Self.defaultTitle(for: fence.style) { fence.title = Self.defaultTitle(for: style) }
            fence.changeStyle(to: style)
            if style == .stickyNote, fence.paper == nil { fence.paper = .yellow }
        }
        Log.write("fence \(id) is now \(style == .stickyNote ? "a sticky note" : "a fence of files")")
        fitToContent(id)
    }

    /// Raises the fence and puts the caret in a tab's note (the selected tab's by default),
    /// selecting `range` if given.
    func focusStickyNote(_ id: UUID, tab tabID: UUID? = nil, select range: NSRange? = nil) {
        guard let fence = store.fence(id), fence.isStickyNote else { return }
        setFencesHidden(false)
        if fence.isCollapsed { toggleCollapse(id) }
        if let tabID, fence.tabs.contains(where: { $0.id == tabID }) { selectTab(id, tabID) }
        let wanted = store.fence(id)?.currentTab.id
        raise(id)
        focus(id)
        whenStickyNoteShows(id, tab: wanted) { textView in
            guard let window = textView.window else { return }
            window.makeKey()
            window.makeFirstResponder(textView)
            guard let range else { return }
            let length = (textView.string as NSString).length
            let start = min(range.location, length)
            let selection = NSRange(location: start, length: min(range.length, length - start))
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(selection)
            if selection.length > 0 { textView.showFindIndicator(for: selection) }
        }
    }

    /// Runs `action` once the fence shows the note of `tabID`: an expanded fence or a newly
    /// selected tab makes it on a coming update.
    private func whenStickyNoteShows(_ id: UUID, tab tabID: UUID?, tries: Int = 20, _ action: @escaping (StickyNoteTextView) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let textView = self.stickyTextView(id), tabID == nil || textView.tabID == tabID, textView.window != nil {
                    action(textView)
                } else if tries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                        MainActor.assumeIsolated { self.whenStickyNoteShows(id, tab: tabID, tries: tries - 1, action) }
                    }
                } else {
                    Log.write("sticky note: fence \(id) didn't show the note of tab \(tabID?.uuidString ?? "?")")
                }
            }
        }
    }

    /// The checklist button: toggles the line the caret is on, or the selected lines.
    func toggleChecklist(_ id: UUID) {
        guard let textView = stickyTextView(id), let window = textView.window else { return }
        focus(id)
        window.makeFirstResponder(textView)
        textView.toggleChecklist()
    }

    /// Pastes clipboard text at the end of the note, for Command-V while it isn't being typed in.
    func pasteIntoStickyNote(_ id: UUID, from pasteboard: NSPasteboard) -> Bool {
        guard pasteboard.string(forType: .string) != nil, let textView = stickyTextView(id), let window = textView.window else { return false }
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.paste(nil)
        return true
    }
}

/// A small sheet of a note's paper with lines on it, for search results.
enum StickyNoteIcon {
    static func image(paper: PaperColor?, size: CGFloat = 26) -> NSImage {
        let fill = NSColor(paper?.bottom ?? Color(hex: 0xE8E4F0))
        let band = NSColor(paper?.title.first ?? Color(hex: 0xC9C2DA))
        let ink = NSColor(PaperColor.ink).withAlphaComponent(0.45)
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let sheet = rect.insetBy(dx: size * 0.12, dy: size * 0.08)
            let shape = NSBezierPath(roundedRect: sheet, xRadius: size * 0.1, yRadius: size * 0.1)
            fill.setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            band.setFill()
            CGRect(x: sheet.minX, y: sheet.minY, width: sheet.width, height: sheet.height * 0.22).fill()
            NSGraphicsContext.restoreGraphicsState()
            ink.setFill()
            for row in 0..<3 {
                let y = sheet.minY + sheet.height * (0.42 + CGFloat(row) * 0.18)
                CGRect(x: sheet.minX + sheet.width * 0.16, y: y, width: sheet.width * (row == 2 ? 0.45 : 0.68), height: max(1, size * 0.05)).fill()
            }
            NSColor.black.withAlphaComponent(0.18).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            return true
        }
    }
}
