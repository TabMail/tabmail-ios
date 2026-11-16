/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Gmail's user-label rules (#500; `ProviderUserLabel`). Gmail labels live on its
/// server: a label is created there and gets an opaque id (`Label_N`), the
/// folder list carries the label catalog, and a pushed message's label ids are
/// the user's only when the catalog knows them as user labels.
extension GmailProvider {

    /// Creates `name` on Gmail. Gmail compares label names without case and
    /// refuses a second create with 409; the label it already has is then
    /// applied, under Gmail's spelling of the name. Any other failure, and a 409
    /// whose lookup finds no label (deleted elsewhere in between), fails the
    /// gesture. With no connected Gmail provider the gesture fails.
    static func userLabel(named name: String, connected: (any EmailProvider)?) async throws -> ProviderUserLabel {
        guard let gmail = connected as? GmailProvider else { throw ProviderError.notConnected }
        let label = try await withThrowingTaskGroup(of: (id: String, name: String).self) { group in
            group.addTask {
                do {
                    return (try await gmail.createLabel(name: name, visible: true), name)
                } catch where httpStatus(of: error) == 409 {
                    // Gmail already has a label by this name (compared
                    // without case): apply that one, under its name.
                    guard let existing = try await gmail.findLabelByName(name) else { throw error }
                    return existing
                }
            }
            group.addTask {
                try await Task.sleep(for: GmailAPI.labelCreateTimeout)
                throw UserLabelCreationTimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        return ProviderUserLabel(providerLabelId: label.id, name: label.name, isSystem: false)
    }

    /// One label per Gmail label in the folder list (user labels appear as
    /// custom folders). Nested labels (e.g., "Work/Projects/Alpha") keep their
    /// full name; splitting into segments happens at display time in the chip
    /// view. `tm_*` names (handled by ActionTag) are left out; system and
    /// auto-created labels are kept, flagged `isSystem`.
    static func userLabelCatalog(from folders: [FolderInfo]) -> [ProviderUserLabel]? {
        folders.compactMap { info in
            // Skip tm_* labels (handled by ActionTag) and system/auto-created labels
            if UserLabelStore.isExcludedKeyword(info.name) { return nil }
            return ProviderUserLabel(
                providerLabelId: info.path, name: info.name,
                isSystem: UserLabelStore.isGmailSystemLabel(id: info.path, name: info.name))
        }
    }

    /// Since label IDs are opaque (`Label_N`), we can't tell user vs system vs
    /// `tm_*` by the ID alone. Instead we take the path main-app already walks:
    /// look up each ID in the `userLabel` table. Only real user labels (rows with
    /// `isSystem=false`) are kept. tm_* labels aren't in that table (main-app
    /// `extractUserLabelIds` filters them out before insert). System labels are
    /// either absent or have `isSystem=true`. Zero extra I/O — the transaction
    /// already has `db`. Cold-start caveat: if this device's main-app hasn't yet
    /// called `fetchFolders`, `userLabel` is empty and no user labels materialize
    /// on the NSE row until sync runs. Push subscription normally follows a sync,
    /// so this is mostly hypothetical.
    static func storedUserLabelIds(fromPushed rawLabels: [String], accountId: String, db: Database) throws -> [String] {
        // Query userLabel for known non-system user labels on this
        // account. A single `IN` query covers all staged labelIds.
        //
        // 🚨 MATCHES AND RETURNS `providerLabelId`, NOT `id` (D10 /
        // `IOS-LABEL-001`). `rawLabels` are the provider's own label ids
        // straight off the push payload, and `userLabel.id` is now the
        // account-prefixed surrogate — matching against it would find
        // nothing and silently strip every Gmail user label from every
        // NSE-delivered message. This function's contract, on every
        // provider, is "bare provider label ids in, bare provider
        // label ids out"; the caller re-mints the surrogate.
        //
        // A6: `providerLabelId` is unindexed, so this is a scan of
        // `userLabel` rather than the previous primary-key probe. That
        // table holds a user's labels — tens of rows, one small page —
        // and an index to serve one NSE-merge lookup is not justified.
        guard !rawLabels.isEmpty else { return [] }
        let placeholders = rawLabels.map { _ in "?" }.joined(separator: ",")
        let args: [DatabaseValueConvertible] = [accountId] + rawLabels
        let known = try String.fetchAll(db, sql: """
            SELECT providerLabelId FROM userLabel
            WHERE accountId = ? AND isSystem = 0 AND providerLabelId IN (\(placeholders))
            """, arguments: StatementArguments(args))
        let knownSet = Set(known)
        return rawLabels.filter { knownSet.contains($0) }
    }
}
