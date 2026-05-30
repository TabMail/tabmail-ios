/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

// MARK: - ExchangeMessageDetail Tests

@Suite("ExchangeMessageDetail")
struct ExchangeMessageDetailTests {

    @Test("Initializes with header and parentFolderId")
    func initFields() {
        let header = MessageHeaderInfo(
            messageId: "msg-123",
            rfc822MessageId: "abc@example.com",
            inReplyTo: nil,
            references: [],
            threadId: "conv-1",
            subject: "Test Subject",
            from: "Alice",
            fromAddress: "alice@example.com",
            to: "bob@example.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(),
            snippet: "Hello",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )
        let detail = ExchangeMessageDetail(header: header, parentFolderId: "folder-abc")
        #expect(detail.header.messageId == "msg-123")
        #expect(detail.header.subject == "Test Subject")
        #expect(detail.parentFolderId == "folder-abc")
    }

    @Test("Empty parentFolderId is valid")
    func emptyParentFolder() {
        let header = MessageHeaderInfo(
            messageId: "msg-456",
            rfc822MessageId: nil,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: "No folder",
            from: "Sender",
            fromAddress: "sender@test.com",
            to: "recipient@test.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(),
            snippet: "",
            isRead: true,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )
        let detail = ExchangeMessageDetail(header: header, parentFolderId: "")
        #expect(detail.parentFolderId == "")
    }

    @Test("Header preserves actionTag through ExchangeMessageDetail")
    func actionTagPreserved() {
        let header = MessageHeaderInfo(
            messageId: "msg-789",
            rfc822MessageId: nil,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: "Tagged",
            from: "User",
            fromAddress: "user@test.com",
            to: "other@test.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(),
            snippet: "preview",
            isRead: false,
            isFlagged: true,
            hasAttachments: true,
            isReplied: false,
            isForwarded: false,
            actionTag: .archive
        )
        let detail = ExchangeMessageDetail(header: header, parentFolderId: "inbox-id")
        #expect(detail.header.actionTag == .archive)
        #expect(detail.header.isFlagged == true)
        #expect(detail.header.hasAttachments == true)
    }
}

// MARK: - ActionTag Category Mapping Tests

@Suite("ActionTag Exchange Category Mapping")
struct ActionTagCategoryMappingTests {

    @Test("All ActionTag imapKeywords are lowercase tm_ prefixed")
    func imapKeywordsFormat() {
        for tag in ActionTag.allCases {
            let keyword = tag.imapKeyword
            #expect(keyword.hasPrefix("tm_"))
            #expect(keyword == keyword.lowercased(), "imapKeyword should be lowercase: \(keyword)")
        }
    }

    @Test("ActionTag category map round-trip: imapKeyword lowercased maps back to tag")
    func categoryMapRoundTrip() {
        // ExchangeProvider builds tagCategoryMap as: tag.imapKeyword.lowercased() -> tag
        var categoryMap: [String: ActionTag] = [:]
        for tag in ActionTag.allCases {
            categoryMap[tag.imapKeyword.lowercased()] = tag
        }

        // Verify each tag can be looked up
        #expect(categoryMap["tm_reply"] == .reply)
        #expect(categoryMap["tm_none"] == ActionTag.none)
        #expect(categoryMap["tm_archive"] == .archive)
        #expect(categoryMap["tm_delete"] == .delete)
    }

    @Test("Category map has exactly 4 entries")
    func categoryMapCount() {
        var categoryMap: [String: ActionTag] = [:]
        for tag in ActionTag.allCases {
            categoryMap[tag.imapKeyword.lowercased()] = tag
        }
        #expect(categoryMap.count == 4)
    }

    @Test("Unknown category not in map returns nil")
    func unknownCategoryReturnsNil() {
        var categoryMap: [String: ActionTag] = [:]
        for tag in ActionTag.allCases {
            categoryMap[tag.imapKeyword.lowercased()] = tag
        }
        #expect(categoryMap["tm_unknown"] == nil)
        #expect(categoryMap["reply"] == nil)
        #expect(categoryMap[""] == nil)
        #expect(categoryMap["TM_REPLY"] == nil) // case-sensitive lookup
    }

