/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB

/// Issue #217: open and edit a draft that ANOTHER mail app (Gmail web, Apple Mail,
/// Outlook, …) left in the Drafts folder.
///
/// PORT of the July (v2final) "fresh writable" server-draft open, adapted to v3's
/// typed provider-native addresses. Instead of opening a compose that carries the
/// server identity on the side, adoption writes an ordinary `Draft` row that owns
/// the server copy's EXACT address — the same row a draft authored on this device
/// has after its first push. From there every existing path (reopen, save-replaces,
/// send-deletes, discard) treats it exactly like a local draft.
///
/// OWNER RULING (2026-10-17): take over the draft whichever client wrote it, and if
/// two apps edit it at the same time, the last save wins. There is deliberately NO
/// lease, lock or conflict warning — the v2final Outlook lease is not ported.
///
/// What still fails closed, because each one is an irreversible-wire hazard rather
/// than a concurrency question:
/// - the address must be exact (IMAP needs the header's observed UIDVALIDITY to
///   equal the Drafts folder's live epoch; a placeholder id is never an address);
/// - the header is re-verified inside the SAME write transaction that inserts the
///   row, so a re-key or renumbering during the network fetches adopts nothing;
/// - a body or attachment that could not be read is retryable, never "empty".
enum ExternalDraftAdoption {
    /// Draft-key prefix for an adopted row. A random suffix, not a derived one: the
    /// insert transaction's owner check is what prevents a duplicate adoption.
    static let draftKeyPrefix = "adopted:"

    static func isAdoptedKey(_ draftId: String) -> Bool {
        draftId.hasPrefix(draftKeyPrefix)
    }

    /// A read or fetch that must be retried before the draft can be adopted.
    enum AdoptionError: Error, Equatable {
        /// The body is not on the device yet, or reads as empty without the
        /// server having confirmed it empty. Opening it would let the first save
        /// overwrite the real server draft with nothing.
        case bodyUnavailable
    }

    // MARK: - Address

    /// The provider-native address of `header`'s server copy, or nil when there is
    /// no exact one. Pure; `folder` must be the header's own folder row.
    ///
    /// Gmail is not handled here: its draft RESOURCE id needs a provider round trip
    /// (`GmailProvider.resolveDraftResource`), so the caller supplies it.
    static func nativeAddress(
        header: MessageHeader,
        folder: Folder,
        runtimeKind: DraftRuntimeIdentityKind
    ) -> LocallyAuthoredDraftOpenAuthority.Address? {
        guard folder.role == .drafts,
              folder.accountId == header.accountId,
              folder.path == header.folderPath,
              !isSyntheticPlaceholderId(header.messageId) else {
            return nil
        }
        switch runtimeKind {
        case .imap:
            // The SAME coordinates `InboxViewModel.deleteDraftMessage` requires of a
            // synced IMAP draft: a numeric UID plus the UIDVALIDITY observed with it,
            // agreeing with the folder's live, unquarantined epoch.
            guard UInt32(header.messageId) != nil,
                  folder.uidValidityResetPendingAt == nil,
                  let liveEpoch = folder.lastKnownUidValidity, liveEpoch > 0,
                  header.observedUidValidity == liveEpoch else {
                return nil
            }
            return .imap(folderPath: folder.path, uidValidity: liveEpoch, uid: header.messageId)
        case .outlook:
            return .outlook(graphId: header.messageId)
        case .gmail, .demo, .unknown:
            return nil
        }
    }

    /// Re-reads `captured` and its Drafts folder; nil when either changed. The same
    /// identity fields `LocallyAuthoredDraftOpenAuthority.resolve` checks.
    static func currentDraftsHeader(
        db: Database,
        captured: MessageHeader
    ) throws -> (header: MessageHeader, folder: Folder)? {
        guard let current = try MessageHeader.fetchOne(db, key: captured.id),
              current.accountId == captured.accountId,
              current.folderId == captured.folderId,
              current.folderPath == captured.folderPath,
              current.messageId == captured.messageId,
              current.rfc822MessageId == captured.rfc822MessageId,
              current.observedUidValidity == captured.observedUidValidity,
              let folder = try Folder.fetchOne(db, key: current.folderId),
              folder.role == .drafts else {
            return nil
        }
        return (current, folder)
    }

    /// The non-Gmail address to adopt, read fresh. nil = nothing adoptable.
    static func adoptableAddress(
        db: Database,
        header: MessageHeader,
        runtimeKind: DraftRuntimeIdentityKind
    ) throws -> LocallyAuthoredDraftOpenAuthority.Address? {
        guard let (current, folder) = try currentDraftsHeader(db: db, captured: header) else {
            return nil
        }
        return nativeAddress(header: current, folder: folder, runtimeKind: runtimeKind)
    }

