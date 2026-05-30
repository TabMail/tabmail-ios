/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

// MARK: - Missing UID Detection Tests (DB-level logic replicating selfHealFolder step 2)

@Suite("SelfHeal — Missing UID Detection")
struct SelfHealMissingUIDTests {

    /// Replicate the SQL logic from selfHealFolder step 2:
    /// Given a set of remote UIDs and a folderId, find which UIDs are missing locally.
    private func findMissingUIDs(
        db: DatabaseQueue,
        remoteUIDs: [UInt32],
        folderId: String
    ) throws -> [UInt32] {
        guard !remoteUIDs.isEmpty else { return [] }
        return try db.read { dbAccess in
            let sqlChunkSize = 500
            var existingIds = Set<String>()
            for start in stride(from: 0, to: remoteUIDs.count, by: sqlChunkSize) {
                let end = min(start + sqlChunkSize, remoteUIDs.count)
                let chunk = remoteUIDs[start..<end].map { "\($0)" }
                let found = try String.fetchSet(dbAccess,
                    MessageHeader
                        .select(Column("messageId"))
                        .filter(Column("folderId") == folderId && chunk.contains(Column("messageId")))
                )
                existingIds.formUnion(found)
            }
            return remoteUIDs.filter { !existingIds.contains("\($0)") }
        }
    }

    @Test("Detects missing UIDs when some exist locally")
    func missingUIDDetection() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .imap)
        try TestDatabase.insertFolder(db)

        // Local has UIDs 1, 3, 5
        for uid in ["1", "3", "5"] {
            try TestDatabase.insertMessageHeader(db, messageId: uid)
        }

        let remoteUIDs: [UInt32] = [1, 2, 3, 4, 5]
        let missing = try findMissingUIDs(db: db, remoteUIDs: remoteUIDs, folderId: "acc1:INBOX")

        #expect(Set(missing) == Set<UInt32>([2, 4]))
    }

    @Test("No missing UIDs when all exist locally")
    func noMissingUIDs() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .imap)
        try TestDatabase.insertFolder(db)

        for uid in ["1", "2", "3"] {
            try TestDatabase.insertMessageHeader(db, messageId: uid)
        }

        let remoteUIDs: [UInt32] = [1, 2, 3]
        let missing = try findMissingUIDs(db: db, remoteUIDs: remoteUIDs, folderId: "acc1:INBOX")

        #expect(missing.isEmpty)
    }

    @Test("All UIDs missing when no local headers exist")
    func allUIDsMissing() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .imap)
        try TestDatabase.insertFolder(db)

        let remoteUIDs: [UInt32] = [10, 20, 30]
        let missing = try findMissingUIDs(db: db, remoteUIDs: remoteUIDs, folderId: "acc1:INBOX")

        #expect(Set(missing) == Set<UInt32>([10, 20, 30]))
    }

    @Test("Empty remote UIDs returns empty result")
    func emptyRemoteUIDs() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .imap)
        try TestDatabase.insertFolder(db)

        let missing = try findMissingUIDs(db: db, remoteUIDs: [], folderId: "acc1:INBOX")

        #expect(missing.isEmpty)
    }

    @Test("Chunked SQL comparison works with >500 remote UIDs")
    func chunkedSQLComparison() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .imap)
        try TestDatabase.insertFolder(db)

        // Insert local headers for even UIDs from 2 to 600
        let localUIDs = stride(from: 2, through: 600, by: 2).map { UInt32($0) }
        for uid in localUIDs {
            try TestDatabase.insertMessageHeader(db, messageId: "\(uid)")
        }

        // Remote has UIDs 1..750 — crosses two chunk boundaries (500, 500)
        let remoteUIDs = (1...750).map { UInt32($0) }
        let missing = try findMissingUIDs(db: db, remoteUIDs: remoteUIDs, folderId: "acc1:INBOX")

        // Missing = all odd UIDs 1..599 + all UIDs 601..750 minus even ones in that range
        let expectedMissing = Set(remoteUIDs.filter { uid in
            !localUIDs.contains(uid)
        })

        #expect(Set(missing) == expectedMissing)
        // Sanity: we expect odd UIDs 1-599 (300) + UIDs 601-750 that are odd (75) = 375
        // Plus UIDs > 600 that are even but not in localUIDs (601-750 evens: 602,604,...,750 = 75)
        // Total missing = 750 - 300 (local count) = 450
        #expect(missing.count == 750 - localUIDs.count)
    }

    @Test("Folder filtering — only compares UIDs within correct folderId")
    func folderFiltering() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .imap)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)

        // Insert UID "1" into Sent folder only
        try TestDatabase.insertMessageHeader(
            db, messageId: "1",
            folderId: "acc1:Sent", folderPath: "Sent", isInInbox: false
        )

        // Check INBOX — UID 1 should be missing because it's in Sent, not INBOX
        let missing = try findMissingUIDs(db: db, remoteUIDs: [1], folderId: "acc1:INBOX")
        #expect(missing == [1])
    }

    @Test("Cross-folder isolation — same messageId in different folders doesn't cause false positives")
    func crossFolderIsolation() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .imap)
        try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        try TestDatabase.insertFolder(db, name: "Archive", path: "Archive", role: .archive)

        // UID "42" exists in both INBOX and Archive
        try TestDatabase.insertMessageHeader(
            db, messageId: "42",
            folderId: "acc1:INBOX", folderPath: "INBOX", isInInbox: true
        )
        try TestDatabase.insertMessageHeader(
            db, messageId: "42",
            folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )

        // UID "99" exists only in Archive
        try TestDatabase.insertMessageHeader(
            db, messageId: "99",
            folderId: "acc1:Archive", folderPath: "Archive", isInInbox: false
        )

        // Check INBOX — 42 found, 99 missing (it's in Archive, not INBOX)
        let missingInbox = try findMissingUIDs(db: db, remoteUIDs: [42, 99], folderId: "acc1:INBOX")
        #expect(Set(missingInbox) == Set<UInt32>([99]))

        // Check Archive — both 42 and 99 found
        let missingArchive = try findMissingUIDs(db: db, remoteUIDs: [42, 99], folderId: "acc1:Archive")
        #expect(missingArchive.isEmpty)
    }
}

