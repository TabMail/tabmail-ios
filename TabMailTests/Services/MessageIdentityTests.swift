/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// Unit coverage for the shared `MessageIdentity` helper. These functions
/// are the single source of truth for GRDB header IDs and AI-cache keys
/// across the main app + NSE; a format drift here breaks pre-sync row
/// materialization and silently duplicates messages.
@Suite("MessageIdentity")
struct MessageIdentityTests {

    @Test("headerId is the accountId:folderPath:messageId composite")
    func headerIdFormat() {
        let id = MessageIdentity.headerId(accountId: "acct-1", folderPath: "INBOX", messageId: "msg-42")
        #expect(id == "acct-1:INBOX:msg-42")
    }

    @Test("headerId keeps Outlook Graph folder IDs intact (no double-accountId)")
    func headerIdWithGraphFolderPath() {
        // Outlook's parentFolderId is opaque + long; it must not be re-wrapped.
        let graphFolder = "AQMkADAwATE2MTQwLTk2YTQtNjViMy0wMAItMDAKAC4AAAMDNjEovScBQ45d1u-N6VF6AQBsEuKMUAqnSoipbS5grLZLAAACAQwAAAA="
        let id = MessageIdentity.headerId(accountId: "acct-o", folderPath: graphFolder, messageId: "msg-outlook")
        #expect(id == "acct-o:\(graphFolder):msg-outlook")
    }

    @Test("folderId is the accountId:folderPath composite")
    func folderIdFormat() {
        #expect(MessageIdentity.folderId(accountId: "acct", folderPath: "INBOX") == "acct:INBOX")
    }

    @Test("aiCacheKey matches MessageAICache.cacheKey byte-for-byte")
    func aiCacheKeyMatchesMessageAICache() {
        // This is the contract the NSE cross-device peer probe depends on.
        let shared = MessageIdentity.aiCacheKey(
            accountId: "acct", folderPath: "INBOX", rfc822MessageId: "abc@example.com"
        )
        let mac = MessageAICache.cacheKey(
            accountId: "acct", folderPath: "INBOX", rfc822MessageId: "abc@example.com"
        )
        #expect(shared == mac)
        #expect(shared == "acct:INBOX:abc@example.com")
    }

    @Test("aiCacheKey returns nil when rfc822MessageId is missing (no cache row for those)")
    func aiCacheKeyNilOnMissingRfc() {
        #expect(MessageIdentity.aiCacheKey(accountId: "a", folderPath: "INBOX", rfc822MessageId: nil) == nil)
        #expect(MessageIdentity.aiCacheKey(accountId: "a", folderPath: "INBOX", rfc822MessageId: "") == nil)
    }

    @Test("aiCacheKey does NOT double-wrap the folder — regression guard for bug 2a")
    func aiCacheKeyNoDoubleAccountId() {
        // The NSEDataBridge pre-fix path built keys as
        // "accountId:accountId:INBOX:rfc" (folderId already embedded accountId,
        // then accountId was prefixed again). Assert the shared helper
        // produces the flat shape the main-app cache stores under.
        let key = MessageIdentity.aiCacheKey(
            accountId: "dup", folderPath: "INBOX", rfc822MessageId: "r@x"
        )
        #expect(key == "dup:INBOX:r@x")
        #expect(key != "dup:dup:INBOX:r@x")
    }

    @Test("MessageHeader.id goes through MessageIdentity — same composite")
    func messageHeaderUsesMessageIdentity() {
        let header = MessageHeader(
            messageId: "m", subject: "", from: "", fromAddress: "", to: "",
            date: Date(timeIntervalSince1970: 0), snippet: "",
            folderId: "acct:INBOX", accountId: "acct",
            folderPath: "INBOX", isInInbox: true
        )
        #expect(header.id == MessageIdentity.headerId(
            accountId: "acct", folderPath: "INBOX", messageId: "m"
        ))
    }
}

// MARK: - Content-key helper

