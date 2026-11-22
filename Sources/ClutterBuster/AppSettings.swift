import Foundation

enum AppSettings {
    static let defaultColorKey = "defaultColor"
    static let defaultIconsPerRowKey = "defaultIconsPerRow"
    static let defaultOpacityKey = "defaultOpacity"
    static let iconsPerRowRange = 2...8

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