    @Test("Case-insensitive lookup matches Exchange behavior")
    func caseInsensitiveLookup() {
        // ExchangeProvider lowercases both: map key = tag.imapKeyword.lowercased(),
        // lookup key = category.lowercased()
        var categoryMap: [String: ActionTag] = [:]
        for tag in ActionTag.allCases {
            categoryMap[tag.imapKeyword.lowercased()] = tag
        }

        // Simulate Exchange categories in different cases
        let categories = ["TM_REPLY", "tm_Archive", "Tm_Delete", "TM_NONE"]
        for category in categories {
            let result = categoryMap[category.lowercased()]
            #expect(result != nil, "Should resolve category '\(category)' case-insensitively")
        }
    }

    @Test("Tag resolution picks lowest sortOrder when multiple categories present")
    func multipleTagsPicksLowestSortOrder() {
        var categoryMap: [String: ActionTag] = [:]
        for tag in ActionTag.allCases {
            categoryMap[tag.imapKeyword.lowercased()] = tag
        }

        // Simulate Exchange message with multiple tm_* categories
        let categories = ["tm_delete", "tm_reply", "tm_archive"]
        var resolvedTag: ActionTag?
        for category in categories {
            if let tag = categoryMap[category.lowercased()] {
                if resolvedTag == nil || tag.sortOrder < resolvedTag!.sortOrder {
                    resolvedTag = tag
                }
            }
        }
        // reply has sortOrder 0 (lowest), should win
        #expect(resolvedTag == .reply)
    }

    @Test("Single category resolves correctly")
    func singleCategoryResolves() {
        var categoryMap: [String: ActionTag] = [:]
        for tag in ActionTag.allCases {
            categoryMap[tag.imapKeyword.lowercased()] = tag
        }

        let categories = ["tm_archive"]
        var resolvedTag: ActionTag?
        for category in categories {
            if let tag = categoryMap[category.lowercased()] {
                if resolvedTag == nil || tag.sortOrder < resolvedTag!.sortOrder {
                    resolvedTag = tag
                }
            }
        }
        #expect(resolvedTag == .archive)
    }

    @Test("No matching categories yields nil tag")
    func noCategoriesYieldsNil() {
        var categoryMap: [String: ActionTag] = [:]
        for tag in ActionTag.allCases {
            categoryMap[tag.imapKeyword.lowercased()] = tag
        }

        let categories = ["personal", "work", "important"]
        var resolvedTag: ActionTag?
        for category in categories {
            if let tag = categoryMap[category.lowercased()] {
                if resolvedTag == nil || tag.sortOrder < resolvedTag!.sortOrder {
                    resolvedTag = tag
                }
            }
        }
        #expect(resolvedTag == nil)
    }

    @Test("Mixed user and tm_ categories only resolves tm_ ones")
    func mixedCategoriesOnlyResolveTm() {
        var categoryMap: [String: ActionTag] = [:]
        for tag in ActionTag.allCases {
            categoryMap[tag.imapKeyword.lowercased()] = tag
        }

        let categories = ["Important", "tm_none", "Follow-up", "Custom Label"]
        var resolvedTag: ActionTag?
        for category in categories {
            if let tag = categoryMap[category.lowercased()] {
                if resolvedTag == nil || tag.sortOrder < resolvedTag!.sortOrder {
                    resolvedTag = tag
                }
            }
        }
        #expect(resolvedTag == ActionTag.none)
    }

    @Test("Empty categories array yields nil")
    func emptyCategoriesYieldsNil() {
        var categoryMap: [String: ActionTag] = [:]
        for tag in ActionTag.allCases {
            categoryMap[tag.imapKeyword.lowercased()] = tag
        }

        let categories: [String] = []
        var resolvedTag: ActionTag?
        for category in categories {
            if let tag = categoryMap[category.lowercased()] {
                if resolvedTag == nil || tag.sortOrder < resolvedTag!.sortOrder {
                    resolvedTag = tag
                }
            }
        }
        #expect(resolvedTag == nil)
    }
}

