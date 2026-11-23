import AppKit

enum AppSettings {
    static let defaultColorKey = "defaultColor"
    static let defaultIconsPerRowKey = "defaultIconsPerRow"
    static let defaultOpacityKey = "defaultOpacity"
    static let globalThemeKey = "globalTheme"
    static let animateThemesKey = "animateThemes"
    static let snapKey = "snapFences"
    static let snapGapKey = "snapGap"
    static let newFileModeKey = "newFileMode"
    static let autoFileRulesKey = "autoFileRules"
    static let iconsPerRowRange = 2...8
    static let snapGapRange = 0...24

    static var defaultColor: FenceColor {
        FenceColor(rawValue: UserDefaults.standard.string(forKey: defaultColorKey) ?? "") ?? .slate
    }

    static var defaultOpacity: Double {
        guard UserDefaults.standard.object(forKey: defaultOpacityKey) != nil else { return 1 }
        return min(max(UserDefaults.standard.double(forKey: defaultOpacityKey), 0), 1)
    }

    static var defaultIconsPerRow: Int {
        let value = UserDefaults.standard.integer(forKey: defaultIconsPerRowKey)
        return iconsPerRowRange.contains(value) ? value : 4
    }
}

/// The global theme and animation switch, shared by every fence, the toolbar and search so
/// a change in Settings shows everywhere at once.
@MainActor
final class ThemeSettings: ObservableObject {
    static let shared = ThemeSettings()

    @Published var globalTheme: FenceTheme {
        didSet { UserDefaults.standard.set(globalTheme.rawValue, forKey: AppSettings.globalThemeKey) }
    }

    @Published var animateThemes: Bool {
        didSet { UserDefaults.standard.set(animateThemes, forKey: AppSettings.animateThemesKey) }
    }

    /// False under Reduce Motion or Low Power Mode.
    @Published private(set) var motionAllowed = true

    /// Whether theme animations should run at all right now.
    var animates: Bool { animateThemes && motionAllowed }

    private init() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: AppSettings.globalThemeKey)
        globalTheme = FenceTheme(rawValue: saved ?? "") ?? .classic
        if let saved, FenceTheme(rawValue: saved) == nil {
            // Saved right away so this happens, and is logged, once.
            defaults.set(FenceTheme.classic.rawValue, forKey: AppSettings.globalThemeKey)
            Log.write("global theme \"\(saved)\" isn't in this version; using Classic")
        }
        animateThemes = defaults.object(forKey: AppSettings.animateThemesKey) as? Bool ?? true
        updateMotion()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMotion() }
        }
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMotion() }
        }
    }

    private func updateMotion() {
        let allowed = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
        if allowed != motionAllowed { motionAllowed = allowed }
    }
}

/// Whether fences snap while they're moved or resized, and the gap left between neighbors.
/// Settings and the toolbar's magnet share it.
@MainActor
final class SnapSettings: ObservableObject {
    static let shared = SnapSettings()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: AppSettings.snapKey)
            if enabled != oldValue { Log.write("snapping \(enabled ? "on" : "off")") }
        }
    }

    @Published var gap: Int {
        didSet { UserDefaults.standard.set(gap, forKey: AppSettings.snapGapKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: AppSettings.snapKey) as? Bool ?? true
        let gap = defaults.object(forKey: AppSettings.snapGapKey) as? Int ?? 6
        self.gap = min(max(gap, AppSettings.snapGapRange.lowerBound), AppSettings.snapGapRange.upperBound)
    }
}

/// What happens to a file that newly appears on the Desktop.
enum NewFileMode: String, CaseIterable, Identifiable {
    case leave, rules, ask, rulesThenAsk

    var id: Self { self }

    var title: String {
        switch self {
        case .leave: "Leave it on the Desktop"
        case .rules: "Sort with rules"
        case .ask: "Ask me each time"
        case .rulesThenAsk: "Sort with rules, ask if no rule matches"
        }
    }

    var usesRules: Bool { self == .rules || self == .rulesThenAsk }
}

/// The kinds of file a rule can match. A file can be more than one: a screenshot is an image too.
enum FileKind: String, Codable, CaseIterable, Identifiable {
    case any, screenshot, image, pdf, document, spreadsheet, presentation, video, audio, archive, folder, app

