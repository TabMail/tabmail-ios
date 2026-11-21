/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import GRDB
import Testing
@testable import TabMail

/// A catch-up request that may still be in flight (#1062): the run asks its
/// folder nothing more while the account's other folders go on, every timeout
/// ends the folder's call, and a call that stops with no timeout leaves
/// nothing in flight. Same world as `IMAPMissingByUIDTests`.
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

    /// Once the run has returned, answer the request it held past its timeout
    /// (`release`) and wait for that late answer: a UIDNEXT read of the test's
    /// own needs the connection of `mailbox`, so it returns only once the
    /// connection is free again. The release, not a sleep, frees it. Then no
    /// request of the run goes to `mailbox` after the one that timed out
    /// (`timedOut`): a request the run had queued behind the held one would go
    /// out now. Nothing is timed.
    @MainActor
    static func answerAfterTheRun(_ w: World, mailbox: String = path, timedOut: Int, release: () -> Void,
                                  sourceLocation: SourceLocation = #_sourceLocation) async throws {
        release()
        _ = try await w.provider.getUidNextWithEpoch(folder: mailbox)
        let afterAnswer = asking(requests(to: mailbox, w.server, from: timedOut + 1))
        #expect(afterAnswer.isEmpty,
                "#1062: no request of the run went to \(mailbox) once the late answer freed its connection: \(afterAnswer)",
                sourceLocation: sourceLocation)
    }

    /// The next run on a link that answers, once the held request was
    /// answered (`answerAfterTheRun`): the folder's first listing range.
    @MainActor
    static func firstRangeOfTheNextRun(_ w: World) async throws -> ClosedRange<Int>? {
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
            // The folder's first FETCH, its first range, is held unanswered
            // until the run has returned, so it always times out.
            w.server.holdNextFetchAfterSnapshot(in: Self.path)
            let start = w.server.recordedCommands().count
            let run = try await Self.inFlightRun(w)
            let held = w.server.isHoldingFetchAfterSnapshot(in: Self.path)
            let asked = Self.requests(to: Self.path, w.server, from: start)
            let timedOut = try #require(asked.first { !Self.listingRanges([$0.command]).isEmpty }, "setup: the folder's first range was asked")
            let range = try #require(Self.listingRanges([timedOut.command]).first)
            #expect(range.lowerBound == 1, "setup: the new listing's first range starts at the folder's first UID: \(range)")
            try Self.expectFolderLeftOutOfTheRun(w, from: start, timedOut: timedOut.index, runSeconds: run.seconds)
            try await Self.answerAfterTheRun(w, timedOut: timedOut.index) { w.server.releaseFetchAfterSnapshot(in: Self.path) }
            #expect(held, "setup: the folder's first range was held past its timeout")
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
            // doubled cap, is held unanswered until the run has returned, so it
            // always times out.
            try await Self.setListing(w, nextUid: 1, rangeWidth: nil, widthCap: cap, top: server.last)
            let grown = cap * SyncConfig.catchUpWidthCapGrowthFactor
            let secondRange = "FETCH \(cap + 1):\(cap + grown)"
            w.server.holdNextCommand(containing: secondRange)
            let start = w.server.recordedCommands().count
            let run = try await Self.inFlightRun(w)
            let held = w.server.isHoldingCommand(containing: secondRange)
            let asked = Self.requests(to: Self.path, w.server, from: start)
            let listed = asked.filter { !Self.listingRanges([$0.command]).isEmpty }
            #expect(Self.listingRanges(listed.prefix(2).map { $0.command }) == [1...cap, (cap + 1)...(cap + grown)],
                    "setup: one call answered a range at the cap and asked the next at the doubled cap")
            let timedOut = try #require(listed.dropFirst().first, "setup: the second range was asked")
            try Self.expectFolderLeftOutOfTheRun(w, from: start, timedOut: timedOut.index, runSeconds: run.seconds)
            try await Self.answerAfterTheRun(w, timedOut: timedOut.index) { w.server.releaseHeldCommand(containing: secondRange) }
            #expect(held, "setup: the second range was held past its timeout")
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
            // the second, at the doubled cap, is held unanswered until the run
            // has returned, so it always times out.
            try await Self.setListing(w, nextUid: 1, rangeWidth: nil, widthCap: cap, top: server.last)
            let grown = cap * SyncConfig.catchUpWidthCapGrowthFactor
            let secondRange = "FETCH \(cap + 1):\(cap + grown)"
            w.server.holdNextCommand(containing: secondRange)
            let start = w.server.recordedCommands().count
            let run = try await Self.inFlightRun(w)
            let held = w.server.isHoldingCommand(containing: secondRange)
            let asked = Self.requests(to: Self.path, w.server, from: start)
            let listed = asked.filter { !Self.listingRanges([$0.command]).isEmpty }
            #expect(Self.listingRanges(listed.prefix(2).map { $0.command }) == [1...cap, (cap + 1)...(cap + grown)],
                    "setup: one call answered a range at the cap and asked the next at the doubled cap")
            let timedOut = try #require(listed.dropFirst().first, "setup: the second range was asked")
            let after = asked.filter { $0.index > timedOut.index }.map { $0.command }
            #expect(after.isEmpty, "#1062: the run never asks the folder again after its request timed out: \(after)")
            #expect(try w.catchUpState()?.listing?.nextUid == cap + 1, "setup: the call's progress was applied")
            #expect(run.didWork, "#1062: the run reports the left-out folder's applied progress as work")
            #expect(run.seconds < Self.leftOutRunSeconds,
                    "#1062: the run ends once only the left-out folder has work: it took \(run.seconds) s of its \(Self.slowLinkDeadline) s")
            try await Self.answerAfterTheRun(w, timedOut: timedOut.index) { w.server.releaseHeldCommand(containing: secondRange) }
            #expect(held, "setup: the second range was held past its timeout")
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
    /// with `siteWidth` stored, it was last tried at `lastAttemptAt`, and its
    /// first FETCH, its first range, is held unanswered until the test releases
    /// it, so it always times out.
    /// *Superseded (#1062):* "every listing request in it is answered only after
    /// the timeout", a timed answer that raced the timeout.
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
        w.server.holdNextFetchAfterSnapshot(in: secondPath)
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
            // Each folder's first FETCH, its first range, is held unanswered
            // until the run has returned, so it always times out.
            w.server.holdNextFetchAfterSnapshot(in: Self.path)
            try await Self.addSecondSlowFolder(w, uids: server, lastAttemptAt: now.addingTimeInterval(-3600))
            let start = w.server.recordedCommands().count
            let run = try await Self.inFlightRun(w)
            let held = [Self.path, Self.secondPath].map { w.server.isHoldingFetchAfterSnapshot(in: $0) }
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
            for (mailbox, timedOut) in [(Self.path, first), (Self.secondPath, second)] {
                try await Self.answerAfterTheRun(w, mailbox: mailbox, timedOut: timedOut.index) {
                    w.server.releaseFetchAfterSnapshot(in: mailbox)
                }
            }
            #expect(held == [true, true], "setup: each folder's first range was held past its timeout: \(held)")
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
    /// `fragments` is held unanswered until the run has returned, so it always
    /// times out: the folder is never asked again in the run, the healthy folder
    /// goes on in a later slice, and the run ends once only the folder has work
    /// (`expectFolderLeftOutOfTheRun`). The held request is then answered
    /// (`answerAfterTheRun`).
    /// *Superseded (#1062):* the request was "answered only after the timeout",
    /// a timed answer that raced the timeout, and a sleep waited for it.
    @MainActor
    static func expectRunLeavesOutTheFolder(_ w: World, timingOut fragments: [String], maxRequests: Int = inFlightSliceRequests,
                                            sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for fragment in fragments { w.server.holdNextCommand(containing: fragment) }
        let start = w.server.recordedCommands().count
        let run = try await inFlightRun(w, maxRequests: maxRequests)
        let wasHeld = fragments.contains { w.server.isHoldingCommand(containing: $0) }
        let held = fragments.map { $0.uppercased() }
        let timedOut = try #require(requests(to: path, w.server, from: start).first { request in
            held.contains { request.command.uppercased().contains($0) }
        }, "setup: the folder's request held past the timeout was asked", sourceLocation: sourceLocation)
        try expectFolderLeftOutOfTheRun(w, from: start, timedOut: timedOut.index, runSeconds: run.seconds,
                                        sourceLocation: sourceLocation)
        try await answerAfterTheRun(w, timedOut: timedOut.index, release: {
            for fragment in fragments { w.server.releaseHeldCommand(containing: fragment) }
        }, sourceLocation: sourceLocation)
        #expect(wasHeld, "setup: the folder's request was held past its timeout", sourceLocation: sourceLocation)
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

    /// The fragment of a listing range's FETCH (`UID FETCH lo:hi (UID FLAGS)`):
    /// in a call that starts a listing, the first command that names flags.
    static let listingFetchFragment = "FLAGS"

    /// Begin the folder's reset reaction (`uidValidityResetPendingAt`) inside
    /// the next catch-up call, before its first request: at the call's first
    /// checkout of the folder's connection (`IMAPProvider.folderConnectionTestHook`),
    /// so always after the slice read the folder and before the result is
    /// applied. Nothing is timed. The caller removes the hook after the call.
    @MainActor
    static func startResetAtTheFirstRequest(_ w: World) async {
        let pool = w.pool, folderId = w.folderId, mailbox = path
        await w.provider.setFolderConnectionTestHookForTesting { folder in
            guard folder == mailbox else { return }
            try? await pool.write { db in
                try db.execute(sql: "UPDATE folder SET uidValidityResetPendingAt = ? WHERE id = ? AND uidValidityResetPendingAt IS NULL",
                               arguments: [Date(), folderId])
            }
        }
    }

    @Test("A folder's call makes progress (it starts the listing and learns the folder's top) and its first range times out, and its result is not applied (a reset of the folder began during the call): the slice reports no progress for the folder, and still reports its request in flight")
    @MainActor
    func timedOutFolderIsInFlightWhenItsApplyIsSkipped() async throws {
        let server = Array(1...20)
        try await Self.withWorld("in-flight-skipped", server: server, local: server) { w in
            let folderId = w.folderId
            try await w.markOwed()
            #expect(try w.catchUpState()?.listing == nil, "setup: no listing is stored, so the call starts one and reads the folder's UIDNEXT first")
            let fetch = Self.listingFetchFragment
            func context() -> CatchUpContext {
                CatchUpContext(deadline: .distantFuture, clock: { Date() }, listingRangeMessages: w.rangeMessages,
                               requestTimeoutSeconds: Self.scaledTimeout)
            }
            // The provider's own result for this call, read without an apply:
            // the UIDNEXT read answers, and the first range is held unanswered.
            w.server.holdNextCommand(containing: fetch)
            let read = try await w.read(context())
            let readHeld = w.server.isHoldingCommand(containing: fetch)
            try await Self.answerHeldRequest(w, holding: fetch)
            #expect(readHeld, "setup: the first range was held past its timeout")
            #expect(read.results.count == 1, "setup: the folder's call returned a result")
            guard read.results.count == 1 else { return }
            let result = read.results[0]
            #expect(result.madeProgress && result.requestMayBeInFlight,
                    "setup: the call made progress, and its first range timed out")
            #expect(IMAPCatchUpState.decode(result.newState)?.listing?.top == server.last,
                    "setup: the progress is the listing the call started, with the top it learned")
            #expect(try w.catchUpState()?.listing == nil, "setup: the read applied nothing")

            // The same call in a slice, the folder's reset beginning during it.
            await Self.startResetAtTheFirstRequest(w)
            w.server.holdNextCommand(containing: fetch)
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            let slice = await w.engine.runCatchUp(provider: w.provider, folderIds: [folderId], context: context())
            await w.provider.setFolderConnectionTestHookForTesting(nil)
            let held = w.server.isHoldingCommand(containing: fetch)
            try await Self.answerHeldRequest(w, holding: fetch)
            #expect(held, "setup: the UIDNEXT read answered, and the first range was held past its timeout")
            #expect(try w.folder().uidValidityResetPendingAt != nil, "setup: the folder's reset began during the call")
            #expect(try w.catchUpState()?.listing == nil, "setup: the apply wrote nothing of the call's result, not even the listing it started")
            #expect(slice.progressedFolderIds.isEmpty,
                    "#1062: a result that is not applied is no progress of the slice, though the call made some: \(slice.progressedFolderIds)")
            #expect(slice.inFlightFolderIds == [folderId],
                    "#1062: a timed-out request is reported in flight whatever the apply did: \(slice.inFlightFolderIds)")
        }
    }

    @Test("A run whose only call makes progress (it starts the listing and learns the folder's top) and then times out, and whose result is not applied (a reset of the folder began during the call): the run reports no work")
    @MainActor
    func skippedApplyOfAProgressingCallIsNoWorkOfTheRun() async throws {
        let server = Array(1...20)
        try await Self.withWorld("in-flight-skipped-run", server: server, local: server) { w in
            // No healthy folder: the account's INBOX completed its listing in
            // the warm-up and has nothing due, so this folder's call is the run's only one.
            try await w.markOwed()
            #expect(try w.catchUpState()?.listing == nil, "setup: no listing is stored, so the call starts one and reads the folder's UIDNEXT first")
            let fetch = Self.listingFetchFragment
            await Self.startResetAtTheFirstRequest(w)
            w.server.holdNextCommand(containing: fetch)
            let run = try await Self.inFlightRun(w)
            await w.provider.setFolderConnectionTestHookForTesting(nil)
            let held = w.server.isHoldingCommand(containing: fetch)
            try await Self.answerHeldRequest(w, holding: fetch)
            // A first range is asked only after the UIDNEXT read answered: the
            // call learned the top, the progress the slice test reads from the
            // provider's own result.
            #expect(held, "setup: the UIDNEXT read answered, and the first range was held past its timeout")
            #expect(try w.folder().uidValidityResetPendingAt != nil, "setup: the folder's reset began during the call")
            #expect(try w.catchUpState()?.listing == nil, "setup: the apply wrote nothing of the call's result")
            #expect(!run.didWork, "#1062: only an applied result is work of the run; this call's progress was never applied")
        }
    }

    // MARK: - A timeout past the hold bound ends the call (#1062)

    /// A pass-over test call's request budget: a production slice's
    /// (`SyncConfig.catchUpSliceMaxRequests`), far more than one range needs,
    /// so the budget never ends the call.
    static let passOverCallRequests = SyncConfig.catchUpSliceMaxRequests

    /// The folder's first site range (`siteServer`, `siteWidth`).
    static var siteRange: ClosedRange<Int> { siteServer[0]...(siteServer[0] + siteWidth - 1) }

    /// The folder's load floor in these worlds: the whole folder, its
    /// older-mail walk being complete (`IMAPProvider.heldRangeStart`).
    static var siteLoadFloor: Int? { IMAPProvider.heldRangeStart(olderMailComplete: true, olderMailCursor: nil) }

    /// The site range carried as a call leaves it: proven or not, with the
    /// missing UIDs still to load and the UIDs whose SEARCH it still owes,
    /// listed under the folder's load floor.
    static func siteCarry(missing: [UInt32] = [], unanswered: [UInt32] = [], proven: Bool = true) -> IMAPCatchUpState.CarriedRange {
        IMAPCatchUpState.CarriedRange(
            lo: siteRange.lowerBound, hi: siteRange.upperBound, candidates: [], missing: missing, deletedListed: [],
            proven: proven, heldFloor: nil, loadsFrom: siteLoadFloor, unanswered: unanswered)
    }

    /// Write the folder's listing in progress at `nextUid`, ranges of
    /// `siteWidth` up to `top`, with a hold on `nextUid` since `heldSince` (nil:
    /// none) and `carried` to go on with first. The rest of the stored state is
    /// kept, its lapse count included, and the listing started at that count,
    /// as one that started after the folder's last mark has.
    @MainActor
    static func writeCarriedListing(_ w: World, nextUid: Int, top: Int?, heldSince: Date?,
                                    carried: IMAPCatchUpState.CarriedRange) async throws {
        var state = try w.catchUpState() ?? IMAPCatchUpState(epoch: UInt32(epoch))
        var listing = IMAPCatchUpState.Listing(nextUid: nextUid, rangeWidth: siteWidth)
        listing.lapseCountAtStart = state.lapseCount
        listing.top = top
        listing.loadHeldSince = heldSince
        listing.carried = carried
        state.listing = listing
        let raw = try #require(state.encoded())
        let folderId = w.folderId
        try await w.pool.write { db in
            try db.execute(sql: "UPDATE folder SET catchUpState = ? WHERE id = ?", arguments: [raw, folderId])
        }
    }

    /// One catch-up call of the folder with a budget of `budget` requests and
    /// no deadline, under `clock`: the slice's result, and how many requests
    /// the call was charged (`CatchUpContext.requestsLeft`).
    @MainActor
    static func keptCall(_ w: World, budget: Int = passOverCallRequests, clock: CatchUpTestClock,
                         requestTimeout: TimeInterval = scaledTimeout) async -> (slice: CatchUpSliceResult, charged: Int) {
        let context = CatchUpContext(deadline: .distantFuture, clock: { clock.now }, maxRequests: budget,
                                     listingRangeMessages: w.rangeMessages, requestTimeoutSeconds: requestTimeout)
        await AccountManager.shared.clearRecentlyCompletedForTesting()
        let slice = await w.engine.runCatchUp(provider: w.provider, folderIds: [w.folderId], context: context)
        return (slice, budget - context.requestsLeft)
    }

    /// Answer the request a test held past its timeout, and wait for that late
    /// answer: a UIDNEXT read of the test's own needs the folder's connection,
    /// which the late request holds until it is answered, so the read returns
    /// only once the connection is free again. Nothing is timed.
    @MainActor
    static func answerHeldRequest(_ w: World, holding fragment: String) async throws {
        w.server.releaseHeldCommand(containing: fragment)
        _ = try await w.provider.getUidNextWithEpoch(folder: path)
    }

    /// Of `requests`, the commands that ask the folder something: all but a
    /// selection of it (SELECT, EXAMINE) or a liveness check (NOOP), which the
    /// test's own UIDNEXT read sends.
    static func asking(_ requests: [(index: Int, command: String)]) -> [String] {
        requests.map { $0.command }.filter { command in
            let verb = command.split(separator: " ").first.map { $0.uppercased() } ?? ""
            return !["SELECT", "EXAMINE", "NOOP"].contains(verb)
        }
    }

    /// One call that works `range`, whose hold on its earliest unresolved UID
    /// is past the bound by construction (it started `pastTheHold` before the
    /// test clock, which stands still), and whose request containing `fragment`
    /// is held unanswered, so it always times out. The call is charged exactly
    /// `charged` requests (the range's own, up to the one that timed out),
    /// sends the folder nothing after it, before or after its late answer,
    /// keeps the width cap, reports the folder in flight, and saves the range
    /// as passed over. The budget is far from spent (no deadline, the clock
    /// stands still, `passOverCallRequests`) and the range is not the
    /// listing's last unless the test says so, so only the end of the call
    /// stops a further request. The late answer is waited for before the
    /// caller counts anything again.
    @MainActor
    static func expectPassOverEndsTheCall(_ w: World, range: ClosedRange<Int>, timingOut fragment: String, charged: Int,
                                          clock: CatchUpTestClock,
                                          sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let before = try #require(try w.catchUpState()?.listing, "setup: the listing is in progress", sourceLocation: sourceLocation)
        w.server.holdNextCommand(containing: fragment)
        let start = w.server.recordedCommands().count
        let call = await keptCall(w, clock: clock)
        let held = w.server.isHoldingCommand(containing: fragment)
        let asked = requests(to: path, w.server, from: start)
        try await answerHeldRequest(w, holding: fragment)
        #expect(held, "setup: the request was held past its timeout", sourceLocation: sourceLocation)
        let listed = listingRanges(asked.map { $0.command })
        #expect(listed.allSatisfy { $0 == range }, "setup: the call asked no listing range but \(range): \(listed)",
                sourceLocation: sourceLocation)
        let timedOut = try #require(asked.first { $0.command.uppercased().contains(fragment.uppercased()) },
                                    "setup: the held request was asked", sourceLocation: sourceLocation)
        #expect(call.charged == charged,
                "#1062: the call was charged its \(charged) request(s) up to the one that timed out, and none after it: \(call.charged)",
                sourceLocation: sourceLocation)
        let after = asked.filter { $0.index > timedOut.index }.map { $0.command }
        #expect(after.isEmpty, "#1062: after a timeout past the hold bound the folder gets no further request in that call: \(after)",
                sourceLocation: sourceLocation)
        let afterAnswer = asking(requests(to: path, w.server, from: start).filter { $0.index > timedOut.index })
        #expect(afterAnswer.isEmpty, "#1062: no request of the call went out once the late answer freed the connection: \(afterAnswer)",
                sourceLocation: sourceLocation)
        #expect(call.slice.inFlightFolderIds == [w.folderId],
                "#1062: the timed-out request is reported in flight: \(call.slice.inFlightFolderIds)", sourceLocation: sourceLocation)
        let listing = try #require(try w.catchUpState()?.listing, "#1062: the listing stays in progress",
                                   sourceLocation: sourceLocation)
        #expect(listing.widthCap == before.widthCap,
                "#1062: the call asked no further range, so no timeout of one capped the width: \(String(describing: listing.widthCap))",
                sourceLocation: sourceLocation)
        #expect(listing.passedOver == true, "#1062: the passed-over range is saved, so the listing completes as not clean",
                sourceLocation: sourceLocation)
        #expect(listing.nextUid == range.upperBound + 1 && listing.loadHeldSince == nil && listing.carried == nil,
                "#1062: the listing is saved past the passed-over range: \(listing)", sourceLocation: sourceLocation)
    }

    /// The folder's next call, once the late answer is in: it goes on from
    /// past the passed-over `range`.
    @MainActor
    static func expectNextCallGoesOnPast(_ w: World, _ range: ClosedRange<Int>, clock: CatchUpTestClock,
                                         sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let next = try await nextRange(w, clock)
        #expect(next?.lowerBound == range.upperBound + 1,
                "#1062: the next call goes on from past the passed-over range: \(next.map { "\($0)" } ?? "none")",
                sourceLocation: sourceLocation)
    }

    @Test("A range's membership proof times out with its hold past the bound: the range is passed over and saved, the call is charged nothing after the proof and the folder gets no further request in it, the width cap stays, and the next call goes on from past the range")
    @MainActor
    func proofTimeoutPastTheHoldEndsTheCall() async throws {
        try await Self.withWorld("pass-over-proof", server: Self.siteServer, local: Self.siteServer) { w in
            let clock = CatchUpTestClock()
            try await Self.setListing(w, nextUid: Self.siteRange.lowerBound, rangeWidth: Self.siteWidth, top: Self.siteServer.last,
                                      loadHeldSince: clock.now.addingTimeInterval(-Self.pastTheHold))
            // The range's listing FETCH and its membership proof.
            try await Self.expectPassOverEndsTheCall(w, range: Self.siteRange, timingOut: "SEARCH", charged: 2, clock: clock)
            try await Self.expectNextCallGoesOnPast(w, Self.siteRange, clock: clock)
        }
    }

    @Test("A missing message's header load times out with its hold past the bound: the range is passed over and saved, the call is charged nothing after the load and the folder gets no further request in it, the width cap stays, and the next call goes on from past the range")
    @MainActor
    func headerLoadTimeoutPastTheHoldEndsTheCall() async throws {
        let missing = Self.siteMissing
        try await Self.withWorld("pass-over-load", server: Self.siteServer, local: Self.siteServer) { w in
            try await w.dropLocal([missing])
            let clock = CatchUpTestClock()
            // The range starts at the missing message, where its hold runs.
            let range = missing...(missing + Self.siteWidth - 1)
            try await Self.setListing(w, nextUid: missing, rangeWidth: Self.siteWidth, top: Self.siteServer.last,
                                      loadHeldSince: clock.now.addingTimeInterval(-Self.pastTheHold))
            // The range's listing FETCH, its membership proof and the header load.
            try await Self.expectPassOverEndsTheCall(w, range: range, timingOut: "ENVELOPE", charged: 3, clock: clock)
            try await Self.expectNextCallGoesOnPast(w, range, clock: clock)
        }
    }

    @Test("The SEARCH a carried range owes for a UID whose header record could not be read times out, with the hold on that UID past the bound: the range is passed over and saved, the call is charged nothing after the SEARCH and the folder gets no further request in it, the width cap stays, and the next call goes on from past the range")
    @MainActor
    func carriedSearchTimeoutPastTheHoldEndsTheCall() async throws {
        let missing = Self.siteMissing
        try await Self.withWorld("pass-over-carried-search", server: Self.siteServer, local: Self.siteServer) { w in
            try await Self.makeSiteMissingUnreadable(w)
            let clock = CatchUpTestClock()
            // The listing waits on the UID whose SEARCH the proven range still owes.
            try await Self.writeCarriedListing(w, nextUid: missing, top: Self.siteServer.last,
                                               heldSince: clock.now.addingTimeInterval(-Self.pastTheHold),
                                               carried: Self.siteCarry(unanswered: [UInt32(missing)]))
            // The owed SEARCH alone: the range is proven and has nothing left to load.
            try await Self.expectPassOverEndsTheCall(w, range: Self.siteRange, timingOut: "SEARCH", charged: 1, clock: clock)
            try await Self.expectNextCallGoesOnPast(w, Self.siteRange, clock: clock)
        }
    }

    @Test("The SEARCH for a UID whose header record could not be read, asked right after its load, times out with the hold on that UID past the bound: the range is passed over and saved, the call is charged nothing after the SEARCH and the folder gets no further request in it, the width cap stays, and the next call goes on from past the range")
    @MainActor
    func unreadableSearchTimeoutPastTheHoldEndsTheCall() async throws {
        let missing = Self.siteMissing
        try await Self.withWorld("pass-over-unreadable-search", server: Self.siteServer, local: Self.siteServer) { w in
            try await Self.makeSiteMissingUnreadable(w)
            let clock = CatchUpTestClock()
            // The listing waits on the missing UID the proven range still has to load.
            try await Self.writeCarriedListing(w, nextUid: missing, top: Self.siteServer.last,
                                               heldSince: clock.now.addingTimeInterval(-Self.pastTheHold),
                                               carried: Self.siteCarry(missing: [UInt32(missing)]))
            // The header load, whose record cannot be read, and the SEARCH for it.
            try await Self.expectPassOverEndsTheCall(w, range: Self.siteRange, timingOut: "SEARCH", charged: 2, clock: clock)
            try await Self.expectNextCallGoesOnPast(w, Self.siteRange, clock: clock)
        }
    }

    @Test("The SEARCH a carried range owes times out with its hold past the bound on the listing's last range: the range is passed over and saved, and the folder's next call completes the listing with no request, as not clean, so the folder stays owed a check")
    @MainActor
    func passOverOfTheLastRangeCompletesTheListingNotClean() async throws {
        // The folder ends at the site range: it is the listing's last.
        let server = Array(Self.siteRange)
        let missing = Self.siteMissing
        try await Self.withWorld("pass-over-last-range", server: server, local: server) { w in
            try await w.dropLocal([missing])
            try await w.markOwed()
            let clock = CatchUpTestClock()
            try await Self.writeCarriedListing(w, nextUid: missing, top: server.last,
                                               heldSince: clock.now.addingTimeInterval(-Self.pastTheHold),
                                               carried: Self.siteCarry(unanswered: [UInt32(missing)]))
            let started = try #require(try w.catchUpState()?.listing?.lapseCountAtStart, "setup: the listing records the lapse count it started at")
            let marked = try w.changeState().selfHealLapse ?? 0
            #expect(started >= marked, "setup: the listing started after the folder's mark, so only an unclean completion leaves the mark")
            try await Self.expectPassOverEndsTheCall(w, range: Self.siteRange, timingOut: "SEARCH", charged: 1, clock: clock)
            let start = w.server.recordedCommands().count
            let next = await Self.keptCall(w, clock: clock)
            let asked = Self.requests(to: Self.path, w.server, from: start).map { $0.command }
            #expect(next.charged == 0 && asked.isEmpty, "#1062: the next call sends no request, the listing being past its top: \(asked)")
            #expect(try w.catchUpState()?.listing == nil, "#1062: the next call completes the listing")
            #expect(try w.changeState().selfHealDue,
                    "#1062: the listing passed a range over, so it completes as not clean and the folder stays owed a check")
        }
    }

    // MARK: - A call that stops with no timeout leaves nothing in flight (#1062)

    /// NO answers to a request: one that names a response too large to read
    /// and one that names a response the client cannot decode (the answered
    /// failures that cap the width as a timeout does,
    /// `UIDWalkCursor.failureCallsForSmallerRange`), and an ordinary refusal.
    static let oversizedAnswer = "PayloadTooLargeError from the fixture"
    static let undecodableAnswer = "IMAPDecoderError from the fixture"
    static let refusedAnswer = "refused by the fixture"

    /// The fragment of the site range's listing FETCH.
    static var siteRangeFetch: String { "FETCH \(siteRange.lowerBound):\(siteRange.upperBound)" }

    /// A catch-up call that stops with no request timed out.
    enum UntimedStop: String, CaseIterable, Sendable {
        /// The site range's listing FETCH is answered as too large to read.
        case oversizedListing
        /// The site range's listing FETCH is answered as undecodable.
        case undecodableListing
        /// The site range's listing FETCH is refused.
        case refusedListing
        /// The budget runs out before the header load of a missing message.
        case budgetBeforeHeaderLoad
        /// The budget runs out before the SEARCH a carried range owes.
        case budgetBeforeOwedSearch
        /// The budget runs out before the SEARCH for a header record that
        /// could not be read.
        case budgetBeforeUnreadableSearch
        /// The UIDNEXT read (the SELECT of a call that starts a listing) is
        /// refused, or answered as too large to read.
        case refusedUidNext, oversizedUidNext
        /// The site range's membership proof (its SEARCH) is refused, or
        /// answered as too large to read.
        case refusedProof, oversizedProof
        /// The SEARCH a carried range owes is refused, or answered as too
        /// large to read.
        case refusedOwedSearch, oversizedOwedSearch
        /// The SEARCH for a header record that could not be read, asked right
        /// after its load, is refused, or answered as too large to read.
        case refusedUnreadableSearch, oversizedUnreadableSearch
        /// The header load of a missing message is refused, or answered as
        /// too large to read.
        case refusedHeaderLoad, oversizedHeaderLoad

        typealias Suite = IMAPMissingByUIDTests

        /// The answered failures of the call's requests other than its
        /// listing FETCH.
        static let answeredFailuresPastTheListing: [UntimedStop] = [
            .refusedUidNext, .oversizedUidNext, .refusedProof, .oversizedProof,
            .refusedOwedSearch, .oversizedOwedSearch, .refusedUnreadableSearch, .oversizedUnreadableSearch,
            .refusedHeaderLoad, .oversizedHeaderLoad,
        ]

        /// The folder of this stop's call: its listing at the site range; for
        /// the owed SEARCH, the site range carried with that SEARCH still owed
        /// (and, for the budget stop, its proof too); for the UIDNEXT read, no
        /// listing stored, so the call starts one.
        @MainActor
        func setUp(_ w: Suite.World) async throws {
            switch self {
            case .oversizedListing, .undecodableListing, .refusedListing, .refusedProof, .oversizedProof:
                try await Suite.startSiteListing(w)
            case .budgetBeforeHeaderLoad, .refusedHeaderLoad, .oversizedHeaderLoad:
                try await w.dropLocal([Suite.siteMissing])
                try await Suite.startSiteListing(w)
            case .budgetBeforeOwedSearch:
                try await w.dropLocal([Suite.siteMissing])
                try await Suite.writeCarriedListing(
                    w, nextUid: Suite.siteRange.lowerBound, top: Suite.siteServer.last, heldSince: nil,
                    carried: Suite.siteCarry(unanswered: [UInt32(Suite.siteMissing)], proven: false))
            case .refusedOwedSearch, .oversizedOwedSearch:
                try await w.dropLocal([Suite.siteMissing])
                try await Suite.writeCarriedListing(
                    w, nextUid: Suite.siteRange.lowerBound, top: Suite.siteServer.last, heldSince: nil,
                    carried: Suite.siteCarry(unanswered: [UInt32(Suite.siteMissing)]))
            case .budgetBeforeUnreadableSearch, .refusedUnreadableSearch, .oversizedUnreadableSearch:
                try await Suite.makeSiteMissingUnreadable(w)
                try await Suite.startSiteListing(w)
            case .refusedUidNext, .oversizedUidNext:
                try await w.markOwed()
            }
        }

        /// The fragments of the request this stop's answered failure answers
        /// (the SELECT in either quoting); none for a budget stop.
        var failingFragments: [String] {
            switch self {
            case .oversizedListing, .undecodableListing, .refusedListing: return [Suite.siteRangeFetch]
            case .refusedUidNext, .oversizedUidNext: return ["SELECT \(Suite.path)", "SELECT \"\(Suite.path)\""]
            // The proof names the range whole.
            case .refusedProof, .oversizedProof: return ["UID \(Suite.siteRange.lowerBound):\(Suite.siteRange.upperBound)"]
            case .refusedOwedSearch, .oversizedOwedSearch, .refusedUnreadableSearch, .oversizedUnreadableSearch:
                return ["UID \(Suite.siteMissing)"]
            case .refusedHeaderLoad, .oversizedHeaderLoad: return ["ENVELOPE"]
            case .budgetBeforeHeaderLoad, .budgetBeforeOwedSearch, .budgetBeforeUnreadableSearch: return []
            }
        }

        /// The NO answer this stop's failure gives; nil for a budget stop.
        var failingAnswer: String? {
            switch self {
            case .oversizedListing, .oversizedUidNext, .oversizedProof, .oversizedOwedSearch, .oversizedUnreadableSearch,
                 .oversizedHeaderLoad:
                return Suite.oversizedAnswer
            case .undecodableListing: return Suite.undecodableAnswer
            case .refusedListing, .refusedUidNext, .refusedProof, .refusedOwedSearch, .refusedUnreadableSearch, .refusedHeaderLoad:
                return Suite.refusedAnswer
            case .budgetBeforeHeaderLoad, .budgetBeforeOwedSearch, .budgetBeforeUnreadableSearch: return nil
            }
        }

        /// Arm this stop's answered failure for one call.
        func arm(_ w: Suite.World) {
            guard let answer = failingAnswer else { return }
            for fragment in failingFragments { w.server.failNextCommand(containing: fragment, message: answer) }
        }

        /// The requests this stop's call may send: for a budget stop, every
        /// request before the stop and none more; for a failure, plenty.
        var budget: Int {
            switch self {
            case .oversizedListing, .undecodableListing, .refusedListing, .refusedUidNext, .oversizedUidNext,
                 .refusedProof, .oversizedProof, .refusedOwedSearch, .oversizedOwedSearch,
                 .refusedUnreadableSearch, .oversizedUnreadableSearch, .refusedHeaderLoad, .oversizedHeaderLoad:
                return Suite.passOverCallRequests
            // The listing FETCH and the membership proof.
            case .budgetBeforeHeaderLoad: return 2
            // The carried range's membership proof.
            case .budgetBeforeOwedSearch: return 1
            // The listing FETCH, the membership proof and the header load.
            case .budgetBeforeUnreadableSearch: return 3
            }
        }

        /// What this stop's call is charged and leaves of the listing, as this
        /// stop always has: a failure at the listing FETCH stops there, and only
        /// an answer that names a response too large or undecodable caps the
        /// width; a failure at a later request stops at that request, caps
        /// nothing, and holds the range from the first UID it left unresolved,
        /// carrying what is still to ask; a budget stop spends the budget and
        /// carries the rest from the UID it stopped at.
        var leaves: (charged: Int, widthCap: Int?, nextUid: Int, carried: IMAPCatchUpState.CarriedRange?) {
            let missing = UInt32(Suite.siteMissing)
            switch self {
            case .oversizedListing, .undecodableListing:
                return (1, max(1, Suite.siteWidth / SyncConfig.catchUpWidthCapShrinkFactor), Suite.siteRange.lowerBound, nil)
            case .refusedListing:
                return (1, nil, Suite.siteRange.lowerBound, nil)
            case .budgetBeforeHeaderLoad:
                return (budget, nil, Suite.siteMissing, Suite.siteCarry(missing: [missing]))
            case .budgetBeforeOwedSearch, .budgetBeforeUnreadableSearch:
                return (budget, nil, Suite.siteMissing, Suite.siteCarry(unanswered: [missing]))
            // The SELECT alone: the listing the call started stays at UID 1,
            // where a new listing starts (`IMAPProvider.catchUpPlan`).
            case .refusedUidNext, .oversizedUidNext:
                return (1, nil, 1, nil)
            // The listing FETCH and the proof: the range is carried unproven,
            // held from its first UID.
            case .refusedProof, .oversizedProof:
                return (2, nil, Suite.siteRange.lowerBound, Suite.siteCarry(proven: false))
            // The owed SEARCH alone.
            case .refusedOwedSearch, .oversizedOwedSearch:
                return (1, nil, Suite.siteMissing, Suite.siteCarry(unanswered: [missing]))
            // The listing FETCH, the proof, the header load and the SEARCH.
            case .refusedUnreadableSearch, .oversizedUnreadableSearch:
                return (4, nil, Suite.siteMissing, Suite.siteCarry(unanswered: [missing]))
            // The listing FETCH, the proof and the header load.
            case .refusedHeaderLoad, .oversizedHeaderLoad:
                return (3, nil, Suite.siteMissing, Suite.siteCarry(missing: [missing]))
            }
        }

        /// `listing` is what this stop leaves (`leaves`).
        func expectLeft(_ listing: IMAPCatchUpState.Listing, _ label: String) {
            let expected = leaves
            #expect(listing.widthCap == expected.widthCap,
                    "\(label): the width cap is what this stop has always left: \(String(describing: listing.widthCap))")
            #expect(listing.nextUid == expected.nextUid, "\(label): the listing stands where this stop has always left it: \(listing.nextUid)")
            #expect(listing.carried == expected.carried,
                    "\(label): the carried work is what this stop has always left: \(String(describing: listing.carried))")
        }
    }

    @Test("A call that stops with no request timed out (its listing answered as too large to read, as undecodable, or refused; its UIDNEXT read, its membership proof, the SEARCH a carried range owes, the SEARCH for a header record that could not be read, or its header load refused or answered as too large to read; or its budget spent before a header load, before the SEARCH a carried range owes, or before the SEARCH for a header record that could not be read): the provider reports no request in flight and the slice leaves no folder out, while the width cap and the carried work are what that stop has always left",
          arguments: UntimedStop.allCases)
    @MainActor
    func callThatStopsWithoutATimeoutLeavesNothingInFlight(_ stop: UntimedStop) async throws {
        try await Self.withWorld("untimed-\(stop.rawValue)", server: Self.siteServer, local: Self.siteServer) { w in
            try await stop.setUp(w)
            let clock = CatchUpTestClock()
            let budget = stop.budget
            func context() -> CatchUpContext {
                CatchUpContext(deadline: .distantFuture, clock: { clock.now }, maxRequests: budget,
                               listingRangeMessages: w.rangeMessages)
            }
            // The provider's own result, read without an apply.
            stop.arm(w)
            let reading = context()
            let read = try await w.read(reading)
            #expect(budget - reading.requestsLeft == stop.leaves.charged, "setup: \(stop): the call stopped where this stop stops it")
            #expect(read.results.count == 1, "setup: \(stop): the folder's call returned a result")
            guard read.results.count == 1 else { return }
            #expect(!read.results[0].requestMayBeInFlight, "#1062: \(stop): no request timed out, so none may still be in flight")
            let provided = try #require(IMAPCatchUpState.decode(read.results[0].newState)?.listing,
                                        "setup: \(stop): the listing is in progress")
            stop.expectLeft(provided, "\(stop) (provider)")

            // The same call in a slice, applied.
            stop.arm(w)
            let applying = context()
            await AccountManager.shared.clearRecentlyCompletedForTesting()
            let slice = await w.engine.runCatchUp(provider: w.provider, folderIds: [w.folderId], context: applying)
            #expect(budget - applying.requestsLeft == stop.leaves.charged, "setup: \(stop): the call stopped where this stop stops it")
            #expect(slice.inFlightFolderIds.isEmpty, "#1062: \(stop): the slice leaves no folder out: \(slice.inFlightFolderIds)")
            let stored = try #require(try w.catchUpState()?.listing, "setup: \(stop): the listing is in progress")
            stop.expectLeft(stored, "\(stop) (slice)")
        }
    }

    @Test("A folder's listing request is answered as too large to read: the answer leaves nothing in flight, so the same run asks that folder again, at the capped width from the same UID, while a healthy folder of the account goes on and completes its listing")
    @MainActor
    func answeredOversizedListingKeepsTheFolderInTheRun() async throws {
        try await Self.withWorld("in-run-oversized", server: Self.siteServer, local: Self.siteServer) { w in
            try await Self.startHealthyListing(w)
            try await Self.startSiteListing(w)
            w.server.failNextCommand(containing: Self.siteRangeFetch, message: Self.oversizedAnswer)
            let start = w.server.recordedCommands().count
            let run = try await Self.inFlightRun(w)
            let ranges = Self.listingRanges(Self.requests(to: Self.path, w.server, from: start).map { $0.command })
            #expect(ranges.first == Self.siteRange, "setup: the folder's first range was asked, and answered as too large: \(ranges)")
            let capped = max(1, Self.siteWidth / SyncConfig.catchUpWidthCapShrinkFactor)
            #expect(ranges.dropFirst().first == Self.siteRange.lowerBound...(Self.siteRange.lowerBound + capped - 1),
                    "#1062: the same run asks the folder again, at the capped width from the same UID: \(ranges)")
            #expect(try Self.healthyState(w)?.listing == nil, "#1062: the healthy folder's listing completed in the same run")
            #expect(run.didWork, "setup: the run made progress")
        }
    }

    @Test("A folder's request other than its listing FETCH (its UIDNEXT read, its membership proof, the SEARCH a carried range owes, the SEARCH for a header record that could not be read, or its header load) is refused or answered as too large to read: the answer leaves nothing in flight, so the same run asks that folder again in a later slice, while a healthy folder of the account goes on and completes its listing",
          arguments: UntimedStop.answeredFailuresPastTheListing)
    @MainActor
    func answeredFailureKeepsTheFolderInTheRun(_ stop: UntimedStop) async throws {
        try await Self.withWorld("in-run-\(stop.rawValue)", server: Self.siteServer, local: Self.siteServer) { w in
            try await Self.startHealthyListing(w)
            try await stop.setUp(w)
            stop.arm(w)
            let start = w.server.recordedCommands().count
            // A slice has room for every request of the folder's call up to the failed one.
            let run = try await Self.inFlightRun(w, maxRequests: max(Self.inFlightSliceRequests, stop.leaves.charged))
            let asked = Self.requests(to: Self.path, w.server, from: start)
            let fragments = stop.failingFragments.map { $0.uppercased() }
            let failed = try #require(asked.first { request in fragments.contains { request.command.uppercased().contains($0) } },
                                      "setup: \(stop): the folder's request that failed was asked")
            // The failure ended the folder's call, so a later request is a later
            // slice's. Only a UID FETCH or SEARCH counts: a selection, a liveness
            // check or the LOGOUT of a connection dropped after the answer asks
            // the folder nothing.
            let after = asked.filter { $0.index > failed.index && $0.command.uppercased().hasPrefix("UID ") }.map { $0.command }
            #expect(!after.isEmpty,
                    "#1062: \(stop): nothing is in flight after an answered request, so the same run asks the folder again in a later slice: \(asked.map { $0.command })")
            #expect(try Self.healthyState(w)?.listing == nil, "#1062: \(stop): the healthy folder's listing completed in the same run")
            #expect(run.didWork, "setup: \(stop): the run made progress")
        }
    }
}
