/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
import GRDB
@testable import TabMail

@Suite("PendingCalendarOperation")
struct PendingCalendarOperationTests {

    @Test("Init sets defaults correctly")
    func initDefaults() {
        let op = PendingCalendarOperation(
            operationType: .create,
            accountId: "acc1",
            arguments: ["summary": .string("Meeting")]
        )
        #expect(op.operationType == "create")
        #expect(op.accountId == "acc1")
        #expect(op.status == PendingStatus.queued.rawValue)
        #expect(op.retryCount == 0)
        #expect(op.eventId == nil)
        #expect(!op.id.isEmpty)
    }

    @Test("Unique IDs generated")
    func uniqueIds() {
        let op1 = PendingCalendarOperation(operationType: .create, accountId: "acc1", arguments: [:])
        let op2 = PendingCalendarOperation(operationType: .create, accountId: "acc1", arguments: [:])
        #expect(op1.id != op2.id)
    }

    @Test("Arguments JSON round-trip with string values")
    func argsStringRoundTrip() {
        let op = PendingCalendarOperation(
            operationType: .create,
            accountId: "acc1",
            arguments: ["summary": .string("Team Standup"), "location": .string("Room A")]
        )
        let args = op.arguments
        if case .string(let val) = args["summary"] {
            #expect(val == "Team Standup")
        } else {
            #expect(Bool(false), "Expected string value for summary")
        }
        if case .string(let val) = args["location"] {
            #expect(val == "Room A")
        } else {
            #expect(Bool(false), "Expected string value for location")
        }
    }

    @Test("Arguments JSON round-trip with int values")
    func argsIntRoundTrip() {
        let op = PendingCalendarOperation(
            operationType: .edit,
            accountId: "acc1",
            arguments: ["duration": .int(60)]
        )
        let args = op.arguments
        if case .int(let val) = args["duration"] {
            #expect(val == 60)
        } else {
            #expect(Bool(false), "Expected int value for duration")
        }
    }

    @Test("Arguments JSON round-trip with bool values")
    func argsBoolRoundTrip() {
        let op = PendingCalendarOperation(
            operationType: .edit,
            accountId: "acc1",
            arguments: ["allDay": .bool(true)]
        )
        let args = op.arguments
        if case .bool(let val) = args["allDay"] {
            #expect(val == true)
        } else {
            #expect(Bool(false), "Expected bool value for allDay")
        }
    }

    @Test("Empty arguments serializes to {}")
    func emptyArgs() {
        let op = PendingCalendarOperation(operationType: .delete, accountId: "acc1", arguments: [:])
        #expect(op.argumentsJSON == "{}")
    }

    @Test("EventId is stored")
    func eventIdStored() {
        let op = PendingCalendarOperation(
            operationType: .edit,
            accountId: "acc1",
            eventId: "event-123",
            arguments: ["summary": .string("Updated")]
        )
        #expect(op.eventId == "event-123")
    }

    @Test("All operation types have correct raw values")
    func operationTypeRawValues() {
        #expect(CalendarOperationType.create.rawValue == "create")
        #expect(CalendarOperationType.edit.rawValue == "edit")
        #expect(CalendarOperationType.delete.rawValue == "delete")
    }

    @Test("generateGoogleEventId format")
    func googleEventIdFormat() {
        let uuid = "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
        let eventId = PendingCalendarOperation.generateGoogleEventId(from: uuid)
        // Should be "tm" + lowercase hex (no hyphens)
        #expect(eventId.hasPrefix("tm"))
        #expect(!eventId.contains("-"))
        #expect(eventId == eventId.lowercased())
    }

    @Test("generateGoogleEventId is deterministic")
    func googleEventIdDeterministic() {
        let uuid = "12345678-1234-1234-1234-123456789012"
        let id1 = PendingCalendarOperation.generateGoogleEventId(from: uuid)
        let id2 = PendingCalendarOperation.generateGoogleEventId(from: uuid)
        #expect(id1 == id2)
    }