/// Invariant coverage for `MessageIdentity.contentKey` and its `ContentKeySpace`
/// discriminator. Every assertion here pins a SYSTEM PROPERTY — the key never
/// leaves its own folder, `.stableProviderId` never moves an existing key, and
/// the only channel by which two distinct messages can share a content key is a
/// duplicate RFC Message-ID. None pins the shape of the minted string, which
/// would merely inherit the mint's own spec and stay green on a broken system.
///
/// ⚑ WHY THERE IS NO "'@'-DISJOINTNESS" TEST HERE. It would pin a FALSE spec.
/// The claim would be that an IMAP-minted provider id never contains `@`, so the
/// provider-id and RFC tail spaces cannot collide. Three production sites
/// disprove it on a `.imap` account: `IMAPFetchMapping.messageIdString(from:)`
/// returns `"\(localPart)@\(domain)"` whenever the FETCH carried no UID (and it
/// is the sole IMAP messageId mint, compiled into both targets);
/// `AccountManager.queueDraftSave` mints an `@`-bearing `draft-` placeholder from
/// a composite key; and `DemoProvider.send` writes `<uuid@domain>` on the demo
/// account, whose provider is `.imap`. Each of those derives from the SAME
/// message's own RFC id, so both candidate tails are the identical string for the
/// identical message and zero cross-message collisions exist — but that is a
/// contingent fact, not a structural guarantee. The collision invariant below is
/// asserted instead; `'@'`-required and `':'`-rejected survive only as cheap
/// validity checks on the tail, never as a disjointness proof.
@Suite("Content key — RFC-first tail for content stores")
struct MessageIdentityContentKeyTests {

    private let account = "acct-1"
    private let folder = "INBOX"

    private func key(_ providerMessageId: String, rfc: String?, space: ContentKeySpace) -> String {
        MessageIdentity.contentKey(
            accountId: account,
            folderPath: folder,
            providerMessageId: providerMessageId,
            rfc822MessageId: rfc,
            space: space
        )
    }

    private func belongsToFolder(_ id: String) -> Bool {
        MessageIdentity.headerIdBelongsToFolder(id, accountId: account, folderPath: folder)
    }

    @Test(".stableProviderId keys byte-identically to headerId — Gmail/Graph keys must not move")
    func stableProviderIdIsByteIdenticalToHeaderId() {
        let providerIds = [
            "18f2c9a4b7d1e003",                                     // Gmail-shaped hex id
            "AAMkADAwATE2MTQwLTk2YTQtNjViMy0wMAItMDAKABAA-w==",     // Graph-shaped opaque id
            "77"                                                    // an IMAP UID
        ]
        for pid in providerIds {
            let expected = MessageIdentity.headerId(
                accountId: account, folderPath: folder, messageId: pid
            )
            #expect(key(pid, rfc: nil, space: .stableProviderId) == expected, "\(pid)")
            // …and, the load-bearing half: ALSO when a perfectly good RFC id is
            // supplied. A stable-provider account must never re-key just because
            // the message happens to carry a usable Message-ID.
            #expect(key(pid, rfc: "good@example.com", space: .stableProviderId) == expected, "\(pid)")
        }
    }

