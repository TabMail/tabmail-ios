import Foundation
import Synchronization
import Testing
@testable import TabMail

/// `AttachmentPairing.unpaired`: attachments pair by name, kind and content, one to one (#863).
@Suite("Attachments pair by name, kind and content, one to one (#863)")
struct AttachmentPairingTests {
    struct File: Sendable, Equatable {
        let id: String
        let name: String
        let kind: String
        let bytes: Data
        let size: Int
    }

    private static let file = "fileattachment"
    private static let agenda = Data("Agenda\n".utf8)
    private static let edited = Data("Agenda, edited\n".utf8)

    /// A copy as Outlook makes one: the same name, kind and bytes, a new id and a larger size.
    private static func copy(_ f: File, id: String) -> File { File(id: id, name: f.name, kind: f.kind, bytes: f.bytes, size: f.size + 16) }

    /// The attachments whose content was asked for, in order.
    final class Asked: Sendable {
        let ids = Mutex<[String]>([])
        var all: [String] { ids.withLock { $0 } }
    }

    private static func unpaired(_ files: [File], against reference: [File], asked: Asked = Asked()) async throws -> [String] {
        try await AttachmentPairing.unpaired(
            files, against: reference, name: { $0.name }, kind: { $0.kind },
            content: { f in
                asked.ids.withLock { $0.append(f.id) }
                return AttachmentPairing.contentDigest(f.bytes)
            }
        ).map(\.id)
    }

    @Test("a copy (new id, larger size) pairs; a same-name file with other bytes does not")
    func sameNameOtherBytesIsUnpaired() async throws {
        let series = File(id: "s1", name: "agenda.pdf", kind: Self.file, bytes: Self.agenda, size: 7)
        let copied = Self.copy(series, id: "c1")
        let replaced = File(id: "r1", name: "agenda.pdf", kind: Self.file, bytes: Self.edited, size: 7)
        #expect(try await Self.unpaired([copied], against: [series]).isEmpty)
        #expect(try await Self.unpaired([replaced], against: [series]) == ["r1"])
    }

    @Test("each reference attachment pairs with at most one: two equal files against one leave one, in order")
    func multisetPairsOneToOne() async throws {
        let series = File(id: "s1", name: "agenda.pdf", kind: Self.file, bytes: Self.agenda, size: 7)
        let both = [Self.copy(series, id: "c1"), Self.copy(series, id: "c2")]
        #expect(try await Self.unpaired(both, against: [series]) == ["c2"])
        #expect(try await Self.unpaired(both, against: [series, Self.copy(series, id: "s2")]).isEmpty)
        #expect(try await Self.unpaired([series], against: both).isEmpty)
    }

    @Test("a different kind or name never pairs, whatever the content")
    func kindAndNameMustMatch() async throws {
        let series = File(id: "s1", name: "agenda.pdf", kind: Self.file, bytes: Self.agenda, size: 7)
        let item = File(id: "i1", name: "agenda.pdf", kind: "itemattachment", bytes: Self.agenda, size: 7)
        let renamed = File(id: "n1", name: "agenda (1).pdf", kind: Self.file, bytes: Self.agenda, size: 7)
        #expect(try await Self.unpaired([item, renamed], against: [series]) == ["i1", "n1"])
    }

    @Test("content is asked only of attachments whose name and kind the other side shares, once each")
    func contentIsReadOnlyForPossiblePartners() async throws {
        let series = File(id: "s1", name: "agenda.pdf", kind: Self.file, bytes: Self.agenda, size: 7)
        let other = File(id: "s2", name: "deck.bin", kind: Self.file, bytes: Self.agenda, size: 7)
        let minutes = File(id: "m1", name: "minutes.txt", kind: Self.file, bytes: Self.edited, size: 9)
        let asked = Asked()
        let left = try await Self.unpaired([Self.copy(series, id: "c1"), minutes], against: [series, other], asked: asked)
        #expect(left == ["m1"])
        #expect(asked.all.sorted() == ["c1", "s1"], "content read for \(asked.all)")
    }

    @Test("a content read that fails fails the pairing")
    func contentFailureThrows() async {
        struct Unreadable: Error {}
        let series = File(id: "s1", name: "agenda.pdf", kind: Self.file, bytes: Self.agenda, size: 7)
        await #expect(throws: Unreadable.self) {
            _ = try await AttachmentPairing.unpaired(
                [Self.copy(series, id: "c1")], against: [series], name: { $0.name }, kind: { $0.kind }, content: { _ in throw Unreadable() })
        }
    }

    @Test("the content digest is the SHA-256 of the bytes in hex")
    func digestIsSHA256() {
        #expect(AttachmentPairing.contentDigest(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(AttachmentPairing.contentDigest(Self.agenda) != AttachmentPairing.contentDigest(Self.edited))
    }
}
