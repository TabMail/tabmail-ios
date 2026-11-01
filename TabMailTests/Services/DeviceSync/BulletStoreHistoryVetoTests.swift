/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// DS-HISTORY: a history save that fails fails the reset, restore or merge it comes before; nothing is
/// replaced without its record.
@MainActor
@Suite("Bullet store history veto")
struct BulletStoreHistoryVetoTests {
    private let defaults = DeviceDefaults()

    @Test("A commit whose history entry is not saved writes nothing and reports itself unsaved; the same commit saved with its entry writes")
    func vetoedCommitWritesNothing() {
        let store = UserDefaultsBulletStore(defaults: defaults.defaults)
        let skeleton = PromptStore.skeleton(.kb)
        let next = FieldState(head: skeleton.head, tail: skeleton.tail,
                              bullets: [Bullet(section: "", text: "a new rule", name: "f0f0000000000001", n: 1)],
                              seen: ["f0f0000000000001": 1])

        var asked: [BulletField] = []
        store.willCommit = { _, fields in
            asked = fields
            return false
        }
        #expect(store.write([.kb: next], kind: .reset) == false)
        #expect(asked == [.kb], "the history was asked to record the field the commit changes")
        #expect(store.read(.kb) == nil, "nothing was stored")
        #expect(store.legacyText(.kb) == nil, "the shown text is untouched")

        store.willCommit = { _, _ in true }
        #expect(store.write([.kb: next], kind: .reset))
        #expect(store.read(.kb) != nil)
        #expect(store.legacyText(.kb)?.contains("a new rule") == true)
    }
}
