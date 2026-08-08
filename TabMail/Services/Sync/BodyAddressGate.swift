/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Refuses a body fetch/write for a row whose provider address is not corroborated.
///
/// **THE DEFECT THIS CLOSES.** `AccountManager.optimisticMoveToFolder` moves the local row to the
/// destination folder while KEEPING THE SOURCE UID, and nulls `observedUidValidity` in the same
/// write. Until the drain's `MessageHeaderRekey.finishMove` re-keys it, the row's address is
/// `(destination folder, SOURCE UID)`. On IMAP each folder owns its own UID space, so that address
/// names a DIFFERENT message. `BackfillBodyQueue` selects exactly those rows by construction
/// (`bodyComplete = 0 AND isInInbox = 0`), fetched the stranger, and stored its body under the moved
/// message's content key — a durable wrong body plus a wrong FTS entry. Present in shipped
/// `v1.6.38`.
///
/// **WHY THE TEST IS "RESOLVES", NOT "CHANGED".** Graph ids are not stable across a move either
/// (`IOS-GRAPH-002`) — but a stale Graph id is an opaque mailbox-unique string, so it MISSES
/// (`404 ErrorItemNotFound`). A stale IMAP UID is a small dense per-folder integer, so it HITS a
/// stranger. The hazard is *silent resolution to another message*, which is why this gate keys off
/// the address space's reuse semantics and not off a provider blocklist.
///
/// **THE MARKER IS THE ROW'S OWN PRIMARY KEY — no new state, no query, no coupling.**
/// `MessageIdentity.headerId` is `"<accountId>:<folderPath>:<messageId>"`, and
/// `optimisticMoveToFolder` **leaves the primary key and `messageId` at their SOURCE values** while
/// rewriting `folderPath` to the destination (stated verbatim in `AccountManager.executeSingleOp`).
/// So for exactly the window this gate closes — and only that window — the row's id encodes a
/// DIFFERENT folder than the row currently claims. `MessageHeaderRekey.finishMove` re-keys the row,
/// which restores agreement.
///
/// ⚠️ **WHY NOT `observedUidValidity == nil`.** That was rev A's proxy and it OVER-MATCHES. A nil
/// epoch also covers rows that were merely never stamped — synced when the folder's epoch was not
/// bound (the backfill-only-folder population), or created before the column existed. Gating on it
/// would refuse body fetches for legitimate messages, which never load and never recover: a more
/// visible bug than the one being fixed. `OversizedBodyQuarantineTests` caught exactly that — it
/// asserts an ordinary nil-epoch IMAP row is fetchable, and it is right to.
///
/// **The key is RE-MINTED from the row's own fields and compared whole, never prefix-matched.**
/// A bare prefix test is blind when the folder path contains the separator — source `Archive:Child`
/// mints `acct:Archive:Child:41`, which still matches the prefix `acct:Archive:` after a move to
/// `Archive`, so the very row this gate exists to catch would read as settled. Equality against
/// `MessageIdentity.headerId(accountId:folderPath:messageId:)` is exact instead, and it parses
/// nothing, so a `:` in either the folder path or the messageId is just data.
///
/// **The gate also compares the fetch's own provenance.** The bytes were fetched against
/// `item.folderPath`/`item.messageId`; the row is re-read at write time. If those disagree the row
/// moved *while the fetch was in flight*, so the bytes belong to an address the row no longer has.
/// This is the case the key test alone cannot see: an undo annihilating an unattempted move restores
/// the source `folderPath`, making the key agree again, while the in-flight bytes are still the
/// destination stranger's.
///
/// **RECOVERY — stated as what is actually GUARANTEED, not as "sync always fixes it".** A refused
/// row keeps `bodyComplete = 0` and `bodyEmptyConfirmed = 0`, so it stays in both body queues'
/// candidate set and is re-attempted; nothing is marked fetched and nothing is dropped. What clears
/// the refusal is the row's key coming back into agreement with its folder, and the guaranteed path
/// for that is `MessageHeaderRekey.finishMove` re-keying on `COPYUID` proof — seconds on the happy
/// path. A folder sync that re-inserts the row at its destination address clears it too.
///
/// ⚠️ Do NOT upgrade that to "ordinary sync always recovers it" (an earlier draft of this comment
/// did, and an audit was right to reject it): a row whose move never completes and whose destination
/// folder is never synced stays refused. That state is a *stuck move* — the body not loading is a
/// symptom of it, not a new failure introduced here — and the pre-fix behaviour in that same state
/// was to durably store another message's body under this row's key. Refusing is strictly better,
/// and it is reversible the moment the move resolves.
///
/// 🚨 **THE STALE-OPEN-VIEW CLOSURE — everything above is about the DURABLE ROW; an already-open
/// view is a separate question, and answering it one site at a time cost three audit rounds.**
/// State the closure instead of its instances:
///
/// > **No event that leaves a view model's in-memory `MessageHeader` stale can heal that view.**
///
/// The re-key is a DELETE at the old key plus an INSERT at the new one (`MessageHeaderRekey.apply`),
/// and `AccountManagerQueue.publishRekeys` mirrors the mapping to Undo, `SearchIndex` and
/// `BodyAssetStore` — **never into a live `MessageDetailViewModel`**. So every screen that holds a
/// captured header — the detail body poll, pull-to-refresh, the three attachment surfaces, a forward
/// launched from that view — keeps testing the pre-move `(destination folder, SOURCE UID)` pair
/// **on every path that needs a NEW fetch**, and stays refused there even after the database has
/// settled. Waiting does not help; repeating a fetch-requiring gesture in the same view does not
/// help; a later sync does not help.
///
/// **The guaranteed recovery is always the same: back out to the message list and reopen**, which
/// rebuilds the view model against the current row. Any narrower claim ("it will load once the move
/// completes", "pull again", "tap it again", "forward it again") is false for this class, and one
/// was found live in a different file in each of rounds 9, 10 and 11.
///
/// ⚠️ **"On every path that needs a NEW fetch" is a load-bearing qualifier, added after an audit
/// round rejected the blanket version of this paragraph.** A blanket closure is false in one
/// direction and, worse, licenses deleting the true exceptions. The boundary, stated exactly:
/// - **A file already materialized into the view's own state still opens.** `AttachmentListView`
///   hands a `downloadedFiles[section]` hit straight to `AttachmentQuickLook.present`, and
///   `EmlAttachmentPreview` assigns its `previewURL` the same way — neither calls
///   `AccountManager.fetchAttachment`, so neither reaches the guard. Those taps keep working in the
///   stale view for as long as it lives.
/// - **A durable-cache hit does NOT survive the re-key.** `publishRekeys` also calls
///   `BodyAssetStore.rekeyContentKey`, which moves the manifest row from the old content key to the
///   destination one. A stale view still asks `attachmentAssetId` for the OLD key, so after the
///   re-key it MISSES a cache that is sitting right there under the new key — and then falls
///   through to the refusing guard. So the durable cache is an exception BEFORE the re-key and not
///   after it, which is the opposite of what "cached attachments still open" suggests on its own.
///
/// **Two further things this closure does NOT say**, because overcorrecting is its own defect:
/// - The poll still heals SAME-KEY failures — a connection error, a lock timeout, or a body that
///   later lands under this row's existing key. It is only the re-key branch that it cannot see.
/// - A repeat gesture is not guaranteed, but it is not useless either: a fresh `ComposeView`
///   re-resolves through `Draft.resolveReplyToHeader`, whose Strategy 2 (account + UNIQUE
///   `rfc822MessageId`) usually finds the re-keyed row. It fails closed on a message with no
///   Message-ID and on duplicate RFC matches — which is why reopening, which restores Strategy 1's
///   direct primary-key hit, is the instruction to give the user. ⚠️ **With one caveat that cost a
///   blocking finding: reopening only restores Strategy 1 if no DRAFT was saved under the
///   deterministic `forward:<accountId>:<stableId>` key.** If one was, `loadDraftOrPrepopulate`
///   takes its existing-draft branch, resolves from the persisted `draft.replyToId`, restores the
///   saved attachment set and never re-runs `carryForwardAttachments` (`IOS-COMPOSE-001`). That is
///   why the carry-forward alert tells the user to DISCARD rather than merely close.
enum BodyAddressGate {

