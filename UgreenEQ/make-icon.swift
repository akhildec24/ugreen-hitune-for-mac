// Generates AppIcon.icns in a dot-matrix style: off-white squircle, near-black dots, one red accent.
// EQ sliders drawn on an 11x11 dot grid. Usage: swiftc make-icon.swift -o make-icon && ./make-icon <outdir>
import AppKit

let N = 11
// slider tracks at columns 1, 5, 9; knobs are 3 wide x 2 tall blocks of dots
struct Knob { let col: Int; let row: Int; let red: Bool }
let knobs = [Knob(col: 1, row: 7, red: false), Knob(col: 5, row: 2, red: true), Knob(col: 9, row: 5, red: false)]
let trackCols = [1, 5, 9]

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let b = NSRect(x: s * 0.0977, y: s * 0.0977, width: s * 0.8047, height: s * 0.8047)
    NSColor(srgbRed: 0.918, green: 0.918, blue: 0.906, alpha: 1).setFill()          // warm off-white
    NSBezierPath(roundedRect: b, xRadius: b.width * 0.225, yRadius: b.width * 0.225).fill()

    let ink = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.08, alpha: 1)
    let red = NSColor(srgbRed: 0.843, green: 0.098, blue: 0.145, alpha: 1)           // #D71925
    let area = b.width * 0.62
    let pitch = area / CGFloat(N)
    let r = pitch * 0.36
    let ox = b.midX - area / 2 + pitch / 2
    let oy = b.midY - area / 2 + pitch / 2

    func center(_ c: Int, _ row: Int) -> NSPoint { NSPoint(x: ox + CGFloat(c) * pitch, y: oy + CGFloat(N - 1 - row) * pitch) }
    func dot(_ c: Int, _ row: Int, _ color: NSColor) {
        let p = center(c, row)
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
    }

    var on = [[NSColor?]](repeating: [NSColor?](repeating: nil, count: N), count: N)   // [row][col]
    for c in trackCols { for row in 0..<N { on[row][c] = ink } }
    for k in knobs { for dr in 0..<2 { for dc in -1...1 { on[k.row + dr][k.col + dc] = k.red ? red : ink } } }

    let showOff = px >= 64                                                            // faint matrix only when large enough
    for row in 0..<N { for c in 0..<N {
        if let color = on[row][c] { dot(c, row, color) }
        else if showOff { dot(c, row, ink.withAlphaComponent(0.10)) }
    } }
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                              ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes { try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png")) }
print("wrote \(sizes.count) icons to \(out)")
