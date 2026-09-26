/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

/// Levels measured on a quiet display microphone: room noise ≈ −45 dB, short utterances peak
/// ≈ −42.5 dB, longer speech −35 to −40 dB.
struct DictationLevelEnvelopeTests {
    private func feed(_ envelope: inout LevelEnvelope, _ decibels: Float, times: Int) -> Float {
        var level: Float = 0
        for _ in 0..<times { level = envelope.level(forDecibels: decibels) }
        return level
    }

    /// Speech only 2.5 dB over the room (a short, quiet dictation) must still move the waveform.
    @Test func quietMicSpeechBarelyAboveTheRoomMoves() {
        var envelope = LevelEnvelope()
        _ = feed(&envelope, -45, times: 30)
        #expect(envelope.level(forDecibels: -42.5) > 0.4)
    }

    /// Adapts to the range coming in: after speech, the loud end sits near the speech, so louder
    /// syllables read higher than softer ones instead of all pinning at full.
    @Test func adaptsToTheIncomingRange() {
        var envelope = LevelEnvelope()
        for _ in 0..<10 {
            _ = feed(&envelope, -60, times: 3)
            _ = feed(&envelope, -20, times: 3)
        }
        let loud = envelope.level(forDecibels: -20)
        let medium = envelope.level(forDecibels: -35)
        #expect(loud > 0.9)
        #expect(medium > 0.2 && medium < loud - 0.2)
    }

    /// Warm-up: a start-up blip (−70 dB) must not anchor the floor, so within the first second of
    /// room noise (−45) and speech (−38) the two already read clearly apart. With a fixed 0.02
    /// weight the floor stayed near −70 and room noise read ≈ 0.7.
    @Test func settlesWithinTheFirstSecond() {
        var envelope = LevelEnvelope()
        _ = feed(&envelope, -70, times: 3)
        for _ in 0..<6 {
            _ = envelope.level(forDecibels: -45)
            _ = envelope.level(forDecibels: -38)
        }
        #expect(envelope.level(forDecibels: -45) < 0.4)
        #expect(envelope.level(forDecibels: -38) > 0.6)
    }

    /// A steady hum settles low rather than holding the bars up.
    @Test func steadySoundSettlesLow() {
        var envelope = LevelEnvelope()
        #expect(feed(&envelope, -45, times: 60) < 0.1)
    }
}
