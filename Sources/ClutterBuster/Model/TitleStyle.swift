import AppKit
import SwiftUI

enum TitleFont: Hashable, Codable {
    case system, rounded, serif, monospaced
    /// An installed font family, by name.
    case family(String)

    static let builtIn: [TitleFont] = [.system, .rounded, .serif, .monospaced]

    var name: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .monospaced: "Monospaced"
        case .family(let family): family
        }
    }

    var design: Font.Design? {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        case .family: nil
        }
    }

    /// Saved as one string: a built-in's name, or "family:" and the family's name.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw.hasPrefix("family:") {
            self = .family(String(raw.dropFirst("family:".count)))
        } else {
            self = Self.builtIn.first { $0.name.lowercased() == raw } ?? .system
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if case .family(let family) = self {
            try container.encode("family:" + family)
        } else {
            try container.encode(name.lowercased())
        }
    }

    /// Installed font families, alphabetically.
    static let installedFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

enum TitleWeight: String, Codable, CaseIterable, Identifiable {
    case regular, medium, semibold, bold

    var id: Self { self }
    var name: String { rawValue.capitalized }

    var font: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    /// `NSFontManager`'s 0–15 weight scale.
    fileprivate var managerWeight: Int {
        switch self {
        case .regular: 5
        case .medium: 6
        case .semibold: 8
        case .bold: 9
        }
    }
}

enum TitleAlignment: String, Codable, CaseIterable, Identifiable {
    case leading, center

    var id: Self { self }
}

/// How a fence's title looks. Each field left nil uses the theme's default.
struct TitleStyle: Codable, Equatable {
    static let sizeRange = 11.0...24.0
    /// Every theme's title size.
    static let defaultSize = 13.0

    var font: TitleFont?
    /// Points, before the fence's text size scales it.
    var size: Double?
    var weight: TitleWeight?
    var alignment: TitleAlignment?
    /// sRGB as "RRGGBB".
    var color: String?

    init() {}

    /// Fields from a newer version, or ones that don't parse, fall back to the theme.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        font = try? container.decodeIfPresent(TitleFont.self, forKey: .font)
        size = (try? container.decodeIfPresent(Double.self, forKey: .size)).map { min(max($0, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) }
        weight = try? container.decodeIfPresent(TitleWeight.self, forKey: .weight)
        alignment = try? container.decodeIfPresent(TitleAlignment.self, forKey: .alignment)
        color = (try? container.decodeIfPresent(String.self, forKey: .color)).flatMap { Color(rgbHex: $0) == nil ? nil : $0 }
    }

    var isDefault: Bool { self == TitleStyle() }

    var pointSize: Double { size ?? Self.defaultSize }

    /// Height of one line of the title at the fence's text size.
    func lineHeight(scale: CGFloat) -> CGFloat {
        let size = CGFloat(pointSize) * scale
        guard case .family(let family) = font else { return size * 1.25 }
        return size * Self.lineHeightRatio(family: family)
    }

    private static var lineHeightRatios: [String: CGFloat] = [:]

    /// Some families draw taller than the system font; this keeps their title from clipping.
    private static func lineHeightRatio(family: String) -> CGFloat {
        if let ratio = lineHeightRatios[family] { return ratio }
        var ratio: CGFloat = 1.25
        if let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 100) {
            ratio = max(1.25, (font.ascender - font.descender + font.leading) / 100)
        }
        lineHeightRatios[family] = ratio
        return ratio
    }

    /// The title's look on `theme` at the fence's text size.
    func resolved(on theme: ThemeStyle, scale: CGFloat) -> ResolvedTitle {
        let size = CGFloat(pointSize) * scale
        let weight = weight ?? theme.titleWeight
        let font = font ?? theme.titleFont
        let custom = color.flatMap { Color(rgbHex: $0) }
        return ResolvedTitle(
            font: Self.font(font, size: size, weight: weight),
            countFont: Self.font(font, size: size, weight: .regular),
            alignment: alignment ?? .center,
            color: custom ?? theme.titleText,
            secondary: custom?.opacity(0.65) ?? theme.titleSecondary
        )
    }

    private static func font(_ font: TitleFont, size: CGFloat, weight: TitleWeight) -> Font {
        if let design = font.design {
            return .system(size: size, weight: weight.font, design: design)
        }
        guard case .family(let family) = font,
              let nsFont = NSFontManager.shared.font(withFamily: family, traits: [], weight: weight.managerWeight, size: size)
        else { return .system(size: size, weight: weight.font) }
        return Font(nsFont as CTFont)
    }
}

struct ResolvedTitle {
    let font: Font
    /// For the item count after the title.
    let countFont: Font
    let alignment: TitleAlignment
    let color: Color
    let secondary: Color
}

extension Color {
    /// Parses "RRGGBB" as sRGB.
    init?(rgbHex: String) {
        guard rgbHex.count == 6, let value = UInt32(rgbHex, radix: 16) else { return nil }
        self.init(hex: value)
    }

    /// The color as sRGB "RRGGBB".
    var rgbHex: String? {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
            .map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", channels[0], channels[1], channels[2])
    }
}
