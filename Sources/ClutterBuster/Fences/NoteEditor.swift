import AppKit

/// The popover a note is edited in. Its text is saved a moment after typing stops and when
/// the popover closes.
final class NoteEditorController: NSViewController, NSTextViewDelegate {
    let itemID: UUID
    let fenceID: UUID
    /// Set for a note made from the Add menu; left empty, it's removed again on close.
    let isNew: Bool
    private let initialText: String
    private let onSave: (String) -> Void
    private var textView: NSTextView?
    private var saveWork: DispatchWorkItem?

    init(itemID: UUID, fenceID: UUID, text: String, isNew: Bool, onSave: @escaping (String) -> Void) {
        self.itemID = itemID
        self.fenceID = fenceID
        self.isNew = isNew
        initialText = text
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var text: String { textView?.string ?? initialText }

    override func loadView() {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = CGRect(x: 0, y: 0, width: 300, height: 220)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        if let textView = scroll.documentView as? NSTextView {
            textView.string = initialText
            textView.font = .systemFont(ofSize: 14)
            textView.textColor = NSColor(white: 0.12, alpha: 1)
            textView.insertionPointColor = NSColor(white: 0.12, alpha: 1)
            textView.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.7, alpha: 1)
            textView.drawsBackground = true
            textView.isRichText = false
            textView.allowsUndo = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.textContainerInset = CGSize(width: 8, height: 10)
            textView.delegate = self
            self.textView = textView
        }
        view = scroll
        preferredContentSize = scroll.frame.size
    }

    /// Puts the cursor at the end of the text, ready to type.
    func focus() {
        guard let textView else { return }
        view.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    func textDidChange(_ notification: Notification) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func save() {
        saveWork?.cancel()
        saveWork = nil
        onSave(text)
    }
}
