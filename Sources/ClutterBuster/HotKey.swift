import AppKit
import Carbon.HIToolbox

/// A key and its modifiers, as Carbon's hot key API takes them.
struct KeyShortcut: Equatable, Hashable {
    /// A virtual key code, like `kVK_Space`.
    let keyCode: UInt32
    /// Carbon modifier flags: `controlKey`, `optionKey`, `shiftKey` and `cmdKey`.
    let modifiers: UInt32

    static let modifierMask = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    static let controlSpace = KeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey))
    static let escape = KeyShortcut(keyCode: UInt32(kVK_Escape), modifiers: 0)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    /// "⌃Space", with the modifiers in the order macOS menus use: ⌃⌥⇧⌘.
    var displayName: String { Self.symbols(for: modifiers) + Self.keyName(keyCode) }

    /// Why this can't be a global shortcut, or nil if it can. A function key works alone;
    /// anything else needs ⌃, ⌥ or ⌘, so typing never sets it off.
    var problem: String? {
        guard !Self.functionKeys.keys.contains(keyCode) else { return nil }
        guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
            return "Include \u{2303} Control, \u{2325} Option or \u{2318} Command, or use a function key."
        }
        return nil
    }

    static func symbols(for modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "\u{2303}" }
        if modifiers & UInt32(optionKey) != 0 { text += "\u{2325}" }
        if modifiers & UInt32(shiftKey) != 0 { text += "\u{21E7}" }
        if modifiers & UInt32(cmdKey) != 0 { text += "\u{2318}" }
        return text
    }

    /// The key's name: a word or symbol for keys that don't type anything, else what it types
    /// with the current keyboard layout, falling back to a US keyboard's.
    static func keyName(_ keyCode: UInt32, usingLayout: Bool = true) -> String {
        if let name = specialKeys[keyCode] ?? functionKeys[keyCode] { return name }
        if usingLayout, let typed = typedCharacter(keyCode) { return typed }
        return usKeys[keyCode] ?? "Key \(keyCode)"
    }

    private static let functionKeys: [UInt32: String] = {
        let codes = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        return Dictionary(uniqueKeysWithValues: codes.enumerated().map { (UInt32($0.element), "F\($0.offset + 1)") })
    }()

    private static let specialKeys: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "\u{21A9}", UInt32(kVK_ANSI_KeypadEnter): "\u{2324}",
        UInt32(kVK_Tab): "\u{21E5}", UInt32(kVK_Delete): "\u{232B}", UInt32(kVK_ForwardDelete): "\u{2326}",
        UInt32(kVK_Escape): "\u{238B}", UInt32(kVK_LeftArrow): "\u{2190}", UInt32(kVK_RightArrow): "\u{2192}",
        UInt32(kVK_UpArrow): "\u{2191}", UInt32(kVK_DownArrow): "\u{2193}", UInt32(kVK_Home): "\u{2196}",
        UInt32(kVK_End): "\u{2198}", UInt32(kVK_PageUp): "\u{21DE}", UInt32(kVK_PageDown): "\u{21DF}",
        UInt32(kVK_Help): "Help",
    ]

    private static let usKeys: [UInt32: String] = {
        let pairs: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"),
            (kVK_ANSI_9, "9"), (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
            (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Semicolon, ";"),
            (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"),
            (kVK_ANSI_Grave, "`"),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { (UInt32($0.0), $0.1) })
    }()

    private static func typedCharacter(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text.uppercased()
    }
}

/// A global shortcut registered with Carbon, which needs no Accessibility permission. It
/// works whichever app is in front, until `unregister`.
@MainActor
final class HotKey {
    let shortcut: KeyShortcut
    /// What `RegisterEventHotKey` returned: `noErr`, or why it failed.
    let status: OSStatus
    private var ref: EventHotKeyRef?
    private let id: UInt32

    private static let signature: OSType = 0x4342_706B // "CBpk"
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    init(_ shortcut: KeyShortcut, onPress: @escaping () -> Void) {
        self.shortcut = shortcut
        id = Self.nextID
        Self.nextID += 1
        Self.installEventHandler()
        var ref: EventHotKeyRef?
        status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref {
            self.ref = ref
            Self.handlers[id] = onPress
        }
    }

    var isRegistered: Bool { ref != nil }

    func unregister() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
        Self.handlers[id] = nil
    }

    private static func installEventHandler() {
        guard eventHandler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == HotKey.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            // Not from inside Carbon's dispatch, which a peek's window changes could re-enter.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.handlers[id]?() }
            }
            return noErr
        }, 1, &pressed, nil, &eventHandler)
    }
}

