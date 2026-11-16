/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// A user label as its provider names it (#500). Each provider owns its own
/// label rules through the `EmailProvider` user-label requirements: how a typed
/// name becomes a label (Gmail creates it on its server, IMAP lowercases the
/// keyword, Outlook keeps the category name as typed), which folders are labels,
/// and which pushed labels are the user's. The menu, the sync and the
/// notification merge call those requirements and never apply a rule
/// themselves (ADR-IOS-060: no provider knowledge above the boundary).
struct ProviderUserLabel: Sendable, Equatable {
    /// The provider's own value, the one that goes on the wire
    /// (`UserLabel.providerLabelId`, `PendingOperation.userLabelId`).
    let providerLabelId: String
    /// The name the label is shown under.
    let name: String
    /// A label the provider keeps for itself, stored but never shown.
    let isSystem: Bool
}
