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

        let text = try await BackendClient(llmSession: http.session).transcribeDictation(wav: wav)

        #expect(text == "ask jordan about the road map")
        let request = try #require(seen.withLock { $0 })
        #expect(request.url.path == "/dictation/transcribe")
        #expect(request.header("X-Client-Type") == "ios")
        #expect(request.header("Content-Type") == "application/json")
        let body = try #require(request.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["audio": wav.base64EncodedString(), "format": "wav"])
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
    ])
    func anErrorResponseSaysWhatWentWrong(status: Int, body: String, expected: DictationError) async {
        let http = FakeHTTP.Scenario()
        http.register(path: "/dictation/transcribe", method: "POST", response: .json(raw: body, statusCode: status))

        await #expect(throws: expected) {
            _ = try await BackendClient(llmSession: http.session).transcribeDictation(wav: wav)
        }
    }
}
