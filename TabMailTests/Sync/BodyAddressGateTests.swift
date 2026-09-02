/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// **THE INVARIANT: no body may be stored against a header whose address is still in flight.**
///
/// These pin the SYSTEM PROPERTY, not the guard's mechanism. A test asserting
/// "`BodyAddressGate.refusal` returned `.addressNotCorroborated`" would inherit the guard's own spec
/// and stay green on a broken system; these assert what the DATABASE ends up holding, which stays
/// meaningful however the refusal is implemented or wherever it is moved.
///
/// **The defect being pinned.** `AccountManager.optimisticMoveToFolder` rewrites a row's
/// `folderPath` to the destination but **leaves the primary key and `messageId` at their SOURCE
/// values**. Until `MessageHeaderRekey.finishMove` re-keys it, the row's address is
/// `(destination, SOURCE UID)` — and on IMAP each folder owns its own UID space, so that address
/// names a DIFFERENT message. `BackfillBodyQueue` selects exactly those rows
/// (`bodyComplete = 0 AND isInInbox = 0`), so the stranger's body was fetched and stored under the
/// moved message's content key, plus indexed into FTS. Present in shipped `v1.6.38`.
///
/// **Two-sidedness is deliberate and load-bearing.** The `writesBody…` cases exist so a "fix" that
/// simply refuses body fetches broadly cannot pass this suite. That is not hypothetical: rev A of
/// this gate keyed off `observedUidValidity == nil`, which ALSO matches rows that were merely never
/// stamped (the backfill-only-folder population) — messages that would then never load and never
/// recover. `writesBodyForNeverStampedRow` is the anchor that rejects that design.
@Suite("Body address gate — no body written against an in-flight address",
       .serialized, .processGlobalState)
struct BodyAddressGateTests {

    private static let strangerText = "stranger body - belongs to the OTHER message at this UID"

    private static func makeHeader(
        accountId: String, folderPath: String, uid: String, rfc822: String?,
        observedUidValidity: Int?, pool: DatabasePool
    ) throws -> MessageHeader {
        var header = MessageHeader(
            messageId: uid, subject: "message \(uid)", from: "Sender",
            fromAddress: "sender@example.com", to: "recipient@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000), snippet: "snippet",
            folderId: "\(accountId):\(folderPath)", accountId: accountId,
            folderPath: folderPath, isInInbox: folderPath == "INBOX")
        header.rfc822MessageId = rfc822
        header.observedUidValidity = observedUidValidity
        header.headerComplete = true
        try pool.write { db in try header.insert(db) }
        return header
    }

    /// Reproduces `optimisticMoveToFolder` exactly: the row is created in the SOURCE folder (so its
    /// primary key encodes INBOX), then `folderId`/`folderPath`/`isInInbox` are rewritten to the
    /// destination and the epoch nulled — **without touching the primary key or `messageId`**.
    private static func insertOptimisticallyMovedHeader(
        accountId: String, sourcePath: String, destinationPath: String, uid: String,
        rfc822: String?, pool: DatabasePool
    ) throws -> String {
        let header = try makeHeader(
            accountId: accountId, folderPath: sourcePath, uid: uid, rfc822: rfc822,
            observedUidValidity: 101, pool: pool)
        try pool.write { db in
            _ = try MessageHeader.filter(Column("id") == header.id).updateAll(db,
                Column("folderId").set(to: "\(accountId):\(destinationPath)"),
                Column("folderPath").set(to: destinationPath),
                Column("isInInbox").set(to: false),
                Column("observedUidValidity").set(to: nil as Int?))
        }
        return header.id
    }

    private static func fetchResult(
        headerId: String, accountId: String, folderPath: String, uid: String,
        fetchedRfc822: String?
    ) -> BodyFetchProcessor.FetchResult {
        let key = ContentKey(rawValue: headerId)
        return BodyFetchProcessor.FetchResult(
            item: BodyFetchProcessor.Item(
                headerId: headerId, accountId: accountId, folderPath: folderPath,
                messageId: uid, isInInbox: false),
            renderedBody: MessageBody.create(contentKey: key, htmlBody: "<p>\(strangerText)</p>"),
            plainText: strangerText,
            hasAttachments: false,
            hasUnresolvedICS: false,
            fetchedRfc822MessageId: fetchedRfc822)
    }

    /// What the server hands back for the fetched UID — the stranger's message, in the pre-render
    /// tests. `rfc822` is a parameter so the address half can be isolated with it nil.
    private static func strangerMessage(
        uid: String, rfc822: String?, inlineCid: String? = nil
    ) -> FullMessageInfo {
        // 1x1 PNG — real bytes, so `renderBody`'s inline-image writer actually materialises a file.
        let pngBytes = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let inline = inlineCid.map {
            [InlineImage(contentId: $0, contentType: "image/png", data: pngBytes)]
        } ?? []
        let html = inlineCid.map { "<p>\(strangerText)</p><img src=\"cid:\($0)\">" }
            ?? "<p>\(strangerText)</p>"
        return FullMessageInfo(
            header: MessageHeaderInfo(
                messageId: uid, rfc822MessageId: rfc822, inReplyTo: nil, references: [],
                threadId: nil, subject: "stranger \(uid)", from: "Stranger",
                fromAddress: "stranger@example.com", to: "recipient@example.com", cc: "", bcc: "",
                replyTo: nil, date: Date(timeIntervalSince1970: 1_700_000_000),
                snippet: strangerText, isRead: false, isFlagged: false, hasAttachments: false,
                isReplied: false, isForwarded: false, actionTag: nil),
            htmlBody: html,
            textBody: strangerText,
            inlineImages: inline)
    }

