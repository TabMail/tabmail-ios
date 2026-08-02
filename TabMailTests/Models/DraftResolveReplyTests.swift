/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("Draft key parsing")
struct DraftKeyParsingTests {

    @Test("draftKey for reply encodes accountId and stableId")
    func replyDraftKey() {
        let key = Draft.draftKey(replyTo: "acct1:msg@example.com", isForward: false, newId: nil)
        #expect(key == "reply:acct1:msg@example.com")
    }

    @Test("draftKey for forward encodes accountId and stableId")
    func forwardDraftKey() {
        let key = Draft.draftKey(replyTo: "acct1:msg@example.com", isForward: true, newId: nil)
        #expect(key == "forward:acct1:msg@example.com")
    }

    @Test("draftKey for new compose uses provided UUID")
    func newDraftKey() {
        let key = Draft.draftKey(replyTo: nil, isForward: false, newId: "test-uuid")
        #expect(key == "new:test-uuid")
    }

    @Test("draftKey for new compose generates UUID when nil")
    func newDraftKeyGenerated() {
        let key = Draft.draftKey(replyTo: nil, isForward: false, newId: nil)
        #expect(key.hasPrefix("new:"))
        #expect(key.count > "new:".count) // UUID appended
    }

    @Test("draftKey roundtrip: stableId can be extracted from reply key")
    func roundtripReply() {
        let stableKey = "myAccount:some-rfc822@host.com"
        let key = Draft.draftKey(replyTo: stableKey, isForward: false, newId: nil)
        // Parse it back
        #expect(key.hasPrefix("reply:"))
        let rest = String(key.dropFirst("reply:".count))
        let colonIdx = rest.firstIndex(of: ":")!
        let accountId = String(rest[rest.startIndex..<colonIdx])
        let stableId = String(rest[rest.index(after: colonIdx)...])
        #expect(accountId == "myAccount")
        #expect(stableId == "some-rfc822@host.com")
    }

    @Test("draftKey roundtrip: stableId with colons preserved")
    func roundtripWithColons() {
        // rfc822 message IDs can contain colons
        let stableKey = "acct:complex:id:with:colons@host.com"
        let key = Draft.draftKey(replyTo: stableKey, isForward: false, newId: nil)
        let rest = String(key.dropFirst("reply:".count))
        let colonIdx = rest.firstIndex(of: ":")!
        let accountId = String(rest[rest.startIndex..<colonIdx])
        let stableId = String(rest[rest.index(after: colonIdx)...])
        #expect(accountId == "acct")
        #expect(stableId == "complex:id:with:colons@host.com")
    }

    @Test("ActiveAgentTracker.messageStableId parsing matches draftKey format")
    @MainActor func trackerParsingConsistency() {
        // The session key for message-detail is "msg:{accountId}:{stableId}"
        // This should parse correctly via ActiveAgentTracker.messageStableId
        let result = ActiveAgentTracker.messageStableId(from: "msg:acct1:rfc822@example.com")
        #expect(result?.accountId == "acct1")
        #expect(result?.stableId == "rfc822@example.com")
    }
}

@Suite("Locally authored draft reopen authority")
struct LocallyAuthoredDraftOpenAuthorityTests {
    private func draft(
        accountId: String = "acc1",
        epoch: String = "E1",
        serverId: String? = nil,
        status: String? = "pushed"
    ) -> Draft {
        var value = Draft(
            id: "draft-1", accountId: accountId,
            toJSON: "[]", ccJSON: "[]", bccJSON: "[]",
            subject: "subject", body: "body", replyToId: nil,
            isForward: false, editHistoryJSON: nil, createdAt: 1, updatedAt: 1,
            serverDraftId: serverId, serverPushStatus: status,
            rfc822MessageId: "draft@example.com", attachmentsDirName: nil)
        value.instanceEpoch = epoch
        return value
    }

    @Test("Every locally-authored draft handoff rejects an owner, generation, status, runtime, or native-address replacement")
    func exactHandoffAuthority() {
        let placeholder = PendingOperation.draftPlaceholderMessageId(
            draftId: "draft-1", instanceEpoch: "E1")
        let cases: [(LocallyAuthoredDraftOpenAuthority, Draft)] = [
            (.init(
                draftId: "draft-1", accountId: "acc1", instanceEpoch: "E1",
                serverPushStatus: "pushed", runtimeKind: .imap,
                address: .placeholder(messageId: placeholder)),
             draft()),
            (.init(
                draftId: "draft-1", accountId: "acc1", instanceEpoch: "E1",
                serverPushStatus: "pushed", runtimeKind: .gmail,
                address: .gmail(resourceId: "gmail-1", containedMessageId: "message-1")),
             draft(serverId: "gmail-1")),
            (.init(
                draftId: "draft-1", accountId: "acc1", instanceEpoch: "E1",
                serverPushStatus: "pushed", runtimeKind: .outlook,
                address: .outlook(graphId: "graph-1")),
             draft(serverId: "graph-1")),
            (.init(
                draftId: "draft-1", accountId: "acc1", instanceEpoch: "E1",
                serverPushStatus: "pushed", runtimeKind: .demo,
                address: .demo(localId: "demo-1")),
             draft(serverId: "demo-1")),
        ]

        for (authority, original) in cases {
            #expect(authority.matches(original, runtimeKind: authority.runtimeKind))
            #expect(!authority.matches(
                draft(accountId: "acc2", serverId: original.serverDraftId),
                runtimeKind: authority.runtimeKind))
            #expect(!authority.matches(
                draft(epoch: "E2", serverId: original.serverDraftId),
                runtimeKind: authority.runtimeKind))
            #expect(!authority.matches(
                draft(serverId: original.serverDraftId, status: "dirty"),
                runtimeKind: authority.runtimeKind))
            #expect(!authority.matches(original, runtimeKind: .unknown))
            // SUBTRACT — v2final's placeholder authority is the local
            // draftId+instanceEpoch owner, not a provider-native address.
            if case .placeholder = authority.address { continue }
            #expect(!authority.matches(
                draft(serverId: original.serverDraftId == nil ? "unexpected" : "replacement"),
                runtimeKind: authority.runtimeKind))
        }
    }
}
