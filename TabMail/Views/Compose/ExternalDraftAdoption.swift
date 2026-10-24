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
/// is no lease or lock — the v2final Outlook lease is not ported. Fourth ruling
/// (2026-10-21): LAST SAVE WINS. Nothing compares the server copy before a save; an
/// upload replaces whatever the server holds, so an edit another app made to the
/// same draft at the same time can be overwritten (#233, accepted). To never open a
/// stale copy, `refreshBeforeOpen` reloads a Gmail or Outlook row with no unsent
/// edits from the server every time it opens.
///
/// What still fails closed, because each one is an irreversible-wire hazard rather
/// than a concurrency question:
/// - the address must be exact (IMAP needs the header's observed UIDVALIDITY to
///   equal the Drafts folder's live epoch; a placeholder id is never an address);
/// - the header is re-verified inside the SAME write transaction that inserts the
///   row, so a re-key or renumbering during the network fetches adopts nothing;
/// - a body or attachment that could not be read is retryable, never "empty";
/// - a draft holding an attachment TabMail cannot carry is refused, never opened
///   without it (`DraftCopyUnsupportedAttachment`, #241).
enum ExternalDraftAdoption {
    /// Draft-key prefix for an adopted row. A random suffix, not a derived one: the
    /// insert transaction's owner check is what prevents a duplicate adoption.
    static let draftKeyPrefix = "adopted:"

    static func isAdoptedKey(_ draftId: String) -> Bool {
        draftId.hasPrefix(draftKeyPrefix)
    }

    /// The key of a new adopted row. An adopted reply's key ends with its parent's
    /// `{accountId}:{stableId}`, the tail a reply written in TabMail carries, so
    /// `Draft.resolveReplyToHeader`'s Strategy 2 finds the parent again after an
    /// IMAP folder move re-keys it (`Draft.replyKeyTail`).
    static func adoptedKey(replyParent: MessageHeader?) -> String {
        let key = draftKeyPrefix + UUID().uuidString
        guard let replyParent else { return key }
        return key + ":\(replyParent.accountId):\(replyParent.stableId)"
    }