    /// Removes any asset folder left over from a PREVIOUS run of this suite.
    ///
    /// ⚠️ **Required, and it caught itself.** The asset store lives on the simulator's real
    /// filesystem and OUTLIVES the test process, while `insertOptimisticallyMovedHeader` mints a
    /// deterministic headerId — so a file written by an earlier run (in this case a deliberate
    /// red-proof run with the refusal moved after `renderBody`) is still on disk and makes the
    /// zero-file assertion fail against perfectly correct code. Fixture state that survives the
    /// process has to be cleared explicitly, not assumed empty.
    private static func clearAssets(headerId: String) {
        guard let dir = BodyAssetStore.folder(for: ContentKey(rawValue: headerId)) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Files actually materialised on disk under this row's asset folder.
    private static func assetFileCount(headerId: String) -> Int {
        guard let dir = BodyAssetStore.folder(for: ContentKey(rawValue: headerId)),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return 0 }
        return entries.count
    }

    private static func storedBody(_ pool: DatabasePool, headerId: String) throws -> MessageBody? {
        try pool.read { db in try MessageBody.fetchOne(db, key: headerId) }
    }

    private static func isRetry(_ result: BodyFetchProcessor.Result) -> Bool {
        if case .retry = result { return true }
        return false
    }

    private static func isSuccess(_ result: BodyFetchProcessor.Result) -> Bool {
        if case .success = result { return true }
        return false
    }

