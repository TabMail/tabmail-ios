/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import SwiftMail
import Testing
@testable import TabMail

@Suite("IMAP bounded MIME-part fetching")
struct IMAPChunkedBodyFetchTests {
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
        #expect(requests.map(\.offset) == Array(stride(from: 0, to: encoded.count, by: 5)))
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
        #expect(requests.map(\.offset) == [0, 2, 4, 6, 8])
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
}
