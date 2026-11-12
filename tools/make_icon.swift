// Turns a square logo into a macOS-style app icon: rounded white tile on a 1024 canvas with margin and shadow.
// Usage: swift tools/make_icon.swift <logo.png> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]) else {
    fputs("usage: make_icon <logo.png> <out.png>\n", stderr)
    exit(1)
}

let size = 1024
let tile = NSRect(x: 100, y: 100, width: 824, height: 824) // Apple icon grid: 824pt body, 100pt margin
let radius: CGFloat = 185
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowBlurRadius = 20
shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.set()
NSColor.white.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Zoom past the logo's own white margin so the brush strokes fill the tile.
shape.addClip()
let s = src.size
let crop = NSRect(x: s.width * 0.12, y: s.height * 0.12, width: s.width * 0.76, height: s.height * 0.76)
src.draw(in: tile, from: crop, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
