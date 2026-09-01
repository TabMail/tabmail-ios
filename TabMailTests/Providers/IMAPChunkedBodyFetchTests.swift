/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail
import Testing
@testable import TabMail

@Suite("IMAP bounded MIME-part fetching", .serialized)
struct IMAPChunkedBodyFetchTests {
    private func provider(for server: FakeIMAPServer) -> IMAPProvider {
        IMAPProvider(
            host: "127.0.0.1", port: server.port,
            username: server.username, password: server.password,
            smtpHost: "127.0.0.1", smtpPort: 587, useTLS: false
        )
    }

    private func multipartMessage(uid: Int = 501) -> (
        message: FakeIMAPServer.Message,
        text: Data,
        attachmentAdvertisedSize: Int
    ) {
        let text = Data(repeating: Character("a").asciiValue!, count: 1024 * 1024 + 17)
        let attachmentSize = 34 * 1024 * 1024
        let header = """
        From: Sender <sender@example.com>\r
        To: Recipient <recipient@example.com>\r
        Subject: Bounded batch\r
        Date: Thu, 02 Oct 2025 01:50:00 +0000\r
        Message-ID: <bounded-batch@example.com>\r
        Content-Type: multipart/mixed; boundary="bounded"\r
        \r

        """
        let bodystructure = """
        (("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" \(text.count) 1)("APPLICATION" "PDF" ("NAME" "large.pdf") NIL NIL "BASE64" \(attachmentSize) NIL ("ATTACHMENT" ("FILENAME" "large.pdf"))) "MIXED")
        """
        let message = FakeIMAPServer.makeMultipartMessage(
            uid: uid,
            subject: "Bounded batch",
            from: "Sender <sender@example.com>",
            to: "Recipient <recipient@example.com>",
            date: "Thu, 02 Oct 2025 01:50:00 +0000",
            internalDate: "02-Oct-2025 01:50:00 +0000",
            messageID: "<bounded-batch@example.com>",
            rawHeader: header,
            fullMessage: Data(header.utf8),
            bodystructure: bodystructure,
            partBodies: ["1": text, "2": Data("not downloaded".utf8)]
        )
        return (message, text, attachmentSize)
    }

    @Test("Background selection downloads render ingredients but not normal attachments")
    func selectsOnlyRenderIngredients() {
        let parts = [
            MessagePart(sectionString: "1", contentType: "text/plain; charset=utf-8"),
            MessagePart(sectionString: "2", contentType: "text/html", disposition: "attachment", filename: "body.html"),
            MessagePart(sectionString: "3", contentType: "text/calendar", disposition: "attachment", filename: "invite.ics"),
            MessagePart(sectionString: "4", contentType: "image/png", disposition: "inline", contentId: "logo@example.com"),
            MessagePart(sectionString: "5", contentType: "image/jpeg", disposition: "attachment", filename: "photo.jpg", contentId: "photo@example.com"),
            MessagePart(sectionString: "6", contentType: "application/pdf", disposition: "attachment", filename: "report.pdf"),
            MessagePart(sectionString: "7", contentType: "message/rfc822", disposition: "attachment", filename: "forwarded.eml"),
            MessagePart(sectionString: "8", contentType: "text/plain", filename: "notes.txt"),
            MessagePart(sectionString: "9", contentType: "text/plain", disposition: "inline", filename: "visible.txt"),
            MessagePart(sectionString: "10", contentType: "message/rfc822", disposition: "attachment", filename: "forward.eml"),
            MessagePart(sectionString: "10.1", contentType: "text/plain"),
            MessagePart(sectionString: "10.2", contentType: "image/png", disposition: "inline", contentId: "nested@example.com"),
            MessagePart(sectionString: "11", contentType: "message/rfc822", disposition: "inline", filename: "inline.eml"),
            MessagePart(sectionString: "11.1", contentType: "text/plain"),
        ]

        let selected = IMAPFetchMapping.requiredBodyPartIndices(in: parts)
            .map { parts[$0].section.description }
        #expect(selected == ["1", "3", "4", "9", "11.1"])
    }

