/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import AVFoundation
import Foundation
import Testing
@testable import TabMail

/// Copied from TabMail Voice's tests with the recorder itself.
struct DictationAudioRecorderTests {
    /// A microphone-like float buffer: `seconds` of a sine at `amplitude`, in every channel.
    private func sine(seconds: Double, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                data[frame] = amplitude * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
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
