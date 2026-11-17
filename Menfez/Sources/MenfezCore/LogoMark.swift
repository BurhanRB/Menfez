// LogoMark.swift — the Menfez mark, drawn with CoreGraphics only.
//
// Tunnel path: nested graphite arches receding into depth, a glowing teal
// doorway at their heart, a teal path running out of it towards the viewer,
// and a small teal light above. A way through, which is what the app opens.
// The app icon (rendered by tools/icon/main.swift into icon.png and
// AppIcon.icns), its simplified 16/32 px slices and the menu-bar template
// images all live here.

import CoreGraphics
import Foundation

public enum LogoMark {

    /// Which figure to draw. The menu bar shows the mode by its figure, not by
    /// colour, because a template image has none.
    public enum Variant: Sendable {
        /// Doorway closed: a solid arch, no path. Nothing passes through.
        case idle
        /// Doorway open: a hollow arch with a path leading into it.
        case flow
        /// The open doorway plus a solid dot above it: traffic leaves through the tunnel.
        case flowBadge
    }

    /// Fills an arch (semicircular top of radius `r` centred on `cx`, `cy`,
    /// straight legs down to `bottom`). y is down.
    static func addArch(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, bottom: CGFloat) {
        let steps = 96
        ctx.move(to: CGPoint(x: cx - r, y: bottom))
        for i in 0...steps {
            let t = CGFloat.pi * (1 - CGFloat(i) / CGFloat(steps))
            ctx.addLine(to: CGPoint(x: cx + r * cos(t), y: cy - r * sin(t)))
        }
        ctx.addLine(to: CGPoint(x: cx + r, y: bottom))
        ctx.closePath()
    }

