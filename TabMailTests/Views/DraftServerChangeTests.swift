/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// #217 second owner ruling (ADR-IOS-091). A draft row keeps a copy of the server
/// text it last wrote or loaded; a server copy whose text no longer matches was
/// changed by another app. THE INVARIANTS:
/// 1. **A server copy another app changed is never overwritten without the user
///    choosing Overwrite.** The upload refuses; the edits stay in the row.
/// 2. **A local copy with no unsent edits never shadows a newer server copy.**
///    Opening follows the server.
/// 3. **Unsent edits are never dropped without the user choosing Reload.**
/// 4. **An older action never undoes a newer one.** Every writer here advances
///    `pushAttemptVersion`, and a reload writes only over the exact row it compared.

/// What this device sends for a draft (the upload's payload), as compared text.
func sentDraftText(
    subject: String, to: [String], cc: [String] = [], bcc: [String] = [], body: String,
    attachmentNames: [String] = []
) -> String {
    DraftServerText.of(DraftMessage(
        to: to, cc: cc, bcc: bcc, subject: subject, body: body,
        attachments: attachmentNames.map {
            DraftAttachment(filename: $0, mimeType: "application/octet-stream", data: Data())
        }))
}
@Suite("Draft server-change decisions (#217)")
struct DraftServerCheckDecisionTests {
    @Test("Compare: the same text is unchanged, different text is changed, no copy is gone")
    func compare() {
        #expect(DraftServerCheck.compare(base: "t1", current: "t1") == .unchanged)
        #expect(DraftServerCheck.compare(base: "t1", current: "t2") == .changed(text: "t2"))
        #expect(DraftServerCheck.compare(base: "t1", current: nil) == .gone)
    }

    @Test("Compare: a row with no copy of the server text keeps last-save-wins, but gone is still gone")
    func compareWithoutBase() {
        #expect(DraftServerCheck.compare(base: nil, current: "t2") == .unchanged)
        #expect(DraftServerCheck.compare(base: nil, current: nil) == .gone)
    }

