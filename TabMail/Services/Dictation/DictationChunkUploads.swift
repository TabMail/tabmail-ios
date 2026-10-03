/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// A long dictation's chunks (ADR-IOS-087; TabMail Voice's ADR-DESK-048): each is sent as it is cut,
/// with its own cleanup, while the user goes on, and tried again while the user is still dictating;
/// at the release, the chunks still failing get their last tries, and the dictation's text is the
/// chunks' in order up to the first that gave up (owner, 2026-10-03: "paste only the up to
/// successful part").
@MainActor
final class DictationChunkUploads {
    /// What every upload of the dictation sends beside its audio.
    struct Upload: Sendable {
        let language: String?
        /// The dictionary's words and the context's terms, to spell as given.
        let vocabulary: [String]
        /// The cleanup's variables.
        let cleanup: [String: String]
    }

    /// A transcribed chunk, and whether its audio started inside the one before it.
    struct Part: Sendable {
        let transcription: DictationTranscription
        let overlapped: Bool
    }

    private struct Job {
        let index: Int
        let overlapped: Bool
        let outcome: Task<Result<DictationTranscription, any Error>, Never>
    }

    private let transcribe: DictationController.Transcribe
    private let upload: Task<Upload, Never>
    private let chunkRetryDelays: [Duration]
    private let lastRetryDelays: [Duration]
    /// A chunk failed after the release and is being tried again: the pill's retry state.
    private let onLastRetry: @MainActor () -> Void
    private var jobs: [Job] = []
    /// The waits of chunks retried while the user dictates: the release cuts them short.
    private var waits: [Int: Task<Void, Never>] = [:]
    private var isReleased = false

    /// `upload` is prepared once, for every chunk; `chunkRetryDelays` are the waits before each retry
    /// while the user dictates, the last repeating; `lastRetryDelays` those after the release.
    init(
        transcribe: @escaping DictationController.Transcribe,
        upload: Task<Upload, Never>,
        chunkRetryDelays: [Duration],
        lastRetryDelays: [Duration],
        onLastRetry: @escaping @MainActor () -> Void
    ) {
        self.transcribe = transcribe
        self.upload = upload
        self.chunkRetryDelays = chunkRetryDelays
        self.lastRetryDelays = lastRetryDelays
        self.onLastRetry = onLastRetry
    }

    /// Sends a chunk, its FLAC from `encode` (run off the main actor). Every chunk is sent, a
    /// silent-sounding one too: the model decides, as for one recording (owner, 2026-10-03: no
    /// loudness gate, so soft speech is never dropped).
    func add(_ cut: DictationChunkCut, encode: @escaping @Sendable () -> Data) {
        BackgroundSyncLogger.logDebug("[Dictation] chunk \(cut.index) cut: samples \(cut.start)..<\(cut.end)\(cut.overlapped ? ", overlapping the one before" : "")")
        let outcome = Task { await self.send(cut.index, encode: encode) }
        jobs.append(Job(index: cut.index, overlapped: cut.overlapped, outcome: outcome))
    }

    /// The user released: chunks still failing get their last tries at once. Returns the chunks'
    /// transcriptions in order up to the first that gave up, and why it did (nil: none did). The
    /// chunks after it are no longer needed and are cancelled.
    func release() async -> (parts: [Part], lost: (any Error)?) {
        isReleased = true
        for wait in waits.values { wait.cancel() }
        var parts: [Part] = []
        for job in jobs {
            switch await job.outcome.value {
            case .success(let transcription):
                parts.append(Part(transcription: transcription, overlapped: job.overlapped))
            case .failure(let error):
                cancel()
                return (parts, error)
            }
        }
        return (parts, nil)
    }

    /// The dictation ended: every request and wait stops.
    func cancel() {
        for job in jobs { job.outcome.cancel() }
        for wait in waits.values { wait.cancel() }
        upload.cancel()
    }

    /// Makes a chunk's request until it answers (owner, 2026-10-03: "retries should keep on happening
    /// until the final give up"). While the user is still dictating, a server error, a dropped
    /// connection, the backend's own timeout or the speech model's rate limit (`backendWaited`) is
    /// tried again after each of `chunkRetryDelays`, the last repeating, for as long as the
    /// dictation goes on: nobody waits for it yet. From the release, it gets `lastRetryDelays` more
    /// tries on the same failures, with the pill's retry state: the last chunk is sent at the
    /// release, so its backend timeout comes after it (owner, 2026-10-03: "we should not lose the
    /// end"). Any other failure (signed out, over quota or the
    /// account's own rate limit, a refused request) gives up at once.
    private func send(_ index: Int, encode: @escaping @Sendable () -> Data) async -> Result<DictationTranscription, any Error> {
        let flac = await Task.detached(priority: .userInitiated) { encode() }.value
        let upload = await upload.value
        // Cancelled while the chunk was encoded or its upload prepared: nothing is sent.
        guard !Task.isCancelled else { return .failure(CancellationError()) }
        BackgroundSyncLogger.logDebug("[Dictation] uploading chunk \(index) (\(flac.count) bytes of FLAC)")
        var waited = 0
        var lastTries = 0
        while true {
            do {
                return .success(try await transcribe(flac, upload.language, upload.vocabulary, upload.cleanup))
            } catch {
                guard !Task.isCancelled else { return .failure(error) }
                let isRetryable = DictationController.isServerError(error) || DictationController.backendWaited(error)
                if !isReleased {
                    guard isRetryable,
                          let delay = waited < chunkRetryDelays.count ? chunkRetryDelays[waited] : chunkRetryDelays.last else {
                        BackgroundSyncLogger.logDebug("[Dictation] chunk \(index) failed for good: \(error)")
                        return .failure(error)
                    }
                    waited += 1
                    BackgroundSyncLogger.logDebug("[Dictation] chunk \(index) failed while recording (\(error)); retrying in \(delay)")
                    let wait = Task<Void, Never> { try? await Task.sleep(for: delay) }
                    waits[index] = wait
                    await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
                    waits[index] = nil
                    // The release cuts the wait short and the chunk is tried at once; a cancel ends it.
                    guard !Task.isCancelled else { return .failure(CancellationError()) }
                    continue
                }
                guard lastTries < lastRetryDelays.count, isRetryable else {
                    BackgroundSyncLogger.logDebug("[Dictation] chunk \(index) failed for good: \(error)")
                    return .failure(error)
                }
                let delay = lastRetryDelays[lastTries]
                lastTries += 1
                BackgroundSyncLogger.logDebug("[Dictation] chunk \(index) failed after the release (\(error)); retrying in \(delay)")
                onLastRetry()
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return .failure(error)
                }
            }
        }
    }
}