/// The macOS keyboard shortcuts in System Settings › Keyboard › Keyboard Shortcuts, which get
/// keys before any app's global shortcut does.
enum SystemShortcuts {
    struct Entry: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        var enabled: Bool
    }

    /// What macOS uses `shortcut` for, said so it fits "… is used by macOS to …", or nil if
    /// it's free. The input source shortcuts only take the key with more than one input source.
    static func conflict(for shortcut: KeyShortcut, entries: [Entry], inputSources: Int) -> String? {
        guard entries.contains(where: {
            $0.enabled && $0.keyCode == shortcut.keyCode && $0.modifiers & KeyShortcut.modifierMask == shortcut.modifiers
        }) else { return nil }
        let space = UInt32(kVK_Space)
        switch (shortcut.keyCode, shortcut.modifiers) {
        case (space, UInt32(controlKey)):
            return inputSources > 1 ? "select the previous input source" : nil
        case (space, UInt32(controlKey | optionKey)):
            return inputSources > 1 ? "select the next input source" : nil
        case (space, UInt32(cmdKey)): return "open Spotlight"
        case (space, UInt32(controlKey | cmdKey)): return "show the emoji and symbols viewer"
        default: return "run one of its keyboard shortcuts"
        }
    }

    static func conflict(for shortcut: KeyShortcut) -> String? {
        conflict(for: shortcut, entries: currentEntries(), inputSources: inputSourceCount())
    }

    private static func currentEntries() -> [Entry] {
        var hotKeys: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&hotKeys) == noErr,
              let array = hotKeys?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return array.compactMap { entry in
            guard let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int else { return nil }
            let enabled = entry[kHISymbolicHotKeyEnabled as String] as? Bool ?? false
            return Entry(keyCode: UInt32(truncatingIfNeeded: code), modifiers: UInt32(truncatingIfNeeded: modifiers), enabled: enabled)
        }
    }

    /// Keyboard layouts and input methods that the input source shortcuts switch between.
    private static func inputSourceCount() -> Int {
        let filter = [
            kTISPropertyInputSourceIsSelectCapable as String: true,
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
        ] as CFDictionary
        return (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.count ?? 1
    }
}

extension AppSettings {
    static let peekKeyCodeKey = "peekKeyCode"
    static let peekModifiersKey = "peekModifiers"
    /// Saved as the key code when the shortcut is cleared.
    static let noKeyCode = -1

    /// The Peek at Fences shortcut: Control-Space until it's changed, nil once it's cleared.
    static func peekShortcut(in defaults: UserDefaults = .standard) -> KeyShortcut? {
        guard let code = defaults.object(forKey: peekKeyCodeKey) as? Int else { return .controlSpace }
        guard code != noKeyCode, let keyCode = UInt32(exactly: code) else { return nil }
        let modifiers = UInt32(truncatingIfNeeded: defaults.integer(forKey: peekModifiersKey))
        return KeyShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    static func setPeekShortcut(_ shortcut: KeyShortcut?, in defaults: UserDefaults = .standard) {
        defaults.set(shortcut.map { Int($0.keyCode) } ?? noKeyCode, forKey: peekKeyCodeKey)
        defaults.set(Int(shortcut?.modifiers ?? 0), forKey: peekModifiersKey)
    }
}

/// The Peek at Fences shortcut: saved in the settings, registered whichever app is in
/// front, and why it can't be used, for Settings to show.
@MainActor
final class PeekShortcut: ObservableObject {
    static let shared = PeekShortcut()

    @Published var shortcut: KeyShortcut? {
        didSet {
            guard shortcut != oldValue else { return }
            AppSettings.setPeekShortcut(shortcut)
            Log.write("peek shortcut: changed to \(shortcut?.displayName ?? "none")")
            register()
        }
    }

    /// Why the shortcut doesn't work, asking for another one. Nil when it's fine or cleared.
    @Published private(set) var problem: String?

    var onPress: () -> Void = {}
    private var hotKey: HotKey?
    /// While a new shortcut is being recorded, the old one stays out of its way.
    private var recording = false

    private init() {
        // Not through the setter, which would save and register it.
        _shortcut = Published(initialValue: AppSettings.peekShortcut())
    }

    func start() { register() }

    func setRecording(_ recording: Bool) {
        guard recording != self.recording else { return }
        self.recording = recording
        if recording {
            hotKey?.unregister()
            hotKey = nil
        } else {
            register()
        }
    }

    /// Checks again whether macOS uses the shortcut, which can change in System Settings.
    func recheck() {
        guard !recording, let shortcut else { return }
        let problem = Self.problem(for: shortcut, status: hotKey?.status ?? noErr)
        if problem != self.problem {
            self.problem = problem
            Log.write("peek shortcut: \(problem ?? "\(shortcut.displayName) is free now")")
        }
    }

    private func register() {
        hotKey?.unregister()
        hotKey = nil
        guard !recording else { return }
        guard let shortcut else {
            problem = nil
            Log.write("peek shortcut: none set")
            return
        }
        let hotKey = HotKey(shortcut) { [weak self] in
            Log.write("peek shortcut: \(shortcut.displayName) pressed")
            self?.onPress()
        }
        self.hotKey = hotKey
        problem = Self.problem(for: shortcut, status: hotKey.status)
        if let problem {
            Log.write("peek shortcut: \(problem) (RegisterEventHotKey status \(hotKey.status))")
        } else {
            Log.write("peek shortcut: registered \(shortcut.displayName)")
        }
    }

    private static func problem(for shortcut: KeyShortcut, status: OSStatus) -> String? {
        let name = shortcut.displayName
        if status == OSStatus(eventHotKeyExistsErr) {
            return "\(name) is already taken by another app. Pick another shortcut."
        }
        if status != noErr {
            return "\(name) couldn't be set up as a shortcut. Pick another one."
        }
        if let use = SystemShortcuts.conflict(for: shortcut) {
            return "\(name) is used by macOS to \(use). Pick another shortcut, or turn that one off in System Settings \u{203A} Keyboard \u{203A} Keyboard Shortcuts."
        }
        return nil
    }
}