    @Test("Text: what this device sends reads back equal however the server re-formats it")
    func reformattedServerCopyIsUnchanged() {
        let body = "Hi Alice,\n\nThe plan & the dates are below.\n\n> quoted line\nThanks"
        let sent = sentDraftText(
            subject: "  Plan   for Q3 ", to: ["Alice <Alice@Example.com>", "bob@example.com"],
            cc: ["carol@example.com"], body: body)
        // Re-formatted by a server: its own HTML document, entities and spacing,
        // display names, address case and order, header whitespace.
        let rewrapped = """
            <html><head><style>p { margin: 0 }</style></head><body>
            <p>Hi&nbsp;Alice,</p><p>&nbsp;</p>
            <p>The plan &amp; the   dates are below.</p>
            <blockquote>quoted line</blockquote><p>Thanks</p></body></html>
            """
        #expect(DraftServerText.of(Self.copy(
            subject: "Plan for Q3", to: "bob@example.com, \"Alice\" <alice@example.com>",
            cc: "Carol <carol@example.com>", html: rewrapped)) == sent,
                "a server re-formatting the same draft must not read as an edit")
        // A plain-text-only copy goes through the same body conversion.
        #expect(DraftServerText.of(Self.copy(
            subject: "Plan for Q3", to: "alice@example.com, bob@example.com",
            cc: "carol@example.com", html: nil, text: body)) == sent)
    }

    @Test("Text: an empty subject equals the server's \"(no subject)\"")
    func emptySubjectEqualsPlaceholder() {
        let sent = sentDraftText(subject: "", to: [], body: "Hello")
        #expect(DraftServerText.of(Self.copy(subject: "(no subject)", html: "<p>Hello</p>")) == sent)
        #expect(DraftServerText.of(Self.copy(subject: "(No Subject)", html: "<p>Hello</p>")) == sent)
    }

    /// One field changed in another app, as `(label, server copy)`.
    private static let editedCopies: [(String, FullMessageInfo)] = [
        ("subject", copy(subject: "Plan v2", to: "alice@example.com", cc: "carol@example.com",
                         bcc: "erin@example.com", html: "<div>Meet on Monday</div>", attachments: ["agenda.pdf"])),
        ("To", copy(subject: "Plan", to: "alice@example.com, dave@example.com", cc: "carol@example.com",
                    bcc: "erin@example.com", html: "<div>Meet on Monday</div>", attachments: ["agenda.pdf"])),
        ("Cc", copy(subject: "Plan", to: "alice@example.com", cc: "",
                    bcc: "erin@example.com", html: "<div>Meet on Monday</div>", attachments: ["agenda.pdf"])),
        ("Bcc", copy(subject: "Plan", to: "alice@example.com", cc: "carol@example.com",
                     bcc: "erin@example.com, frank@example.com", html: "<div>Meet on Monday</div>",
                     attachments: ["agenda.pdf"])),
        ("body word", copy(subject: "Plan", to: "alice@example.com", cc: "carol@example.com",
                           bcc: "erin@example.com", html: "<div>Meet on Tuesday</div>", attachments: ["agenda.pdf"])),
        ("body spacing", copy(subject: "Plan", to: "alice@example.com", cc: "carol@example.com",
                              bcc: "erin@example.com", html: "<div>Meet onMonday</div>", attachments: ["agenda.pdf"])),
        ("attachment added", copy(subject: "Plan", to: "alice@example.com", cc: "carol@example.com",
                                  bcc: "erin@example.com", html: "<div>Meet on Monday</div>",
                                  attachments: ["agenda.pdf", "notes.txt"])),
        ("attachment removed", copy(subject: "Plan", to: "alice@example.com", cc: "carol@example.com",
                                    bcc: "erin@example.com", html: "<div>Meet on Monday</div>")),
        ("inline image added", copy(subject: "Plan", to: "alice@example.com", cc: "carol@example.com",
                                    bcc: "erin@example.com", html: "<div>Meet on Monday</div>",
                                    attachments: ["agenda.pdf"], inlineImageTypes: ["image/png"])),
        ("text part only, changed", copy(subject: "Plan", to: "alice@example.com", cc: "carol@example.com",
                                         bcc: "erin@example.com", html: "", text: "Meet on Tuesday",
                                         attachments: ["agenda.pdf"])),
    ]

    private static let sentForEdits = sentDraftText(
        subject: "Plan", to: ["alice@example.com"], cc: ["carol@example.com"], bcc: ["erin@example.com"],
        body: "Meet on Monday", attachmentNames: ["agenda.pdf"])

    @Test("Text: the unchanged copy matches what this device sent")
    func unchangedCopyMatches() {
        #expect(DraftServerText.of(Self.copy(
            subject: "Plan", to: "alice@example.com", cc: "carol@example.com", bcc: "Erin <erin@example.com>",
            html: "<div>Meet on Monday</div>", attachments: ["agenda.pdf"])) == Self.sentForEdits)
    }

    @Test("Text: a change to any field another app can edit reads as an edit",
          arguments: Self.editedCopies.map(\.0))
    func editedFieldsAreChanged(field: String) throws {
        let edited = try #require(Self.editedCopies.first { $0.0 == field }?.1)
        #expect(DraftServerText.of(edited) != Self.sentForEdits, "a \(field) edit read as unchanged")
    }

    @Test("Text: an adopted inline image, uploaded as an attachment, compares equal to the original")
    func adoptedInlineImageRoundTrips() {
        let original = Self.copy(subject: "Plan", html: "<p>See <img src=\"cid:logo@x\"></p>",
                                 inlineImageTypes: ["image/png"])
        let image = InlineImage(contentId: "logo@x", contentType: "image/png", data: Data([1]))
        let uploaded = sentDraftText(
            subject: "Plan", to: [], body: "See",
            attachmentNames: [ExternalDraftAdoption.inlineImageFilename(image, index: 0)])
        #expect(DraftServerText.of(original) == uploaded)
    }

    private static func copy(
        subject: String, to: String = "", cc: String = "", bcc: String = "",
        html: String?, text: String? = nil, attachments: [String] = [], inlineImageTypes: [String] = []
    ) -> FullMessageInfo {
        FullMessageInfo(
            header: MessageHeaderInfo(
                messageId: "m1", rfc822MessageId: nil, inReplyTo: nil, references: [], threadId: nil,
                subject: subject, from: "", fromAddress: "", to: to, cc: cc, bcc: bcc, replyTo: nil,
                date: Date(), snippet: "", isRead: true, isFlagged: false, hasAttachments: !attachments.isEmpty,
                isReplied: false, isForwarded: false, actionTag: nil),
            htmlBody: html, textBody: text,
            attachments: attachments.enumerated().map { index, name in
                AttachmentInfo(filename: name, contentType: "application/octet-stream",
                               section: "\(index + 1)", size: 1, encoding: nil)
            },
            inlineImages: inlineImageTypes.enumerated().map { index, type in
                InlineImage(contentId: "img\(index)@x", contentType: type, data: Data([UInt8(index)]))
            })
    }
}

