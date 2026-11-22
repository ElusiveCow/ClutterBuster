import AppKit
import SwiftUI

/// Theme illustrations bundled in Contents/Resources/Themes. Missing files are skipped.
enum ThemeArt {
    private static let cache = NSCache<NSString, NSImage>()
    private static let missing = NSCache<NSString, NSNull>()

    static func image(_ name: String) -> NSImage? {
        let key = name as NSString
        if let image = cache.object(forKey: key) { return image }
        if missing.object(forKey: key) != nil { return nil }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Themes"),
              let image = NSImage(contentsOf: url) else {
            missing.setObject(NSNull(), forKey: key)
            Log.write("theme art \"\(name)\" not found in the app bundle")
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct ThemeFillView: View {
    let fill: ThemeFill

    var body: some View {
        switch fill {
        case .color(let color):
            Rectangle().fill(color)
        case .gradient(let colors):
            Rectangle().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
        case .glass:
            VisualEffectBackground()
        }
    }
}

/// Blurs whatever is behind the window. Always dark so it matches Frosted Glass's solid
/// title bar and corner card in light mode too.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: Body

/// The fence body: fill, static pattern and drifting particles, all behind the items.
struct ThemeBody: View {
    let style: ThemeStyle
    let animate: Bool

    var body: some View {
        ZStack {
            ThemeFillView(fill: style.body)
                .opacity(style.isSeeThrough ? style.bodyOpacity : 1)
            if style.pattern != .none {
                BodyPattern(pattern: style.pattern, ink: style.bodySecondary)
            }
            if let particle = style.particle, particle != .steam {
                ParticleEmitter(kind: particle, running: animate)
            }
            if style.theme == .space {
                StarLayer(animate: animate)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Deterministic pseudo-random numbers so patterns stay put between frames.
struct SeededRandom {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

struct BodyPattern: View {
    let pattern: ThemePattern
    let ink: Color

    var body: some View {
        Canvas { context, size in
            var random = SeededRandom(7)
            switch pattern {
            case .none:
                break

            case .snow:
                let count = Int(size.width * size.height / 1400)
                for _ in 0..<count {
                    let r = 0.6 + random.next() * 1.4
                    let rect = CGRect(x: random.next() * size.width, y: random.next() * size.height, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.12 + random.next() * 0.22)))
                }

            case .retroGrid:
                let horizon = size.height * 0.52
                let color = Color(hex: 0xFF6AD5)
                var lines = Path()
                for i in 1...9 {
                    let t = Double(i) / 9
                    let y = horizon + (size.height - horizon) * t * t
                    lines.move(to: CGPoint(x: 0, y: y))
                    lines.addLine(to: CGPoint(x: size.width, y: y))
                }
                let vanishing = CGPoint(x: size.width / 2, y: horizon - 40)
                for i in -10...10 {
                    let x = size.width / 2 + Double(i) * size.width / 9
                    let start = CGPoint(x: vanishing.x + (x - vanishing.x) * 40 / (horizon - vanishing.y + 40), y: horizon)
                    lines.move(to: start)
                    lines.addLine(to: CGPoint(x: vanishing.x + (x - vanishing.x) * 2.4, y: size.height))
                }
                context.stroke(lines, with: .color(color.opacity(0.22)), lineWidth: 1)
                var glow = Path()
                glow.move(to: CGPoint(x: 0, y: horizon))
                glow.addLine(to: CGPoint(x: size.width, y: horizon))
                context.stroke(glow, with: .color(color.opacity(0.45)), lineWidth: 1.2)

            case .nebula:
                let blobs: [(CGPoint, CGFloat, Color)] = [
                    (CGPoint(x: 0.18, y: 0.3), 0.55, Color(hex: 0x7B3FE4).opacity(0.38)),
                    (CGPoint(x: 0.82, y: 0.55), 0.5, Color(hex: 0x2D6BFF).opacity(0.28)),
                    (CGPoint(x: 0.45, y: 0.95), 0.45, Color(hex: 0xE040A0).opacity(0.22)),
                ]
                for (center, radius, color) in blobs {
                    let c = CGPoint(x: center.x * size.width, y: center.y * size.height)
                    let r = radius * max(size.width, size.height)
                    context.fill(
                        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(Gradient(colors: [color, color.opacity(0)]), center: c, startRadius: 0, endRadius: r)
                    )
                }

            case .waves:
                for i in 0..<4 {
                    let baseY = size.height * (0.35 + Double(i) * 0.17)
                    var wave = Path()
                    wave.move(to: CGPoint(x: 0, y: baseY))
                    let step: CGFloat = 6
                    var x: CGFloat = 0
                    while x <= size.width + step {
                        wave.addLine(to: CGPoint(x: x, y: baseY + sin(x / 34 + Double(i) * 1.3) * 5))
                        x += step
                    }
                    context.stroke(wave, with: .color(ink.opacity(0.09)), lineWidth: 1.5)
                }

            case .woodGrain:
                var y: CGFloat = 4
                var row = 0
                while y < size.height {
                    var grain = Path()
                    grain.move(to: CGPoint(x: 0, y: y))
                    let phase = random.next() * 10
                    let amplitude = 0.8 + random.next() * 2
                    var x: CGFloat = 0
                    while x <= size.width + 8 {
                        grain.addLine(to: CGPoint(x: x, y: y + sin(x / 60 + phase) * amplitude))
                        x += 8
                    }
                    let color: Color = row % 3 == 0 ? .white.opacity(0.035) : .black.opacity(0.09)
                    context.stroke(grain, with: .color(color), lineWidth: 1 + random.next())
                    y += 5 + random.next() * 9
                    row += 1
                }

            case .sandRakes:
                var rakes = context
                let center = CGPoint(x: size.width * 0.2, y: size.height * 0.3)
                var y: CGFloat = 3
                while y < size.height {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    var x: CGFloat = 0
                    while x <= size.width + 8 {
                        line.addLine(to: CGPoint(x: x, y: y + sin(x / 50) * 1.5))
                        x += 8
                    }
                    rakes.stroke(line, with: .color(ink.opacity(0.13)), lineWidth: 0.8)
                    y += 6
                }
                rakes.blendMode = .clear
                rakes.fill(Path(ellipseIn: CGRect(x: center.x - 48, y: center.y - 48, width: 96, height: 96)), with: .color(.black))
                for r in stride(from: CGFloat(14), through: 46, by: 6) {
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: .color(ink.opacity(0.13)), lineWidth: 0.8)
                }
                context.fill(Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 6, width: 16, height: 12)), with: .color(ink.opacity(0.18)))

            case .scanlines:
                var lines = Path()
                var y: CGFloat = 0
                while y < size.height {
                    lines.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                    y += 3
                }
                context.fill(lines, with: .color(.black.opacity(0.22)))
                let colors = [Color(hex: 0x3DF0FF), Color(hex: 0xFF3E8A), Color(hex: 0xFFE45C)]
                let count = Int(size.width * size.height / 5000)
                for i in 0..<count {
                    let x = (random.next() * size.width / 3).rounded() * 3
                    let y = (random.next() * size.height / 3).rounded() * 3
                    context.fill(Path(CGRect(x: x, y: y, width: 3, height: 3)), with: .color(colors[i % 3].opacity(0.35)))
                }

            case .sparkles:
                let count = Int(size.width * size.height / 4500)
                for _ in 0..<count {
                    let c = CGPoint(x: random.next() * size.width, y: random.next() * size.height)
                    let r = 1.5 + random.next() * 2.5
                    context.fill(Self.sparkle(at: c, radius: r), with: .color(ink.opacity(0.18 + random.next() * 0.2)))
                }
            }
        }
    }

    static func sparkle(at c: CGPoint, radius r: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
        return path
    }
}

/// Space's star field: three fixed groups of stars that fade in and out at different
/// rates while animating.
struct StarLayer: View {
    var animate = false
    /// Previews draw the stars directly rather than in their own layers.
    var live = true

    var body: some View {
        ZStack {
            ForEach(0..<3) { group in
                if live {
                    PulsingImage(running: animate, period: 9 - Double(group) * 2.5, phase: Double(group) * 0.33, lowest: 0.15, still: 0.85) {
                        StarGroup(group: group)
                    }
                } else {
                    StarGroup(group: group).opacity(0.85)
                }
            }
        }
    }
}

private struct StarGroup: View {
    let group: Int

    var body: some View {
        Canvas { context, size in
            var random = SeededRandom(42)
            let count = Int(size.width * size.height / 900)
            for index in 0..<count {
                let c = CGPoint(x: random.next() * size.width, y: random.next() * size.height)
                let alpha = 0.35 + random.next() * 0.6
                let big = random.next() > 0.9
                let r = 0.5 + random.next() * 0.9
                guard index % 3 == group else { continue }
                if big {
                    context.fill(BodyPattern.sparkle(at: c, radius: 3.2), with: .color(.white.opacity(alpha)))
                } else {
                    context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(alpha)))
                }
            }
        }
    }
}

// MARK: Border

struct ThemeBorderView: View {
    let border: ThemeBorder
    let cornerRadius: CGFloat
    /// Fences and the toolbar draw the rainbow in its own layer so it can travel. Previews
    /// and the search list use a still one.
    var live = false
    var animate = false

