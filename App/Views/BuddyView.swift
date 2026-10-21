import SwiftUI

/// Buddy, the C2D mascot: a small blue toy robot with a `>_` face. Purely decorative — no chat, no AI,
/// no network. Drawn from layered SwiftUI shapes and gradients (a 2D take on a 3D toy, not a real render).
/// Animation is cheap and event-driven: one repeating float, a sleeping blink loop that dies with the view,
/// and a keyframed hop per click. Reduce Motion turns all of it off except the blink.
struct BuddyMascotView: View {
    var size: CGFloat
    /// Idle float + blink. Off for the tiny rail icon, which only reacts to hover.
    var animated = true
    var hovered = false
    /// Being carried (desktop pet drag): leans and grows a little, stops floating.
    var held = false
    /// Off: eyes shut, colours faded, a little "z". Used by the rail toggle while the pet is hidden.
    var asleep = false
    /// Bump to play one hop.
    var hop = 0
    /// An agent is working: the antenna glows amber and pulses.
    var working = false
    /// An agent finished (or needs you): the right arm waves until this goes false.
    var waving = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floating = false
    @State private var blinking = false
    @State private var pulse = false
    @State private var waveUp = false

    private static let blueLight = Color(red: 0.66, green: 0.85, blue: 1.0)
    private static let blue = Color(red: 0.36, green: 0.64, blue: 0.98)
    private static let blueDeep = Color(red: 0.18, green: 0.43, blue: 0.86)
    private static let navy = Color(red: 0.08, green: 0.12, blue: 0.24)
    private static let navyDeep = Color(red: 0.04, green: 0.07, blue: 0.16)
    private static let glow = Color(red: 0.58, green: 0.91, blue: 1.0)
    private static let amber = Color(red: 1.0, green: 0.78, blue: 0.25)
    private static let blush = Color(red: 1.0, green: 0.6, blue: 0.72)

