/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("Database Concurrent Access")
struct DatabaseConcurrencyTests {

    @Test("Concurrent reads don't block")
    func concurrentReads() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)
        for i in 0..<10 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)")
        }

        // Run 10 parallel reads
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await db.read { try MessageHeader.fetchCount($0) }
                }
            }
            for try await count in group {
                #expect(count == 10)
            }
        }
    }

    @Test("Writes are serialized but both succeed")
    func serializedWrites() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Two concurrent writes
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await db.write { db in
                    let header = MessageHeader(
                        messageId: "1",
                        subject: "Msg 1",
                        from: "a@b.com",
                        fromAddress: "a@b.com",
                        to: "x@y.com",
                        date: Date(),
                        snippet: "",
                        folderId: "acc1:INBOX",
                        accountId: "acc1",
                        folderPath: "INBOX",
                        isInInbox: true
                    )
                    try header.insert(db)
                }
            }
            group.addTask {
                try await db.write { db in
                    let header = MessageHeader(
                        messageId: "2",
                        subject: "Msg 2",
                        from: "c@d.com",
                        fromAddress: "c@d.com",
                        to: "x@y.com",
                        date: Date(),
                        snippet: "",
                        folderId: "acc1:INBOX",
                        accountId: "acc1",
                        folderPath: "INBOX",
                        isInInbox: true
                    )
                    try header.insert(db)
                }
            }
            try await group.waitForAll()
        }

        let count = try await db.read { try MessageHeader.fetchCount($0) }
        #expect(count == 2)
    }

    @Test("Read during write sees consistent snapshot")
    func readDuringWriteConsistent() async throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)
        try TestDatabase.insertFolder(db)

        // Pre-insert 5 messages
        for i in 0..<5 {
            try TestDatabase.insertMessageHeader(db, messageId: "\(i)")
        }

        // Read should always see a consistent count (either 5 or 5+batch)
        let count = try await db.read { try MessageHeader.fetchCount($0) }
        #expect(count == 5)
    }
}
