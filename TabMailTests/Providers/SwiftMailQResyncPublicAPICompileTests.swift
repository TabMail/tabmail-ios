/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import SwiftMail

/// Compile-time guard: the QRESYNC checkpoint round trip must be writable with
/// only `import SwiftMail` and values held in plain integer variables (the app
/// never imports NIOIMAPCore). A toolchain or SwiftMail change that breaks this
/// fails the test build, not a release. Never executed against a server.
private func qresyncCheckpointRoundTrip(server: IMAPServer, named: IMAPNamedConnection) async throws {
    let supportsQResync: Bool = await server.supportsQResync
    let supportsCondStore: Bool = await server.supportsCondStore
    let namedSupportsQResync: Bool = await named.supportsQResync
    let namedSupportsCondStore: Bool = await named.supportsCondStore
    guard supportsQResync, supportsCondStore, namedSupportsQResync, namedSupportsCondStore else { return }
    _ = try await server.enable([.qresync])

    let ordinary = try await server.selectMailbox("INBOX")
    let storedUIDValidity: UInt32 = ordinary.uidValidity.value
    let storedUIDNext: UInt32 = ordinary.uidNext.value
    guard let storedModificationSequence: UInt64 = ordinary.highestModificationSequenceValue else { return }
    _ = storedUIDNext

    let resync: Mailbox.ResyncSelection = try await server.selectMailbox(
        "INBOX",
        resyncingFromUIDValidity: storedUIDValidity,
        modificationSequence: storedModificationSequence
    )
    let nextModificationSequence: UInt64? = resync.selection.highestModificationSequenceValue
    _ = nextModificationSequence
    _ = resync.vanishedEarlier
    _ = resync.changedFlags

    _ = try await named.select(
        mailbox: "INBOX",
        resyncingFromUIDValidity: storedUIDValidity,
        modificationSequence: storedModificationSequence
    )
}

@Suite("SwiftMail QRESYNC public API compiles with SwiftMail alone")
struct SwiftMailQResyncPublicAPICompileTests {
    @Test("the integer QRESYNC round trip is reachable without NIOIMAPCore")
    func roundTripCompiles() {
        let reference: (IMAPServer, IMAPNamedConnection) async throws -> Void = qresyncCheckpointRoundTrip
        _ = reference
    }
}
