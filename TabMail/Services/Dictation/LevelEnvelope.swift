/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

/// Adapts the waveform to the range of sound coming in, so it follows the voice on any
/// microphone: two exponential-moving-average envelopes of the loudness (dB). The floor follows
/// quieter readings fast and louder ones slowly; the peak follows louder readings fast and
/// quieter ones slowly. Each reading shows where it sits between them.
///
/// Warm-up: a moving average starts out anchored to its first readings (a start-up blip could
/// hold the floor down for seconds). Each weight is therefore at least 1/n for the n-th reading,
/// making the envelopes plain running averages while few readings exist; the window grows until
/// the EMA's own weight takes over (n = 1/alpha, ≈ 4 s for the slow side).
struct LevelEnvelope {
    private var floor: Float?
    private var peak: Float?
    private var count = 0

    mutating func level(forDecibels decibels: Float) -> Float {
        count += 1
        let floor = Self.follow(floor ?? decibels, to: decibels, fastWhenBelow: true, count: count)
        let peak = Self.follow(peak ?? decibels, to: decibels, fastWhenBelow: false, count: count)
        self.floor = floor
        self.peak = peak
        let top = max(peak, floor + DictationConfig.envelopeMinimumRange)
        return max(0, min(1, (decibels - floor) / (top - floor)))
    }

    private static func follow(_ value: Float, to reading: Float, fastWhenBelow: Bool, count: Int) -> Float {
        let fast = (reading < value) == fastWhenBelow
        let alpha = max(fast ? DictationConfig.envelopeFastAlpha : DictationConfig.envelopeSlowAlpha, 1 / Float(count))
        return value + (reading - value) * alpha
    }
}
