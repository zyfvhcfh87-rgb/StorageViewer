#!/usr/bin/env swift
// make_icons.swift — render StorageViewer app-icon candidates.
// Usage:  swift make_icons.swift <outdir>            -> all variants + contact sheet
//         swift make_icons.swift <outdir> <variant>  -> one variant at 1024px
//         swift make_icons.swift <outdir> <variant> <size> -> one size

import AppKit
import CoreText
import Foundation

// MARK: - Palette (mirrors Sources/StorageViewer/Theme.swift)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: a
    )
}

let accent = rgb(0x4c8bf5)
let amber = rgb(0xe8a23a)
let catCols: [NSColor] = [
    rgb(0x3d7ae0), // code
    rgb(0x8b5cf6), // images
    rgb(0xe85d8c), // video
    rgb(0xe6c53a), // audio
    rgb(0x2fbf8a), // archives
    rgb(0x3cb8d9), // documents
    rgb(0x8a8a8a), // other
]

// MARK: - Geometry helpers

/// macOS "superellipse" squircle approximation.
func squircle(_ r: CGRect, n: CGFloat = 4.75, steps: Int = 900) -> NSBezierPath {
    let path = NSBezierPath()
    let a = r.width / 2, b = r.height / 2
    let cx = r.midX, cy = r.midY
    for i in 0...steps {
        let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
        let c = cos(t), s = sin(t)
        let x = cx + a * pow(abs(c), 2 / n) * (c >= 0 ? 1 : -1)
        let y = cy + b * pow(abs(s), 2 / n) * (s >= 0 ? 1 : -1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.line(to: CGPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

/// Squarified treemap layout (Bruls/Huizing/van Wijk) — same look the app produces.
func squarify(_ weights: [CGFloat], in rect: CGRect) -> [CGRect] {
    let total = weights.reduce(0, +)
    var areas = weights.map { $0 / total * rect.width * rect.height }
    var rects: [CGRect] = []
    var rem = rect
    var row: [CGFloat] = []

    func worst(_ items: [CGFloat], _ side: CGFloat) -> CGFloat {
        let sum = items.reduce(0, +)
        guard sum > 0, let mn = items.min(), let mx = items.max() else { return .infinity }
        return max(side * side * mx / (sum * sum), sum * sum / (side * side * mn))
    }
    func layoutRow() {
        let sum = row.reduce(0, +)
        if rem.width >= rem.height {
            let w = sum / rem.height
            var y = rem.minY
            for a in row {
                let h = a / w
                rects.append(CGRect(x: rem.minX, y: y, width: w, height: h))
                y += h
            }
            rem.origin.x += w
            rem.size.width -= w
        } else {
            let h = sum / rem.width
            var x = rem.minX
            for a in row {
                let w = a / h
                rects.append(CGRect(x: x, y: rem.maxY - h, width: w, height: h))
                x += w
            }
            rem.size.height -= h
        }
        row = []
    }

    while !areas.isEmpty {
        let next = areas[0]
        let side = min(rem.width, rem.height)
        if row.isEmpty || worst(row + [next], side) <= worst(row, side) {
            row.append(next)
            areas.removeFirst()
        } else {
            layoutRow()
        }
    }
    if !row.isEmpty { layoutRow() }
    return rects
}

let mosaicWeights: [CGFloat] = [26, 19, 15, 11, 8, 6, 5, 4, 3, 2]

func drawMosaic(in rect: CGRect, ctx: CGContext, alpha: CGFloat = 1, gutter: CGFloat = 10, radius: CGFloat = 8, selected: Int? = 1) {
    let blocks = squarify(mosaicWeights, in: rect)
    for (i, r) in blocks.enumerated() {
        let inset = r.insetBy(dx: gutter / 2, dy: gutter / 2)
        guard inset.width > 1, inset.height > 1 else { continue }
        let path = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
        catCols[i % catCols.count].withAlphaComponent(alpha).setFill()
        path.fill()
        if i == selected {
            amber.setStroke()
            path.lineWidth = 8
            path.stroke()
        }
    }
}

// MARK: - Tile

/// Big Sur+ icon tile: 824pt squircle on a 1024 canvas.
func tileRect(for canvas: CGFloat) -> CGRect {
    let t = canvas * 824 / 1024
    return CGRect(x: (canvas - t) / 2, y: (canvas - t) / 2, width: t, height: t)
}

func beginTile(_ ctx: CGContext, canvas: CGFloat) -> CGRect {
    let tile = tileRect(for: canvas)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -canvas * 0.012), blur: canvas * 0.024,
                  color: NSColor.black.withAlphaComponent(0.5).cgColor)
    rgb(0x151517).setFill()
    squircle(tile).fill()
    ctx.restoreGState()

    ctx.saveGState()
    squircle(tile).addClip()
    let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(0x27272d).cgColor, rgb(0x101012).cgColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: tile.midX, y: tile.maxY),
        end: CGPoint(x: tile.midX, y: tile.minY),
        options: []
    )
    return tile
}