    /// A read or fetch that must be retried before the draft can be adopted.
    enum AdoptionError: Error, Equatable {
        /// The body is not on the device yet, or reads as empty without the
        /// server having confirmed it empty. Opening it would let the first save
        /// overwrite the real server draft with nothing.
        case bodyUnavailable
        /// A copy that carries its attachment bytes lacks one of them.
        case attachmentUnavailable
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
    /// A copy with an HTML part is decoded from it (`EmailFilter.htmlToPlainText`
    /// keeping spacing as the page shows it; its line rules never add a blank
    /// line). A copy with only a text part
    /// (every draft TabMail uploads, and an Outlook copy, which Exchange returns as
    /// text) is used as is: line endings become `\n` and trailing line breaks are
    /// dropped, since MIME adds one, so a save and reopen never grows the body.
    /// Line breaks the user typed at the very end go too (accepted, IOS-DRAFT-023). A
    /// `format=flowed` text part arrives here already decoded by the provider's
    /// draft read (`EmailFilter.decodeFormatFlowed`, #238).
    ///
    /// PORT of v2final `ServerDraftBody` (F5): an empty or whitespace-only body
    /// opens only when the server CONFIRMED it empty, or when the draft carries
    /// attachments (the body fetch stored it as an attachment-only message). It
    /// then opens as written: whitespace the user typed is text like any other.
    static func editableBody(
        text: String?,
        html: String?,
        bodyEmptyConfirmed: Bool,
        hasAttachments: Bool
    ) -> String? {
        let plain: String
        if let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            plain = EmailFilter.htmlToPlainText(html, keepingSpacing: true)
        } else {
            var lines = (text ?? "")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            while lines.hasSuffix("\n") { lines.removeLast() }
            plain = lines
        }
        if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return plain }
        return bodyEmptyConfirmed || hasAttachments ? plain : nil
    }

    /// The reply parent the other app's draft names through `In-Reply-To`, or nil.
    ///
    /// Same rule as `Draft.resolveReplyToHeader`'s Strategy 2: exactly ONE header in
    /// the account carries that Message-ID. The adopted key then carries the parent's
    /// stable id (`adoptedKey`), so every reopen applies Strategy 2 again. The parent is then claimed only if the
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
        draft.replyToProviderMessageId = replyParent?.messageId
        draft.replyToUidValidity = replyParent?.observedUidValidity
        draft.serverCopyNamesParent = MessageIdentity.comparableRfc822Identity(content.inReplyTo) != nil
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
        let parent = try replyParent(for: current, db: db)
        let draft = makeDraft(
            id: adoptedKey(replyParent: parent),
            header: current,
            address: address,
            content: content,
            replyParent: parent,
            instanceEpoch: UUID().uuidString,
            now: now)
        try DraftStore.applyAdoption(draft, db: db)
        return draft.id
    }

    /// The reload, inside ONE write transaction: `decided` is the row the open read
    /// started from. Writes only if the row is still exactly that row — same
    /// generation, same conflict version, same status and same server address — so a
    /// newer save (another compose window, the agent) made while the server copy was
    /// being read always wins. Advances `pushAttemptVersion`, so
    /// an upload started before the reload retires at Stage A.
    ///
    /// A copy that replies to a different message than the row does (another app
    /// replaced the draft) is never merged into it, which would send the new text as
    /// a reply to the old parent: the row, which holds nothing the server lacks, is
    /// removed instead, and the next open adopts the copy whole.
    static func applyReload(
        db: Database,
        decided: Draft,
        content: ServerContent,
        now: Double = Date().timeIntervalSince1970
    ) throws -> ReloadWrite {
        guard var draft = try Draft.fetchOne(db, key: decided.id),
              draft.accountId == decided.accountId,
              draft.instanceEpoch == decided.instanceEpoch,
              draft.pushAttemptVersion == decided.pushAttemptVersion,
              draft.serverPushStatus == decided.serverPushStatus,
              draft.serverDraftId == decided.serverDraftId,
              draft.serverDraftFolderPath == decided.serverDraftFolderPath,
              draft.serverDraftUidValidity == decided.serverDraftUidValidity else {
            return .unchanged
        }
        let previousDirName = draft.attachmentsDirName
        if try repliesElsewhere(draft, copyInReplyTo: content.inReplyTo, db: db) {
            try draft.delete(db)
            return .removed(previousDirName: previousDirName)
        }
        draft.toJSON = Draft.encodeStringArray(RecipientEntry(content.to).draftEntries)
        draft.ccJSON = Draft.encodeStringArray(RecipientEntry(content.cc).draftEntries)
        draft.bccJSON = Draft.encodeStringArray(RecipientEntry(content.bcc).draftEntries)
        draft.subject = content.subject
        draft.body = content.body
        draft.attachmentsDirName = content.attachmentsDirName
        draft.updatedAt = now
        draft.serverPushStatus = "pushed"
        draft.serverCopyNamesParent = MessageIdentity.comparableRfc822Identity(content.inReplyTo) != nil
        draft.pushAttemptVersion += 1
        try draft.update(db)
        return .applied(previousDirName: previousDirName)
    }

    /// What `applyReload` wrote. `previousDirName` is the attachment directory the
    /// row no longer references once the write commits.
    enum ReloadWrite: Equatable {
        /// The row changed while the copy was read; nothing was written.
        case unchanged
        /// The row now holds the copy's content.
        case applied(previousDirName: String?)
        /// The copy replies to another message; the row was removed.
        case removed(previousDirName: String?)
    }

    /// Whether the server copy names, through `In-Reply-To`, a parent other than
    /// the one Send would reply to for `draft`. The row's parent is resolved as Send
    /// resolves it (`Draft.resolveReplyToHeader`, which follows a parent that moved),
    /// and a parent the row claims but cannot resolve is not taken as agreement: the
    /// row is clean, so removing it lets the next open adopt the copy whole. A copy
    /// naming no parent replies elsewhere only when the copy the row last uploaded or
    /// read named one (`Draft.serverCopyNamesParent`, #278): another app put a
    /// standalone message in the draft's place. A row with no record keeps its parent.
    /// A forward, or a row claiming no parent, is not compared; re-adoption of a copy
    /// whose parent the device lacks therefore claims none and stays put.
    static func repliesElsewhere(_ draft: Draft, copyInReplyTo: String?, db: Database) throws -> Bool {
        guard !draft.isForward,
              draft.replyToId != nil || Draft.replyKeyTail(draftKey: draft.id, isForward: false) != nil else {
            return false
        }
        guard let copyParent = MessageIdentity.comparableRfc822Identity(copyInReplyTo) else {
            return draft.serverCopyNamesParent == true
        }
        let parent = try Draft.resolveReplyToHeader(
            draftKey: draft.id, replyToId: draft.replyToId, isForward: false,
            expectedProviderMessageId: draft.replyToProviderMessageId,
            expectedUidValidity: draft.replyToUidValidity, db: db)
        guard let rowParent = MessageIdentity.comparableRfc822Identity(parent?.rfc822MessageId) else { return true }
        return rowParent != copyParent
    }

    // MARK: - Orchestration

    /// A server copy's editable content, read from ONE `fetchDraftCopy` result, so
    /// subject, recipients, body and attachments all come from the same version.
    /// Attachments are staged in a new directory, which the caller owns from here on.
    struct ServerContent {
        let subject: String
        let to: String
        let cc: String
        let bcc: String
        let body: String
        let attachmentsDirName: String?
        let attachmentCount: Int
        /// The copy's `In-Reply-To`, as the server returned it.
        var inReplyTo: String? = nil
    }

    /// The file name an adopted inline image is carried under. The body is edited
    /// as plain text, so an inline image travels on as an ordinary attachment.
    static func inlineImageFilename(_ image: InlineImage, index: Int) -> String {
        let ext = UTType(mimeType: image.contentType)?.preferredFilenameExtension ?? "bin"
        return "image\(index + 1).\(ext)"
    }

    /// A server copy's editable content with its attachment bytes in memory: the
    /// network half, which `refreshBeforeOpen` bounds by its timeout. Nothing is
    /// written to disk until `stage`, so a read abandoned at the timeout leaves
    /// nothing behind.
    struct ReadCopy: Sendable {
        let subject: String
        let to: String
        let cc: String
        let bcc: String
        let body: String
        let attachments: [DraftAttachment]
        let inReplyTo: String?
    }

    private static func read(
        _ copy: FullMessageInfo,
        accountId: String,
        identity: DraftDeleteIdentity,
        bodyEmptyConfirmed: Bool
    ) async throws -> ReadCopy {
        // Top-level only: parts nested inside an attached `.eml` travel inside it.
        let attachmentInfos = copy.attachments.filter { $0.parentEmlSection == nil }
        // A file this device cannot store under its own name is never carried, and
        // never fetched first (#241).
        guard attachmentInfos.allSatisfy({ AttachmentFilename.isSafeFileComponent($0.filename) }) else {
            throw DraftCopyUnsupportedAttachment()
        }
        // A body part this successful read returned, even an empty one, IS the
        // server's word that the draft is empty (another app cleared it). Only a copy
        // with no body part at all stays unopenable, so a body the reader failed to
        // extract can never blank the draft.
        let bodyReturned = copy.htmlBody != nil || copy.textBody != nil
        guard let body = editableBody(
            text: copy.textBody,
            html: copy.htmlBody,
            bodyEmptyConfirmed: bodyEmptyConfirmed || bodyReturned,
            hasAttachments: !attachmentInfos.isEmpty || !copy.inlineImages.isEmpty) else {
            throw AdoptionError.bodyUnavailable
        }

        // Attachment ids belong to the message the copy was read from (Gmail
        // replaces that message on every save), so they are fetched by its id. A
        // file whose bytes the copy already carries (every IMAP file, read under its
        // proven UIDVALIDITY; every Gmail file, read whole) is never fetched, and an
        // IMAP file is never fetched again by UID alone.
        let folderPath: String
        if case .imap(let folder, _, _) = identity { folderPath = folder } else { folderPath = "" }
        var attachments: [DraftAttachment] = []
        for info in attachmentInfos {
            let data: Data
            if let bytes = copy.attachmentData?[info.section] {
                data = bytes
            } else if case .imap = identity {
                throw AdoptionError.attachmentUnavailable
            } else {
                data = try await AccountManager.shared.fetchAttachment(
                    accountId: accountId, messageId: copy.header.messageId, folderPath: folderPath,
                    section: info.section, encoding: info.encoding)
            }
            attachments.append(DraftAttachment(
                filename: info.filename, mimeType: info.contentType, data: data))
        }
        for (index, image) in copy.inlineImages.enumerated() {
            attachments.append(DraftAttachment(
                filename: inlineImageFilename(image, index: index),
                mimeType: image.contentType, data: image.data))
        }
        return ReadCopy(
            subject: copy.header.subject,
            to: copy.header.to, cc: copy.header.cc, bcc: copy.header.bcc,
            body: body, attachments: attachments, inReplyTo: copy.header.inReplyTo)
    }

    /// Writes a read copy's attachments to a new staging directory.
    private static func stage(_ read: ReadCopy) throws -> ServerContent {
        let dirName: String? = read.attachments.isEmpty ? nil : DraftAttachmentStorage.newStagingDirName()
        if let dirName {
            do {
                try DraftAttachmentStorage.saveAttachments(read.attachments, dirName: dirName)
            } catch {
                DraftAttachmentStorage.deleteAttachments(dirName: dirName)
                throw error
            }
        }
        return ServerContent(
            subject: read.subject, to: read.to, cc: read.cc, bcc: read.bcc, body: read.body,
            attachmentsDirName: dirName, attachmentCount: read.attachments.count,
            inReplyTo: read.inReplyTo)
    }

    /// Read the server copy at `address`, then insert the adopted row.
    /// Returns without inserting when the server no longer has the draft, the
    /// header changed, or a row already owns the address; the caller re-runs its
    /// normal resolver either way. THROWS when a read or fetch failed, which the
    /// loader shows as retryable, or `DraftCopyUnsupportedAttachment`, which it
    /// shows as final.
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
        // Gmail replaces a draft's message on every save. A copy read from another
        // message than the listed one is a newer version whose headers (its reply
        // parent among them) the list has not seen yet: not adopted, like a changed
        // header; the next sync lists it.
        if case .gmail(_, let containedMessageId) = address, copy.header.messageId != containedMessageId {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DraftAdoption] header=\(DebugModeManager.escapedForLogLine(String(header.id.prefix(60)))) server copy is a newer message — not adopted")
            }
            return
        }
        let content = try stage(try await read(
            copy, accountId: header.accountId, identity: identity,
            bodyEmptyConfirmed: header.bodyEmptyConfirmed))
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

    /// Whether opening a row reloads its server copy first. Pure.
    ///
    /// Only a Gmail or Outlook row with no unsent edits (`"pushed"`): it holds
    /// nothing the server lacks, and another app can edit those drafts in place. A
    /// row with unsent edits (`"dirty"`, `"pushing"`, or never uploaded) opens as it
    /// is and its next upload replaces the server copy (last save wins, #233). An
    /// IMAP message never changes in place, so another app's edit is a new message
    /// under a new UID, opened by adoption; a demo draft lives only on this device.
    static func reloadsBeforeOpen(serverPushStatus: String?, identity: DraftDeleteIdentity) -> Bool {
        guard serverPushStatus == "pushed" else { return false }
        switch identity {
        case .gmail, .outlook:
            return true
        case .gmailContainedMessage, .imap, .demo:
            return false
        }
    }

    /// What `refreshBeforeOpen` found: open the row, or refuse it.
    enum OpenCheck: Equatable {
        case open
        case unsupportedAttachment
        /// Another app replaced the draft with a reply to another message; the
        /// local row is gone and the next open adopts the new one.
        case replacedElsewhere
    }

    /// #217 (ADR-IOS-091): bring a saved draft up to date before it opens. Every
    /// open of a persisted draft runs this (`ComposeView.loadDraftOrPrepopulate`),
    /// whichever screen opened it.
    ///
    /// A row `reloadsBeforeOpen` selects takes the server's version, with no
    /// comparison (owner ruling 2026-10-21, last save wins). The whole read,
    /// attachments included, runs under `ExternalDraftOpenConfig.reloadTimeoutSeconds`.
    /// Anything that stops it (offline, a timeout, a gone copy, a part that could not
    /// be read, a row that changed meanwhile) opens the row as it is. A copy holding
    /// an attachment TabMail cannot carry returns `.unsupportedAttachment`: the draft
    /// is then not opened for editing, since its next save would replace the
    /// server's version with a stale one (#241).
    /// `willReadServer` runs just before the network read, so a draft that needs
    /// none opens without a loading cover.
    @discardableResult
    static func refreshBeforeOpen(
        draftId: String,
        willReadServer: @MainActor () -> Void
    ) async -> OpenCheck {
        do {
            guard let row = try await AppDatabase.dbPool.read({ db in
                      try Draft.fetchOne(db, key: draftId)
                  }),
                  let provider = await AccountManager.shared.provider(accountId: row.accountId),
                  let identity = DraftStore.priorIdentity(
                      for: row, runtimeKind: AccountManager.draftRuntimeIdentityKind(for: provider)),
                  reloadsBeforeOpen(serverPushStatus: row.serverPushStatus, identity: identity) else {
                return .open
            }
            await willReadServer()
            let accountId = row.accountId
            let readCopy: ReadCopy? = try await withTimeout(
                seconds: ExternalDraftOpenConfig.reloadTimeoutSeconds
            ) {
                guard let copy = try await provider.fetchDraftCopy(identity: identity) else { return nil }
                return try await read(
                    copy, accountId: accountId, identity: identity, bodyEmptyConfirmed: false)
            }
            guard let readCopy else { return .open }
            let content = try stage(readCopy)
            let dirName = content.attachmentsDirName
            let written: ReloadWrite
            do {
                written = try await AppDatabase.dbPool.write { db in
                    try applyReload(db: db, decided: row, content: content)
                }
            } catch {
                if let dirName { DraftAttachmentStorage.deleteAttachments(dirName: dirName) }
                throw error
            }
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DraftAdoption] reload before open draft=\(draftId) write=\(written) attachments=\(content.attachmentCount)")
            }
            switch written {
            case .applied(let oldDir):
                // Committed: the old directory is no longer referenced.
                if let oldDir, oldDir != dirName { DraftAttachmentStorage.deleteAttachments(dirName: oldDir) }
                return .open
            case .unchanged:
                if let dirName { DraftAttachmentStorage.deleteAttachments(dirName: dirName) }
                return .open
            case .removed(let oldDir):
                if let dirName { DraftAttachmentStorage.deleteAttachments(dirName: dirName) }
                if let oldDir { DraftAttachmentStorage.deleteAttachments(dirName: oldDir) }
                return .replacedElsewhere
            }
        } catch is DraftCopyUnsupportedAttachment {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DraftAdoption] Open-time reload for draft=\(draftId) refused: an attachment TabMail cannot carry")
            }
            return .unsupportedAttachment
        } catch {
            if DebugModeManager.isLoggingEnabled() {
                BackgroundSyncLogger.logDebug("[DraftAdoption] Open-time reload for draft=\(draftId) did not complete (\(error)) — opening the local copy")
            }
            return .open
        }
    }
}

enum ExternalDraftOpenConfig {
    /// How long opening a draft waits for its server copy before opening the local
    /// copy instead, so a slow or offline read never blocks the user.
    static let reloadTimeoutSeconds: TimeInterval = 8
}
