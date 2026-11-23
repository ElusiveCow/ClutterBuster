import CoreServices
import Foundation
import UniformTypeIdentifiers

/// What rules can know about a file: its name, extension and kinds.
struct FileFacts {
    let url: URL
    let name: String
    /// Lowercased, without the dot.
    let ext: String
    let kinds: Set<FileKind>
    /// How it was recognized as a screenshot, for the log.
    let screenshotSource: String?

    /// The most specific kind, for "Remember for PDFs".
    var primaryKind: FileKind {
        let order: [FileKind] = [.screenshot, .pdf, .image, .spreadsheet, .presentation, .document, .video, .audio, .archive, .app, .folder]
        return order.first(where: kinds.contains) ?? .any
    }

    var kindDescription: String {
        let names = FileKind.allCases.filter(kinds.contains).map(\.name)
        let kinds = names.isEmpty ? "no particular kind" : names.joined(separator: ", ")
        return screenshotSource.map { "\(kinds); screenshot by its \($0)" } ?? kinds
    }

    static func of(_ url: URL) -> FileFacts {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey])
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        let name = url.lastPathComponent
        var kinds = Self.kinds(of: values?.contentType, isFolder: isFolder)
        let screenshot = isFolder ? nil : screenshotSource(url)
        if screenshot != nil { kinds.insert(.screenshot) }
        return FileFacts(url: url, name: name, ext: url.pathExtension.lowercased(), kinds: kinds, screenshotSource: screenshot)
    }

    static func kinds(of type: UTType?, isFolder: Bool) -> Set<FileKind> {
        if isFolder { return [.folder] }
        guard let type else { return [] }
        func conforms(_ types: [UTType], _ identifiers: [String] = []) -> Bool {
            (types + identifiers.compactMap { UTType($0) }).contains { type.conforms(to: $0) }
        }
        var kinds: Set<FileKind> = []
        if conforms([.application, .applicationBundle]) { kinds.insert(.app) }
        if conforms([.pdf]) { kinds.insert(.pdf) }
        if conforms([.image]) { kinds.insert(.image) }
        if conforms([.movie, .video]) { kinds.insert(.video) } else if conforms([.audio]) { kinds.insert(.audio) }
        if conforms([.archive, .zip, .gzip, .diskImage], ["public.tar-archive", "org.7-zip.7-zip-archive", "com.rarlab.rar-archive"]) {
            kinds.insert(.archive)
        }
        let spreadsheet = conforms([.spreadsheet, .commaSeparatedText, .tabSeparatedText], [
            "org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls", "com.apple.iwork.numbers.numbers",
            "org.oasis-open.opendocument.spreadsheet",
        ])
        let presentation = conforms([.presentation], [
            "org.openxmlformats.presentationml.presentation", "com.microsoft.powerpoint.ppt", "com.apple.iwork.keynote.key",
            "org.oasis-open.opendocument.presentation",
        ])
        if spreadsheet { kinds.insert(.spreadsheet) }
        if presentation { kinds.insert(.presentation) }
        let document = conforms([.text, .rtf, .rtfd], [
            "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.pages",
            "org.oasis-open.opendocument.text", "net.daringfireball.markdown",
        ])
        if document, !spreadsheet, !presentation { kinds.insert(.document) }
        return kinds
    }

    /// Screenshots and screen recordings carry the Spotlight attribute `kMDItemIsScreenCapture`.
    /// Files copied from elsewhere may have lost it, so names count too.
    static func screenshotSource(_ url: URL) -> String? {
        if xattrBool(url, "com.apple.metadata:kMDItemIsScreenCapture") == true { return "Spotlight attribute" }
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
           let value = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool, value {
            return "Spotlight attribute"
        }
        let name = url.lastPathComponent.lowercased()
        return ["screenshot", "screen shot", "screen recording"].contains(where: name.hasPrefix) ? "name" : nil
    }

    /// A Spotlight attribute saved as an extended attribute: a binary property list.
    private static func xattrBool(_ url: URL, _ attribute: String) -> Bool? {
        let size = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size, let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }
}

extension AutoFileRule {
    func matches(_ facts: FileFacts) -> Bool {
        guard kind == .any || facts.kinds.contains(kind) else { return false }
        let name = trimmedName
        if !name.isEmpty, !facts.name.localizedCaseInsensitiveContains(name) { return false }
        let extensions = extensions
        return extensions.isEmpty || extensions.contains(facts.ext)
    }
}

/// The rule a file goes by: the first that matches and whose fence and tab still exist.
/// Matching rules that can't be used are listed in `skipped`.
struct RuleMatch {
    typealias Skipped = (rule: AutoFileRule, index: Int, problem: String)

    let rule: AutoFileRule
    let index: Int

    static func first(for facts: FileFacts, in rules: [AutoFileRule], fences: [Fence]) -> (match: RuleMatch?, skipped: [Skipped]) {
        var skipped: [Skipped] = []
        for (index, rule) in rules.enumerated() where rule.matches(facts) {
            if let problem = rule.problem(in: fences) {
                skipped.append((rule, index, problem))
                continue
            }
            return (RuleMatch(rule: rule, index: index), skipped)
        }
        return (nil, skipped)
    }
}

