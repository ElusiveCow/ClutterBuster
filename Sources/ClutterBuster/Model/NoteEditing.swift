import Foundation

/// A change to a sticky note's text: `range` is replaced with `replacement`, then `selection`
/// is selected.
struct NoteEdit: Equatable {
    var range: NSRange
    var replacement: String
    /// Nil leaves the selection to the text view.
    var selection: NSRange?
}

/// Checklist editing for sticky notes. Works on the note's text with UTF-16 ranges, as
/// NSTextView does, and on "\n" line breaks only, as `NoteLine` does.
enum NoteEditing {
    private static let newline = unichar(10)

    /// The line holding `location`, without its line break.
    static func lineRange(in text: NSString, at location: Int) -> NSRange {
        let location = min(max(location, 0), text.length)
        var start = location
        while start > 0, text.character(at: start - 1) != newline { start -= 1 }
        var end = location
        while end < text.length, text.character(at: end) != newline { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Every line, without line breaks. Empty text is one empty line.
    static func lineRanges(in text: NSString) -> [NSRange] {
        var lines: [NSRange] = []
        var start = 0
        for index in 0..<text.length where text.character(at: index) == newline {
            lines.append(NSRange(location: start, length: index - start))
            start = index + 1
        }
        lines.append(NSRange(location: start, length: text.length - start))
        return lines
    }

    /// The "- [ ] " or "- [x] " starting a checklist line, or nil for a plain line.
    static func markerRange(in text: NSString, line: NSRange) -> NSRange? {
        guard line.length >= NoteLine.markerLength else { return nil }
        let marker = NSRange(location: line.location, length: NoteLine.markerLength)
        guard case .item = NoteLine(Substring(text.substring(with: marker))) else { return nil }
        return marker
    }

    static func isChecked(in text: NSString, line: NSRange) -> Bool {
        guard let marker = markerRange(in: text, line: line) else { return false }
        return text.substring(with: marker) != NoteLine.uncheckedMarker
    }

    // MARK: Return and delete

    /// Return on a checklist item with text starts a new item; on an empty item it removes the
    /// box and ends the list. Nil lets Return do what it always does.
    static func returnEdit(in text: NSString, selection: NSRange) -> NoteEdit? {
        let line = lineRange(in: text, at: selection.location)
        guard NSMaxRange(selection) <= NSMaxRange(line), let marker = markerRange(in: text, line: line),
              selection.location >= NSMaxRange(marker) else { return nil }
        let content = text.substring(with: NSRange(location: NSMaxRange(marker), length: NSMaxRange(line) - NSMaxRange(marker)))
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            return NoteEdit(range: line, replacement: "", selection: NSRange(location: line.location, length: 0))
        }
        let insert = "\n" + NoteLine.uncheckedMarker
        return NoteEdit(range: selection, replacement: insert, selection: NSRange(location: selection.location + (insert as NSString).length, length: 0))
    }

    /// Delete just after an item's box removes the box, leaving its text as a plain line.
    static func deleteBackwardEdit(in text: NSString, selection: NSRange) -> NoteEdit? {
        guard selection.length == 0 else { return nil }
        let line = lineRange(in: text, at: selection.location)
        guard let marker = markerRange(in: text, line: line), selection.location == NSMaxRange(marker) else { return nil }
        return NoteEdit(range: marker, replacement: "", selection: NSRange(location: line.location, length: 0))
    }

    /// Forward delete at the end of a line joins the next one; an item's box goes with its
    /// line break rather than showing as text.
    static func deleteForwardEdit(in text: NSString, selection: NSRange) -> NoteEdit? {
        guard selection.length == 0 else { return nil }
        let line = lineRange(in: text, at: selection.location)
        guard selection.location == NSMaxRange(line), NSMaxRange(line) < text.length else { return nil }
        let next = lineRange(in: text, at: NSMaxRange(line) + 1)
        guard let marker = markerRange(in: text, line: next) else { return nil }
        return NoteEdit(
            range: NSRange(location: NSMaxRange(line), length: NSMaxRange(marker) - NSMaxRange(line)),
            replacement: "", selection: NSRange(location: NSMaxRange(line), length: 0)
        )
    }

    // MARK: Checklists

    /// Makes the selected lines checklist items, or plain lines again when they all are.
    /// Blank lines in a selection of several are left alone.
    static func toggleChecklistEdit(in text: NSString, selection: NSRange) -> NoteEdit {
        let lines = linesCovered(by: selection, in: text)
        let nonBlank = lines.filter { !text.substring(with: $0).trimmingCharacters(in: .whitespaces).isEmpty }
        let targets = lines.count == 1 || nonBlank.isEmpty ? lines : nonBlank
        let removing = targets.allSatisfy { markerRange(in: text, line: $0) != nil }

        var changes: [(start: Int, adds: Bool)] = []
        var pieces: [String] = []
        for line in lines {
            let content = text.substring(with: line)
            if removing, markerRange(in: text, line: line) != nil {
                pieces.append((content as NSString).substring(from: NoteLine.markerLength))
                changes.append((line.location, false))
            } else if !removing, targets.contains(line), markerRange(in: text, line: line) == nil {
                pieces.append(NoteLine.uncheckedMarker + content)
                changes.append((line.location, true))
            } else {
                pieces.append(content)
            }
        }
        let block = NSRange(location: lines[0].location, length: NSMaxRange(lines[lines.count - 1]) - lines[0].location)

        func map(_ position: Int) -> Int {
            var shift = 0
            for change in changes {
                if change.adds {
                    if position >= change.start { shift += NoteLine.markerLength }
                } else if position >= change.start + NoteLine.markerLength {
                    shift -= NoteLine.markerLength
                } else if position > change.start {
                    shift -= position - change.start
                }
            }
            return position + shift
        }
        let start = map(selection.location)
        let end = map(NSMaxRange(selection))
        return NoteEdit(range: block, replacement: pieces.joined(separator: "\n"), selection: NSRange(location: start, length: max(end - start, 0)))
    }

    /// Ticks or unticks the item on the line starting at `lineStart`.
    static func toggleCheckEdit(in text: NSString, lineStart: Int) -> NoteEdit? {
        let line = lineRange(in: text, at: lineStart)
        guard line.location == lineStart, markerRange(in: text, line: line) != nil else { return nil }
        return NoteEdit(range: NSRange(location: lineStart + 3, length: 1), replacement: isChecked(in: text, line: line) ? " " : "x", selection: nil)
    }

    /// The lines a selection touches. One ending at the very start of a line leaves that line
    /// out, as when whole lines are selected by dragging down to the next.
    static func linesCovered(by selection: NSRange, in text: NSString) -> [NSRange] {
        let first = lineRange(in: text, at: selection.location)
        var end = NSMaxRange(selection)
        if selection.length > 0, end > first.location, end <= text.length, text.character(at: end - 1) == newline { end -= 1 }
        var lines = [first]
        while NSMaxRange(lines[lines.count - 1]) < min(end, text.length) {
            lines.append(lineRange(in: text, at: NSMaxRange(lines[lines.count - 1]) + 1))
        }
        return lines
    }

    // MARK: The caret

    /// Where a caret may go: never inside an item's marker or before its box, which go to
    /// the start of its text. Going back from there goes to the end of the line above.
    static func allowedCaret(_ location: Int, from previous: Int?, in text: NSString) -> Int {
        let line = lineRange(in: text, at: location)
        guard let marker = markerRange(in: text, line: line), location < NSMaxRange(marker) else { return location }
        if previous == NSMaxRange(marker), line.location > 0 { return line.location - 1 }
        return NSMaxRange(marker)
    }
}
