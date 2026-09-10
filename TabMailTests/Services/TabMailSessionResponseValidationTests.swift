/* This Source Code Form is subject to the terms of the Mozilla Public
    * License, v. 2.0. If a copy of the MPL was not distributed with this
    * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
import Synchronization
@testable import TabMail

@Suite("Session refresh response invariants")
struct TabMailSessionResponseValidationTests {
    @MainActor
    @Test("Unusable responses yield no bearer and preserve the durable authorization", arguments: ["malformed", "wrong-user", "empty-access", "empty-refresh", "expired", "status-500"])
    func responseValidation(scenario: String) async throws {
        let h = CredentialTestHarness(); let store = h.sessions
        let old = try CredentialTestHarness.sessionData()
        _ = try store.installNewSession(old)
        let requests = Mutex(0)
        let result = await NSETokenManager.validSession(sessionStore: store) { request in
            requests.withLock { $0 += 1 }
            let data: Data
            if scenario == "malformed" { data = Data("{malformed".utf8) }
            else {
                data = try CredentialTestHarness.sessionData(user: scenario == "wrong-user" ? "user-b" : "user-a",
                        access: scenario == "empty-access" ? "" : "synthetic-response-access",
                        refresh: scenario == "empty-refresh" ? "" : "synthetic-response-refresh",
                        expired: scenario == "expired")
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: scenario == "status-500" ? 500 : 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(requests.withLock { $0 } == 1)
        #expect(result == nil)
        let durable = try #require(store.loadActiveSession())
        #expect(durable.data == old)
    }
    @MainActor
    @Test("Auth refusal and server outage retain distinct recovery outcomes", arguments: [400, 401, 403, 429, 500])
    func refusalClassification(status: Int) async throws {
        let h = CredentialTestHarness(); let store = h.sessions
        let old = try CredentialTestHarness.sessionData(); _ = try store.installNewSession(old)
        let requests = Mutex(0)
        let coordinator = TabMailTokenCoordinator(sessionStore: store) { request in
            requests.withLock { $0 += 1 }
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let result = await coordinator.validToken()
        switch result {
        case .permanentFailure: #expect([400,401,403].contains(status))
        case .transientFailure: #expect([429,500].contains(status))
        default: Issue.record("Unusable response authorized work")
        }
        #expect(requests.withLock { $0 } == 1)
        #expect(store.loadActiveSession()?.data == old)
    }
}