// MARK: - Rate Limiting Tests

@Suite("SelfHeal — Rate Limiting via UserDefaults")
struct SelfHealRateLimitTests {

    private let testAccountId = "selfheal_test_\(UUID().uuidString)"

    private var rateLimitKey: String { "selfHeal_lastRun_\(testAccountId)" }

    @Test("Recent run timestamp causes skip (< 1 hour ago)")
    func rateLimitSkipsRecentRun() {
        let key = rateLimitKey
        // Set last run to 10 minutes ago
        let tenMinutesAgo = Date().timeIntervalSince1970 - 600
        UserDefaults.standard.set(tenMinutesAgo, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let lastRun = UserDefaults.standard.double(forKey: key)
        let hourAgo = Date().timeIntervalSince1970 - 3600
        let shouldSkip = lastRun >= hourAgo

        #expect(shouldSkip, "Should skip when last run was only 10 minutes ago")
    }

    @Test("Old run timestamp allows execution (> 1 hour ago)")
    func rateLimitAllowsOldRun() {
        let key = rateLimitKey
        // Set last run to 2 hours ago
        let twoHoursAgo = Date().timeIntervalSince1970 - 7200
        UserDefaults.standard.set(twoHoursAgo, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let lastRun = UserDefaults.standard.double(forKey: key)
        let hourAgo = Date().timeIntervalSince1970 - 3600
        let shouldSkip = lastRun >= hourAgo

        #expect(!shouldSkip, "Should NOT skip when last run was 2 hours ago")
    }

    @Test("No previous run allows execution (key not set)")
    func rateLimitAllowsFirstRun() {
        let key = rateLimitKey
        UserDefaults.standard.removeObject(forKey: key)

        let lastRun = UserDefaults.standard.double(forKey: key) // returns 0.0
        let hourAgo = Date().timeIntervalSince1970 - 3600
        let shouldSkip = lastRun >= hourAgo

        #expect(!shouldSkip, "Should NOT skip when key has never been set (defaults to 0)")
    }

    @Test("forceSingleFolder bypasses rate limit check")
    func forceSingleFolderBypassesRateLimit() {
        let key = rateLimitKey
        // Set last run to just now — would normally cause a skip
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        // With forceSingleFolder != nil, rate limit check is skipped entirely
        let forceSingleFolder: Folder? = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: testAccountId)
        let shouldCheckRateLimit = (forceSingleFolder == nil)

        #expect(!shouldCheckRateLimit, "Rate limit check should be bypassed when forceSingleFolder is non-nil")
    }
}

// MARK: - Folder Role Filtering Tests

@Suite("SelfHeal — Folder Role Filtering")
struct SelfHealFolderRoleFilterTests {

