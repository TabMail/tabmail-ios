/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@testable import TabMail

/// Writes chat turns as the app does: a demo turn (`demo:` session) only
/// inside a running demo, with its run's admission (#231). A turn outside a
/// demo is written with no admission, as real history is.
enum DemoRunFixture {

    static func indexTurn(chatHistoryId: String, sessionId: String?, role: String, dateMs: Int64, text: String) async {
        await withAdmission(for: sessionId) { admission in
            await MemoryIndex.shared.indexTurn(
                chatHistoryId: chatHistoryId, sessionId: sessionId, role: role,
                dateMs: dateMs, text: text, admission: admission)
        }
    }

    @discardableResult
    static func appendTurn(_ turn: ChatTurn) async throws -> [ChatTurn] {
        try await withAdmission(for: turn.sessionId) { admission in
            try await ChatStore.shared.appendTurn(turn, admission: admission)
        }
    }

    /// Runs `body` with the running demo's admission for a demo turn, starting
    /// a demo run for it if none is running (and ending that run after).
    private static func withAdmission<T>(
        for sessionId: String?,
        _ body: (DemoModeStore.Admission?) async throws -> T
    ) async rethrows -> T {
        guard sessionId?.hasPrefix("demo:") == true else { return try await body(nil) }
        let (startedRun, admission) = await MainActor.run { () -> (Bool, DemoModeStore.Admission?) in
            let store = DemoModeStore.shared
            let started = !store.isActive
            store.isActive = true
            return (started, store.chatAdmission)
        }
        do {
            let result = try await body(admission)
            if startedRun { await MainActor.run { DemoModeStore.shared.isActive = false } }
            return result
        } catch {
            if startedRun { await MainActor.run { DemoModeStore.shared.isActive = false } }
            throw error
        }
    }
}
