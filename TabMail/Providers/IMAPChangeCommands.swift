/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail

// MARK: - CONDSTORE requests from the SwiftMail fork (#755)
//
// `SELECT <mailbox> (CONDSTORE)` (RFC 7162 §3.1.8) through
// `IMAPServer.selectMailbox(_:enablingCondStore:)`: the window listing's SELECT
// on a session with CONDSTORE on (`IMAPProvider.negotiateListingCondStore`), so
// the SELECT reports HIGHESTMODSEQ. Reached only through `IMAPChangeCommands`,
// so nothing else in the provider depends on the fork's names. Below the
// provider boundary (ADR-IOS-060): the engine never sees this type.

/// The fork's CONDSTORE request, in the provider's terms.
struct IMAPChangeCommands: Sendable {
    /// `SELECT <name> (CONDSTORE)`. `highestModificationSequenceValue` is nil for
    /// NOMODSEQ.
    func selectCondStore(_ name: String, on server: IMAPServer) async throws -> Mailbox.Selection {
        try await server.selectMailbox(name, enablingCondStore: true)
    }
}

extension Mailbox.Selection {
    /// The SELECT's EXISTS count when the server sent one a mailbox can hold;
    /// nil = the count is unknown (SwiftMail reads an omitted EXISTS as 0).
    var reportedMessageCount: Int? {
        guard messageCountReported, (0...Int(UInt32.max)).contains(messageCount) else { return nil }
        return messageCount
    }
}
