/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Shown in the chat pill's input field while dictating, as TabMail Voice's overlay: a warm-up
/// swirl until audio arrives, then a waveform pill following the voice, a circle with a spinning
/// rim while transcribing, and a message when the dictation fails. The views and their numbers
/// are copied from TabMail Voice (`OverlayPanel.swift`).
struct DictationPillView: View {
    let controller: DictationController

    enum Mode: Equatable {
        case hidden, swirl, listening, transcribing, message(String)
    }

    private var mode: Mode {
        switch controller.phase {
        case .idle: .hidden
        case .listening: controller.isHearing ? .listening : .swirl
        case .transcribing: .transcribing
        case .failed(let message): .message(message)
        }
    }

    var body: some View {
        ZStack {
            switch mode {
            case .hidden:
                EmptyView()
            case .swirl:
                GatheringSwirl()
                    .frame(height: DictationConfig.swirlCanvasHeight)
                    .transition(.opacity)
            case .listening, .transcribing, .message:
                Pill(mode: mode, level: controller.level)
                    .transition(.scale(scale: DictationConfig.pillAppearScale).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, minHeight: DictationConfig.swirlCanvasHeight)
        .animation(.spring(response: DictationConfig.pillSpringResponse, dampingFraction: DictationConfig.pillSpringDamping), value: mode)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch mode {
        case .hidden: ""
        case .swirl, .listening: "Listening"
        case .transcribing: "Transcribing"
        case .message(let text): text
        }
    }

    private struct Pill: View {
        let mode: Mode
        let level: Float

        private var isThinking: Bool { mode == .transcribing }

        var body: some View {
            HStack(spacing: DictationConfig.pillContentSpacing) {
                switch mode {
                case .transcribing:
                    // Shrinks back to a circle while the words are worked out.
                    Color.clear.frame(width: DictationConfig.pillHeight, height: DictationConfig.pillHeight)
                case .message(let text):
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Brand.gradient)
                    Text(text)
                        .font(.system(size: DictationConfig.pillFontSize, weight: .medium))
                        // The pill is light in light and dark mode alike.
                        .foregroundStyle(Color.black)
                        .lineLimit(DictationConfig.pillMaxTextLines)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    Waveform(level: level)
                }
            }
            .padding(.horizontal, isThinking ? 0 : DictationConfig.pillHorizontalPadding)
            .padding(.vertical, isThinking ? 0 : DictationConfig.pillVerticalPadding)
            .frame(minHeight: DictationConfig.pillHeight)
            // A capsule while one line tall; a rounded rectangle for longer messages, and a
            // circle (as wide as tall) while thinking.
            .background(Color(white: DictationConfig.pillFillWhite), in: Self.shape)
            .overlay {
                if isThinking {
                    SpinningRim()
                } else {
                    Self.shape.strokeBorder(Brand.gradient, lineWidth: DictationConfig.pillBorderWidth)
                }
            }
            .shadow(color: Brand.purple.opacity(DictationConfig.pillGlowOpacity), radius: DictationConfig.pillGlowRadius)
        }

        private static let shape = RoundedRectangle(cornerRadius: DictationConfig.pillHeight / 2, style: .continuous)
    }
}

/// The pill uses only the TabMail icon's colours: blue → purple.
private enum Brand {
    private static let blueRGB: (Double, Double, Double) = (0, 0x91 / 255, 1)
    private static let purpleRGB: (Double, Double, Double) = (0x7B / 255, 0, 1)
    static let blue = colour(at: 0)
    static let purple = colour(at: 1)
    static let gradient = LinearGradient(colors: [blue, purple], startPoint: .leading, endPoint: .trailing)

