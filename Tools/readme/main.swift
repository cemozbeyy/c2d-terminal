// Renders the README artwork into .github/readme/ with SwiftUI's ImageRenderer.
// Buddy is the app's own BuddyMascotView (copied out of App/Views/BuddyView.swift at build time), the
// screenshot and demo frame are real captures from Website/shots. Colours follow the landing page.
//
//   ./Tools/readme/render.sh
import AppKit
import SwiftUI

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let out = root.appendingPathComponent(".github/readme")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

extension Color {
    init(hex: UInt32) { self.init(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255) }
    static let cream = Color(hex: 0xfbf6ee), ink = Color(hex: 0x2d2723), inkSoft = Color(hex: 0x5d5550)
    static let lav = Color(hex: 0xc9bcff), lavD = Color(hex: 0x6f5cf1), peach = Color(hex: 0xffd3b8)
    static let mint = Color(hex: 0xc6ecd9), butter = Color(hex: 0xffeaa6), sky = Color(hex: 0xcfe6ff), rose = Color(hex: 0xffd0dc)
    static let coral = Color(hex: 0xe4766a), claude = Color(hex: 0xd97757), green = Color(hex: 0x2f9e6e), amber = Color(hex: 0xe0a21b), blue = Color(hex: 0x3f7fe0)
}

func image(_ name: String) -> NSImage { NSImage(contentsOf: root.appendingPathComponent("Website/shots/\(name)"))! }

/// Top-level code runs on the main thread; ImageRenderer just needs the compiler to know it.
func save<V: View>(_ view: V, _ name: String, scale: CGFloat = 2) {
    MainActor.assumeIsolated {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .light))
        r.scale = scale
        guard let cg = r.cgImage else { fatalError("render failed: \(name)") }
        let rep = NSBitmapImageRep(cgImage: cg)
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        print("wrote .github/readme/\(name) \(cg.width)x\(cg.height)")
    }
}

let rounded = { (size: CGFloat, weight: Font.Weight) in Font.system(size: size, weight: weight, design: .rounded) }
let hand = { (size: CGFloat) in Font.custom("Bradley Hand", size: size) }

struct Sparkle: View {
    var color: Color; var size: CGFloat
    var body: some View { Image(systemName: "sparkle").font(.system(size: size, weight: .bold)).foregroundStyle(color) }
}

/// Cream card with soft lavender/peach glows; every graphic sits on one so it reads in GitHub's dark mode too.
struct Panel<Content: View>: View {
    var tint: Color = .cream
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background {
                ZStack {
                    tint
                    Circle().fill(Color.lav.opacity(0.35)).frame(width: 520).blur(radius: 90).offset(x: 360, y: -160)
                    Circle().fill(Color.peach.opacity(0.35)).frame(width: 420).blur(radius: 90).offset(x: -380, y: 180)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

// MARK: Hero

let hero = Panel {
    HStack(alignment: .center, spacing: 44) {
        ZStack {
            BuddyMascotView(size: 300, animated: false)
            Sparkle(color: .butter, size: 26).offset(x: -150, y: -40)
            Sparkle(color: .lav, size: 20).offset(x: 140, y: -130)
            Sparkle(color: .lavD.opacity(0.6), size: 28).offset(x: 150, y: 90)
        }
        .frame(width: 320, height: 320)
        VStack(alignment: .leading, spacing: 14) {
            Text("C2D Terminal").font(rounded(68, .heavy)).foregroundStyle(Color.ink)
            Text("Cozy terminal. Serious work.").font(rounded(32, .bold))
                .foregroundStyle(LinearGradient(colors: [.lavD, Color(hex: 0xb05fd1), Color(hex: 0xe07a5f)], startPoint: .leading, endPoint: .trailing))
            Text("A native macOS workspace where your terminals, editor, Git and AI coding agents work side by side.")
                .font(rounded(21, .regular)).foregroundStyle(Color.inkSoft).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            Text("Agents propose. You decide.").font(rounded(21, .semibold)).foregroundStyle(Color.ink)
        }
        .frame(width: 560, alignment: .leading)
    }
    .padding(.horizontal, 56).padding(.vertical, 48)
    .frame(width: 1100)
    .overlay(alignment: .topTrailing) {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Your development").font(hand(24))
            Text("sidekick  ↙").font(hand(24))
        }
        .foregroundStyle(Color.lavD).rotationEffect(.degrees(-8)).padding(.top, 34).padding(.trailing, 40)
    }
}
save(hero, "hero.png")

// MARK: Buttons (each wrapped in a link in the README)

struct Pill: View {
    var icon: String; var title: String; var dark = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 17, weight: .bold))
            Text(title).font(rounded(19, .semibold))
        }
        .foregroundStyle(dark ? Color.white : Color.ink)
        .padding(.horizontal, 24).frame(height: 54)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dark ? Color.lavD : Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(dark ? Color.clear : Color.ink.opacity(0.14), lineWidth: 1.5))
        .padding(3)
    }
}
save(Pill(icon: "play.fill", title: "Watch the demo (45 s)", dark: true), "btn-demo.png")
save(Pill(icon: "terminal", title: "Build from source"), "btn-build.png")
save(Pill(icon: "heart", title: "Contribute"), "btn-contribute.png")