    /// Draw the menu-bar figure into `rect`, on a 22-unit grid (y down) so
    /// that at 22 pt every straight edge lands on a whole point. `slat`
    /// paints the arch, `flow` the path and the dot. Every variant shares
    /// the same arch: x 5…17, top 7, legs to 17, doorway radius 3.
    public static func draw(in ctx: CGContext, rect: CGRect, variant: Variant,
                            slat: CGColor, flow: CGColor) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: rect.width / 22, y: -rect.height / 22)

        ctx.setFillColor(slat)
        addArch(ctx, cx: 11, cy: 13, r: 6, bottom: 17)
        if variant != .idle { addArch(ctx, cx: 11, cy: 13, r: 3, bottom: 17) }
        ctx.fillPath(using: .evenOdd)
        guard variant != .idle else { return }

        // Floor in perspective: doorway-wide at the top, a 1-unit gap below the legs.
        ctx.setFillColor(flow)
        ctx.addLines(between: [CGPoint(x: 8, y: 18), CGPoint(x: 14, y: 18),
                               CGPoint(x: 16, y: 21), CGPoint(x: 6, y: 21)])
        ctx.closePath()
        ctx.fillPath()
        if variant == .flowBadge {
            // 2 units clear of the arch top.
            ctx.fillEllipse(in: CGRect(x: 9, y: 1, width: 4, height: 4))
        }
    }

    /// The full app icon, `size` pixels square: graphite squircle, three
    /// receding arch rings, glowing teal doorway and path, teal light above.
    /// Follows the macOS icon grid (an 824/1024 body with margins).
    public static func appIcon(size: Int) -> CGImage? {
        let s = CGFloat(size)
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        if size <= 32 { drawSmallIcon(in: ctx, size: s); return ctx.makeImage() }

        let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
        let radius = body.width * 0.225
        let tile = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Soft drop shadow under the tile, as system icons have.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 28 / 1024,
                      color: rgb(0x000000, 0.35))
        ctx.addPath(tile)
        ctx.setFillColor(rgb(0x1E2124))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tile)
        ctx.clip()
        // Unit square over the body, y down.
        ctx.translateBy(x: body.minX, y: body.maxY)
        ctx.scaleBy(x: body.width, y: -body.height)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
            CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)!
        }
        func vertical(_ g: CGGradient, _ y0: CGFloat, _ y1: CGFloat) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        // Graphite, a touch lighter at the top.
        vertical(gradient([rgb(0x262A2E), rgb(0x1E2124)], [0, 1]), 0, 1)

        let cx: CGFloat = 0.5, cy: CGFloat = 0.58, sill: CGFloat = 0.72
        // Outer ring: the lightest graphite, catching light at its crown.
        ctx.saveGState()
        addArch(ctx, cx: cx, cy: cy, r: 0.32, bottom: 1.1)
        ctx.clip()
        vertical(gradient([rgb(0x36393F), rgb(0x2C2F35)], [0, 1]), 0.26, 0.8)
        ctx.restoreGState()
        // Middle and inner rings: darker, faintly teal from the doorway.
        ctx.setFillColor(rgb(0x21292C))
        addArch(ctx, cx: cx, cy: cy, r: 0.25, bottom: 1.1)
        ctx.fillPath()
        ctx.setFillColor(rgb(0x1A2327))
        addArch(ctx, cx: cx, cy: cy, r: 0.175, bottom: 1.1)
        ctx.fillPath()
        // The doorway's light spilling onto the inner ring.
        ctx.saveGState()
        addArch(ctx, cx: cx, cy: cy, r: 0.175, bottom: sill)
        ctx.clip()
        ctx.drawRadialGradient(gradient([rgb(0x4FC9B0, 0.16), rgb(0x4FC9B0, 0)], [0, 1]),
                               startCenter: CGPoint(x: cx, y: 0.6), startRadius: 0.08,
                               endCenter: CGPoint(x: cx, y: 0.6), endRadius: 0.2, options: [])
        ctx.restoreGState()

        // Floor: below a line through the doorway's sill, sloping out to the sides.
        let slope: CGFloat = 0.29
        let door: CGFloat = 0.10
        func floorY(_ x: CGFloat) -> CGFloat { sill + slope * max(0, abs(x - cx) - door) }
        ctx.setFillColor(rgb(0x262D31))
        ctx.addLines(between: [CGPoint(x: -0.1, y: floorY(-0.1)), CGPoint(x: cx - door, y: sill),
                               CGPoint(x: cx + door, y: sill), CGPoint(x: 1.1, y: floorY(1.1)),
                               CGPoint(x: 1.1, y: 1.1), CGPoint(x: -0.1, y: 1.1)])
        ctx.closePath()
        ctx.fillPath()

        // Path: doorway-wide at the sill, out to the tile's foot; bright at the door.
        let spread: CGFloat = 1.02   // half-width gained per unit of depth
        let foot: CGFloat = 1.05
        ctx.saveGState()
        ctx.addLines(between: [CGPoint(x: cx - door, y: sill), CGPoint(x: cx + door, y: sill),
                               CGPoint(x: cx + door + spread * (foot - sill), y: foot),
                               CGPoint(x: cx - door - spread * (foot - sill), y: foot)])
        ctx.closePath()
        ctx.clip()
        vertical(gradient([rgb(0x4CBBA6), rgb(0x2F7C72), rgb(0x2A6D66)], [0, 0.45, 1]), sill, 1)
        ctx.restoreGState()

        // Doorway, with a soft glow.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: s * 22 / 1024, color: rgb(0x5AD3BB, 0.3))
        ctx.setFillColor(rgb(0x58D0B9))
        addArch(ctx, cx: cx, cy: cy, r: door, bottom: sill)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        addArch(ctx, cx: cx, cy: cy, r: door, bottom: sill)
        ctx.clip()
        vertical(gradient([rgb(0x5DD3BC), rgb(0x55CDB6)], [0, 1]), cy - door, sill)
        ctx.restoreGState()

        // The light above.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: s * 14 / 1024, color: rgb(0x52C2AC, 0.5))
        ctx.setFillColor(rgb(0x52C2AC))
        ctx.fillEllipse(in: CGRect(x: cx - 0.031, y: 0.165, width: 0.062, height: 0.062))
        ctx.restoreGState()

        ctx.restoreGState()

        // Hairline rim so the tile holds its edge on a dark Dock.
        ctx.addPath(tile)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.08))
        ctx.setLineWidth(max(1, s * 3 / 1024))
        ctx.strokePath()
        return ctx.makeImage()
    }

    /// The 16 and 32 px icons: the full drawing shrinks to a smudge, so these
    /// get their own figure on a 16-unit grid (y down). Bigger tile, no shadow
    /// or rim, one light arch ring, a bold teal doorway and a short path. The
    /// light above is dropped: it would touch the ring.
    static func drawSmallIcon(in ctx: CGContext, size: CGFloat) {
        let u = size / 16
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: u, y: -u)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: 15, height: 15),
                           cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
        ctx.setFillColor(rgb(0x202427))
        ctx.fillPath()
        ctx.setFillColor(rgb(0x4A4F57))
        addArch(ctx, cx: 8, cy: 8, r: 5, bottom: 12)
        ctx.fillPath()
        ctx.setFillColor(rgb(0x58D0B9))
        addArch(ctx, cx: 8, cy: 8, r: 2, bottom: 12)
        ctx.fillPath()
        ctx.setFillColor(rgb(0x3A9C8B))
        ctx.addLines(between: [CGPoint(x: 6, y: 12), CGPoint(x: 10, y: 12),
                               CGPoint(x: 13, y: 15.5), CGPoint(x: 3, y: 15.5)])
        ctx.closePath()
        ctx.fillPath()
    }

    /// A black-on-clear template image for the menu bar, `points` square at
    /// `scale`: the 22-unit figure from `draw`, not the app icon scaled down.
    public static func template(_ variant: Variant, points: Int = 22, scale: Int = 2) -> CGImage? {
        let px = points * scale
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(in: ctx, rect: CGRect(x: 0, y: 0, width: px, height: px), variant: variant,
             slat: rgb(0x000000), flow: rgb(0x000000))
        return ctx.makeImage()
    }

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
