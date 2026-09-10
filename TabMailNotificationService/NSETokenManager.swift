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
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            NSELog.step("NSE credential: scope=session stage=end elapsed_ms=\(elapsed)")
        }
        guard let record = sessionStore.loadActiveSession() else {
            NSELog.step("NSE credential: scope=session stage=lookup outcome=missing_or_unreadable")
            return nil
        }
        guard expectedGeneration == nil || expectedGeneration == record.generation else {
            NSELog.step("NSE credential: scope=session stage=lookup outcome=activation_changed")
            return nil
        }
        NSELog.step("NSE credential: scope=session stage=lookup outcome=loaded")
        do {
            let requestTransport = dataForRequest ?? transport
            let result = try await CredentialRefreshGate.$diagnostic.withValue({ event in
                NSELog.step("NSE credential: scope=session \(event)")
            }) {
                try await TabMailSessionRefresh.token(record: record, store: sessionStore) { request in
                    NSELog.step("NSE credential: scope=session stage=network outcome=started")
                    let response = try await requestTransport(request)
                    NSELog.step("NSE credential: scope=session stage=network http=\((response.1 as? HTTPURLResponse)?.statusCode ?? 0)")
                    return response
                }
            }
            guard !Task.isCancelled else {
                NSELog.step("NSE credential: scope=session stage=finish outcome=cancelled")
                return nil
            }
            guard result.persisted else {
                NSELog.step("NSE credential: scope=session stage=finish outcome=not_persisted")
                return nil
            }
            guard sessionStore.loadActiveSession()?.location == record.location else {
                NSELog.step("NSE credential: scope=session stage=finish outcome=activation_changed")
                return nil
            }
            NSELog.step("NSE credential: scope=session stage=finish outcome=usable_shared_credential")
            return result
        } catch {
            NSELog.step("NSE credential: scope=session stage=finish outcome=\(NSELog.credentialFailure(error))")
            return nil
        }
    }

    static func validAccessToken(sessionStore: TabMailSessionStore? = nil,
                                 dataForRequest: DataForRequest? = nil) async -> String? {
        await validSession(sessionStore: sessionStore, dataForRequest: dataForRequest)?.session.accessToken
    }
}