func endTile(_ ctx: CGContext, tile: CGRect) {
    ctx.restoreGState()
    rgb(0xffffff, 0.10).setStroke()
    let edge = squircle(tile.insetBy(dx: 0.75, dy: 0.75))
    edge.lineWidth = 1.5
    edge.stroke()
}

// MARK: - Variants (all drawn inside the clipped tile)

/// 1. Field — the app itself: a treemap mosaic filling the tile.
func drawField(_ ctx: CGContext, canvas: CGFloat) {
    let tile = beginTile(ctx, canvas: canvas)
    drawMosaic(in: tile.insetBy(dx: canvas * 0.068, dy: canvas * 0.068), ctx: ctx)
    endTile(ctx, tile: tile)
}

/// 2. Loupe — treemap under a magnifier.
func drawLoupe(_ ctx: CGContext, canvas: CGFloat) {
    let tile = beginTile(ctx, canvas: canvas)
    let mosaicRect = tile.insetBy(dx: canvas * 0.05, dy: canvas * 0.05)
    drawMosaic(in: mosaicRect, ctx: ctx, alpha: 0.55, selected: nil)

    let lensR = canvas * 0.235
    let center = CGPoint(x: tile.midX - canvas * 0.045, y: tile.midY + canvas * 0.045)

    // Glass: re-render the mosaic magnified inside the lens.
    ctx.saveGState()
    NSBezierPath(ovalIn: CGRect(x: center.x - lensR, y: center.y - lensR, width: lensR * 2, height: lensR * 2)).addClip()
    let zoom: CGFloat = 1.5
    let big = CGRect(
        x: center.x - (center.x - mosaicRect.minX) * zoom,
        y: center.y - (center.y - mosaicRect.minY) * zoom,
        width: mosaicRect.width * zoom,
        height: mosaicRect.height * zoom
    )
    drawMosaic(in: big, ctx: ctx, alpha: 1, selected: nil)
    rgb(0xffffff, 0.07).setFill()
    NSBezierPath(ovalIn: CGRect(x: center.x - lensR, y: center.y - lensR, width: lensR * 2, height: lensR * 2)).fill()
    ctx.restoreGState()

    // Handle (under the ring).
    ctx.saveGState()
    let angle = -CGFloat.pi / 4
    let gripStart = CGPoint(
        x: center.x + cos(angle) * (lensR + canvas * 0.010),
        y: center.y + sin(angle) * (lensR + canvas * 0.010)
    )
    ctx.translateBy(x: gripStart.x, y: gripStart.y)
    ctx.rotate(by: angle)
    let handle = CGRect(x: 0, y: -canvas * 0.030, width: canvas * 0.21, height: canvas * 0.060)
    rgb(0x26262c).setFill()
    NSBezierPath(roundedRect: handle, xRadius: canvas * 0.030, yRadius: canvas * 0.030).fill()
    rgb(0xffffff, 0.14).setStroke()
    let hPath = NSBezierPath(roundedRect: handle.insetBy(dx: 1, dy: 1), xRadius: canvas * 0.028, yRadius: canvas * 0.028)
    hPath.lineWidth = 2
    hPath.stroke()
    ctx.restoreGState()

    // Ring.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: canvas * 0.012, color: accent.withAlphaComponent(0.5).cgColor)
    accent.setStroke()
    let ring = NSBezierPath(ovalIn: CGRect(x: center.x - lensR, y: center.y - lensR, width: lensR * 2, height: lensR * 2))
    ring.lineWidth = canvas * 0.034
    ring.stroke()
    ctx.restoreGState()

    // Rim light.
    rgb(0xffffff, 0.22).setStroke()
    let rim = NSBezierPath(ovalIn: CGRect(
        x: center.x - lensR + canvas * 0.014, y: center.y - lensR + canvas * 0.014,
        width: (lensR - canvas * 0.014) * 2, height: (lensR - canvas * 0.014) * 2
    ))
    rim.lineWidth = canvas * 0.006
    rim.stroke()

    endTile(ctx, tile: tile)
}