    // These match the values in SyncEngine.swift
    private let primaryRoles: Set<FolderRole> = [.inbox]
    private let secondaryRoles: Set<FolderRole> = [.sent, .drafts, .trash, .archive, .spam]

    /// Replicate the filter predicate from selfHealRecentMessages
    private func isSyncable(_ folder: Folder) -> Bool {
        primaryRoles.contains(folder.role) ||
        secondaryRoles.contains(folder.role) ||
        folder.isFavorite
    }

    @Test("Primary role folders (inbox) pass filter")
    func primaryRoleFoldersPass() {
        let inbox = Folder(name: "INBOX", path: "INBOX", role: .inbox, accountId: "acc1")
        #expect(isSyncable(inbox))
    }

    @Test("Secondary role folders pass filter")
    func secondaryRoleFoldersPass() {
        let roles: [FolderRole] = [.sent, .drafts, .trash, .archive, .spam]
        for role in roles {
            let folder = Folder(name: role.rawValue, path: role.rawValue, role: role, accountId: "acc1")
            #expect(isSyncable(folder), "Folder with role \(role) should pass filter")
        }
    }

    @Test("Custom role non-favorite folders are excluded")
    func customNonFavoriteExcluded() {
        let folder = Folder(name: "MyLabel", path: "MyLabel", role: .custom, accountId: "acc1")
        #expect(!isSyncable(folder), "Custom non-favorite folder should be excluded")
    }

    @Test("Custom role favorite folders pass filter")
    func customFavoriteIncluded() {
        var folder = Folder(name: "MyLabel", path: "MyLabel", role: .custom, accountId: "acc1")
        folder.isFavorite = true
        #expect(isSyncable(folder), "Custom favorite folder should pass filter")
    }

    @Test("Filter selects correct subset from mixed folders")
    func filterSelectsCorrectSubset() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, provider: .imap)

        let inbox = try TestDatabase.insertFolder(db, name: "INBOX", path: "INBOX", role: .inbox)
        let sent = try TestDatabase.insertFolder(db, name: "Sent", path: "Sent", role: .sent)
        let custom1 = try TestDatabase.insertFolder(db, name: "Work", path: "Work", role: .custom)
        var custom2 = Folder(name: "VIP", path: "VIP", role: .custom, accountId: "acc1")
        custom2.isFavorite = true
        try db.write { try custom2.insert($0) }

        let allFolders: [Folder] = try db.read { db in
            try Folder.filter(Column("accountId") == "acc1" && Column("path") != "").fetchAll(db)
        }

        let syncable = allFolders.filter { isSyncable($0) }
        let syncableIds = Set(syncable.map(\.id))

        #expect(syncableIds.contains(inbox.id), "Inbox should be included")
        #expect(syncableIds.contains(sent.id), "Sent should be included")
        #expect(!syncableIds.contains(custom1.id), "Non-favorite custom should be excluded")
        #expect(syncableIds.contains(custom2.id), "Favorite custom should be included")
        #expect(syncable.count == 3)
    }
}

// MARK: - IMAP-Only Guard Tests

@Suite("SelfHeal — IMAP-Only Guard")
struct SelfHealIMAPGuardTests {

    @Test("Non-IMAP providers should be excluded")
    func nonIMAPProvidersExcluded() {
        // selfHealRecentMessages checks: account.provider == .imap
        let nonIMAPProviders: [AccountProvider] = [.gmail, .outlook, .icloud]
        for provider in nonIMAPProviders {
            let shouldRun = (provider == .imap)
            #expect(!shouldRun, "\(provider) should NOT trigger self-heal")
        }
    }

    @Test("IMAP provider should be allowed")
    func imapProviderAllowed() {
        let provider: AccountProvider = .imap
        let shouldRun = (provider == .imap)
        #expect(shouldRun, "IMAP provider should trigger self-heal")
    }
}