    @Test("generateGoogleEventId produces valid characters")
    func googleEventIdValidChars() {
        let uuid = UUID().uuidString
        let eventId = PendingCalendarOperation.generateGoogleEventId(from: uuid)
        // Google requires: lowercase a-v and digits 0-9
        // UUID hex uses a-f and 0-9, which are all valid
        let validChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        for scalar in eventId.unicodeScalars {
            #expect(validChars.contains(scalar), "Invalid character: \(scalar)")
        }
    }

    @Test("Arguments round-trip with double values")
    func argsDoubleRoundTrip() {
        let op = PendingCalendarOperation(
            operationType: .edit,
            accountId: "acc1",
            arguments: ["latitude": .double(37.7749)]
        )
        let args = op.arguments
        if case .double(let val) = args["latitude"] {
            #expect(abs(val - 37.7749) < 0.0001)
        } else {
            #expect(Bool(false), "Expected double value for latitude")
        }
    }

    @Test("Arguments round-trip with array values")
    func argsArrayRoundTrip() {
        let op = PendingCalendarOperation(
            operationType: .create,
            accountId: "acc1",
            arguments: ["attendees": .array([.string("a@b.com"), .string("c@d.com")])]
        )
        let args = op.arguments
        if case .array(let arr) = args["attendees"] {
            #expect(arr.count == 2)
        } else {
            #expect(Bool(false), "Expected array value for attendees")
        }
    }

    @Test("Arguments round-trip with nested dictionary")
    func argsNestedDictRoundTrip() {
        let op = PendingCalendarOperation(
            operationType: .create,
            accountId: "acc1",
            arguments: ["reminders": .dictionary(["useDefault": .bool(false)])]
        )
        let args = op.arguments
        if case .dictionary(let dict) = args["reminders"] {
            if case .bool(let val) = dict["useDefault"] {
                #expect(val == false)
            } else {
                #expect(Bool(false), "Expected bool value for useDefault")
            }
        } else {
            #expect(Bool(false), "Expected dictionary value for reminders")
        }
    }
}

@Suite("PendingCalendarOperation Persistence")
struct PendingCalendarOperationPersistenceTests {

    // MARK: - Insert / Fetch / Delete round-trip

