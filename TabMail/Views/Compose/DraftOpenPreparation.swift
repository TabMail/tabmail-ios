/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import SwiftUI
import GRDB

/// Everything opening a saved draft waits for, done BEFORE its compose is shown
/// (#309), so the compose's first frame already holds the draft. The screen the
/// draft was opened from keeps a busy mark on it meanwhile; a compose that
/// appeared empty and filled in later read as a blank.
///
/// The order is the open's contract: resolve a Drafts header to its local row
/// (adopting a draft another mail app wrote, #217), reload a clean Gmail or
/// Outlook row from its server copy (ADR-IOS-091, capped at
/// `ExternalDraftOpenConfig.reloadTimeoutSeconds`), then read the row with its
/// exact owning account and reply parent. `ComposeView` repeats its own guarded
/// read of the row at the handoff and does not read the server again.
enum DraftOpenPreparation {
    enum Source {
        /// A Drafts header: the Drafts list, the detail column, a chat pill.
        case header(MessageHeader)
        /// A local draft row: the compose agent's working draft.
        case draftId(String)
    }

    /// A draft ready to edit. The account is non-optional: a persisted `Draft`
    /// only ever opens bound to the exact account that OWNS the row
    /// (`ComposeDraftGuards.mayBindPersistedDraft`). There is no nil-account open,
    /// because a nil account is what let the inner `ComposeView` fall back to
    /// `navigationStore.accounts.first`.
    struct Prepared {
        let draft: Draft
        let account: Account
        let replyTo: MessageHeader?
        let openAuthority: LocallyAuthoredDraftOpenAuthority?
    }

    enum Failure: Equatable {
        /// AUTHORITATIVE ABSENCE (`ServerDraftComposeLoader.Resolution.noLocalCopy`).
        case noLocalCopy
        /// The draft holds an attachment TabMail cannot carry (#241). Final.
        case unsupportedAttachment
        /// The open-time reload found the server copy replying to another message
        /// and removed the row (`ExternalDraftAdoption.OpenCheck.replacedElsewhere`).
        case changedWhileOpening
        /// PORT — v2final `DraftComposePresenter.LoadResult.accountUnavailable`
        /// (D-OPEN #5, commits `a8eb813b5` / `69a9bae88`). The draft's exact owning
        /// account could not be resolved. FAIL CLOSED — never open on a fallback
        /// account, which would send from / attach to the WRONG account.
        case accountUnavailable
        /// ⚑ NO REFERENCE — INVENTED. A read or a provider call THREW, so whether
        /// the draft can open is UNKNOWN. Retryable, never authoritative: a thrown
        /// read collapsed into "not found" auto-dismissed, so a momentarily busy or
        /// suspended database made the user's tap silently do nothing at all.
        case loadFailed
    }

    enum Outcome {
        case ready(Prepared)
        /// The row is gone, or is no longer the one the header named: nothing opens.
        case nothingToOpen
        case unavailable(Failure)
    }

    typealias Resolver = @MainActor @Sendable () async throws -> LocallyAuthoredDraftOpenAuthority?

    /// `resolver` replaces only the header-to-row resolution, for UI-test fixtures.
    @MainActor
    static func prepare(_ source: Source, resolver: Resolver? = nil) async -> Outcome {
        let draftId: String
        var openAuthority: LocallyAuthoredDraftOpenAuthority?
        switch source {
        case .draftId(let id):
            draftId = id
        case .header(let header):
            let resolved: Result<LocallyAuthoredDraftOpenAuthority?, any Error>
            do {
                if let resolver {
                    resolved = .success(try await resolver())
                } else {
                    resolved = .success(try await ServerDraftComposeLoader.resolveOpenAuthority(header: header))
                }
            } catch {
                resolved = .failure(error)
            }
            switch ServerDraftComposeLoader.classify(resolved) {
            case .authorized(let authority):
                openAuthority = authority
                draftId = authority.draftId
            case .noLocalCopy:
                return .unavailable(.noLocalCopy)
            case .resolveFailed:
                return .unavailable(.loadFailed)
            case .unsupportedAttachment:
                return .unavailable(.unsupportedAttachment)
            }
        }
        // #217 (ADR-IOS-091): every open of a saved draft, from any screen, first
        // reloads a Gmail or Outlook row with no unsent edits from its server copy.
        switch await ExternalDraftAdoption.refreshBeforeOpen(draftId: draftId, willReadServer: {}) {
        case .open:
            break
        case .unsupportedAttachment:
            return .unavailable(.unsupportedAttachment)
        case .replacedElsewhere:
            return .unavailable(.changedWhileOpening)
        }
        return await load(draftId: draftId, openAuthority: openAuthority)
    }

