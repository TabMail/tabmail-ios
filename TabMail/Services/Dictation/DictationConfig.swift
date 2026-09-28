/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AVFoundation
import CoreGraphics
import Foundation

/// Every tunable number for chat-pill dictation. The flow, the waveform and these values are
/// copied from TabMail Voice (`tabmail-voice/apps/macos/TabMailVoice/Config/DictationConfig.swift`),
/// which is the reference implementation; keep them in step.
enum DictationConfig {
    // MARK: Audio

    /// Frames per microphone tap callback (~85 ms at 48 kHz).
    static let audioTapBufferSize: AVAudioFrameCount = 4096
    /// Fixed loudness → 0…1 scale for the recording's peak-level diagnostics.
    static let levelQuietDecibels: Float = -50
    static let levelLoudDecibels: Float = -30
    /// Waveform (`LevelEnvelope`): per-buffer EMA weights. The floor and peak envelopes move this
    /// fraction toward a reading on their fast side (floor down, peak up)…
    static let envelopeFastAlpha: Float = 0.5
    /// …and this fraction on their slow side (≈ 4 s time constant at ~12 buffers/s).
    static let envelopeSlowAlpha: Float = 0.02
    /// The envelopes are at least this many dB apart, so a steady hum doesn't swing the bars
    /// full height. Small: a quiet mic's speech can sit only 2–5 dB above its room noise.
    static let envelopeMinimumRange: Float = 4
    /// Quieter than this is digital silence (the device starting): not yet hearing anything.
    static let silenceDecibels: Float = -80
    /// The waveform level moves this fraction of the way to a louder reading per buffer
    /// (0 = frozen, 1 = no smoothing)…
    static let levelAttack: Float = 0.7
    /// …and this much when it falls, so the waveform jumps with the voice and settles gently.
    static let levelRelease: Float = 0.25
    /// Upload format: 16 kHz mono 16-bit PCM WAV — what Whisper-class models consume natively,
    /// at ~32 KB per second of speech.
    static let recordingSampleRate: Double = 16_000
    /// Recording continues this long after the mic button is tapped to stop, so the last word
    /// isn't clipped.
    static let releaseTailDuration: Duration = .milliseconds(300)
    /// Recording stops and is sent automatically at this length: the most audio the backend's
    /// speech-to-text model takes (AssemblyAI's Sync API, up to 120 seconds; backend ADR-022).
    /// Also well under the backend's 10 MiB upload limit (~3.8 MB at 16 kHz 16-bit mono).
    static let maxRecordingDuration: Duration = .seconds(120)

    // MARK: Backend

    static let transcribePath = "/dictation/transcribe"
    /// The backend prompt that fixes recognition errors in a transcript using what is on screen.
    static let cleanupPrompt = "system_prompt_dictate_cleanup"
    static let transcriptionRequestTimeout: TimeInterval = 45
    /// Longest the cleanup may take (seconds); past it the transcript is used as heard.
    static let cleanupTimeout: TimeInterval = 3
    /// The languages the backend transcribes (backend ADR-024, `src/config/transcription.json`):
    /// its default model's 18, then the 12 it routes to a second model. Settings offers these;
    /// keep them in step with the backend.
    static let dictationLanguages = [
        "en", "es", "fr", "de", "it", "pt", "ar", "da", "nl", "fi", "he", "hi", "ja", "zh", "no", "sv", "tr", "vi",
        "cs", "el", "fa", "hu", "id", "ko", "mk", "ms", "pl", "ro", "ru", "th",
    ]

    // MARK: Screen context for the cleanup

    /// The app name the cleanup prompt is told the user is dictating into.
    static let contextAppName = "TabMail"
    /// Most recent chat turns included in the screen text.
    static let contextMaxChatMessages = 20
    /// Longest screen text sent (characters, the most recent kept). Bounds the cleanup model's
    /// input only; nothing is stored.
    static let contextMaxScreenChars = 20_000

    // MARK: Waveform pill

