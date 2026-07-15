/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Test Helpers

/// Builds a realistic MessageHeaderInfo with sensible defaults.
private func makeHeaderInfo(
    messageId: String = "100",
    rfc822MessageId: String? = "<msg-100@example.com>",
    inReplyTo: String? = nil,
    references: [String] = [],
    threadId: String? = nil,
    subject: String = "Test Subject",
    from: String = "Alice Smith",
    fromAddress: String = "alice@example.com",
    to: String = "bob@example.com",
    cc: String = "",
    bcc: String = "",
    replyTo: String? = nil,
    date: Date = TestFixtureDate.anchor,
    snippet: String = "Test snippet",
    isRead: Bool = false,
    isFlagged: Bool = false,
    hasAttachments: Bool = false,
    isReplied: Bool = false,
    isForwarded: Bool = false,
    actionTag: ActionTag? = nil,
    userLabelIds: [String] = [],
    userLabelIdsAreAuthoritative: Bool = false
) -> MessageHeaderInfo {
    MessageHeaderInfo(
        messageId: messageId,
        rfc822MessageId: rfc822MessageId,
        inReplyTo: inReplyTo,
        references: references,
        threadId: threadId,
        subject: subject,
        from: from,
        fromAddress: fromAddress,
        to: to,
        cc: cc,
        bcc: bcc,
        replyTo: replyTo,
        date: date,
        snippet: snippet,
        isRead: isRead,
        isFlagged: isFlagged,
        hasAttachments: hasAttachments,
        isReplied: isReplied,
        isForwarded: isForwarded,
        actionTag: actionTag,
        userLabelIds: userLabelIds,
        userLabelIdsAreAuthoritative: userLabelIdsAreAuthoritative
    )
}

// MARK: - Suite: field-scoped intent protection (real runSyncMessages)

/// Drives the real full-sync upsert. Read, flagged, and action-tag are three
/// independently mutable intentions: protecting one must never discard a
/// concurrent server change to either of the others before the sync cursor moves.
@Suite("runSyncMessages — field-scoped intent protection", .serialized, .processGlobalState)
struct RunSyncFieldScopedIntentProtectionTests {
    private enum ProtectedField: Equatable {
        case read
        case flagged
        case actionTag

        var operationType: OperationType {
            switch self {
            case .read: .markRead
            case .flagged: .markFlagged
            case .actionTag: .setTag
            }
        }

        var recentField: MessageIdentity.RecentlyCompletedField {
            switch self {
            case .read: .read
            case .flagged: .flagged
            case .actionTag: .actionTag
            }
        }

        var recentValue: MessageIdentity.RecentlyCompletedFieldValue {
            switch self {
            case .read: .read(true)
            case .flagged: .flagged(true)
            case .actionTag: .actionTag(ActionTag.reply.rawValue)
            }
        }
    }

