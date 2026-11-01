/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

/// Nothing `BulletSync.outgoing` returns is over the relay's budget (DS-WIRE, DS-CHUNK, DS-OVERSIZE): not a part
/// of a split field, and not the reply of a field with no live bullet whose seen list alone is too big.
@MainActor
@Suite("A message is never over the relay's budget")
struct BulletSyncEnvelopeTests {
    private func sync(_ device: DeviceDefaults) -> BulletSync {
        BulletSync(store: UserDefaultsBulletStore(defaults: device.defaults),
                   options: .init(fields: [.kb], skeleton: { _ in .none }, newName: { "ffff0000ffff0000" },
                                  newID: { UUID().uuidString }, budget: { BulletSyncConfig.messageMaxBytes },
                                  error: { _ in }, catalog: .init(defaults: [])))
    }

    @Test("A field with no live bullet and a seen list over the budget sends nothing; an ordinary empty field still sends")
    func emptyFieldWithOversizeSeenListSendsNothing() throws {
        let names = (1...5500).map { String(format: "%016x", $0) }
        let incoming = names.enumerated().map { Bullet(section: "", text: "item \($0.offset)", name: $0.element, n: 1) }
        let source = DeviceDefaults()
        defer { source.dispose() }
        source.storeStates([.kb: (incoming, Dictionary(uniqueKeysWithValues: names.map { ($0, 1) }))])
        // The receiver deleted all of them, at newer counters.
        let target = DeviceDefaults()
        defer { target.dispose() }
        target.storeStates([.kb: ([], Dictionary(uniqueKeysWithValues: names.map { ($0, 10000) }))])
        let older = sync(source)
        let newer = sync(target)
        guard case .messages(let parts) = older.outgoing(.kb) else { Issue.record("the older device did not send"); return }
        #expect(!parts.isEmpty)
        #expect(parts.allSatisfy { $0.utf8.count <= BulletSyncConfig.messageMaxBytes }, "control: the older device's parts fit")
        for text in parts {
            let message = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            _ = newer.receive(message)
        }
        #expect(newer.state(.kb).bullets.isEmpty, "no deleted label came back")
        switch newer.outgoing(.kb) {
        case .oversize(let bytes, let budget):
            #expect(bytes > budget)
        case .messages(let replies):
            #expect(replies.allSatisfy { $0.utf8.count <= BulletSyncConfig.messageMaxBytes }, "a reply over the relay's budget would be dropped")
        }
        // Control: an ordinary empty field sends one message that fits.
        let empty = DeviceDefaults()
        defer { empty.dispose() }
        empty.storeStates([:])
        guard case .messages(let control) = sync(empty).outgoing(.kb) else { Issue.record("an empty field did not send"); return }
        #expect(control.count == 1)
        #expect(control.allSatisfy { $0.utf8.count <= BulletSyncConfig.messageMaxBytes })
    }
}
