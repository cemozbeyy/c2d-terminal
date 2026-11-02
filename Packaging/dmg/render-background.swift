#!/usr/bin/env swift
// Renders Packaging/dmg/background.png (660×400 pt @2x) for the install DMG: app icon slot, arrow, Applications slot.
// Run: swift Packaging/dmg/render-background.swift Packaging/dmg/background.png   (committed; CI does not re-render)
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "background.png"
let size = NSSize(width: 660, height: 400)
let scale: CGFloat = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Palette: Midnight Violet (App/Design/ThemeManager.swift default theme).
let bg = NSColor(srgbRed: 0.094, green: 0.098, blue: 0.137, alpha: 1)
let fg = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.96, alpha: 1)
let muted = NSColor(srgbRed: 0.62, green: 0.63, blue: 0.70, alpha: 1)
let accent = NSColor(srgbRed: 0.56, green: 0.47, blue: 0.95, alpha: 1)
bg.setFill(); NSRect(origin: .zero, size: size).fill()

// Arrow between the two icon slots (icons sit at y≈190 in Finder coordinates → 400-190 here).
let y: CGFloat = 400 - 190
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 265, y: y)); arrow.line(to: NSPoint(x: 395, y: y))
arrow.move(to: NSPoint(x: 372, y: y + 16)); arrow.line(to: NSPoint(x: 395, y: y)); arrow.line(to: NSPoint(x: 372, y: y - 16))
arrow.lineWidth = 5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
accent.setStroke(); arrow.stroke()

func draw(_ text: String, size pt: CGFloat, weight: NSFont.Weight, color: NSColor, at p: NSPoint) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: pt, weight: weight), .foregroundColor: color]
    let s = NSAttributedString(string: text, attributes: attrs)
    s.draw(at: NSPoint(x: p.x - s.size().width / 2, y: p.y))
}
draw("C2D Terminal", size: 26, weight: .bold, color: fg, at: NSPoint(x: 330, y: 330))
draw("Drag to Applications to install", size: 14, weight: .medium, color: muted, at: NSPoint(x: 330, y: 304))
draw("macOS 15+ · Apple Silicon", size: 11, weight: .regular, color: muted, at: NSPoint(x: 330, y: 36))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) \(Int(size.width * scale))×\(Int(size.height * scale))")
