import AppKit

/// What a link's page says about itself: its title and where its icons are, best first.
struct LinkPage {
    var title: String?
    var iconURLs: [URL] = []

    /// Reads the title and icon links out of a page's HTML. Touch icons come first since
    /// they're large, then other icons by their stated size, largest first.
    static func parse(html: String, base: URL) -> LinkPage {
        var page = LinkPage()
        if let match = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>", options: [.regularExpression, .caseInsensitive]) {
            let tag = String(html[match])
            let inner = tag.replacingOccurrences(of: "^<title[^>]*>|</title>$", with: "", options: [.regularExpression, .caseInsensitive])
            let title = decodeEntities(inner)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { page.title = title }
        }

        var icons: [(url: URL, rank: Int)] = []
        let linkTags = matches(of: "<link\\b[^>]*>", in: html)
        for tag in linkTags {
            let attributes = self.attributes(of: tag)
            guard let rel = attributes["rel"]?.lowercased(), let href = attributes["href"],
                  let url = URL(string: decodeEntities(href), relativeTo: base)?.absoluteURL,
                  url.scheme == "https" || url.scheme == "http" else { continue }
            let rels = Set(rel.split(separator: " ").map(String.init))
            let size = attributes["sizes"].flatMap { sizes in
                sizes.lowercased().split(separator: " ").compactMap { Int($0.split(separator: "x").first ?? "") }.max()
            }
            if rels.contains("apple-touch-icon") || rels.contains("apple-touch-icon-precomposed") {
                icons.append((url, 10_000 + (size ?? 180)))
            } else if rels.contains("icon") {
                icons.append((url, size ?? 16))
            }
        }
        page.iconURLs = icons.sorted { $0.rank > $1.rank }.map(\.url)
        return page
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func attributes(of tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: "([a-zA-Z_:-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))") else { return [:] }
        var attributes: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let name = Range(match.range(at: 1), in: tag).map({ String(tag[$0]).lowercased() }) else { continue }
            let value = (2...4).lazy.compactMap { Range(match.range(at: $0), in: tag).map { String(tag[$0]) } }.first
            if let value, attributes[name] == nil { attributes[name] = value }
        }
        return attributes
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in ["&quot;": "\"", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&ndash;": "\u{2013}", "&mdash;": "\u{2014}"] {
            result = result.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let digits = Range(match.range(at: 2), in: result),
                      let hex = Range(match.range(at: 1), in: result) else { continue }
                let radix = result[hex].isEmpty ? 10 : 16
                guard let code = UInt32(result[digits], radix: radix), let scalar = Unicode.Scalar(code) else { continue }
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        // Last, so "&amp;lt;" ends up as "&lt;".
        return result.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }
}

/// Link icons. A link's page is fetched once for its title and favicon, and favicons are
/// saved per site in Application Support, so a site is only ever asked once. A site whose
/// icon couldn't be had is tried again at the next launch; meanwhile its links show a globe.
@MainActor
final class Favicons {
    static let shared = Favicons()

    private let folder: URL
    private var images: [String: NSImage] = [:]
    /// Sites whose icon couldn't be fetched this launch.
    private var failedHosts: Set<String> = []
    private var pageTasks: [String: Task<String?, Never>] = [:]

    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClutterBuster/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private static func host(of url: URL) -> String? {
        url.host()?.lowercased()
    }

    private func fileURL(forHost host: String) -> URL {
        folder.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    /// The saved icon for the link's site, without fetching anything.
    func cachedIcon(for url: URL) -> NSImage? {
        guard let host = Self.host(of: url) else { return nil }
        if let image = images[host] { return image }
        guard let image = NSImage(contentsOf: fileURL(forHost: host)) else { return nil }
        images[host] = image
        return image
    }

    /// The link's site icon, fetching it the first time.
    func icon(for url: URL) async -> NSImage? {
        if let image = cachedIcon(for: url) { return image }
        guard let host = Self.host(of: url), !failedHosts.contains(host) else { return nil }
        _ = await fetchPage(url)
        return cachedIcon(for: url)
    }

    /// Fetches the link's page and returns its title, saving the site's icon on the way if
    /// it doesn't have one yet.
    func fetchPage(_ url: URL) async -> String? {
        let key = url.absoluteString
        if let task = pageTasks[key] { return await task.value }
        let task = Task<String?, Never> {
            let page = await Self.loadPage(url)
            if let host = Self.host(of: url), self.cachedIcon(for: url) == nil, !self.failedHosts.contains(host) {
                var candidates = page?.iconURLs ?? []
                if let scheme = url.scheme, let fallback = URL(string: "\(scheme)://\(url.host() ?? host)/favicon.ico") {
                    candidates.append(fallback)
                }
                if let (png, source) = await Self.downloadIcon(from: candidates), let image = NSImage(data: png) {
                    do {
                        try png.write(to: self.fileURL(forHost: host), options: .atomic)
                    } catch {
                        Log.write("favicon: couldn't save the icon for \(host): \(error.localizedDescription)")
                    }
                    self.images[host] = image
                    Log.write("favicon: saved \(host)'s icon from \(source.absoluteString)")
                } else {
                    self.failedHosts.insert(host)
                    Log.write("favicon: no icon for \(host) (tried \(candidates.count) place(s)); its links show a globe")
                }
            }
            return page?.title
        }
        pageTasks[key] = task
        let title = await task.value
        pageTasks[key] = nil
        return title
    }

    private nonisolated static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        // Some sites turn away requests that don't look like a browser's.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        return request
    }

    private nonisolated static func loadPage(_ url: URL) async -> LinkPage? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.mimeType?.contains("html") == true else { return nil }
            let head = data.prefix(1_000_000)
            let html = String(data: head, encoding: .utf8) ?? String(decoding: head, as: UTF8.self)
            return LinkPage.parse(html: html, base: response.url ?? url)
        } catch {
            Log.write("link: couldn't load \(url.absoluteString): \(error.localizedDescription)")
            return nil
        }
    }

    /// The first candidate that downloads as a picture, as PNG data at its own size (at most
    /// 256 pixels), and where it came from.
    private nonisolated static func downloadIcon(from candidates: [URL]) async -> (Data, URL)? {
        for candidate in candidates {
            guard let (data, response) = try? await URLSession.shared.data(for: request(candidate)),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let png = await MainActor.run(body: { pngData(from: data) }) else { continue }
            return (png, candidate)
        }
        return nil
    }

    private static func pngData(from data: Data) -> Data? {
        guard let image = NSImage(data: data), image.isValid else { return nil }
        let largest = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        let side = min(max(largest > 0 ? largest : Int(image.size.width), 16), 256)
        guard side > 0, let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: CGRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
