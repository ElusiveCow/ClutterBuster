import AppKit

// Phase 0 spike: cover one desktop icon with a desktop-level window and check
// that it stays hidden through Finder restarts and display changes.
//
// Usage:
//   swift run CoverSpike --list
//   swift run CoverSpike --name "Some File.pdf" [--debug]

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ message: String) {
    let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(time)] \(message)")
}

struct DesktopItem {
    let name: String
    /// Finder coordinates: points, origin at the top-left of the main display.
    let position: CGPoint

    var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(name)
    }
}

enum Finder {
    static func desktopItems() -> [DesktopItem]? {
        let source = """
        tell application "Finder"
            set names to name of every item of desktop
            set positions to desktop position of every item of desktop
        end tell
        set out to ""
        repeat with i from 1 to count of names
            set p to item i of positions
            set out to out & (item i of names) & tab & (item 1 of p) & tab & (item 2 of p) & linefeed
        end repeat
        return out
        """
        guard let text = run(source) else { return nil }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]) else { return nil }
            return DesktopItem(name: String(parts[0]), position: CGPoint(x: x, y: y))
        }
    }

    static func position(of name: String) -> CGPoint? {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            set p to desktop position of item "\(escaped)" of desktop
            return ((item 1 of p) as text) & tab & ((item 2 of p) as text)
        end tell
        """
        guard let text = run(source) else { return nil }
        let parts = text.split(separator: "\t")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    static var iconSize: CGFloat { viewSetting("iconSize") ?? 64 }
    static var textSize: CGFloat { viewSetting("textSize") ?? 12 }

    private static func viewSetting(_ key: String) -> CGFloat? {
        let settings = CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, "com.apple.finder" as CFString) as? [String: Any]
        let icon = settings?["IconViewSettings"] as? [String: Any]
        return (icon?[key] as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            log("Finder query failed: \(error[NSAppleScript.errorMessage] ?? error)")
            return nil
        }
        return result?.stringValue
    }
}

/// Converts a Finder desktop position (assumed to be the icon's center) into the
/// screen rect that covers the icon and its label.
func coverFrame(for position: CGPoint) -> NSRect {
    let icon = Finder.iconSize
    let text = Finder.textSize
    let width = max(icon + 44, 110)
    let height = icon + 12 + text * 2.8 + 8
    let top = position.y - icon / 2 - 8
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: position.x - width / 2, y: mainHeight - (top + height), width: width, height: height)
}

final class CoverView: NSView {
    let item: DesktopItem
    var debug: Bool { didSet { needsDisplay = true } }
    var showPlaceholder = false { didSet { needsDisplay = true } }
    var onUserMoved: () -> Void = {}

    private var mouseStart: NSPoint = .zero
    private var originStart: NSPoint = .zero
    private var dragged = false

    init(item: DesktopItem, debug: Bool) {
        self.item = item
        self.debug = debug
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        if debug {
            NSColor.systemRed.withAlphaComponent(0.3).setFill()
            shape.fill()
            NSColor.systemRed.setStroke()
            shape.lineWidth = 2
            shape.stroke()
            return
        }
        guard showPlaceholder else {
            NSColor.systemTeal.setFill()
            shape.fill()
            return
        }
        NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.24, alpha: 1).setFill()
        shape.fill()

        let iconSide = min(bounds.width, bounds.height) * 0.45
        let iconRect = NSRect(x: bounds.midX - iconSide / 2, y: bounds.maxY - iconSide - 10, width: iconSide, height: iconSide)
        NSWorkspace.shared.icon(forFile: item.url.path).draw(in: iconRect)

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]
        ("Covered\n" + item.name as NSString).draw(
            in: NSRect(x: 4, y: 4, width: bounds.width - 8, height: iconRect.minY - 6),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        mouseStart = NSEvent.mouseLocation
        originStart = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let dx = now.x - mouseStart.x
        let dy = now.y - mouseStart.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        window?.setFrameOrigin(NSPoint(x: originStart.x + dx, y: originStart.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragged {
            onUserMoved()
            log("Cover dragged by user to \(window.map { NSStringFromRect($0.frame) } ?? "?")")
        } else {
            log("Cover clicked, opening \(item.url.path)")
            NSWorkspace.shared.open(item.url)
        }
    }
}

final class SpikeController: NSObject {
    let item: DesktopItem
    let window: NSWindow
    let view: CoverView
    private var statusItem: NSStatusItem?
    private var lastPosition: CGPoint
    private var userMoved = false
    private var timer: Timer?

    init(item: DesktopItem, debug: Bool) {
        self.item = item
        self.lastPosition = item.position
        view = CoverView(item: item, debug: debug)
        window = NSWindow(contentRect: coverFrame(for: item.position), styleMask: .borderless, backing: .buffered, defer: false)
        super.init()

        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = view
        view.onUserMoved = { [weak self] in self?.userMoved = true }
    }

    func start() {
        window.orderFrontRegardless()
        log("Covering \"\(item.name)\" at Finder position \(item.position), window frame \(NSStringFromRect(window.frame))")
        log("Window level \(window.level.rawValue) (desktop icons are \(CGWindowLevelForKey(.desktopIconWindow)), normal windows are 0)")

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }

        buildStatusMenu()
    }

    @objc private func appLaunched(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == "com.apple.finder" else { return }
        log("Finder relaunched, re-reading icon position in 2s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.reposition(reason: "Finder relaunch") }
    }

    @objc private func screensChanged() {
        log("Screen parameters changed: \(NSScreen.screens.map { NSStringFromRect($0.frame) })")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.reposition(reason: "screen change") }
    }

    private func poll() {
        guard let position = Finder.position(of: item.name) else { return }
        if position != lastPosition {
            log("Finder reports the icon moved: \(lastPosition) -> \(position)")
            reposition(reason: "icon moved", position: position)
        }
    }

    @objc private func resetToIcon() {
        userMoved = false
        reposition(reason: "manual reset")
    }

    @objc private func toggleDebug() {
        view.debug.toggle()
        log("Debug overlay \(view.debug ? "on" : "off")")
    }

    @objc private func togglePlaceholder() {
        view.showPlaceholder.toggle()
        log("Placeholder icon \(view.showPlaceholder ? "on" : "off")")
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func reposition(reason: String, position: CGPoint? = nil) {
        guard let position = position ?? Finder.position(of: item.name) else {
            log("Could not read icon position after \(reason)")
            return
        }
        lastPosition = position
        window.orderFrontRegardless()
        if userMoved {
            log("\(reason): icon at \(position); cover left where the user dragged it")
            return
        }
        window.setFrame(coverFrame(for: position), display: true)
        log("\(reason): cover moved to \(NSStringFromRect(window.frame))")
    }

    private func buildStatusMenu() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "CB"
        let menu = NSMenu()
        menu.addItem(withTitle: "Clutter Buster spike: \(item.name)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Snap cover back onto icon", action: #selector(resetToIcon), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Toggle debug overlay", action: #selector(toggleDebug), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "Toggle placeholder icon", action: #selector(togglePlaceholder), keyEquivalent: "p").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        self.statusItem = statusItem
    }
}

let arguments = CommandLine.arguments
let debug = arguments.contains("--debug")
let requestedName = arguments.firstIndex(of: "--name").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }

guard let items = Finder.desktopItems(), !items.isEmpty else {
    log("No desktop items found (is Finder showing desktop icons, and is Automation access allowed?)")
    exit(1)
}

if arguments.contains("--list") {
    for item in items { print("\(item.name)\t\(Int(item.position.x)),\(Int(item.position.y))") }
    exit(0)
}

guard let target = requestedName.map({ name in items.first { $0.name == name } }) ?? items.first else {
    log("No desktop item named \"\(requestedName ?? "")\". Run with --list to see names.")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = SpikeController(item: target, debug: debug)
controller.start()
app.run()