    private var shell: LinearGradient {
        LinearGradient(colors: [Self.blueLight, Self.blue, Self.blueDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private var motion: Bool { animated && !reduceMotion }

    var body: some View {
        let s = size
        ZStack {
            // Ground shadow shrinks as Buddy floats up.
            Ellipse().fill(.black.opacity(0.18)).frame(width: s * 0.5, height: s * 0.06).blur(radius: s * 0.015)
                .scaleEffect(floating ? 0.85 : 1).offset(y: s * 0.46)
            figure(s)
                .offset(y: motion && !held ? (floating ? -s * 0.03 : s * 0.005) : 0)
                .keyframeAnimator(initialValue: Hop(), trigger: reduceMotion ? 0 : hop) { content, v in
                    content.scaleEffect(x: v.squash, y: 2 - v.squash, anchor: .bottom).offset(y: v.lift * s).rotationEffect(.degrees(v.tilt))
                } keyframes: { _ in
                    KeyframeTrack(\.squash) {
                        SpringKeyframe(1.08, duration: 0.08); SpringKeyframe(0.94, duration: 0.14); SpringKeyframe(1, duration: 0.3)
                    }
                    KeyframeTrack(\.lift) {
                        LinearKeyframe(0, duration: 0.08); SpringKeyframe(-0.12, duration: 0.16); SpringKeyframe(0, duration: 0.32, spring: .bouncy)
                    }
                    KeyframeTrack(\.tilt) {
                        LinearKeyframe(0, duration: 0.1); SpringKeyframe(-6, duration: 0.12); SpringKeyframe(5, duration: 0.12); SpringKeyframe(0, duration: 0.2)
                    }
                }
        }
        .frame(width: s, height: s)
        .rotationEffect(.degrees(reduceMotion ? 0 : held ? 8 : hovered ? -5 : 0))
        .scaleEffect(reduceMotion ? 1 : held ? 1.08 : hovered ? 1.06 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.55), value: held)
        .onAppear {
            guard motion else { return }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { floating = true }
        }
        .onChange(of: working, initial: true) { _, on in
            if on && !reduceMotion { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true } }
            else { withAnimation(.easeOut(duration: 0.2)) { pulse = false } }
        }
        .onChange(of: waving, initial: true) { _, on in
            if on && !reduceMotion { withAnimation(.easeInOut(duration: 0.28).repeatForever(autoreverses: true)) { waveUp = true } }
            else { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { waveUp = false } }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: waving)
        .task(id: animated) {
            // Blink every few seconds; the task is cancelled when the view leaves the screen.
            guard animated else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 3...5.5)))
                withAnimation(.easeIn(duration: 0.07)) { blinking = true }
                try? await Task.sleep(for: .milliseconds(110))
                withAnimation(.easeOut(duration: 0.1)) { blinking = false }
            }
        }
        .saturation(asleep ? 0.25 : 1)
        .opacity(asleep ? 0.75 : 1)
        .overlay(alignment: .topTrailing) {
            if asleep {
                Text("z").font(.system(size: size * 0.3, weight: .heavy, design: .rounded))
                    .foregroundStyle(Self.blue.opacity(0.8))
                    .offset(x: size * 0.12, y: -size * 0.12)
                    .transition(.scale(scale: 0.3, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: asleep)
        .accessibilityHidden(true)
    }

    private func figure(_ s: CGFloat) -> some View {
        ZStack {
            // Feet
            ForEach([-1.0, 1.0], id: \.self) { side in
                Capsule().fill(Self.blueDeep).frame(width: s * 0.13, height: s * 0.075).offset(x: side * s * 0.09, y: s * 0.4)
            }
            // Arms, tucked at the sides
            ForEach(waving ? [-1.0] : [-1.0, 1.0], id: \.self) { side in
                Capsule().fill(shell).frame(width: s * 0.085, height: s * 0.19)
                    .rotationEffect(.degrees(side * -22), anchor: .top)
                    .offset(x: side * s * 0.235, y: s * 0.22)
            }
            // Body with a little chest screen
            RoundedRectangle(cornerRadius: s * 0.13, style: .continuous).fill(shell)
                .overlay(alignment: .top) { Ellipse().fill(.white.opacity(0.35)).frame(width: s * 0.24, height: s * 0.05).blur(radius: s * 0.012).offset(y: s * 0.03) }
                .frame(width: s * 0.4, height: s * 0.27).offset(y: s * 0.245)
            RoundedRectangle(cornerRadius: s * 0.03, style: .continuous).fill(Self.navy)
                .overlay { Text(">_").font(.system(size: s * 0.05, weight: .heavy, design: .monospaced)).foregroundStyle(Self.glow) }
                .frame(width: s * 0.15, height: s * 0.08).offset(y: s * 0.235)
            // Antenna
            Capsule().fill(Self.blueDeep).frame(width: s * 0.025, height: s * 0.08).offset(y: -s * 0.41)
            let light = working ? Self.amber : Self.glow
            Circle().fill(RadialGradient(colors: [.white, light], center: .topLeading, startRadius: 0, endRadius: s * 0.05))
                .frame(width: s * 0.065)
                .shadow(color: light.opacity(working ? 1 : 0.8), radius: s * (working && pulse ? 0.06 : 0.02))
                .scaleEffect(working && pulse ? 1.25 : 1)
                .offset(y: -s * 0.45)
            // Ear bumps
            ForEach([-1.0, 1.0], id: \.self) { side in
                Circle().fill(LinearGradient(colors: [Self.blue, Self.blueDeep], startPoint: .top, endPoint: .bottom))
                    .frame(width: s * 0.12).offset(x: side * s * 0.425, y: -s * 0.1)
            }
            head(s).offset(y: -s * 0.1)
            if waving {
                // Raised right arm, drawn over the head so the hand shows beside it; swings while waving.
                Capsule().fill(shell).frame(width: s * 0.085, height: s * 0.19)
                    .rotationEffect(.degrees(waveUp && !reduceMotion ? -150 : -118), anchor: .top)
                    .offset(x: s * 0.39, y: s * 0.17)
                    .transition(.opacity)
            }
        }
    }

    private func head(_ s: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: s * 0.25, style: .continuous).fill(shell)
                .shadow(color: Self.blueDeep.opacity(0.45), radius: s * 0.03, y: s * 0.02)
            // Specular highlight + rim give the shell its volume.
            Ellipse().fill(.white.opacity(0.55)).frame(width: s * 0.42, height: s * 0.1).blur(radius: s * 0.02).offset(x: -s * 0.1, y: -s * 0.22)
            RoundedRectangle(cornerRadius: s * 0.25, style: .continuous).strokeBorder(.white.opacity(0.28), lineWidth: max(0.5, s * 0.008))
            // Face display
            RoundedRectangle(cornerRadius: s * 0.16, style: .continuous)
                .fill(LinearGradient(colors: [Self.navy, Self.navyDeep], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .topLeading) {
                    Ellipse().fill(.white.opacity(0.12)).frame(width: s * 0.22, height: s * 0.06).rotationEffect(.degrees(-12)).offset(x: s * 0.06, y: s * 0.04)
                }
                .frame(width: s * 0.62, height: s * 0.39)
                .shadow(color: .black.opacity(0.25), radius: s * 0.01, y: s * 0.006)
            // Eyes
            ForEach([-1.0, 1.0], id: \.self) { side in
                Capsule().fill(Self.glow).frame(width: s * 0.065, height: s * 0.1)
                    .scaleEffect(y: blinking || asleep ? 0.12 : 1)
                    .shadow(color: Self.glow.opacity(0.7), radius: s * 0.015)
                    .offset(x: side * s * 0.12, y: -s * 0.05)
            }
            // Cheeks + the prompt mouth
            ForEach([-1.0, 1.0], id: \.self) { side in
                Circle().fill(Self.blush.opacity(0.45)).frame(width: s * 0.06).blur(radius: s * 0.006).offset(x: side * s * 0.21, y: s * 0.04)
            }
            Text(">_").font(.system(size: s * 0.085, weight: .heavy, design: .monospaced)).foregroundStyle(Self.glow)
                .shadow(color: Self.glow.opacity(0.6), radius: s * 0.012).offset(y: s * 0.075)
        }
        .frame(width: s * 0.82, height: s * 0.58)
    }

    private struct Hop { var squash = 1.0; var lift = 0.0; var tilt = 0.0 }
}

/// Rail entry for the desktop pet: shows Buddy (or bounces it if already out). Highlighted while Buddy is
/// on the desktop; right-click to hide. Matches the destination buttons' size and selection style.
struct BuddyRailButton: View {
    private let pet = BuddyPet.shared
    @State private var hovered = false

    var body: some View {
        let on = pet.isVisible
        Button { pet.toggle() } label: {
            VStack(spacing: 4) {
                BuddyMascotView(size: 24, animated: false, hovered: hovered, asleep: !on)
                Text("Buddy").font(.system(size: 9.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
            .frame(width: 72, height: 52)
            .background(on ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Theme.panelRadius))
        }
        .buttonStyle(.plain).clickCursor()
        .onHover { hovered = $0 }
        .help(on ? "Buddy is on your desktop. Click to put Buddy to sleep." : "Buddy is asleep. Click to wake Buddy up.")
        .accessibilityLabel("Buddy")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