    /// Load the draft and its owning account, FAIL CLOSED on both axes.
    private static func load(
        draftId: String, openAuthority: LocallyAuthoredDraftOpenAuthority?
    ) async -> Outcome {
        BackgroundSyncLogger.logDebug("[DraftOpenPreparation] Loading draft: \(draftId)")
        let loaded: (Draft, Account?)?
        do {
            loaded = try await AppDatabase.dbPool.read { db in
                guard let draft = try Draft.fetchOne(db, key: draftId) else { return nil }
                return (draft, try Account.fetchOne(db, key: draft.accountId))
            }
        } catch {
            // A THROWN read is NOT absence. The superseded `return .notFound` here
            // auto-dismissed the presenter, so a busy/suspended database silently
            // swallowed the user's tap on an existing draft.
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DraftOpenPreparation] ⚠ Draft/Account read THREW for \(draftId) — offering retry, not dismissal: \(error)")
            }
            return .unavailable(.loadFailed)
        }
        guard let (draft, account) = loaded else {
            BackgroundSyncLogger.logDebug("[DraftOpenPreparation] Draft NOT FOUND: \(draftId)")
            return .nothingToOpen
        }

        // PORT — v2final `ServerDraftOpen.mayBindPersistedDraft` (commits
        // `a8eb813b5` / `69a9bae88`), via `ComposeDraftGuards`. EVERY persisted
        // `Draft` open requires the row's exact owning `Account`; there is no
        // accounts-first fallback. Previously a nil `account` was handed to
        // `ComposeView` as `account: nil`, whose `resolvedAccount` then fell through
        // to `navigationStore.accounts.first` — a silent bind to the WRONG account,
        // which sends from the wrong address and pushes the server draft into the
        // wrong mailbox. `ComposeView` repeats this binding at its own handoff.
        //
        // SUBTRACT — v2final's `serverDraftHeader` arm (`mayOpenWithAccount`) and
        // the Gmail/Outlook `mayReuseAtComposeHandoff` RFC/RESOURCE revalidation are
        // NOT ported. `DraftComposePresenter` here has no `serverDraftHeader` and no
        // `backSeed` parameter: this forward-port's server-draft open path is
        // `LocallyAuthoredDraftOpenAuthority`, whose `matches(_:runtimeKind:)`
        // already requires the exact provider-native address (`serverDraftId ==
        // resourceId` / `graphId` / `localId`) plus accountId, instanceEpoch and
        // serverPushStatus equality against the freshly-read row — a STRICTER check
        // than the reference's RFC-corroborated union, and re-run inside
        // `ComposeView.loadDraftOrPrepopulate` at the second handoff. The
        // reference's premise (a Gmail row whose RESOURCE must be recovered from a
        // contained MESSAGE id, matched by rotating RFC) has no producer here:
        // nothing in this tree constructs a `ServerDraftOpen.Identity` or opens a
        // compose from a bare server header.
        guard ComposeDraftGuards.mayBindPersistedDraft(
            draftAccountId: draft.accountId, resolvedAccountId: account?.id
        ), let account else {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DraftOpenPreparation] Persisted-draft account unavailable — fail closed (draft.accountId=\(draft.accountId.prefix(20)) account=\(account == nil ? "nil" : "set"))")
            }
            return .unavailable(.accountUnavailable)
        }

        if let openAuthority {
            guard openAuthority.draftId == draftId,
                  account.id == openAuthority.accountId,
                  let runtimeKind = await AccountManager.shared.draftRuntimeIdentityKind(
                      accountId: openAuthority.accountId),
                  openAuthority.matches(draft, runtimeKind: runtimeKind) else {
                return .nothingToOpen
            }
        }

        // Resolve reply-to message (with stableId fallback for stale PKs).
        //
        // A THROWN resolver read is NOT "this draft has no reply parent". The
        // superseded call went through `Draft.resolveReplyToHeader`'s non-`db`
        // overload, whose whole body is `try? AppDatabase.dbPool.read { … }`: a
        // busy or suspended database returned nil and this function still returned
        // `.loaded(draft:replyTo: nil, account:)`. That manufactured an
        // authoritative negative out of "we could not look" — the never-drop
        // clause-2 error, in the very function whose `.loadFailed` arm documents
        // that a thrown read is not absence. A genuine REFUSAL by the guard still
        // returns nil and still opens compose (unquoted); only the throw diverts.
        let replyToResult: Result<MessageHeader?, Error>
        do {
            replyToResult = .success(try await resolveReplyTo(draft: draft, draftId: draftId))
        } catch {
            replyToResult = .failure(error)
        }
        guard ComposeDraftGuards.readState(replyToResult) != .error else {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DraftOpenPreparation] ⚠ Reply-target resolve THREW for \(draftId) — offering retry, not a nil reply target")
            }
            return .unavailable(.loadFailed)
        }
        // `.error` is excluded above, so this is the resolver's genuine verdict:
        // a proven header, or a refusal (nil) that opens compose with no parent.
        let replyTo: MessageHeader?
        if case .success(let value) = replyToResult { replyTo = value } else { replyTo = nil }

        BackgroundSyncLogger.logDebug("[DraftOpenPreparation] Loaded draft: \(draftId) replyTo=\(replyTo?.id.prefix(20) ?? "nil")")
        return .ready(Prepared(draft: draft, account: account, replyTo: replyTo, openAuthority: openAuthority))
    }

    /// T5.8 — resolve through the GUARDED resolver. `draft.replyToId` is a
    /// `MessageHeader` PRIMARY KEY and that key is MUTABLE
    /// (`accountId:folderPath:messageId`), so a folder move re-keys it and a
    /// UIDVALIDITY reset + purge-and-resync can seat a DIFFERENT physical message at
    /// the identical PK. The header this returns is handed straight to
    /// `ComposeView(replyTo:)`, where it drives the reply address, the subject and
    /// the quote attribution — so an unguarded hit here is a wrong-correspondent
    /// reply, not merely a wrong quote. The v80 stamp names the address the user
    /// actually replied to; nil (a pre-v80 row) falls to the draft key's RFC
    /// baseline inside the resolver, never to an unconditional accept.
    ///
    /// Goes through the `db`-scoped overload and PROPAGATES a failed read, so the
    /// caller can tell a refusal (nil) from an unreadable database (throw). The
    /// non-`db` convenience overload swallows the latter into the former.
    private static func resolveReplyTo(draft: Draft, draftId: String) async throws -> MessageHeader? {
        // Hoisted into locals so the `@Sendable` read closure captures plain values.
        let replyToId = draft.replyToId
        let isForward = draft.isForward
        let expectedProviderMessageId = draft.replyToProviderMessageId
        let expectedUidValidity = draft.replyToUidValidity
        return try await AppDatabase.dbPool.read { db in
            try Draft.resolveReplyToHeader(
                draftKey: draftId, replyToId: replyToId, isForward: isForward,
                expectedProviderMessageId: expectedProviderMessageId,
                expectedUidValidity: expectedUidValidity, db: db)
        }
    }
}

