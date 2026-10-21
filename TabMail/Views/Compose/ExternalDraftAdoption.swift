/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import UniformTypeIdentifiers

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
/// OWNER RULING (2026-10-17): take over the draft whichever client wrote it. There
/// is no lease or lock — the v2final Outlook lease is not ported. Second ruling, same
/// day: never keep a stale local copy, and ask before overwriting a server copy that
/// another app changed. So every adopted or reloaded row keeps a copy of the server
/// text its content came from (`Draft.serverDraftText`, `DraftServerCheck`), and
/// `refreshBeforeOpen` reloads a row with no unsent edits whose server copy no
/// longer matches it.
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

    /// The provider identity that reads the server copy at `address`.
    static func identity(for address: LocallyAuthoredDraftOpenAuthority.Address) -> DraftDeleteIdentity? {
        switch address {
        case .imap(let folderPath, let uidValidity, let uid):
            guard let uid = Int(uid), uid > 0 else { return nil }
            return .imap(folder: folderPath, uidValidity: uidValidity, uid: uid)
        case .gmail(let resourceId, _):
            return .gmail(resourceId: resourceId)
        case .outlook(let graphId):
            return .outlook(graphId: graphId)
        case .placeholder, .demo:
            return nil
        }
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
        content: ServerContent,
        replyParent: MessageHeader?,
        instanceEpoch: String,
        now: Double
    ) -> Draft {
        var draft = Draft(
            id: id,
            accountId: header.accountId,
            toJSON: Draft.encodeStringArray(RecipientEntry(content.to).draftEntries),
            ccJSON: Draft.encodeStringArray(RecipientEntry(content.cc).draftEntries),
            bccJSON: Draft.encodeStringArray(RecipientEntry(content.bcc).draftEntries),
            subject: content.subject,
            body: content.body,
            replyToId: replyParent?.id,
            isForward: false,
            editHistoryJSON: nil,
            createdAt: now,
            updatedAt: now,
            serverDraftId: nil,
            serverPushStatus: "pushed",
            rfc822MessageId: header.rfc822MessageId,
            attachmentsDirName: content.attachmentsDirName)
        draft.instanceEpoch = instanceEpoch
        draft.serverDraftText = content.serverText
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
        content: ServerContent,
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
            content: content,
            replyParent: try replyParent(for: current, db: db),
            instanceEpoch: UUID().uuidString,
            now: now)
        try DraftStore.applyAdoption(draft, db: db)
        return draft.id
    }

    /// The reload, inside ONE write transaction: `decided` is the row the open
    /// check compared. Writes only if the row is still exactly that row — same
    /// generation, same conflict version, same status and same server address — so a
    /// newer save (another compose window, the agent) or a "Save as new" made while
    /// the server copy was being read always wins. Advances `pushAttemptVersion`, so
    /// an upload started before the reload retires at Stage A.
    /// Returns the attachment directory the row used before (to delete after
    /// commit), `.some(nil)` when it had none, or nil when nothing was written.
    static func applyReload(
        db: Database,
        decided: Draft,
        content: ServerContent,
        now: Double = Date().timeIntervalSince1970
    ) throws -> String?? {
        guard var draft = try Draft.fetchOne(db, key: decided.id),
              draft.accountId == decided.accountId,
              draft.instanceEpoch == decided.instanceEpoch,
              draft.pushAttemptVersion == decided.pushAttemptVersion,
              draft.serverPushStatus == decided.serverPushStatus,
              draft.serverDraftId == decided.serverDraftId,
              draft.serverDraftFolderPath == decided.serverDraftFolderPath,
              draft.serverDraftUidValidity == decided.serverDraftUidValidity else {
            return nil
        }
        let previousDirName = draft.attachmentsDirName
        draft.toJSON = Draft.encodeStringArray(RecipientEntry(content.to).draftEntries)
        draft.ccJSON = Draft.encodeStringArray(RecipientEntry(content.cc).draftEntries)
        draft.bccJSON = Draft.encodeStringArray(RecipientEntry(content.bcc).draftEntries)
        draft.subject = content.subject
        draft.body = content.body
        draft.attachmentsDirName = content.attachmentsDirName
        draft.updatedAt = now
        draft.serverDraftText = content.serverText
        draft.serverPushStatus = "pushed"
        draft.pushAttemptVersion += 1
        try draft.update(db)
        return .some(previousDirName)
    }

    // MARK: - Orchestration

    /// A server copy's editable content, read from ONE `fetchDraftCopy` result, so
    /// subject, recipients, body and attachments all come from the same version.
    /// Attachments are staged in a new directory, which the caller owns from here on.
    /// The user's answer when the server copy of a draft with unsent edits changed.
    enum ServerChangeChoice: Sendable {
        /// Keep this device's edits; the next upload replaces the other version.
        case overwrite
        /// Take the other version; this device's edits are dropped.
        case reload
        /// Keep both: this device's edits become a new server draft.
        case saveAsNew
    }

    struct ServerContent {
        let subject: String
        let to: String
        let cc: String
        let bcc: String
        let body: String
        /// The copy's text (`DraftServerText`), kept as the row's copy.
        let serverText: String
        let attachmentsDirName: String?
        let attachmentCount: Int
    }

    /// The file name an adopted inline image is carried under. The body is edited
    /// as plain text, so an inline image travels on as an ordinary attachment.
    /// `DraftServerText` names inline images the same way, so the copy this device
    /// uploads after adopting them compares equal to the original.
    static func inlineImageFilename(_ image: InlineImage, index: Int) -> String {
        let ext = UTType(mimeType: image.contentType)?.preferredFilenameExtension ?? "bin"
        return "image\(index + 1).\(ext)"
    }

    private static func content(
        of copy: FullMessageInfo,
        accountId: String,
        identity: DraftDeleteIdentity,
        bodyEmptyConfirmed: Bool
    ) async throws -> ServerContent {
        // Top-level only: parts nested inside an attached `.eml` travel inside it.
        let attachmentInfos = copy.attachments.filter { $0.parentEmlSection == nil }
        let html: String?
        if let htmlBody = copy.htmlBody, !htmlBody.isEmpty {
            html = htmlBody
        } else {
            html = copy.textBody.map(EmailFilter.plainTextToHTML)
        }
        guard let body = editableBody(
            html: html,
            bodyEmptyConfirmed: bodyEmptyConfirmed,
            hasAttachments: !attachmentInfos.isEmpty || !copy.inlineImages.isEmpty) else {
            throw AdoptionError.bodyUnavailable
        }

        // Attachment ids belong to the message the copy was read from (Gmail
        // replaces that message on every save), so they are fetched by its id.
        let folderPath: String
        if case .imap(let folder, _, _) = identity { folderPath = folder } else { folderPath = "" }
        var attachments: [DraftAttachment] = []
        for info in attachmentInfos {
            let data = try await AccountManager.shared.fetchAttachment(
                accountId: accountId, messageId: copy.header.messageId, folderPath: folderPath,
                section: info.section, encoding: info.encoding)
            attachments.append(DraftAttachment(
                filename: info.filename, mimeType: info.contentType, data: data))
        }
        for (index, image) in copy.inlineImages.enumerated() {
            attachments.append(DraftAttachment(
                filename: inlineImageFilename(image, index: index),
                mimeType: image.contentType, data: image.data))
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
        return ServerContent(
            subject: copy.header.subject, to: copy.header.to, cc: copy.header.cc, bcc: copy.header.bcc,
            body: body, serverText: DraftServerText.of(copy),
            attachmentsDirName: dirName, attachmentCount: attachments.count)
    }

    /// Read the server copy at `address`, then insert the adopted row, keeping the
    /// copy's text as the row's copy of the server text.
    /// Returns without inserting when the server no longer has the draft, the
    /// header changed, or a row already owns the address; the caller re-runs its
    /// normal resolver either way. THROWS when a read or fetch failed, which the
    /// loader shows as retryable.
    static func adopt(
        header: MessageHeader,
        address: LocallyAuthoredDraftOpenAuthority.Address,
        runtimeKind: DraftRuntimeIdentityKind
    ) async throws {
        guard let identity = identity(for: address) else { return }
        guard let provider = await AccountManager.shared.provider(accountId: header.accountId) else {
            throw ProviderError.notConnected
        }
        guard let copy = try await provider.fetchDraftCopy(identity: identity) else {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DraftAdoption] header=\(DebugModeManager.escapedForLogLine(String(header.id.prefix(60)))) server copy is gone — not adopted")
            }
            return
        }
        let content = try await content(
            of: copy, accountId: header.accountId, identity: identity,
            bodyEmptyConfirmed: header.bodyEmptyConfirmed)
        let dirName = content.attachmentsDirName
        let insertedId: String?
        do {
            insertedId = try await AppDatabase.dbPool.write { db in
                try insertAdoptedDraft(
                    db: db, header: header, address: address, runtimeKind: runtimeKind,
                    content: content)
            }
        } catch {
            if let dirName { DraftAttachmentStorage.deleteAttachments(dirName: dirName) }
            throw error
        }
        if insertedId == nil, let dirName {
            DraftAttachmentStorage.deleteAttachments(dirName: dirName)
        }
        if DebugModeManager.isLoggingEnabled() {
            BackgroundSyncLogger.logDebug("[DraftAdoption] header=\(DebugModeManager.escapedForLogLine(String(header.id.prefix(60)))) adopted=\(insertedId ?? "nil (header changed or already owned)") attachments=\(content.attachmentCount)")
        }
    }

    /// #217 (ADR-IOS-091): bring a saved draft up to date before it opens. Every
    /// open of a persisted draft runs this (`ComposeView.loadDraftOrPrepopulate`),
    /// whichever screen opened it.
    ///
    /// When the server copy changed (owner rulings 2026-10-17):
    /// - a row with no unsent edits (`"pushed"`) holds nothing the server lacks, so
    ///   it simply takes the server's version;
    /// - a row WITH unsent edits (saved offline, or an upload that refused the
    ///   changed copy) asks the user first: `askAboutUnsentEdits` returns Overwrite,
    ///   Reload or Save as new, or nil to open the edits as they are (Save asks
    ///   again).
    /// Anything that stops the check — offline, a gone copy, a body that could not
    /// be read, a row that changed meanwhile — opens the row as it is: Save and the
    /// upload check again, so nothing here can overwrite either side.
    /// `willReadServer` runs just before the network read, so a draft that needs
    /// none (a new compose, a draft never uploaded) opens without a loading cover.
    static func refreshBeforeOpen(
        draftId: String,
        willReadServer: @MainActor () -> Void,
        askAboutUnsentEdits: @MainActor () async -> ServerChangeChoice?
    ) async {
        do {
            guard let row = try await AppDatabase.dbPool.read({ db in
                      try Draft.fetchOne(db, key: draftId)
                  }),
                  let provider = await AccountManager.shared.provider(accountId: row.accountId),
                  let identity = DraftStore.priorIdentity(
                      for: row, runtimeKind: AccountManager.draftRuntimeIdentityKind(for: provider)) else {
                return
            }
            await willReadServer()
            let copy = try await withTimeout(seconds: DraftServerCheckConfig.checkTimeoutSeconds) {
                try await provider.fetchDraftCopy(identity: identity)
            }
            guard let copy,
                  case .changed(let serverText) = DraftServerCheck.compare(
                      base: row.serverDraftText, current: DraftServerText.of(copy)) else {
                return
            }
            if row.serverPushStatus != "pushed" {
                let epoch = row.instanceEpoch ?? ""
                switch await askAboutUnsentEdits() {
                case nil:
                    return
                case .overwrite?:
                    _ = try await AppDatabase.dbPool.write { db in
                        try DraftStore.rebaseOnServerText(
                            draftId: draftId, expectedInstanceEpoch: epoch, serverText: serverText, db: db)
                    }
                    return
                case .saveAsNew?:
                    _ = try await AppDatabase.dbPool.write { db in
                        try DraftStore.detachFromServerCopy(
                            draftId: draftId, expectedInstanceEpoch: epoch, db: db)
                    }
                    return
                case .reload?:
                    break
                }
            }
            let content = try await content(
                of: copy, accountId: row.accountId, identity: identity, bodyEmptyConfirmed: false)
            let dirName = content.attachmentsDirName
            let previousDir: String??
            do {
                previousDir = try await AppDatabase.dbPool.write { db in
                    try applyReload(db: db, decided: row, content: content)
                }
            } catch {
                if let dirName { DraftAttachmentStorage.deleteAttachments(dirName: dirName) }
                throw error
            }
            switch previousDir {
            case .some(let oldDir):
                // Committed: the old directory is no longer referenced.
                if let oldDir, oldDir != dirName { DraftAttachmentStorage.deleteAttachments(dirName: oldDir) }
            case .none:
                if let dirName { DraftAttachmentStorage.deleteAttachments(dirName: dirName) }
            }
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DraftAdoption] reload before open draft=\(draftId) applied=\(previousDir != nil) attachments=\(content.attachmentCount)")
            }
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DraftAdoption] Open-time server check for draft=\(draftId) did not complete (\(error)) — opening the local copy; Save and the upload check again")
            }
        }
    }
}
