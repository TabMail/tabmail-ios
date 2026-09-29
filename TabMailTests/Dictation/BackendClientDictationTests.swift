/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
import Testing
@testable import TabMail

/// `POST /dictation/transcribe`: the request TabMail Voice sends, from the iOS client.
struct BackendClientDictationTests {
    private let wav = WAVEncoder.encode(pcm16Mono: Data(repeating: 1, count: 320), sampleRate: 16_000)

    @Test func postsTheRecordingAsBase64WAVAndReturnsTheText() async throws {
        let http = FakeHTTP.Scenario()
        let seen = Mutex<FakeHTTP.Request?>(nil)
        http.register(path: "/dictation/transcribe", method: "POST") { request in
            seen.withLock { $0 = request }
            return .json(raw: #"{"text":"ask jordan about the road map"}"#)
        }

        let transcription = try await BackendClient(llmSession: http.session).transcribeDictation(wav: wav, language: nil, vocabulary: [])

        // No cleanup asked for, none returned.
        #expect(transcription == DictationTranscription(text: "ask jordan about the road map", cleanedText: nil))
        let request = try #require(seen.withLock { $0 })
        #expect(request.url.path == "/dictation/transcribe")
        #expect(request.header("X-Client-Type") == "ios")
        #expect(request.header("Content-Type") == "application/json")
        let body = try #require(request.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        // No language: the key is left out (the backend's default model).
        #expect(body == ["audio": wav.base64EncodedString(), "format": "wav"])
    }

    /// The language picks the backend's speech-to-text model (backend ADR-024).
    @Test func sendsTheLanguageWithTheRecording() async throws {
        let http = FakeHTTP.Scenario()
        let seen = Mutex<FakeHTTP.Request?>(nil)
        http.register(path: "/dictation/transcribe", method: "POST") { request in
            seen.withLock { $0 = request }
            return .json(raw: #"{"text":"annyeong"}"#)
        }

        _ = try await BackendClient(llmSession: http.session).transcribeDictation(wav: wav, language: "ko", vocabulary: [])

        let request = try #require(seen.withLock { $0 })
        let body = try #require(request.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["audio": wav.base64EncodedString(), "format": "wav", "language": "ko"])
    }

    /// The words to spell as given go with the recording (ADR-IOS-086, backend ADR-025), in order;
    /// with none, the key is left out (above).
    @Test func sendsTheVocabularyWithTheRecording() async throws {
        let http = FakeHTTP.Scenario()
        let seen = Mutex<FakeHTTP.Request?>(nil)
        http.register(path: "/dictation/transcribe", method: "POST") { request in
            seen.withLock { $0 = request }
            return .json(raw: #"{"text":"ask Xyvora"}"#)
        }

        _ = try await BackendClient(llmSession: http.session).transcribeDictation(wav: wav, language: nil, vocabulary: ["Xyvora", "Kaelthorne Drake"])

        let request = try #require(seen.withLock { $0 })
        let body = try #require(request.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(body.keys) == ["audio", "format", "vocabulary"])
        #expect(body["vocabulary"] as? [String] == ["Xyvora", "Kaelthorne Drake"])
    }

    /// The cleanup's variables go as `cleanup`, and the backend cleans up the transcript in the same
    /// request (backend ADR-027): its `cleaned_text` comes back beside the transcript.
    @Test func sendsTheCleanupAndReturnsTheCleanedUpText() async throws {
        let http = FakeHTTP.Scenario()
        let seen = Mutex<FakeHTTP.Request?>(nil)
        http.register(path: "/dictation/transcribe", method: "POST") { request in
            seen.withLock { $0 = request }
            return .json(raw: #"{"text":"ask jordan","cleaned_text":"Ask Jordan.","duration_seconds":1}"#)
        }
        let cleanup = DictationCleanup.variables(context: DictationContext(windowTitle: "Chat", screenText: "» ‸"), dictionary: ["Xyvora"])

        let transcription = try await BackendClient(llmSession: http.session).transcribeDictation(wav: wav, language: nil, vocabulary: [], cleanup: cleanup)

        #expect(transcription == DictationTranscription(text: "ask jordan", cleanedText: "Ask Jordan."))
        let request = try #require(seen.withLock { $0 })
        let body = try #require(request.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(Set(body.keys) == ["audio", "format", "cleanup"])
        #expect(body["cleanup"] as? [String: String] == cleanup)
    }

    /// A failed cleanup is `""`, not missing; an old backend, which ignores `cleanup`, answers none.
    @Test(arguments: [
        (#"{"text":"ask jordan","cleaned_text":""}"#, ""),
        (#"{"text":"ask jordan"}"#, nil),
    ] as [(String, String?)])
    func theCleanedTextIsAsTheBackendAnswers(raw: String, cleanedText: String?) async throws {
        let http = FakeHTTP.Scenario()
        http.register(path: "/dictation/transcribe", method: "POST", response: .json(raw: raw))
        let cleanup = DictationCleanup.variables(context: DictationContext(windowTitle: "Chat", screenText: "» ‸"), dictionary: [])

        let transcription = try await BackendClient(llmSession: http.session).transcribeDictation(wav: wav, language: nil, vocabulary: [], cleanup: cleanup)

        #expect(transcription == DictationTranscription(text: "ask jordan", cleanedText: cleanedText))
    }

    @Test(arguments: [
        (401, #"{"error":"invalid_token"}"#, DictationError.unauthorized),
        (402, #"{"error":"no_active_subscription"}"#, DictationError.subscriptionRequired),
        (403, #"{"error":"consent_required"}"#, DictationError.accountSetupRequired),
        (403, #"{"error":"forbidden"}"#, DictationError.accessDenied),
        (429, #"{"error":"rate_limited"}"#, DictationError.rateLimited),
        (400, #"{"error":"audio_too_large"}"#, DictationError.recordingTooLong),
        (502, "", DictationError.failed(status: 502)),
        (200, #"{"transcript":"wrong shape"}"#, DictationError.invalidResponse),
        (200, #"{"text":"ask jordan","cleaned_text":7}"#, DictationError.invalidResponse),
    ])
    func anErrorResponseSaysWhatWentWrong(status: Int, body: String, expected: DictationError) async {
        let http = FakeHTTP.Scenario()
        http.register(path: "/dictation/transcribe", method: "POST", response: .json(raw: body, statusCode: status))

        await #expect(throws: expected) {
            _ = try await BackendClient(llmSession: http.session).transcribeDictation(wav: wav, language: nil, vocabulary: [])
        }
    }
}

/// The transcription is authenticated with the signed-in TabMail session's access token; the
/// backend refuses it otherwise (`requireAuth`), so the endpoint here does the same.
@Suite(.serialized, .processGlobalState)
struct BackendClientDictationAuthTests {
    private let wav = WAVEncoder.encode(pcm16Mono: Data(repeating: 1, count: 320), sampleRate: 16_000)
    private static let accessToken = "dictation-test-access"

    @MainActor
    private func installSession() throws {
        // Far enough ahead that `validToken()` answers without a refresh; relative to now.
        let expiresAt = Int(Date().addingTimeInterval(365 * 24 * 60 * 60).timeIntervalSince1970)
        let data = try JSONSerialization.data(withJSONObject: [
            "access_token": Self.accessToken,
            "refresh_token": "dictation-test-refresh",
            "expires_at": expiresAt,
            "user": ["id": "dictation-test-user", "email": "session@example.com"],
        ])
        _ = try TabMailSessionStore.shared.installNewSession(data)
    }

    @MainActor
    private func restoreSession(_ data: Data?) throws {
        _ = TabMailAuthService.completeSession(mode: .deactivate, notify: false)
        if let data {
            _ = try TabMailSessionStore.shared.installNewSession(data)
        }
    }

    @Test func theSignedInSessionAuthenticatesTheRecording() async throws {
        #expect(await MainActor.run { !DemoModeStore.shared.isActive })
        let previous = await MainActor.run { TabMailSessionStore.shared.loadActiveSession()?.data }
        let http = FakeHTTP.Scenario()
        let bearers = Mutex<[String?]>([])
        http.register(path: "/dictation/transcribe", method: "POST") { request in
            let bearer = request.header("Authorization")
            bearers.withLock { $0.append(bearer) }
            return bearer == "Bearer \(Self.accessToken)"
                ? .json(raw: #"{"text":"ask jordan"}"#)
                : .json(raw: #"{"error":"invalid_token"}"#, statusCode: 401)
        }
        let client = BackendClient(llmSession: http.session)

        let outcome: Result<Void, any Error>
        do {
            try await MainActor.run { try installSession() }
            #expect(try await client.transcribeDictation(wav: wav, language: nil, vocabulary: []) .text == "ask jordan")

            // Signed out, no token is sent and the refusal reads as an ended session.
            _ = await MainActor.run { TabMailAuthService.completeSession(mode: .deactivate, notify: false) }
            await #expect(throws: DictationError.unauthorized) {
                _ = try await client.transcribeDictation(wav: wav, language: nil, vocabulary: [])
            }
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        try await MainActor.run { try restoreSession(previous) }
        try outcome.get()

        #expect(bearers.withLock { $0 } == ["Bearer \(Self.accessToken)", nil])
    }
}