/// The row writes behind the three choices and behind reload, on a plain queue.
@Suite("Draft server-change row writes (#217)")
struct DraftServerChangeRowTests {
    private static let accountId = "acc-imap"

    /// An adopted IMAP draft at Drafts/900001/7 whose copy of the server text is "old local text".
    private func makeAdoptedImapDraft(_ db: DatabaseQueue) throws -> (MessageHeader, Draft) {
        try TestDatabase.insertAccount(
            db, id: Self.accountId, email: "imap@example.com", provider: .imap)
        var folder = Folder(name: "Drafts", path: "Drafts", role: .drafts, accountId: Self.accountId)
        folder.lastKnownUidValidity = 900_001
        try db.write { try folder.insert($0) }
        var header = try TestDatabase.insertMessageHeader(
            db, messageId: "7", subject: "From the server", to: "alice@example.com",
            folderId: folder.id, accountId: Self.accountId, folderPath: "Drafts",
            isInInbox: false, rfc822MessageId: "server@example.com")
        header.observedUidValidity = 900_001
        try db.write { try header.update($0) }
        let address = try #require(try db.read { db in
            try ExternalDraftAdoption.adoptableAddress(db: db, header: header, runtimeKind: .imap)
        })
        let inserted = try db.write { db in
            try ExternalDraftAdoption.insertAdoptedDraft(
                db: db, header: header, address: address, runtimeKind: .imap,
                content: Self.content(body: "old local text", serverText: "copy: old local text"))
        }
        let draftId = try #require(inserted)
        let draft = try #require(try db.read { try Draft.fetchOne($0, key: draftId) })
        return (header, draft)
    }

    static func content(
        subject: String = "From the server", to: String = "alice@example.com", bcc: String = "",
        body: String, serverText: String
    ) -> ExternalDraftAdoption.ServerContent {
        ExternalDraftAdoption.ServerContent(
            subject: subject, to: to, cc: "", bcc: bcc, body: body, serverText: serverText,
            attachmentsDirName: nil, attachmentCount: 0)
    }

    private func reload(_ db: DatabaseQueue, decided: Draft) throws -> String?? {
        try db.write { db in
            try ExternalDraftAdoption.applyReload(
                db: db, decided: decided,
                content: Self.content(
                    subject: "Edited in another app", to: "alice@example.com, dave@example.com",
                    bcc: "erin@example.com", body: "server text", serverText: "copy: server text"))
        }
    }

    @Test("Reload replaces the row's content with the fetched copy, marks it clean and advances the version")
    func reloadReplacesContent() throws {
        let db = try TestDatabase.make()
        let (_, draft) = try makeAdoptedImapDraft(db)

        let written = try reload(db, decided: draft)

        #expect(written != nil, "the reload wrote nothing")
        let row = try #require(try db.read { try Draft.fetchOne($0, key: draft.id) })
        #expect(row.body == "server text")
        #expect(row.subject == "Edited in another app", "subject must come from the fetched copy")
        #expect(row.toArray == ["alice@example.com", "dave@example.com"])
        #expect(row.bccArray == ["erin@example.com"])
        #expect(row.serverPushStatus == "pushed", "a reloaded row holds no unsent edits")
        #expect(row.serverDraftText == "copy: server text",
                "the row's copy of the server text must be the copy it loaded")
        #expect(row.serverDraftId == "7", "the reload must keep the exact address")
        #expect(row.pushAttemptVersion > draft.pushAttemptVersion,
                "an upload started before the reload must retire at Stage A")
    }

    @Test("Reload writes nothing over a row that changed after it was compared", arguments: [
        "newer save", "overwrite", "generation", "status", "address",
    ])
    func reloadFailsClosed(change: String) throws {
        let db = try TestDatabase.make()
        let (_, decided) = try makeAdoptedImapDraft(db)
        try db.write { db in
            var row = try #require(try Draft.fetchOne(db, key: decided.id))
            switch change {
            case "newer save":
                row.body = "newest local edit"
                row.updatedAt += 1
                try DraftStore.applySave(row, db: db)
                return
            case "overwrite":
                // Changes only the row's copy of the server text and its version.
                _ = try DraftStore.rebaseOnServerText(
                    draftId: row.id, expectedInstanceEpoch: try #require(row.instanceEpoch),
                    serverText: "copy: newer server text", db: db)
                return
            case "generation": row.instanceEpoch = "another-generation"
            case "status": row.serverPushStatus = "dirty"
            default: row.serverDraftId = "9"
            }
            try row.update(db)
        }
        let before = try #require(try db.read { try Draft.fetchOne($0, key: decided.id) })

        #expect(try reload(db, decided: decided) == nil)

        let after = try #require(try db.read { try Draft.fetchOne($0, key: decided.id) })
        #expect(after.body == before.body && after.subject == before.subject
                && after.serverPushStatus == before.serverPushStatus
                && after.pushAttemptVersion == before.pushAttemptVersion,
                "a refused reload must leave the row untouched (\(change))")
    }

    @Test("Overwrite records the server's current text and keeps the edits")
    func overwriteRebases() throws {
        let db = try TestDatabase.make()
        let (_, draft) = try makeAdoptedImapDraft(db)
        let epoch = try #require(draft.instanceEpoch)

        #expect(try db.write { try DraftStore.rebaseOnServerText(
            draftId: draft.id, expectedInstanceEpoch: "other", serverText: "t9", db: $0) } == false)
        #expect(try db.write { try DraftStore.rebaseOnServerText(
            draftId: draft.id, expectedInstanceEpoch: epoch, serverText: "t9", db: $0) })

        let row = try db.read { try Draft.fetchOne($0, key: draft.id) }
        #expect(row?.serverDraftText == "t9")
        #expect(row?.serverDraftId == "7")
        #expect(row?.body == "old local text")
        #expect((row?.pushAttemptVersion ?? 0) > draft.pushAttemptVersion)
    }

    @Test("Save as new detaches the row from the other app's copy and keeps the edits")
    func saveAsNewDetaches() throws {
        let db = try TestDatabase.make()
        let (header, draft) = try makeAdoptedImapDraft(db)
        let epoch = try #require(draft.instanceEpoch)

        #expect(try db.write { try DraftStore.detachFromServerCopy(
            draftId: draft.id, expectedInstanceEpoch: epoch, db: $0) })

        let row = try #require(try db.read { try Draft.fetchOne($0, key: draft.id) })
        #expect(row.serverDraftId == nil && row.serverDraftFolderPath == nil
                && row.serverDraftUidValidity == nil && row.serverDraftText == nil)
        #expect(row.serverPushStatus == nil, "the next upload must create a new server draft")
        #expect(row.body == "old local text")
        #expect(row.pushAttemptVersion > draft.pushAttemptVersion,
                "an upload already past its check must not reattach the row to the other copy")
        #expect(try db.read { db in
            try LocallyAuthoredDraftOpenAuthority.resolve(db: db, header: header, runtimeKind: .imap)
        } == nil, "the other app's copy must be free to open (and be adopted) on its own")
    }

    @Test("Reload at Save drops the unsent edits so no upload pushes them")
    func reloadAtSaveDropsEdits() throws {
        let db = try TestDatabase.make()
        var (_, draft) = try makeAdoptedImapDraft(db)
        try db.write { db in
            draft.serverPushStatus = "dirty"
            try draft.update(db)
        }
        let epoch = try #require(draft.instanceEpoch)

        #expect(try db.write { try DraftStore.discardUnsentEditsForReload(
            draftId: draft.id, expectedInstanceEpoch: epoch, db: $0) })

        let row = try db.read { try Draft.fetchOne($0, key: draft.id) }
        #expect(row?.serverPushStatus == "pushed")
        #expect((row?.pushAttemptVersion ?? 0) > draft.pushAttemptVersion)
        #expect(row?.serverDraftText == "copy: old local text",
                "the copy must stay OLD so the next open sees the server copy changed and reloads")
    }
}

