/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import TabMail

/// The real speech detector (Apple's sound classifier) against speech and against a room: a
/// dictation starts recording on a voice, never on noise or hum.
@MainActor
struct SoundClassifierSpeechDetectorTests {
    private final class Heard: Sendable {
        let speech = Mutex(0)
        let failures = Mutex(0)
    }

    private func detector(_ heard: Heard) -> SoundClassifierSpeechDetector {
        SoundClassifierSpeechDetector(
            onSpeech: { heard.speech.withLock { $0 += 1 } },
            onFailure: { _ in heard.failures.withLock { $0 += 1 } }
        )
    }

    /// `samples` at 48 kHz in microphone-sized buffers.
    private func buffers(_ samples: [Float], sampleRate: Double = 48_000) -> [AVAudioPCMBuffer] {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        return stride(from: 0, to: samples.count, by: Int(DictationConfig.audioTapBufferSize)).map { start in
            let count = min(Int(DictationConfig.audioTapBufferSize), samples.count - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count { buffer.floatChannelData![0][index] = samples[start + index] }
            return buffer
        }
    }

    /// Four seconds of white noise, then four of mains hum, at a room's level: never speech.
    @Test func noiseAndHumAreNotSpeech() async {
        let heard = Heard()
        let detector = detector(heard)
        var seed: UInt32 = 12_345
        let noise = (0..<192_000).map { _ -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed) / Float(UInt32.max) - 0.5) * 0.04
        }
        let hum = (0..<192_000).map { 0.05 * sin(2 * .pi * 60 * Float($0) / 48_000) }
        for buffer in buffers(noise + hum) { detector.analyze(buffer) }

        #expect(await detector.finish() == false)
        #expect(heard.speech.withLock { $0 } == 0)
        #expect(heard.failures.withLock { $0 } == 0)
    }

    /// A spoken sentence (the system's speech synthesiser) is heard, once.
    @Test func aSpokenSentenceIsHeard() async throws {
        let spoken = try await synthesize("Move the meeting with the design team to Thursday afternoon, and send them the notes.")
        try #require(!spoken.isEmpty)
        let heard = Heard()
        let detector = detector(heard)
        for buffer in spoken { detector.analyze(buffer) }

        #expect(await detector.finish())
        #expect(heard.speech.withLock { $0 } == 1)
        #expect(heard.failures.withLock { $0 } == 0)
    }

    private func synthesize(_ text: String) async throws -> [AVAudioPCMBuffer] {
        let synthesizer = AVSpeechSynthesizer()
        let collected = Mutex<[AVAudioPCMBuffer]>([])
        let done = Mutex(false)
        synthesizer.write(AVSpeechUtterance(string: text)) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            // An empty buffer marks the end.
            guard pcm.frameLength > 0 else {
                done.withLock { $0 = true }
                return
            }
            collected.withLock { $0.append(pcm) }
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while !done.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        withExtendedLifetime(synthesizer) {}
        return collected.withLock { $0 }
    }
}
