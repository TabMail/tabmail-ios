/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Testing
@testable import TabMail

@Suite("Native provider action contract", .serialized, .processGlobalState)
struct ProviderMessageActionTests {
    @Test("Gmail routes setters and labels to only the named native copy")
    func gmailCommandsPreserveNativeIdentity() async throws {
        let server = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: "duplicate@example.com", providerMessageId: "target", labels: ["INBOX", "UNREAD"]),
            .init(rfc822MessageId: "duplicate@example.com", providerMessageId: "bystander", labels: ["INBOX", "UNREAD"])
        ])
        defer { server.close() }
        let provider: any EmailProvider = server.provider()
        let source = ProviderMessageSource(memberIds: ["target"], folderPath: "INBOX", admittedUidValidity: nil)
        for value in [true, false] {
            let read = try await provider.performMessageAction(.read(value), at: source)
            #expect(read.dispositionedMemberIds == ["target"])
            #expect(server.snapshot(providerMessageId: "target")?.isRead == value)
            _ = try await provider.performMessageAction(.flagged(value), at: source)
            #expect(server.snapshot(providerMessageId: "target")?.isFlagged == value)
            _ = try await provider.performMessageAction(.userLabel(id: "Label_1", add: value), at: source)
            #expect(server.snapshot(providerMessageId: "target")?.labels.contains("Label_1") == value)
        }
        let move = try await provider.performMessageAction(.move(destination: "Archive"), at: source)
        #expect(!move.addressChangesOnMove)
        #expect(move.provenDestinations.isEmpty)
        #expect(server.snapshot(providerMessageId: "target")?.labels == ["Archive", "UNREAD"])
        #expect(server.snapshot(providerMessageId: "bystander")?.labels == ["INBOX", "UNREAD"])
        #expect(server.modifyLog().allSatisfy { $0.providerMessageId == "target" })
        let before = server.modifyLog().count
        for action in [ProviderMessageAction.replied, .forwarded] {
            let outcome = try await provider.performMessageAction(action, at: source)
            #expect(outcome.dispositionedMemberIds == ["target"])
        }
        #expect(server.modifyLog().count == before)
    }

    @Test("Graph routes setters and labels and returns the move response's native address")
    func graphCommandsPreserveNativeIdentityAndDestination() async throws {
        let server = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: "duplicate@example.com", providerMessageId: "target", folderId: "Source"),
            .init(rfc822MessageId: "duplicate@example.com", providerMessageId: "bystander", folderId: "Source")
        ])
        defer { server.close() }
        let provider: any EmailProvider = server.provider()
        let source = ProviderMessageSource(memberIds: ["target"], folderPath: "Source", admittedUidValidity: nil)
        for value in [true, false] {
            _ = try await provider.performMessageAction(.read(value), at: source)
            #expect(server.snapshot(providerMessageId: "target")?.isRead == value)
            _ = try await provider.performMessageAction(.flagged(value), at: source)
            #expect(server.snapshot(providerMessageId: "target")?.isFlagged == value)
            _ = try await provider.performMessageAction(.userLabel(id: "Label_1", add: value), at: source)
            #expect(server.categories(providerMessageId: "target")?.contains("Label_1") == value)
        }
        let before = server.mutationLog()
        for action in [ProviderMessageAction.replied, .forwarded] {
            let outcome = try await provider.performMessageAction(action, at: source)
            #expect(outcome.dispositionedMemberIds == ["target"])
        }
        #expect(server.mutationLog() == before)
        let move = try await provider.performMessageAction(.move(destination: "Archive"), at: source)
        #expect(move.addressChangesOnMove)
        #expect(move.dispositionedMemberIds == ["target"])
        #expect(move.provenDestinations.count == 1)
        guard move.provenDestinations.count == 1 else { return }
        let address = move.provenDestinations[0]
        #expect(address.sourceProviderId == "target")
        #expect(address.destinationUidValidity == nil)
        #expect(server.snapshot(providerMessageId: address.destinationProviderId)?.folderId == "Archive")
        #expect(server.snapshot(providerMessageId: "target") == nil)
        #expect(server.snapshot(providerMessageId: "bystander")?.folderId == "Source")
    }

    @Test("REST action outcomes attribute absence and bank only one addressed member")
    func restActionOutcomesBankOnlyOneMember() async throws {
        let gmail = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: "live@example.com", providerMessageId: "live", labels: ["UNREAD"])
        ])
        let graph = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: "live@example.com", providerMessageId: "live", folderId: "Source")
        ])
        defer { gmail.close(); graph.close() }
        let providers: [any EmailProvider] = [gmail.provider(), graph.provider()]
        for provider in providers {
            let gone = try await provider.performMessageAction(.read(true), at: .init(
                memberIds: ["gone", "live"], folderPath: "Source", admittedUidValidity: nil))
            #expect(gone.dispositionedMemberIds == ["gone"])
            #expect(gone.confirmedGoneMemberIds == ["gone"])
            #expect(gone.provenDestinations.isEmpty)
            let live = try await provider.performMessageAction(.read(true), at: .init(
                memberIds: ["live", "later"], folderPath: "Source", admittedUidValidity: nil))
            #expect(live.dispositionedMemberIds == ["live"])
            #expect(live.confirmedGoneMemberIds.isEmpty)
        }
        #expect(gmail.modifyLog().map(\.providerMessageId) == ["gone", "live"])
        #expect(graph.snapshot(providerMessageId: "live")?.isRead == true)
    }

    @Test("Remote label actions settle only the first native member and leave the tail untouched")
    func labelActionsLeaveTailUnsettled() async throws {
        let gmail = StatefulGmailActionServer(messages: [
            .init(rfc822MessageId: "duplicate@example.com", providerMessageId: "first", labels: []),
            .init(rfc822MessageId: "duplicate@example.com", providerMessageId: "tail", labels: [])
        ])
        let graph = StatefulExchangeActionServer(messages: [
            .init(rfc822MessageId: "duplicate@example.com", providerMessageId: "first", folderId: "Source"),
            .init(rfc822MessageId: "duplicate@example.com", providerMessageId: "tail", folderId: "Source")
        ])
        defer { gmail.close(); graph.close() }
        let providers: [any EmailProvider] = [gmail.provider(), graph.provider()]
        for provider in providers {
            for add in [true, false] {
                let outcome = try await provider.performMessageAction(.userLabel(id: "Label_1", add: add), at: .init(
                    memberIds: ["first", "tail"], folderPath: "Source", admittedUidValidity: nil))
                #expect(outcome.dispositionedMemberIds == ["first"])
                #expect(outcome.confirmedGoneMemberIds.isEmpty)
            }
        }
        #expect(gmail.modifyLog().map(\.providerMessageId) == ["first", "first"])
        #expect(gmail.snapshot(providerMessageId: "tail")?.labels.isEmpty == true)
        #expect(graph.categories(providerMessageId: "tail")?.isEmpty == true)
    }

    @Test("Demo explicitly settles unrepresented remote flags and labels")
    func demoExplicitNoOps() async throws {
        let provider: any EmailProvider = DemoProvider(accountId: "demo-action-test")
        for action in [ProviderMessageAction.replied, .forwarded, .userLabel(id: "Label_1", add: true), .userLabel(id: "Label_1", add: false)] {
            let outcome = try await provider.performMessageAction(action, at: .init(
                memberIds: ["one", "two"], folderPath: "Source", admittedUidValidity: nil))
            #expect(outcome.dispositionedMemberIds == ["one", "two"])
            #expect(outcome.provenDestinations.isEmpty)
            #expect(outcome.confirmedGoneMemberIds.isEmpty)
        }
    }
}