/// 3. Platter — a disk whose surface is divided into category arcs.
func drawPlatter(_ ctx: CGContext, canvas: CGFloat) {
    let tile = beginTile(ctx, canvas: canvas)
    let c = CGPoint(x: tile.midX, y: tile.midY)
    let outer = canvas * 0.335
    let inner = canvas * 0.155

    // Drop shadow for the disc.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -canvas * 0.008), blur: canvas * 0.02,
                  color: NSColor.black.withAlphaComponent(0.5).cgColor)
    rgb(0x0b0b0d).setFill()
    NSBezierPath(ovalIn: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2)).fill()
    ctx.restoreGState()

    // Wedges.
    let shares: [CGFloat] = [30, 22, 16, 11, 8, 6, 5]
    let total = shares.reduce(0, +)
    let gap: CGFloat = 0.9 // degrees
    var angle: CGFloat = 90 // start at top, sweep clockwise
    for (i, share) in shares.enumerated() {
        let span = share / total * 360
        let path = NSBezierPath()
        path.move(to: c)
        path.appendArc(withCenter: c, radius: outer, startAngle: angle - gap, endAngle: angle - span + gap, clockwise: true)
        path.close()
        catCols[i % catCols.count].setFill()
        path.fill()
        angle -= span
    }

    // Inner disc with grooves.
    ctx.saveGState()
    NSBezierPath(ovalIn: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2)).addClip()
    let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(0x2a2a30).cgColor, rgb(0x141416).cgColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        grad,
        startCenter: c, startRadius: 0,
        endCenter: c, endRadius: inner,
        options: [.drawsAfterEndLocation]
    )
    for rr in stride(from: inner * 0.45, to: inner, by: inner * 0.16) {
        rgb(0xffffff, 0.05).setStroke()
        let ring = NSBezierPath(ovalIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
        ring.lineWidth = 2
        ring.stroke()
    }
    ctx.restoreGState()

    // Separator ring between wedges and inner disc.
    rgb(0x0b0b0d).setStroke()
    let sep = NSBezierPath(ovalIn: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
    sep.lineWidth = canvas * 0.008
    sep.stroke()

    // Hub.
    rgb(0x0f0f11).setFill()
    let hub = canvas * 0.052
    NSBezierPath(ovalIn: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2)).fill()
    rgb(0x2a2a2e).setStroke()
    let hubRing = NSBezierPath(ovalIn: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2))
    hubRing.lineWidth = canvas * 0.006
    hubRing.stroke()
    accent.setFill()
    let dot = canvas * 0.016
    NSBezierPath(ovalIn: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2)).fill()

    // Sheen across the disc.
    ctx.saveGState()
    NSBezierPath(ovalIn: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2)).addClip()
    let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(0xffffff, 0.10).cgColor, rgb(0xffffff, 0).cgColor] as CFArray,
        locations: [0, 0.55]
    )!
    ctx.drawLinearGradient(
        sheen,
        start: CGPoint(x: c.x - outer * 0.5, y: c.y + outer * 0.9),
        end: CGPoint(x: c.x + outer * 0.4, y: c.y - outer * 0.4),
        options: []
    )
    ctx.restoreGState()

    endTile(ctx, tile: tile)
}

