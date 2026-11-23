import AppKit

enum AppSettings {
    static let defaultColorKey = "defaultColor"
    static let defaultIconsPerRowKey = "defaultIconsPerRow"
    static let defaultOpacityKey = "defaultOpacity"
    static let globalThemeKey = "globalTheme"
    static let animateThemesKey = "animateThemes"
    static let snapKey = "snapFences"
    static let snapGapKey = "snapGap"
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