    static let rainbow: [Color] = [
        Color(hex: 0xFF3B5C), Color(hex: 0xFF9F1C), Color(hex: 0xFFE14D), Color(hex: 0x3BE37A),
        Color(hex: 0x2BD9FF), Color(hex: 0x4F6BFF), Color(hex: 0xC04DFF), Color(hex: 0xFF3B5C),
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        Group {
            switch border {
            case .line(let color):
                shape.strokeBorder(color, lineWidth: 1)
            case .glow(let color):
                ZStack {
                    shape.strokeBorder(color.opacity(0.5), lineWidth: 6).blur(radius: 4)
                    shape.strokeBorder(color.opacity(0.9), lineWidth: 1.5)
                }
                .clipShape(shape)
            case .rainbow:
                if live {
                    RainbowBorderLayer(cornerRadius: cornerRadius, running: animate)
                } else {
                    RainbowBorder(cornerRadius: cornerRadius)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct RainbowBorder: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let gradient = AngularGradient(colors: ThemeBorderView.rainbow, center: .center)
        ZStack {
            shape.strokeBorder(gradient, lineWidth: 9).blur(radius: 6).opacity(0.8)
            shape.strokeBorder(gradient, lineWidth: 2.5)
        }
        .clipShape(shape)
    }
}

// MARK: Corner

/// The theme's corner illustration: pure decoration in the body's bottom-trailing corner.
struct CornerArt: View {
    let style: ThemeStyle
    let area: CGSize
    let animate: Bool
    /// Height the grid above keeps for a row of icons.
    var minimumGrid = FenceMetrics.baseMinimumGridHeight

    static let padding: CGFloat = 3
    /// Width at an `artScale` of 1, and the tallest the art gets.
    static let baseWidth: CGFloat = 130
    static let maxHeight: CGFloat = 110

    /// Shrinks on small fences so the grid above it keeps room for a row of icons, and isn't
    /// drawn at all when it would be too small to make out.
    static func size(for style: ThemeStyle, area: CGSize, minimumGrid: CGFloat = FenceMetrics.baseMinimumGridHeight) -> CGSize? {
        guard let name = style.cornerArt, let image = ThemeArt.image(name), image.size.width > 0 else { return nil }
        let aspect = image.size.height / image.size.width
        var width = min(baseWidth * style.artScale, area.width * 0.45)
        var height = width * aspect
        let maxHeight = min(Self.maxHeight, area.height - minimumGrid - padding)
        if height > maxHeight {
            height = maxHeight
            width = height / aspect
        }
        guard height >= 32 else { return nil }
        return CGSize(width: width, height: height)
    }

    var body: some View {
        if let name = style.cornerArt, let image = ThemeArt.image(name),
           let size = Self.size(for: style, area: area, minimumGrid: minimumGrid) {
            Image(nsImage: image)
                .resizable()
                .interpolation(style.theme == .arcade ? .none : .high)
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .overlay(alignment: .topLeading) {
                    if style.particle == .steam {
                        // Rises from the coffee in the Cozy Cafe illustration.
                        ParticleEmitter(kind: .steam, running: animate)
                            .frame(width: size.width * 0.3, height: size.height * 0.6)
                            .offset(x: size.width * 0.48, y: -size.height * 0.5)
                    }
                }
                .padding(Self.padding)
                .allowsHitTesting(false)
        }
    }
}

// MARK: Title accents

struct TitleAccentView: View {
    let accent: TitleAccent
    let animate: Bool

    var body: some View {
        switch accent {
        case .none:
            EmptyView()
        case .leaves:
            if let leaf = ThemeArt.image("fall_leaf") {
                GeometryReader { geo in
                    let image = Image(nsImage: leaf).resizable().interpolation(.high)
                    image.frame(width: 15, height: 15).rotationEffect(.degrees(-28)).position(x: 38, y: 9)
                    image.frame(width: 11, height: 11).rotationEffect(.degrees(40)).position(x: 51, y: 20)
                    image.frame(width: 14, height: 14).rotationEffect(.degrees(22)).position(x: geo.size.width - 40, y: 10)
                }
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
        case .lights:
            StringLights(animate: animate)
        }
    }
}

/// Christmas string lights along the top of the title bar. Each color is its own layer
/// that fades in and out in turn.
struct StringLights: View {
    let animate: Bool

    static let colors = [Color(hex: 0xFF4D4D), Color(hex: 0xFFD24A), Color(hex: 0x4CE07A), Color(hex: 0x5AB8FF)]
    static let spacing: CGFloat = 24

    static func wireY(_ x: CGFloat) -> CGFloat {
        let segment = spacing * 2
        let t = x.truncatingRemainder(dividingBy: segment) / segment
        return 1.5 + 5 * 4 * t * (1 - t)
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                var wire = Path()
                wire.move(to: CGPoint(x: 0, y: Self.wireY(0)))
                var x: CGFloat = 0
                while x <= size.width {
                    wire.addLine(to: CGPoint(x: x, y: Self.wireY(x)))
                    x += 2
                }
                context.stroke(wire, with: .color(Color(hex: 0x1F3A24).opacity(0.9)), lineWidth: 1)
            }
            ForEach(0..<Self.colors.count, id: \.self) { group in
                PulsingImage(running: animate, period: 3.5, phase: Double(group) * 0.25, lowest: 0.45) {
                    BulbGroup(group: group)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct BulbGroup: View {
    let group: Int

    var body: some View {
        let color = StringLights.colors[group]
        Canvas { context, size in
            var index = 0
            var x = StringLights.spacing / 2
            while x < size.width {
                defer {
                    x += StringLights.spacing
                    index += 1
                }
                guard index % StringLights.colors.count == group else { continue }
                let y = StringLights.wireY(x) + 1
                var glow = context
                glow.addFilter(.blur(radius: 3))
                glow.fill(Path(ellipseIn: CGRect(x: x - 5, y: y - 1, width: 10, height: 10)), with: .color(color.opacity(0.6)))
                context.fill(Path(CGRect(x: x - 1.5, y: y - 1, width: 3, height: 2)), with: .color(Color(hex: 0x2B2B2B)))
                context.fill(Path(ellipseIn: CGRect(x: x - 2.4, y: y + 0.5, width: 4.8, height: 6.5)), with: .color(color))
            }
        }
    }
}

// MARK: Previews

/// A tiny fence drawn from a style, for the theme pickers.
struct ThemePreview: View {
    let style: ThemeStyle

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let shape = RoundedRectangle(cornerRadius: max(4, w * 0.07))
            VStack(spacing: 0) {
                ZStack {
                    ThemeFillView(fill: style.titleBar)
                    Capsule().fill(style.titleText.opacity(0.85)).frame(width: w * 0.34, height: max(2, h * 0.055))
                }
                .frame(height: h * 0.2)
                HStack(spacing: w * 0.03) {
                    Capsule().fill(style.tabPill).frame(width: w * 0.24, height: h * 0.1)
                    Capsule().fill(style.tabText.opacity(0.6)).frame(width: w * 0.14, height: h * 0.035)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, w * 0.05)
                .frame(height: h * 0.15)
                .frame(maxWidth: .infinity)
                .background(style.tabStrip)
                ZStack(alignment: .bottomTrailing) {
                    previewBody
                    if style.pattern != .none {
                        BodyPattern(pattern: style.pattern, ink: style.bodySecondary)
                    }
                    if style.theme == .space { StarLayer(live: false) }
                    HStack(alignment: .top, spacing: w * 0.06) {
                        ForEach(0..<3) { _ in
                            RoundedRectangle(cornerRadius: w * 0.025)
                                .fill(style.bodyText.opacity(0.3))
                                .frame(width: w * 0.14, height: w * 0.14)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(w * 0.07)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if let name = style.cornerArt, let image = ThemeArt.image(name) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: w * 0.5, maxHeight: h * 0.42, alignment: .bottomTrailing)
                            .padding(w * 0.02)
                    }
                }
            }
            .clipShape(shape)
            .overlay(ThemeBorderView(border: style.border, cornerRadius: max(4, w * 0.07)))
        }
    }

    /// See-through bodies are shown over a sample wallpaper.
    @ViewBuilder private var previewBody: some View {
        if style.isSeeThrough {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x3A6FD8), Color(hex: 0x9A4FD0), Color(hex: 0xF08A5D)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if case .glass = style.body {
                    Color.white.opacity(0.18)
                    Color(hex: 0x30333A).opacity(0.45)
                } else {
                    ThemeFillView(fill: style.body).opacity(style.bodyOpacity)
                }
            }
        } else {
            ThemeFillView(fill: style.body)
        }
    }
}