    private static func fixture(
        accountId: String, provider: AccountProvider
    ) throws -> (DatabasePool, URL, AppDatabase?) {
        let (pool, dir, previous) = try FolderEpochTestFixture.makeAppDB()
        _ = try FolderEpochTestFixture.makeAccount(id: accountId, provider: provider, pool: pool)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "INBOX", role: .inbox, pool: pool,
            lastKnownUidValidity: 101)
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive", role: .archive, pool: pool,
            lastKnownUidValidity: 202)
        return (pool, dir, previous)
    }

    // MARK: - The red proof

    /// **RED-FIRST on pre-fix code:** before `BodyAddressGate`, `process` wrote the stranger's body
    /// under the moved header's key, so `storedBody` was non-nil and carried `strangerText`.
    ///
    /// ⚠️ **The fetched `Message-ID` is nil ON PURPOSE — this test is the red proof for the ADDRESS
    /// half, and it must be able to fail when only that half is removed.** The first cut passed a
    /// *differing* stranger id here, which meant the identity half refused the write on its own and
    /// the test stayed green with the address check deleted: a confounded proof that would have
    /// certified an unguarded build. A nil on either side is an absence of evidence that
    /// `identityContradicts` deliberately does not act on, so with it nil the ONLY thing that can
    /// refuse is the address check. That is also the realistic worst case — `Message-ID` is a
    /// SHOULD, and the servers that omit it are exactly the ones where the identity backstop cannot
    /// help. (Found by audit.)
    @Test("A message mid-move never gets a body written — even with no Message-ID to corroborate")
    func refusesBodyForInFlightImapAddress() async throws {
        let accountId = "gate-imap"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .imap)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let headerId = try Self.insertOptimisticallyMovedHeader(
            accountId: accountId, sourcePath: "INBOX", destinationPath: "Archive",
            uid: "41", rfc822: "moved-message@example.com", pool: pool)

        let (result, processed) = await BodyFetchProcessor.process(
            fetchResult: Self.fetchResult(
                headerId: headerId, accountId: accountId, folderPath: "Archive", uid: "41",
                fetchedRfc822: nil),
            enableAI: false)

        #expect(Self.isRetry(result))
        #expect(processed == nil)
        #expect(try Self.storedBody(pool, headerId: headerId) == nil)
    }

    /// The nested-folder case the raw `hasPrefix` version was BLIND to: moving
    /// `Archive:Child` → `Archive` leaves the key `<acct>:Archive:Child:41`, which still satisfies
    /// the prefix `<acct>:Archive:`. Whole-key equality against the re-minted
    /// `MessageIdentity.headerId` is what refuses it. Fetched id nil for the same reason as above —
    /// the address half must carry this alone.
    @Test("A child-to-parent move is still detected as in flight")
    func refusesBodyForNestedFolderMove() async throws {
        let accountId = "gate-nested"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .imap)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        try FolderEpochTestFixture.insertFolder(
            accountId: accountId, path: "Archive:Child", role: .archive, pool: pool,
            lastKnownUidValidity: 303)
        let headerId = try Self.insertOptimisticallyMovedHeader(
            accountId: accountId, sourcePath: "Archive:Child", destinationPath: "Archive",
            uid: "41", rfc822: "nested-move@example.com", pool: pool)
        // Precisely the trap: the key DOES carry the destination's prefix.
        #expect(headerId.hasPrefix(MessageIdentity.headerIdPrefix(accountId: accountId, folderPath: "Archive")))

        let (result, processed) = await BodyFetchProcessor.process(
            fetchResult: Self.fetchResult(
                headerId: headerId, accountId: accountId, folderPath: "Archive", uid: "41",
                fetchedRfc822: nil),
            enableAI: false)

        #expect(Self.isRetry(result))
        #expect(processed == nil)
        #expect(try Self.storedBody(pool, headerId: headerId) == nil)
    }

    /// The provenance half. The row moved and moved BACK while the fetch was in flight (an undo
    /// annihilating an unattempted move restores `folderPath`), so the key agrees with the folder
    /// again and the address check is satisfied — but the bytes in hand were fetched against
    /// `Archive`, where a stranger lives at UID 41. Nil fetched id so only provenance can refuse.
    @Test("Bytes fetched against a folder the row has since left are never written")
    func refusesWhenFetchProvenanceDisagreesWithTheRow() async throws {
        let accountId = "gate-provenance"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .imap)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // Settled row, sitting in INBOX with an agreeing key.
        let header = try Self.makeHeader(
            accountId: accountId, folderPath: "INBOX", uid: "41",
            rfc822: "came-back@example.com", observedUidValidity: 101, pool: pool)

        // The in-flight fetch was issued against Archive/41 before the undo landed.
        let (result, processed) = await BodyFetchProcessor.process(
            fetchResult: Self.fetchResult(
                headerId: header.id, accountId: accountId, folderPath: "Archive", uid: "41",
                fetchedRfc822: nil),
            enableAI: false)

        #expect(Self.isRetry(result))
        #expect(processed == nil)
        #expect(try Self.storedBody(pool, headerId: header.id) == nil)
    }

    /// The identity half — (d). The address is settled, so the in-flight check passes; the message
    /// the server actually returned is a different one, and that alone must refuse.
    @Test("A settled address still refuses when the server returns a different message")
    func refusesWhenReturnedIdentityContradictsTheRow() async throws {
        let accountId = "gate-identity"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .imap)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let header = try Self.makeHeader(
            accountId: accountId, folderPath: "Archive", uid: "41",
            rfc822: "the-row-names-this@example.com", observedUidValidity: 202, pool: pool)

        let (result, _) = await BodyFetchProcessor.process(
            fetchResult: Self.fetchResult(
                headerId: header.id, accountId: accountId, folderPath: "Archive", uid: "41",
                fetchedRfc822: "but-the-server-returned-this@example.com"),
            enableAI: false)

        #expect(Self.isRetry(result))
        #expect(try Self.storedBody(pool, headerId: header.id) == nil)
    }

    // MARK: - Non-vacuity: the gate must NOT refuse the ordinary cases

    @Test("A settled IMAP address writes the body normally")
    func writesBodyWhenAddressIsSettled() async throws {
        let accountId = "gate-ok"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .imap)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let header = try Self.makeHeader(
            accountId: accountId, folderPath: "Archive", uid: "41",
            rfc822: "agreed@example.com", observedUidValidity: 202, pool: pool)

        let (result, processed) = await BodyFetchProcessor.process(
            fetchResult: Self.fetchResult(
                headerId: header.id, accountId: accountId, folderPath: "Archive", uid: "41",
                fetchedRfc822: "agreed@example.com"),
            enableAI: false)

        #expect(Self.isSuccess(result))
        #expect(processed != nil)
        #expect(try Self.storedBody(pool, headerId: header.id) != nil)
    }

    /// 🚨 **THE ANCHOR THAT REJECTS REV A.** A never-stamped row (nil `observedUidValidity`) whose
    /// address was never moved is perfectly fetchable. Gating on the nil epoch — rev A's design —
    /// would refuse this, and such messages would never load and never recover. This case is not
    /// hypothetical: `OversizedBodyQuarantineTests` exercises exactly this shape, and the
    /// backfill-only-folder population reaches a nil epoch by ordinary means.
    @Test("A never-stamped but never-moved row still writes its body")
    func writesBodyForNeverStampedRow() async throws {
        let accountId = "gate-unstamped"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .imap)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let header = try Self.makeHeader(
            accountId: accountId, folderPath: "Archive", uid: "41",
            rfc822: "never-stamped@example.com", observedUidValidity: nil, pool: pool)

        let (result, processed) = await BodyFetchProcessor.process(
            fetchResult: Self.fetchResult(
                headerId: header.id, accountId: accountId, folderPath: "Archive", uid: "41",
                fetchedRfc822: "never-stamped@example.com"),
            enableAI: false)

        #expect(Self.isSuccess(result))
        #expect(processed != nil)
        #expect(try Self.storedBody(pool, headerId: header.id) != nil)
    }

    /// Provider scoping, two-sided. A stale Graph/Gmail id MISSES rather than resolving to a
    /// stranger, so an in-flight row on those providers is not a wrong-message hazard.
    @Test("A provider without a reused UID space writes the body even mid-move")
    func writesBodyForProviderWithoutReusedUidSpace() async throws {
        let accountId = "gate-gmail"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .gmail)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let headerId = try Self.insertOptimisticallyMovedHeader(
            accountId: accountId, sourcePath: "INBOX", destinationPath: "Archive",
            uid: "gmail-id-41", rfc822: "gmail-msg@example.com", pool: pool)

        let (result, processed) = await BodyFetchProcessor.process(
            fetchResult: Self.fetchResult(
                headerId: headerId, accountId: accountId, folderPath: "Archive",
                uid: "gmail-id-41", fetchedRfc822: "gmail-msg@example.com"),
            enableAI: false)

        #expect(Self.isSuccess(result))
        #expect(processed != nil)
        #expect(try Self.storedBody(pool, headerId: headerId) != nil)
    }

    /// The OTHER side of scoping the identity backstop. On a provider whose stale addresses miss
    /// rather than resolve, a fetch by opaque id returns that id's message by construction, so a
    /// differing `Message-ID` is not evidence of a wrong-message write — it is a legitimate skew
    /// (a locally-minted draft id vs. the one the server assigned, say). Refusing here would be
    /// PERMANENT for such a row: it would never load and never recover, which is exactly the
    /// failure rev A was rejected for. So it must write.
    @Test("A differing Message-ID does not refuse on a provider without a reused id space")
    func writesBodyDespiteIdentitySkewOnNonReusedIdSpace() async throws {
        let accountId = "gate-skew"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .outlook)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let header = try Self.makeHeader(
            accountId: accountId, folderPath: "Archive", uid: "graph-id-41",
            rfc822: "locally-minted@example.com", observedUidValidity: nil, pool: pool)

        let (result, processed) = await BodyFetchProcessor.process(
            fetchResult: Self.fetchResult(
                headerId: header.id, accountId: accountId, folderPath: "Archive",
                uid: "graph-id-41", fetchedRfc822: "server-assigned@example.com"),
            enableAI: false)

        #expect(Self.isSuccess(result))
        #expect(processed != nil)
        #expect(try Self.storedBody(pool, headerId: header.id) != nil)
    }

    /// A missing `Message-ID` on either side is an ABSENCE OF EVIDENCE, not a contradiction.
    /// RFC 5322 makes the header a SHOULD, not a MUST — refusing on nil would reject legitimate
    /// mail from every server that omits it, a far larger population than the hazard.
    @Test("A missing Message-ID on either side does not refuse")
    func nilIdentityOnEitherSideDoesNotRefuse() async throws {
        let accountId = "gate-nil-rfc"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .imap)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let header = try Self.makeHeader(
            accountId: accountId, folderPath: "Archive", uid: "41",
            rfc822: nil, observedUidValidity: 202, pool: pool)

        let (result, _) = await BodyFetchProcessor.process(
            fetchResult: Self.fetchResult(
                headerId: header.id, accountId: accountId, folderPath: "Archive", uid: "41",
                fetchedRfc822: "server-supplied@example.com"),
            enableAI: false)

        #expect(Self.isSuccess(result))
        #expect(try Self.storedBody(pool, headerId: header.id) != nil)
    }

    // MARK: - The refusal must happen BEFORE render, not only at the write

    /// 🚨 **Every other database-level test here calls `process` with an ALREADY-RENDERED
    /// `FetchResult`, so deleting both pre-render checks left this whole suite green** — while
    /// restoring the durable inline-image writes they exist to prevent (`renderBody` builds
    /// `BodyAssetStore.makeInlineImageWriter(forContentKey:)` keyed by THIS row, so a refused
    /// render still publishes the stranger's images under the victim's content key, and the
    /// write-time refusal cannot undo a file). These two pin the pre-render gate through the
    /// observable outcome of the function that would do the rendering. (Found by audit.)
    @Test("An in-flight address is refused before the body is ever rendered")
    func refusesBeforeRender() async throws {
        let accountId = "gate-prerender"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .imap)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let headerId = try Self.insertOptimisticallyMovedHeader(
            accountId: accountId, sourcePath: "INBOX", destinationPath: "Archive",
            uid: "41", rfc822: "moved-message@example.com", pool: pool)
        Self.clearAssets(headerId: headerId)

        let result = await BodyFetchProcessor.renderFetched(
            item: BodyFetchProcessor.Item(
                headerId: headerId, accountId: accountId, folderPath: "Archive",
                messageId: "41", isInInbox: false),
            fullMessage: Self.strangerMessage(uid: "41", rfc822: nil, inlineCid: "img@stranger"))

        guard case .failure(let outcome) = result else {
            Issue.record("render must be refused for an in-flight address, got success")
            return
        }
        #expect(Self.isRetry(outcome))
        // 🚨 THE ORDERING ASSERTION — the whole point of this gate being PRE-render. Returning
        // `.retry` proves only that a refusal happened somewhere; moving the check to AFTER
        // `renderBody` would keep the line above green while the stranger's image bytes landed
        // durably under the victim's content key, where the write-time refusal cannot reach them.
        // Zero files on disk is what proves the refusal came FIRST.
        #expect(
            Self.assetFileCount(headerId: headerId) == 0,
            "a refused render must not have persisted any inline-image bytes under this row's content key")
    }

    /// The non-vacuity control: the SAME call on a settled row must render. Without this, the test
    /// above would also pass against a build whose `renderFetched` refused everything.
    @Test("A settled address still renders normally")
    func rendersWhenAddressIsSettled() async throws {
        let accountId = "gate-prerender-ok"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .imap)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let header = try Self.makeHeader(
            accountId: accountId, folderPath: "Archive", uid: "41",
            rfc822: "settled@example.com", observedUidValidity: 202, pool: pool)
        Self.clearAssets(headerId: header.id)

        let result = await BodyFetchProcessor.renderFetched(
            item: BodyFetchProcessor.Item(
                headerId: header.id, accountId: accountId, folderPath: "Archive",
                messageId: "41", isInInbox: false),
            fullMessage: Self.strangerMessage(
                uid: "41", rfc822: "settled@example.com", inlineCid: "img@settled"))

        guard case .success(let fetchResult) = result else {
            Issue.record("a settled address must render")
            return
        }
        #expect(fetchResult.plainText?.isEmpty == false)
        // NON-VACUITY FOR THE ASSERTION ABOVE: the inline-image writer really does materialise a
        // file on this path. Without this, "zero files" in the refused case would also pass against
        // a build where the writer never ran at all, and the ordering assertion would prove nothing.
        #expect(
            Self.assetFileCount(headerId: header.id) > 0,
            "the settled control must actually write inline-image bytes — otherwise the refused case's zero-file assertion is vacuous")
        // This is the ONLY test here that leaves bytes behind, and `BodyAssetStore` writes to the
        // simulator's real filesystem — it outlives the test process. The header ids are
        // deterministic, so a leftover file from a previous run is indistinguishable from one this
        // run wrote. That is not hypothetical: it made a red-proof of the refusal path fail against
        // CORRECT code during this change's own development. The `clearAssets` calls at test START
        // are what make the zero-file assertions meaningful; this one keeps the store clean for
        // everything downstream.
        Self.clearAssets(headerId: header.id)
    }

    // MARK: - The refusal must happen BEFORE the network fetch

    /// 🚨 **Pins the PRE-FETCH refusal, which nothing else can see.** Deleting it leaves every
    /// other test green: `fetch` would simply proceed to the network, come back, and be refused by
    /// the pre-render check instead — same `.retry`, same zero assets, same database. The ONLY
    /// observable difference is whether the provider was asked at all, so the provider's `callLog`
    /// is the assertion. That difference is the entire point: a refused row keeps
    /// `bodyComplete = 0`, so the queues re-admit it every cycle, and without this check each of
    /// those cycles paid a full IMAP round trip that was guaranteed to be refused. (Found by audit.)
    @Test("An in-flight address is refused before the provider is ever asked")
    func refusesBeforeNetworkFetch() async throws {
        let accountId = "gate-prefetch"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .imap)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let headerId = try Self.insertOptimisticallyMovedHeader(
            accountId: accountId, sourcePath: "INBOX", destinationPath: "Archive",
            uid: "41", rfc822: "moved-message@example.com", pool: pool)

        let provider = MockEmailProvider()
        await provider.setFetchMessageResult(Self.strangerMessage(uid: "41", rfc822: nil))

        let result = await BodyFetchProcessor.fetch(
            item: BodyFetchProcessor.Item(
                headerId: headerId, accountId: accountId, folderPath: "Archive",
                messageId: "41", isInInbox: false),
            provider: provider)

        guard case .failure(let outcome) = result else {
            Issue.record("fetch must be refused for an in-flight address, got success")
            return
        }
        #expect(Self.isRetry(outcome))
        let log = await provider.callLog
        #expect(
            log.contains(where: { $0.hasPrefix("fetchMessage(") }) == false,
            "the provider must never be asked for a message whose address is in flight — that round trip is guaranteed to be refused")
    }

    /// Non-vacuity for the assertion above: on a settled row the SAME call really does reach the
    /// provider. Without this, "the provider was not asked" would also pass against a build whose
    /// `fetch` never asked anyone.
    @Test("A settled address does reach the provider")
    func settledAddressReachesProvider() async throws {
        let accountId = "gate-prefetch-ok"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .imap)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let header = try Self.makeHeader(
            accountId: accountId, folderPath: "Archive", uid: "41",
            rfc822: "settled@example.com", observedUidValidity: 202, pool: pool)

        let provider = MockEmailProvider()
        await provider.setFetchMessageResult(
            Self.strangerMessage(uid: "41", rfc822: "settled@example.com"))

        _ = await BodyFetchProcessor.fetch(
            item: BodyFetchProcessor.Item(
                headerId: header.id, accountId: accountId, folderPath: "Archive",
                messageId: "41", isInInbox: false),
            provider: provider)

        let log = await provider.callLog
        #expect(log.contains(where: { $0.hasPrefix("fetchMessage(") }))
    }

    /// 🚨 **Pins `fetch`'s OWN pre-render check — the batch producer's test cannot reach it.**
    /// `refusesBeforeRender` exercises `renderFetched`; `fetch` carries a SEPARATE pre-render check,
    /// and deleting only that one leaves the whole suite green: the pre-fetch check passes (the row
    /// is settled when the fetch starts), the row moves while the fetch is on the wire, `fetch`
    /// renders and persists the stranger's inline image, and `process` still returns `.retry`. Two
    /// producers, two checks, two tests — a guard duplicated across producers needs pinning at each
    /// one. (Found by audit.)
    ///
    /// The move lands INSIDE the provider call via `setFetchMessageHook`, which is the only way to
    /// hit a window that opens after the network returns and closes before the render.
    @Test("A move landing during the fetch is refused before that fetch is rendered")
    func refusesBeforeRenderWhenMoveLandsDuringFetch() async throws {
        let accountId = "gate-midfetch"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .imap)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        // Settled at the moment the fetch starts, so the PRE-FETCH check passes.
        let header = try Self.makeHeader(
            accountId: accountId, folderPath: "INBOX", uid: "41",
            rfc822: "mid-fetch@example.com", observedUidValidity: 101, pool: pool)
        Self.clearAssets(headerId: header.id)

        let provider = MockEmailProvider()
        await provider.setFetchMessageResult(
            Self.strangerMessage(uid: "41", rfc822: nil, inlineCid: "img@midfetch"))
        // The optimistic move lands while the fetch is on the wire: folderPath moves to Archive
        // while the primary key and messageId stay at their INBOX values.
        await provider.setFetchMessageHook {
            try? await pool.write { db in
                _ = try MessageHeader.filter(Column("id") == header.id).updateAll(db,
                    Column("folderId").set(to: "\(accountId):Archive"),
                    Column("folderPath").set(to: "Archive"),
                    Column("isInInbox").set(to: false),
                    Column("observedUidValidity").set(to: nil as Int?))
            }
        }

        let result = await BodyFetchProcessor.fetch(
            item: BodyFetchProcessor.Item(
                headerId: header.id, accountId: accountId, folderPath: "INBOX",
                messageId: "41", isInInbox: true),
            provider: provider)

        guard case .failure(let outcome) = result else {
            Issue.record("a move landing during the fetch must be refused before render")
            return
        }
        #expect(Self.isRetry(outcome))
        // The provider WAS asked (pre-fetch passed) — so this proves the LATER check fired...
        let log = await provider.callLog
        #expect(log.contains(where: { $0.hasPrefix("fetchMessage(") }))
        // ...and that it fired before the render, which is what stops the durable asset write.
        #expect(
            Self.assetFileCount(headerId: header.id) == 0,
            "the refusal must land before renderBody persists the stranger's inline image")
    }

    // MARK: - Unit-level coverage of the predicate itself

    @Test("In-flight detection re-mints the row's key and compares it whole")
    func inFlightDetection() {
        // Settled: the key is exactly what the row's own fields re-mint to.
        #expect(!BodyAddressGate.addressIsInFlight(
            id: "acc:Archive:41", accountId: "acc", folderPath: "Archive", messageId: "41"))
        // Mid-move: the key still encodes INBOX while the row claims Archive.
        #expect(BodyAddressGate.addressIsInFlight(
            id: "acc:INBOX:41", accountId: "acc", folderPath: "Archive", messageId: "41"))
        // 🚨 THE CASE A RAW `hasPrefix` IS BLIND TO. A child→parent move leaves a key that still
        // carries the destination's prefix (`acc:Archive:` prefixes `acc:Archive:Child:41`), so the
        // prefix form called this settled and would have written the stranger's body.
        #expect(BodyAddressGate.addressIsInFlight(
            id: "acc:Archive:Child:41", accountId: "acc", folderPath: "Archive", messageId: "41"))
        // 🚨 THE CASE `headerIdBelongsToFolder` WOULD GET WRONG THE OTHER WAY. Its no-deeper-colon
        // clause reads a messageId containing ':' as not belonging — and reply-draft header ids
        // carry that extra colon (a live v3 quirk), so those rows would be refused permanently.
        // Re-minting is exact: the colon is just data on both sides.
        #expect(!BodyAddressGate.addressIsInFlight(
            id: "acc:Drafts:local:99", accountId: "acc", folderPath: "Drafts", messageId: "local:99"))
        // A folder path containing ':' is likewise compared, never parsed.
        #expect(!BodyAddressGate.addressIsInFlight(
            id: "acc:Odd:Path:41", accountId: "acc", folderPath: "Odd:Path", messageId: "41"))
        // A folder whose name merely PREFIXES another must not be treated as settled.
        #expect(BodyAddressGate.addressIsInFlight(
            id: "acc:Arch:41", accountId: "acc", folderPath: "Archive", messageId: "41"))
    }

    @Test("The address predicate is scoped to reused-UID-space providers")
    func addressPredicateProviderScoping() {
        #expect(BodyAddressGate.addressCanResolveToAnotherMessage(provider: .imap, accountId: "a"))
        #expect(BodyAddressGate.addressCanResolveToAnotherMessage(provider: .icloud, accountId: "a"))
        #expect(!BodyAddressGate.addressCanResolveToAnotherMessage(provider: .gmail, accountId: "a"))
        // The Demo account is stored as IMAP but served by DemoProvider — no wire, no UID reuse.
        #expect(!BodyAddressGate.addressCanResolveToAnotherMessage(
            provider: .imap, accountId: DemoSeed.demoAccountId))
    }

    @Test("The identity check fires only when both ids are present and differ")
    func identityContradictionIsTwoSided() {
        #expect(BodyAddressGate.identityContradicts(stored: "a@example.com", fetched: "b@example.com"))
        #expect(!BodyAddressGate.identityContradicts(stored: "a@example.com", fetched: "a@example.com"))
        #expect(!BodyAddressGate.identityContradicts(stored: nil, fetched: "b@example.com"))
        #expect(!BodyAddressGate.identityContradicts(stored: "a@example.com", fetched: nil))
        #expect(!BodyAddressGate.identityContradicts(stored: "", fetched: "b@example.com"))
        // Angle-bracket forms normalize to the same identity, not a contradiction.
        #expect(!BodyAddressGate.identityContradicts(
            stored: "a@example.com", fetched: "<a@example.com>"))
    }

    // MARK: - The sibling reader: attachments

    /// 🚨 **The SAME defect class, in the reader next door.** `AccountManager.fetchAttachment`
    /// addresses the wire by `(message.folderPath, message.messageId)` — the exact pair
    /// `optimisticMoveToFolder` leaves inconsistent — so mid-move it returns a STRANGER's
    /// attachment. `AttachmentListView.downloadAndPreview` then previews those bytes AND caches
    /// them via `BodyAssetStore.writeAttachment` under `ContentKey(message.id)`, stamped with the
    /// victim row's own identity from `AttachmentCacheIdentity.stamp(for:)` — so the wrong bytes
    /// carry the right proof and every later read accepts them. Unlike the body path there is no
    /// authoritative downstream refusal to catch it.
    ///
    /// **Why this asserts the BLOCK DECISION rather than a wire outcome.** `fetchAttachment` is
    /// coupled to the singleton's `providers`/`workQueues` dictionaries and is not reachable in a
    /// unit test (see the note atop `AccountManagerFetchTests`). The decision function is the whole
    /// of the guard, and the property that matters is its DIRECTION.
    ///
    /// ⚠️ **The third case is the one that must never silently flip.** The body sibling,
    /// `bodyFetchIsBlockedByPendingAddress`, deliberately fails OPEN — correct there, because
    /// `BodyFetchProcessor.process` refuses again at write time. Copying that direction here would
    /// be a fail-open seam feeding a guard, which is fail-dangerous
    /// (`feedback_port_safe_only_if_consumer_direction_same`). An unverifiable identity must REFUSE.
    @Test("An attachment fetch is refused mid-move, and refused when identity cannot be verified")
    @MainActor
    func attachmentFetchIsBlockedForInFlightAddress() async throws {
        let accountId = "gate-attach"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .imap)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }
        let manager = AccountManager.shared

        // (1) IN FLIGHT — the row still carries the SOURCE UID at the destination folder.
        let moved = try Self.insertOptimisticallyMovedHeader(
            accountId: accountId, sourcePath: "INBOX", destinationPath: "Archive",
            uid: "41", rfc822: "victim@example.com", pool: pool)
        let movedHeader = try await pool.read { db in try MessageHeader.fetchOne(db, key: moved) }
        #expect(movedHeader != nil)
        guard let movedHeader else { return }
        let inFlightBlocked = await manager.attachmentFetchIsBlockedByPendingAddress(for: movedHeader)
        #expect(
            inFlightBlocked,
            "an in-flight address must never reach the wire — it names a different message")

        // (2) SETTLED — the non-vacuity control. Without this a guard that refuses everything
        //     would pass, and the user could never open any attachment.
        let settled = try Self.makeHeader(
            accountId: accountId, folderPath: "Archive", uid: "77",
            rfc822: "settled@example.com", observedUidValidity: 202, pool: pool)
        let settledBlocked = await manager.attachmentFetchIsBlockedByPendingAddress(for: settled)
        #expect(
            !settledBlocked,
            "a settled address must fetch normally — refusing it drops a user intention")

        // (3) UNVERIFIABLE — the account row is gone, so the provider cannot be determined.
        //     This is the direction that distinguishes a guard from a pre-filter.
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
        }
        let unverifiableBlocked = await manager.attachmentFetchIsBlockedByPendingAddress(for: settled)
        #expect(
            unverifiableBlocked,
            "an identity that cannot be verified must FAIL CLOSED — this guard has no backstop")
    }

    /// 🚨 **Pins the CLASSIFICATION that two callers depend on.** `ProviderError.addressPendingMove`
    /// is deterministic and pre-wire: retrying the same stale value cannot succeed, and the
    /// connection is fine. Two consequences ride on that:
    ///   - `AccountManager.fetchAttachment`'s own `for attempt in 1...2` loop retries only when
    ///     `SyncEngine.isConnectionError` is true, so misclassifying this would spend a pointless
    ///     second attempt on a refusal that cannot change.
    ///   - `AttachmentListView` renders "Download failed. Check your connection and try again." for
    ///     connection errors, which would send the user to diagnose their network for a refusal
    ///     that has nothing to do with it, and would bury the actual instruction (reopen the
    ///     message) that does recover.
    ///
    /// The `notConnected` case is the two-sided control: it proves the predicate is live and that a
    /// `false` here means something, rather than the predicate simply never firing. (Found by audit.)
    /// 🚨 **THE PRODUCER SIDE of the case the test above classifies.** Both halves were green
    /// while the contract between them was untested: `addressPendingMoveIsNotAConnectionError`
    /// CONSTRUCTS a `ProviderError.addressPendingMove` by hand and asserts how it is classified,
    /// and `attachmentFetchIsBlockedForInFlightAddress` asserts the PREDICATE
    /// `attachmentFetchIsBlockedByPendingAddress` returns `true` — but nothing ran the funnel and
    /// checked WHICH error comes out of it.
    ///
    /// That gap is load-bearing here specifically. This refusal used to be
    /// `NSError(domain: "TabMail", code: -3)` wrapped in `ProviderError.networkError`, and it was
    /// changed to the typed case so the body and attachment refusals cannot drift apart and a
    /// single `case ProviderError.addressPendingMove` match works against either. Restore the old
    /// NSError at this throw site and every existing test in this suite stays green — while
    /// `SyncEngine.isConnectionError` starts returning `true` for it, which sends
    /// `fetchAttachment`'s `for attempt in 1...2` loop into a pointless second attempt and tells
    /// the user to check their network for a refusal that has nothing to do with it.
    /// (`feedback_validation_needs_a_producer_side_test`: both halves green, contract dead.)
    ///
    /// Non-vacuity is two-sided IN THE SAME RUN: both calls must fail, so the assertion is about
    /// WHICH failure. A gate that refused everything would fail the settled half; a gate that
    /// refused nothing would fail the mid-move half. What keeps the settled half off the wire is
    /// that `Self.fixture`'s account carries no `imapHost`, so `AccountManager.createIMAPProvider`
    /// throws `authenticationFailed` before any provider is constructed or registered — NOT the
    /// absence of a registered provider, which is what causes `connectAccount` to be called in the
    /// first place. Asserted below rather than assumed. (Found by audit.)
    @Test("The body funnel throws the typed pending-move case in the mid-move window, and only there")
    func funnelThrowsTypedPendingMoveInTheMidMoveWindow() async throws {
        let accountId = "gate-funnel-typed"
        let (pool, dir, previous) = try Self.fixture(accountId: accountId, provider: .imap)
        defer {
            AppDatabase.shared.withLock { $0 = previous }
            TestDatabaseTeardown.retire(pool: pool, directory: dir)
        }

        // (1) MID-MOVE. The row's PK still encodes the SOURCE folder while its columns name the
        //     destination — the window `optimisticMoveToFolder` opens and `finishMove` closes.
        let movedId = try Self.insertOptimisticallyMovedHeader(
            accountId: accountId, sourcePath: "INBOX", destinationPath: "Archive",
            uid: "41", rfc822: "victim@example.com", pool: pool)
        let moved = try #require(try await pool.read { db in
            try MessageHeader.fetchOne(db, key: movedId)
        })
        // Fixture self-check: assert the row really is in the window this test is about, so the
        // test cannot quietly stop reproducing it if the helper changes.
        #expect(
            BodyAddressGate.addressIsInFlight(
                id: moved.id, accountId: moved.accountId,
                folderPath: moved.folderPath, messageId: moved.messageId),
            "fixture check: the row must be inside the mid-move window")

        var pendingMoveId: String?
        var unexpected: Error?
        do {
            try await AccountManager.shared.fetchBody(for: moved)
            Issue.record("the funnel must refuse a mid-move address before it reaches the wire")
        } catch let ProviderError.addressPendingMove(id) {
            pendingMoveId = id
        } catch {
            unexpected = error
        }
        #expect(
            pendingMoveId == moved.id,
            "the funnel must throw the TYPED pending-move case carrying this row's id, not a wrapped NSError; got \(unexpected.map { "\($0)" } ?? "no throw")")

        // (2) SETTLED — the control, same fixture. This one must fail for some OTHER reason:
        //     reaching provider resolution is proof the gate let it past.
        let acct = try #require(try await pool.read { db in try Account.fetchOne(db, key: accountId) })
        #expect(acct.imapHost == nil,
                "fixture precondition: without this the settled control would attempt a live connection")
        let settled = try Self.makeHeader(
            accountId: accountId, folderPath: "Archive", uid: "77",
            rfc822: "settled@example.com", observedUidValidity: 202, pool: pool)
        var settledThrewPendingMove = false
        do {
            try await AccountManager.shared.fetchBody(for: settled)
        } catch is CancellationError {
            // not the case under test
        } catch let ProviderError.addressPendingMove(id) {
            settledThrewPendingMove = true
            Issue.record("a settled address must not be refused as mid-move (id: \(id))")
        } catch {
            // Expected: provider resolution or the fetch itself fails. Anything that is not
            // `addressPendingMove` proves the gate did not fire.
        }
        #expect(
            !settledThrewPendingMove,
            "refusing a settled address as mid-move would make every body permanently unfetchable")
    }

    @Test("A pending-move refusal is not a connection error")
    func addressPendingMoveIsNotAConnectionError() {
        #expect(!SyncEngine.isConnectionError(ProviderError.addressPendingMove("acct:INBOX:41")))
        #expect(SyncEngine.isConnectionError(ProviderError.notConnected))
        // The user-facing text must name the gesture that actually recovers. A bare "try again"
        // is wrong here: an open view keeps the pre-move header in memory, so re-tapping resubmits
        // the same stale address. See `IOS-BODY-005`.
        let text = ProviderError.addressPendingMove("acct:INBOX:41").errorDescription ?? ""
        #expect(text.localizedCaseInsensitiveContains("open it again"))
    }
}