/// The upload. Uses an installed `DatabasePool` because `pushDraftToServer` reads
/// and writes through `AppDatabase.dbPool`.
@Suite("Draft upload never overwrites a changed server copy (#217)", .serialized, .processGlobalState)
@MainActor
struct DraftServerChangePushTests {
    private nonisolated static let accountId = "acc-outlook"

    private func withInstalledPool(
        _ body: (DatabasePool) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("draft-server-change-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("test.sqlite").path,
            configuration: configuration)
        let appDatabase = try AppDatabase(dbPool: pool)
        let previous = AppDatabase.shared.withLock { current -> AppDatabase? in
            let saved = current
            current = appDatabase
            return saved
        }
        defer {
            InstalledTestDatabaseLifetime.finish(previous: previous, pool: pool, directory: directory)
        }
        try await body(pool)
    }

    /// An Outlook draft at Graph id `g1` with unsent edits, whose copy of the server
    /// text is "as last saved".
    private func insertEditedOutlookDraft(_ pool: DatabasePool) async throws -> Draft {
        try await pool.write { db in
            var account = Account(
                emailAddress: "outlook@example.com", displayName: "Test", provider: .outlook)
            account.id = Self.accountId
            try account.insert(db)
            var draft = Draft(
                id: "adopted:test", accountId: Self.accountId,
                toJSON: Draft.encodeStringArray(["alice@example.com"]), ccJSON: "[]", bccJSON: "[]",
                subject: "Plan", body: "edited on this device", replyToId: nil, isForward: false,
                editHistoryJSON: nil, createdAt: 1, updatedAt: 2,
                serverDraftId: "g1", serverPushStatus: "dirty",
                rfc822MessageId: nil, attachmentsDirName: nil)
            draft.instanceEpoch = "E1"
            draft.serverDraftText = sentDraftText(
                subject: "Plan", to: ["alice@example.com"], body: Self.lastSaved)
            try draft.insert(db)
            return draft
        }
    }