    @Test("Encoded bytes are concatenated before one transfer-decoding pass")
    func concatenatesBeforeDecoding() async throws {
        let decoded = Data("chunk boundaries must not corrupt base64".utf8)
        let encoded = decoded.base64EncodedData()
        var requests: [(offset: Int, count: Int)] = []

        let assembled = try await IMAPFetchMapping.concatenateEncodedPart(
            expectedSize: encoded.count,
            chunkSize: 5
        ) { offset, count in
            requests.append((offset, count))
            let end = min(offset + count, encoded.count)
            return encoded.subdata(in: offset..<end)
        }

        let part = MessagePart(
            sectionString: "1",
            contentType: "text/plain",
            encoding: "base64",
            data: assembled
        )
        #expect(part.decodedData() == decoded)
        #expect(requests.first?.offset == 0)
        #expect(requests.allSatisfy { $0.count <= 5 })
        #expect(requests.map(\.offset)
                == Array(stride(from: 0, to: encoded.count, by: 5)) + [encoded.count])
    }

    @Test("Unknown-size parts require an empty response after a short chunk")
    func unknownSizeRequiresEmptyResponse() async throws {
        let source = Data("seven!!".utf8)
        var calls = 0
        let assembled = try await IMAPFetchMapping.concatenateEncodedPart(
            expectedSize: nil,
            chunkSize: 4
        ) { offset, count in
            calls += 1
            let end = min(offset + count, source.count)
            return source.subdata(in: offset..<end)
        }
        #expect(assembled == source)
        #expect(calls == 3)
    }

    @Test("Known-size assembly keeps advancing after a short non-empty response")
    func knownSizeContinuesAfterShortResponse() async throws {
        let source = Data("abcdefghij".utf8)
        var requests: [(offset: Int, count: Int)] = []
        let assembled = try await IMAPFetchMapping.concatenateEncodedPart(
            expectedSize: source.count,
            chunkSize: 4
        ) { offset, count in
            requests.append((offset, count))
            let end = min(offset + min(count, 2), source.count)
            return source.subdata(in: offset..<end)
        }
        #expect(assembled == source)
        #expect(requests.map(\.offset) == [0, 2, 4, 6, 8, 10])
    }

    @Test("Known-size assembly rejects understated BODYSTRUCTURE size")
    func rejectsUnderstatedPositiveSize() async {
        let source = Data("abcdef".utf8)
        await #expect(throws: IMAPPartialFetchAssemblyError.contentBeyondExpectedSize(expected: 5)) {
            _ = try await IMAPFetchMapping.concatenateEncodedPart(
                expectedSize: 5,
                chunkSize: 3
            ) { offset, count in
                let end = min(offset + count, source.count)
                return source.subdata(in: offset..<end)
            }
        }
    }

    @Test("Zero BODYSTRUCTURE size is proven rather than trusted")
    func rejectsFalseZeroSize() async {
        await #expect(throws: IMAPPartialFetchAssemblyError.contentBeyondExpectedSize(expected: 0)) {
            _ = try await IMAPFetchMapping.concatenateEncodedPart(expectedSize: 0) { offset, count in
                #expect(offset == 0)
                #expect(count == 1)
                return Data("x".utf8)
            }
        }
    }

    @Test("NSE aggregate budget requires known render-part sizes and ignores attachments")
    func aggregateBudgetUsesRenderPartsOnly() {
        let sized = [
            MessagePart(sectionString: "1", contentType: "text/plain", size: 6),
            MessagePart(
                sectionString: "2", contentType: "application/pdf",
                disposition: "attachment", filename: "large.pdf", size: 100_000
            ),
            MessagePart(
                sectionString: "3", contentType: "image/png",
                disposition: "inline", contentId: "logo@example.com", size: 4
            ),
        ]
        #expect(IMAPFetchMapping.requiredBodyPartsFitAggregateBudget(in: sized, byteBudget: 10))
        #expect(!IMAPFetchMapping.requiredBodyPartsFitAggregateBudget(in: sized, byteBudget: 9))

        let unknown = [MessagePart(sectionString: "1", contentType: "text/plain", size: nil)]
        #expect(!IMAPFetchMapping.requiredBodyPartsFitAggregateBudget(in: unknown, byteBudget: 10))
        #expect(!IMAPFetchMapping.requiredBodyPartsFitAggregateBudget(in: [], byteBudget: -1))
    }

    @Test("An empty response before the BODYSTRUCTURE size is terminal")
    func rejectsPrematureEnd() async {
        await #expect(throws: IMAPPartialFetchAssemblyError.prematureEnd(expected: 10, received: 3)) {
            _ = try await IMAPFetchMapping.concatenateEncodedPart(
                expectedSize: 10,
                chunkSize: 4
            ) { offset, _ in
                offset == 0 ? Data("abc".utf8) : Data()
            }
        }
    }

    @Test("Deterministic partial-fetch failures are distinguished from transient errors")
    func classifiesTerminalProtocolFailures() {
        #expect(IMAPFetchMapping.isDeterministicPartialFetchFailure(
            PartialFetchError.invalidResponse("range ignored")
        ))
        #expect(IMAPFetchMapping.isDeterministicPartialFetchFailure(
            PartialFetchError.serverRejected
        ))
        #expect(IMAPFetchMapping.isDeterministicPartialFetchFailure(
            IMAPPartialFetchAssemblyError.prematureEnd(expected: 10, received: 3)
        ))
        #expect(!IMAPFetchMapping.isDeterministicPartialFetchFailure(
            PartialFetchError.messageNotFound
        ))
        #expect(!IMAPFetchMapping.isDeterministicPartialFetchFailure(
            PartialFetchError.invalidRange
        ))
        #expect(!IMAPFetchMapping.isDeterministicPartialFetchFailure(
            URLError(.timedOut)
        ))
    }

    @Test("Provider batch hot path chunks render text and never fetches a >32 MiB attachment")
    func providerBatchWireContract() async throws {
        let fixture = multipartMessage()
        let server = FakeIMAPServer(messages: [fixture.message])
        try server.start()
        defer { server.stop() }
        let provider = provider(for: server)
        try await provider.connect()
        defer { Task { try? await provider.disconnect() } }

        let result = try await provider.fetchMessagesBatch(ids: ["501"], folder: "INBOX")
        let fetched = try #require(result["501"])
        #expect(fetched.textBody?.utf8.count == fixture.text.count)
        #expect(fetched.attachments.first?.size == fixture.attachmentAdvertisedSize)

        let commands = server.recordedCommands()
        #expect(commands.contains { $0.contains("BODY.PEEK[1]<0.1048576>") })
        #expect(commands.contains { $0.contains("BODY.PEEK[1]<1048576.17>") })
        #expect(commands.contains { $0.contains("BODY.PEEK[1]<1048593.1>") })
        #expect(!commands.contains { $0.contains("BODY.PEEK[2]") || $0.contains("BODY[2]") })
    }

    @Test("Ignored range is terminal but a transient NO remains retryable")
    func providerClassifiesWireFailures() async throws {
        let ignoredFixture = multipartMessage(uid: 502)
        let ignoredServer = FakeIMAPServer(messages: [ignoredFixture.message])
        ignoredServer.ignorePartialRange(forSection: "1")
        try ignoredServer.start()
        defer { ignoredServer.stop() }
        let ignoredProvider = provider(for: ignoredServer)
        try await ignoredProvider.connect()
        defer { Task { try? await ignoredProvider.disconnect() } }

        do {
            _ = try await ignoredProvider.fetchMessagesBatch(ids: ["502"], folder: "INBOX")
            Issue.record("An ignored partial range must not be accepted")
        } catch ProviderError.bodyIndexingUnsupported(
            let id, let observedUidValidity, let fetchedRfc822MessageId
        ) {
            #expect(id == "502")
            #expect(observedUidValidity == 1)
            #expect(fetchedRfc822MessageId == "bounded-batch@example.com")
        } catch {
            Issue.record("Unexpected ignored-range error: \(error)")
        }

        let transientFixture = multipartMessage(uid: 503)
        let transientServer = FakeIMAPServer(messages: [transientFixture.message])
        transientServer.failNextCommand(containing: "BODY.PEEK[1]")
        try transientServer.start()
        defer { transientServer.stop() }
        let transientProvider = provider(for: transientServer)
        try await transientProvider.connect()
        defer { Task { try? await transientProvider.disconnect() } }

        do {
            _ = try await transientProvider.fetchMessagesBatch(ids: ["503"], folder: "INBOX")
            Issue.record("Injected NO should fail this attempt")
        } catch ProviderError.bodyIndexingUnsupported {
            Issue.record("A transient tagged NO must remain retryable")
        } catch {
            #expect(true)
        }
    }
}
