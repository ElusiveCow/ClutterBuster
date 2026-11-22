import SwiftUI

enum FenceTheme: String, Codable, CaseIterable, Identifiable {
    case classic, rgb, fall, winter, ocean, glass, retro, halloween, christmas
    case cafe, space, beach, arcade, catNap, robot, notebook

    var id: String { rawValue }

    var name: String {
        switch self {
        case .classic: "Classic"
        case .rgb: "RGB"
        case .fall: "Fall"
        case .winter: "Winter"
        case .ocean: "Ocean"
        case .glass: "Frosted Glass"
        case .retro: "Retro"
        case .halloween: "Halloween"
        case .christmas: "Christmas"
        case .cafe: "Cozy Cafe"
        case .space: "Space"
        case .beach: "Beach"
        case .arcade: "Arcade"
        case .catNap: "Cat Nap"
        case .robot: "AI"
        case .notebook: "Notebook"
        }
    }

    /// The look of a non-Classic theme. Classic depends on the fence; use `ThemeStyle.resolve`.
    var style: ThemeStyle { ThemeStyle.make(self) }
}

enum ThemeFill {
    case color(Color)
    /// Top to bottom.
    case gradient([Color])
    /// A blur of whatever is behind the window.
    case glass
}

enum ThemeBorder {
    case line(Color)
    case glow(Color)
    /// A slowly turning rainbow with a soft glow.
    case rainbow
}

enum ThemePattern {
    case none, snow, retroGrid, nebula, waves, woodGrain, scanlines, sparkles, circuit, ruledPaper
}

enum ThemeParticle {
    case leaves, snow, bubbles, steam
}

enum TitleAccent {
    case none, leaves, lights
}

/// Everything a fence, the toolbar and the search dropdown need to draw a theme. The title
/// bar and tab strip are always solid so their text stays readable; only the body can be
/// see-through.
struct ThemeStyle {
    var theme: FenceTheme
    /// Light body with dark text.
    var isLight = false
    var body: ThemeFill
    /// 1 is solid. Glass bodies are always see-through.
    var bodyOpacity: Double = 1
    /// Solid color matching the body near its bottom, for surfaces that can't be see-through
    /// such as the search dropdown.
    var solidBody: Color
    var pattern: ThemePattern = .none

    var titleBar: ThemeFill
    var titleText: Color = .white
    var titleSecondary: Color = .white.opacity(0.6)
    /// The title's default font and weight; a fence's `TitleStyle` can override them.
    var titleFont: TitleFont = .system
    var titleWeight: TitleWeight = .semibold

    var tabStrip: Color
    var tabPill: Color
    var tabSelectedText: Color = .white
    var tabText: Color = .white.opacity(0.7)

    var bodyText: Color = .white
    var bodySecondary: Color = .white.opacity(0.7)
    /// Shadow under text on the title bar, tabs and body. Clear on light themes.
    var textShadow: Color = .black.opacity(0.45)

    var border: ThemeBorder = .line(.white.opacity(0.12))
    var accent: Color = .accentColor

    var cornerArt: String?
    /// Corner art width relative to `CornerArt.baseWidth`.
    var artScale: CGFloat = 1.2
    var particle: ThemeParticle?
    var titleAccent: TitleAccent = .none

    /// True when the desktop shows through the body.
    var isSeeThrough: Bool {
        if case .glass = body { return true }
        return bodyOpacity < 1
    }

    /// Small capsule buttons drawn on the tab strip.
    var tabControl: Color { tabSelectedText.opacity(0.1) }
    /// Small capsule buttons drawn on the title bar color (the toolbar uses these).
    var titleControl: Color { titleText.opacity(0.13) }

    /// The style a fence draws with: its own theme, or the global one when it has none.
    static func resolve(_ fence: Fence, global: FenceTheme) -> ThemeStyle {
        of(fence.theme ?? global, for: fence)
    }

