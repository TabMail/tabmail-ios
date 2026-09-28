/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

@preconcurrency import AVFoundation
import SoundAnalysis
import Synchronization

/// Tells when someone starts speaking into a dictation. Tests substitute one that decides by
/// buffer.
protocol SpeechDetecting: AnyObject, Sendable {
    /// Called with every captured buffer, on the audio render thread.
    func analyze(_ buffer: AVAudioPCMBuffer)
    /// Analyses what is still buffered, then reports whether speech was heard at all.
    func finish() async -> Bool
}

/// Hears speech with Apple's on-device sound classifier. A classifier, not a loudness gate: on
/// quiet microphones speech sits only a few dB above the room noise (TabMail Voice ADR-DESK-005),
/// so no level threshold tells a quiet sentence from background noise.
///
/// `onSpeech` runs once, the first time a window is classified as speech; `onFailure` if the
/// classifier can't run. Both run on the analysis queue.
final class SoundClassifierSpeechDetector: NSObject, SpeechDetecting, SNResultsObserving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.tabmail.dictation.speech", qos: .userInitiated)
    private let onSpeech: @Sendable () -> Void
    private let onFailure: @Sendable (any Error) -> Void
    private let heard = Mutex(false)
    // Only the analysis queue touches these.
    private var analyzer: SNAudioStreamAnalyzer?
    private var framePosition: AVAudioFramePosition = 0
    private var failed = false

    init(onSpeech: @escaping @Sendable () -> Void, onFailure: @escaping @Sendable (any Error) -> Void) {
        self.onSpeech = onSpeech
        self.onFailure = onFailure
    }

    func analyze(_ buffer: AVAudioPCMBuffer) {
        guard !heard.withLock({ $0 }) else { return }
        queue.async { [self] in
            guard !failed else { return }
            do {
                let analyzer = try analyzer ?? makeAnalyzer(format: buffer.format)
                self.analyzer = analyzer
                analyzer.analyze(buffer, atAudioFramePosition: framePosition)
                framePosition += AVAudioFramePosition(buffer.frameLength)
            } catch {
                failed = true
                onFailure(error)
            }
        }
    }

    func finish() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                analyzer?.completeAnalysis()
                continuation.resume(returning: heard.withLock { $0 })
            }
        }
    }

    private func makeAnalyzer(format: AVAudioFormat) throws -> SNAudioStreamAnalyzer {
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: DictationConfig.speechDetectionWindow, preferredTimescale: DictationConfig.speechDetectionTimescale)
        try analyzer.add(request, withObserver: self)
        return analyzer
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let confidence = DictationConfig.speechClassifications
            .compactMap { result.classification(forIdentifier: $0)?.confidence }
            .max() ?? 0
        guard confidence >= DictationConfig.speechConfidence else { return }
        let isFirst = heard.withLock { heard in
            defer { heard = true }
            return !heard
        }
        guard isFirst else { return }
        BackgroundSyncLogger.logDebug("[Dictation] speech heard (confidence \(confidence))")
        onSpeech()
    }

    func request(_ request: SNRequest, didFailWithError error: any Error) {
        BackgroundSyncLogger.logDebug("[Dictation] speech detection failed: \(error)")
        onFailure(error)
    }
}