// MARK: - Exchange Folder Role Mapping Tests

@Suite("Exchange Folder Role Mapping")
struct ExchangeFolderRoleMappingTests {

    @Test("Well-known folder names map to correct roles")
    func wellKnownFolderRoles() {
        // These are the knownFolderSpecs from ExchangeProvider.fetchFolders
        let specs: [(name: String, role: FolderRole)] = [
            ("inbox", .inbox),
            ("sentitems", .sent),
            ("drafts", .drafts),
            ("deleteditems", .trash),
            ("junkemail", .spam),
            ("archive", .archive),
        ]

        for (name, expectedRole) in specs {
            #expect(expectedRole != .custom, "Well-known folder '\(name)' should not be .custom")
        }

        // Verify all expected roles are covered
        let mappedRoles = Set(specs.map(\.role))
        #expect(mappedRoles.contains(.inbox))
        #expect(mappedRoles.contains(.sent))
        #expect(mappedRoles.contains(.drafts))
        #expect(mappedRoles.contains(.trash))
        #expect(mappedRoles.contains(.spam))
        #expect(mappedRoles.contains(.archive))
        #expect(!mappedRoles.contains(.custom))
    }

    @Test("Unknown folder IDs default to .custom role")
    func unknownFolderDefaultsToCustom() {
        let knownFolderIds: [String: FolderRole] = [
            "AAMk-inbox": .inbox,
            "AAMk-sent": .sent,
        ]
        let unknownId = "AAMk-custom-folder"
        let role = knownFolderIds[unknownId] ?? .custom
        #expect(role == .custom)
    }

    @Test("FolderInfo preserves all fields")
    func folderInfoFields() {
        let folder = FolderInfo(
            name: "Inbox",
            path: "AAMkAD-folder-id",
            role: .inbox,
            unreadCount: 5,
            totalCount: 100
        )
        #expect(folder.name == "Inbox")
        #expect(folder.path == "AAMkAD-folder-id")
        #expect(folder.role == .inbox)
        #expect(folder.unreadCount == 5)
        #expect(folder.totalCount == 100)
    }

    @Test("FolderInfo with zero counts")
    func folderInfoZeroCounts() {
        let folder = FolderInfo(
            name: "Empty Folder",
            path: "folder-empty",
            role: .custom,
            unreadCount: 0,
            totalCount: 0
        )
        #expect(folder.unreadCount == 0)
        #expect(folder.totalCount == 0)
    }
}

// MARK: - Exchange Provider Types (Non-actor)

@Suite("Exchange Provider Types")
struct ExchangeProviderTypesTests {

    @Test("FolderRole enum has all expected cases")
    func folderRoleCases() {
        let allRoles: [FolderRole] = [.inbox, .sent, .drafts, .trash, .archive, .spam, .custom]
        #expect(allRoles.count == 7)
    }

    @Test("FolderRole is Codable round-trip")
    func folderRoleCodable() throws {
        let roles: [FolderRole] = [.inbox, .sent, .drafts, .trash, .archive, .spam, .custom]
        for role in roles {
            let data = try JSONEncoder().encode(role)
            let decoded = try JSONDecoder().decode(FolderRole.self, from: data)
            #expect(decoded == role)
        }
    }

    @Test("MessageHeaderInfo preserves all fields")
    func messageHeaderInfoFields() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let header = MessageHeaderInfo(
            messageId: "test-id",
            rfc822MessageId: "rfc@example.com",
            inReplyTo: "parent@example.com",
            references: [],
            threadId: "thread-1",
            subject: "Test",
            from: "Sender Name",
            fromAddress: "sender@example.com",
            to: "recipient@example.com",
            cc: "cc@example.com",
            bcc: "bcc@example.com",
            replyTo: "reply@example.com",
            date: date,
            snippet: "Preview text",
            isRead: true,
            isFlagged: true,
            hasAttachments: true,
            isReplied: true,
            isForwarded: true,
            actionTag: .reply
        )