/// A prepared draft open, as the item a full-screen cover presents.
struct PreparedDraftOpen: Identifiable {
    let id = UUID()
    let source: DraftOpenPreparation.Source
    let outcome: DraftOpenPreparation.Outcome
}

/// #309: the one draft open being prepared, app-wide, and where its busy mark
/// shows. The newest user action wins: a newer open replaces it, and an accepted
/// navigation (another message, a folder, a chat pill) cancels it, so a slow
/// preparation never presents over what the user went to next.
@MainActor @Observable
final class DraftOpenTracker {
    static let shared = DraftOpenTracker()

    /// The mark of the compose button's working-draft open.
    static let toolbarMark = "compose-toolbar"

    private(set) var token: UUID?
    /// The list row id (or `toolbarMark`) showing the busy mark; nil for an open
    /// started from a toast or a chat pill whose row is not on screen.
    private(set) var mark: String?

    /// Starts an open, replacing any still being prepared: the newest wins, even
    /// from the same place (the toolbar's working draft may have changed).
    func begin(mark: String?) -> UUID {
        let started = UUID()
        token = started
        self.mark = mark
        return started
    }

    /// Ends the open `started` began: false when a newer open or navigation
    /// replaced it, so its outcome must not present.
    func end(_ started: UUID) -> Bool {
        guard token == started else { return false }
        cancel()
        return true
    }

    /// A newer navigation was accepted: the open being prepared must not present.
    func cancel() {
        token = nil
        mark = nil
    }
}

extension DraftOpenPreparation {
    /// Prepares `source` under a `DraftOpenTracker` token, with the busy mark on
    /// `mark` meanwhile. Returns the open to present, or nil for an open a newer
    /// action replaced, and nothing to open.
    @MainActor
    static func open(_ source: Source, mark: String?, resolver: Resolver? = nil) async -> PreparedDraftOpen? {
        let tracker = DraftOpenTracker.shared
        let started = tracker.begin(mark: mark)
        let outcome = await prepare(source, resolver: resolver)
        guard tracker.end(started) else { return nil }
        if case .nothingToOpen = outcome { return nil }
        return PreparedDraftOpen(source: source, outcome: outcome)
    }

    /// The Drafts header `messageId` names, or nil for any other message. One read
    /// transaction, so the header and its folder's role agree.
    static func draftsHeader(messageId: String) -> MessageHeader? {
        try? AppDatabase.dbPool.read { db -> MessageHeader? in
            guard let header = try MessageHeader.fetchOne(db, key: messageId),
                  try Folder.fetchOne(db, key: header.folderId)?.role == .drafts else { return nil }
            return header
        }
    }
}

/// The busy mark a draft shows where it was opened while its compose is prepared.
struct DraftOpeningMark: View {
    var body: some View {
        ProgressView()
            .padding(8)
            .background(.regularMaterial, in: Circle())
            .accessibilityLabel("Opening draft")
    }
}
