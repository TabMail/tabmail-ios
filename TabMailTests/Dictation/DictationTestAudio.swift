/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AVFoundation
import Foundation
@testable import TabMail

/// Synthetic dictation audio for the long-dictation tests (ADR-IOS-087), as TabMail Voice's tests
/// make it: 16 kHz mono floats, as the recorder keeps them.
enum DictationTestAudio {
    static let rate = DictationConfig.recordingSampleRate

    /// A seeded random source (mulberry32), so every run hears the same audio.
    struct Random {
        private var state: UInt32

        init(seed: UInt32) { state = seed }

        mutating func next() -> Double {
            state &+= 0x6D2B_79F5
            var t = state
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
    }

    /// Speech-like sound: a tone whose loudness rises and falls four times a second, as syllables
    /// do, over the room's noise. Its dips between syllables are short, never a pause.
    static func speech(_ seconds: Double, _ random: inout Random, amplitude: Float = 0.25) -> [Float] {
        (0..<Int((seconds * rate).rounded())).map { index in
            let t = Double(index) / rate
            let syllable = 0.15 + 0.85 * abs(sin(2 * .pi * 2 * t))
            return amplitude * Float(syllable * sin(2 * .pi * 220 * t)) + Float(random.next() - 0.5) * 0.004
        }
    }

    /// The room alone: faint noise.
    static func room(_ seconds: Double, _ random: inout Random) -> [Float] {
        (0..<Int((seconds * rate).rounded())).map { _ in Float(random.next() - 0.5) * 0.004 }
    }

    /// `samples` as 16-bit PCM, as the recorder stores them.
    static func pcm16(_ samples: [Float]) -> [Int16] {
        samples.map { sample in
            let clamped = max(-1, min(1, sample))
            return Int16((clamped < 0 ? clamped * 32_768 : clamped * 32_767).rounded())
        }
    }

    /// `samples` as microphone buffers of `frames` each, at 16 kHz.
    static func buffers(_ samples: [Float], frames: Int = Int(DictationConfig.audioTapBufferSize)) -> [AVAudioPCMBuffer] {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        return stride(from: 0, to: samples.count, by: frames).map { offset in
            let count = min(frames, samples.count - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
            }
            return buffer
        }
    }
}