    private nonisolated static let lastSaved = "as last saved"

    /// The server copy as Graph returns this draft: the body re-formatted as an HTML
    /// document, the recipient with a display name.
    private static func serverCopy(
        _ text: String, subject: String = "Plan", to: [String] = ["Alice <alice@example.com>"]
    ) -> FullMessageInfo {
        MockEmailProvider.draftCopy(
            subject: subject, to: to, cc: [],
            html: "<html><head><style>p{margin:0}</style></head><body><p>\(text)</p></body></html>")
    }

    private func push(_ provider: MockEmailProvider) async throws -> DraftStore.PushDisposition {
        try await DraftStore.shared.pushDraftToServer(
            draftId: "adopted:test", expectedInstanceEpoch: "E1", provider: provider,
            runtimeKind: .outlook, draftsFolderPath: "Drafts")
    }

    @Test("Changed elsewhere: the upload refuses and keeps the edits for the user to decide")
    func changedServerCopyIsNotOverwritten() async throws {
        try await withInstalledPool { pool in
            _ = try await insertEditedOutlookDraft(pool)
            let provider = MockEmailProvider(saveDraftResult: .created(.outlook(graphId: "g1")))
            await provider.setDraftCopy(.success(Self.serverCopy("rewritten in another app")))

            let result = try await push(provider)

            #expect(result == .serverChanged)
            #expect(await provider.callLog.contains { $0.hasPrefix("saveDraft") } == false,
                    "the upload overwrote a server copy another app changed")
            let row = try await pool.read { try Draft.fetchOne($0, key: "adopted:test") }
            #expect(row?.serverPushStatus == "dirty", "the edits must stay unsent, not be marked done")
            #expect(row?.body == "edited on this device")
            #expect(row?.serverDraftText == sentDraftText(
                subject: "Plan", to: ["alice@example.com"], body: Self.lastSaved))
        }
    }

    @Test("Recipients or subject changed elsewhere: the upload refuses too", arguments: [
        ("Plan", ["Alice <alice@example.com>", "dave@example.com"]),
        ("Plan (final)", ["Alice <alice@example.com>"]),
    ])
    func changedHeaderFieldsAreNotOverwritten(subject: String, to: [String]) async throws {
        try await withInstalledPool { pool in
            _ = try await insertEditedOutlookDraft(pool)
            let provider = MockEmailProvider(saveDraftResult: .created(.outlook(graphId: "g1")))
            await provider.setDraftCopy(.success(Self.serverCopy(Self.lastSaved, subject: subject, to: to)))

            #expect(try await push(provider) == .serverChanged)
            #expect(await provider.callLog.contains { $0.hasPrefix("saveDraft") } == false)
        }
    }

    @Test("Unchanged (only re-formatted): the upload replaces the copy and records what it sent")
    func unchangedServerCopyIsReplaced() async throws {
        try await withInstalledPool { pool in
            _ = try await insertEditedOutlookDraft(pool)
            let provider = MockEmailProvider(saveDraftResult: .created(.outlook(graphId: "g1")))
            await provider.setDraftCopy(.success(Self.serverCopy(Self.lastSaved)))

            let result = try await push(provider)

            #expect(result == .completed)
            #expect(await provider.callLog.contains {
                $0.contains("existingIdentity:Optional(TabMail.DraftDeleteIdentity.outlook(graphId: \"g1\"))")
            })
            let row = try await pool.read { try Draft.fetchOne($0, key: "adopted:test") }
            #expect(row?.serverPushStatus == "pushed")
            #expect(row?.serverDraftText == sentDraftText(
                subject: "Plan", to: ["alice@example.com"], body: "edited on this device"),
                    "the next check must compare against OUR write")
        }
    }

    @Test("Gone elsewhere: the upload saves the edits as a new draft")
    func goneServerCopyIsSavedAsNew() async throws {
        try await withInstalledPool { pool in
            _ = try await insertEditedOutlookDraft(pool)
            let provider = MockEmailProvider(saveDraftResult: .created(.outlook(graphId: "g2")))
            await provider.setDraftCopy(.success(nil))

            let result = try await push(provider)

            #expect(result == .completed)
            #expect(await provider.callLog.contains { $0.contains("saveDraft(existingIdentity:nil") },
                    "a vanished copy must not be addressed; the edits are saved as a new draft")
            let row = try await pool.read { try Draft.fetchOne($0, key: "adopted:test") }
            #expect(row?.serverDraftId == "g2")
            #expect(row?.serverDraftText == sentDraftText(
                subject: "Plan", to: ["alice@example.com"], body: "edited on this device"))
        }
    }

    @Test("A check that cannot run is an unknown: the upload retries and writes nothing")
    func failedCheckRetries() async throws {
        try await withInstalledPool { pool in
            _ = try await insertEditedOutlookDraft(pool)
            let provider = MockEmailProvider()
            await provider.setDraftCopy(.failure(URLError(.notConnectedToInternet)))

            await #expect(throws: URLError.self) { try await push(provider) }

            #expect(await provider.callLog.contains { $0.hasPrefix("saveDraft") } == false)
            let row = try await pool.read { try Draft.fetchOne($0, key: "adopted:test") }
            #expect(row?.serverPushStatus == "dirty", "the row must stay admissible for the retry")
        }
    }

    @Test("After Overwrite, the upload replaces the other app's version")
    func overwriteThenPushReplaces() async throws {
        try await withInstalledPool { pool in
            _ = try await insertEditedOutlookDraft(pool)
            let other = Self.serverCopy("rewritten in another app")
            _ = try await pool.write { try DraftStore.rebaseOnServerText(
                draftId: "adopted:test", expectedInstanceEpoch: "E1",
                serverText: DraftServerText.of(other), db: $0) }
            let provider = MockEmailProvider(saveDraftResult: .created(.outlook(graphId: "g1")))
            await provider.setDraftCopy(.success(other))

            #expect(try await push(provider) == .completed)
            #expect(await provider.callLog.contains {
                $0.contains("existingIdentity:Optional(TabMail.DraftDeleteIdentity.outlook(graphId: \"g1\"))")
            })
        }
    }

    @Test("After Save as new, the upload creates a new draft and leaves the other copy alone")
    func saveAsNewThenPushCreates() async throws {
        try await withInstalledPool { pool in
            _ = try await insertEditedOutlookDraft(pool)
            _ = try await pool.write { try DraftStore.detachFromServerCopy(
                draftId: "adopted:test", expectedInstanceEpoch: "E1", db: $0) }
            let provider = MockEmailProvider(saveDraftResult: .created(.outlook(graphId: "g2")))

            #expect(try await push(provider) == .completed)
            let calls = await provider.callLog
            #expect(calls.contains { $0.contains("saveDraft(existingIdentity:nil") })
            #expect(!calls.contains { $0.contains("g1") }, "the other app's copy was touched: \(calls)")
            #expect(await provider.fetchDraftCopyLog.isEmpty, "a detached row has nothing to check")
        }
    }

    @Test("After Reload at Save, no upload pushes the dropped edits")
    func reloadAtSaveThenPushDoesNothing() async throws {
        try await withInstalledPool { pool in
            _ = try await insertEditedOutlookDraft(pool)
            _ = try await pool.write { try DraftStore.discardUnsentEditsForReload(
                draftId: "adopted:test", expectedInstanceEpoch: "E1", db: $0) }
            let provider = MockEmailProvider()

            #expect(try await push(provider) == .notApplied)
            #expect(await provider.callLog.contains { $0.hasPrefix("saveDraft") } == false)
        }
    }
}

