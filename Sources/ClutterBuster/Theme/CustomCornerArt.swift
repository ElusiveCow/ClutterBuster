import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// A fence's own corner picture: the subject of a photo lifted out of its background, saved
/// as a PNG in Application Support. The original file is never touched.
enum CustomCornerArt {
    /// Longest side of a saved picture, in pixels.
    static let side = 512

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClutterBuster/CornerArt", isDirectory: true)

    private static let cache = NSCache<NSString, NSImage>()

    static func fileName(for fenceID: UUID) -> String { "\(fenceID.uuidString).png" }

    static func url(_ fileName: String) -> URL { folder.appendingPathComponent(fileName) }

    static func exists(for fenceID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(fileName(for: fenceID)).path)
    }

    static func image(_ fileName: String) -> NSImage? {
        let key = fileName as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let image = NSImage(contentsOf: url(fileName)) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func delete(for fenceID: UUID) {
        let name = fileName(for: fenceID)
        cache.removeObject(forKey: name as NSString)
        guard FileManager.default.fileExists(atPath: url(name).path) else { return }
        do {
            try FileManager.default.removeItem(at: url(name))
            Log.write("deleted the corner picture of fence \(fenceID)")
        } catch {
            Log.write("couldn't delete the corner picture of fence \(fenceID): \(error.localizedDescription)")
        }
    }

    // MARK: Undo trash

    /// Where a deleted fence's picture waits while the delete can still be undone.
    static let undoTrash = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClutterBuster/UndoTrash", isDirectory: true)

    /// Moves the fence's picture into the undo trash. False if it has none.
    @discardableResult
    static func moveToUndoTrash(for fenceID: UUID) -> Bool {
        let name = fileName(for: fenceID)
        cache.removeObject(forKey: name as NSString)
        guard FileManager.default.fileExists(atPath: url(name).path) else { return false }
        let trashed = undoTrash.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: undoTrash, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: trashed)
            try FileManager.default.moveItem(at: url(name), to: trashed)
            Log.write("moved the corner picture of fence \(fenceID) to the undo trash")
            return true
        } catch {
            Log.write("couldn't move the corner picture of fence \(fenceID) to the undo trash, so deleted it: \(error.localizedDescription)")
            delete(for: fenceID)
            return false
        }
    }

    /// Puts the fence's picture back from the undo trash.
    static func restoreFromUndoTrash(for fenceID: UUID) {
        let name = fileName(for: fenceID)
        let trashed = undoTrash.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: trashed.path) else {
            Log.write("  the corner picture of fence \(fenceID) isn't in the undo trash any more")
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url(name))
            try FileManager.default.moveItem(at: trashed, to: url(name))
            cache.removeObject(forKey: name as NSString)
            Log.write("  put the corner picture of fence \(fenceID) back")
        } catch {
            Log.write("  couldn't put the corner picture of fence \(fenceID) back: \(error.localizedDescription)")
        }
    }

    static func deleteFromUndoTrash(for fenceID: UUID) {
        let trashed = undoTrash.appendingPathComponent(fileName(for: fenceID))
        guard FileManager.default.fileExists(atPath: trashed.path) else { return }
        try? FileManager.default.removeItem(at: trashed)
        Log.write("deleted the corner picture of fence \(fenceID) from the undo trash")
    }

    /// Deletes everything in the undo trash, as on quit and at launch.
    static func emptyUndoTrash(_ reason: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: undoTrash.path)) ?? []
        guard !names.isEmpty else { return }
        for name in names { try? FileManager.default.removeItem(at: undoTrash.appendingPathComponent(name)) }
        Log.write("emptied the undo trash (\(names.count) picture(s)), \(reason)")
    }

    enum Failure: LocalizedError {
        case unreadable, unwritable

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file isn't a picture Clutter Buster can read."
            case .unwritable: "The picture couldn't be saved."
            }
        }
    }

    struct Made {
        let fileName: String
        /// False when no subject was found and the whole photo was framed instead.
        let cutOut: Bool
    }

    /// Lifts the subject of the picture at `source` out of its background with Vision, trims
    /// it, scales it to `side` and saves it for `fenceID`, replacing any earlier one. Without a
    /// clear subject the whole photo is saved in a soft rounded frame. Slow, so call it off
    /// the main thread.
    static func make(from source: URL, for fenceID: UUID) throws -> Made {
        guard let photo = load(source) else { throw Failure.unreadable }
        let subject = foreground(of: photo)
        let name = fileName(for: fenceID)
        guard let picture = subject.flatMap(fitted) ?? framed(photo), save(picture, to: url(name)) else {
            throw Failure.unwritable
        }
        cache.removeObject(forKey: name as NSString)
        return Made(fileName: name, cutOut: subject != nil)
    }

    /// The picture upright and no bigger than Vision needs.
    private static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Every subject Vision finds, on a transparent background and cropped to them.
    private static func foreground(of image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
            let buffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: true
            )
            let masked = CIImage(cvPixelBuffer: buffer)
            return CIContext().createCGImage(masked, from: masked.extent)
        } catch {
            Log.write("corner picture: Vision failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Scaled down so its longest side is at most `side`, keeping transparency.
    private static func fitted(_ image: CGImage) -> CGImage? {
        let scale = min(1, CGFloat(side) / CGFloat(max(image.width, image.height)))
        let size = CGSize(width: (CGFloat(image.width) * scale).rounded(), height: (CGFloat(image.height) * scale).rounded())
        return draw(size: size) { context in
            context.draw(image, in: CGRect(origin: .zero, size: size))
        }
    }

    /// The whole photo with rounded corners inside a white rounded border.
    private static func framed(_ photo: CGImage) -> CGImage? {
        let scale = min(1, CGFloat(side) / CGFloat(max(photo.width, photo.height)))
        let size = CGSize(width: (CGFloat(photo.width) * scale).rounded(), height: (CGFloat(photo.height) * scale).rounded())
        let border = (min(size.width, size.height) * 0.05).rounded()
        let radius = min(size.width, size.height) * 0.12
        return draw(size: size) { context in
            let outer = CGRect(origin: .zero, size: size)
            context.addPath(CGPath(roundedRect: outer, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
            let inner = outer.insetBy(dx: border, dy: border)
            let innerRadius = max(radius - border, 2)
            context.addPath(CGPath(roundedRect: inner, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
            context.clip()
            let fill = max(inner.width / CGFloat(photo.width), inner.height / CGFloat(photo.height))
            let drawn = CGSize(width: CGFloat(photo.width) * fill, height: CGFloat(photo.height) * fill)
            context.draw(photo, in: CGRect(x: inner.midX - drawn.width / 2, y: inner.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
        }
    }

    private static func draw(size: CGSize, _ body: (CGContext) -> Void) -> CGImage? {
        guard size.width >= 1, size.height >= 1,
              let context = CGContext(
                  data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        body(context)
        return context.makeImage()
    }

    private static func save(_ image: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