    @Test("Insert and fetch round-trip preserves all fields")
    func insertFetchRoundTrip() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = PendingCalendarOperation(
            operationType: .create,
            accountId: "acc1",
            eventId: "evt-42",
            arguments: ["summary": .string("Standup"), "allDay": .bool(false)]
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingCalendarOperation.fetchOne($0, key: op.id) }
        #expect(fetched != nil)
        #expect(fetched?.id == op.id)
        #expect(fetched?.operationType == "create")
        #expect(fetched?.accountId == "acc1")
        #expect(fetched?.eventId == "evt-42")
        #expect(fetched?.status == PendingStatus.queued.rawValue)
        #expect(fetched?.retryCount == 0)
        #expect(fetched?.argumentsJSON == op.argumentsJSON)
    }

    @Test("Delete removes op from DB")
    func deleteRemovesOp() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = PendingCalendarOperation(operationType: .delete, accountId: "acc1", arguments: [:])
        try db.write { try op.insert($0) }
        try db.write { _ = try PendingCalendarOperation.deleteOne($0, key: op.id) }

        let fetched = try db.read { try PendingCalendarOperation.fetchOne($0, key: op.id) }
        #expect(fetched == nil)
    }

    @Test("fetchAll returns all inserted ops")
    func fetchAllReturnsAll() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op1 = PendingCalendarOperation(operationType: .create, accountId: "acc1", arguments: ["s": .string("A")])
        let op2 = PendingCalendarOperation(operationType: .edit, accountId: "acc1", eventId: "e1", arguments: ["s": .string("B")])
        let op3 = PendingCalendarOperation(operationType: .delete, accountId: "acc1", eventId: "e2", arguments: [:])
        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        let all = try db.read { try PendingCalendarOperation.fetchAll($0) }
        #expect(all.count == 3)
    }

    // MARK: - Filter by status

    @Test("Filter by status returns matching ops only")
    func filterByStatus() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op1 = PendingCalendarOperation(operationType: .create, accountId: "acc1", arguments: [:])
        // op1 stays queued (default)
        var op2 = PendingCalendarOperation(operationType: .edit, accountId: "acc1", arguments: [:])
        op2.status = PendingStatus.inFlight.rawValue
        var op3 = PendingCalendarOperation(operationType: .delete, accountId: "acc1", arguments: [:])
        op3.status = PendingStatus.cancelled.rawValue

        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        let queued = try db.read {
            try PendingCalendarOperation.filter(Column("status") == PendingStatus.queued.rawValue).fetchAll($0)
        }
        #expect(queued.count == 1)
        #expect(queued[0].id == op1.id)

        let inFlight = try db.read {
            try PendingCalendarOperation.filter(Column("status") == PendingStatus.inFlight.rawValue).fetchAll($0)
        }
        #expect(inFlight.count == 1)
        #expect(inFlight[0].id == op2.id)

        let cancelled = try db.read {
            try PendingCalendarOperation.filter(Column("status") == PendingStatus.cancelled.rawValue).fetchAll($0)
        }
        #expect(cancelled.count == 1)
        #expect(cancelled[0].id == op3.id)
    }

    // MARK: - Filter by accountId

    @Test("Filter by accountId returns only matching ops")
    func filterByAccountId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@b.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "c@d.com")

        let op1 = PendingCalendarOperation(operationType: .create, accountId: "acc1", arguments: [:])
        let op2 = PendingCalendarOperation(operationType: .create, accountId: "acc2", arguments: [:])
        let op3 = PendingCalendarOperation(operationType: .edit, accountId: "acc1", arguments: [:])
        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        let acc1Ops = try db.read {
            try PendingCalendarOperation.filter(Column("accountId") == "acc1").fetchAll($0)
        }
        #expect(acc1Ops.count == 2)
        #expect(acc1Ops.allSatisfy { $0.accountId == "acc1" })

        let acc2Ops = try db.read {
            try PendingCalendarOperation.filter(Column("accountId") == "acc2").fetchAll($0)
        }
        #expect(acc2Ops.count == 1)
    }

    // MARK: - Status transitions

    @Test("Status transition: queued -> inFlight")
    func statusQueuedToInFlight() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var op = PendingCalendarOperation(operationType: .create, accountId: "acc1", arguments: [:])
        try db.write { try op.insert($0) }
        #expect(op.status == PendingStatus.queued.rawValue)

        op.status = PendingStatus.inFlight.rawValue
        try db.write { try op.save($0) }

        let fetched = try db.read { try PendingCalendarOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.status == PendingStatus.inFlight.rawValue)
    }

    @Test("Status transition: inFlight -> queued (on failure)")
    func statusInFlightToQueued() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var op = PendingCalendarOperation(operationType: .edit, accountId: "acc1", arguments: [:])
        op.status = PendingStatus.inFlight.rawValue
        try db.write { try op.insert($0) }

        op.status = PendingStatus.queued.rawValue
        try db.write { try op.save($0) }

        let fetched = try db.read { try PendingCalendarOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.status == PendingStatus.queued.rawValue)
    }

    @Test("Status transition: queued -> cancelled")
    func statusQueuedToCancelled() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var op = PendingCalendarOperation(operationType: .delete, accountId: "acc1", arguments: [:])
        try db.write { try op.insert($0) }

        op.status = PendingStatus.cancelled.rawValue
        try db.write { try op.save($0) }

        let fetched = try db.read { try PendingCalendarOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.status == PendingStatus.cancelled.rawValue)
    }

    // MARK: - retryCount

    @Test("retryCount can be incremented and persisted")
    func retryCountIncrement() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var op = PendingCalendarOperation(operationType: .create, accountId: "acc1", arguments: [:])
        try db.write { try op.insert($0) }

        op.retryCount = 5
        try db.write { try op.save($0) }

        let fetched = try db.read { try PendingCalendarOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.retryCount == 5)
    }

    // MARK: - Duplicate prevention

    @Test("Duplicate insert with same id throws")
    func duplicateInsertThrows() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = PendingCalendarOperation(operationType: .create, accountId: "acc1", arguments: [:])
        try db.write { try op.insert($0) }

        #expect(throws: (any Error).self) {
            try db.write { try op.insert($0) }
        }
    }

    // MARK: - Cascade delete via account FK

    @Test("Deleting account cascades to pending calendar ops")
    func cascadeDeleteOnAccountRemoval() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op1 = PendingCalendarOperation(operationType: .create, accountId: "acc1", arguments: [:])
        let op2 = PendingCalendarOperation(operationType: .edit, accountId: "acc1", arguments: [:])
        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
        }

        let before = try db.read { try PendingCalendarOperation.fetchAll($0) }
        #expect(before.count == 2)

        try db.write { _ = try Account.deleteOne($0, key: "acc1") }

        let after = try db.read { try PendingCalendarOperation.fetchAll($0) }
        #expect(after.count == 0)
    }

    // MARK: - Ordering by createdAt

    @Test("Ordering by createdAt ascending yields FIFO order")
    func orderingByCreatedAt() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var op1 = PendingCalendarOperation(operationType: .create, accountId: "acc1", arguments: [:])
        op1.createdAt = Date(timeIntervalSince1970: 200)
        var op2 = PendingCalendarOperation(operationType: .edit, accountId: "acc1", arguments: [:])
        op2.createdAt = Date(timeIntervalSince1970: 100)
        var op3 = PendingCalendarOperation(operationType: .delete, accountId: "acc1", arguments: [:])
        op3.createdAt = Date(timeIntervalSince1970: 300)

        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        let ordered = try db.read {
            try PendingCalendarOperation.order(Column("createdAt").asc).fetchAll($0)
        }
        #expect(ordered.count == 3)
        #expect(ordered[0].id == op2.id) // earliest
        #expect(ordered[1].id == op1.id)
        #expect(ordered[2].id == op3.id) // latest
    }

    // MARK: - Arguments JSON persists through GRDB round-trip

    @Test("Complex arguments survive GRDB insert/fetch round-trip")
    func complexArgsGRDBRoundTrip() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = PendingCalendarOperation(
            operationType: .create,
            accountId: "acc1",
            eventId: "evt-99",
            arguments: [
                "summary": .string("Team Meeting"),
                "allDay": .bool(true),
                "duration": .int(60),
                "attendees": .array([.string("a@b.com"), .string("c@d.com")]),
                "reminders": .dictionary(["useDefault": .bool(false)])
            ]
        )
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingCalendarOperation.fetchOne($0, key: op.id) }!
        let args = fetched.arguments

        if case .string(let val) = args["summary"] {
            #expect(val == "Team Meeting")
        } else {
            #expect(Bool(false), "Expected string for summary")
        }
        if case .bool(let val) = args["allDay"] {
            #expect(val == true)
        } else {
            #expect(Bool(false), "Expected bool for allDay")
        }
        if case .int(let val) = args["duration"] {
            #expect(val == 60)
        } else {
            #expect(Bool(false), "Expected int for duration")
        }
        if case .array(let arr) = args["attendees"] {
            #expect(arr.count == 2)
        } else {
            #expect(Bool(false), "Expected array for attendees")
        }
    }

    // MARK: - All operation types persist

    @Test("All CalendarOperationType values persist and round-trip via GRDB")
    func allOperationTypesPersist() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let types: [CalendarOperationType] = [.create, .edit, .delete]
        for opType in types {
            let op = PendingCalendarOperation(operationType: opType, accountId: "acc1", arguments: [:])
            try db.write { try op.insert($0) }
            let fetched = try db.read { try PendingCalendarOperation.fetchOne($0, key: op.id) }
            #expect(fetched?.operationType == opType.rawValue, "CalendarOperationType \(opType.rawValue) should round-trip")
        }

        let all = try db.read { try PendingCalendarOperation.fetchAll($0) }
        #expect(all.count == types.count)
    }

    // MARK: - deleteAll by filter

    @Test("deleteAll by status removes matching ops only")
    func deleteAllByStatus() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op1 = PendingCalendarOperation(operationType: .create, accountId: "acc1", arguments: [:])
        var op2 = PendingCalendarOperation(operationType: .edit, accountId: "acc1", arguments: [:])
        op2.status = PendingStatus.cancelled.rawValue
        var op3 = PendingCalendarOperation(operationType: .delete, accountId: "acc1", arguments: [:])
        op3.status = PendingStatus.cancelled.rawValue

        try db.write { dbConn in
            try op1.insert(dbConn)
            try op2.insert(dbConn)
            try op3.insert(dbConn)
        }

        let deleted = try db.write {
            try PendingCalendarOperation
                .filter(Column("status") == PendingStatus.cancelled.rawValue)
                .deleteAll($0)
        }
        #expect(deleted == 2)

        let remaining = try db.read { try PendingCalendarOperation.fetchAll($0) }
        #expect(remaining.count == 1)
        #expect(remaining[0].status == PendingStatus.queued.rawValue)
    }

    // MARK: - eventId nil for create, present for edit/delete

    @Test("eventId nil persists correctly through GRDB")
    func eventIdNilPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = PendingCalendarOperation(operationType: .create, accountId: "acc1", arguments: [:])
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingCalendarOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.eventId == nil)
    }

    @Test("eventId present persists correctly through GRDB")
    func eventIdPresentPersists() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let op = PendingCalendarOperation(operationType: .edit, accountId: "acc1", eventId: "google-event-abc", arguments: [:])
        try db.write { try op.insert($0) }

        let fetched = try db.read { try PendingCalendarOperation.fetchOne($0, key: op.id) }
        #expect(fetched?.eventId == "google-event-abc")
    }
}