    /// A point on the blue → purple gradient (0 = blue, 1 = purple).
    static func colour(at fraction: Double) -> Color {
        Color(
            red: blueRGB.0 + (purpleRGB.0 - blueRGB.0) * fraction,
            green: blueRGB.1 + (purpleRGB.1 - blueRGB.1) * fraction,
            blue: blueRGB.2 + (purpleRGB.2 - blueRGB.2) * fraction
        )
    }
}

/// Particles spiral inward while the microphone warms up, then keep a tight orbit.
private struct GatheringSwirl: View {
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                let progress = min(1, elapsed / DictationConfig.swirlGatherSeconds)
                let eased = 1 - pow(1 - progress, 3)
                let radius = DictationConfig.swirlStartRadius
                    + (DictationConfig.swirlOrbitRadius - DictationConfig.swirlStartRadius) * eased
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let count = DictationConfig.swirlParticleCount
                for index in 0..<count {
                    let fraction = Double(index) / Double(count)
                    let angle = 2 * .pi * (fraction + elapsed * DictationConfig.swirlRevolutionsPerSecond)
                    // Each particle trails slightly further out, so the ring reads as a spiral.
                    let r = radius * (1 + fraction * DictationConfig.swirlSpiralSpread)
                    let point = CGPoint(x: centre.x + cos(angle) * r, y: centre.y + sin(angle) * r)
                    let dot = DictationConfig.swirlParticleSize * Self.blend(DictationConfig.swirlOuterParticleScale, fraction)
                    context.opacity = Self.blend(DictationConfig.swirlOuterParticleOpacity, fraction)
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)),
                        with: .color(Brand.colour(at: fraction))
                    )
                }
            }
        }
        .onAppear { start = Date() }
    }

    /// 1 for the innermost particle (`fraction` 0), falling linearly towards `outer`.
    private static func blend(_ outer: Double, _ fraction: Double) -> Double {
        outer + (1 - outer) * (1 - fraction)
    }
}

/// Loading indicator on the thinking circle's rim: a blue → violet arc with a fading tail,
/// circling over a faint blue ring.
private struct SpinningRim: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let turns = timeline.date.timeIntervalSinceReferenceDate * DictationConfig.thinkingRevolutionsPerSecond
            ZStack {
                Circle()
                    .stroke(Brand.blue.opacity(DictationConfig.thinkingTrackOpacity), lineWidth: DictationConfig.thinkingRimWidth)
                Circle()
                    .trim(from: 0, to: DictationConfig.thinkingArcFraction)
                    .stroke(
                        AngularGradient(
                            colors: [Brand.blue.opacity(0), Brand.blue, Brand.colour(at: DictationConfig.thinkingArcEndColour)],
                            center: .center,
                            startAngle: .zero, endAngle: .degrees(360 * DictationConfig.thinkingArcFraction)
                        ),
                        style: StrokeStyle(lineWidth: DictationConfig.thinkingRimWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(360 * turns.truncatingRemainder(dividingBy: 1)))
            }
            .padding(DictationConfig.thinkingRimWidth / 2)
        }
    }
}

/// Voice waveform: bars follow the incoming sound level with a travelling ripple.
private struct Waveform: View {
    let level: Float

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: DictationConfig.meterBarSpacing) {
                ForEach(0..<DictationConfig.meterBarCount, id: \.self) { index in
                    Capsule()
                        .fill(Brand.gradient)
                        .frame(width: DictationConfig.meterBarWidth, height: barHeight(index, time: time))
                }
            }
            .frame(height: DictationConfig.meterMaxBarHeight)
        }
    }

    private func barHeight(_ index: Int, time: TimeInterval) -> CGFloat {
        let count = DictationConfig.meterBarCount
        let centre = Double(count - 1) / 2
        let distance = abs(Double(index) - centre) / max(centre, 1)
        let weight = 1 - distance * (1 - DictationConfig.meterEdgeBarWeight)
        // Each bar ripples at its own speed, so the motion reads as a voice rather than a meter.
        let speed = DictationConfig.waveformRippleSpeed * (1 + DictationConfig.waveformSpeedVariance * sin(Double(index) * DictationConfig.waveformSpeedPhaseStep))
        let ripple = (sin(time * speed - Double(index) * DictationConfig.waveformRipplePhase) + 1) / 2
        let voice = pow(Double(level), DictationConfig.waveformLevelExponent) * DictationConfig.waveformGain
            * weight * (1 - DictationConfig.waveformRippleDepth + DictationConfig.waveformRippleDepth * ripple)
        let amount = min(1, DictationConfig.waveformIdleLevel * ripple + voice)
        let minHeight = DictationConfig.meterMinBarHeight
        return minHeight + CGFloat(amount) * (DictationConfig.meterMaxBarHeight - minHeight)
    }
}