    private func verifyProtection(
        _ protectedField: ProtectedField,
        source: String,
        recentlyCompletedOnly: Bool,
        fieldScope: MessageFieldScope = .folder,
        expectedProtection: Bool = true,
        pushFolderPath: String? = nil,
        recentAccountId: String? = nil,
        includeLegacyBareIdentity: Bool = false,
        includeConflictingRecentValueAtSameExpiry: Bool = false,
        pendingOperationType: OperationType? = nil,
        pendingStatus: PendingStatus = .queued
    ) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: dir.appendingPathComponent("test.sqlite").path,
            configuration: configuration
        )
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: dir)
        }
        try AppDatabase.runMigrations(on: pool)

        let accountId = "full-field-\(UUID().uuidString)"
        let folderPath = "Folder_D"
        let providerId = "provider-current-\(UUID().uuidString)"
        let rfc822 = "field-protection-\(UUID().uuidString)@example.com"
        let folder = Folder(
            name: "Folder D",
            path: folderPath,
            role: .inbox,
            accountId: accountId
        )
        var account = Account(
            emailAddress: "recipient@example.com",
            displayName: "Recipient",
            provider: .gmail
        )
        account.id = accountId
        var header = MessageHeader(
            messageId: providerId,
            subject: "Field protection",
            from: "Sender",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            date: Date().addingTimeInterval(-60),
            snippet: "local",
            folderId: folder.id,
            accountId: accountId,
            folderPath: folder.path,
            isInInbox: true
        )
        header.rfc822MessageId = "<\(rfc822)>"
        header.headerComplete = true
        header.isRead = true
        header.isFlagged = true
        header.actionTag = .reply
        header.tagSortOrder = ActionTag.reply.sortOrder

        var operation = PendingOperation(
            type: pendingOperationType ?? protectedField.operationType,
            messageIds: [rfc822],
            accountId: accountId,
            folderPath: source,
            tagValue: protectedField == .actionTag ? ActionTag.reply.rawValue : nil
        )
        operation.status = pendingStatus.rawValue

        let persistedAccount = account
        let persistedHeader = header
        let persistedOperation = operation
        try await pool.write { db in
            try persistedAccount.insert(db)
            try folder.insert(db)
            try persistedHeader.insert(db)
            if !recentlyCompletedOnly {
                try persistedOperation.insert(db)
            }
        }

        let remote = makeHeaderInfo(
            messageId: providerId,
            rfc822MessageId: persistedHeader.rfc822MessageId,
            subject: persistedHeader.subject,
            from: persistedHeader.from,
            fromAddress: persistedHeader.fromAddress,
            to: persistedHeader.to,
            date: persistedHeader.date,
            snippet: "remote",
            isRead: false,
            isFlagged: false,
            actionTag: .archive
        )
        let effectiveFieldScope = fieldScope
        let base = MockEmailProvider(messageFieldScope: effectiveFieldScope)
        await base.setFetchMessagesResult([remote])
        let provider: any EmailProvider = base

        var recent: [String: Date] = [:]
        if recentlyCompletedOnly {
            let expiry = Date().addingTimeInterval(60)
            let identityOwner = recentAccountId ?? accountId
            let identities = [providerId, persistedHeader.rfc822MessageId].compactMap { $0 }
            for identity in identities {
                if includeLegacyBareIdentity {
                    recent[identity] = expiry
                }
                switch effectiveFieldScope {
                case .account:
                    recent[MessageIdentity.recentlyCompletedAccountKey(
                        accountId: identityOwner,
                        messageId: identity
                    )] = expiry
                    recent[MessageIdentity.recentlyCompletedFieldKey(
                        accountId: identityOwner,
                        messageId: identity,
                        field: protectedField.recentField
                    )] = expiry
                    recent[MessageIdentity.recentlyCompletedFieldValueKey(
                        accountId: identityOwner,
                        messageId: identity,
                        value: protectedField.recentValue
                    )] = expiry
                    if includeConflictingRecentValueAtSameExpiry {
                        recent[MessageIdentity.recentlyCompletedFieldValueKey(
                            accountId: identityOwner,
                            messageId: identity,
                            value: .actionTag(nil)
                        )] = expiry
                    }
                case .folder:
                    recent[MessageIdentity.headerId(
                        accountId: identityOwner,
                        folderPath: source,
                        messageId: identity
                    )] = expiry
                    recent[MessageIdentity.recentlyCompletedFieldKey(
                        accountId: identityOwner,
                        folderPath: source,
                        messageId: identity,
                        field: protectedField.recentField
                    )] = expiry
                    recent[MessageIdentity.recentlyCompletedFieldValueKey(
                        accountId: identityOwner,
                        folderPath: source,
                        messageId: identity,
                        value: protectedField.recentValue
                    )] = expiry
                    if includeConflictingRecentValueAtSameExpiry {
                        recent[MessageIdentity.recentlyCompletedFieldValueKey(
                            accountId: identityOwner,
                            folderPath: source,
                            messageId: identity,
                            value: .actionTag(nil)
                        )] = expiry
                    }
                }
            }
        }
        if let pushFolderPath {
            let expiry = Date().addingTimeInterval(
                SyncConfig.pushMergeStaleProtectionTTLSeconds
            )
            let identities = [providerId, persistedHeader.rfc822MessageId].compactMap { $0 }
            for identity in identities {
                recent[MessageIdentity.recentlyCompletedPushKey(
                    accountId: accountId,
                    folderPath: pushFolderPath,
                    messageId: identity
                )] = expiry
            }
        }

        _ = try await SyncEngine.runSyncMessages(
            for: folder,
            provider: provider,
            limit: 50,
            dbPool: PrioritizedDatabase(pool: pool),
            recentlyCompleted: recent
        )

        let refreshed = try #require(try await pool.read { db in
            try MessageHeader.fetchOne(db, key: persistedHeader.id)
        })
        let pushProtectsCurrentRow = pushFolderPath == folderPath
        let protectsRead = pushProtectsCurrentRow
            || (expectedProtection && protectedField == .read)
        let protectsFlagged = pushProtectsCurrentRow
            || (expectedProtection && protectedField == .flagged)
        let protectsActionTag = pushProtectsCurrentRow
            || (expectedProtection && protectedField == .actionTag)
        #expect(refreshed.isRead == protectsRead)
        #expect(refreshed.isFlagged == protectsFlagged)
        #expect(refreshed.actionTag == (protectsActionTag ? .reply : .archive))
        #expect(refreshed.tagSortOrder == refreshed.actionTag?.sortOrder ?? 99)
    }

    @Test("pending markRead protects read while remote flagged and actionTag still apply")
    func pendingReadProtectsOnlyRead() async throws {
        try await verifyProtection(
            .read,
            source: "Folder_D",
            recentlyCompletedOnly: false
        )
    }

    @Test("pending markFlagged protects flagged while remote read and actionTag still apply")
    func pendingFlaggedProtectsOnlyFlagged() async throws {
        try await verifyProtection(
            .flagged,
            source: "Folder_D",
            recentlyCompletedOnly: false
        )
    }

    @Test("legacy pending actionTag row does not protect local-only tag")
    func pendingActionTagProtectsOnlyActionTag() async throws {
        try await verifyProtection(
            .actionTag,
            source: "Folder_D",
            recentlyCompletedOnly: false,
            expectedProtection: false
        )
    }

    @Test("cancelled markRead supplies no value authority")
    func cancelledReadDoesNotProtect() async throws {
        try await verifyProtection(
            .read,
            source: "Folder_D",
            recentlyCompletedOnly: false,
            expectedProtection: false,
            pendingStatus: .cancelled
        )
    }

    @Test("cancelled generic operation does not skip the full upsert")
    func cancelledGenericDoesNotProtect() async throws {
        try await verifyProtection(
            .read,
            source: "Folder_D",
            recentlyCompletedOnly: false,
            expectedProtection: false,
            pendingOperationType: .markReplied,
            pendingStatus: .cancelled
        )
    }

    @Test("recent markRead key protects read while remote flagged and actionTag still apply")
    func recentReadProtectsOnlyRead() async throws {
        try await verifyProtection(
            .read,
            source: "Folder_D",
            recentlyCompletedOnly: true
        )
    }

    @Test("recent markFlagged key protects flagged while remote read and actionTag still apply")
    func recentFlaggedProtectsOnlyFlagged() async throws {
        try await verifyProtection(
            .flagged,
            source: "Folder_D",
            recentlyCompletedOnly: true
        )
    }

    @Test("recent actionTag key protects tag while remote read and flagged still apply")
    func recentActionTagProtectsOnlyActionTag() async throws {
        try await verifyProtection(
            .actionTag,
            source: "Folder_D",
            recentlyCompletedOnly: true
        )
    }

    @Test("equal-expiry opposite exact receipts are ambiguous while coarse protection remains")
    func tiedRecentValuesDoNotChooseAnArbitraryWinner() async throws {
        try await verifyProtection(
            .actionTag,
            source: "Folder_D",
            recentlyCompletedOnly: true,
            includeConflictingRecentValueAtSameExpiry: true
        )
    }

    @Test("Gmail-style provider protects a pending field intention across label rows")
    func accountScopedProviderProtectsAcrossFolders() async throws {
        try await verifyProtection(
            .flagged,
            source: "Folder_B",
            recentlyCompletedOnly: false,
            fieldScope: .account
        )
    }

    @Test("IMAP-style provider does not let a pending UID protect another mailbox")
    func folderScopedProviderDoesNotProtectAnotherFolder() async throws {
        try await verifyProtection(
            .flagged,
            source: "Folder_B",
            recentlyCompletedOnly: false,
            fieldScope: .folder,
            expectedProtection: false
        )
    }

    @Test("IMAP-style recent field key protects only its originating mailbox")
    func folderScopedRecentFieldDoesNotProtectAnotherFolder() async throws {
        try await verifyProtection(
            .read,
            source: "Folder_B",
            recentlyCompletedOnly: true,
            fieldScope: .folder,
            expectedProtection: false
        )
    }

    @Test("push provenance composes with a field key to protect the exact row")
    func pushAndFieldKeyComposeForCurrentFolder() async throws {
        try await verifyProtection(
            .read,
            source: "Folder_D",
            recentlyCompletedOnly: true,
            fieldScope: .account,
            pushFolderPath: "Folder_D"
        )
    }

    @Test("push provenance from another label does not protect this row")
    func pushKeyIsFolderQualified() async throws {
        try await verifyProtection(
            .read,
            source: "Folder_D",
            recentlyCompletedOnly: true,
            fieldScope: .account,
            pushFolderPath: "Folder_B"
        )
    }

    @Test("legacy bare provider id from account A cannot protect account B")
    func bareRecentIdentityCannotCrossAccounts() async throws {
        try await verifyProtection(
            .read,
            source: "Folder_D",
            recentlyCompletedOnly: true,
            fieldScope: .account,
            expectedProtection: false,
            recentAccountId: "other-account-\(UUID().uuidString)",
            includeLegacyBareIdentity: true
        )
    }
}

// MARK: - Suite: UID remap ftsRekeys emission (real runSyncMessages)

/// Drives the real `SyncEngine.runSyncMessages` against `MockEmailProvider` to
/// lock the UID-remap contract introduced with `SearchIndex.rekeyHeaders`:
/// a re-keyed row must ride `ftsRekeys` (its FTS entry MOVES in place,
/// preserving indexed body + embedding) and must NOT ride `staleIds` (which
/// would delete that entry) nor `newHeaders` (header-only re-index).
@Suite("runSyncMessages — UID remap ftsRekeys emission", .serialized, .processGlobalState)
struct RunSyncUIDRemapFtsRekeyTests {

