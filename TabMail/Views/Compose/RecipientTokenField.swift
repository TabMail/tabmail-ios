/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI

/// One recipient field of the compose. Every binding and action takes `role`,
/// so typing, a contact pick and what the field shows all reach that role's
/// recipients and no other. A commit, a contact pick and a rejected entry's
/// edit go through `Recipients.replace(with:showCc:)`; removing a chip and
/// each keystroke write the field directly (ADR-IOS-092).
struct RecipientTokenField: View {
    let role: ComposeDraftGuards.RecipientRole
    @Binding var recipients: ComposeDraftGuards.Recipients
    @Binding var showCc: Bool
    let searchResults: [ContactResult]
    let onFocus: () -> Void
    @Binding var revealedChipKey: String?

    var body: some View {
        TokenField(
            tokens: Binding(get: { recipients[role].tokens }, set: { recipients[role].tokens = $0 }),
            rejected: Binding(get: { recipients[role].rejected }, set: { recipients[role].rejected = $0 }),
            input: Binding(get: { recipients[role].input }, set: { recipients[role].input = $0 }),
            displayNames: recipients[role].displayNames,
            searchResults: searchResults,
            onFocus: onFocus,
            onSelectContact: { contact in
                set(recipients.picking(contact.email, name: contact.name, to: role))
            },
            commit: { text, typing in set(recipients.committing(text, typing: typing, to: role)) },
            onEditRejected: { index in set(recipients.editingRejected(at: index, in: role)) },
            canAddMore: { recipients.canAddMore },
            revealedChipKey: $revealedChipKey,
            fieldKey: "\(role)")
    }

    private func set(_ new: ComposeDraftGuards.Recipients) {
        recipients.replace(with: new, showCc: &showCc)
    }
}
