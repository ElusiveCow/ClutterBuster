#!/usr/bin/env swift
// Renders the 1024×1024 app icon master to Resources/AppIcon-1024.png.
// Usage: swift scripts/make-icon.swift [output.png]
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon-1024.png"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    rgb(CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255, a)
}

/// Apple-style continuous-corner rounded rect ("squircle"); `r` is the nominal corner radius.
func squircle(in rect: CGRect, radius r: CGFloat = 185.4) -> CGPath {
    let a: CGFloat = 1.52866483
    // Corner curve in local coordinates (distance from the corner along each edge), in units of r.
    let segments: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: 1.08849323, y: 0), CGPoint(x: 0.86840689, y: 0), CGPoint(x: 0.63149399, y: 0.07491100)),
        (CGPoint(x: 0.37282392, y: 0.16905899), CGPoint(x: 0.16905899, y: 0.37282392), CGPoint(x: 0.07491100, y: 0.63149399)),
        (CGPoint(x: 0, y: 0.86840689), CGPoint(x: 0, y: 1.08849323), CGPoint(x: 0, y: a)),
    ]
    let path = CGMutablePath()
    func corner(_ c: CGPoint, _ sx: CGFloat, _ sy: CGFloat, xFirst: Bool) {
        func map(_ p: CGPoint) -> CGPoint {
            let q = xFirst ? p : CGPoint(x: p.y, y: p.x)
            return CGPoint(x: c.x + sx * q.x * r, y: c.y + sy * q.y * r)
        }
        for (c1, c2, end) in segments { path.addCurve(to: map(end), control1: map(c1), control2: map(c2)) }
    }
    path.move(to: CGPoint(x: rect.minX + a * r, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - a * r, y: rect.minY))
    corner(CGPoint(x: rect.maxX, y: rect.minY), -1, 1, xFirst: true)
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - a * r))
    corner(CGPoint(x: rect.maxX, y: rect.maxY), -1, -1, xFirst: false)
    path.addLine(to: CGPoint(x: rect.minX + a * r, y: rect.maxY))
    corner(CGPoint(x: rect.minX, y: rect.maxY), 1, -1, xFirst: true)
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + a * r))
    corner(CGPoint(x: rect.minX, y: rect.minY), 1, 1, xFirst: false)
    path.closeSubpath()
    return path
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

// MARK: Body (824×824 centered, standard macOS grid)

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = squircle(in: body)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0, 0, 0, 0.32))
ctx.addPath(bodyPath)
ctx.setFillColor(hex(0x6FA3E8))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
// Soft "desktop wallpaper" gradient: sky blue at the top fading to warm lavender/peach.
linearGradient(ctx, [hex(0x7DB5F2), hex(0xA9B9F0), hex(0xF1C2D6)],
               from: CGPoint(x: 300, y: 924), to: CGPoint(x: 724, y: 100))
// Gentle glow in the upper left.
let glow = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 0.35), rgb(1, 1, 1, 0)] as CFArray, locations: nil)!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 280, y: 860), startRadius: 0,
                       endCenter: CGPoint(x: 280, y: 860), endRadius: 560, options: [])
ctx.restoreGState()

// MARK: Fences

struct Panel {
    var rect: CGRect
    var top: CGColor
    var bottom: CGColor
    var bar: CGColor
}

let titleBar: CGFloat = 64
let corner: CGFloat = 40

func drawPanel(_ p: Panel) {
    let path = roundedRect(p.rect, corner)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0.10, 0.12, 0.30, 0.35))
    ctx.addPath(path)
    ctx.setFillColor(p.bottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    linearGradient(ctx, [p.top, p.bottom], from: CGPoint(x: p.rect.midX, y: p.rect.maxY),
                   to: CGPoint(x: p.rect.midX, y: p.rect.minY))
    // Title bar.
    let bar = CGRect(x: p.rect.minX, y: p.rect.maxY - titleBar, width: p.rect.width, height: titleBar)
    ctx.setFillColor(p.bar)
    ctx.fill(bar)
    ctx.setFillColor(rgb(1, 1, 1, 0.18))
    ctx.fill(CGRect(x: bar.minX, y: bar.minY - 2, width: bar.width, height: 2))
    // Title placeholder.
    let pillW = min(p.rect.width * 0.42, 150)
    ctx.addPath(roundedRect(CGRect(x: p.rect.midX - pillW / 2, y: bar.midY - 9, width: pillW, height: 18), 9))
    ctx.setFillColor(rgb(1, 1, 1, 0.85))
    ctx.fillPath()
    ctx.restoreGState()

    // Hairline highlight around the panel.
    ctx.saveGState()
    ctx.addPath(roundedRect(p.rect.insetBy(dx: 1.5, dy: 1.5), corner - 1.5))
    ctx.setStrokeColor(rgb(1, 1, 1, 0.45))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
}