    static let pillFontSize: CGFloat = 13
    static let pillHeight: CGFloat = 26
    static let pillHorizontalPadding: CGFloat = 14
    /// Keeps text off the pill's rounded top and bottom when a message wraps.
    static let pillVerticalPadding: CGFloat = 5
    static let pillContentSpacing: CGFloat = 8
    static let pillMaxTextLines = 3
    static let pillBorderWidth: CGFloat = 1
    static let pillGlowOpacity: Double = 0.35
    static let pillGlowRadius: CGFloat = 8
    /// The pill grows out of the swirl from this fraction of its size.
    static let pillAppearScale: CGFloat = 0.2
    static let pillSpringResponse: Double = 0.25
    static let pillSpringDamping: Double = 0.75
    /// Warm-up swirl: particles spiral from `swirlStartRadius` to `swirlOrbitRadius`.
    static let swirlParticleCount = 14
    static let swirlStartRadius: Double = 36
    static let swirlOrbitRadius: Double = 7
    static let swirlSpiralSpread: Double = 0.6
    static let swirlGatherSeconds: Double = 0.3
    static let swirlRevolutionsPerSecond: Double = 1.4
    static let swirlParticleSize: Double = 5
    /// The outermost particle's size and opacity, as a share of the innermost's (full) ones.
    static let swirlOuterParticleScale: Double = 0.5
    static let swirlOuterParticleOpacity: Double = 0.35
    /// Height the swirl is drawn in, inside the input bar.
    static let swirlCanvasHeight: CGFloat = 44
    /// Number of bars in the pill's waveform.
    static let meterBarCount = 9
    static let meterBarWidth: CGFloat = 3
    static let meterBarSpacing: CGFloat = 3
    static let meterMinBarHeight: CGFloat = 3
    static let meterMaxBarHeight: CGFloat = 18
    /// The listening pill's height: the waveform between the pill's vertical padding.
    static let listeningPillHeight = max(pillHeight, meterMaxBarHeight + 2 * pillVerticalPadding)
    /// The language badge left of the waveform: a circle as tall as the waveform, so the pill keeps
    /// its height, inset so it is concentric with the pill's rounded end.
    static let languageBadgeDiameter: CGFloat = meterMaxBarHeight
    static let languageBadgeInset: CGFloat = (listeningPillHeight - languageBadgeDiameter) / 2
    static let languageBadgeFontSize: CGFloat = 8
    /// Bar height follows level^exponent (< 1 lifts quieter speech), times the gain.
    static let waveformLevelExponent: Double = 1
    static let waveformGain: Double = 1
    /// The bars always ripple this much (0…1) while listening, so the pill looks alive between words.
    static let waveformIdleLevel: Double = 0.05
    /// Each bar's ripple speed differs by up to this fraction, so the motion looks organic.
    static let waveformSpeedVariance: Double = 0.2
    /// Phase step (radians per bar) that spreads the speed variance across the bars.
    static let waveformSpeedPhaseStep: Double = 1.7
    /// Outer bars reach this fraction of the centre bar's height.
    static let meterEdgeBarWeight: Double = 0.45
    /// Travelling ripple across the bars (radians per second, radians per bar, share of height).
    static let waveformRippleSpeed: Double = 9
    static let waveformRipplePhase: Double = 0.7
    static let waveformRippleDepth: Double = 0.25
    /// While transcribing, the pill is a circle with a gradient arc circling its rim.
    static let thinkingRimWidth: CGFloat = 2.5
    static let thinkingArcFraction: CGFloat = 0.7
    static let thinkingRevolutionsPerSecond: Double = 1.2
    static let thinkingTrackOpacity: Double = 0.2
    /// The arc runs from blue to this point on the blue → purple gradient: the full purple end
    /// reads reddish on the spinning arc.
    static let thinkingArcEndColour: Double = 0.6
    /// Pill fill: a soft off-white (pure white glared).
    static let pillFillWhite: Double = 0.96
    /// How long an error message stays in the input bar.
    static let errorDisplayDuration: Duration = .seconds(3)
}
