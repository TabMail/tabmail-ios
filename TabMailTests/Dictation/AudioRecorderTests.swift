/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AVFoundation
import Foundation
import Testing
@testable import TabMail

/// Copied from TabMail Voice's tests with the recorder itself.
struct DictationAudioRecorderTests {
    /// A microphone-like float buffer: `seconds` of a sine at `amplitude`, in every channel except
    /// the `silent` ones.
    private func sine(seconds: Double, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1, amplitude: Float = 0.5, silent: Set<Int> = []) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                data[frame] = silent.contains(channel) ? 0 : amplitude * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        return buffer
    }

    private func feed(_ recorder: AudioRecorder, _ buffer: AVAudioPCMBuffer, chunk: AVAudioFrameCount = 4096) {
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            let count = min(chunk, buffer.frameLength - offset)
            let part = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count)!
            part.frameLength = count
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(part.floatChannelData![channel], buffer.floatChannelData![channel] + Int(offset), Int(count) * MemoryLayout<Float>.size)
            }
            recorder.append(part)
            offset += count
        }
    }

    @Test func resamplesMicrophoneAudioTo16kMono16Bit() throws {
        let recorder = AudioRecorder()
        feed(recorder, sine(seconds: 1))
        let recording = try recorder.finish()

        #expect(recording.sampleRate == 16_000)
        // Resampler latency may hold back a few frames; within 1% of one second.
        #expect(abs(recording.duration - 1) < 0.01)
        #expect(recording.pcm.count % 2 == 0)
        #expect(!recording.truncated)
    }

    @Test func downmixesMultiChannelInput() throws {
        let recorder = AudioRecorder()
        feed(recorder, sine(seconds: 0.5, channels: 2))
        let recording = try recorder.finish()
        #expect(abs(recording.duration - 0.5) < 0.01)
    }

    /// Root-mean-square of 16-bit little-endian PCM, as a fraction of full scale.
    private func rms(_ pcm: Data) -> Double {
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Double(Int16(littleEndian: $0)) / Double(Int16.max) }
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count)).squareRoot()
    }

    /// The upload is the sound that was recorded: a tone keeps its loudness through the resampler
    /// (a sine's RMS is its amplitude / √2), and silence stays silent.
    @Test func theRecordingCarriesTheSoundItWasGiven() throws {
        let tone = AudioRecorder()
        feed(tone, sine(seconds: 1, amplitude: 0.5))
        let toneRMS = rms(try tone.finish().pcm)
        #expect(abs(toneRMS - 0.5 / 2.0.squareRoot()) < 0.05)

        let silence = AudioRecorder()
        feed(silence, sine(seconds: 1, amplitude: 0))
        let silentRecording = try silence.finish()
        // A second of audio was recorded (within the resampler's latency), all of it silent.
        #expect(abs(silentRecording.duration - 1) < 0.01)
        #expect(rms(silentRecording.pcm) < 0.001)
    }

    /// Every channel reaches the mono upload: a voice on either side of a stereo interface is heard.
    @Test func downmixKeepsEachChannel() throws {
        let left = AudioRecorder()
        feed(left, sine(seconds: 0.5, channels: 2, silent: [1]))
        let leftRMS = rms(try left.finish().pcm)

        let right = AudioRecorder()
        feed(right, sine(seconds: 0.5, channels: 2, silent: [0]))
        let rightRMS = rms(try right.finish().pcm)

        #expect(leftRMS > 0.1)
        #expect(rightRMS > 0.1)
        #expect(abs(leftRMS - rightRMS) < 0.02)
    }

    @Test func recordsWhenTheFirstAudioArrived() throws {
        #expect(try AudioRecorder().finish().firstBufferAt == nil)

        let before = ContinuousClock.now
        let recorder = AudioRecorder()
        feed(recorder, sine(seconds: 0.1))
        let first = try #require(try recorder.finish().firstBufferAt)
        #expect(first >= before)
    }

    /// Audio past the cap is dropped (and flagged), keeping uploads under the backend limit.
    @Test func stopsAtTheMaximumDuration() throws {
        let recorder = AudioRecorder(maxDuration: .seconds(1))
        feed(recorder, sine(seconds: 2))
        let recording = try recorder.finish()
        #expect(recording.truncated)
        #expect(recording.pcm.count == 16_000 * MemoryLayout<Int16>.size)
    }

    @Test func emptyRecording() throws {
        let recording = try AudioRecorder().finish()
        #expect(recording.pcm.isEmpty)
        #expect(recording.peakLevel == 0)
    }
}
