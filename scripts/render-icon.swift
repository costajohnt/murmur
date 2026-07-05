// Renders the Murmur app-icon base PNG (1024x1024) with CoreGraphics/AppKit.
// Usage: swift scripts/render-icon.swift <output.png>
// Draws a rounded-rect charcoal background with a subtle vertical gradient and
// a centered soundwave motif (rounded vertical bars) in light/white.
import AppKit
import CoreGraphics

let size = 1024.0
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("could not create context") }

let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

// Transparent outside the rounded rect (macOS applies its own mask, but a
// rounded-rect keeps it clean at every size).
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

// Rounded-rect background path. macOS icon "squircle" corner ~ 0.2237 * size.
let corner = size * 0.2237
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.addPath(bgPath)
ctx.clip()

// Subtle vertical gradient: lighter charcoal at top -> near-black at bottom.
let topColor = CGColor(colorSpace: rgb, components: [0.16, 0.17, 0.19, 1.0])!   // #2A2C30
let botColor = CGColor(colorSpace: rgb, components: [0.07, 0.07, 0.09, 1.0])!   // #121217
let gradient = CGGradient(colorsSpace: rgb, colors: [topColor, botColor] as CFArray, locations: [0.0, 1.0])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Soundwave: 5 centered rounded vertical bars, symmetric heights.
// Heights as fraction of size; classic short-tall-tall-tall-short shape.
let barHeights: [Double] = [0.20, 0.34, 0.46, 0.34, 0.20]
let barWidth = size * 0.072
let gap = size * 0.052
let count = Double(barHeights.count)
let totalWidth = count * barWidth + (count - 1) * gap
var x = (size - totalWidth) / 2.0
let centerY = size / 2.0

ctx.setFillColor(CGColor(colorSpace: rgb, components: [0.96, 0.97, 0.99, 1.0])!) // near-white
for h in barHeights {
    let barH = size * h
    let rect = CGRect(x: x, y: centerY - barH / 2.0, width: barWidth, height: barH)
    let r = barWidth / 2.0
    let p = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(p)
    ctx.fillPath()
    x += barWidth + gap
}

guard let image = ctx.makeImage() else { fatalError("could not make image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("could not encode png") }
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
