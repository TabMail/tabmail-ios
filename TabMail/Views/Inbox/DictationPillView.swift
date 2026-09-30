/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Laid over the chat pill's input field while dictating (the field's text dims behind it): TabMail
/// Voice's waveform, flat while it waits for speech, following the voice once someone speaks, and
/// rippling at rest while the words are transcribed. Nothing else: no language, and nothing when a dictation fails (the field simply
/// comes back), but a note while a transcription the server failed is tried again. The waveform and its numbers are copied from TabMail Voice (`OverlayPanel.swift`).
struct DictationPillView: View {
    let controller: DictationController

    /// Shown while the transcription is tried again (`DictationController.isRetrying`). As TabMail
    /// Voice's pill.
    static let retryingMessage = "Server error, retrying…"

    var body: some View {
        Group {
            if controller.isRetrying {
                Text(Self.retryingMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Waveform(level: controller.level, isFlat: controller.phase == .listening && !controller.hasHeardSpeech)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// What VoiceOver reads for the waveform.
    var accessibilityLabel: String {
        switch controller.phase {
        case .idle: ""
        case .listening: "Listening"
        case .transcribing: controller.isRetrying ? Self.retryingMessage : "Transcribing"
        }
    }
}

/// TabMail Voice's thinking spinner (`SpinningRim` in its overlay): a faint track with a
/// gradient arc circling it, in the icon's blue → purple.
struct DictationSpinner: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let turns = timeline.date.timeIntervalSinceReferenceDate * DictationConfig.thinkingRevolutionsPerSecond
            ZStack {
                Circle()
                    .stroke(Self.colour(at: 0).opacity(DictationConfig.thinkingTrackOpacity), lineWidth: DictationConfig.thinkingRimWidth)
                Circle()
                    .trim(from: 0, to: DictationConfig.thinkingArcFraction)
                    .stroke(
                        AngularGradient(
                            colors: [Self.colour(at: 0).opacity(0), Self.colour(at: 0), Self.colour(at: DictationConfig.thinkingArcEndColour)],
                            center: .center,
                            startAngle: .zero, endAngle: .degrees(360 * DictationConfig.thinkingArcFraction)
                        ),
                        style: StrokeStyle(lineWidth: DictationConfig.thinkingRimWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(360 * turns.truncatingRemainder(dividingBy: 1)))
            }
            .padding(DictationConfig.thinkingRimWidth / 2)
        }
        .frame(width: DictationConfig.spinnerDiameter, height: DictationConfig.spinnerDiameter)
    }

    /// A point on the TabMail icon's blue → purple gradient (0 = blue, 1 = purple).
    private static func colour(at fraction: Double) -> Color {
        let blue = (red: 0.0, green: 0x91 / 255.0, blue: 1.0)
        let purple = (red: 0x7B / 255.0, green: 0.0, blue: 1.0)
        return Color(
            red: blue.red + (purple.red - blue.red) * fraction,
            green: blue.green + (purple.green - blue.green) * fraction,
            blue: blue.blue + (purple.blue - blue.blue) * fraction
        )
    }
}

/// Voice waveform: bars follow the incoming sound level with a travelling ripple, or lie flat.
private struct Waveform: View {
    let level: Float
    let isFlat: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: DictationConfig.meterBarSpacing) {
                ForEach(0..<DictationConfig.meterBarCount, id: \.self) { index in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: DictationConfig.meterBarWidth, height: barHeight(index, time: time))
                }
            }
            .frame(height: DictationConfig.meterMaxBarHeight)
        }
    }

    private func barHeight(_ index: Int, time: TimeInterval) -> CGFloat {
        guard !isFlat else { return DictationConfig.meterMinBarHeight }
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
