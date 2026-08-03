/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - T4 — OutboxMessage.loadAttachments classifies `.meta` sidecars correctly
//
// Invariant under test (Outbox Reliability Rule 5, on the SEND path): the
// message that leaves carries EVERY attachment the user attached, or it does
// not leave at all. `OutboxMessage.saveAttachments` stores an attachment
// literally named `settings.meta` as data `0_settings.meta` with its own
// sidecar `0_settings.meta.meta`; the old naive `!hasSuffix(".meta")` filter
// classified BOTH as sidecars and silently dropped the attachment, so the email
// was SENT without it. The classification is now: a `.meta` file is a metadata
// SIDECAR iff its base (name minus ".meta") is a present file; a `.meta` DATA
// file whose own sidecar is absent is indistinguishable from a lost-data orphan
// and FAILS CLOSED.
//
// PORT — `v2final:TabMail/Models/OutboxMessage.swift`'s `loadAttachments()`
// (classification fixed in commit `6c4f973`, carried in `d2f0c96a3`), and the
// same six lines T4.D1 ported into `DraftAttachmentStorage.loadAttachments`.
// The two functions must classify identically: a file that round-trips as a
// draft must not vanish on send.

@Suite("Outbox attachment .meta classification")
struct OutboxAttachmentMetaClassificationTests {

    /// Run `body`, returning the `DraftAttachmentLoadError` it threw, or nil if it
    /// did not throw one. Lets a test pin the EXACT failure mode instead of only
    /// "some error".
    private func loadError(_ body: () throws -> [DraftAttachment]) -> DraftAttachmentLoadError? {
        do {
            _ = try body()
            return nil
        } catch let error as DraftAttachmentLoadError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - The data-loss case (red on the naive filter)

    @Test("An attachment literally named *.meta survives a send-path round-trip through the outbox")
    func literalMetaAttachmentSurvivesSendRoundTrip() throws {
        // `settings.meta` is a REAL attachment whose name ends in ".meta". The
        // production writer stores it as data `0_settings.meta` + its own sidecar
        // `0_settings.meta.meta`.
        let attachments = [
            DraftAttachment(filename: "settings.meta", mimeType: "application/octet-stream",
                            data: Data("settings-payload".utf8)),
            DraftAttachment(filename: "report.pdf", mimeType: "application/pdf",
                            data: Data("report-payload".utf8))
        ]
        let draft = DraftMessage(to: ["recipient@example.com"], subject: "meta name",
                                 body: "body", attachments: attachments)
        let outbox = OutboxMessage(accountId: "acct-outbox-meta", draft: draft)
        // The PRODUCTION staging call, exactly as the queue-send path makes it.
        try OutboxMessage.saveAttachments(attachments, dirName: outbox.id)
        defer { outbox.deleteAttachments() }

        // Both files and both sidecars are on disk — the writer's own layout is
        // what makes the naive filter ambiguous, so pin it.
        let dir = try #require(outbox.attachmentsDir)
        let onDisk = Set(try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent))
        #expect(onDisk.contains("0_settings.meta"))
        #expect(onDisk.contains("0_settings.meta.meta"))

        // THE INVARIANT: the payload the send path actually hands the provider
        // carries every attachment, byte for byte. `toDraftMessage()` is the
        // function the drain calls, so assert the end state there — not merely on
        // the loader.
        let payload = try outbox.toDraftMessage()
        #expect(payload.attachments.count == attachments.count)
        guard payload.attachments.count == attachments.count else { return }
        #expect(payload.attachments.map(\.filename).sorted() == ["report.pdf", "settings.meta"])
        let byName = Dictionary(uniqueKeysWithValues: payload.attachments.map { ($0.filename, $0) })
        #expect(byName["settings.meta"]?.data == Data("settings-payload".utf8))
        #expect(byName["settings.meta"]?.mimeType == "application/octet-stream")
        #expect(byName["report.pdf"]?.data == Data("report-payload".utf8))
        #expect(byName["report.pdf"]?.mimeType == "application/pdf")
    }

    // MARK: - The fail-closed case (the classification must not become a hole)

    @Test("An orphaned .meta with no data sibling fails the send closed instead of sending a subset")
    func orphanedMetaFailsSendClosed() throws {
        let attachments = [
            DraftAttachment(filename: "report.pdf", mimeType: "application/pdf",
                            data: Data("report-payload".utf8))
        ]
        let draft = DraftMessage(to: ["recipient@example.com"], subject: "orphan meta",
                                 body: "body", attachments: attachments)
        let outbox = OutboxMessage(accountId: "acct-outbox-orphan", draft: draft)
        try OutboxMessage.saveAttachments(attachments, dirName: outbox.id)
        defer { outbox.deleteAttachments() }

        // The data file of a SECOND attachment was lost; only its sidecar remains.
        // `1_lost.pdf.meta` has no base (`1_lost.pdf` absent) so it is not a
        // sidecar, and it has no sidecar of its own (`1_lost.pdf.meta.meta`
        // absent) — indistinguishable from a real attachment named `lost.pdf.meta`
        // whose sidecar is gone.
        let dir = try #require(outbox.attachmentsDir)
        try "application/pdf".write(to: dir.appendingPathComponent("1_lost.pdf.meta"),
                                    atomically: true, encoding: .utf8)

        // THE INVARIANT: the send fails rather than delivering the readable
        // subset. Never send an email with missing attachments.
        let error = loadError { try outbox.loadAttachments() }
        guard case .ambiguousMetaFilename(let name)? = error else {
            Issue.record("expected ambiguousMetaFilename, got \(String(describing: error))")
            return
        }
        #expect(name == "1_lost.pdf.meta")
        // The same failure must reach the send payload builder — the drain must
        // not be able to route around the loader.
        #expect(throws: DraftAttachmentLoadError.self) { try outbox.toDraftMessage() }
    }

    // MARK: - Draft ↔ outbox parity

    @Test("Draft and outbox storage classify a literal *.meta attachment identically")
    func draftAndOutboxClassifyMetaIdentically() throws {
        let attachments = [
            DraftAttachment(filename: "settings.meta", mimeType: "application/octet-stream",
                            data: Data("settings-payload".utf8))
        ]
        // Draft side, in an isolated root (that storage has a `root:` test seam).
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutboxMetaParity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try DraftAttachmentStorage.saveAttachments(attachments, dirName: "d1", root: root)
        let draftLoaded = try DraftAttachmentStorage.loadAttachments(dirName: "d1", root: root)

        // Outbox side, through the production base dir.
        let draft = DraftMessage(to: ["recipient@example.com"], subject: "parity",
                                 body: "body", attachments: attachments)
        let outbox = OutboxMessage(accountId: "acct-outbox-parity", draft: draft)
        try OutboxMessage.saveAttachments(attachments, dirName: outbox.id)
        defer { outbox.deleteAttachments() }
        let outboxLoaded = try outbox.loadAttachments()

        // THE INVARIANT: a file that round-trips as a draft does not vanish on
        // send. Same count, same names, same bytes.
        #expect(draftLoaded.count == attachments.count)
        #expect(outboxLoaded.count == draftLoaded.count)
        guard draftLoaded.count == attachments.count,
              outboxLoaded.count == draftLoaded.count else { return }
        #expect(draftLoaded.map(\.filename) == outboxLoaded.map(\.filename))
        #expect(draftLoaded.map(\.data) == outboxLoaded.map(\.data))
        #expect(outboxLoaded[0].filename == "settings.meta")
    }
}
