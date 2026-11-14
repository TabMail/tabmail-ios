import CryptoKit
import Foundation

/// Pairs the attachments of one item with those of another by what they ARE: the same name, the
/// same kind and the same content. Never by id, size or timestamp: Outlook gives an occurrence
/// changed on its own (an exception) its own COPY of each of its series' attachments, with the same
/// name, kind and bytes but a new id, a larger listed size and a new `lastModifiedDateTime`
/// (measured on a work account, 2026-11-14), and a file replaced by another of the same name is
/// not a copy at all (#863).
enum AttachmentPairing {
    /// What an attachment pairs by before its content is read: its name and kind.
    private struct Shape: Hashable { let name: String; let kind: String }
    /// What an attachment pairs by: its name, kind and content.
    private struct Key: Hashable { let shape: Shape; let content: String }

    /// The members of `attachments` no member of `reference` pairs with, in their order.
    ///
    /// Two attachments pair when their `name`, `kind` and `content` are equal. It is a multiset
    /// match: each member of `reference` pairs with at most one member of `attachments`, so two
    /// equal files against one leave one unpaired. `content` (for a file, `contentDigest` of its
    /// bytes) is asked only of an attachment whose name and kind some attachment on the other side
    /// shares, at most once each, so an attachment with no possible partner is never read.
    nonisolated static func unpaired<Attachment: Sendable>(
        _ attachments: [Attachment],
        against reference: [Attachment],
        name: @Sendable (Attachment) -> String,
        kind: @Sendable (Attachment) -> String,
        content: @Sendable (Attachment) async throws -> String
    ) async throws -> [Attachment] {
        func shape(_ attachment: Attachment) -> Shape { Shape(name: name(attachment), kind: kind(attachment)) }
        let shared = Set(attachments.map { shape($0) }).intersection(reference.map { shape($0) })
        var unmatched: [Key: Int] = [:]
        for attachment in reference where shared.contains(shape(attachment)) {
            unmatched[Key(shape: shape(attachment), content: try await content(attachment)), default: 0] += 1
        }
        var left: [Attachment] = []
        for attachment in attachments {
            let attachmentShape = shape(attachment)
            guard shared.contains(attachmentShape) else {
                left.append(attachment)
                continue
            }
            let key = Key(shape: attachmentShape, content: try await content(attachment))
            if let count = unmatched[key], count > 0 {
                unmatched[key] = count - 1
            } else {
                left.append(attachment)
            }
        }
        return left
    }

    /// The content a file pairs by: the SHA-256 of its bytes, in hex.
    nonisolated static func contentDigest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