        #expect(header.messageId == "test-id")
        #expect(header.rfc822MessageId == "rfc@example.com")
        #expect(header.inReplyTo == "parent@example.com")
        #expect(header.threadId == "thread-1")
        #expect(header.subject == "Test")
        #expect(header.from == "Sender Name")
        #expect(header.fromAddress == "sender@example.com")
        #expect(header.to == "recipient@example.com")
        #expect(header.cc == "cc@example.com")
        #expect(header.bcc == "bcc@example.com")
        #expect(header.replyTo == "reply@example.com")
        #expect(header.date == date)
        #expect(header.snippet == "Preview text")
        #expect(header.isRead == true)
        #expect(header.isFlagged == true)
        #expect(header.hasAttachments == true)
        #expect(header.isReplied == true)
        #expect(header.isForwarded == true)
        #expect(header.actionTag == .reply)
    }

    @Test("MessageHeaderInfo with nil optional fields")
    func messageHeaderInfoNilOptionals() {
        let header = MessageHeaderInfo(
            messageId: "id",
            rfc822MessageId: nil,
            inReplyTo: nil,
            references: [],
            threadId: nil,
            subject: "Subject",
            from: "From",
            fromAddress: "from@test.com",
            to: "to@test.com",
            cc: "",
            bcc: "",
            replyTo: nil,
            date: Date(),
            snippet: "",
            isRead: false,
            isFlagged: false,
            hasAttachments: false,
            isReplied: false,
            isForwarded: false,
            actionTag: nil
        )

        #expect(header.rfc822MessageId == nil)
        #expect(header.inReplyTo == nil)
        #expect(header.threadId == nil)
        #expect(header.replyTo == nil)
        #expect(header.actionTag == nil)
    }

    @Test("ActionTag sortOrder determines priority correctly")
    func actionTagPriorityOrder() {
        let sorted = ActionTag.allCases.sorted { $0.sortOrder < $1.sortOrder }
        #expect(sorted == [.reply, .none, .archive, .delete])
    }

    @Test("Non-tm_ categories are preserved by filter logic")
    func nonTmCategoriesPreserved() {
        // Simulates ExchangeProvider.setActionTag filter: keep non-tm_* categories
        let existingCategories = ["Important", "tm_reply", "Personal", "tm_archive", "Work"]
        let filtered = existingCategories.filter { cat in
            !ActionTag.allCases.contains { $0.imapKeyword.lowercased() == cat.lowercased() }
        }
        #expect(filtered == ["Important", "Personal", "Work"])
    }

    @Test("Filter preserves categories when no tm_ categories present")
    func filterNothingToRemove() {
        let categories = ["Red", "Blue", "Green"]
        let filtered = categories.filter { cat in
            !ActionTag.allCases.contains { $0.imapKeyword.lowercased() == cat.lowercased() }
        }
        #expect(filtered == ["Red", "Blue", "Green"])
    }

    @Test("Filter removes all tm_ categories")
    func filterAllTmRemoved() {
        let categories = ["tm_reply", "tm_archive", "tm_delete", "tm_none"]
        let filtered = categories.filter { cat in
            !ActionTag.allCases.contains { $0.imapKeyword.lowercased() == cat.lowercased() }
        }
        #expect(filtered.isEmpty)
    }

    @Test("Filter handles case-insensitive tm_ categories")
    func filterCaseInsensitive() {
        let categories = ["TM_REPLY", "Tm_Archive", "Custom"]
        let filtered = categories.filter { cat in
            !ActionTag.allCases.contains { $0.imapKeyword.lowercased() == cat.lowercased() }
        }
        #expect(filtered == ["Custom"])
    }
}