    @Test("UID remap reconciles authoritative remote label removal after identity-state restore")
    func uidRemapReconcilesAuthoritativeLabelRemoval() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: dir)
        }
        try AppDatabase.runMigrations(on: pool)

        let accountId = "label-remap-\(UUID().uuidString)"
        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
        let oldId = "\(accountId):INBOX:100"
        let newId = "\(accountId):INBOX:200"
        let labelId = "project"
        let rfc822MessageId = "label-remap@example.com"
        try await pool.write { db in
            var account = Account(
                emailAddress: "label-remap@example.com",
                displayName: "Label Remap",
                provider: .imap
            )
            account.id = accountId
            try account.insert(db)
            try folder.insert(db)
            try UserLabel(
                id: labelId,
                accountId: accountId,
                name: "Project",
                isSystem: false
            ).insert(db)
            var header = MessageHeader(
                messageId: "100",
                subject: "Label remap",
                from: "sender@example.com",
                fromAddress: "sender@example.com",
                to: "recipient@example.com",
                date: TestFixtureDate.anchor,
                snippet: "",
                folderId: folder.id,
                accountId: accountId,
                folderPath: folder.path,
                isInInbox: true
            )
            header.rfc822MessageId = rfc822MessageId
            try header.insert(db)
            try MessageUserLabel(messageId: oldId, accountId: accountId, userLabelId: labelId).insert(db)
        }

        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setFetchMessagesResult([
            makeHeaderInfo(
                messageId: "200",
                rfc822MessageId: rfc822MessageId,
                userLabelIds: [],
                userLabelIdsAreAuthoritative: true
            ),
        ])

        _ = try await SyncEngine.runSyncMessages(
            for: folder,
            provider: mock,
            limit: 50,
            dbPool: PrioritizedDatabase(pool: pool)
        )

        let finalState = try await pool.read { db in
            (
                try MessageHeader.fetchOne(db, key: oldId),
                try MessageHeader.fetchOne(db, key: newId),
                try MessageUserLabel
                    .filter(Column("messageId") == newId)
                    .fetchCount(db)
            )
        }
        #expect(finalState.0 == nil)
        #expect(finalState.1 != nil)
        #expect(finalState.2 == 0)
    }

    @Test("non-authoritative empty label metadata preserves existing local membership")
    func nonAuthoritativeLabelsPreserveMembership() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: dir)
        }
        try AppDatabase.runMigrations(on: pool)

        let accountId = "label-cold-\(UUID().uuidString)"
        let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
        let messageId = "gmail-message-1"
        let headerId = "\(accountId):INBOX:\(messageId)"
        let labelId = "Label_42"
        try await pool.write { db in
            var account = Account(
                emailAddress: "label-cold@example.com",
                displayName: "Label Cold",
                provider: .gmail
            )
            account.id = accountId
            try account.insert(db)
            try folder.insert(db)
            try UserLabel(
                id: labelId,
                accountId: accountId,
                name: "Project",
                isSystem: false
            ).insert(db)
            var header = MessageHeader(
                messageId: messageId,
                subject: "Cold catalog",
                from: "sender@example.com",
                fromAddress: "sender@example.com",
                to: "recipient@example.com",
                date: TestFixtureDate.anchor,
                snippet: "",
                folderId: folder.id,
                accountId: accountId,
                folderPath: folder.path,
                isInInbox: true
            )
            header.rfc822MessageId = "label-cold-message@example.com"
            try header.insert(db)
            try MessageUserLabel(messageId: headerId, accountId: accountId, userLabelId: labelId).insert(db)
        }

        let mock = MockEmailProvider(messageFieldScope: .account)
        await mock.setFetchMessagesResult([
            makeHeaderInfo(
                messageId: messageId,
                rfc822MessageId: "label-cold-message@example.com",
                userLabelIds: [],
                userLabelIdsAreAuthoritative: false
            ),
        ])

        _ = try await SyncEngine.runSyncMessages(
            for: folder,
            provider: mock,
            limit: 50,
            dbPool: PrioritizedDatabase(pool: pool)
        )

        let membershipCount = try await pool.read { db in
            try MessageUserLabel
                .filter(Column("messageId") == headerId && Column("userLabelId") == labelId)
                .fetchCount(db)
        }
        #expect(membershipCount == 1)
    }

    @Test("Remap emits ftsRekeys with new messageId; old id avoids staleIds/newHeaders")
    func remapEmitsFtsRekey() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: dir)
        }
        try AppDatabase.runMigrations(on: pool)

        let date = TestFixtureDate.anchor
        try await pool.write { db in
            var acc = Account(emailAddress: "remap@example.com", displayName: "T", provider: .imap)
            acc.id = "racc"
            try acc.insert(db)
            let folder = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "racc")
            try folder.insert(db)
            var header = MessageHeader(
                messageId: "100", subject: "Remap target", from: "a@x", fromAddress: "a@x",
                to: "b@x", date: date, snippet: "s",
                folderId: "racc:INBOX", accountId: "racc", folderPath: "INBOX", isInInbox: true
            )
            header.rfc822MessageId = "remap-x@example.com"
            header.headerComplete = true
            header.bodyComplete = true
            try header.insert(db)
            try MessageBody(headerId: "racc:INBOX:100", htmlContent: "<p>kept</p>").insert(db)
        }

        let folder = try await pool.read { try Folder.fetchOne($0, key: "racc:INBOX")! }
        let mock = MockEmailProvider()
        await mock.setFetchMessagesResult([
            makeHeaderInfo(messageId: "200", rfc822MessageId: "remap-x@example.com",
                           subject: "Remap target", date: date)
        ])

        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: 50, dbPool: PrioritizedDatabase(pool: pool))

        // ftsRekeys carries the move, with the new provider message id.
        #expect(result.ftsRekeys.count == 1)
        #expect(result.ftsRekeys.first?.oldId == "racc:INBOX:100")
        #expect(result.ftsRekeys.first?.newId == "racc:INBOX:200")
        #expect(result.ftsRekeys.first?.newMessageId == "200")
        // The old id must NOT be removed from FTS or header-only re-indexed.
        #expect(!result.staleIds.contains("racc:INBOX:100"))
        #expect(!result.newHeaders.contains { $0.id == "racc:INBOX:200" })
        #expect(result.uidMigratedOldIds == ["100"])

        // GRDB row re-keyed in place, body preserved, bodyComplete untouched
        // (its FTS entry rides the rekey — no refetch churn).
        let migrated = try await pool.read { try MessageHeader.fetchOne($0, key: "racc:INBOX:200") }
        #expect(migrated != nil)
        #expect(migrated?.bodyComplete == true)
        let old = try await pool.read { try MessageHeader.fetchOne($0, key: "racc:INBOX:100") }
        #expect(old == nil)
        let body = try await pool.read { try MessageBody.fetchOne($0, key: "racc:INBOX:200") }
        #expect(body?.htmlContent == "<p>kept</p>")
    }

    /// Round G candidate 3 (UID-remap canonicalization): the UID-remap path merges
    /// rows whose identity is proven by rfc822MessageId, not just the newest generation.
    @Test("Occupied target merges every identity-proven local state before deleting the old UID")
    func occupiedTargetMergesBeforeOldUIDDelete() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: dir)
        }
        try AppDatabase.runMigrations(on: pool)

        let accountId = "uid-collision-\(UUID().uuidString)"
        let inboxId = "\(accountId):INBOX"
        let archiveId = "\(accountId):Archive"
        let oldId = "\(accountId):INBOX:100"
        let extraOldId = "\(accountId):INBOX:150"
        let targetId = "\(accountId):INBOX:200"
        let rfc822 = "<uid-collision@example.com>"
        let date = Date().addingTimeInterval(-60)

        try await pool.write { db in
            var account = Account(
                emailAddress: "uid-collision@example.com",
                displayName: "UID Collision",
                provider: .imap
            )
            account.id = accountId
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
                .insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: accountId)
                .insert(db)
            try UserLabel(id: "uid-old-label", accountId: accountId, name: "Old", isSystem: false)
                .insert(db)
            try UserLabel(id: "uid-extra-label", accountId: accountId, name: "Extra", isSystem: false)
                .insert(db)
            try UserLabel(id: "uid-target-label", accountId: accountId, name: "Target", isSystem: false)
                .insert(db)

            var old = MessageHeader(
                messageId: "100",
                subject: "Rich old generation",
                from: "Old Sender",
                fromAddress: "old-sender@example.com",
                to: "recipient@example.com",
                date: date,
                snippet: "old",
                folderId: inboxId,
                accountId: accountId,
                folderPath: "INBOX",
                isInInbox: true
            )
            old.rfc822MessageId = rfc822
            old.summaryBlurb = "old summary survives"
            try old.insert(db)

            var extraOld = MessageHeader(
                messageId: "150",
                subject: "Second old generation",
                from: "Extra Sender",
                fromAddress: "extra-sender@example.com",
                to: "recipient@example.com",
                date: date,
                snippet: "extra",
                folderId: inboxId,
                accountId: accountId,
                folderPath: "INBOX",
                isInInbox: true
            )
            extraOld.rfc822MessageId = rfc822
            extraOld.summaryTodos = "second old generation survives"
            try extraOld.insert(db)

            var target = MessageHeader(
                messageId: "200",
                subject: "Skeletal target generation",
                from: "Target Sender",
                fromAddress: "target-sender@example.com",
                to: "recipient@example.com",
                date: date,
                snippet: "target",
                folderId: inboxId,
                accountId: accountId,
                folderPath: "INBOX",
                isInInbox: true
            )
            target.rfc822MessageId = rfc822
            target.cachedReply = "target reply survives"
            // Occupy the destination PK outside the syncing folder, matching the
            // optimistic-move remnant shape that bypasses folder-scoped membership.
            target.folderId = archiveId
            target.folderPath = "Archive"
            target.isInInbox = false
            try target.insert(db)

            try MessageBody(
                headerId: oldId,
                htmlContent: "<p>the much richer old body must survive the UID collision</p>"
            ).insert(db)
            try MessageBody(headerId: extraOldId, htmlContent: "<p>extra</p>").insert(db)
            try MessageBody(headerId: targetId, htmlContent: "<p>short</p>").insert(db)
            try MessageUserLabel(messageId: oldId, accountId: accountId, userLabelId: "uid-old-label").insert(db)
            try MessageUserLabel(messageId: extraOldId, accountId: accountId, userLabelId: "uid-extra-label").insert(db)
            try MessageUserLabel(messageId: targetId, accountId: accountId, userLabelId: "uid-target-label").insert(db)
            try MessageReference(
                messageHeaderId: oldId,
                referencedRfc822Id: "<old-reference@example.com>"
            ).insert(db)
            try MessageReference(
                messageHeaderId: targetId,
                referencedRfc822Id: "<target-reference@example.com>"
            ).insert(db)
            try MessageReference(
                messageHeaderId: extraOldId,
                referencedRfc822Id: "<extra-reference@example.com>"
            ).insert(db)
        }

        let folder = try #require(try await pool.read { try Folder.fetchOne($0, key: inboxId) })
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setFetchMessagesResult([
            makeHeaderInfo(
                messageId: "200",
                rfc822MessageId: rfc822,
                subject: "Current remote generation",
                date: date,
                isRead: true
            ),
        ])

        let result = try await SyncEngine.runSyncMessages(
            for: folder,
            provider: mock,
            limit: 50,
            dbPool: PrioritizedDatabase(pool: pool)
        )

        #expect(result.ftsRekeys.count == 2)
        guard result.ftsRekeys.count == 2 else { return }
        #expect(Set(result.ftsRekeys.map(\.oldId)) == [oldId, extraOldId])
        #expect(result.ftsRekeys.allSatisfy { $0.newId == targetId })
        #expect(result.ftsRekeys.allSatisfy { $0.newMessageId == "200" })
        #expect(Set(result.staleIds).isDisjoint(with: [oldId, extraOldId]))
        #expect(!result.newHeaders.contains { $0.id == targetId })
        #expect(Set(result.uidMigratedOldIds) == ["100", "150"])

        let survivor = try #require(try await pool.read {
            try MessageHeader.fetchOne($0, key: targetId)
        })
        #expect(survivor.folderId == inboxId)
        #expect(survivor.folderPath == "INBOX")
        #expect(survivor.isInInbox)
        #expect(survivor.summaryBlurb == "old summary survives")
        #expect(survivor.summaryTodos == "second old generation survives")
        #expect(survivor.cachedReply == "target reply survives")
        #expect(try await pool.read { try MessageHeader.fetchOne($0, key: oldId) } == nil)
        #expect(try await pool.read { try MessageHeader.fetchOne($0, key: extraOldId) } == nil)
        let mergedBody = try #require(try await pool.read {
            try MessageBody.fetchOne($0, key: targetId)
        })
        #expect(mergedBody.htmlContent?.contains("much richer old body") == true)
        let labels = try await pool.read { db in
            try MessageUserLabel
                .filter(Column("messageId") == targetId)
                .fetchAll(db)
                .map(\.userLabelId)
        }
        #expect(Set(labels) == ["uid-old-label", "uid-extra-label", "uid-target-label"])
        let references = try await pool.read { db in
            try MessageReference
                .filter(Column("messageHeaderId") == targetId)
                .fetchAll(db)
                .map(\.referencedRfc822Id)
        }
        #expect(Set(references) == [
            "<old-reference@example.com>",
            "<extra-reference@example.com>",
            "<target-reference@example.com>",
        ])
    }
}