    @Test("The space discriminator is load-bearing — .uidAddressed moves the tail where .stableProviderId does not")
    func spaceDiscriminatorActuallyDiscriminates() {
        // Two-sided guard for the test above: were `contentKey` to ignore `space`
        // (or both cases to return the provider id), byte-identity would hold
        // vacuously. It cannot, because these two differ for the same inputs.
        let stable = key("77", rfc: "good@example.com", space: .stableProviderId)
        let addressed = key("77", rfc: "good@example.com", space: .uidAddressed)
        #expect(stable != addressed)
        #expect(stable == MessageIdentity.headerId(accountId: account, folderPath: folder, messageId: "77"))
        #expect(addressed == MessageIdentity.headerId(
            accountId: account, folderPath: folder, messageId: "good@example.com"
        ))
    }

    @Test("A malformed or absent RFC id falls back to the provider id and the key still belongs to its own folder")
    func malformedRfcFallsBackAndStaysFolderScoped() {
        let unusable: [(label: String, raw: String?)] = [
            ("nil",                  nil),
            ("empty",                ""),
            ("whitespace only",      "   \t "),
            ("embedded CR",          "a@example.com\r"),
            ("embedded LF",          "a\n@example.com"),
            ("unbalanced open",      "<a@example.com"),
            ("unbalanced close",     "a@example.com>"),
            ("no @ at all",          "no-at-sign-here"),
            ("two @",                "a@b@example.com"),
            ("empty local part",     "@example.com"),
            ("empty domain",         "a@"),
            // ⚑ THE colon case. RFC 5322 permits a colon inside a no-fold-literal
            // domain and `EmailFilter.normalizeMessageId` performs no validation,
            // so without the v3-only `':'` term this value would survive into the
            // tail. See `colonBearingTailWouldEscapeTheFolder` for what that costs.
            ("no-fold-literal domain", "a@[IPv6:2001:db8::1]")
        ]

        let providerId = "4210"
        let fallback = key(providerId, rfc: nil, space: .stableProviderId)

        for (label, raw) in unusable {
            let minted = key(providerId, rfc: raw, space: .uidAddressed)
            // The property: the row remains reachable by every folder-scoped
            // query and SQL sweep…
            #expect(belongsToFolder(minted), "\(label): key left its own folder")
            // …and keys exactly where it keyed BEFORE this change.
            #expect(minted == fallback, "\(label): did not fall back to the provider id")
        }
    }

    @Test("Non-vacuity — a colon-bearing tail DOES escape its own folder, which is why ':' is rejected at the mint")
    func colonBearingTailWouldEscapeTheFolder() {
        // The constructed negative case behind the folder-scoping assertions. If
        // `usableRfc822Tail` admitted the colon, THIS is the key it would mint,
        // and it is invisible to `headerIdBelongsToFolder` and to the SQL twin
        // `headerIdLikeNoDeeperColonSQLFragment` — so the row's FTS entry, chat-id
        // mapping and body assets would silently orphan on the next folder purge
        // or UIDVALIDITY reset.
        let colonBearing = "a@[IPv6:2001:db8::1]"
        let wouldBeKey = MessageIdentity.headerId(
            accountId: account, folderPath: folder, messageId: colonBearing
        )
        #expect(!belongsToFolder(wouldBeKey))
        // The mint refuses it, so `contentKey` never produces that key.
        #expect(MessageIdentity.usableRfc822Tail(colonBearing) == nil)
        #expect(key("4210", rfc: colonBearing, space: .uidAddressed) != wouldBeKey)
    }

    @Test("A usable RFC id becomes the tail — the same message keys identically across a UID renumber")
    func usableRfcBecomesTheTailAcrossRenumbers() {
        // One Message-ID, three wire spellings, three different UIDs — exactly
        // what a UIDVALIDITY renumber produces. This is the whole reason the
        // change exists: the body and FTS rows must NOT move.
        let spellings = ["a.b+c@example.com", "<a.b+c@example.com>", "  <a.b+c@example.com>  "]
        let uids = ["11", "9021", "3"]
        var minted = Set<String>()
        for (uid, raw) in zip(uids, spellings) {
            let k = key(uid, rfc: raw, space: .uidAddressed)
            #expect(belongsToFolder(k), "\(raw): key left its own folder")
            #expect(k != key(uid, rfc: nil, space: .uidAddressed), "\(raw): tail did not come from the RFC id")
            minted.insert(k)
        }
        #expect(minted.count == 1)

        // Cheap validity checks on the tail (deliberately NOT a disjointness proof).
        let tail = MessageIdentity.usableRfc822Tail("<a.b+c@example.com>")
        #expect(tail?.contains(":") == false)
        #expect(tail?.split(separator: "@", omittingEmptySubsequences: false).count == 2)
    }

    @Test("No two DISTINCT messages in a folder share a content key, except through a duplicate RFC Message-ID")
    func distinctMessagesCollideOnlyThroughADuplicateRfc() {
        struct Msg {
            let label: String
            let providerId: String
            let rfc: String?
        }

        let corpus: [Msg] = [
            // Ordinary rfc-having IMAP rows.
            Msg(label: "uid 101", providerId: "101", rfc: "one@example.com"),
            Msg(label: "uid 102", providerId: "102", rfc: "<two@example.com>"),
            // rfc-less rows — these keep the provider-id tail.
            Msg(label: "uid 103 rfc-less", providerId: "103", rfc: nil),
            Msg(label: "uid 104 blank rfc", providerId: "104", rfc: "   "),
            // Present but unusable RFC values — also the provider-id tail.
            Msg(label: "uid 105 unbalanced rfc", providerId: "105", rfc: "<three@example.com"),
            Msg(label: "uid 106 colon rfc", providerId: "106", rfc: "four@[IPv6:2001:db8::1]"),
            // The census shapes: a `.imap` account whose PROVIDER id contains '@'.
            // Both are derived from the same message's own Message-ID, so both
            // candidate tails are the identical string for that message.
            Msg(label: "uid-less fetch", providerId: "five@example.com", rfc: "five@example.com"),
            Msg(label: "demo send", providerId: "six@domain.com", rfc: "<six@domain.com>"),
            // THE ONE ACCEPTED COLLAPSE: a different message carrying a duplicate
            // Message-ID (buggy sender, or a duplicate delivery).
            Msg(label: "uid 201 duplicate rfc", providerId: "201", rfc: "one@example.com")
        ]

        var collisions: [Set<String>] = []
        for i in corpus.indices {
            for j in corpus.indices where j > i {
                let a = corpus[i]
                let b = corpus[j]
                #expect(a.providerId != b.providerId, "corpus bug: \(a.label)/\(b.label) are not distinct messages")
                guard key(a.providerId, rfc: a.rfc, space: .uidAddressed)
                        == key(b.providerId, rfc: b.rfc, space: .uidAddressed) else { continue }
                collisions.append([a.label, b.label])
                // THE INVARIANT: a collision is admissible ONLY when both sides
                // carry the SAME usable RFC Message-ID.
                let ra = MessageIdentity.usableRfc822Tail(a.rfc)
                let rb = MessageIdentity.usableRfc822Tail(b.rfc)
                #expect(
                    ra != nil && ra == rb,
                    "\(a.label) collided with \(b.label) through something other than a duplicate Message-ID"
                )
            }
        }

        // Two-sided: the "except" clause must actually be EXERCISED or the
        // invariant above holds vacuously. Exactly one pair may collide, and it
        // must be the duplicate-Message-ID pair.
        #expect(collisions.count == 1)
        #expect(collisions.first == ["uid 101", "uid 201 duplicate rfc"])

        // And no message's key leaves its own folder.
        for msg in corpus {
            #expect(
                belongsToFolder(key(msg.providerId, rfc: msg.rfc, space: .uidAddressed)),
                "\(msg.label)"
            )
        }
    }

    @Test("AccountProvider.contentKeySpace maps every provider, and no provider's key escapes its folder")
    func providerLadderMapsEveryProvider() {
        // Server-assigned ids that are never reassigned — must not re-key.
        #expect(AccountProvider.gmail.contentKeySpace == .stableProviderId)
        #expect(AccountProvider.outlook.contentKeySpace == .stableProviderId)
        // Mutable, reusable UID addresses — RFC-first.
        #expect(AccountProvider.imap.contentKeySpace == .uidAddressed)
        #expect(AccountProvider.icloud.contentKeySpace == .uidAddressed)
        // Calendar-only, unreachable from every content-key site. Pinned to the
        // byte-identical space so it can never silently re-key a store.
        #expect(AccountProvider.caldav.contentKeySpace == .stableProviderId)

        // System property across the whole ladder: whatever the space, and even
        // with a colon-bearing RFC value under a folder path that itself contains
        // the hierarchy delimiter, the key belongs to its OWN folder and not to
        // the parent — the `nestedSiblingFolderSurvivesTheParentPurge` property,
        // restated for content keys.
        let nested = "Drafts:Sub"
        for provider in [AccountProvider.gmail, .outlook, .imap, .icloud, .caldav] {
            let minted = MessageIdentity.contentKey(
                accountId: account,
                folderPath: nested,
                providerMessageId: "77",
                rfc822MessageId: "a@[IPv6:2001:db8::1]",
                space: provider.contentKeySpace
            )
            #expect(
                MessageIdentity.headerIdBelongsToFolder(minted, accountId: account, folderPath: nested),
                "\(provider)"
            )
            #expect(
                !MessageIdentity.headerIdBelongsToFolder(minted, accountId: account, folderPath: "Drafts"),
                "\(provider)"
            )
        }
    }
}
