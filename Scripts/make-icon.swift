#!/usr/bin/env swift
// Generate Resources/AppIcon.icns — a white "T" centered on a green tile.
//
// Run by hand after changing the design, not by the Makefile:
//
//     swift Scripts/make-icon.swift
//
// The .icns is committed, so `make app` just copies it. Regenerating it per
// build would put a Swift script compile in front of every build.
//
// This is a deliberate sibling of ~/vimango_hybrid/scripts/make-icon.swift:
// same tile grid, same corner treatment, same per-size rendering, so the two
// apps read as a pair in the Dock. Only the letter and the hue differ. The
// duplication is on purpose — the repos are independent and neither should
// reach into the other — but a change to the tile style belongs in both.
//
// The green is luminance-matched to that app's blue (#3498db): white sits at
// 3.14:1 on this green and 3.15:1 on the blue, so neither tile looks heavier
// than the other. Hue is ~146 deg against the blue's ~204 deg — far enough
// apart to tell at a glance, close enough in saturation to look related.

import AppKit
import QuartzCore

// MARK: - Geometry
//
// Everything below is a fraction of the 1024pt canvas, so each iconset size
// is drawn at its own size rather than downscaled from a master — that is
// what keeps the 16pt and 32pt tiles crisp.

// Apple's macOS grid: an 824x824 body centered in 1024, corner radius
// 0.225 * 824.
let tileInset: CGFloat = 100.0 / 1024.0          // (1024 - 824) / 2
let tileSide: CGFloat = 824.0 / 1024.0
let tileRadius: CGFloat = 185.4 / 1024.0

// Mark geometry, in units of the *tile* (not the canvas). x from the tile's
// left edge, y from its bottom. Same bounding box as the sibling app's V, so
// the two letters sit at the same size on the same grid.
let markLeft: CGFloat = 0.22
let markRight: CGFloat = 0.78
let markTop: CGFloat = 0.77
let markBottom: CGFloat = 0.23

// The V's arms are 0.145 of the tile measured horizontally, but they are
// diagonal, so perpendicular they are 0.145 * 0.54 / 0.6083 = 0.129. The T's
// strokes are axis-aligned, so matching that perpendicular figure is what
// makes the two letters the same weight; a horizontal bar at the V's
// *horizontal* 0.145 would read noticeably heavier.
let strokeWidth: CGFloat = 0.129

let tileColor = NSColor(srgbRed: 0x26 / 255.0, green: 0xa6 / 255.0, blue: 0x5d / 255.0, alpha: 1)
let markColor = NSColor.white

/// The T as two overlapping rectangles — crossbar and stem — filled as one
/// path. They overlap at the top rather than butting, so no seam can show up
/// as a hairline at small sizes.
func makeTPath(tile: CGRect) -> NSBezierPath {
    func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> NSRect {
        NSRect(
            x: tile.minX + x0 * tile.width,
            y: tile.minY + y0 * tile.height,
            width: (x1 - x0) * tile.width,
            height: (y1 - y0) * tile.height
        )
    }
    let bar = rect(markLeft, markTop - strokeWidth, markRight, markTop)
    let stemLeft = 0.5 - strokeWidth / 2
    let stem = rect(stemLeft, markBottom, stemLeft + strokeWidth, markTop)

    let path = NSBezierPath()
    path.appendRect(bar)
    path.appendRect(stem)
    path.windingRule = .nonZero
    return path
}

/// The tile, drawn through a CALayer so the corners get Apple's continuous
/// squircle curve. NSBezierPath(roundedRect:xRadius:yRadius:) would give
/// circular arcs, which read subtly wrong next to real app icons.
func drawTile(in ctx: CGContext, rect: CGRect) {
    let layer = CALayer()
    // render(in:) ignores the layer's position and draws at the context
    // origin, so the layer is sized at the origin and the context is moved
    // instead. Setting layer.frame here would silently draw bottom-left.
    layer.frame = CGRect(origin: .zero, size: rect.size)
    layer.backgroundColor = tileColor.cgColor
    layer.cornerRadius = tileRadius * rect.width / tileSide
    layer.cornerCurve = .continuous
    layer.isOpaque = false

    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.minY)
    layer.render(in: ctx)
    ctx.restoreGState()
}

func renderIcon(size: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate a \(size)x\(size) bitmap") }

    let side = CGFloat(size)
    NSGraphicsContext.saveGraphicsState()
    guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not make a graphics context for \(size)x\(size)")
    }
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext

    let tile = CGRect(
        x: tileInset * side, y: tileInset * side,
        width: tileSide * side, height: tileSide * side
    )
    drawTile(in: ctx, rect: tile)

    markColor.setFill()
    makeTPath(tile: tile).fill()

    gctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(size)x\(size) as PNG")
    }
    return png
}

// Note for anyone verifying this icon: do NOT inspect pixels by running
// `iconutil -c iconset` on the .icns and reading the PNGs it extracts. That
// round trip unpremultiplies with clipping, so every antialiased edge comes
// back blown out instead of the tile color and the artwork looks like it has
// a fringe it does not have. Inspect the PNGs this script writes into its
// temp .iconset instead.

// MARK: - Emit the iconset and run iconutil

// (base point size, scale) -> icon_<base>x<base>[@2x].png
let members: [(base: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

let fm = FileManager.default
let repoRoot = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()   // Scripts/
    .deletingLastPathComponent()   // repo root
let resources = repoRoot.appendingPathComponent("Resources")
let output = resources.appendingPathComponent("AppIcon.icns")

let iconset = fm.temporaryDirectory
    .appendingPathComponent("Taskwarrior-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for (base, scale) in members {
    let pixels = base * scale
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(base)x\(base)\(suffix).png"
    try renderIcon(size: pixels).write(to: iconset.appendingPathComponent(name))
    print("  \(name)  (\(pixels)x\(pixels))")
}

try fm.createDirectory(at: resources, withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed (\(iconutil.terminationStatus))\n".data(using: .utf8)!)
    exit(1)
}

let bytes = (try fm.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
print("✓ wrote \(output.path) (\(bytes) bytes)")