// MARK: - Suite: duplicate canonicalization ftsRekeys wiring (real runSyncMessages)

/// Drives the real production caller around `canonicalizeLocalRows`. Direct canonicalizer
/// tests cannot detect a caller that sends its merge losers through `staleIds` instead of
/// forwarding their identity-proven rekeys to SearchIndex.
///
/// Round G candidate 2 (full-sync canonicalization) at the real `runSyncMessages` caller:
/// every independently proven old-to-survivor re-key must reach the FTS rekey channel.
@Suite("runSyncMessages — duplicate canonicalization ftsRekeys emission", .serialized, .processGlobalState)
struct RunSyncDuplicateCanonicalizationFtsRekeyTests {

    @Test("Every duplicate loser emits old-to-survivor rekey and never rides staleIds")
    func duplicateLosersUseFtsRekeyChannel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: dir)
        }
        try AppDatabase.runMigrations(on: pool)

        let accountId = "canonical-wiring-\(UUID().uuidString)"
        let folderPath = "TRASH"
        let folderId = "\(accountId):\(folderPath)"
        let providerId = "duplicate-provider-id"
        let rfc822 = "duplicate-wiring@example.com"
        let date = Date().addingTimeInterval(-60)
        let legacyPaths = ["INBOX", "Legacy"]

        try await pool.write { db in
            var account = Account(
                emailAddress: "canonical-wiring@example.com",
                displayName: "Canonical Wiring",
                provider: .gmail
            )
            account.id = accountId
            try account.insert(db)
            try Folder(
                name: "Trash", path: folderPath, role: .trash, accountId: accountId
            ).insert(db)

            for legacyPath in legacyPaths {
                var loser = MessageHeader(
                    messageId: providerId,
                    subject: "Duplicate wiring",
                    from: "Sender",
                    fromAddress: "sender@example.com",
                    to: "recipient@example.com",
                    date: date,
                    snippet: "duplicate",
                    folderId: folderId,
                    accountId: accountId,
                    folderPath: legacyPath,
                    isInInbox: false
                )
                loser.isRead = true
                loser.isFlagged = true
                loser.actionTag = .archive
                loser.tagSortOrder = 0
                loser.rfc822MessageId = rfc822
                try loser.insert(db)
            }
            var canonical = MessageHeader(
                messageId: providerId,
                subject: "Duplicate wiring",
                from: "Sender",
                fromAddress: "sender@example.com",
                to: "recipient@example.com",
                date: date,
                snippet: "duplicate",
                folderId: folderId,
                accountId: accountId,
                folderPath: folderPath,
                isInInbox: false
            )
            canonical.isRead = true
            canonical.isFlagged = true
            canonical.actionTag = .archive
            canonical.tagSortOrder = 0
            canonical.rfc822MessageId = rfc822
            try canonical.insert(db)
            for type in [OperationType.markUnread, .markUnflagged, .removeTag] {
                let operation = PendingOperation(
                    type: type,
                    messageIds: [rfc822],
                    accountId: accountId,
                    folderPath: folderPath
                )
                try operation.insert(db)
            }
        }

        let folder = try #require(try await pool.read {
            try Folder.fetchOne($0, key: folderId)
        })
        let mock = MockEmailProvider()
        await mock.setFetchMessagesResult([
            makeHeaderInfo(
                messageId: providerId,
                rfc822MessageId: "<duplicate-wiring@example.com>",
                subject: "Duplicate wiring",
                date: date,
                isRead: true,
                isFlagged: true,
                actionTag: .archive
            ),
        ])

        // Pending intent wins even if an opposite completed receipt remains live.
        let recentExpiry = Date().addingTimeInterval(120)
        var recent: [String: Date] = [:]
        for field in MessageIdentity.RecentlyCompletedField.allCases {
            recent[MessageIdentity.recentlyCompletedFieldKey(
                accountId: accountId,
                folderPath: folderPath,
                messageId: providerId,
                field: field
            )] = recentExpiry
        }
        for value in [
            MessageIdentity.RecentlyCompletedFieldValue.read(true),
            .flagged(true),
            .actionTag(ActionTag.archive.rawValue),
        ] {
            recent[MessageIdentity.recentlyCompletedFieldValueKey(
                accountId: accountId,
                folderPath: folderPath,
                messageId: providerId,
                value: value
            )] = recentExpiry
        }

        let result = try await SyncEngine.runSyncMessages(
            for: folder,
            provider: mock,
            limit: 50,
            dbPool: PrioritizedDatabase(pool: pool),
            recentlyCompleted: recent
        )

        let canonicalId = "\(accountId):\(folderPath):\(providerId)"
        let loserIds = Set(legacyPaths.map { "\(accountId):\($0):\(providerId)" })
        #expect(result.ftsRekeys.count == 2)
        let emitted = Set(result.ftsRekeys.map { "\($0.oldId)->\($0.newId)" })
        #expect(emitted == Set(loserIds.map { "\($0)->\(canonicalId)" }))
        #expect(result.ftsRekeys.allSatisfy { $0.newMessageId == nil })
        #expect(Set(result.staleIds).isDisjoint(with: loserIds),
                "identity merge losers must never be deleted through staleIds")
        #expect(result.newHeaders.isEmpty)

        let rows = try await pool.read {
            try MessageHeader
                .filter(Column("accountId") == accountId
                        && Column("messageId") == providerId)
                .fetchAll($0)
        }
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        #expect(rows[0].id == canonicalId)
        #expect(rows[0].isRead == false, "pending markUnread is exact, not an OR merge")
        #expect(rows[0].isFlagged == false, "pending markUnflagged is exact, not an OR merge")
        // A queued `.removeTag` PendingOperation provides NO field authority
        // for actionTag — confirmed by the sibling suite's "legacy pending
        // actionTag row does not protect local-only tag" (only
        // `recentlyCompleted` evidence does, via `isPendingActionTag`'s
        // hardcoded `false` in SyncEngineFullSync.swift). The evidence seeded
        // above is `.actionTag(ActionTag.archive.rawValue)`, matching both the
        // pre-existing rows and the remote value, so `.archive` is the
        // correct outcome. Round D-0 also means this holds regardless of the
        // row being outside the inbox (Trash) — no inbox-scoped nulling.
        #expect(rows[0].actionTag == .archive)
        #expect(rows[0].tagSortOrder == ActionTag.archive.sortOrder)
    }

    @Test("Pre-sync and orphan reclaim remove labels absent from authoritative state")
    func preSyncInboxReclaimMergesAllDuplicates() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: dir)
        }
        try AppDatabase.runMigrations(on: pool)

        let accountId = "pre-sync-merge-\(UUID().uuidString)"
        let providerId = "shared-provider-id"
        let rfc822 = "<pre-sync-merge@example.com>"
        let date = Date().addingTimeInterval(-60)
        let sourcePaths = ["LegacyInboxA", "LegacyInboxB"]
        let folderId = "\(accountId):INBOX"
        let orphanProviderId = "orphan-provider-id"
        let orphanTargetId = "\(folderId):\(orphanProviderId)"
        let orphanLabelId = "orphan-stale-label"

        try await pool.write { db in
            var account = Account(
                emailAddress: "pre-sync-merge@example.com",
                displayName: "Pre-sync Merge",
                provider: .outlook
            )
            account.id = accountId
            try account.insert(db)
            try Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: accountId)
                .insert(db)
            try Folder(
                name: "Archive", path: "Archive", role: .archive, accountId: accountId
            ).insert(db)
            try UserLabel(
                id: orphanLabelId,
                accountId: accountId,
                name: "Orphan Label",
                isSystem: false
            ).insert(db)
            for path in sourcePaths {
                try Folder(name: path, path: path, role: .custom, accountId: accountId)
                    .insert(db)
                try UserLabel(
                    id: "label-\(path)",
                    accountId: accountId,
                    name: path,
                    isSystem: false
                ).insert(db)
            }

            for (index, path) in sourcePaths.enumerated() {
                var source = MessageHeader(
                    messageId: providerId,
                    subject: "Pre-sync duplicate",
                    from: "Sender",
                    fromAddress: "sender@example.com",
                    to: "recipient@example.com",
                    date: date,
                    snippet: "duplicate",
                    folderId: "\(accountId):\(path)",
                    accountId: accountId,
                    folderPath: path,
                    isInInbox: true
                )
                source.rfc822MessageId = rfc822
                source.isRead = true
                source.isFlagged = true
                source.actionTag = .archive
                source.tagSortOrder = 0
                if index == 0 {
                    source.summaryBlurb = "summary from source A"
                } else {
                    source.cachedReply = "reply from source B"
                }
                try source.insert(db)
                let html = index == 0
                    ? "<p>short source body</p>"
                    : "<p>the richer source B body token must survive duplicate reclaim</p>"
                try MessageBody(headerId: source.id, htmlContent: html).insert(db)
                try MessageUserLabel(
                    messageId: source.id,
                    accountId: accountId,
                    userLabelId: "label-\(path)"
                ).insert(db)
                try MessageReference(
                    messageHeaderId: source.id,
                    referencedRfc822Id: "<reference-\(index)@example.com>"
                ).insert(db)
            }

            var orphan = MessageHeader(
                messageId: orphanProviderId,
                subject: "Orphan message",
                from: "Sender",
                fromAddress: "sender@example.com",
                to: "recipient@example.com",
                date: date,
                snippet: "orphan",
                folderId: "\(accountId):Archive",
                accountId: accountId,
                folderPath: "INBOX",
                isInInbox: false
            )
            orphan.rfc822MessageId = "<orphan-reclaim@example.com>"
            try orphan.insert(db)
            try MessageUserLabel(
                messageId: orphan.id,
                accountId: accountId,
                userLabelId: orphanLabelId
            ).insert(db)
        }

        let targetId = "\(accountId):INBOX:\(providerId)"
        let sourceIds = Set(sourcePaths.map { "\(accountId):\($0):\(providerId)" })
        let folder = try #require(try await pool.read { try Folder.fetchOne($0, key: folderId) })
        let mock = MockEmailProvider(messageFieldScope: .account)
        await mock.setFetchMessagesResult([
            makeHeaderInfo(
                messageId: providerId,
                rfc822MessageId: rfc822,
                subject: "Pre-sync duplicate",
                date: date,
                isRead: true,
                isFlagged: true,
                actionTag: .archive,
                userLabelIds: [],
                userLabelIdsAreAuthoritative: true
            ),
            makeHeaderInfo(
                messageId: orphanProviderId,
                rfc822MessageId: "<orphan-reclaim@example.com>",
                subject: "Orphan message",
                date: date,
                userLabelIds: [],
                userLabelIdsAreAuthoritative: true
            ),
        ])

        // Conflicting receipts may coexist until their independent TTLs expire. The
        // unique greatest expiry across provider-id/RFC aliases is authoritative.
        let olderExpiry = Date().addingTimeInterval(30)
        let newerExpiry = Date().addingTimeInterval(60)
        var recent: [String: Date] = [:]
        for field in MessageIdentity.RecentlyCompletedField.allCases {
            for identity in [providerId, rfc822] {
                recent[MessageIdentity.recentlyCompletedFieldKey(
                    accountId: accountId,
                    messageId: identity,
                    field: field
                )] = newerExpiry
            }
        }
        for value in [
            MessageIdentity.RecentlyCompletedFieldValue.read(true),
            .flagged(true),
            .actionTag(ActionTag.archive.rawValue),
        ] {
            recent[MessageIdentity.recentlyCompletedFieldValueKey(
                accountId: accountId,
                messageId: providerId,
                value: value
            )] = olderExpiry
        }
        for value in [
            MessageIdentity.RecentlyCompletedFieldValue.read(false),
            .flagged(false),
            .actionTag(nil),
        ] {
            recent[MessageIdentity.recentlyCompletedFieldValueKey(
                accountId: accountId,
                messageId: rfc822,
                value: value
            )] = newerExpiry
        }

        let result = try await SyncEngine.runSyncMessages(
            for: folder,
            provider: mock,
            limit: 50,
            dbPool: PrioritizedDatabase(pool: pool),
            recentlyCompleted: recent
        )

        #expect(Set(result.ftsRekeys.map(\.oldId)) == sourceIds)
        #expect(result.ftsRekeys.allSatisfy { $0.newId == targetId })
        #expect(Set(result.staleIds).isDisjoint(with: sourceIds))
        let survivor = try #require(try await pool.read {
            try MessageHeader.fetchOne($0, key: targetId)
        })
        #expect(survivor.summaryBlurb == "summary from source A")
        #expect(survivor.cachedReply == "reply from source B")
        #expect(survivor.isRead == false)
        #expect(survivor.isFlagged == false)
        #expect(survivor.actionTag == nil)
        #expect(survivor.tagSortOrder == 99)
        let rows = try await pool.read {
            try MessageHeader
                .filter(Column("accountId") == accountId
                        && Column("messageId") == providerId
                        && Column("isInInbox") == true)
                .fetchAll($0)
        }
        #expect(rows.count == 1)
        let mergedBody = try #require(try await pool.read {
            try MessageBody.fetchOne($0, key: targetId)
        })
        #expect(mergedBody.htmlContent?.contains("richer source B body token") == true)
        let labels = try await pool.read { db in
            try MessageUserLabel
                .filter(Column("messageId") == targetId)
                .fetchAll(db)
                .map(\.userLabelId)
        }
        #expect(labels.isEmpty)
        let reclaimedOrphan = try #require(try await pool.read {
            try MessageHeader.fetchOne($0, key: orphanTargetId)
        })
        #expect(reclaimedOrphan.folderId == folderId)
        #expect(reclaimedOrphan.isInInbox)
        let orphanLabelCount = try await pool.read { db in
            try MessageUserLabel
                .filter(Column("messageId") == orphanTargetId)
                .fetchCount(db)
        }
        #expect(orphanLabelCount == 0)
        let references = try await pool.read { db in
            try MessageReference
                .filter(Column("messageHeaderId") == targetId)
                .fetchAll(db)
                .map(\.referencedRfc822Id)
        }
        #expect(Set(references) == [
            "<reference-0@example.com>",
            "<reference-1@example.com>",
        ])
    }

    @Test("Draft dedup merges generations and removes labels absent from authoritative state")
    func draftDedupMergesAllOptimisticGenerations() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: dir)
        }
        try AppDatabase.runMigrations(on: pool)

        let accountId = "draft-merge-\(UUID().uuidString)"
        let folderPath = "Drafts"
        let folderId = "\(accountId):\(folderPath)"
        let rfc822 = "<draft-merge@example.com>"
        let sourceMessageIds = ["optimistic-a", "optimistic-b"]
        let remoteDate = Date()
        let sourceDate = remoteDate.addingTimeInterval(-30 * 24 * 60 * 60)

        try await pool.write { db in
            var account = Account(
                emailAddress: "draft-merge@example.com",
                displayName: "Draft Merge",
                provider: .imap
            )
            account.id = accountId
            try account.insert(db)
            try Folder(
                name: "Drafts", path: folderPath, role: .drafts, accountId: accountId
            ).insert(db)
            for index in sourceMessageIds.indices {
                let labelId = "draft-label-\(index)"
                try UserLabel(
                    id: labelId, accountId: accountId, name: labelId, isSystem: false
                ).insert(db)
                var source = MessageHeader(
                    messageId: sourceMessageIds[index],
                    subject: "Optimistic draft",
                    from: "Sender",
                    fromAddress: "sender@example.com",
                    to: "recipient@example.com",
                    date: sourceDate,
                    snippet: "draft",
                    folderId: folderId,
                    accountId: accountId,
                    folderPath: folderPath,
                    isInInbox: false
                )
                source.rfc822MessageId = rfc822
                source.isRead = true
                source.isFlagged = true
                source.actionTag = .archive
                source.tagSortOrder = 0
                if index == 0 {
                    source.summaryBlurb = "summary from optimistic A"
                } else {
                    source.cachedReply = "reply from optimistic B"
                }
                try source.insert(db)
                try MessageBody(
                    headerId: source.id,
                    htmlContent: index == 0
                        ? "<p>short draft body</p>"
                        : "<p>the richer optimistic B draft body must survive</p>"
                ).insert(db)
                try MessageUserLabel(
                    messageId: source.id,
                    accountId: accountId,
                    userLabelId: labelId
                ).insert(db)
                try MessageReference(
                    messageHeaderId: source.id,
                    referencedRfc822Id: "<draft-reference-\(index)@example.com>"
                ).insert(db)
            }
            for type in [OperationType.markUnread, .markUnflagged, .removeTag] {
                let operation = PendingOperation(
                    type: type,
                    messageIds: ["draft-merge@example.com"],
                    accountId: accountId,
                    folderPath: folderPath
                )
                try operation.insert(db)
            }
        }

        let currentMessageId = "server-current"
        let targetId = "\(accountId):\(folderPath):\(currentMessageId)"
        let sourceIds = Set(sourceMessageIds.map { "\(accountId):\(folderPath):\($0)" })
        let folder = try #require(try await pool.read { try Folder.fetchOne($0, key: folderId) })
        let mock = MockEmailProvider(staleWindowMode: .date)
        await mock.setFetchMessagesResult([
            makeHeaderInfo(
                messageId: currentMessageId,
                rfc822MessageId: rfc822,
                subject: "Current server draft",
                date: remoteDate,
                isRead: true,
                isFlagged: true,
                actionTag: .archive,
                userLabelIds: [],
                userLabelIdsAreAuthoritative: true
            ),
        ])

        // count == limit forces the date-window path; the older optimistic rows
        // are not stale candidates, so this directly exercises Draft/Sent dedup.
        let result = try await SyncEngine.runSyncMessages(
            for: folder,
            provider: mock,
            limit: 1,
            dbPool: PrioritizedDatabase(pool: pool)
        )

        #expect(Set(result.ftsRekeys.map(\.oldId)) == sourceIds)
        #expect(result.ftsRekeys.allSatisfy { $0.newId == targetId })
        #expect(Set(result.staleIds).isDisjoint(with: sourceIds))
        let rows = try await pool.read {
            try MessageHeader
                .filter(Column("folderId") == folderId
                        && Column("rfc822MessageId") == rfc822)
                .fetchAll($0)
        }
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        let survivor = rows[0]
        #expect(survivor.id == targetId)
        #expect(survivor.summaryBlurb == "summary from optimistic A")
        #expect(survivor.cachedReply == "reply from optimistic B")
        #expect(survivor.isRead == false)
        #expect(survivor.isFlagged == false)
        // No `recentlyCompleted` evidence is passed to this call, so
        // `fieldAuthority.actionTag` is `.unprotected` — `mergeLocalIdentityFields`'s
        // OR-merge fill (`if target.actionTag == nil, let tag = row.actionTag`)
        // is what determines the outcome, picking up one optimistic
        // generation's `.archive`. Round D-0: this is no longer nulled out
        // just because the survivor sits in Drafts (never the inbox) — the
        // old assertion here was masked by that inbox-scoped null, not by any
        // real protection (drafts/sent never get a legitimate AI-computed
        // actionTag in production; this fixture's residual tag is synthetic).
        #expect(survivor.actionTag == .archive)
        #expect(survivor.tagSortOrder == ActionTag.archive.sortOrder)
        let body = try #require(try await pool.read {
            try MessageBody.fetchOne($0, key: targetId)
        })
        #expect(body.htmlContent?.contains("richer optimistic B draft body") == true)
        let labels = try await pool.read { db in
            try MessageUserLabel
                .filter(Column("messageId") == targetId)
                .fetchAll(db)
                .map(\.userLabelId)
        }
        #expect(labels.isEmpty)
        let references = try await pool.read { db in
            try MessageReference
                .filter(Column("messageHeaderId") == targetId)
                .fetchAll(db)
                .map(\.referencedRfc822Id)
        }
        #expect(Set(references) == [
            "<draft-reference-0@example.com>",
            "<draft-reference-1@example.com>",
        ])
    }

    @Test("Draft dedup merges optimistic generations when the current server row already exists")
    func draftDedupMergesIntoExistingCurrentRow() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: dir)
        }
        try AppDatabase.runMigrations(on: pool)

        let accountId = "draft-existing-\(UUID().uuidString)"
        let folderPath = "Drafts"
        let folderId = "\(accountId):\(folderPath)"
        let rfc822 = "<draft-existing@example.com>"
        let currentMessageId = "server-current"
        let sourceMessageIds = ["optimistic-a", "optimistic-b"]
        let remoteDate = Date()
        let sourceDate = remoteDate.addingTimeInterval(-30 * 24 * 60 * 60)

        try await pool.write { db in
            var account = Account(
                emailAddress: "draft-existing@example.com",
                displayName: "Existing Draft",
                provider: .imap
            )
            account.id = accountId
            try account.insert(db)
            try Folder(
                name: "Drafts", path: folderPath, role: .drafts, accountId: accountId
            ).insert(db)

            var current = MessageHeader(
                messageId: currentMessageId,
                subject: "Fresh local draft",
                from: "Sender",
                fromAddress: "sender@example.com",
                to: "recipient@example.com",
                date: remoteDate,
                snippet: "current",
                folderId: folderId,
                accountId: accountId,
                folderPath: folderPath,
                isInInbox: false
            )
            current.rfc822MessageId = rfc822
            try current.insert(db)
            try MessageBody(
                headerId: current.id,
                htmlContent: "<p>current body</p>"
            ).insert(db)
            try UserLabel(
                id: "stale-draft-label",
                accountId: accountId,
                name: "Stale Draft Label",
                isSystem: false
            ).insert(db)
            try MessageUserLabel(
                messageId: current.id,
                accountId: accountId,
                userLabelId: "stale-draft-label"
            ).insert(db)

            for index in sourceMessageIds.indices {
                var source = MessageHeader(
                    messageId: sourceMessageIds[index],
                    subject: "Optimistic draft",
                    from: "Sender",
                    fromAddress: "sender@example.com",
                    to: "recipient@example.com",
                    date: sourceDate,
                    snippet: "optimistic",
                    folderId: folderId,
                    accountId: accountId,
                    folderPath: folderPath,
                    isInInbox: false
                )
                source.rfc822MessageId = rfc822
                if index == 0 {
                    source.summaryBlurb = "summary from optimistic A"
                } else {
                    source.cachedReply = "reply from optimistic B"
                }
                try source.insert(db)
                try MessageBody(
                    headerId: source.id,
                    htmlContent: index == 0
                        ? "<p>short source body</p>"
                        : "<p>the richer optimistic body must reach the existing row</p>"
                ).insert(db)
            }
        }

        let targetId = "\(accountId):\(folderPath):\(currentMessageId)"
        let sourceIds = Set(sourceMessageIds.map { "\(accountId):\(folderPath):\($0)" })
        let folder = try #require(try await pool.read { try Folder.fetchOne($0, key: folderId) })
        let mock = MockEmailProvider(staleWindowMode: .date)
        await mock.setFetchMessagesResult([
            makeHeaderInfo(
                messageId: currentMessageId,
                rfc822MessageId: rfc822,
                subject: "Lagging server draft",
                date: remoteDate,
                userLabelIds: [],
                userLabelIdsAreAuthoritative: true
            ),
        ])

        // The old generations fall outside the fetched date window, so only the
        // Draft/Sent existing-row convergence path can remove them.
        let result = try await SyncEngine.runSyncMessages(
            for: folder,
            provider: mock,
            limit: 1,
            dbPool: PrioritizedDatabase(pool: pool)
        )

        #expect(Set(result.ftsRekeys.map(\.oldId)) == sourceIds)
        #expect(result.ftsRekeys.allSatisfy { $0.newId == targetId })
        #expect(Set(result.staleIds).isDisjoint(with: sourceIds))
        let rows = try await pool.read {
            try MessageHeader
                .filter(Column("folderId") == folderId
                        && Column("rfc822MessageId") == rfc822)
                .fetchAll($0)
        }
        #expect(rows.count == 1)
        guard rows.count == 1 else { return }
        let survivor = rows[0]
        #expect(survivor.id == targetId)
        #expect(survivor.subject == "Fresh local draft")
        #expect(survivor.summaryBlurb == "summary from optimistic A")
        #expect(survivor.cachedReply == "reply from optimistic B")
        let body = try #require(try await pool.read {
            try MessageBody.fetchOne($0, key: targetId)
        })
        #expect(body.htmlContent?.contains("richer optimistic body") == true)
        let labelCount = try await pool.read { db in
            try MessageUserLabel
                .filter(Column("messageId") == targetId)
                .fetchCount(db)
        }
        #expect(labelCount == 0)
    }
}

