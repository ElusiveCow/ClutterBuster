// Cuts a generated illustration out of its flat background and writes a trimmed PNG with
// transparency, for the theme art in Resources/Themes.
//
//   swift scripts/cutout.swift <input> <output.png> [--bg white|green|magenta] [--holes]
//                              [--flood] [--despill-all] [--sample] [--max 420]
//
// Vision's foreground mask lifts the subject. Edge pixels are then "unmatted" against the
// known background color so no white or green fringe remains. --holes also clears enclosed
// areas that match the background (gaps in monstera leaves, stripes in a sun). --flood uses a
// color key from the borders instead of Vision, for subjects Vision trims too much.
// --despill-all removes background tint from every pixel, not just the edges.
// --sample measures the background from the image's border instead of assuming the pure
// color, for generators that paint green as (0, 243, 12).
// Vision needs the Neural Engine, so run this outside a sandbox.
import AppKit
import CoreImage
import Vision

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: cutout.swift <input> <output.png> [--bg white|green|magenta] [--holes] [--max N]")
    exit(1)
}
let inputURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])
var bgName = "white"
var clearHoles = false
var useFlood = false
var despillAll = false
var sampleBackground = false
var maxSide = 420
var index = 3
while index < args.count {
    switch args[index] {
    case "--bg": index += 1; bgName = args[index]
    case "--holes": clearHoles = true
    case "--flood": useFlood = true
    case "--despill-all": despillAll = true
    case "--sample": sampleBackground = true
    case "--max": index += 1; maxSide = Int(args[index]) ?? maxSide
    default: break
    }
    index += 1
}
var background: (Double, Double, Double) = switch bgName {
case "green": (0, 255, 0)
case "magenta": (255, 0, 255)
default: (255, 255, 255)
}

guard let source = NSImage(contentsOf: inputURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("can't read \(inputURL.path)")
    exit(1)
}
let width = source.width
let height = source.height

func rgbaPixels(_ image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixels
}

var pixels = rgbaPixels(source)

if sampleBackground {
    var sum = (0.0, 0.0, 0.0)
    var count = 0.0
    for x in stride(from: 0, to: width, by: 4) {
        for y in [0, height - 1] {
            let p = (y * width + x) * 4
            sum = (sum.0 + Double(pixels[p]), sum.1 + Double(pixels[p + 1]), sum.2 + Double(pixels[p + 2]))
            count += 1
        }
    }
    background = (sum.0 / count, sum.1 / count, sum.2 / count)
    print("sampled background \(Int(background.0)), \(Int(background.1)), \(Int(background.2))")
}

func distanceToBackground(_ i: Int) -> Double {
    let r = Double(pixels[i]) - background.0
    let g = Double(pixels[i + 1]) - background.1
    let b = Double(pixels[i + 2]) - background.2
    return (r * r + g * g + b * b).squareRoot()
}

/// Alpha from Vision's foreground mask, or nil if Vision finds nothing.
func visionMask() -> [Double]? {
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: source)
    do {
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        let mask = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        var values = [Float](repeating: 0, count: width * height)
        context.render(
            mask, toBitmap: &values, rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .Rf, colorSpace: nil
        )
        return values.map(Double.init)
    } catch {
        print("vision failed: \(error)")
        return nil
    }
}

/// Color-key alpha: transparent near the background color, opaque well away from it.
func keyAlpha(_ i: Int, low: Double, high: Double) -> Double {
    min(max((distanceToBackground(i * 4) - low) / (high - low), 0), 1)
}

/// Color key limited to background-colored pixels connected to the image border, so light
/// areas inside the subject (latte foam, a pale saucer) stay opaque.
func floodKey() -> [Double] {
    var alpha = [Double](repeating: 1, count: width * height)
    var visited = [Bool](repeating: false, count: width * height)
    var queue: [Int] = []
    func push(_ i: Int) {
        guard !visited[i], distanceToBackground(i * 4) < 60 else { return }
        visited[i] = true
        queue.append(i)
    }
    for x in 0..<width { push(x); push((height - 1) * width + x) }
    for y in 0..<height { push(y * width); push(y * width + width - 1) }
    var head = 0
    while head < queue.count {
        let i = queue[head]; head += 1
        alpha[i] = keyAlpha(i, low: 14, high: 60)
        let x = i % width, y = i / width
        if x > 0 { push(i - 1) }
        if x < width - 1 { push(i + 1) }
        if y > 0 { push(i - width) }
        if y < height - 1 { push(i + width) }
    }
    return alpha
}

var alpha: [Double]
if useFlood {
    alpha = floodKey()
    print("using border flood key")
} else if let mask = visionMask() {
    alpha = mask
    print("using Vision mask")
} else {
    alpha = (0..<(width * height)).map { keyAlpha($0, low: 18, high: 60) }
    print("using color key")
}

// Soft mask edges that still match the background are fringe, not subject.
for i in 0..<(width * height) where alpha[i] < 0.999 {
    alpha[i] = min(alpha[i], keyAlpha(i, low: 6, high: 22))
}
if clearHoles {
    for i in 0..<(width * height) { alpha[i] = min(alpha[i], keyAlpha(i, low: 10, high: 34)) }
}

// Unmatte: remove the background's contribution from partially transparent pixels, then
// suppress any remaining green or magenta spill near the edge.
for i in 0..<(width * height) {
    let a = alpha[i]
    let p = i * 4
    if a <= 0.004 {
        pixels[p] = 0; pixels[p + 1] = 0; pixels[p + 2] = 0; pixels[p + 3] = 0
        continue
    }
    var r = Double(pixels[p]), g = Double(pixels[p + 1]), b = Double(pixels[p + 2])
    if a < 0.98 {
        r = (r - (1 - a) * background.0) / a
        g = (g - (1 - a) * background.1) / a
        b = (b - (1 - a) * background.2) / a
    }
    if a < 0.995 || despillAll {
        if bgName == "green" { g = min(g, max(r, b)) }
        if bgName == "magenta" {
            let spill = max(0, min(r, b) - g)
            r -= spill * 0.9
            b -= spill * 0.9
        }
    }
    r = min(max(r, 0), 255); g = min(max(g, 0), 255); b = min(max(b, 0), 255)
    pixels[p] = UInt8(r * a)
    pixels[p + 1] = UInt8(g * a)
    pixels[p + 2] = UInt8(b * a)
    pixels[p + 3] = UInt8(a * 255)
}

// Trim to the visible subject plus a little padding.
var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 10 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= minX else {
    print("nothing left after cutout")
    exit(1)
}
let pad = 4
minX = max(minX - pad, 0); minY = max(minY - pad, 0)
maxX = min(maxX + pad, width - 1); maxY = min(maxY + pad, height - 1)

let full = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!.makeImage()!
let cropped = full.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

let scale = min(1, Double(maxSide) / Double(max(cropped.width, cropped.height)))
let outWidth = max(1, Int((Double(cropped.width) * scale).rounded()))
let outHeight = max(1, Int((Double(cropped.height) * scale).rounded()))
let output = CGContext(
    data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
output.interpolationQuality = .high
output.draw(cropped, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
let rep = NSBitmapImageRep(cgImage: output.makeImage()!)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: outputURL)
print("wrote \(outputURL.lastPathComponent) \(outWidth)x\(outHeight) \(data.count / 1024) KB")
