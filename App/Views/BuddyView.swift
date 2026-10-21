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
    /// An agent is working: the antenna glows amber and pulses, and Buddy strikes a thinking pose (hand on
    /// chin, head tilted, a notebook whose pages turn, thought bubbles).
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
    /// Waving wins over thinking: a finished session matters more than one still running.
    private var thinking: Bool { working && !waving }
    private static let notebookCover = Color(red: 0.44, green: 0.36, blue: 0.95)
    private static let paper = Color(red: 0.99, green: 0.97, blue: 0.93)

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
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: thinking)
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
            ForEach(waving || thinking ? [-1.0] : [-1.0, 1.0], id: \.self) { side in
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
            head(s).rotationEffect(.degrees(thinking ? 7 : 0)).offset(y: -s * 0.1)
            if thinking {
                // Only this part animates per frame, and only while an agent works (30 fps is plenty for it).
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !animated)) { context in
                    let t = reduceMotion || !animated ? 0 : context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        notebook(s, t: t).offset(y: s * 0.31)
                        thoughtBubbles(s, t: t)
                    }
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                // Right arm bent up to the chin, drawn over the head so the hand rests on it.
                Capsule().fill(shell).frame(width: s * 0.085, height: s * 0.2)
                    .rotationEffect(.degrees(-37), anchor: .bottom)
                    .offset(x: s * 0.25, y: s * 0.2)
                Circle().fill(shell).frame(width: s * 0.1)
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: max(0.5, s * 0.006)))
                    .offset(x: s * 0.13, y: s * 0.14)
                    .transition(.opacity)
            }
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
                    .offset(x: side * s * 0.12 + (thinking ? s * 0.025 : 0), y: thinking ? -s * 0.075 : -s * 0.05)
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

    /// An open notebook in front of Buddy; one page turns every 1.6 s (static under Reduce Motion).
    private func notebook(_ s: CGFloat, t: Double) -> some View {
        let w = s * 0.19, h = s * 0.15
        let phase = t.truncatingRemainder(dividingBy: 1.6) / 1.6
        let turn = min(1, phase / 0.55)                         // flip during the first half, rest after
        let eased = turn * turn * (3 - 2 * turn)
        func page(_ lines: Int) -> some View {
            RoundedRectangle(cornerRadius: s * 0.012, style: .continuous).fill(Self.paper)
                .overlay(alignment: .top) {
                    VStack(alignment: .leading, spacing: s * 0.018) {
                        ForEach(0..<lines, id: \.self) { i in
                            Capsule().fill(Self.navy.opacity(0.22)).frame(width: w * (i == lines - 1 ? 0.45 : 0.7), height: max(0.6, s * 0.007))
                        }
                    }
                    .padding(.top, h * 0.2)
                }
                .frame(width: w, height: h)
        }
        return ZStack {
            // Cover peeking out behind the pages.
            RoundedRectangle(cornerRadius: s * 0.02, style: .continuous).fill(Self.notebookCover)
                .frame(width: w * 2 + s * 0.03, height: h + s * 0.03)
            HStack(spacing: s * 0.004) { page(4); page(3) }
            if !reduceMotion && animated && turn < 1 {
                page(3)
                    .rotation3DEffect(.degrees(-180 * eased), axis: (x: 0, y: 1, z: 0), anchor: .leading, perspective: 0.2)
                    .offset(x: w / 2 + s * 0.002)
            }
            Capsule().fill(Self.notebookCover.opacity(0.9)).frame(width: max(1, s * 0.012), height: h)   // spine
        }
        .rotation3DEffect(.degrees(28), axis: (x: 1, y: 0, z: 0), perspective: 0.5)   // tilted towards Buddy
        .shadow(color: .black.opacity(0.22), radius: s * 0.015, y: s * 0.01)
    }

    /// Three small bubbles rising beside the head, lighting up one after another.
    private func thoughtBubbles(_ s: CGFloat, t: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let wave = reduceMotion || !animated ? 1 : 0.5 + 0.5 * sin((t * 4) - Double(i) * 0.9)
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(Self.blue.opacity(0.35), lineWidth: max(0.5, s * 0.006)))
                    .frame(width: s * (0.035 + 0.018 * Double(i)))
                    .opacity(0.45 + 0.55 * wave)
                    .scaleEffect(0.85 + 0.15 * wave)
                    .offset(x: -s * (0.36 + 0.055 * Double(i)), y: -s * (0.34 + 0.065 * Double(i)))
            }
        }
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
