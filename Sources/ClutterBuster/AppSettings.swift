import Foundation

enum AppSettings {
    static let defaultColorKey = "defaultColor"
    static let defaultIconsPerRowKey = "defaultIconsPerRow"
    static let iconsPerRowRange = 2...8

    static var defaultColor: FenceColor {
        FenceColor(rawValue: UserDefaults.standard.string(forKey: defaultColorKey) ?? "") ?? .slate
    }

    static var defaultIconsPerRow: Int {
        let value = UserDefaults.standard.integer(forKey: defaultIconsPerRowKey)
        return iconsPerRowRange.contains(value) ? value : 4
    }
}
