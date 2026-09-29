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
    /// default speech-to-text model takes (AssemblyAI's Sync API, up to 120 seconds; backend
    /// ADR-022). The model for the other languages (backend ADR-024) takes longer.
    /// Also well under the backend's 10 MiB upload limit (~3.8 MB at 16 kHz 16-bit mono).
    static let maxRecordingDuration: Duration = .seconds(120)

    // MARK: Speech detection

    /// Nothing is recorded, and `maxRecordingDuration` doesn't start, until Apple's on-device
    /// sound classifier hears speech: background noise alone never records (owner, 2026-09-28).
    /// Its analysis window (seconds; the classifier allows 0.5–15, default 3). Measured
    /// 2026-09-28 on synthetic speech: at this window, speech was heard within a second of it
    /// starting.
    static let speechDetectionWindow: Double = 0.975
    /// `CMTime` timescale for the window (units per second).
    static let speechDetectionTimescale: Int32 = 1000
    /// The classifier's speech classes that start the recording. Not "babble": a crowd in the
    /// background.
    static let speechClassifications = ["speech", "whispering", "shout"]
    /// Confidence (0…1) that counts as speech. Measured 2026-09-28: speech 20 dB quieter than
    /// normal inside noise scored ≥ 0.91; white noise ≤ 0.20 and mains hum ≤ 0.03.
    static let speechConfidence: Double = 0.5
    /// Audio kept from before speech is heard, so the first word isn't clipped while the
    /// classifier makes up its mind. Counts toward `maxRecordingDuration`.
    static let speechPreRollDuration: Duration = .seconds(2)

    // MARK: Backend

    static let transcribePath = "/dictation/transcribe"
    /// Covers the upload, the transcription and the cleanup the backend runs in the same request
    /// under its own deadline (backend ADR-027; owner, 2026-09-28: 1.5 s at most).
    static let transcriptionRequestTimeout: TimeInterval = 45
    /// The languages the backend transcribes (backend ADR-024, `src/config/transcription.json`):
    /// its default model's 18, then the 12 it routes to a second model. Settings offers these;
    /// keep them in step with the backend.
    static let dictationLanguages = [
        "en", "es", "fr", "de", "it", "pt", "ar", "da", "nl", "fi", "he", "hi", "ja", "zh", "no", "sv", "tr", "vi",
        "cs", "el", "fa", "hu", "id", "ko", "mk", "ms", "pl", "ro", "ru", "th",
    ]

    // MARK: Dictionary (ADR-IOS-086)

    /// The words sent with each dictation: the backend takes at most 200 (backend ADR-025), half
    /// from the user's dictionary, which holds at most this many so all of them are always sent…
    static let dictionaryMaxEntries = 100
    /// …and half picked from what the dictation is about (`DictationContextTerms`).
    static let contextTermsMax = 100
    /// Longest a transcription waits for the context terms (seconds), which are picked while the
    /// user speaks; past it the transcription goes without them.
    static let contextTermsWait: TimeInterval = 0.2
    /// Each word is at most this many characters (UTF-16 code units, as the backend counts them)
    /// and this many space-separated words. As TabMail Voice's.
    static let dictionaryWordMaxChars = 50
    static let dictionaryWordMaxWords = 6
    /// After a dictation lands in the input field, the field is read this often, for this long, to
    /// learn the user's corrections to it. A correction counts once the field has not changed for
    /// one interval, or when the input is sent.
    static let correctionPollInterval: Duration = .milliseconds(500)
    static let correctionWatchDuration: Duration = .seconds(30)
    /// A correction is learned only if it changed at most this share of the dictation's words (more
    /// is a rewrite), and it respells a word rather than replacing it: the edit distance between the
    /// heard and the corrected spelling is at most this share of the longer ("Zivora" → "Xyvora" is
    /// 2 of 6).
    static let correctionMaxChangedShare = 0.5
    static let correctionMaxEditShare = 0.65
    /// A lowercase correction that keeps at least this share of the shorter spelling's start,
    /// changing only its end, is another form of the same word ("report" → "reports", "send" →
    /// "sent"), not learned.
    static let correctionMinStemShare = 0.5
    /// A corrected word shorter than this (characters) is not learned.
    static let correctionMinWordLength = 3
    /// Everyday English words, never learned: replacing one with another ("then" → "than") is a
    /// change of wording, not a name or term to spell. TabMail Voice's list.
    static let correctionCommonWords: Set<String> = Set("""
        about after again also always another any are around back because been before being best better
        between both but came can come could day did does done down each even every few find first for from
        get give going good got great had has have her here him his how into its just keep know last left
        like little long look made make many may might more most much must never new next not now off okay
        old once one only other our out over own put said same saw say see she should since some still
        such take than that the their them then there these they thing think this those though thought
        through too two under until upon use very want was way well went were what when where which while
        who why will with work would yes yet you your
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    // MARK: Screen context for the cleanup

    /// The app name the cleanup prompt is told the user is dictating into.
    static let contextAppName = "TabMail"
    /// Most recent chat turns included in the screen text.
    static let contextMaxChatMessages = 20
    /// Longest screen text sent (characters, the most recent kept, ending at the caret: about a
    /// paragraph). Owner, 2026-09-28: as in TabMail Voice, the cleanup gets only the text around
    /// the caret, since more context slows it (was 20,000). Bounds the cleanup model's input
    /// only; nothing is stored.
    static let contextMaxScreenChars = 500
    /// The backend's limit on each cleanup field (its `transcription.json` `cleanup.maxFieldChars`,
    /// ADR-027), in UTF-16 code units. Over it the backend refuses the whole request, the
    /// transcription included, so every field is cut to it (`DictationCleanup.variables`).
    static let cleanupFieldMaxUTF16 = 20_000

    // MARK: Waveform

    /// While dictating, the input field's text stays faintly visible behind the waveform, at this
    /// opacity.
    static let dimmedInputOpacity: Double = 0.15
    /// Number of bars in the waveform.
    static let meterBarCount = 9
    static let meterBarWidth: CGFloat = 3
    static let meterBarSpacing: CGFloat = 3
    static let meterMinBarHeight: CGFloat = 3
    static let meterMaxBarHeight: CGFloat = 18
    /// Bar height follows level^exponent (< 1 lifts quieter speech), times the gain.
    static let waveformLevelExponent: Double = 1
    static let waveformGain: Double = 1
    /// The bars always ripple this much (0…1), so the waveform looks alive between words and while
    /// the words are transcribed.
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

    // MARK: Transcribing spinner

    /// While the words are transcribed, the send button is TabMail Voice's thinking spinner
    /// (`apps/desktop/src/core/config.ts`): a faint track with a blue → purple arc circling it.
    static let spinnerDiameter: CGFloat = 24
    static let thinkingRimWidth: CGFloat = 2.5
    static let thinkingArcFraction: CGFloat = 0.7
    static let thinkingRevolutionsPerSecond: Double = 1.2
    static let thinkingTrackOpacity: Double = 0.2
    /// The arc runs from blue to this point on the blue → purple gradient: the full purple end
    /// reads reddish on the spinning arc.
    static let thinkingArcEndColour: Double = 0.6
}