    /// Whether `address`, re-derived from the current rows, still names `header`.
    private static func addressStillNames(
        _ address: LocallyAuthoredDraftOpenAuthority.Address,
        header: MessageHeader,
        folder: Folder,
        runtimeKind: DraftRuntimeIdentityKind
    ) -> Bool {
        if case .gmail(_, let containedMessageId) = address {
            return runtimeKind == .gmail
                && folder.accountId == header.accountId
                && folder.path == header.folderPath
                && header.messageId == containedMessageId
        }
        return nativeAddress(header: header, folder: folder, runtimeKind: runtimeKind) == address
    }

    /// Whether any `Draft` row of the account already owns `address`. An owner,
    /// whatever its state, is never duplicated.
    static func addressIsOwned(
        _ address: LocallyAuthoredDraftOpenAuthority.Address,
        accountId: String,
        db: Database
    ) throws -> Bool {
        var request = Draft.filter(Column("accountId") == accountId)
        switch address {
        case .imap(let folderPath, let uidValidity, let uid):
            request = request
                .filter(Column("serverDraftId") == uid)
                .filter(Column("serverDraftFolderPath") == folderPath)
                .filter(Column("serverDraftUidValidity") == uidValidity)
        case .gmail(let resourceId, _):
            request = request.filter(Column("serverDraftId") == resourceId)
        case .outlook(let graphId):
            request = request.filter(Column("serverDraftId") == graphId)
        case .placeholder, .demo:
            // Never adopted; report owned so nothing is inserted.
            return true
        }
        return try request.fetchCount(db) > 0
    }

    // MARK: - Content

