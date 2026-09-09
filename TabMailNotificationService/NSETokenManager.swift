/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
#if TABMAIL_TESTS
@testable import TabMail
#endif

/// Background recovery requires a durably shared token under the same activation.
enum NSETokenManager {
    typealias DataForRequest = TabMailSessionRefresh.Transport
    @TaskLocal static var transport: DataForRequest = { try await URLSession.shared.data(for: $0) }

    @TaskLocal static var storeOverride: TabMailSessionStore?
    static var store: TabMailSessionStore { storeOverride ?? .shared }

    @TaskLocal static var expectedGeneration: String?

    static func supabaseUserId(sessionStore: TabMailSessionStore? = nil) -> String? {
        let sessionStore = sessionStore ?? store
        guard let record = sessionStore.loadActiveSession(),
              let session = try? JSONDecoder().decode(TabMailSession.self, from: record.data) else { return nil }
        return session.userId
    }

    static func userId(inSessionJSON json: [String: Any]) -> String? {
        (json["user"] as? [String: Any])?["id"] as? String ?? json["sub"] as? String
    }

    static func validSession(sessionStore: TabMailSessionStore? = nil,
                             dataForRequest: DataForRequest? = nil) async -> TabMailSessionRefresh.Result? {
        let sessionStore = sessionStore ?? store
        guard let record = sessionStore.loadActiveSession(),
              expectedGeneration == nil || expectedGeneration == record.generation,
              let result = try? await TabMailSessionRefresh.token(record: record, store: sessionStore,
                  transport: dataForRequest ?? transport),
              !Task.isCancelled, result.persisted,
              sessionStore.loadActiveSession()?.location == record.location else { return nil }
        return result
    }

    static func validAccessToken(sessionStore: TabMailSessionStore? = nil,
                                 dataForRequest: DataForRequest? = nil) async -> String? {
        await validSession(sessionStore: sessionStore, dataForRequest: dataForRequest)?.session.accessToken
    }
}