// MARK: - FIX A: bounded newRemoteIds membership (SyncEngine.newRemoteIds)

/// Direct coverage for `SyncEngine.newRemoteIds(in:folderId:remoteIds:cachedLocalIds:)`
/// — the bounded membership check that replaced an unbounded full-folder load inside
/// `runSyncMessages` (All Mail was ~7s of write execution). These call the real
/// production helper, so they
/// guard the chunked-stride path, the empty-`remoteIds` no-op (a raw `IN ()` would be
/// invalid SQL), folder scoping, and equivalence with the full-load subtraction it
/// replaced.
@Suite("runSyncMessages — newRemoteIds (bounded membership)")
struct RunSyncNewRemoteIdsTests {

    @Test("Returns only remote ids not already present locally (DB path)")
    func newIdsFromDB() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageHeader(db, messageId: "2")
        try TestDatabase.insertMessageHeader(db, messageId: "3")

        let remote: Set<String> = ["2", "3", "4", "5"]
        let result = try db.read {
            try SyncEngine.newRemoteIds(in: $0, folderId: folder.id, remoteIds: remote, cachedLocalIds: nil)
        }
        #expect(result == ["4", "5"])
    }

    @Test("Empty remoteIds is a valid no-op (no IN () crash)")
    func emptyRemoteIds() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertMessageHeader(db, messageId: "1")

        let result = try db.read {
            try SyncEngine.newRemoteIds(in: $0, folderId: folder.id, remoteIds: [], cachedLocalIds: nil)
        }
        #expect(result.isEmpty)
    }

    @Test("All remote already local → empty")
    func allLocal() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertMessageHeader(db, messageId: "1")
        try TestDatabase.insertMessageHeader(db, messageId: "2")

        let result = try db.read {
            try SyncEngine.newRemoteIds(in: $0, folderId: folder.id, remoteIds: ["1", "2"], cachedLocalIds: nil)
        }
        #expect(result.isEmpty)
    }

    @Test("No local rows → every remote id is new")
    func noneLocal() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)

        let remote: Set<String> = ["7", "8", "9"]
        let result = try db.read {
            try SyncEngine.newRemoteIds(in: $0, folderId: folder.id, remoteIds: remote, cachedLocalIds: nil)
        }
        #expect(result == remote)
    }

    @Test("cachedLocalIds path bypasses the DB entirely")
    func cachedPath() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        // No rows inserted for "2"/"3", yet the cache marks them local → they must be
        // excluded purely from the cache, proving the DB path is not consulted.
        let remote: Set<String> = ["2", "3", "4"]
        let result = try db.read {
            try SyncEngine.newRemoteIds(in: $0, folderId: folder.id, remoteIds: remote, cachedLocalIds: ["2", "3"])
        }
        #expect(result == ["4"])
    }

    @Test("Scoped to the folder — same messageId in another folder is still new")
    func folderScoped() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let inbox = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        let archive = try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)
        // messageId "5" exists only in Archive.
        try TestDatabase.insertMessageHeader(db, messageId: "5", folderId: archive.id, folderPath: "Archive")

        let result = try db.read {
            try SyncEngine.newRemoteIds(in: $0, folderId: inbox.id, remoteIds: ["5"], cachedLocalIds: nil)
        }
        #expect(result == ["5"])
    }

    @Test("Chunked path (> chunk size) equals full-load subtraction")
    func chunkedEquivalence() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        let folder = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        // 300 local ids "0".."299".
        var localIds = Set<String>()
        for i in 0..<300 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)")
            localIds.insert("\(i)")
        }
        // 601 remote ids "0".."600" → forces two IN chunks (sqlChunkSize = 500).
        let remote = Set((0...600).map { "\($0)" })
        let result = try db.read {
            try SyncEngine.newRemoteIds(in: $0, folderId: folder.id, remoteIds: remote, cachedLocalIds: nil)
        }
        #expect(result == remote.subtracting(localIds))
    }
}