/// 4. Dial — the scan animation frozen: tick ring, comet head, map plate inside.
func drawDial(_ ctx: CGContext, canvas: CGFloat) {
    let tile = beginTile(ctx, canvas: canvas)
    let c = CGPoint(x: tile.midX, y: tile.midY)
    let inner = canvas * 0.245
    let outer = canvas * 0.315
    let ticks = 72
    let span = 0.27
    let startAngle: CGFloat = 95 // comet head lands upper-right

    for i in 0..<ticks {
        let theta = (startAngle + CGFloat(i) / CGFloat(ticks) * 360) * .pi / 180
        let frac = CGFloat(i) / CGFloat(ticks) // 0..1 along the comet (0 = head)
        let p0 = CGPoint(x: c.x + cos(theta) * inner, y: c.y + sin(theta) * inner)
        let p1 = CGPoint(x: c.x + cos(theta) * outer, y: c.y + sin(theta) * outer)
        let path = NSBezierPath()
        path.move(to: p0)
        path.line(to: p1)
        path.lineCapStyle = .round
        path.lineWidth = canvas * 0.012
        if frac <= span {
            let t = frac / span
            (t < 0.45 ? accent : t < 0.75 ? rgb(0x2c5ea8) : rgb(0x1d3d6e)).setStroke()
        } else {
            rgb(0x2c2c2c).setStroke()
        }
        path.stroke()
    }

    // Map plate in the middle, like the app's map area.
    let plateSize = canvas * 0.34
    let plate = CGRect(x: c.x - plateSize / 2, y: c.y - plateSize / 2, width: plateSize, height: plateSize)
    rgb(0x0c0c0e).setFill()
    NSBezierPath(roundedRect: plate, xRadius: canvas * 0.03, yRadius: canvas * 0.03).fill()
    rgb(0x2a2a2a).setStroke()
    let plateEdge = NSBezierPath(roundedRect: plate, xRadius: canvas * 0.03, yRadius: canvas * 0.03)
    plateEdge.lineWidth = canvas * 0.004
    plateEdge.stroke()

    let inset = plate.insetBy(dx: canvas * 0.016, dy: canvas * 0.016)
    let mini = squarify([6, 4, 3, 2], in: inset)
    let miniCols = [catCols[0], catCols[1], catCols[4], catCols[3]]
    for (i, r) in mini.enumerated() {
        let b = r.insetBy(dx: canvas * 0.005, dy: canvas * 0.005)
        let path = NSBezierPath(roundedRect: b, xRadius: canvas * 0.01, yRadius: canvas * 0.01)
        miniCols[i].setFill()
        path.fill()
    }
    endTile(ctx, tile: tile)
}

/// 5. Folder — a Finder-ish folder whose body is the treemap.
func drawFolder(_ ctx: CGContext, canvas: CGFloat) {
    let tile = beginTile(ctx, canvas: canvas)

    let bodyW = tile.width * 0.86
    let bodyX = tile.midX - bodyW / 2
    let backTop = tile.maxY - canvas * 0.17
    let back = CGRect(x: bodyX, y: tile.minY + canvas * 0.16, width: bodyW, height: backTop - tile.minY - canvas * 0.16)
    let tab = CGRect(x: bodyX + bodyW * 0.06, y: backTop - canvas * 0.01, width: bodyW * 0.34, height: canvas * 0.09)

    // Back panel + tab.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -canvas * 0.01), blur: canvas * 0.02,
                  color: NSColor.black.withAlphaComponent(0.5).cgColor)
    rgb(0x2b2b31).setFill()
    NSBezierPath(roundedRect: back, xRadius: canvas * 0.05, yRadius: canvas * 0.05).fill()
    NSBezierPath(roundedRect: tab, xRadius: canvas * 0.03, yRadius: canvas * 0.03).fill()
    ctx.restoreGState()
    rgb(0x2b2b31).setFill()
    // Fill the seam under the tab so the two shapes read as one.
    NSBezierPath(rect: CGRect(x: bodyX + bodyW * 0.05, y: backTop - canvas * 0.02, width: bodyW * 0.36, height: canvas * 0.03)).fill()

    // Front face: the treemap clipped to the folder front.
    let front = CGRect(x: bodyX, y: back.minY, width: bodyW, height: back.height * 0.74)
    ctx.saveGState()
    NSBezierPath(roundedRect: front, xRadius: canvas * 0.045, yRadius: canvas * 0.045).addClip()
    drawMosaic(in: front.insetBy(dx: canvas * 0.012, dy: canvas * 0.012), ctx: ctx, gutter: canvas * 0.012, radius: canvas * 0.012, selected: nil)
    // Top edge shadow where front meets back.
    let shade = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(0x000000, 0.35).cgColor, rgb(0x000000, 0).cgColor] as CFArray,
        locations: [0, 0.4]
    )!
    ctx.drawLinearGradient(
        shade,
        start: CGPoint(x: front.midX, y: front.maxY),
        end: CGPoint(x: front.midX, y: front.maxY - canvas * 0.07),
        options: []
    )
    ctx.restoreGState()

    rgb(0xffffff, 0.10).setStroke()
    let frontEdge = NSBezierPath(roundedRect: front, xRadius: canvas * 0.045, yRadius: canvas * 0.045)
    frontEdge.lineWidth = 1.5
    frontEdge.stroke()

    endTile(ctx, tile: tile)
}

