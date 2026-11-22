import AppKit
import SwiftUI

/// Occasional drifting leaves, snowflakes, petals, bubbles or steam. Each particle is a
/// Core Animation layer with one low-frame-rate animation, and nothing redraws between
/// particles. Stopping lets the ones in flight finish and launches no more.
struct ParticleEmitter: NSViewRepresentable {
    let kind: ThemeParticle
    let running: Bool

    func makeNSView(context: Context) -> EmitterView {
        EmitterView(kind: kind)
    }

    func updateNSView(_ view: EmitterView, context: Context) {
        view.isRunning = running
    }
}

final class EmitterView: NSView {
    private let kind: ThemeParticle
    private let image: CGImage?
    private var timer: Timer?

    var isRunning = false {
        didSet {
            guard isRunning != oldValue else { return }
            if isRunning { scheduleNext(initial: true) } else { stop() }
        }
    }

    init(kind: ThemeParticle) {
        self.kind = kind
        image = Self.image(for: kind)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else if isRunning, timer == nil { scheduleNext(initial: true) }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Seconds between particles, on average.
    private var interval: Double {
        switch kind {
        case .leaves: 9
        case .snow: 2.6
        case .petals: 7
        case .bubbles: 3.5
        case .steam: 0.9
        }
    }

    private func scheduleNext(initial: Bool = false) {
        stop()
        guard isRunning, window != nil else { return }
        let wait = initial ? Double.random(in: 0.3...interval) : interval * Double.random(in: 0.6...1.4)
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.launch()
                self?.scheduleNext()
            }
        }
        timer.tolerance = wait * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Particles

    private func launch() {
        guard let host = layer, let image, bounds.width > 20, bounds.height > 20 else { return }
        let size = bounds.size
        let scale = CGFloat.random(in: kind == .steam ? 0.9...1.1 : 0.7...1.2)
        let sprite = CALayer()
        sprite.contents = image
        sprite.contentsScale = 2
        sprite.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / 2 * scale, height: CGFloat(image.height) / 2 * scale)
        sprite.opacity = 0

        // Layer coordinates run bottom-up.
        let path = CGMutablePath()
        let duration: Double
        var spin = Double.random(in: -2.5...2.5)
        var peakOpacity: Float = 1
        var growth: CGFloat = 1
        switch kind {
        case .leaves, .snow, .petals:
            let speed: CGFloat = kind == .snow ? .random(in: 16...26) : .random(in: 24...34)
            let start = CGPoint(x: .random(in: 0...size.width), y: size.height + 10)
            let fall = size.height + 20
            let sway: CGFloat = kind == .snow ? 10 : 22
            let drift = CGFloat.random(in: -30...30)
            path.move(to: start)
            let waves = 3
            for wave in 1...waves {
                let t = CGFloat(wave) / CGFloat(waves)
                let end = CGPoint(x: start.x + drift * t, y: start.y - fall * t)
                let side: CGFloat = wave % 2 == 0 ? -1 : 1
                let mid = CGPoint(x: start.x + drift * (t - 0.5 / CGFloat(waves)) + sway * side, y: start.y - fall * (t - 0.5 / CGFloat(waves)))
                path.addQuadCurve(to: end, control: mid)
            }
            duration = Double(fall / speed)
            if kind == .snow { spin = 0; peakOpacity = .random(in: 0.55...0.95) }
        case .bubbles:
            let start = CGPoint(x: .random(in: 10...max(11, size.width - 10)), y: -8)
            let rise = size.height * .random(in: 0.55...0.85)
            path.move(to: start)
            path.addQuadCurve(to: CGPoint(x: start.x + .random(in: -12...12), y: start.y + rise), control: CGPoint(x: start.x + .random(in: -14...14), y: start.y + rise / 2))
            duration = Double(rise / .random(in: 22...30))
            spin = 0
            peakOpacity = 0.85
        case .steam:
            let start = CGPoint(x: size.width / 2 + .random(in: -size.width * 0.2...size.width * 0.2), y: 0)
            path.move(to: start)
            path.addQuadCurve(to: CGPoint(x: start.x + .random(in: -8...8), y: size.height), control: CGPoint(x: start.x + .random(in: -10...10), y: size.height / 2))
            duration = .random(in: 2.4...3)
            spin = 0
            peakOpacity = 0.3
            growth = 1.8
        }

        let position = CAKeyframeAnimation(keyPath: "position")
        position.path = path
        position.calculationMode = .paced
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        let startAngle = Double.random(in: 0...(2 * .pi))
        rotation.fromValue = startAngle
        rotation.toValue = startAngle + spin
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = growth
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, peakOpacity, peakOpacity, 0]
        fade.keyTimes = kind == .steam ? [0, 0.2, 0.4, 1] : [0, 0.08, 0.85, 1]

        let group = CAAnimationGroup()
        group.animations = [position, rotation, grow, fade]
        group.duration = duration
        // Slow drift reads fine at a low frame rate and costs far less to composite.
        group.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { sprite.removeFromSuperlayer() }
        host.addSublayer(sprite)
        sprite.add(group, forKey: "drift")
        CATransaction.commit()
    }

    // MARK: Particle images, drawn at 2x

    private static func image(for kind: ThemeParticle) -> CGImage? {
        switch kind {
        case .leaves: leafImage()
        case .snow: dotImage(diameter: 6)
        case .petals: petalImage()
        case .bubbles: bubbleImage()
        case .steam: dotImage(diameter: 14)
        }
    }

    private static func image(size: CGSize, draw: (CGContext) -> Void) -> CGImage? {
        let context = CGContext(
            data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return nil }
        context.scaleBy(x: 2, y: 2)
        draw(context)
        return context.makeImage()
    }

    private static func leafImage() -> CGImage? {
        guard let leaf = ThemeArt.image("fall_leaf") else { return nil }
        return image(size: CGSize(width: 16, height: 16)) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            leaf.draw(in: CGRect(x: 0, y: 0, width: 16, height: 16))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func dotImage(diameter: CGFloat) -> CGImage? {
        image(size: CGSize(width: diameter, height: diameter)) { context in
            let center = CGPoint(x: diameter / 2, y: diameter / 2)
            let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0.35, 1])!
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: diameter / 2, options: [])
        }
    }

    private static func petalImage() -> CGImage? {
        image(size: CGSize(width: 9, height: 6)) { context in
            context.addEllipse(in: CGRect(x: 0, y: 0, width: 9, height: 6))
            context.clip()
            let colors = [NSColor(Color(hex: 0xFFC4D6)).cgColor, NSColor(Color(hex: 0xF58FB0)).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 9, y: 0), options: [])
        }
    }

    private static func bubbleImage() -> CGImage? {
        image(size: CGSize(width: 12, height: 12)) { context in
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.75))
            context.setLineWidth(1)
            context.strokeEllipse(in: CGRect(x: 0.5, y: 0.5, width: 11, height: 11))
            context.setFillColor(CGColor(gray: 1, alpha: 0.6))
            context.fillEllipse(in: CGRect(x: 3, y: 6.5, width: 3, height: 2.4))
        }
    }
}