    var id: Self { self }

    var name: String {
        switch self {
        case .any: "Any file"
        case .screenshot: "Screenshot"
        case .image: "Image"
        case .pdf: "PDF"
        case .document: "Document"
        case .spreadsheet: "Spreadsheet"
        case .presentation: "Presentation"
        case .video: "Video"
        case .audio: "Audio"
        case .archive: "Archive"
        case .folder: "Folder"
        case .app: "App"
        }
    }

    /// For "Remember for PDFs".
    var plural: String {
        switch self {
        case .any: "files"
        case .pdf: "PDFs"
        case .audio: "audio files"
        default: name.lowercased() + "s"
        }
    }
}

/// "If a file is this kind, its name contains this and its extension is one of these, put it
/// in this fence's tab." Empty conditions match anything. A nil tab means whichever tab the
/// fence is showing.
struct AutoFileRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: FileKind = .any
    var nameContains = ""
    /// One extension or several separated by commas or spaces, with or without dots.
    var fileExtension = ""
    var fenceID: UUID?
    var tabID: UUID?

    init(kind: FileKind = .any, nameContains: String = "", fileExtension: String = "", fenceID: UUID? = nil, tabID: UUID? = nil) {
        self.kind = kind
        self.nameContains = nameContains
        self.fileExtension = fileExtension
        self.fenceID = fenceID
        self.tabID = tabID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = (try? container.decodeIfPresent(FileKind.self, forKey: .kind)) ?? .any
        nameContains = try container.decodeIfPresent(String.self, forKey: .nameContains) ?? ""
        fileExtension = try container.decodeIfPresent(String.self, forKey: .fileExtension) ?? ""
        fenceID = try container.decodeIfPresent(UUID.self, forKey: .fenceID)
        tabID = try container.decodeIfPresent(UUID.self, forKey: .tabID)
    }

    var extensions: [String] {
        fileExtension.lowercased()
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : String($0) }
            .filter { !$0.isEmpty }
    }

    var trimmedName: String { nameContains.trimmingCharacters(in: .whitespaces) }

    /// "PDF", "Screenshot named “Invoice”", "Any file ending .png or .jpg".
    var summary: String {
        var parts = [kind.name]
        if !trimmedName.isEmpty { parts.append("named \u{201C}\(trimmedName)\u{201D}") }
        let extensions = extensions
        if !extensions.isEmpty { parts.append("ending " + extensions.map { "." + $0 }.joined(separator: " or ")) }
        return parts.joined(separator: " ")
    }

    /// Why the rule can't be used right now, or nil when its fence and tab exist.
    func problem(in fences: [Fence]) -> String? {
        guard let fenceID else { return "Choose a fence" }
        guard let fence = fences.first(where: { $0.id == fenceID }) else { return "Its fence was deleted" }
        guard fence.holdsItems else { return "Its fence is a sticky note" }
        if let tabID, !fence.tabs.contains(where: { $0.id == tabID }) { return "Its tab was deleted" }
        return nil
    }
}

/// The "New Desktop Files" settings: what to do with a new file, and the rules for sorting it.
@MainActor
final class NewFileSettings: ObservableObject {
    static let shared = NewFileSettings()

    @Published var mode: NewFileMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: AppSettings.newFileModeKey)
            if mode != oldValue { Log.write("new files: setting changed to \"\(mode.title)\"") }
        }
    }

    /// Checked from the top; the first that matches wins.
    @Published var rules: [AutoFileRule] {
        didSet { save() }
    }

    private init() {
        let defaults = UserDefaults.standard
        mode = NewFileMode(rawValue: defaults.string(forKey: AppSettings.newFileModeKey) ?? "") ?? .leave
        if let json = defaults.string(forKey: AppSettings.autoFileRulesKey), let data = json.data(using: .utf8),
           let saved = try? JSONDecoder().decode([AutoFileRule].self, from: data) {
            rules = saved
        } else {
            rules = []
        }
    }

    /// Saved as a JSON string so it reads and edits easily with `defaults`.
    private func save() {
        guard let data = try? JSONEncoder().encode(rules), let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: AppSettings.autoFileRulesKey)
    }
}
