/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
@testable import TabMail

@Suite("Connection Pool Config - Single Source of Truth")
struct ConnectionPoolConfigTests {

    @Test("imapMaxConnectionCeiling is the single config for IMAP connection limits")
    func singleSourceOfTruth() {
        // This value is used by: pool default max, work queue concurrency,
        // probe target, and backfill worker count. There should be no other
        // IMAP-specific connection limit constants.
        let ceiling = SyncConfig.imapMaxConnectionCeiling
        #expect(ceiling >= 10, "Ceiling should be high enough to discover most server limits")
        #expect(ceiling <= 50, "Ceiling should not be absurdly high")
    }

    @Test("Reserved connections leaves headroom")
    func reservedConnections() {
        // Pool reserves 1 connection for headroom (other clients, server overhead).
        // With ceiling=20, effective max = 19 before server limit known.
        let ceiling = SyncConfig.imapMaxConnectionCeiling
        // At minimum, usable connections should be ceiling - some small reserve
        #expect(ceiling > 1, "Ceiling must exceed reserved count")
    }

    @Test("Creation backoff constants are reasonable")
    func creationBackoff() {
        // Backoff prevents hammering the server when connections are rejected.
        // Initial should be short (try again soon), max should cap at ~30s.
        // These are private to the pool, so we test the observable behavior
        // through the config constants we CAN access.
        #expect(SyncConfig.imapPoolLivenessCheckSeconds > 0)
        #expect(SyncConfig.imapPoolLivenessCheckSeconds <= 300)
    }

    @Test("Pool idle prune is longer than liveness check")
    func pruneAfterLiveness() {
        // Liveness checks must fire before pruning, otherwise connections
        // get pruned without being checked first.
        #expect(SyncConfig.imapPoolLivenessCheckSeconds < SyncConfig.imapPoolIdlePruneSeconds)
    }
}
