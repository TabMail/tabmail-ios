/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
@testable import TabMail

/// Holds the prompt store's semaphore from a task of its own until `end()`, as a slow caller would.
@MainActor
final class PromptStoreHolder {
    private let task: Task<Void, Error>
    private let release: AsyncStream<Void>.Continuation

    init(_ store: PromptStore) async {
        let (released, release) = AsyncStream<Void>.makeStream()
        let (taken, took) = AsyncStream<Void>.makeStream()
        self.release = release
        task = Task { @MainActor in
            defer { took.finish() }
            try await store.withPromptStore("test holder") { _ in
                took.yield()
                for await _ in released { break }
            }
        }
        for await _ in taken { break }
    }

    func end() async throws {
        release.yield()
        try await task.value
    }
}

/// What the tests leave in the prompt store of the test host, removed again: every bullet whose text
/// carries the test's tag, deleted by the labels the store shows for it (DS-DISPLAYED).
@MainActor
enum PromptStoreTestCleanup {
    static func remove(tag: String, from store: PromptStore) async {
        for section in PromptSection.allCases {
            for shown in store.shown(section) where shown.text.contains(tag) {
                _ = await store.edit("test cleanup") { try $0.deleteShown(shown, from: section) }
            }
        }
    }

    /// A tag no other test's text carries.
    static func tag() -> String {
        "fx-" + UUID().uuidString.lowercased().prefix(8)
    }
}

/// A `bullet_state` message from a peer the store has never seen, carrying one KB bullet.
enum ForeignBulletMessage {
    nonisolated(unsafe) private static var sequence = 0

    @MainActor
    static func kb(_ text: String) -> String {
        sequence += 1
        let name = String(format: "f0f0%04x%08x", Int.random(in: 0...0xFFFF), sequence)
        let sender = String(format: "e1e1%04x%08x", Int.random(in: 0...0xFFFF), sequence)
        let snap = String(format: "%016x", sequence)
        return #"{"type":"bullet_state","v":1,"field":"kb","sender":"\#(sender)","snap":"\#(snap)","part":1,"parts":1,"bullets":[["","\#(text)","\#(name)",1]],"seen":{"\#(name)":1}}"#
    }
}
