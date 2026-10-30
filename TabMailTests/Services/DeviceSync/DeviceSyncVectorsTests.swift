/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import CryptoKit
import Foundation
import Testing
@testable import TabMail

// The shared Device Sync conformance vectors' parse cases and text rules (§12). The vectors and the
// default catalog are byte-identical in TabMail for Thunderbird, iOS and Voice: a change to either is
// made in all three, and the hashes in DeviceSyncSharedFiles with it.

/// A string's bytes: the vectors compare texts as JavaScript does, code unit by code unit, never by
/// canonical equivalence.
private func bytes(_ text: String) -> Data {
    Data(text.utf8)
}

private func bulletField(_ value: Any?) throws -> BulletField {
    guard let name = value as? String, let field = BulletField(rawValue: name) else { throw DeviceSyncTestError("no field \(String(describing: value))") }
    return field
}

private func pair(_ value: Any?) throws -> (section: String, text: String) {
    guard let pair = value as? [String], pair.count == 2 else { throw DeviceSyncTestError("not a [section, text]: \(String(describing: value))") }
    return (pair[0], pair[1])
}

@MainActor
@Suite("Device Sync shared conformance vectors")
struct DeviceSyncVectorsTests {
    nonisolated static let parseIDs: [String] = DeviceSyncSharedFiles.parseCases.map { $0["id"] as! String }
    nonisolated static let trimCodes: [String] = (DeviceSyncSharedFiles.vectors["conventions"] as? [String: Any])?["trim"] as? [String] ?? []

    /// R2: the same characters are trimmed on every platform, or a text one stores is one another refuses.
    @Test("Trims each R2 character at both ends and keeps it inside", arguments: trimCodes)
    func trimsEachCharacter(_ hex: String) throws {
        let scalar = try #require(UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init))
        let character = String(scalar)
        #expect(Bullets.trim("\(character)\(character)a\(character)b\(character)") == "a\(character)b")
    }

    @Test("Trims nothing outside the R2 list")
    func trimsNothingElse() {
        #expect(Self.trimCodes.count == 25)
        #expect(Bullets.trim("\u{200B}a\u{0085}\u{180E}") == "\u{200B}a\u{0085}\u{180E}")
    }

    /// DS-CHUNK cuts parts by the message's bytes, so a text is written as `JSON.stringify` writes it:
    /// a control character without a short escape as `\u` and four lowercase hex digits, DEL and
    /// everything above it as itself.
    @Test("A text is written as JSON.stringify writes it, and reads back as itself")
    func writesAsJSONStringify() throws {
        let text = "a\u{0B}b\u{1B}c\u{00}d\u{1F}e\u{7F}f\u{08}\u{0C}\n\r\t\"\\g\u{2028}h"
        let written = BulletJSON.string(text)
        #expect(written == #""a\u000bb\u001bc\u0000d\u001fe"# + "\u{7F}" + #"f\b\f\n\r\t\"\\g"# + "\u{2028}" + #"h""#)
        let read = try JSONSerialization.jsonObject(with: Data("[\(written)]".utf8)) as? [String]
        #expect(read == [text])
    }

    @Test("The vectors and the catalog are the shared files, byte for byte")
    func sharedFiles() {
        let vectors = SHA256.hash(data: DeviceSyncSharedFiles.vectorsData).map { String(format: "%02x", $0) }.joined()
        let catalog = SHA256.hash(data: DeviceSyncSharedFiles.catalogData).map { String(format: "%02x", $0) }.joined()
        #expect(vectors == DeviceSyncSharedFiles.vectorsSHA256)
        #expect(catalog == DeviceSyncSharedFiles.catalogSHA256)
        #expect(DeviceSyncSharedFiles.vectors["catalogSha256"] as? String == DeviceSyncSharedFiles.catalogSHA256)
    }

    @Test("parse", arguments: parseIDs)
    func parse(id: String) throws {
        let vector = try #require(DeviceSyncSharedFiles.parseCases.first { $0["id"] as? String == id })
        let field = try bulletField(vector["field"])
        let parsed = Bullets.parse(field, vector["text"] as! String)
        #expect(parsed.head.map(bytes) == (vector["head"] as! [String]).map(bytes), "head")
        #expect(parsed.tail.map(bytes) == (vector["tail"] as! [String]).map(bytes), "tail")
        let expected = try (vector["bullets"] as! [Any]).map(pair)
        #expect(parsed.bullets.map { bytes($0.section) + bytes("\u{0}") + bytes($0.text) }
                == expected.map { bytes($0.section) + bytes("\u{0}") + bytes($0.text) }, "bullets")
        func labelled(_ items: [BulletItem]) -> [Bullet] {
            items.map { Bullet(section: $0.section, text: $0.text, name: "default:x", n: 1) }
        }
        let rendered = Bullets.render(field, head: parsed.head, tail: parsed.tail, bullets: labelled(parsed.bullets))
        if let render = vector["render"] as? String {
            #expect(bytes(rendered) == bytes(render), "render")
        }
        // Stable after one round: the rendered text parses to the same bullets, each section's in order
        // (render puts a repeated section's bullets together), and renders the same.
        let again = Bullets.parse(field, rendered)
        func bySection(_ items: [BulletItem]) -> [Data: [Data]] {
            Dictionary(grouping: items, by: { bytes($0.section) }).mapValues { $0.map { bytes($0.text) } }
        }
        #expect(bySection(again.bullets) == bySection(parsed.bullets), "parsed again")
        #expect(bytes(Bullets.render(field, head: again.head, tail: again.tail, bullets: labelled(again.bullets))) == bytes(rendered), "rendered again")
    }
}
