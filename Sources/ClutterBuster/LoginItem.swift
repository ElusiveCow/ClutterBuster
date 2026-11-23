import AppKit
import ServiceManagement

/// Clutter Buster always opens at login. It registers itself with `SMAppService` at launch,
/// but only when it runs from an Applications folder, so a copy in a build folder never
/// becomes the login item.
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    @Published private(set) var status: SMAppService.Status = .notRegistered
    /// Why it isn't registered, when that's not up to the user.
    @Published private(set) var problem: String?

    private init() {}

    var summary: String {
        if problem != nil { return "Not set up" }
        switch status {
        case .enabled: return "On"
        case .requiresApproval: return "Waiting for your approval"
        case .notRegistered: return "Off"
        case .notFound: return "Not found"
        @unknown default: return "Unknown"
        }
    }

    func registerAtLaunch() {
        let bundle = Bundle.main.bundleURL
        guard Self.isInstalled(bundle) else {
            problem = "Clutter Buster is running from \(bundle.deletingLastPathComponent().path), so it isn't set to open at login. Move it to Applications."
            Log.write("login item: not registering, running from \(bundle.path) rather than an Applications folder")
            refresh()
            return
        }
        let service = SMAppService.mainApp
        let before = service.status
        switch before {
        case .enabled:
            Log.write("login item: registered for \(bundle.path)")
        case .requiresApproval:
            Log.write("login item: registered for \(bundle.path), waiting for approval in System Settings › General › Login Items")
        default:
            do {
                try service.register()
                Log.write("login item: registered \(bundle.path) (was \(Self.name(before))), now \(Self.name(service.status))")
            } catch {
                problem = error.localizedDescription
                Log.write("login item: couldn't register \(bundle.path) (was \(Self.name(before))): \(error.localizedDescription)")
            }
        }
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
        if status == .enabled || status == .requiresApproval, Self.isInstalled(Bundle.main.bundleURL) { problem = nil }
    }

    func openLoginItemsSettings() {
        Log.write("login item: opening System Settings › General › Login Items")
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Whether the app is in /Applications or ~/Applications.
    nonisolated static func isInstalled(_ bundleURL: URL) -> Bool {
        let folder = bundleURL.deletingLastPathComponent().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").standardizedFileURL.path
        return folder == "/Applications" || folder == home
    }

    static func name(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .requiresApproval: "requires approval"
        case .notRegistered: "not registered"
        case .notFound: "not found"
        @unknown default: "status \(status.rawValue)"
        }
    }
}