// MARK: - FIX C: large-folder stale safety (real runSyncMessages)

/// Drives the REAL `SyncEngine.runSyncMessages` via `MockEmailProvider` to lock the
/// FIX C safeguard: when a fetch returns FEWER than `limit` messages, the
/// "complete-knowledge" stale path (delete any local row not returned) is taken ONLY
/// when the local side is <= `SyncConfig.staleDetectionMaxFullScan`. A LARGE folder
/// that returns < limit is a truncated/partial fetch — treating it as complete would
/// mass-stale-delete the rows it never returned (the ADR-IOS-042 data-loss class).
@Suite("runSyncMessages — large-folder stale safety (FIX C)", .serialized, .processGlobalState)
struct RunSyncLargeFolderStaleSafetyTests {

    @Test("Large folder + partial (< limit) fetch does NOT mass-stale-delete unreturned rows")
    func largeFolderPartialFetchNoMassStale() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: dir)
        }
        try AppDatabase.runMigrations(on: pool)

        let date = TestFixtureDate.anchor
        let oldCount = SyncConfig.staleDetectionMaxFullScan + 50   // exceeds the gate
        try await pool.write { db in
            var acc = Account(emailAddress: "arch@example.com", displayName: "T", provider: .imap)
            acc.id = "racc"
            try acc.insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: "racc").insert(db)
            // Many OLD low-UID archive rows (below any realistic fetch floor).
            for uid in 1...oldCount {
                var h = MessageHeader(
                    messageId: "\(uid)", subject: "Old \(uid)", from: "a@x", fromAddress: "a@x",
                    to: "b@x", date: date, snippet: "s",
                    folderId: "racc:Archive", accountId: "racc", folderPath: "Archive", isInInbox: false
                )
                h.rfc822MessageId = "old-\(uid)@example.com"
                h.headerComplete = true
                try h.insert(db)
            }
        }

        let folder = try await pool.read { try Folder.fetchOne($0, key: "racc:Archive")! }
        // Simulate a TRUNCATED fetch of a huge folder: only 3 high-UID messages come back
        // (< limit), none matching the old local rows.
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setFetchMessagesResult([
            makeHeaderInfo(messageId: "900000", rfc822MessageId: "new-900000@example.com", subject: "New", date: date),
            makeHeaderInfo(messageId: "900001", rfc822MessageId: "new-900001@example.com", subject: "New", date: date),
            makeHeaderInfo(messageId: "900002", rfc822MessageId: "new-900002@example.com", subject: "New", date: date),
        ])

        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: 50, dbPool: PrioritizedDatabase(pool: pool))

        // FIX C: localCount > threshold → bounded windowed path (UID floor = 900000), so
        // none of the old low-UID rows are candidates → nothing stale-deleted. Without the
        // gate this would complete-knowledge-delete all `oldCount` rows (ADR-IOS-042).
        #expect(result.staleIds.isEmpty)
        let survivors = try await pool.read {
            try MessageHeader.filter(Column("folderId") == "racc:Archive").fetchCount($0)
        }
        #expect(survivors >= oldCount)          // all old rows survive (+ the 3 new inserts)
        let firstRow = try await pool.read { try MessageHeader.fetchOne($0, key: "racc:Archive:1") }
        #expect(firstRow != nil)
    }

    @Test("Small folder + partial (< limit) fetch STILL stale-deletes a genuinely-missing row")
    func smallFolderCompleteKnowledgePreserved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("t.sqlite").path)
        defer {
            try? pool.close()
            try? FileManager.default.removeItem(at: dir)
        }
        try AppDatabase.runMigrations(on: pool)

        let date = TestFixtureDate.anchor
        try await pool.write { db in
            var acc = Account(emailAddress: "arch@example.com", displayName: "T", provider: .imap)
            acc.id = "racc"
            try acc.insert(db)
            try Folder(name: "Archive", path: "Archive", role: .archive, accountId: "racc").insert(db)
            for uid in 1...5 {
                var h = MessageHeader(
                    messageId: "\(uid)", subject: "Msg \(uid)", from: "a@x", fromAddress: "a@x",
                    to: "b@x", date: date, snippet: "s",
                    folderId: "racc:Archive", accountId: "racc", folderPath: "Archive", isInInbox: false
                )
                h.rfc822MessageId = "m-\(uid)@example.com"
                h.headerComplete = true
                try h.insert(db)
            }
        }

        let folder = try await pool.read { try Folder.fetchOne($0, key: "racc:Archive")! }
        // Server now returns only UIDs 1-4 (< limit); UID 5 is genuinely gone.
        let mock = MockEmailProvider(staleWindowMode: .uid)
        await mock.setFetchMessagesResult((1...4).map { uid in
            makeHeaderInfo(messageId: "\(uid)", rfc822MessageId: "m-\(uid)@example.com", subject: "Msg \(uid)", date: date)
        })

        let result = try await SyncEngine.runSyncMessages(
            for: folder, provider: mock, limit: 50, dbPool: PrioritizedDatabase(pool: pool))

        // localCount (5) <= threshold → complete-knowledge path preserved → UID 5 is stale.
        #expect(result.staleIds.contains("racc:Archive:5"))
        #expect(!result.staleIds.contains("racc:Archive:1"))
    }
}