/// The provider reads themselves, against canned HTTP.
@Suite("Draft server copy reads (#217)")
struct DraftCopyReadTests {
    private static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test("Graph: the draft's current body is read, and 404 means gone")
    func graphCopy() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let received = ISO8601DateFormatter().string(from: Date())
        http.register(path: "/messages/g1", method: "GET", response: .json(raw: """
            {"id":"g1","subject":"Plan","from":{"emailAddress":{"address":"owner@example.com"}},
             "receivedDateTime":"\(received)","isRead":true,"hasAttachments":false,
             "body":{"contentType":"html","content":"<html><body><p>Meet on Monday</p></body></html>"}}
            """))
        // Reading a Graph message always lists its attachments too.
        http.register(path: "/messages/g1/attachments", method: "GET", response: .json(raw: #"{"value":[]}"#))
        http.register(path: "/messages/g404", method: "GET", response: .status(404))
        let provider = ExchangeProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

        let copy = try #require(try await provider.fetchDraftCopy(identity: .outlook(graphId: "g1")))
        #expect(DraftServerText.of(copy) == sentDraftText(
            subject: "Plan", to: [], body: "Meet on Monday"))
        #expect(try await provider.fetchDraftCopy(identity: .outlook(graphId: "g404")) == nil)
    }

    @Test("Graph: a server error is an unknown, never gone")
    func graphErrorThrows() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        http.register(path: "/messages/g1", method: "GET", response: .status(500))
        let provider = ExchangeProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

        await #expect(throws: (any Error).self) {
            try await provider.fetchDraftCopy(identity: .outlook(graphId: "g1"))
        }
    }

    @Test("Gmail: the message the draft currently wraps is read, and 404 means gone")
    func gmailCopy() async throws {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let internalDate = String(Int(Date().timeIntervalSince1970 * 1000))
        http.register(path: "/drafts/r1", method: "GET",
                      response: .json(raw: #"{"message":{"id":"m-5"}}"#))
        http.register(path: "/drafts/r404", method: "GET", response: .status(404))
        http.register(path: "/messages/m-5", method: "GET", response: .json(raw: """
            {"id":"m-5","internalDate":"\(internalDate)","labelIds":["DRAFT"],
             "payload":{"mimeType":"multipart/alternative",
               "headers":[{"name":"Subject","value":"Plan"},{"name":"From","value":"owner@example.com"}],
               "parts":[{"mimeType":"text/html","body":{"size":20,"data":"\(Self.base64URL("<div>Meet on Monday</div>"))"}}]}}
            """))
        let provider = GmailProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)

        let copy = try #require(try await provider.fetchDraftCopy(identity: .gmail(resourceId: "r1")))
        #expect(DraftServerText.of(copy) == sentDraftText(
            subject: "Plan", to: [], body: "Meet on Monday"))
        #expect(try await provider.fetchDraftCopy(identity: .gmail(resourceId: "r404")) == nil)
    }

    @Test("Providers refuse to read another provider's draft address")
    func foreignIdentityIsRefused() async {
        let http = FakeHTTP.Scenario()
        defer { http.close() }
        let gmail = GmailProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
        let graph = ExchangeProvider(
            userEmail: "owner@example.com", accessToken: { _ in "token" }, session: http.session)
        await #expect(throws: ProviderError.self) {
            try await gmail.fetchDraftCopy(identity: .outlook(graphId: "g1"))
        }
        await #expect(throws: ProviderError.self) {
            try await graph.fetchDraftCopy(identity: .gmail(resourceId: "r1"))
        }
        #expect(http.recordedCalls().isEmpty)
    }
}
