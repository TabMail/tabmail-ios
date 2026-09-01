/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// End-to-end IMAPProvider tests using `FakeIMAPServer` with multipart
/// BODYSTRUCTURE including a nested `message/rfc822` part.
///
/// Response shapes are verified against RFC 3501 §7.4.2 (FETCH response /
/// body-type-msg) — the nested rfc822 BODYSTRUCTURE includes envelope and a
/// recursive body inside the standard body-fields. Without the recursion,
/// SwiftMail's parser rejects the response and `fetchMessage` fails.
///
/// `.serialized` — FakeIMAPServer binds a listening socket; parallel runs
/// would contend on ephemeral port allocation.
@Suite("IMAPProvider — nested rfc822 end-to-end", .serialized)
struct IMAPProviderMockNestedEmlTests {

    private actor SuspendedEmlFetch {
        private var continuation: CheckedContinuation<Data, Never>?

        func fetch() async -> Data {
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilStarted() async {
            while continuation == nil { await Task.yield() }
        }

        func finish(with data: Data) {
            continuation?.resume(returning: data)
            continuation = nil
        }
    }

    private actor PresentationBarrier {
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilBlocked() async {
            while continuation == nil { await Task.yield() }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    // MARK: - File-uploaded .eml (filename-based, octet-stream, base64 transfer)

    @Test("A cancelled .eml fetch cannot freeze previews after its view disappears")
    @MainActor
    func cancelledEmlFetchDoesNotAcquirePreviewFreeze() async {
        PreviewFreezeGate.shared.end()
        defer { PreviewFreezeGate.shared.end() }
        let suspendedFetch = SuspendedEmlFetch()
        let attachment = AttachmentInfo(
            filename: "attached.eml",
            contentType: "message/rfc822",
            section: "2",
            size: 128,
            encoding: nil
        )
        let bytes = Data("""
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: Cancelled preview\r
        \r
        Body
        """.utf8)

        let coordinator = EmlAttachmentPreviewTaskCoordinator()
        let presentationTask = coordinator.start {
            do {
                _ = try await EmlAttachmentPreviewLoader.load(attachment: attachment) {
                    await suspendedFetch.fetch()
                }
                try EmlAttachmentPreviewLoader.beginPreviewFreeze()
            } catch is CancellationError {
                // The production task handles lifecycle cancellation silently.
            } catch {
                Issue.record("Unexpected load failure: \(error)")
            }
        }
        await suspendedFetch.waitUntilStarted()
        coordinator.cancel()
        await suspendedFetch.finish(with: bytes)
        await presentationTask.value
        #expect(!PreviewFreezeGate.shared.isFrozen)
    }

    @Test("Cancellation after .eml parsing still prevents preview freeze acquisition")
    @MainActor
    func cancellationBetweenLoadAndPresentationDoesNotAcquirePreviewFreeze() async {
        PreviewFreezeGate.shared.end()
        defer { PreviewFreezeGate.shared.end() }
        let barrier = PresentationBarrier()
        let attachment = AttachmentInfo(
            filename: "attached.eml",
            contentType: "message/rfc822",
            section: "2",
            size: 128,
            encoding: nil
        )
        let bytes = Data("""
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: Parsed before cancellation\r
        \r
        Body
        """.utf8)

        let presentationTask = Task { @MainActor in
            let payload = try await EmlAttachmentPreviewLoader.load(attachment: attachment) {
                bytes
            }
            await barrier.wait()
            try EmlAttachmentPreviewLoader.beginPreviewFreeze()
            return payload
        }
        await barrier.waitUntilBlocked()
        presentationTask.cancel()
        await barrier.release()

        do {
            _ = try await presentationTask.value
            Issue.record("A cancelled presentation must not acquire the preview freeze")
        } catch is CancellationError {
            #expect(!PreviewFreezeGate.shared.isFrozen)
        } catch {
            Issue.record("Unexpected cancellation result: \(error)")
        }
    }

    /// Regression test for the "messageNotFound" bug where tapping a nested
    /// attachment inside a file-uploaded `.eml` would throw because the
    /// recursive parent fetch carried `encoding: nil` instead of the outer
    /// `.eml`'s actual transfer encoding. When the outer is base64 (common),
    /// that meant EMLParser received base64 text rather than decoded RFC 822.
    ///
    /// Shape: BODYSTRUCTURE declares an `application/octet-stream` part with
    /// `.eml` filename and `BASE64` transfer encoding. `BODY[<section>]`
    /// returns base64-encoded bytes that decode to a multipart RFC 822
    /// containing a nested PDF.
    @Test("Background skips an opaque .eml; on-demand fetch preserves nested attachment access")
    func fileUploadedEmlBase64EndToEnd() async throws {
        let topHtml = "<p>TOP BODY</p>"
        let topHtmlBytes = Data(topHtml.utf8)

        let pdfPayloadText = "%%SYNTHETIC-IMAP-PDF%%"

        // The uploaded `.eml` file's content — a complete RFC 822 message
        // with one text/html body and one attachment. The attachment is
        // plain-text-inlined (no transfer encoding) so the test focuses on
        // the OUTER `.eml`'s base64 transfer encoding — that's the
        // encoding-passthrough path that caused the messageNotFound bug.
        let innerRfc822 = """
        From: Uploader <uploader@example.com>\r
        To: Me <me@example.com>\r
        Subject: IMAP NESTED SUBJECT\r
        Date: Wed, 2 Oct 2025 01:50:00 +0000\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="inner-b"\r
        \r
        --inner-b\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>NESTED BODY</p>\r
        --inner-b\r
        Content-Type: application/pdf\r
        Content-Disposition: attachment; filename="imap-nested.pdf"\r
        \r
        \(pdfPayloadText)\r
        --inner-b--\r
        """
        let innerBytes = Data(innerRfc822.utf8)

        // On the IMAP wire, BODY[2] returns the .eml bytes in their
        // transfer-encoded form. Outlook et al. typically base64-encode
        // `.eml` attachments for 7-bit-safe transport.
        let emlOnWire = innerBytes.base64EncodedString()
        let emlOnWireBytes = Data(emlOnWire.utf8)

        // Top-level outer multipart/mixed assembled for the full-message fetch.
        // Needed when callers request BODY[] (we don't in this test, but it
        // keeps the fake self-consistent).
        let outerRaw = """
        From: Outer <outer@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: Outer\r
        Date: Thu, 02 Oct 2025 01:50:00 +0000\r
        Message-ID: <outer@example.com>\r
        Content-Type: multipart/mixed; boundary="outer-b"\r
        \r
        --outer-b\r
        Content-Type: text/html; charset=utf-8\r
        \r
        \(topHtml)\r
        --outer-b\r
        Content-Type: application/octet-stream; name="carrier.eml"\r
        Content-Disposition: attachment; filename="carrier.eml"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(emlOnWire)\r
        --outer-b--\r
        """
        let outerBytes = Data(outerRaw.utf8)

        // BODYSTRUCTURE — RFC 3501 §7.4.2 body-type-mpart. The
        // octet-stream part declares BASE64 encoding and a Content-
        // Disposition with filename="carrier.eml".
        let bodystructure = """
        (("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" \(topHtmlBytes.count) 1)("APPLICATION" "OCTET-STREAM" ("NAME" "carrier.eml") NIL NIL "BASE64" \(emlOnWireBytes.count) NIL ("attachment" ("filename" "carrier.eml"))) "MIXED")
        """

        let outerHeader = """
        From: Outer <outer@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: Outer\r
        Date: Thu, 02 Oct 2025 01:50:00 +0000\r
        Message-ID: <outer@example.com>\r
        Content-Type: multipart/mixed; boundary="outer-b"\r
        \r

        """

        let msg = FakeIMAPServer.makeMultipartMessage(
            uid: 77,
            subject: "Outer",
            from: "Outer <outer@example.com>",
            to: "Recipient <recipient@example.com>",
            date: "Thu, 02 Oct 2025 01:50:00 +0000",
            internalDate: "02-Oct-2025 01:50:00 +0000",
            messageID: "<outer@example.com>",
            rawHeader: outerHeader,
            fullMessage: outerBytes,
            bodystructure: bodystructure,
            partBodies: [
                "1": topHtmlBytes,
                "2": emlOnWireBytes   // base64 text on the wire
            ]
        )

        let server = FakeIMAPServer(messages: [msg])
        try server.start()
        defer { server.stop() }

        let provider = IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: "testuser",
            password: "testpass",
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )

        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        // === Part 1: background body fetch leaves the opaque .eml metadata-only ===

        let info = try await provider.fetchMessage(id: "77", folder: "INBOX")
        #expect(info.observedUidValidity == 1)
        let html = try #require(info.htmlBody)
        #expect(html.contains("TOP BODY"))
        #expect(!html.contains("tm-eml-section"))
        #expect(!html.contains("NESTED BODY"))
        #expect(info.attachments.allSatisfy { $0.filename != "imap-nested.pdf" })

        let carrier = try #require(info.attachments.first { $0.filename == "carrier.eml" })
        #expect(carrier.section == "2")
        #expect(carrier.encoding?.lowercased() == "base64")

        // === Part 2: tapping the .eml fetches and decodes its parent bytes ===

        let preview = try await EmlAttachmentPreviewLoader.load(attachment: carrier) {
            try await provider.fetchAttachment(
                messageId: "77", folder: "INBOX",
                section: carrier.section, encoding: carrier.encoding,
                expectedObservedUidValidity: nil,
                expectedRfc822MessageId: "outer@example.com"
            )
        }
        #expect(preview.html.contains("NESTED BODY"))
        let nested = try #require(
            preview.nestedAttachments.first { $0.filename == "imap-nested.pdf" }
        )

        // === Part 3: an attachment selected inside that preview resolves through
        // === the compound section and the same bounded parent-fetch path.      ===

        let expectedCompound = EmlParsing.nestedSection(parent: "2", index: 0)
        let fetchedBytes = try await provider.fetchAttachment(
            messageId: "77", folder: "INBOX",
            section: expectedCompound, encoding: carrier.encoding,
            expectedObservedUidValidity: nil,
            expectedRfc822MessageId: "outer@example.com"
        )
        let fetchedString = String(data: fetchedBytes, encoding: .utf8) ?? ""
        #expect(nested.filename == "imap-nested.pdf")
        #expect(fetchedString.contains("%%SYNTHETIC-IMAP-PDF%%"))
    }

    @Test("Background excludes attached message/rfc822 descendants but keeps parent metadata")
    func nestedRfc822RemainsMetadataOnly() async throws {
        // Top-level body (section 1) — text/html.
        let topHtml = "<p>TOP BODY TEXT</p>"
        let topHtmlBytes = Data(topHtml.utf8)

        // Nested body (section 2.1 — inside the rfc822) — text/html.
        let innerHtml = "<p>INNER BODY TEXT</p>"
        let innerHtmlBytes = Data(innerHtml.utf8)

        // Full section 2 (the raw nested rfc822 — used if the provider ever
        // requests BODY[2] as a whole). Matches what a real server returns.
        let innerRfc822 = """
        From: Inner Sender <inner@example.com>\r
        To: To One <to1@example.com>\r
        Subject: Inner subject\r
        Date: Wed, 01 Oct 2025 12:00:00 +0000\r
        Message-ID: <inner@example.com>\r
        Content-Type: text/html; charset=utf-8\r
        \r
        \(innerHtml)
        """
        let innerRfc822Bytes = Data(innerRfc822.utf8)

        // Full outer message — multipart/mixed with boundary.
        let boundary = "----=_Part_1_abc"
        let outerRaw = """
        From: Outer <outer@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: Outer subject\r
        Date: Thu, 02 Oct 2025 01:50:00 +0000\r
        Message-ID: <outer@example.com>\r
        Content-Type: multipart/mixed; boundary="\(boundary)"\r
        \r
        --\(boundary)\r
        Content-Type: text/html; charset=utf-8\r
        \r
        \(topHtml)\r
        --\(boundary)\r
        Content-Type: message/rfc822\r
        Content-Disposition: attachment; filename="inner.eml"\r
        \r
        \(innerRfc822)\r
        --\(boundary)--\r
        """
        let outerBytes = Data(outerRaw.utf8)

        // RFC 3501 §7.4.2 body-type-mpart: list of body-type entries then
        // media-subtype. body-type-msg: basic fields + envelope + recursive
        // body + lines.
        // Envelope address list form: ((name source-route local domain))
        let innerEnvelope = """
        ("Wed, 01 Oct 2025 12:00:00 +0000" "Inner subject" (("Inner Sender" NIL "inner" "example.com")) (("Inner Sender" NIL "inner" "example.com")) (("Inner Sender" NIL "inner" "example.com")) (("To One" NIL "to1" "example.com")) NIL NIL NIL "<inner@example.com>")
        """
        let innerBodyStructure = """
        ("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" \(innerHtmlBytes.count) 1)
        """
        let bodystructure = """
        (("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" \(topHtmlBytes.count) 1)("MESSAGE" "RFC822" ("NAME" "inner.eml") NIL NIL "7BIT" \(innerRfc822Bytes.count) \(innerEnvelope) \(innerBodyStructure) \(innerRfc822.filter { $0 == "\n" }.count)) "MIXED")
        """

        let outerHeader = """
        From: Outer <outer@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: Outer subject\r
        Date: Thu, 02 Oct 2025 01:50:00 +0000\r
        Message-ID: <outer@example.com>\r
        Content-Type: multipart/mixed; boundary="\(boundary)"\r
        \r

        """

        let msg = FakeIMAPServer.makeMultipartMessage(
            uid: 42,
            subject: "Outer subject",
            from: "Outer <outer@example.com>",
            to: "Recipient <recipient@example.com>",
            date: "Thu, 02 Oct 2025 01:50:00 +0000",
            internalDate: "02-Oct-2025 01:50:00 +0000",
            messageID: "<outer@example.com>",
            rawHeader: outerHeader,
            fullMessage: outerBytes,
            bodystructure: bodystructure,
            partBodies: [
                "1": topHtmlBytes,
                "2": innerRfc822Bytes,
                "2.1": innerHtmlBytes
            ]
        )

        let server = FakeIMAPServer(messages: [msg])
        try server.start()
        defer { server.stop() }

        let provider = IMAPProvider(
            host: "127.0.0.1",
            port: server.port,
            username: "testuser",
            password: "testpass",
            smtpHost: "127.0.0.1",
            smtpPort: 587,
            useTLS: false
        )

        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let info: FullMessageInfo
        do {
            info = try await provider.fetchMessage(id: "42", folder: "INBOX")
        } catch {
            Issue.record("fetchMessage threw: \(error)")
            return
        }

        // The top-level render body is present, while the attached message and
        // its flattened descendants remain metadata-only until explicitly opened.
        let html = try #require(info.htmlBody)
        #expect(html.contains("TOP BODY TEXT"))
        #expect(html.contains("tm-eml-section"))
        #expect(!html.contains("INNER BODY TEXT"))
        let attachedMessage = try #require(info.attachments.first { $0.filename == "inner.eml" })
        #expect(attachedMessage.section == "2")

        let preview = try await EmlAttachmentPreviewLoader.load(attachment: attachedMessage) {
            try await provider.fetchAttachment(
                messageId: "42", folder: "INBOX",
                section: attachedMessage.section, encoding: attachedMessage.encoding,
                expectedObservedUidValidity: 1,
                expectedRfc822MessageId: "outer@example.com"
            )
        }
        #expect(preview.html.contains("INNER BODY TEXT"))
        #expect(server.recordedCommands().contains {
            $0.contains("BODY.PEEK[2]<0.\(innerRfc822Bytes.count)>")
        })
        #expect(server.recordedCommands().contains {
            $0.contains("BODY.PEEK[2]<\(innerRfc822Bytes.count).1>")
        })
    }

    @Test("UIDVALIDITY turnover refuses normal and .eml attachment payloads")
    func attachmentReadsRefuseUidTurnover() async throws {
        let bodystructure = """
        (("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 4 1)("APPLICATION" "PDF" ("NAME" "document.pdf") NIL NIL "7BIT" 3 NIL ("attachment" ("filename" "document.pdf")))("APPLICATION" "OCTET-STREAM" ("NAME" "attached.eml") NIL NIL "7BIT" 8 NIL ("attachment" ("filename" "attached.eml"))) "MIXED")
        """
        func message(id: String, normal: String, eml: String) -> FakeIMAPServer.Message {
            FakeIMAPServer.makeMultipartMessage(
                uid: 9,
                subject: "Attachment identity",
                from: "Sender <sender@example.com>",
                to: "Recipient <recipient@example.com>",
                date: "Thu, 02 Oct 2025 01:50:00 +0000",
                internalDate: "02-Oct-2025 01:50:00 +0000",
                messageID: "<\(id)>",
                rawHeader: "Message-ID: <\(id)>\r\nDate: Thu, 02 Oct 2025 01:50:00 +0000\r\n\r\n",
                fullMessage: Data(),
                bodystructure: bodystructure,
                partBodies: [
                    "1": Data("body".utf8),
                    "2": Data(normal.utf8),
                    "3": Data(eml.utf8),
                ]
            )
        }

        let originalId = "original-attachment@example.com"
        let server = FakeIMAPServer(messages: [
            message(id: originalId, normal: "old", eml: "old-eml")
        ])
        server.setUidValidity(41, for: "INBOX")
        try server.start()
        defer { server.stop() }

        let provider = IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false
        )
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        // The row still names epoch 41/UID 9, while UID 9 now belongs to a
        // different message in epoch 42. Neither a normal file nor a metadata-
        // only .eml tap may read the replacement payload.
        server.setMessages([
            message(id: "replacement@example.com", normal: "new", eml: "new-eml")
        ], in: "INBOX")
        server.setUidValidity(42, for: "INBOX")

        for section in ["2", "3"] {
            do {
                _ = try await provider.fetchAttachment(
                    messageId: "9",
                    folder: "INBOX",
                    section: section,
                    encoding: nil,
                    expectedObservedUidValidity: 41,
                    expectedRfc822MessageId: originalId
                )
                Issue.record("Section \(section) was fetched across UIDVALIDITY turnover")
            } catch ProviderError.uidValidityChanged(let folder, let stored, let live) {
                #expect(folder == "INBOX")
                #expect(stored == 41)
                #expect(live == 42)
            } catch {
                Issue.record("Unexpected turnover refusal for section \(section): \(error)")
            }
        }
        do {
            _ = try await provider.fetchAttachment(
                messageId: "9",
                folder: "INBOX",
                section: "2",
                encoding: nil,
                expectedObservedUidValidity: nil,
                expectedRfc822MessageId: originalId
            )
            Issue.record("Message-ID fallback accepted a replacement message")
        } catch ProviderError.actionIdentityResolutionFailed(let messageId) {
            #expect(messageId == "9")
        } catch {
            Issue.record("Unexpected Message-ID fallback refusal: \(error)")
        }
        #expect(!server.recordedCommands().contains { command in
            command.contains("BODY.PEEK[2]") || command.contains("BODY.PEEK[3]")
        })
    }
}