    /// The editable plain-text body, or nil when it must not open yet.
    ///
    /// PORT of v2final `ServerDraftBody` (F5): an empty or whitespace-only body
    /// opens only when the server CONFIRMED it empty, or when the draft carries
    /// attachments (the body fetch stored it as an attachment-only message).
    static func editableBody(
        html: String?,
        bodyEmptyConfirmed: Bool,
        hasAttachments: Bool
    ) -> String? {
        let plain = html.map { EmailFilter.htmlToPlainText($0) } ?? ""
        if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return plain }
        return bodyEmptyConfirmed || hasAttachments ? "" : nil
    }

    /// The reply parent the other app's draft names through `In-Reply-To`, or nil.
    ///
    /// Same rule as `Draft.resolveReplyToHeader`'s Strategy 2: exactly ONE header in
    /// the account carries that Message-ID. The parent is then claimed only if the
    /// v80 stamps written from it will be accepted again at reopen
    /// (`Draft.acceptsReplyTargetHit`), so adoption never manufactures a reply whose
    /// Send is blocked from the start. No provable parent = an unthreaded draft.
    static func replyParent(for header: MessageHeader, db: Database) throws -> MessageHeader? {
        guard let raw = header.inReplyTo else { return nil }
        let rfc = EmailFilter.normalizeMessageId(raw)
        guard !rfc.isEmpty else { return nil }
        let candidates = try MessageHeader.fetchAll(
            db, sql: Draft.replyTargetLookupSQL, arguments: [header.accountId, rfc])
        guard candidates.count == 1 else { return nil }
        let parent = candidates[0]
        let accepted = try Draft.acceptsReplyTargetHit(
            expectedRfc: nil,
            expectedProviderMessageId: parent.messageId,
            expectedUidValidity: parent.observedUidValidity,
            hit: parent,
            hitIsEpochAddressed: Draft.replyTargetIsEpochAddressed(
                accountId: parent.accountId, db: db))
        return accepted ? parent : nil
    }

    /// The adopted row. Pure. Status `"pushed"`: the server copy IS this content,
    /// so nothing is pushed until the user edits.
    static func makeDraft(
        id: String,
        header: MessageHeader,
        address: LocallyAuthoredDraftOpenAuthority.Address,
        body: String,
        attachmentsDirName: String?,
        replyParent: MessageHeader?,
        instanceEpoch: String,
        now: Double
    ) -> Draft {
        var draft = Draft(
            id: id,
            accountId: header.accountId,
            toJSON: Draft.encodeStringArray(Draft.parseRecipients(header.to)),
            ccJSON: Draft.encodeStringArray(Draft.parseRecipients(header.cc)),
            bccJSON: Draft.encodeStringArray(Draft.parseRecipients(header.bcc)),
            subject: header.subject,
            body: body,
            replyToId: replyParent?.id,
            isForward: false,
            editHistoryJSON: nil,
            createdAt: now,
            updatedAt: now,
            serverDraftId: nil,
            serverPushStatus: "pushed",
            rfc822MessageId: header.rfc822MessageId,
            attachmentsDirName: attachmentsDirName)
        draft.instanceEpoch = instanceEpoch
        draft.replyToProviderMessageId = replyParent?.messageId
        draft.replyToUidValidity = replyParent?.observedUidValidity
        switch address {
        case .imap(let folderPath, let uidValidity, let uid):
            draft.serverDraftId = uid
            draft.serverDraftFolderPath = folderPath
            draft.serverDraftUidValidity = uidValidity
        case .gmail(let resourceId, _):
            draft.serverDraftId = resourceId
        case .outlook(let graphId):
            draft.serverDraftId = graphId
        case .placeholder, .demo:
            break
        }
        return draft
    }

    /// The insert, inside ONE write transaction: re-verify that `header` is still
    /// the server copy `address` names, refuse if any row already owns it, then
    /// insert. Returns the new draft id, or nil when nothing was inserted.
    static func insertAdoptedDraft(
        db: Database,
        header: MessageHeader,
        address: LocallyAuthoredDraftOpenAuthority.Address,
        runtimeKind: DraftRuntimeIdentityKind,
        body: String,
        attachmentsDirName: String?,
        now: Double = Date().timeIntervalSince1970
    ) throws -> String? {
        guard let (current, folder) = try currentDraftsHeader(db: db, captured: header),
              addressStillNames(address, header: current, folder: folder, runtimeKind: runtimeKind),
              try !addressIsOwned(address, accountId: current.accountId, db: db) else {
            return nil
        }
        let draft = makeDraft(
            id: draftKeyPrefix + UUID().uuidString,
            header: current,
            address: address,
            body: body,
            attachmentsDirName: attachmentsDirName,
            replyParent: try replyParent(for: current, db: db),
            instanceEpoch: UUID().uuidString,
            now: now)
        try DraftStore.applyAdoption(draft, db: db)
        return draft.id
    }

    // MARK: - Orchestration

    /// Fetch the server copy's body and attachments, then insert the adopted row.
    /// Returns without inserting when the header changed or a row already owns the
    /// address; the caller re-runs its normal resolver either way. THROWS when a
    /// read or fetch failed, which the loader shows as retryable.
    static func adopt(
        header: MessageHeader,
        address: LocallyAuthoredDraftOpenAuthority.Address,
        runtimeKind: DraftRuntimeIdentityKind
    ) async throws {
        // No-op when the body is already on the device.
        try await AccountManager.shared.fetchBody(for: header)

        let snapshot = try await AppDatabase.dbPool.read { db -> (MessageHeader, MessageBody)? in
            guard let (current, _) = try currentDraftsHeader(db: db, captured: header),
                  let body = try MessageBody.fetchOne(db, key: current.id) else {
                return nil
            }
            return (current, body)
        }
        guard let (current, messageBody) = snapshot else {
            throw AdoptionError.bodyUnavailable
        }
        // Top-level only: parts nested inside an attached `.eml` travel inside it.
        let attachmentInfos = messageBody.attachments.filter { $0.parentEmlSection == nil }
        guard let body = editableBody(
            html: messageBody.htmlContent,
            bodyEmptyConfirmed: current.bodyEmptyConfirmed,
            hasAttachments: !attachmentInfos.isEmpty) else {
            throw AdoptionError.bodyUnavailable
        }

        var attachments: [DraftAttachment] = []
        for info in attachmentInfos {
            let data = try await AccountManager.shared.fetchAttachment(
                for: current, section: info.section, encoding: info.encoding)
            attachments.append(DraftAttachment(
                filename: info.filename, mimeType: info.contentType, data: data))
        }
        let dirName: String? = attachments.isEmpty ? nil : DraftAttachmentStorage.newStagingDirName()
        if let dirName {
            do {
                try DraftAttachmentStorage.saveAttachments(attachments, dirName: dirName)
            } catch {
                DraftAttachmentStorage.deleteAttachments(dirName: dirName)
                throw error
            }
        }

        let insertedId: String?
        do {
            insertedId = try await AppDatabase.dbPool.write { db in
                try insertAdoptedDraft(
                    db: db, header: current, address: address, runtimeKind: runtimeKind,
                    body: body, attachmentsDirName: dirName)
            }
        } catch {
            if let dirName { DraftAttachmentStorage.deleteAttachments(dirName: dirName) }
            throw error
        }
        if insertedId == nil, let dirName {
            DraftAttachmentStorage.deleteAttachments(dirName: dirName)
        }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[DraftAdoption] header=\(DebugModeManager.escapedForLogLine(String(header.id.prefix(60)))) adopted=\(insertedId ?? "nil (header changed or already owned)") attachments=\(attachments.count)")
        }
    }
}