// MARK: - Rendering

typealias Painter = (CGContext, CGFloat) -> Void

let variants: [(name: String, painter: Painter)] = [
    ("field", drawField),
    ("loupe", drawLoupe),
    ("platter", drawPlatter),
    ("dial", drawDial),
    ("folder", drawFolder),
]

func render(painter: Painter, size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    painter(NSGraphicsContext.current!.cgContext, size)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    do {
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        print("wrote", path)
    } catch {
        FileHandle.standardError.write("failed to write \(path): \(error)\n".data(using: .utf8)!)
    }
}

/// Contact sheet: big row + dock-size row + labels.
func renderSheet(_ reps: [(String, NSBitmapImageRep)]) -> NSBitmapImageRep {
    let big: CGFloat = 300, small: CGFloat = 56
    let pad: CGFloat = 40, gap: CGFloat = 36, labelH: CGFloat = 46
    let w = pad * 2 + CGFloat(reps.count) * big + CGFloat(reps.count - 1) * gap
    let h = pad * 2 + big + 24 + small + labelH
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    rgb(0x19191d).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: w, height: h)).fill()

    for (i, item) in reps.enumerated() {
        let x = pad + CGFloat(i) * (big + gap)
        let yBig = pad + small + 24 + labelH
        ctx.draw(item.1.cgImage!, in: CGRect(x: x, y: yBig, width: big, height: big))
        let xSmall = x + (big - small) / 2
        ctx.draw(item.1.cgImage!, in: CGRect(x: xSmall, y: pad + labelH, width: small, height: small))

        // Label via Core Text — glyphs are upright in this y-up context.
        let label = NSAttributedString(string: item.0, attributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .medium),
            .foregroundColor: rgb(0xdddddd),
        ])
        let line = CTLineCreateWithAttributedString(label)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let tw = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x + (big - tw) / 2, y: pad + labelH - 26)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Main

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "design/icon-variants"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

if args.count > 2 {
    let name = args[2]
    let size: CGFloat = args.count > 3 ? CGFloat(Double(args[3]) ?? 1024) : 1024
    guard let v = variants.first(where: { $0.name == name }) else {
        FileHandle.standardError.write("unknown variant '\(name)'\n".data(using: .utf8)!)
        exit(1)
    }
    writePNG(render(painter: v.painter, size: size), to: "\(outDir)/\(name)-\(Int(size)).png")
} else {
    var reps: [(String, NSBitmapImageRep)] = []
    for v in variants {
        let rep = render(painter: v.painter, size: 1024)
        writePNG(rep, to: "\(outDir)/icon-\(v.name).png")
        reps.append((v.name, rep))
    }
    writePNG(renderSheet(reps), to: "\(outDir)/icon-variants.png")
}
