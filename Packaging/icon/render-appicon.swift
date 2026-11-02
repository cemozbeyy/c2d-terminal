#!/usr/bin/env swift
// Renders the C2D Terminal app icon (1024×1024 PNG, transparent corners) from the brand mark in Website/favicon.svg:
// the violet "window buddy" (title bar, traffic lights, eyes, `>_` prompt) on a Midnight Violet charcoal squircle
// (App/Design/ThemeManager.swift). Apple's macOS grid: 824 pt artwork centred on a 1024 canvas.
// Run: swift Packaging/icon/render-appicon.swift Packaging/icon/AppIcon-1024.png
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let N: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(N), pixelsHigh: Int(N), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
}
// Canvas is transparent; the squircle is the icon's silhouette (Finder applies no mask to classic icons).
let inset: CGFloat = 100
let sq = NSRect(x: inset, y: inset, width: N - 2 * inset, height: N - 2 * inset)   // 824×824
let squircle = NSBezierPath(roundedRect: sq, xRadius: 185, yRadius: 185)
// Soft drop shadow under the squircle (Apple icons carry a faint one).
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.shadowBlurRadius = 28
shadow.set()
hex(0x0C0E14).setFill(); squircle.fill()
NSGraphicsContext.current?.restoreGraphicsState()
// Charcoal gradient (panel → window) and a subtle border, as the app's surfaces.
NSGradient(starting: hex(0x1A1F2E), ending: hex(0x0C0E14))!.draw(in: squircle, angle: -90)
hex(0x343A4F).setStroke(); squircle.lineWidth = 6; squircle.stroke()

// The buddy: favicon geometry (viewBox 8 14 104 92 → window 96×84 at 12,18) scaled to ~70 % of the squircle.
let scale: CGFloat = 6.0                         // 96 * 6 = 576 pt wide
let winW: CGFloat = 96 * scale, winH: CGFloat = 84 * scale
let ox = (N - winW) / 2, oy = (N - winH) / 2 - 10
func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + (x - 12) * scale, y: oy + (84 - (y - 18)) * scale) }   // SVG y-down → AppKit y-up
let body = NSBezierPath(roundedRect: NSRect(x: ox, y: oy, width: winW, height: winH), xRadius: 26 * scale, yRadius: 26 * scale)
NSGraphicsContext.current?.saveGraphicsState()
let s2 = NSShadow(); s2.shadowColor = NSColor.black.withAlphaComponent(0.45); s2.shadowOffset = NSSize(width: 0, height: -10); s2.shadowBlurRadius = 30; s2.set()
hex(0x6F5CF1).setFill(); body.fill()
NSGraphicsContext.current?.restoreGraphicsState()
// Title bar: lighter violet, clipped to the body.
NSGraphicsContext.current?.saveGraphicsState(); body.addClip()
hex(0x8F80FF).setFill(); NSRect(x: ox, y: oy + winH - 24 * scale, width: winW, height: 24 * scale).fill()
NSGraphicsContext.current?.restoreGraphicsState()
for (i, c) in [0xFF8F86, 0xFFD36B, 0x7FE0A5].enumerated() {
    let p = P(30 + CGFloat(i) * 12, 29); let r = 4 * scale
    hex(UInt32(c)).setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
}
for x in [44.0, 76.0] as [CGFloat] {
    let e = P(x, 62); let r = 7 * scale
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: e.x - r, y: e.y - r, width: 2 * r, height: 2 * r)).fill()
    let pu = P(x, 63); let pr = 3.6 * scale
    hex(0x2D2723).setFill(); NSBezierPath(ovalIn: NSRect(x: pu.x - pr, y: pu.y - pr, width: 2 * pr, height: 2 * pr)).fill()
}
let prompt = NSBezierPath(); prompt.lineWidth = 3 * scale; prompt.lineCapStyle = .round; prompt.lineJoinStyle = .round
prompt.move(to: P(52, 80)); prompt.line(to: P(57, 84)); prompt.line(to: P(52, 88))
prompt.move(to: P(61, 88)); prompt.line(to: P(70, 88))
NSColor.white.setStroke(); prompt.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
