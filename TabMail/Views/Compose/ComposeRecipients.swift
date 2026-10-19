/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

extension ComposeDraftGuards {
    /// Which recipient field of the compose.
    enum RecipientRole: CaseIterable {
        case to, cc, bcc
    }

    /// The compose's To, Cc and Bcc fields as one value (ADR-IOS-092). Every
    /// change the compose makes to a field by role (typing, a contact pick, a
    /// prefill or reopened draft, an AI edit, Send, a save) goes through here,
    /// so the mapping that keeps Bcc recipients in Bcc is tested in one place.
    struct Recipients: Equatable {
        var to = RecipientField()
        var cc = RecipientField()
        var bcc = RecipientField()

        subscript(role: RecipientRole) -> RecipientField {
            get {
                switch role {
                case .to: to
                case .cc: cc
                case .bcc: bcc
                }
            }
            set {
                switch role {
                case .to: to = newValue
                case .cc: cc = newValue
                case .bcc: bcc = newValue
                }
            }
        }

        /// Recipients across the three fields. Text in an input line is not
        /// counted: it is not a recipient yet.
        var total: Int { to.tokens.count + cc.tokens.count + bcc.tokens.count }

        var canAddMore: Bool { total < SyncConfig.outboxMaxRecipients }

        /// What a draft stores for each field: its addresses, then any text left
        /// in its input line (`committedRecipients`).
        var stored: (to: [String], cc: [String], bcc: [String]) {
            (committedRecipients(tokens: to.tokens, input: to.input),
             committedRecipients(tokens: cc.tokens, input: cc.input),
             committedRecipients(tokens: bcc.tokens, input: bcc.input))
        }

        /// The fields after `text` was committed to one of them, within the
        /// recipient cap; unchanged when `text` names no address.
        func committing(_ text: String, typing: String, to role: RecipientRole) -> Recipients {
            var result = self
            let room = SyncConfig.outboxMaxRecipients - total
            if let field = ComposeDraftGuards.committing(text, typing: typing, to: self[role], room: room) {
                result[role] = field
            }
            return result
        }

        /// The fields after a contact was picked in one of them.
        func picking(_ address: String, name: String?, to role: RecipientRole) -> Recipients {
            var result = self
            let room = SyncConfig.outboxMaxRecipients - total
            result[role] = ComposeDraftGuards.picking(address, name: name, to: self[role], room: room)
            return result
        }

        /// The fields filled from outside their input lines (a reopened draft, a
        /// prefill, a reply). A field given no entry is left as it is. Display
        /// names already known are kept, and a name the fill gives wins.
        func filling(to: RecipientEntry? = nil, cc: RecipientEntry? = nil, bcc: RecipientEntry? = nil) -> Recipients {
            var result = self
            for (role, entry) in [(RecipientRole.to, to), (.cc, cc), (.bcc, bcc)] {
                guard let entry else { continue }
                var field = fieldState(entry)
                field.displayNames = self[role].displayNames.merging(field.displayNames) { _, new in new }
                result[role] = field
            }
            return result
        }

        /// The fields after an AI edit: each field's delta applied to that field.
        func applying(to: RecipientDelta?, cc: RecipientDelta?, bcc: RecipientDelta?) -> Recipients {
            var result = self
            for (role, delta) in [(RecipientRole.to, to), (.cc, cc), (.bcc, bcc)] {
                guard let delta, !delta.isEmpty else { continue }
                result[role] = ComposeDraftGuards.applying(delta, to: self[role])
            }
            return result
        }

        /// The fields with the addresses in their input lines committed, as
        /// close, save and Send do.
        var pendingCommitted: Recipients {
            Recipients(to: ComposeDraftGuards.pendingCommitted(to),
                       cc: ComposeDraftGuards.pendingCommitted(cc),
                       bcc: ComposeDraftGuards.pendingCommitted(bcc))
        }

        /// What Send sends, given fields already committed (`pendingCommitted`).
        var sendRecipients: SendRecipients {
            ComposeDraftGuards.sendRecipients(to: to, cc: cc, bcc: bcc)
        }

        /// Gives `name` to `address` in every field that lists it.
        mutating func name(_ address: String, _ name: String) {
            for role in RecipientRole.allCases where self[role].tokens.contains(address) {
                self[role].displayNames[address] = name
            }
        }

        /// Whether any field already knows a name for `address`.
        func hasName(for address: String) -> Bool {
            RecipientRole.allCases.contains { self[$0].displayNames[address] != nil }
        }
    }
}

extension ComposeDraftGuards.RecipientField {
    /// No address and no text in the input line.
    var isEmpty: Bool { tokens.isEmpty && input.isEmpty }
}