@Suite("CalDAVConfig Persistence")
struct CalDAVConfigPersistenceTests {

    @Test("Insert and fetch round-trip preserves all fields")
    func insertFetchRoundTrip() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var config = CalDAVConfig(accountId: "acc1", serverURL: "https://caldav.example.com", username: "user@example.com", displayName: "Work Cal")
        config.principalURL = "https://caldav.example.com/principals/user"
        config.calendarHomeURL = "https://caldav.example.com/calendars/user"
        try db.write { try config.insert($0) }

        let fetched = try db.read { try CalDAVConfig.fetchOne($0, key: config.id) }
        #expect(fetched != nil)
        #expect(fetched?.id == config.id)
        #expect(fetched?.accountId == "acc1")
        #expect(fetched?.serverURL == "https://caldav.example.com")
        #expect(fetched?.username == "user@example.com")
        #expect(fetched?.displayName == "Work Cal")
        #expect(fetched?.principalURL == "https://caldav.example.com/principals/user")
        #expect(fetched?.calendarHomeURL == "https://caldav.example.com/calendars/user")
        #expect(fetched?.needsReauth == false)
    }

    @Test("Delete removes config from DB")
    func deleteRemovesConfig() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let config = CalDAVConfig(accountId: "acc1", serverURL: "https://a.com", username: "u")
        try db.write { try config.insert($0) }
        try db.write { _ = try CalDAVConfig.deleteOne($0, key: config.id) }

        let fetched = try db.read { try CalDAVConfig.fetchOne($0, key: config.id) }
        #expect(fetched == nil)
    }

    @Test("Update persists changes")
    func updatePersistsChanges() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        var config = CalDAVConfig(accountId: "acc1", serverURL: "https://a.com", username: "u")
        try db.write { try config.insert($0) }

        config.needsReauth = true
        config.principalURL = "https://new-principal"
        config.displayName = "Updated Name"
        try db.write { try config.save($0) }

        let fetched = try db.read { try CalDAVConfig.fetchOne($0, key: config.id) }
        #expect(fetched?.needsReauth == true)
        #expect(fetched?.principalURL == "https://new-principal")
        #expect(fetched?.displayName == "Updated Name")
    }

    @Test("Cascade delete on account removal")
    func cascadeDeleteOnAccountRemoval() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let config = CalDAVConfig(accountId: "acc1", serverURL: "https://a.com", username: "u")
        try db.write { try config.insert($0) }

        try db.write { _ = try Account.deleteOne($0, key: "acc1") }

        let remaining = try db.read { try CalDAVConfig.fetchAll($0) }
        #expect(remaining.isEmpty)
    }

    @Test("Filter by accountId")
    func filterByAccountId() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db, id: "acc1", email: "a@b.com")
        try TestDatabase.insertAccount(db, id: "acc2", email: "c@d.com")

        let c1 = CalDAVConfig(accountId: "acc1", serverURL: "https://a.com", username: "u1")
        let c2 = CalDAVConfig(accountId: "acc2", serverURL: "https://b.com", username: "u2")
        try db.write { dbConn in
            try c1.insert(dbConn)
            try c2.insert(dbConn)
        }

        let acc1Configs = try db.read {
            try CalDAVConfig.filter(Column("accountId") == "acc1").fetchAll($0)
        }
        #expect(acc1Configs.count == 1)
        #expect(acc1Configs[0].username == "u1")
    }

    @Test("Duplicate insert with same id throws")
    func duplicateInsertThrows() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let config = CalDAVConfig(accountId: "acc1", serverURL: "https://a.com", username: "u")
        try db.write { try config.insert($0) }

        #expect(throws: (any Error).self) {
            try db.write { try config.insert($0) }
        }
    }

    @Test("Optional fields nil by default persist correctly")
    func optionalFieldsNil() throws {
        let db = try TestDatabase.make()
        try TestDatabase.insertAccount(db)

        let config = CalDAVConfig(accountId: "acc1", serverURL: "https://a.com", username: "u")
        try db.write { try config.insert($0) }

        let fetched = try db.read { try CalDAVConfig.fetchOne($0, key: config.id) }
        #expect(fetched?.principalURL == nil)
        #expect(fetched?.calendarHomeURL == nil)
        #expect(fetched?.displayName == nil)
    }
}

@Suite("CalDAVConfig")
struct CalDAVConfigTests {

    @Test("Init sets defaults correctly")
    func initDefaults() {
        let config = CalDAVConfig(accountId: "acc1", serverURL: "https://caldav.example.com", username: "user@example.com")
        #expect(config.accountId == "acc1")
        #expect(config.serverURL == "https://caldav.example.com")
        #expect(config.username == "user@example.com")
        #expect(config.needsReauth == false)
        #expect(config.principalURL == nil)
        #expect(config.calendarHomeURL == nil)
        #expect(config.displayName == nil)
        #expect(!config.id.isEmpty)
    }

    @Test("DisplayName optional")
    func displayNameOptional() {
        let config = CalDAVConfig(
            accountId: "acc1", serverURL: "https://caldav.example.com",
            username: "user@example.com", displayName: "My Calendar"
        )
        #expect(config.displayName == "My Calendar")
    }

    @Test("Unique IDs generated")
    func uniqueIds() {
        let c1 = CalDAVConfig(accountId: "acc1", serverURL: "https://a.com", username: "u1")
        let c2 = CalDAVConfig(accountId: "acc1", serverURL: "https://a.com", username: "u1")
        #expect(c1.id != c2.id)
    }
}
