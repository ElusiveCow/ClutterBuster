import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Supplies item icons that match the Desktop. When Finder shows icon previews, documents
/// get Quick Look thumbnails (drawn as icons); everything else, and anything still loading,
/// uses the regular Finder icon, which also honors custom icons.
@MainActor
final class IconProvider {
    static let shared = IconProvider()

    private var plainIcons: [String: NSImage] = [:]
    private var previews: [String: NSImage] = [:]
    private var missingPreviews: Set<String> = []
    private var tasks: [String: Task<NSImage?, Never>] = [:]

    func plainIcon(for path: String) -> NSImage {
        if let icon = plainIcons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        plainIcons[path] = icon
        return icon
    }

    /// The best icon available right now, without waiting for a thumbnail.
    func currentIcon(for path: String, pointSize: CGFloat, scale: CGFloat) -> NSImage {
        previews[Self.key(path: path, pointSize: pointSize, scale: scale)] ?? plainIcon(for: path)
    }

    func preview(for path: String, pointSize: CGFloat, scale: CGFloat) async -> NSImage? {
        let key = Self.key(path: path, pointSize: pointSize, scale: scale)
        if let image = previews[key] { return image }
        if missingPreviews.contains(key) || !Self.wantsPreview(path: path) { return nil }
        if let task = tasks[key] { return await task.value }

        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: Self.bucket(pointSize), height: Self.bucket(pointSize)),
            scale: scale,
            representationTypes: .thumbnail
        )
        request.iconMode = true
        let task = Task<NSImage?, Never> {
            try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
        tasks[key] = task
        let image = await task.value
        tasks[key] = nil
        if let image { previews[key] = image } else { missingPreviews.insert(key) }
        return image
    }

    /// Cache key: path, size bucket, and modification date so edited files refresh.
    static func key(path: String, pointSize: CGFloat, scale: CGFloat) -> String {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(Int(bucket(pointSize) * scale))|\(modified)"
    }

    private static func bucket(_ pointSize: CGFloat) -> CGFloat {
        [32, 64, 128, 256].first { $0 >= pointSize } ?? 256
    }

    private static func wantsPreview(path: String) -> Bool {
        guard finderShowsIconPreviews else { return false }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .customIconKey])
        // Finder shows folders, apps and custom-icon files with their regular icon.
        return values?.isDirectory == false && values?.customIcon == nil
    }

    private static var finderShowsIconPreviews: Bool {
        let settings = CFPreferencesCopyAppValue("DesktopViewSettings" as CFString, "com.apple.finder" as CFString) as? [String: Any]
        let iconView = settings?["IconViewSettings"] as? [String: Any]
        return (iconView?["showIconPreview"] as? NSNumber)?.boolValue ?? true
    }
}

struct ItemIcon: View {
    let path: String
    let size: CGFloat

    @Environment(\.displayScale) private var scale
    @State private var preview: NSImage?

    var body: some View {
        let key = IconProvider.key(path: path, pointSize: size, scale: scale)
        Image(nsImage: preview ?? IconProvider.shared.currentIcon(for: path, pointSize: size, scale: scale))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: key) {
                preview = await IconProvider.shared.preview(for: path, pointSize: size, scale: scale)
            }
    }
}