// MARK: Screenshot, framed

let shot = image("shot1.jpg")
let framed = Image(nsImage: shot).resizable().aspectRatio(contentMode: .fit).frame(width: 1060)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.black.opacity(0.25), lineWidth: 1))
    .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
    .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 40)
save(framed, "screenshot.png")

// MARK: Feature strip

struct Feature: View {
    var icon: String; var tint: Color; var title: String; var detail: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 46, height: 46).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(rounded(16, .bold)).foregroundStyle(Color.ink)
                Text(detail).font(rounded(13.5, .regular)).foregroundStyle(Color.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
let features = Panel {
    VStack(spacing: 22) {
        HStack(spacing: 18) {
            Feature(icon: "apple.terminal", tint: .lavD, title: "Real terminals", detail: "Genuine PTY, your shell")
            Feature(icon: "asterisk", tint: .claude, title: "Claude Code", detail: "Sessions in C2D's own panes")
            Feature(icon: "doc.text", tint: .lavD, title: "Editor & explorer", detail: "Write, search, jump to file:line")
        }
        HStack(spacing: 18) {
            Feature(icon: "arrow.triangle.branch", tint: .coral, title: "Git", detail: "Hunks, branches, worktrees")
            Feature(icon: "checklist", tint: .green, title: "Tasks", detail: "Plan, then hand to an agent")
            Feature(icon: "gauge.with.dots.needle.33percent", tint: .blue, title: "Token Saver", detail: "See and trim your context")
        }
    }
    .padding(.horizontal, 36).padding(.vertical, 30).frame(width: 1100)
}
save(features, "features.png")

// MARK: Demo card (the whole image links to the video)

let poster = image("demo-poster.jpg")
let demo = Panel(tint: Color(hex: 0xf3effd)) {
    HStack(spacing: 44) {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit).frame(width: 470)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    Circle().fill(.black.opacity(0.55)).frame(width: 84)
                        .overlay(Image(systemName: "play.fill").font(.system(size: 34)).foregroundStyle(.white).offset(x: 3))
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 3))
                }
            Text("0:45").font(rounded(15, .bold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(.black.opacity(0.7))).padding(12)
        }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
        VStack(alignment: .leading, spacing: 14) {
            Text("See it in action").font(rounded(40, .heavy)).foregroundStyle(Color.ink)
            Text("A quick 45-second tour: open a project, work beside Claude Code, run the tests and review the changes in Git.")
                .font(rounded(19, .regular)).foregroundStyle(Color.inkSoft).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            HStack(spacing: 10) {
                Image(systemName: "play.fill").font(.system(size: 16, weight: .bold))
                Text("Watch the demo (45 s)").font(rounded(19, .semibold))
            }
            .foregroundStyle(.white).padding(.horizontal, 26).frame(height: 54)
            .background(Capsule().fill(Color.lavD)).padding(.top, 6)
            Text("Real workflow. Not just a terminal.").font(hand(22)).foregroundStyle(Color.lavD)
                .rotationEffect(.degrees(-4)).padding(.top, 8)
        }
        .frame(width: 440, alignment: .leading)
    }
    .padding(.horizontal, 48).padding(.vertical, 44).frame(width: 1100)
}
save(demo, "demo.png")

// MARK: Small icons for the text sections

let icons: [(String, String, Color)] = [
    ("icon-open-source", "chevron.left.forwardslash.chevron.right", .lavD),
    ("icon-privacy", "checkmark.shield", .green),
    ("icon-early", "star", .amber),
    ("icon-one-place", "square.grid.2x2", .lavD),
    ("icon-control", "person.crop.circle.badge.checkmark", .lavD),
    ("icon-workflow", "bolt", .lavD),
    ("icon-tokens", "gauge.with.dots.needle.33percent", .blue),
]
for (name, symbol, tint) in icons {
    save(Image(systemName: symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(tint)
        .frame(width: 56, height: 56).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.14))), "\(name).png")
}