    /// Why a fetch/write was refused. `nil` means "proceed".
    enum Refusal: Sendable, Equatable {
        /// The row sits in an address space where a stale address resolves to another
        /// message, and nothing has corroborated this address yet.
        case addressNotCorroborated
        /// The message the server actually returned is not the message the row names.
        case identityMismatch(stored: String, fetched: String)
        /// The row moved (or moved back) while this fetch was in flight, so the bytes in hand
        /// were fetched against an address the row no longer has.
        case fetchProvenanceMismatch
        /// The row or its account could not be read, so the address could not be verified.
        /// An UNKNOWN answer is retryable, never authoritative — writing under it would be
        /// exactly the "could not determine ⇒ treat as proven" conflation that the
        /// never-drop rule names as this codebase's most repeated defect.
        case verificationUnavailable

        /// Log form. Message-IDs are user data and these lines land in a PERSISTENT diagnostic
        /// file, so no part of either id is rendered.
        ///
        /// ⚠️ **This used to log a 24-character prefix of each id, with a comment asserting that
        /// was "not enough to reconstruct a correspondent". That was wrong** — `alice@example.com`
        /// is 17 characters, so the prefix was the WHOLE identifier for any ordinary address-shaped
        /// Message-ID, and the comment's confidence is exactly what stopped anyone counting.
        /// (Found by audit.) The lengths are kept because they distinguish "both present and
        /// different" from a malformed value without revealing either.
        var logDescription: String {
            switch self {
            case .addressNotCorroborated:
                return "address in flight (row id names a different folder than the row claims — optimistic move not yet re-keyed)"
            case .identityMismatch(let stored, let fetched):
                return "identity mismatch (row's Message-ID and the server's differ; lengths \(stored.count)/\(fetched.count) — values withheld, this log persists)"
            case .fetchProvenanceMismatch:
                return "fetch provenance mismatch (row moved while the fetch was in flight — these bytes were fetched against an address it no longer has)"
            case .verificationUnavailable:
                return "verification unavailable (row or account unreadable)"
            }
        }
    }