/// A small white document with a folded corner and a colored label stripe.
func drawDocument(center: CGPoint, width w: CGFloat, accent: CGColor) {
    let h = w * 1.28
    let r = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    let fold = w * 0.32
    let path = CGMutablePath()
    path.move(to: CGPoint(x: r.minX + 8, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX - 8, y: r.minY))
    path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + 8), control: CGPoint(x: r.maxX, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
    path.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY))
    path.addLine(to: CGPoint(x: r.minX + 8, y: r.maxY))
    path.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - 8), control: CGPoint(x: r.minX, y: r.maxY))
    path.addLine(to: CGPoint(x: r.minX, y: r.minY + 8))
    path.addQuadCurve(to: CGPoint(x: r.minX + 8, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
    path.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: rgb(0, 0, 0.2, 0.30))
    ctx.addPath(path)
    ctx.setFillColor(rgb(1, 1, 1, 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Folded corner.
    let ear = CGMutablePath()
    ear.move(to: CGPoint(x: r.maxX - fold, y: r.maxY))
    ear.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY - fold + 6))
    ear.addQuadCurve(to: CGPoint(x: r.maxX - fold + 6, y: r.maxY - fold), control: CGPoint(x: r.maxX - fold, y: r.maxY - fold))
    ear.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
    ear.closeSubpath()
    ctx.addPath(ear)
    ctx.setFillColor(hex(0xD5DCEA))
    ctx.fillPath()

    // Text lines + accent stripe.
    let lineX = r.minX + w * 0.18
    let lineW = w * 0.64
    ctx.setFillColor(accent)
    ctx.addPath(roundedRect(CGRect(x: lineX, y: r.minY + h * 0.56, width: lineW * 0.7, height: h * 0.075), h * 0.037))
    ctx.fillPath()
    ctx.setFillColor(hex(0xC3CCDC))
    for (i, f) in [1.0, 0.85, 1.0].enumerated() {
        let y = r.minY + h * (0.40 - CGFloat(i) * 0.12)
        ctx.addPath(roundedRect(CGRect(x: lineX, y: y, width: lineW * f, height: h * 0.055), h * 0.027))
        ctx.fillPath()
    }
}

/// A small folder glyph.
func drawFolder(center: CGPoint, width w: CGFloat, color: CGColor, light: CGColor) {
    let h = w * 0.80
    let r = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    let tab = CGRect(x: r.minX, y: r.maxY - h * 0.22, width: w * 0.45, height: h * 0.22)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: rgb(0, 0, 0.2, 0.30))
    ctx.addPath(roundedRect(tab, 8))
    ctx.addPath(roundedRect(CGRect(x: r.minX, y: r.minY, width: w, height: h * 0.88), 10))
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(roundedRect(CGRect(x: r.minX, y: r.minY, width: w, height: h * 0.74), 10))
    ctx.clip()
    linearGradient(ctx, [light, color], from: CGPoint(x: r.midX, y: r.minY + h * 0.74), to: CGPoint(x: r.midX, y: r.minY))
    ctx.restoreGState()
}