    /// A theme's style as it would look on `fence`; Classic uses the fence's color and opacity.
    static func of(_ theme: FenceTheme, for fence: Fence) -> ThemeStyle {
        theme == .classic ? classic(color: fence.color, opacity: fence.opacity) : theme.style
    }

    static func classic(color: FenceColor, opacity: Double) -> ThemeStyle {
        let body = Color(nsColor: color.body)
        let titleBar = Color(nsColor: color.titleBar)
        return ThemeStyle(
            theme: .classic,
            body: .color(body),
            // Fully transparent pixels let clicks and drops fall through to the desktop, so
            // "Clear" keeps a barely visible tint.
            bodyOpacity: max(min(opacity, 1), 0.03),
            solidBody: body,
            titleBar: .color(titleBar),
            tabStrip: Color(nsColor: color.titleBar.blended(withFraction: 0.08, of: .white) ?? color.titleBar),
            tabPill: .white.opacity(0.35),
            tabText: .white.opacity(0.65),
            textShadow: .black.opacity(opacity < 1 ? 0.6 : 0)
        )
    }

    /// Toolbar and search follow the global theme. Classic keeps the original dark bar.
    static func chrome(_ theme: FenceTheme) -> ThemeStyle {
        guard theme == .classic else { return theme.style }
        var style = classic(color: .graphite, opacity: 1)
        style.titleBar = .color(Color(white: 0.12).opacity(0.94))
        style.solidBody = Color(white: 0.12)
        return style
    }