/// What "Remember my choice" makes a rule for: a kind of file, or failing that an extension.
enum RememberTarget: Equatable {
    case kind(FileKind)
    case fileExtension(String)

    /// The kind all the files share, else the extension they share, else nothing.
    static func shared(by facts: [FileFacts]) -> RememberTarget? {
        guard let first = facts.first else { return nil }
        let kind = first.primaryKind
        if kind != .any, facts.allSatisfy({ $0.primaryKind == kind }) { return .kind(kind) }
        if !first.ext.isEmpty, facts.allSatisfy({ $0.ext == first.ext }) { return .fileExtension(first.ext) }
        return nil
    }

    var label: String {
        switch self {
        case .kind(let kind): "Remember for \(kind.plural)"
        case .fileExtension(let ext): "Remember for .\(ext) files"
        }
    }

    func rule(fenceID: UUID, tabID: UUID?) -> AutoFileRule {
        switch self {
        case .kind(let kind): AutoFileRule(kind: kind, fenceID: fenceID, tabID: tabID)
        case .fileExtension(let ext): AutoFileRule(fileExtension: ext, fenceID: fenceID, tabID: tabID)
        }
    }
}

/// Decides what happens to each new Desktop file, following Settings › New Desktop Files:
/// leave it, file it by the first matching rule, or ask with the popup card.
@MainActor
final class AutoFiler {
    private let coordinator: FenceCoordinator
    private let prompt: NewFilePromptController
    private let settings = NewFileSettings.shared

    init(coordinator: FenceCoordinator, prompt: NewFilePromptController) {
        self.coordinator = coordinator
        self.prompt = prompt
        prompt.onChoose = { [weak self] urls, fenceID, tabID, remember in
            self?.fileFromPrompt(urls, fenceID: fenceID, tabID: tabID, remember: remember)
        }
        prompt.onLeave = { urls, reason in
            for url in urls { Log.write("new file \"\(url.lastPathComponent)\": left on the Desktop, \(reason)") }
        }
    }

    func handle(_ urls: [URL]) {
        let mode = settings.mode
        var unmatched: [URL] = []
        for url in urls {
            let facts = FileFacts.of(url)
            let name = url.lastPathComponent
            Log.write("new file \"\(name)\": \(facts.kindDescription); setting is \"\(mode.title)\"")
            guard mode.usesRules else {
                if mode == .leave { Log.write("  left on the Desktop") }
                unmatched.append(url)
                continue
            }
            let (match, skipped) = RuleMatch.first(for: facts, in: settings.rules, fences: coordinator.store.fences)
            for skip in skipped {
                Log.write("  rule \(skip.index + 1) (\(skip.rule.summary)) matches but is skipped: \(skip.problem.lowercased())")
            }
            if let match, let fenceID = match.rule.fenceID {
                file(url, fenceID: fenceID, tabID: match.rule.tabID, how: "by rule \(match.index + 1) (\(match.rule.summary))")
            } else {
                if mode == .rules { Log.write("  no rule matches; left on the Desktop") }
                unmatched.append(url)
            }
        }
        guard mode == .ask || mode == .rulesThenAsk, !unmatched.isEmpty else { return }
        if mode == .rulesThenAsk { Log.write("  no rule matches \(unmatched.count) file(s); asking") }
        prompt.ask(unmatched)
    }

    private func fileFromPrompt(_ urls: [URL], fenceID: UUID, tabID: UUID?, remember: RememberTarget?) {
        for url in urls {
            if coordinator.store.fences.contains(where: { $0.items.contains { $0.path == url.path } }) {
                Log.write("new file \"\(url.lastPathComponent)\": already in a fence, so the popup's choice doesn't apply")
                continue
            }
            file(url, fenceID: fenceID, tabID: tabID, how: "from the popup")
        }
        guard let remember, coordinator.store.fence(fenceID) != nil else { return }
        let rule = remember.rule(fenceID: fenceID, tabID: tabID)
        settings.rules.append(rule)
        Log.write("new files: remembered as rule \(settings.rules.count) (\(rule.summary))")
        if settings.mode == .ask {
            settings.mode = .rulesThenAsk
            Log.write("new files: switched to \"\(NewFileMode.rulesThenAsk.title)\" so the remembered choice applies")
        }
    }

    private func file(_ url: URL, fenceID: UUID, tabID: UUID?, how: String) {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.write("new file \"\(name)\": gone, nothing to file")
            return
        }
        guard let fence = coordinator.store.fence(fenceID) else {
            Log.write("new file \"\(name)\": its fence no longer exists; left on the Desktop")
            return
        }
        let tab = tabID.flatMap { id in fence.tabs.first { $0.id == id } } ?? fence.currentTab
        coordinator.addItems([url], to: fenceID, tab: tab.id)
        Log.write("auto-filed \"\(name)\" to \(fence.title) \u{203A} \(tab.name) \(how)")
    }
}
