// Renders the Ghosty app icon into an .iconset directory: a halftone ghost with a
// prompt chevron cut out of the dots and a single orange cursor dot.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// All geometry is in a 1024×1024, y-up canvas.

/// Ghost silhouette: dome, straight sides, three scalloped hems.
func ghostPath() -> CGPath {
    let p = CGMutablePath()
    let cx: CGFloat = 512, r: CGFloat = 225, domeY: CGFloat = 575, hemY: CGFloat = 345
    p.move(to: CGPoint(x: cx - r, y: hemY))
    p.addLine(to: CGPoint(x: cx - r, y: domeY))
    p.addArc(center: CGPoint(x: cx, y: domeY), radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
    p.addLine(to: CGPoint(x: cx + r, y: hemY))
    let bump = (2 * r) / 3 + 0.001
    for i in 0..<3 {
        let c = CGPoint(x: cx + r - bump * (CGFloat(i) + 0.5), y: hemY)
        p.addArc(center: c, radius: bump / 2, startAngle: 0, endAngle: .pi, clockwise: true)
        if i < 2 { p.addLine(to: CGPoint(x: c.x - bump / 2, y: hemY + 34)) }
    }
    p.closeSubpath()
    return p
}

let ghost = ghostPath()
let ghostBox = ghost.boundingBox

// The ">" of the prompt, as negative space.
let chevron: CGPath = {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 408, y: 640))
    p.addLine(to: CGPoint(x: 478, y: 585))
    p.addLine(to: CGPoint(x: 408, y: 530))
    return p.copy(strokingWithWidth: 62, lineCap: .round, lineJoin: .round, miterLimit: 10)
}()
let chevronClear = chevron.copy(strokingWithWidth: 22, lineCap: .round, lineJoin: .round, miterLimit: 10)

// The cursor: one orange dot where the "_" would be.
let cursorCenter = CGPoint(x: 578, y: 548)
let cursorRadius: CGFloat = 36

let ink = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
let orange = NSColor(srgbRed: 0.95, green: 0.55, blue: 0.10, alpha: 1)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // White card with the standard macOS icon footprint.
    let card = NSRect(x: 100, y: 100, width: 824, height: 824)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 186, yRadius: 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20,
                  color: NSColor.black.withAlphaComponent(0.22).cgColor)
    NSColor.white.setFill()
    cardPath.fill()
    ctx.restoreGState()
    ctx.saveGState()
    cardPath.addClip()
    NSGradient(starting: .white, ending: NSColor(white: 0.955, alpha: 1))!
        .draw(in: card, angle: -90)
    ctx.restoreGState()
    NSColor(white: 0, alpha: 0.08).setStroke()
    cardPath.lineWidth = 2
    cardPath.stroke()

    // Halftone: dots grow from the crown of the ghost to its hem,
    // and shrink where the silhouette or the prompt cuts them off.
    // Small sizes get a coarser screen so the dots stay legible.
    let spacing: CGFloat = px <= 64 ? 44 : 27
    ink.setFill()
    if px <= 32 {
        // Too small for a screen of dots: solid silhouette, same cut-out and cursor.
        ctx.addPath(ghost)
        ctx.fillPath()
        ctx.setBlendMode(.clear)
        ctx.addPath(chevron)
        ctx.fillPath()
        ctx.addEllipse(in: CGRect(x: cursorCenter.x - cursorRadius - 14, y: cursorCenter.y - cursorRadius - 14,
                                  width: (cursorRadius + 14) * 2, height: (cursorRadius + 14) * 2))
        ctx.fillPath()
        ctx.setBlendMode(.normal)
        // Clearing punched through the card too; repaint it under the holes.
        ctx.setBlendMode(.destinationOver)
        NSColor.white.setFill()
        cardPath.fill()
        ctx.setBlendMode(.normal)
        orange.setFill()
        ctx.fillEllipse(in: CGRect(x: cursorCenter.x - cursorRadius, y: cursorCenter.y - cursorRadius,
                                   width: cursorRadius * 2, height: cursorRadius * 2))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
    var y = ghostBox.minY - spacing
    var row = 0
    while y <= ghostBox.maxY + spacing {
        // Offset alternate rows for a classic halftone screen.
        var x = ghostBox.minX - spacing + (row % 2 == 0 ? 0 : spacing / 2)
        while x <= ghostBox.maxX + spacing {
            let c = CGPoint(x: x, y: y)
            defer { x += spacing }
            guard ghost.contains(c), !chevronClear.contains(c) else { continue }
            if hypot(c.x - cursorCenter.x, c.y - cursorCenter.y) < cursorRadius + spacing * 0.55 { continue }

            let t = 1 - (y - ghostBox.minY) / ghostBox.height         // 0 at crown, 1 at hem
            var r = spacing * 0.5 * (0.46 + 0.48 * t)
            let probes = [CGPoint(x: x + spacing * 0.75, y: y), CGPoint(x: x - spacing * 0.75, y: y),
                          CGPoint(x: x, y: y + spacing * 0.75), CGPoint(x: x, y: y - spacing * 0.75)]
            let outside = probes.filter { !ghost.contains($0) }.count
            r *= 1 - 0.18 * CGFloat(outside)
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        y += spacing * 0.87
        row += 1
    }

    orange.setFill()
    ctx.fillEllipse(in: CGRect(x: cursorCenter.x - cursorRadius, y: cursorCenter.y - cursorRadius,
                               width: cursorRadius * 2, height: cursorRadius * 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