    /// True when a stale address in this account RESOLVES to a different message rather than
    /// missing — i.e. the account numbers messages in a reused per-folder space.
    ///
    /// Same provider classification as `AccountManager.admissionEpochForNewGesture` and
    /// `admittedOrdinaryActionTargets`: the IMAP family, minus the Demo account, which is stored as
    /// IMAP but served by `DemoProvider` (no wire, no UID reuse).
    static func addressCanResolveToAnotherMessage(provider: AccountProvider, accountId: String) -> Bool {
        guard provider == .imap || provider == .icloud else { return false }
        guard accountId != DemoSeed.demoAccountId else { return false }
        return true
    }

    /// True when the row's primary key encodes a DIFFERENT folder than the row currently claims —
    /// i.e. `optimisticMoveToFolder` has moved it and `finishMove` has not re-keyed it yet, so its
    /// `messageId` is a UID from the SOURCE folder's space.
    ///
    /// Provider-independent by construction; the caller decides whether that is hazardous.
    /// ⚠️ **RECONSTRUCT AND COMPARE WHOLE — do not `hasPrefix`, and do not use
    /// `headerIdBelongsToFolder` here.** The row's key is a pure function of three fields the row
    /// still carries, so the exact test is to re-mint it with the same helper that minted it and
    /// compare for equality. Neither weaker predicate is correct at this call site:
    ///
    /// - A raw `hasPrefix(headerIdPrefix(...))` is **BLIND** when the folder path contains the
    ///   separator: source `Archive:Child` mints `acct:Archive:Child:41`, which still carries the
    ///   prefix `acct:Archive:` after a move to `Archive`, so the very row this gate exists to catch
    ///   reads as settled. (This was the first cut; found by audit.)
    /// - `MessageIdentity.headerIdBelongsToFolder` fixes that with a "no deeper colon" clause, but
    ///   that clause reads any id whose **messageId** contains `:` as not belonging — and
    ///   reply-draft header ids carry exactly that extra colon (a live v3 quirk). Those rows would be
    ///   refused *permanently*, which is the same never-loads-never-recovers failure that got rev A
    ///   rejected. It is the right predicate for callers that have only an id to classify; it is the
    ///   wrong one here, where the messageId is in hand.
    ///
    /// Equality on the re-minted key is exact for both: it parses nothing, so a `:` in the folder
    /// path or in the messageId is simply data on both sides of the comparison.
    static func addressIsInFlight(
        id: String, accountId: String, folderPath: String, messageId: String
    ) -> Bool {
        id != MessageIdentity.headerId(
            accountId: accountId, folderPath: folderPath, messageId: messageId)
    }

