/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A catch-up request that may still be in flight (#1062): the run asks its
/// folder nothing more while the account's other folders go on, and every
/// timeout ends the folder's call. Same world as `IMAPMissingByUIDTests`.
extension IMAPMissingByUIDTests {

    // MARK: - A request that may still be in flight ends its folder for the run (#1062)

    /// The requests sent to `mailbox` among the recorded commands from `start`
    /// on, each with its index in the log: every command a connection sent while
    /// it had the mailbox selected, and a SELECT, EXAMINE or STATUS naming it.
    static func requests(to mailbox: String, _ server: FakeIMAPServer, from start: Int) -> [(index: Int, command: String)] {
        server.recordedCommandsWithMailbox().enumerated().dropFirst(start).compactMap { entry -> (index: Int, command: String)? in
            let (index, recorded) = entry
            let words = recorded.command.split(separator: " ")
            let verb = words.first.map { $0.uppercased() } ?? ""
            let names = words.count > 1 && words[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == mailbox
            let toMailbox = recorded.mailbox == mailbox || (["SELECT", "EXAMINE", "STATUS"].contains(verb) && names)
            return toMailbox ? (index, recorded.command) : nil
        }
    }

    /// The healthy folder of the in-flight tests: the account's INBOX, answered
    /// at once, whose listing is in progress with a small width cap, so it takes
    /// a range or two per slice over several slices.
    static let healthyPath = "INBOX"
    static let healthyServer = Array(1...60)
    static let healthyWidthCap = 2
    /// Requests per slice in the in-flight tests: room for a call that answers
    /// one range (its FETCH and its membership SEARCH) and asks the next.
    static let inFlightSliceRequests = 3

    /// Give the account a healthy folder (`healthyPath`) whose listing is in
    /// progress: the server and the device hold the same messages there.
    @MainActor
    static func startHealthyListing(_ w: World) async throws {
        w.server.setMessages(healthyServer.map { message($0) }, in: healthyPath)
        try FolderEpochTestFixture.insertHeaders(accountId: w.accountId, path: healthyPath, uids: healthyServer, pool: w.pool)
        var listing = IMAPCatchUpState.Listing(nextUid: 1, rangeWidth: nil)
        listing.widthCap = healthyWidthCap
        listing.top = healthyServer.last
        let raw = try #require(IMAPCatchUpState(epoch: UInt32(epoch), listing: listing).encoded())
        let folderId = "\(w.accountId):\(healthyPath)"
        try await w.pool.write { db in
            try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [raw, folderId])
        }
    }

    /// The healthy folder's stored catch-up state.
    @MainActor
    static func healthyState(_ w: World) throws -> IMAPCatchUpState? {
        let folderId = "\(w.accountId):\(healthyPath)"
        let raw = try w.pool.read { db in
            try String.fetchOne(db, sql: "SELECT catchUpState FROM folder WHERE id = ?", arguments: [folderId])
        }
        return IMAPCatchUpState.decode(raw)
    }

    /// How long an in-flight test's run may take: well within its deadline. A
    /// run that kept taking slices once only its left-out folder had work would
    /// run to the deadline.
    static let leftOutRunSeconds: TimeInterval = slowLinkDeadline / 2

    /// One background run on the scaled link, `maxRequests` per slice: a slice
    /// shorter than a request's timeout, as in production, so a timeout spends
    /// its slice. Returns the run's own answer (an applied result made progress)
    /// and how long the run took.
    @MainActor @discardableResult
    static func inFlightRun(_ w: World, maxRequests: Int = inFlightSliceRequests) async throws -> (didWork: Bool, seconds: TimeInterval) {
        let started = Date()
        let didWork = try await w.workerRun(maxRequests: maxRequests, deadlineIn: slowLinkDeadline, requestTimeout: scaledTimeout,
                                            sliceSeconds: scaledSliceSeconds, intervalSeconds: scaledIntervalSeconds)
        return (didWork, Date().timeIntervalSince(started))
    }

    /// The run of an in-flight test, which took `runSeconds`, after the
    /// folder's request timed out at the command `timedOut`: the folder got no
    /// request after it; the healthy folder was asked after it, so in a later
    /// slice (the timeout spent its own), until its listing completed; and the
    /// run ended once only the left-out folder had work.
    /// *Superseded (#1062):* "the healthy folder kept being asked in later
    /// slices", counted as at least two listing ranges after the timeout.
    @MainActor
    static func expectFolderLeftOutOfTheRun(_ w: World, from start: Int, timedOut: Int, runSeconds: TimeInterval,
                                            sourceLocation: SourceLocation = #_sourceLocation) throws {
        let after = requests(to: path, w.server, from: start).filter { $0.index > timedOut }.map { $0.command }
        #expect(after.isEmpty, "#1062: the run never asks the folder again after its request timed out: \(after)",
                sourceLocation: sourceLocation)
        let healthy = listingRanges(requests(to: healthyPath, w.server, from: timedOut + 1).map { $0.command })
        #expect(!healthy.isEmpty, "#1062: the healthy folder is asked in a later slice of the same run: \(healthy)",
                sourceLocation: sourceLocation)
        #expect(try healthyState(w)?.listing == nil, "#1062: the healthy folder's listing completed in the same run",
                sourceLocation: sourceLocation)
        #expect(runSeconds < leftOutRunSeconds,
                "#1062: the run ends once only the left-out folder has work: it took \(runSeconds) s of its \(slowLinkDeadline) s",
                sourceLocation: sourceLocation)
    }

    /// The next run on a link that answers: the folder's first listing range.
    @MainActor
    static func firstRangeOfTheNextRun(_ w: World) async throws -> ClosedRange<Int>? {
        // Let the late answer free the connection.
        try await Task.sleep(for: .seconds(slowAnswerSeconds))
        let start = w.server.recordedCommands().count
        try await inFlightRun(w)
        return listingRanges(requests(to: path, w.server, from: start).map { $0.command }).first
    }

    @Test("A call that starts a listing and times out on its first range: the run never asks that folder again while a healthy folder of the account goes on in later slices, and the run ends once only that folder has work; the listing keeps the top it learned, and the next run asks half the timed-out width from the same UID")
    @MainActor
    func timeoutOnTheCallThatStartsAListingLeavesTheFolderOutOfTheRun() async throws {
        let server = Array(1...20)
        try await Self.withWorld("in-flight-listing-start", server: server, local: server) { w in
            try await Self.startHealthyListing(w)
            try await w.markOwed()
            #expect(try w.catchUpState()?.listing == nil, "setup: no listing is stored, so the call starts one")
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: Self.slowAnswerSeconds)
            let start = w.server.recordedCommands().count
            let run = try await Self.inFlightRun(w)
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: nil)
            let asked = Self.requests(to: Self.path, w.server, from: start)
            let timedOut = try #require(asked.first { !Self.listingRanges([$0.command]).isEmpty }, "setup: the folder's first range was asked")
            let range = try #require(Self.listingRanges([timedOut.command]).first)
            #expect(range.lowerBound == 1, "setup: the new listing's first range starts at the folder's first UID: \(range)")
            try Self.expectFolderLeftOutOfTheRun(w, from: start, timedOut: timedOut.index, runSeconds: run.seconds)
            let listing = try #require(try w.catchUpState()?.listing, "#1062: the listing the call started is saved")
            #expect(listing.top == server.last, "#1062: the saved listing keeps the top the call learned")
            #expect(listing.nextUid == range.lowerBound, "#1062: the listing stays at the UID whose range timed out")
            let capped = range.count / SyncConfig.catchUpWidthCapShrinkFactor
            #expect(listing.widthCap == capped, "#1062: one timeout capped the width once: \(String(describing: listing.widthCap))")
            let next = try await Self.firstRangeOfTheNextRun(w)
            #expect(next == range.lowerBound...(range.lowerBound + capped - 1),
                    "#1062: the next run asks half the timed-out width from the same UID: \(next.map { "\($0)" } ?? "none")")
        }
    }

    @Test("A call that answers a range and then times out on the next: the run never asks that folder again while a healthy folder of the account goes on in later slices, and the run ends once only that folder has work; the listing keeps the place the answer moved it to, and the next run asks half the timed-out width from there")
    @MainActor
    func timeoutAfterAnAnsweredRangeLeavesTheFolderOutOfTheRun() async throws {
        let server = Array(1...20)
        let cap = 5
        try await Self.withWorld("in-flight-after-answer", server: server, local: server) { w in
            try await Self.startHealthyListing(w)
            // The first range (`cap` messages) answers; the second, at the
            // doubled cap, holds more than the link answers in time.
            try await Self.setListing(w, nextUid: 1, rangeWidth: nil, widthCap: cap, top: server.last)
            w.server.slowListingFetch(in: Self.path, overRecords: cap, seconds: Self.slowAnswerSeconds)
            let start = w.server.recordedCommands().count
            let run = try await Self.inFlightRun(w)
            w.server.slowListingFetch(in: Self.path, overRecords: cap, seconds: nil)
            let asked = Self.requests(to: Self.path, w.server, from: start)
            let listed = asked.filter { !Self.listingRanges([$0.command]).isEmpty }
            let grown = cap * SyncConfig.catchUpWidthCapGrowthFactor
            #expect(Self.listingRanges(listed.prefix(2).map { $0.command }) == [1...cap, (cap + 1)...(cap + grown)],
                    "setup: one call answered a range at the cap and asked the next at the doubled cap")
            let timedOut = try #require(listed.dropFirst().first, "setup: the second range was asked")
            try Self.expectFolderLeftOutOfTheRun(w, from: start, timedOut: timedOut.index, runSeconds: run.seconds)
            let listing = try #require(try w.catchUpState()?.listing, "setup: the listing is in progress")
            #expect(listing.nextUid == cap + 1, "#1062: the saved listing keeps the place the answered range moved it to")
            #expect(listing.top == server.last, "#1062: the saved listing keeps its top")
            let capped = grown / SyncConfig.catchUpWidthCapShrinkFactor
            #expect(listing.widthCap == capped, "#1062: one timeout capped the width once: \(String(describing: listing.widthCap))")
            let next = try await Self.firstRangeOfTheNextRun(w)
            #expect(next == (cap + 1)...(cap + capped),
                    "#1062: the next run asks half the timed-out width from the UID after the answered range: \(next.map { "\($0)" } ?? "none")")
        }
    }

    @Test("A run whose only progress is that of the folder whose request then timed out: the folder is never asked again, the run ends once only that folder has work, and the run still reports the folder's applied progress as work")
    @MainActor
    func soleProgressOfALeftOutFolderEndsTheRunAndCounts() async throws {
        let server = Array(1...20)
        let cap = 5
        try await Self.withWorld("in-flight-sole-progress", server: server, local: server) { w in
            // No healthy folder: the account's INBOX completed its listing in
            // the warm-up and has nothing due. The folder's first range answers;
            // the second, at the doubled cap, holds more than the link answers in time.
            try await Self.setListing(w, nextUid: 1, rangeWidth: nil, widthCap: cap, top: server.last)
            w.server.slowListingFetch(in: Self.path, overRecords: cap, seconds: Self.slowAnswerSeconds)
            let start = w.server.recordedCommands().count
            let run = try await Self.inFlightRun(w)
            w.server.slowListingFetch(in: Self.path, overRecords: cap, seconds: nil)
            let asked = Self.requests(to: Self.path, w.server, from: start)
            let listed = asked.filter { !Self.listingRanges([$0.command]).isEmpty }
            let grown = cap * SyncConfig.catchUpWidthCapGrowthFactor
            #expect(Self.listingRanges(listed.prefix(2).map { $0.command }) == [1...cap, (cap + 1)...(cap + grown)],
                    "setup: one call answered a range at the cap and asked the next at the doubled cap")
            let timedOut = try #require(listed.dropFirst().first, "setup: the second range was asked")
            let after = asked.filter { $0.index > timedOut.index }.map { $0.command }
            #expect(after.isEmpty, "#1062: the run never asks the folder again after its request timed out: \(after)")
            #expect(try w.catchUpState()?.listing?.nextUid == cap + 1, "setup: the call's progress was applied")
            #expect(run.didWork, "#1062: the run reports the left-out folder's applied progress as work")
            #expect(run.seconds < Self.leftOutRunSeconds,
                    "#1062: the run ends once only the left-out folder has work: it took \(run.seconds) s of its \(Self.slowLinkDeadline) s")
            // Let the late answer free the connection before the world closes.
            try await Task.sleep(for: .seconds(Self.slowAnswerSeconds))
        }
    }

    /// The account's second folder whose requests time out (a Sent folder).
    static let secondPath = "Sent"

    /// Write `listing` as the catch-up state of the account's folder at
    /// `folderPath`, last tried at `lastAttemptAt`.
    @MainActor
    static func writeListing(_ w: World, folderPath: String, _ listing: IMAPCatchUpState.Listing, lastAttemptAt: Date) async throws {
        var state = IMAPCatchUpState(epoch: UInt32(epoch), listing: listing)
        state.lastAttemptAt = lastAttemptAt
        let raw = try #require(state.encoded())
        let folderId = "\(w.accountId):\(folderPath)"
        try await w.pool.write { db in
            try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [raw, folderId])
        }
    }

    /// Give the account its second folder (`secondPath`): the server and the
    /// device hold `uids` there, its listing is in progress at the first of them
    /// with `siteWidth` stored, it was last tried at `lastAttemptAt`, and every
    /// listing request in it is answered only after the timeout.
    @MainActor
    static func addSecondSlowFolder(_ w: World, uids: [Int], lastAttemptAt: Date) async throws {
        w.server.setMessages(uids.map { message($0) }, in: secondPath)
        w.server.setUidValidity(epoch, for: secondPath)
        try FolderEpochTestFixture.insertFolder(accountId: w.accountId, path: secondPath, role: .sent, pool: w.pool,
                                                totalCount: uids.count, lastKnownUidNext: (uids.max() ?? 0) + 1,
                                                lastKnownUidValidity: epoch)
        try FolderEpochTestFixture.insertHeaders(accountId: w.accountId, path: secondPath, uids: uids, pool: w.pool)
        var listing = IMAPCatchUpState.Listing(nextUid: uids[0], rangeWidth: siteWidth)
        listing.top = uids.last
        try await writeListing(w, folderPath: secondPath, listing, lastAttemptAt: lastAttemptAt)
        w.server.slowListingFetch(in: secondPath, overRecords: 0, seconds: slowAnswerSeconds)
    }

    @Test("Two folders time out in different slices of one run, each on a call that makes no progress: neither is asked again after its own timeout, the run goes on past each timeout slice, and the healthy folder completes its listing in later slices")
    @MainActor
    func leftOutFoldersAccumulateOverTheRun() async throws {
        let server = Array(1...20)
        try await Self.withWorld("in-flight-two-folders", server: server, local: server) { w in
            try await Self.startHealthyListing(w)
            // Tried longest ago first: the healthy folder (never tried) takes
            // the first slice, the folder the second, the second folder the third.
            let now = Date()
            var listing = IMAPCatchUpState.Listing(nextUid: server[0], rangeWidth: Self.siteWidth)
            listing.top = server.last
            try await Self.writeListing(w, folderPath: Self.path, listing, lastAttemptAt: now.addingTimeInterval(-7200))
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: Self.slowAnswerSeconds)
            try await Self.addSecondSlowFolder(w, uids: server, lastAttemptAt: now.addingTimeInterval(-3600))
            let start = w.server.recordedCommands().count
            let run = try await Self.inFlightRun(w)
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: nil)
            w.server.slowListingFetch(in: Self.secondPath, overRecords: 0, seconds: nil)
            func firstListing(_ mailbox: String) -> (index: Int, command: String)? {
                Self.requests(to: mailbox, w.server, from: start).first { !Self.listingRanges([$0.command]).isEmpty }
            }
            let first = try #require(firstListing(Self.path), "setup: the folder's range was asked")
            #expect(try w.catchUpState()?.listing?.nextUid == server[0],
                    "setup: the folder's call made no progress: the listing stays at its first UID")
            // The timeout spent its slice, and the call made no progress: the run
            // goes on only because the slice left the folder out.
            let second = try #require(firstListing(Self.secondPath),
                                      "#1062: the run goes on past the first timeout slice and asks the second folder in a later slice")
            #expect(second.index > first.index, "setup: the second folder timed out after the first")
            for (mailbox, timedOut) in [(Self.path, first), (Self.secondPath, second)] {
                let after = Self.requests(to: mailbox, w.server, from: start).filter { $0.index > timedOut.index }.map { $0.command }
                #expect(after.isEmpty, "#1062: the run never asks \(mailbox) again after its request timed out: \(after)")
            }
            let healthy = Self.listingRanges(Self.requests(to: Self.healthyPath, w.server, from: second.index + 1).map { $0.command })
            #expect(!healthy.isEmpty, "#1062: the healthy folder is asked after the second timeout, in a later slice of the same run: \(healthy)")
            #expect(try Self.healthyState(w)?.listing == nil, "#1062: the healthy folder's listing completed in the same run")
            #expect(run.seconds < Self.leftOutRunSeconds,
                    "#1062: the run ends once only the left-out folders have work: it took \(run.seconds) s of its \(Self.slowLinkDeadline) s")
            // Let the late answers free the connections before the world closes.
            try await Task.sleep(for: .seconds(Self.slowAnswerSeconds))
        }
    }

    // MARK: - Every request that times out leaves its folder out (#1062)

    /// The folder of the per-request tests: UIDs no request of the healthy
    /// folder names (it holds `healthyServer`), so a fragment of the folder's own
    /// SEARCH holds only that SEARCH. Listed from its first UID in ranges of
    /// `siteWidth`; `siteMissing` is in the first one.
    static let siteServer = Array(101...120)
    static let siteWidth = 5
    static let siteMissing = 103

    /// One run in which the folder's request whose command contains one of
    /// `fragments` is answered only after the timeout: the folder is never asked
    /// again in the run, the healthy folder goes on in a later slice, and the run
    /// ends once only the folder has work (`expectFolderLeftOutOfTheRun`).
    @MainActor
    static func expectRunLeavesOutTheFolder(_ w: World, timingOut fragments: [String], maxRequests: Int = inFlightSliceRequests,
                                            sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for fragment in fragments { w.server.stallNextCommand(containing: fragment, seconds: slowAnswerSeconds) }
        let start = w.server.recordedCommands().count
        let run = try await inFlightRun(w, maxRequests: maxRequests)
        let held = fragments.map { $0.uppercased() }
        let timedOut = try #require(requests(to: path, w.server, from: start).first { request in
            held.contains { request.command.uppercased().contains($0) }
        }, "setup: the folder's request held past the timeout was asked", sourceLocation: sourceLocation)
        try expectFolderLeftOutOfTheRun(w, from: start, timedOut: timedOut.index, runSeconds: run.seconds,
                                        sourceLocation: sourceLocation)
        // Let the late answer free the connection before the world closes.
        try await Task.sleep(for: .seconds(slowAnswerSeconds))
    }

    /// Start the folder's listing at its first UID, ranges of `siteWidth`.
    @MainActor
    static func startSiteListing(_ w: World) async throws {
        try await setListing(w, nextUid: siteServer[0], rangeWidth: siteWidth, top: siteServer.last)
    }

    @Test("The UIDNEXT read of a call that starts a listing times out: the run never asks that folder again, while a healthy folder of the account goes on in a later slice, and the run ends once only that folder has work")
    @MainActor
    func uidNextTimeoutLeavesTheFolderOutOfTheRun() async throws {
        try await Self.withWorld("in-flight-uidnext", server: Self.siteServer, local: Self.siteServer) { w in
            try await Self.startHealthyListing(w)
            try await w.markOwed()
            #expect(try w.catchUpState()?.listing == nil, "setup: no listing is stored, so the call reads the folder's UIDNEXT first")
            // The folder's SELECT, either quoting: the UIDNEXT read is its first request in the run.
            try await Self.expectRunLeavesOutTheFolder(w, timingOut: ["SELECT \(Self.path)", "SELECT \"\(Self.path)\""])
            let listing = try #require(try w.catchUpState()?.listing, "setup: the call saved the listing it started")
            #expect(listing.top == nil, "setup: the UIDNEXT read timed out before the listing learned its top")
        }
    }

    @Test("A range's membership proof times out: the run never asks that folder again, while a healthy folder of the account goes on in a later slice, and the run ends once only that folder has work")
    @MainActor
    func proofTimeoutLeavesTheFolderOutOfTheRun() async throws {
        let first = Self.siteServer[0]
        try await Self.withWorld("in-flight-proof", server: Self.siteServer, local: Self.siteServer) { w in
            try await Self.startHealthyListing(w)
            try await Self.startSiteListing(w)
            // The proof of the first range names it whole.
            try await Self.expectRunLeavesOutTheFolder(w, timingOut: ["UID \(first):\(first + Self.siteWidth - 1)"])
        }
    }

    /// Make `siteMissing` a missing message whose header record the client
    /// cannot read: its load leaves the UID unanswered, and the SEARCH for it
    /// (`UID SEARCH UID <uid>`) is the request a test holds.
    @MainActor
    static func makeSiteMissingUnreadable(_ w: World) async throws {
        let server = siteServer, unreadable = siteMissing
        var messages = server.map { message($0) }
        let index = try #require(server.firstIndex(of: unreadable))
        messages[index] = message(unreadable, date: "not a date")
        w.server.setMessages(messages, in: path)
        w.server.suppressFetchInternalDate(in: path, uids: [unreadable])
        try await w.dropLocal([unreadable])
    }

    @Test("The SEARCH a carried range still owes for a UID whose header record could not be read times out: the run never asks that folder again, while a healthy folder of the account goes on in a later slice, and the run ends once only that folder has work")
    @MainActor
    func carriedUnansweredSearchTimeoutLeavesTheFolderOutOfTheRun() async throws {
        try await Self.withWorld("in-flight-unanswered-carried", server: Self.siteServer, local: Self.siteServer) { w in
            try await Self.makeSiteMissingUnreadable(w)
            try await Self.startHealthyListing(w)
            try await Self.startSiteListing(w)
            // `inFlightSliceRequests` per slice: the folder's first call lists the
            // range, proves it and loads the UID, and carries the SEARCH it owes
            // (no request left); a later call asks that SEARCH first.
            try await Self.expectRunLeavesOutTheFolder(w, timingOut: ["UID \(Self.siteMissing)"])
        }
    }

    @Test("The SEARCH for a UID whose header record could not be read, asked right after its load, times out: the run never asks that folder again, while a healthy folder of the account goes on in a later slice, and the run ends once only that folder has work")
    @MainActor
    func unansweredSearchTimeoutLeavesTheFolderOutOfTheRun() async throws {
        try await Self.withWorld("in-flight-unanswered", server: Self.siteServer, local: Self.siteServer) { w in
            try await Self.makeSiteMissingUnreadable(w)
            try await Self.startHealthyListing(w)
            try await Self.startSiteListing(w)
            // One request more per slice: the folder's first call lists the
            // range, proves it, loads the UID and asks its SEARCH in the same call.
            try await Self.expectRunLeavesOutTheFolder(w, timingOut: ["UID \(Self.siteMissing)"],
                                                       maxRequests: Self.inFlightSliceRequests + 1)
        }
    }

    @Test("The header load of a missing message times out: the run never asks that folder again, while a healthy folder of the account goes on in a later slice, and the run ends once only that folder has work")
    @MainActor
    func headerLoadTimeoutLeavesTheFolderOutOfTheRun() async throws {
        try await Self.withWorld("in-flight-load", server: Self.siteServer, local: Self.siteServer) { w in
            try await w.dropLocal([Self.siteMissing])
            try await Self.startHealthyListing(w)
            try await Self.startSiteListing(w)
            // The healthy folder misses nothing, so the only header load is the folder's.
            try await Self.expectRunLeavesOutTheFolder(w, timingOut: ["ENVELOPE"])
        }
    }

    @Test("A folder's request times out and its result is not applied (a reset of the folder began while the request was out): the slice still reports the folder's request as possibly in flight")
    @MainActor
    func timedOutFolderIsInFlightWhenItsApplyIsSkipped() async throws {
        let server = Array(1...20)
        try await Self.withWorld("in-flight-skipped", server: server, local: server) { w in
            let folderId = w.folderId
            try await Self.setListing(w, nextUid: 7, rangeWidth: 5, top: server.last)
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: Self.slowAnswerSeconds)
            let start = w.server.recordedCommands().count
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            async let sliced = w.engine.runCatchUp(provider: w.provider, folderIds: [folderId], context: CatchUpContext(
                deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages,
                requestTimeoutSeconds: Self.scaledTimeout))
            var polls = 0
            while Self.listingRanges(w.server.recordedCommands().dropFirst(start)).isEmpty, polls < Self.suspensionPolls {
                try await Task.sleep(for: .milliseconds(10))
                polls += 1
            }
            #expect(polls < Self.suspensionPolls, "setup: the folder's range was asked")
            // The folder's reset reaction begins while the range's request is
            // out: the apply then writes nothing of the call's result.
            try await w.pool.write { db in
                try db.execute(sql: "UPDATE folder SET uidValidityResetPendingAt = ? WHERE id = ?", arguments: [Date(), folderId])
            }
            let slice = await sliced
            w.server.slowListingFetch(in: Self.path, overRecords: 0, seconds: nil)
            #expect(try w.catchUpState()?.listing?.widthCap == nil, "setup: the apply wrote nothing, not even the cap the call set")
            #expect(!slice.progressed, "setup: nothing of the folder's result was applied")
            #expect(slice.inFlightFolderIds == [folderId],
                    "#1062: a timed-out request is reported in flight whatever the apply did: \(slice.inFlightFolderIds)")
            // Let the late answer free the connection before the world closes.
            try await Task.sleep(for: .seconds(Self.slowAnswerSeconds))
        }
    }

    // MARK: - A timeout past the hold bound ends the call (#1062)

    /// One call that lists `range`, held since past the bound, and whose request
    /// containing `fragment` times out: the range is passed over and saved, the
    /// folder gets no further request in that call, and the next call lists from
    /// past the range. The call's budget is never spent (no deadline, a clock
    /// that stands still, no request cap) and the listing has ranges left, so
    /// only the end of the call after the timeout stops the next range's request.
    @MainActor
    static func expectPassOverEndsTheCall(_ w: World, range: ClosedRange<Int>, timingOut fragment: String,
                                          clock: CatchUpTestClock,
                                          sourceLocation: SourceLocation = #_sourceLocation) async throws {
        w.server.stallNextCommand(containing: fragment, seconds: slowAnswerSeconds)
        let start = w.server.recordedCommands().count
        await w.slice(clock: clock, requestTimeout: scaledTimeout)
        let asked = requests(to: path, w.server, from: start)
        #expect(listingRanges(asked.map { $0.command }).first == range, "setup: the call listed \(range) first",
                sourceLocation: sourceLocation)
        let timedOut = try #require(asked.first { $0.command.uppercased().contains(fragment.uppercased()) },
                                    "setup: the request held past the timeout was asked", sourceLocation: sourceLocation)
        let after = asked.filter { $0.index > timedOut.index }.map { $0.command }
        #expect(after.isEmpty, "#1062: after a timeout past the hold bound the folder gets no further request in that call: \(after)",
                sourceLocation: sourceLocation)
        let listing = try #require(try w.catchUpState()?.listing, "#1062: the listing stays in progress",
                                   sourceLocation: sourceLocation)
        #expect(listing.passedOver == true, "#1062: the passed-over range is saved, so the listing completes as not clean",
                sourceLocation: sourceLocation)
        #expect(listing.nextUid == range.upperBound + 1 && listing.loadHeldSince == nil && listing.carried == nil,
                "#1062: the listing is saved past the passed-over range: \(listing)", sourceLocation: sourceLocation)
        // Let the late answer free the connection.
        try await Task.sleep(for: .seconds(slowAnswerSeconds))
        let next = try await nextRange(w, clock)
        #expect(next?.lowerBound == range.upperBound + 1,
                "#1062: the next call goes on from past the passed-over range: \(next.map { "\($0)" } ?? "none")",
                sourceLocation: sourceLocation)
    }

    @Test("A range's membership proof times out with its hold past the bound: the range is passed over and saved, the folder gets no further request in that call, and the next call goes on from past the range")
    @MainActor
    func proofTimeoutPastTheHoldEndsTheCall() async throws {
        let first = Self.siteServer[0]
        try await Self.withWorld("pass-over-proof", server: Self.siteServer, local: Self.siteServer) { w in
            let clock = CatchUpTestClock()
            try await Self.setListing(w, nextUid: first, rangeWidth: Self.siteWidth, top: Self.siteServer.last,
                                      loadHeldSince: clock.now.addingTimeInterval(-Self.pastTheHold))
            try await Self.expectPassOverEndsTheCall(w, range: first...(first + Self.siteWidth - 1),
                                                     timingOut: "SEARCH", clock: clock)
        }
    }

    @Test("A missing message's header load times out with its hold past the bound: the range is passed over and saved, the folder gets no further request in that call, and the next call goes on from past the range")
    @MainActor
    func headerLoadTimeoutPastTheHoldEndsTheCall() async throws {
        let missing = Self.siteMissing
        try await Self.withWorld("pass-over-load", server: Self.siteServer, local: Self.siteServer) { w in
            try await w.dropLocal([missing])
            let clock = CatchUpTestClock()
            // The range starts at the missing message, where its hold runs.
            try await Self.setListing(w, nextUid: missing, rangeWidth: Self.siteWidth, top: Self.siteServer.last,
                                      loadHeldSince: clock.now.addingTimeInterval(-Self.pastTheHold))
            try await Self.expectPassOverEndsTheCall(w, range: missing...(missing + Self.siteWidth - 1),
                                                     timingOut: "ENVELOPE", clock: clock)
        }
    }
}
