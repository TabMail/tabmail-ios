/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// Laid over the chat pill's input field while dictating (the field's text dims behind it): TabMail
/// Voice's waveform, following the microphone's sound from the start, speech or not, and
/// rippling at rest while the words are transcribed. Nothing else: no language, and nothing when a dictation fails (the field simply
/// comes back), but a note once a transcription the server failed has been tried again for
/// `transcriptionRetryNoticeDelay` (`DictationController.showsRetryNote`). The waveform and its numbers are copied from TabMail Voice (`OverlayPanel.swift`).
struct DictationPillView: View {
    let controller: DictationController

    /// Shown once the transcription has been tried again for a while (`DictationController.
    /// showsRetryNote`). As TabMail Voice's pill.
    static let retryingMessage = "Server error, retrying…"

    var body: some View {
        Group {
            if controller.showsRetryNote {
                Text(Self.retryingMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Waveform(level: controller.level, colour: Self.waveformColour(hasVoice: controller.hasHeardSpeech))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The waveform's colour: washed out while the dictation waits for speech, vivid once
    /// speech is heard, a sign it is listening (owner, 2026-10-02).
    static func waveformColour(hasVoice: Bool) -> Color {
        hasVoice ? Palette.waveformVoiced : Palette.waveformWaiting
    }

    /// What VoiceOver reads for the waveform.
    var accessibilityLabel: String {
        switch controller.phase {
        case .idle: ""
        case .listening: "Listening"
        case .transcribing: controller.showsRetryNote ? Self.retryingMessage : "Transcribing"
        }
    }
}

/// TabMail Voice's thinking spinner (`SpinningRim` in its overlay): a faint track with a
/// gradient arc circling it, in the icon's blue → purple; while a server error is tried again,
/// both fade to the retry's colours (`Palette.retryArcStart` → `Palette.retryArcEnd`). The two sets
/// of colours are two layers circling together, one fading out as the other fades in over
/// `DictationConfig.colourTransition`, as TabMail Voice draws it.
struct DictationSpinner: View {
    var isRetrying = false

    var body: some View {
        TimelineView(.animation) { timeline in
            let turns = timeline.date.timeIntervalSinceReferenceDate * DictationConfig.thinkingRevolutionsPerSecond
            ZStack {
                Self.layer(Self.colours(isRetrying: false), turns: turns)
                    .animation(.easeInOut(duration: DictationConfig.colourTransition)) { $0.opacity(isRetrying ? 0 : 1) }
                Self.layer(Self.colours(isRetrying: true), turns: turns)
                    .animation(.easeInOut(duration: DictationConfig.colourTransition)) { $0.opacity(isRetrying ? 1 : 0) }
            }
            .padding(DictationConfig.thinkingRimWidth / 2)
        }
        .frame(width: DictationConfig.spinnerDiameter, height: DictationConfig.spinnerDiameter)
    }

    /// One set of the spinner's colours: its track and its arc, `turns` round.
    private static func layer(_ colours: (track: Color, arc: (start: Color, end: Color)), turns: Double) -> some View {
        ZStack {
            Circle()
                .stroke(colours.track.opacity(DictationConfig.thinkingTrackOpacity), lineWidth: DictationConfig.thinkingRimWidth)
            Circle()
                .trim(from: 0, to: DictationConfig.thinkingArcFraction)
                .stroke(
                    AngularGradient(
                        colors: [colours.arc.start.opacity(0), colours.arc.start, colours.arc.end],
                        center: .center,
                        startAngle: .zero, endAngle: .degrees(360 * DictationConfig.thinkingArcFraction)
                    ),
                    style: StrokeStyle(lineWidth: DictationConfig.thinkingRimWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(360 * turns.truncatingRemainder(dividingBy: 1)))
        }
    }

    /// The track's colour and the arc's two ends: the brand blue → purple, or the retry's colours
    /// while retrying.
    static func colours(isRetrying: Bool) -> (track: Color, arc: (start: Color, end: Color)) {
        if isRetrying {
            return (Palette.retryArcStart, (Palette.retryArcStart, Palette.retryArcEnd))
        }
        return (colour(at: 0), (colour(at: 0), colour(at: DictationConfig.thinkingArcEndColour)))
    }

    /// A point on the TabMail icon's blue → purple gradient (0 = blue, 1 = purple).
    static func colour(at fraction: Double) -> Color {
        Palette.brandBlue.mix(with: Palette.brandPurple, by: fraction, in: .device)
    }
}

/// Voice waveform: bars follow the incoming sound level with a travelling ripple.
private struct Waveform: View {
    let level: Float
    let colour: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: DictationConfig.meterBarSpacing) {
                ForEach(0..<DictationConfig.meterBarCount, id: \.self) { index in
                    Capsule()
                        .fill(colour)
                        .frame(width: DictationConfig.meterBarWidth, height: barHeight(index, time: time))
                }
            }
            .frame(height: DictationConfig.meterMaxBarHeight)
        }
        .animation(.easeInOut(duration: DictationConfig.colourTransition), value: colour)
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