    fileprivate static func make(_ theme: FenceTheme) -> ThemeStyle {
        switch theme {
        case .classic:
            return classic(color: .slate, opacity: 1)

        case .rgb:
            let ink = Color(hex: 0x1D1D22)
            return ThemeStyle(
                theme: theme,
                isLight: true,
                body: .gradient([Color(hex: 0xFBFBFD), Color(hex: 0xEEF0F5)]),
                solidBody: Color(hex: 0xEEF0F5),
                titleBar: .gradient([.white, Color(hex: 0xF5F6F9)]),
                titleText: ink,
                titleSecondary: Color(hex: 0x6E6E78),
                tabStrip: Color(hex: 0xE8EAF0),
                tabPill: .white,
                tabSelectedText: ink,
                tabText: ink.opacity(0.62),
                bodyText: ink,
                bodySecondary: ink.opacity(0.55),
                textShadow: .clear,
                border: .rainbow,
                accent: Color(hex: 0x6B5BFF)
            )

        case .fall:
            return ThemeStyle(
                theme: theme,
                body: .gradient([Color(hex: 0x8F4B1D), Color(hex: 0x6A3312)]),
                bodyOpacity: 0.9,
                solidBody: Color(hex: 0x6A3312),
                titleBar: .gradient([Color(hex: 0x7C3A12), Color(hex: 0x6B300E)]),
                titleText: Color(hex: 0xFFF3E4),
                titleSecondary: Color(hex: 0xF5C08A),
                tabStrip: Color(hex: 0x8A4518),
                tabPill: Color(hex: 0xD9772A),
                tabText: Color(hex: 0xFBE2C8).opacity(0.85),
                bodyText: Color(hex: 0xFFF6EC),
                bodySecondary: Color(hex: 0xF5CFA6),
                border: .line(Color(hex: 0xF2A65A).opacity(0.4)),
                accent: Color(hex: 0xE5852F),
                cornerArt: "fall_corner",
                artScale: 1.25,
                particle: .leaves,
                titleAccent: .leaves
            )

        case .winter:
            return ThemeStyle(
                theme: theme,
                body: .gradient([Color(hex: 0x76A6D2), Color(hex: 0x4A7BA6)]),
                bodyOpacity: 0.86,
                solidBody: Color(hex: 0x4A7BA6),
                pattern: .snow,
                titleBar: .gradient([Color(hex: 0x3F6C95), Color(hex: 0x365F86)]),
                titleSecondary: Color(hex: 0xCFE6FA),
                tabStrip: Color(hex: 0x4E7DA7),
                tabPill: Color(hex: 0x8DB8DE),
                tabText: .white.opacity(0.75),
                bodySecondary: Color(hex: 0xE3F1FC),
                textShadow: Color(hex: 0x0E2A45).opacity(0.5),
                border: .line(.white.opacity(0.45)),
                accent: Color(hex: 0x5AA9E6),
                cornerArt: "winter_corner",
                artScale: 1.2,
                particle: .snow
            )

        case .ocean:
            return ThemeStyle(
                theme: theme,
                body: .gradient([Color(hex: 0x0F5384), Color(hex: 0x08304F)]),
                bodyOpacity: 0.88,
                solidBody: Color(hex: 0x08304F),
                pattern: .waves,
                titleBar: .gradient([Color(hex: 0x0A3B62), Color(hex: 0x083456)]),
                titleSecondary: Color(hex: 0x9FD6F7),
                tabStrip: Color(hex: 0x0E4772),
                tabPill: Color(hex: 0x2E86C1),
                tabText: .white.opacity(0.72),
                bodySecondary: Color(hex: 0xB5E0F8),
                border: .line(Color(hex: 0x5EC4F0).opacity(0.38)),
                accent: Color(hex: 0x2E9BE0),
                cornerArt: "ocean_corner",
                artScale: 1.15,
                particle: .bubbles
            )

        case .glass:
            return ThemeStyle(
                theme: theme,
                body: .glass,
                solidBody: Color(hex: 0x3B3E46),
                titleBar: .gradient([Color(hex: 0x30333A), Color(hex: 0x2A2C32)]),
                titleSecondary: .white.opacity(0.6),
                tabStrip: Color(hex: 0x383B42),
                tabPill: Color(hex: 0x666A74),
                tabText: .white.opacity(0.7),
                border: .line(.white.opacity(0.28)),
                accent: Color(hex: 0x6BA4FF)
            )

        case .retro:
            return ThemeStyle(
                theme: theme,
                body: .gradient([Color(hex: 0x2C1660), Color(hex: 0x6C2384), Color(hex: 0xB8357E)]),
                bodyOpacity: 0.9,
                solidBody: Color(hex: 0xB8357E),
                pattern: .retroGrid,
                titleBar: .gradient([Color(hex: 0x1F0F45), Color(hex: 0x27124F)]),
                titleSecondary: Color(hex: 0xFF9BD8),
                tabStrip: Color(hex: 0x321A66),
                tabPill: Color(hex: 0xF0479E),
                tabText: Color(hex: 0xF5D3FF).opacity(0.8),
                bodySecondary: Color(hex: 0xFFC6EC),
                textShadow: Color(hex: 0x1A0533).opacity(0.6),
                border: .glow(Color(hex: 0xFF4FD8)),
                accent: Color(hex: 0xF0479E),
                cornerArt: "retro_corner",
                artScale: 1.1
            )

        case .halloween:
            let ink = Color(hex: 0x2A0E31)
            return ThemeStyle(
                theme: theme,
                body: .gradient([Color(hex: 0x2E1846), Color(hex: 0x1B0D2B)]),
                bodyOpacity: 0.9,
                solidBody: Color(hex: 0x1B0D2B),
                pattern: .sparkles,
                titleBar: .gradient([Color(hex: 0xF28C28), Color(hex: 0xDB6C14)]),
                titleText: ink,
                titleSecondary: Color(hex: 0x5B2608),
                tabStrip: Color(hex: 0x3A1F57),
                tabPill: Color(hex: 0xF28C28),
                tabSelectedText: ink,
                tabText: Color(hex: 0xF7D9B8).opacity(0.85),
                bodySecondary: Color(hex: 0xF7C795),
                border: .line(Color(hex: 0xF28C28).opacity(0.45)),
                accent: Color(hex: 0xF28C28),
                cornerArt: "halloween_corner",
                artScale: 1.2
            )

        case .christmas:
            return ThemeStyle(
                theme: theme,
                body: .gradient([Color(hex: 0x1E5C3B), Color(hex: 0x144529)]),
                bodyOpacity: 0.92,
                solidBody: Color(hex: 0x144529),
                pattern: .snow,
                titleBar: .gradient([Color(hex: 0xB8212F), Color(hex: 0x9A1A26)]),
                titleSecondary: Color(hex: 0xFFC9CD),
                tabStrip: Color(hex: 0x174D31),
                tabPill: Color(hex: 0x2F8F57),
                tabText: .white.opacity(0.72),
                bodySecondary: Color(hex: 0xCFEBD9),
                border: .line(Color(hex: 0xD9B44A).opacity(0.45)),
                accent: Color(hex: 0xC8283A),
                cornerArt: "christmas_corner",
                artScale: 0.95,
                titleAccent: .lights
            )

        case .cafe:
            return ThemeStyle(
                theme: theme,
                body: .gradient([Color(hex: 0x6E4529), Color(hex: 0x50301B)]),
                bodyOpacity: 0.92,
                solidBody: Color(hex: 0x50301B),
                pattern: .woodGrain,
                titleBar: .gradient([Color(hex: 0x3F2716), Color(hex: 0x372112)]),
                titleText: Color(hex: 0xFFF2E2),
                titleSecondary: Color(hex: 0xE2BE95),
                titleFont: .serif,
                tabStrip: Color(hex: 0x5A3922),
                tabPill: Color(hex: 0xB97A45),
                tabText: Color(hex: 0xF3DEC6).opacity(0.8),
                bodyText: Color(hex: 0xFFF6EA),
                bodySecondary: Color(hex: 0xEBCCA8),
                border: .line(Color(hex: 0xD9A877).opacity(0.35)),
                accent: Color(hex: 0xC0844E),
                cornerArt: "cafe_corner",
                artScale: 1.15,
                particle: .steam
            )

        case .space:
            return ThemeStyle(
                theme: theme,
                body: .gradient([Color(hex: 0x0C0B2C), Color(hex: 0x1D1150)]),
                bodyOpacity: 0.92,
                solidBody: Color(hex: 0x1D1150),
                pattern: .nebula,
                titleBar: .gradient([Color(hex: 0x0A0920), Color(hex: 0x0D0B28)]),
                titleSecondary: Color(hex: 0xB9A8FF),
                tabStrip: Color(hex: 0x16133D),
                tabPill: Color(hex: 0x6A4BD6),
                tabText: .white.opacity(0.7),
                bodySecondary: Color(hex: 0xC9BEFF),
                border: .glow(Color(hex: 0x8C7BFF)),
                accent: Color(hex: 0x7A5CF0),
                cornerArt: "space_corner",
                artScale: 0.95
            )

        case .beach:
            let ink = Color(hex: 0x4A3416)
            return ThemeStyle(
                theme: theme,
                isLight: true,
                body: .gradient([Color(hex: 0xF5E6C6), Color(hex: 0xE9D19F)]),
                bodyOpacity: 0.9,
                solidBody: Color(hex: 0xE9D19F),
                pattern: .waves,
                titleBar: .gradient([Color(hex: 0x3FA7CB), Color(hex: 0x3496BA)]),
                titleSecondary: Color(hex: 0xDDF4FC),
                tabStrip: Color(hex: 0xECD9B0),
                tabPill: .white,
                tabSelectedText: ink,
                tabText: ink.opacity(0.68),
                bodyText: ink,
                bodySecondary: ink.opacity(0.6),
                textShadow: .clear,
                border: .line(Color(hex: 0xC9A665).opacity(0.6)),
                accent: Color(hex: 0x2F9CC4),
                cornerArt: "beach_corner",
                artScale: 0.95
            )

        case .arcade:
            return ThemeStyle(
                theme: theme,
                body: .gradient([Color(hex: 0x16123A), Color(hex: 0x0C0A20)]),
                solidBody: Color(hex: 0x0C0A20),
                pattern: .scanlines,
                titleBar: .gradient([Color(hex: 0x231C55), Color(hex: 0x1E184A)]),
                titleText: Color(hex: 0xFFE45C),
                titleSecondary: Color(hex: 0x6EF3FF),
                titleFont: .monospaced,
                tabStrip: Color(hex: 0x1A1640),
                tabPill: Color(hex: 0xFF3E8A),
                tabText: Color(hex: 0xB8B3FF).opacity(0.85),
                bodySecondary: Color(hex: 0x9EF6FF),
                border: .glow(Color(hex: 0x3DF0FF)),
                accent: Color(hex: 0xFF3E8A),
                cornerArt: "arcade_corner",
                artScale: 1.1
            )

        case .catNap:
            let ink = Color(hex: 0x3B2A54)
            return ThemeStyle(
                theme: theme,
                isLight: true,
                body: .gradient([Color(hex: 0xF6EDF9), Color(hex: 0xE8DAF2)]),
                bodyOpacity: 0.9,
                solidBody: Color(hex: 0xE8DAF2),
                pattern: .sparkles,
                titleBar: .gradient([Color(hex: 0xCDB6E6), Color(hex: 0xC2A9DF)]),
                titleText: ink,
                titleSecondary: Color(hex: 0x6E5590),
                titleFont: .rounded,
                tabStrip: Color(hex: 0xEBDDF4),
                tabPill: .white,
                tabSelectedText: ink,
                tabText: ink.opacity(0.65),
                bodyText: ink,
                bodySecondary: ink.opacity(0.6),
                textShadow: .clear,
                border: .line(Color(hex: 0xB89BD8).opacity(0.6)),
                accent: Color(hex: 0x9B7BD0),
                cornerArt: "catnap_corner",
                artScale: 1.05
            )

        case .robot:
            let ink = Color(hex: 0x1F2B3D)
            return ThemeStyle(
                theme: theme,
                isLight: true,
                body: .gradient([Color(hex: 0xF9FBFF), Color(hex: 0xEAF1FB)]),
                solidBody: Color(hex: 0xEAF1FB),
                pattern: .circuit,
                titleBar: .gradient([.white, Color(hex: 0xF3F7FD)]),
                titleText: ink,
                titleSecondary: Color(hex: 0x5D6B80),
                titleFont: .rounded,
                tabStrip: Color(hex: 0xDCE7F6),
                tabPill: .white,
                tabSelectedText: ink,
                tabText: ink.opacity(0.62),
                bodyText: ink,
                bodySecondary: ink.opacity(0.55),
                textShadow: .clear,
                border: .glow(Color(hex: 0x7FB8FF)),
                accent: Color(hex: 0x3B8BF0),
                cornerArt: "robot_corner",
                artScale: 0.95
            )

        case .notebook:
            let ink = Color(hex: 0x2B2F3A)
            let brown = Color(hex: 0x4A3320)
            return ThemeStyle(
                theme: theme,
                isLight: true,
                body: .gradient([Color(hex: 0xFFFDF6), Color(hex: 0xFBF5E7)]),
                solidBody: Color(hex: 0xFBF5E7),
                pattern: .ruledPaper,
                titleBar: .gradient([Color(hex: 0xD9BC92), Color(hex: 0xCDAE82)]),
                titleText: brown,
                titleSecondary: brown.opacity(0.7),
                titleFont: .family("Noteworthy"),
                tabStrip: Color(hex: 0xEFE2C8),
                tabPill: Color(hex: 0xFFFCF3),
                tabSelectedText: ink,
                tabText: ink.opacity(0.62),
                bodyText: ink,
                bodySecondary: ink.opacity(0.55),
                textShadow: .clear,
                border: .line(Color(hex: 0xB89A6E).opacity(0.7)),
                accent: Color(hex: 0x3C6FD1),
                cornerArt: "notebook_corner",
                artScale: 1.15
            )
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
