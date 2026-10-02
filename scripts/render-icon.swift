// Renders the MacNative app icon and mark with CoreGraphics.
//
// This is a 1:1 CoreGraphics transcription of Resources/Logo/macnative-icon.svg and
// macnative-mark.svg (the SVGs are the source of truth). Drawing natively avoids depending
// on NSImage's SVG renderer, which ignores filters and some gradient attributes.
//
//   swift scripts/render-icon.swift icon <size> <out.png>
//   swift scripts/render-icon.swift mark <size> <out.png>
//
// All geometry is in the SVG's 1024×1024 user space (y down).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: Palette (Sources/MacNative/UI/Theme.swift)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let cyan = rgb(0x00D4FF), purple = rgb(0x8B5CF6), pink = rgb(0xEC4899)
let magenta = rgb(0xA21CAF), magentaLight = rgb(0xE879F9)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

// MARK: Geometry

/// Superellipse (|x|^n + |y|^n = 1) — approximates Apple's continuous-corner icon body.
func squircle(_ rect: CGRect, n: CGFloat = 4) -> CGPath {
    let p = CGMutablePath()
    let cx = rect.midX, cy = rect.midY, a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)

// The mark: two chevrons ("peaks") that together spell an M. They meet at the
// baseline in the middle, where their strokes overlap — two worlds (Windows games and
// the Mac) merging into one. The overlap is lit up as a brighter "glass" facet.
enum Mark {
    static let stroke: CGFloat = 108
    static let base: CGFloat = 718       // flat baseline (strokes are clipped here)
    static let apex: CGFloat = 330       // apex of the centre-line
    static let xs: [CGFloat] = [274, 393, 512, 631, 750]   // baseline / apex x positions (centre-line)
    static let left = leg([xs[0], xs[1], xs[2]])
    static let right = leg([xs[2], xs[3], xs[4]])
    static let bounds = CGRect(x: 212, y: 270, width: 600, height: 450)

    /// Centre-line of one peak, extended past the baseline so the clip yields a flat cut.
    static func leg(_ x: [CGFloat]) -> [CGPoint] {
        let ext: CGFloat = 80
        let dx = (x[1] - x[0]) / (base - apex) * ext
        return [CGPoint(x: x[0] - dx, y: base + ext), CGPoint(x: x[1], y: apex), CGPoint(x: x[2] + dx, y: base + ext)]
    }
}

func chevronPath(_ pts: [CGPoint]) -> CGPath {
    let line = CGMutablePath()
    line.addLines(between: pts)
    return line.copy(strokingWithWidth: Mark.stroke, lineCap: .butt, lineJoin: .round, miterLimit: 10)
}

// MARK: Drawing

func drawMark(_ ctx: CGContext, shadowScale: CGFloat) {
    let baseClip = CGRect(x: 0, y: 0, width: 1024, height: Mark.base)
    let lp = chevronPath(Mark.left), rp = chevronPath(Mark.right)

    // Soft contact shadow under the glyph.
    if shadowScale > 0 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * shadowScale), blur: 36 * shadowScale,
                      color: rgb(0x000000, 0.55))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.clip(to: baseClip)
        ctx.addPath(lp); ctx.addPath(rp); ctx.setFillColor(rgb(0x2A0F3A)); ctx.fillPath(using: .winding)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.clip(to: baseClip)

    // Whole M: brand gradient cyan → purple → pink.
    ctx.saveGState()
    ctx.addPath(lp); ctx.addPath(rp); ctx.clip(using: .winding)
    ctx.drawLinearGradient(gradient([(0, cyan), (0.5, purple), (1, pink)]),
                           start: CGPoint(x: 230, y: 380), end: CGPoint(x: 794, y: 660),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Glass sheen: soft white falloff from the top.
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0.30)), (0.45, rgb(0xFFFFFF, 0.0))]),
                           start: CGPoint(x: 512, y: 262), end: CGPoint(x: 512, y: 718), options: [])
    ctx.restoreGState()

    // Overlap facet where the peaks meet.
    ctx.saveGState()
    ctx.addPath(lp); ctx.clip()
    ctx.addPath(rp); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0.92)), (0.55, rgb(0xF5C2FB)), (1, magentaLight)]),
                           start: CGPoint(x: 512, y: 540), end: CGPoint(x: 512, y: 718), options: [.drawsBeforeStartLocation])
    ctx.restoreGState()

    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext, scale: CGFloat) {
    let shape = squircle(body)

    // Drop shadow (inside the 1024 canvas).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: rgb(0x000000, 0.45))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x09090B)); ctx.fillPath()
    ctx.restoreGState()

    // Body: dark vertical gradient.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0x1E1E2A)), (0.55, rgb(0x12121A)), (1, rgb(0x09090B))]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // Brand glow behind the mark.
    ctx.drawRadialGradient(gradient([(0, rgb(0xA21CAF, 0.42)), (1, rgb(0xA21CAF, 0))]),
                           startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 560), endRadius: 400, options: [])
    ctx.restoreGState()

    drawMark(ctx, shadowScale: scale)

    // Inner rim highlight (top) and edge.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.addPath(shape)
    ctx.setLineWidth(6)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0.22)), (0.35, rgb(0xFFFFFF, 0.04)), (1, rgb(0xFFFFFF, 0.02))]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()
}

// MARK: Main

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[2]) else {
    FileHandle.standardError.write("usage: render-icon.swift icon|mark <size> <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let mode = args[1], out = URL(fileURLWithPath: args[3])

let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high
let scale = CGFloat(size) / 1024
// Flip to SVG space (y down).
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: scale, y: -scale)

if mode == "icon" {
    drawIcon(ctx, scale: scale)
} else {
    // Fit the glyph's bounds into the canvas with a small margin.
    let b = Mark.bounds, inset: CGFloat = 40
    let f = (1024 - 2 * inset) / max(b.width, b.height)
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: f, y: f)
    ctx.translateBy(x: -b.midX, y: -b.midY)
    drawMark(ctx, shadowScale: 0)
}

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
