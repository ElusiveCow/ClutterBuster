import AppKit
import SwiftUI

// Theme animations run as Core Animation layer animations at a low frame rate. SwiftUI only
// draws each still once, so a ticking animation never redraws the rest of the fence.

private let slowFrameRate = CAFrameRateRange(minimum: 4, maximum: 10, preferred: 8)

@MainActor
private func renderImage<V: View>(_ view: V, size: CGSize, scale: CGFloat) -> CGImage? {
    guard size.width >= 1, size.height >= 1 else { return nil }
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = scale
    return renderer.cgImage
}

/// Pauses or resumes every animation on a layer, keeping its place.
private extension CALayer {
    func setPaused(_ paused: Bool) {
        if paused {
            guard speed != 0 else { return }
            let now = convertTime(CACurrentMediaTime(), from: nil)
            speed = 0
            timeOffset = now
        } else {
            guard speed == 0 else { return }
            let pausedAt = timeOffset
            speed = 1
            timeOffset = 0
            beginTime = 0
            beginTime = convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        }
    }
}

/// Base for views that draw SwiftUI content once per size and animate it in Core Animation.
class LayerAnimationView: NSView {
    var isRunning = false {
        didSet { if isRunning != oldValue { runningChanged() } }
    }
    private var renderedSize: CGSize = .zero
    private var renderedScale: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers()
        if bounds.size != renderedSize || scale != renderedScale {
            renderedSize = bounds.size
            renderedScale = scale
            render(scale: scale)
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    func layoutLayers() {}
    func render(scale: CGFloat) {}
    func runningChanged() {}
}

// MARK: Pulse

/// SwiftUI content shown as a still whose opacity rises and falls while running.
struct PulsingImage<Content: View>: NSViewRepresentable {
    let running: Bool
    /// Seconds for one full fade out and back.
    let period: Double
    /// Where in the cycle this one starts, from 0 to 1, so groups twinkle in turn.
    var phase: Double = 0
    var lowest: Float = 0.4
    /// Opacity while paused.
    var still: Float = 1
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> PulseView { PulseView() }

    func updateNSView(_ view: PulseView, context: Context) {
        view.draw = { size, scale in renderImage(content(), size: size, scale: scale) }
        view.pulse = (period, phase, lowest, still)
        view.isRunning = running
    }
}

final class PulseView: LayerAnimationView {
    var draw: ((CGSize, CGFloat) -> CGImage?)?
    var pulse: (period: Double, phase: Double, lowest: Float, still: Float) = (4, 0, 0.4, 1)
    private let sprite = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(sprite)
    }

    override func layoutLayers() { sprite.frame = bounds }

    override func render(scale: CGFloat) {
        sprite.contentsScale = scale
        sprite.contents = draw?(bounds.size, scale)
        if sprite.animation(forKey: "pulse") == nil { runningChanged() }
    }

    override func runningChanged() {
        sprite.opacity = pulse.still
        guard isRunning else {
            sprite.removeAnimation(forKey: "pulse")
            return
        }
        guard sprite.animation(forKey: "pulse") == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = pulse.lowest
        animation.duration = pulse.period / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.beginTime = CACurrentMediaTime() - pulse.phase * pulse.period
        animation.preferredFrameRateRange = slowFrameRate
        sprite.add(animation, forKey: "pulse")
    }
}

// MARK: Blink

/// SwiftUI content shown as a still that's hidden except for brief flashes while running:
/// once partway through each `period`, then twice in quick succession near its end.
struct BlinkingImage<Content: View>: NSViewRepresentable {
    let running: Bool
    var period: Double = 9
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> BlinkView { BlinkView() }

    func updateNSView(_ view: BlinkView, context: Context) {
        view.draw = { size, scale in renderImage(content(), size: size, scale: scale) }
        view.period = period
        view.isRunning = running
    }
}

final class BlinkView: LayerAnimationView {
    var draw: ((CGSize, CGFloat) -> CGImage?)?
    var period: Double = 9
    private let sprite = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        sprite.opacity = 0
        layer?.addSublayer(sprite)
    }

    override func layoutLayers() { sprite.frame = bounds }

    override func render(scale: CGFloat) {
        sprite.contentsScale = scale
        sprite.contents = draw?(bounds.size, scale)
        if sprite.animation(forKey: "blink") == nil { runningChanged() }
    }

    override func runningChanged() {
        guard isRunning else {
            sprite.removeAnimation(forKey: "blink")
            return
        }
        guard sprite.animation(forKey: "blink") == nil else { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        // Discrete animations hold each value until the next key time, so there's one extra.
        animation.values = [0, 1, 0, 1, 0, 1, 0]
        animation.keyTimes = [0, 0.4, 0.42, 0.9, 0.92, 0.94, 0.96, 1]
        animation.calculationMode = .discrete
        animation.duration = period
        animation.repeatCount = .infinity
        // Fast enough that a blink of a fifth of a second always lands on a frame.
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)
        sprite.add(animation, forKey: "blink")
    }
}

// MARK: Rainbow border

/// RGB's border: a rainbow ring with a soft glow whose colors travel around the fence.
struct RainbowBorderLayer: NSViewRepresentable {
    let cornerRadius: CGFloat
    let running: Bool

    func makeNSView(context: Context) -> RainbowView { RainbowView(cornerRadius: cornerRadius) }

    func updateNSView(_ view: RainbowView, context: Context) {
        view.isRunning = running
    }
}

final class RainbowView: LayerAnimationView {
    private let cornerRadius: CGFloat
    private let ring = CALayer()
    private let ringMask = CALayer()
    private let gradient = CAGradientLayer()

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        gradient.type = .conic
        gradient.colors = ThemeBorderView.rainbow.map { NSColor($0).cgColor }
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        ring.addSublayer(gradient)
        ring.mask = ringMask
        layer?.addSublayer(ring)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 20
        spin.repeatCount = .infinity
        spin.preferredFrameRateRange = slowFrameRate
        gradient.add(spin, forKey: "spin")
        gradient.setPaused(true)
    }

    override func layoutLayers() {
        ring.frame = bounds
        ringMask.frame = bounds
        // Big enough to cover the ring at any angle.
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func render(scale: CGFloat) {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let mask = ZStack {
            shape.strokeBorder(.white, lineWidth: 9).blur(radius: 6).opacity(0.8)
            shape.strokeBorder(.white, lineWidth: 2.5)
        }
        .clipShape(shape)
        ringMask.contentsScale = scale
        ringMask.contents = renderImage(mask, size: bounds.size, scale: scale)
    }

    override func runningChanged() {
        gradient.setPaused(!isRunning)
    }
}