    /// The corroboration test. Providers whose stale addresses merely MISS are always fetchable —
    /// only a reused per-folder UID space turns a stale address into a different message.
    static func isAddressCorroborated(
        id: String,
        accountId: String,
        folderPath: String,
        messageId: String,
        provider: AccountProvider
    ) -> Bool {
        guard addressCanResolveToAnotherMessage(provider: provider, accountId: accountId) else {
            return true
        }
        return !addressIsInFlight(
            id: id, accountId: accountId, folderPath: folderPath, messageId: messageId)
    }

    /// Defense-in-depth identity check, applied to what the server actually returned.
    ///
    /// Positive and two-sided ON PURPOSE: it fires only when BOTH ids are present and they differ.
    /// RFC 5322 makes `Message-ID` a SHOULD, not a MUST, so a nil on either side is an absence of
    /// evidence and must NOT refuse — treating it as a mismatch would refuse legitimate mail from
    /// every server that omits the header.
    ///
    /// Both sides already flow through `EmailFilter.normalizeMessageId` (the header sync path and
    /// the full-message fetch path share `IMAPProvider.mapMessageInfo`), so this normalizes only as
    /// belt-and-suspenders against a future producer that does not.
    static func identityContradicts(stored: String?, fetched: String?) -> Bool {
        guard let stored, let fetched else { return false }
        guard !stored.isEmpty, !fetched.isEmpty else { return false }
        return EmailFilter.normalizeMessageId(stored) != EmailFilter.normalizeMessageId(fetched)
    }

    /// Combined gate for the write path. `nil` ⇒ the write may proceed.
    static func refusal(
        id: String,
        accountId: String,
        folderPath: String,
        messageId: String,
        provider: AccountProvider,
        storedRfc822MessageId: String?,
        fetchedRfc822MessageId: String?
    ) -> Refusal? {
        // BOTH halves are scoped to the same hazard: an address space where a stale address
        // RESOLVES to another message. Where a stale address merely MISSES (Gmail/Graph — a 404,
        // not a stranger), there is no wrong-message write for either check to prevent, so the
        // identity backstop can only produce false refusals there. Scoping it out is deliberate:
        // over-matching is the failure mode that killed rev A, and a refusal on this path is
        // permanent for any row whose stored and server-side Message-IDs legitimately differ.
        guard addressCanResolveToAnotherMessage(provider: provider, accountId: accountId) else {
            return nil
        }
        if !isAddressCorroborated(
            id: id, accountId: accountId, folderPath: folderPath, messageId: messageId,
            provider: provider) {
            return .addressNotCorroborated
        }
        if identityContradicts(stored: storedRfc822MessageId, fetched: fetchedRfc822MessageId) {
            return .identityMismatch(
                stored: storedRfc822MessageId ?? "", fetched: fetchedRfc822MessageId ?? "")
        }
        return nil
    }

    /// Read-path convenience for callers that already hold the row: the interactive
    /// `AccountManager.fetchBody` and `MessageDetailViewModel.loadBody`. Identity cannot be checked
    /// before the fetch (nothing has been returned yet), so this is the address half only.
    static func isFetchable(header: MessageHeader, provider: AccountProvider) -> Bool {
        isAddressCorroborated(
            id: header.id,
            accountId: header.accountId,
            folderPath: header.folderPath,
            messageId: header.messageId,
            provider: provider)
    }

    /// Look up the account's provider for a header. Returns nil when the account is gone.
    static func provider(forAccountId accountId: String, db: Database) throws -> AccountProvider? {
        try Account.fetchOne(db, key: accountId)?.provider
    }
}