/// A small photo thumbnail (landscape with sun and hills).
func drawPhoto(center: CGPoint, width w: CGFloat) {
    let h = w * 0.82
    let r = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: rgb(0, 0, 0.2, 0.30))
    ctx.addPath(roundedRect(r, 10))
    ctx.setFillColor(rgb(1, 1, 1))
    ctx.fillPath()
    ctx.restoreGState()
    let inner = r.insetBy(dx: 7, dy: 7)
    ctx.saveGState()
    ctx.addPath(roundedRect(inner, 5))
    ctx.clip()
    linearGradient(ctx, [hex(0x9FD3FF), hex(0xE8F4FF)], from: CGPoint(x: inner.midX, y: inner.maxY), to: CGPoint(x: inner.midX, y: inner.minY))
    ctx.setFillColor(hex(0xFFC24D))
    ctx.fillEllipse(in: CGRect(x: inner.maxX - inner.width * 0.36, y: inner.maxY - inner.height * 0.42, width: inner.width * 0.22, height: inner.width * 0.22))
    let hill = CGMutablePath()
    hill.move(to: CGPoint(x: inner.minX, y: inner.minY))
    hill.addLine(to: CGPoint(x: inner.minX, y: inner.minY + inner.height * 0.30))
    hill.addLine(to: CGPoint(x: inner.minX + inner.width * 0.38, y: inner.minY + inner.height * 0.62))
    hill.addLine(to: CGPoint(x: inner.minX + inner.width * 0.62, y: inner.minY + inner.height * 0.36))
    hill.addLine(to: CGPoint(x: inner.minX + inner.width * 0.76, y: inner.minY + inner.height * 0.48))
    hill.addLine(to: CGPoint(x: inner.maxX, y: inner.minY + inner.height * 0.22))
    hill.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
    hill.closeSubpath()
    ctx.addPath(hill)
    ctx.setFillColor(hex(0x3FA36B))
    ctx.fillPath()
    ctx.restoreGState()
}

// Palette: brighter takes on the app's ocean / plum / sunset / forest presets.
let ocean = Panel(rect: CGRect(x: 186, y: 206, width: 320, height: 612),
                  top: hex(0x3E8FD8), bottom: hex(0x2368B0), bar: hex(0x1B4F8A))
let plum = Panel(rect: CGRect(x: 538, y: 486, width: 300, height: 332),
                 top: hex(0x9C6CC4), bottom: hex(0x74489C), bar: hex(0x573377))
let sunset = Panel(rect: CGRect(x: 538, y: 206, width: 300, height: 248),
                   top: hex(0xF4955F), bottom: hex(0xDE6A3C), bar: hex(0xB24E2A))

for p in [ocean, plum, sunset] { drawPanel(p) }

// Ocean fence: neat 2×3 grid of documents.
let docW: CGFloat = 92
let oceanContent = CGRect(x: ocean.rect.minX, y: ocean.rect.minY, width: ocean.rect.width, height: ocean.rect.height - titleBar)
let accents = [hex(0x2E86DE), hex(0xEE7B45), hex(0x9B59B6), hex(0x3FA36B), hex(0xE0B12A), hex(0x2E86DE)]
for row in 0..<3 {
    for col in 0..<2 {
        let cx = oceanContent.minX + oceanContent.width * (col == 0 ? 0.28 : 0.72)
        let cy = oceanContent.maxY - oceanContent.height * (0.19 + CGFloat(row) * 0.31)
        drawDocument(center: CGPoint(x: cx, y: cy), width: docW, accent: accents[row * 2 + col])
    }
}

// Plum fence: two photos.
let plumContent = CGRect(x: plum.rect.minX, y: plum.rect.minY, width: plum.rect.width, height: plum.rect.height - titleBar)
drawPhoto(center: CGPoint(x: plumContent.minX + plumContent.width * 0.29, y: plumContent.midY), width: 104)
drawPhoto(center: CGPoint(x: plumContent.minX + plumContent.width * 0.71, y: plumContent.midY), width: 104)

// Sunset fence: two folders (forest + blue accents).
let sunsetContent = CGRect(x: sunset.rect.minX, y: sunset.rect.minY, width: sunset.rect.width, height: sunset.rect.height - titleBar)
drawFolder(center: CGPoint(x: sunsetContent.minX + sunsetContent.width * 0.29, y: sunsetContent.midY),
           width: 104, color: hex(0x2F8F5B), light: hex(0x5CC28A))
drawFolder(center: CGPoint(x: sunsetContent.minX + sunsetContent.width * 0.71, y: sunsetContent.midY),
           width: 104, color: hex(0x2E7CC8), light: hex(0x67B2F2))

// MARK: Glossy rim on the body

ctx.saveGState()
ctx.addPath(squircle(in: body.insetBy(dx: 1.5, dy: 1.5), radius: 184))
ctx.setStrokeColor(rgb(1, 1, 1, 0.30))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// MARK: Write PNG

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: size, height: size)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
