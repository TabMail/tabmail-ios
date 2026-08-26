/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

/// The timestamp field of an app-log entry line — everything between the
/// line's leading `[` and the first `]`.
///
/// Shared by the three suites that assert on entry lines (`AppLogStore`,
/// `BackgroundSyncLogger`, `AuthDiagnostics`) so they parse the format one way.
/// Scalar-wise rather than with `hasPrefix`/`split`, matching
/// `AppLogStore.entryTag` and `MIS-IOS-013`.
enum AppLogEntryLine {
    static func timestampField(of line: Substring) -> String? {
        let scalars = Array(line.unicodeScalars)
        guard scalars.first == "[" else { return nil }
        guard let end = scalars.firstIndex(of: "]") else { return nil }
        var field = String.UnicodeScalarView()
        for scalar in scalars[1..<end] { field.append(scalar) }
        return String(field)
    }
}

/// Invariants of the single-file app log (GitHub #83).
///
/// These pin the PROPERTIES consolidation had to preserve, not the mechanism
/// that delivers them: one file for every main-app channel, channel-separable
/// reads, an unchanged always-on/debug-gated split, and a trim that never retains
/// a partial physical LINE — the unit is a line, not a logical entry, so a cut
/// inside `logChatError`'s deliberate two-line entry leaves its continuation as
/// a leading orphan.
///
/// `.processGlobalState` as well as `.serialized`: every test here rebinds
/// process-global seams (`AppLogStore.fileURLOverride` / `maxBytesOverride` /
/// `keepBytesOverride`, `DebugModeManager.loggingEnabledOverrideForTesting`),
/// and `.serialized` orders tests only WITHIN one suite. `BackgroundSyncLogger`
/// and `AuthDiagnostics` mutate the same globals from their own suites.
///
/// ⚠️ The trait is currently INERT, and the honest reason is worth stating so
/// nobody cites it as evidence the race is handled: `TabMail.xcscheme` sets
/// `parallelizable = "NO"`, so no two suites run concurrently and there is no
/// window for one suite's `_resetForTesting` to point another's writer at the
/// real Application Support log. It is here because it is the correct guard the
/// day parallelisation is enabled, and because every other suite that mutates
/// these globals carries it — not because it is fixing an observed flake.
/// Measured, not assumed: a probe suite hammering the same five keys with the
/// trait removed still ran strictly after this one.
///
/// ⚠️ The trait does not cover the OTHER hazard, and no trait could: a task
/// escaping an EARLIER test can call the always-on `BackgroundSyncLogger.log` /
/// `.logError` at any moment, and it lands in whichever file `fileURLOverride`
/// currently names. Assertions here are therefore scoped to each test's own
/// markers rather than to whole-file counts or a single expected tag.
@Suite("AppLogStore", .serialized, .processGlobalState)
struct AppLogStoreTests {

    // MARK: - The channel/writer table
    //
    // The always-on and debug-gated sets are DATA here rather than two
    // hand-written marker lists, because `everyChannelIsClassifiedExactlyOnce`
    // uses them as the oracle for `AppLogChannel.allCases`. A new channel whose
    // writer is not classified fails that test instead of being invisible.

    /// One channel and the named façade that writes it.
    ///
    /// `backgroundSyncLoggerFunction` is the `BackgroundSyncLogger` entry point
    /// the source scanner reads, or `nil` for a channel whose façade lives on a
    /// different type (`DeviceSyncLogger`, `AuthDiagnostics`).
    struct ChannelWriter: Sendable {
        let channel: AppLogChannel
        let backgroundSyncLoggerFunction: String?
        let write: @Sendable (String) -> Void
    }

    /// The five channels that persist in production regardless of the debug
    /// gate — a field failure has to leave a trace (`IOS-LOG-002`).
    static let alwaysOnWriters: [ChannelWriter] = [
        ChannelWriter(channel: .sync, backgroundSyncLoggerFunction: "log") {
            BackgroundSyncLogger.log($0)
        },
        ChannelWriter(channel: .error, backgroundSyncLoggerFunction: "logError") {
            BackgroundSyncLogger.logError($0, source: "TestSource")
        },
        ChannelWriter(channel: .chatError, backgroundSyncLoggerFunction: "logChatError") {
            BackgroundSyncLogger.logChatError($0)
        },
        ChannelWriter(channel: .deviceSync, backgroundSyncLoggerFunction: nil) {
            DeviceSyncLogger.log($0)
        },
        ChannelWriter(channel: .auth, backgroundSyncLoggerFunction: nil) {
            AuthDiagnostics.log($0)
        },
    ]

    /// The ten channels added for investigation, each a no-op unless debug mode
    /// is unlocked (global `CLAUDE.md` rule 12).
    static let debugGatedWriters: [ChannelWriter] = [
        ChannelWriter(channel: .bgAppRefresh, backgroundSyncLoggerFunction: "logBGAppRefresh") {
            BackgroundSyncLogger.logBGAppRefresh($0)
        },
        ChannelWriter(channel: .bgProcessing, backgroundSyncLoggerFunction: "logBGProcessing") {
            BackgroundSyncLogger.logBGProcessing($0)
        },
        ChannelWriter(channel: .aiProcessing, backgroundSyncLoggerFunction: "logAIProcessing") {
            BackgroundSyncLogger.logAIProcessing($0)
        },
        ChannelWriter(channel: .push, backgroundSyncLoggerFunction: "logPush") {
            BackgroundSyncLogger.logPush($0)
        },
        ChannelWriter(channel: .backfillAI, backgroundSyncLoggerFunction: "logBackfillAI") {
            BackgroundSyncLogger.logBackfillAI($0)
        },
        ChannelWriter(channel: .backfill, backgroundSyncLoggerFunction: "logBackfill") {
            BackgroundSyncLogger.logBackfill($0)
        },
        ChannelWriter(channel: .inbox, backgroundSyncLoggerFunction: "logInbox") {
            BackgroundSyncLogger.logInbox($0)
        },
        ChannelWriter(channel: .boot, backgroundSyncLoggerFunction: "logBoot") {
            BackgroundSyncLogger.logBoot($0)
        },
        ChannelWriter(channel: .bodyRender, backgroundSyncLoggerFunction: "logBodyRender") {
            BackgroundSyncLogger.logBodyRender($0)
        },
        ChannelWriter(channel: .stuckDiag, backgroundSyncLoggerFunction: "logStuckDiag") {
            BackgroundSyncLogger.logStuckDiag($0)
        },
    ]

    /// A per-channel marker that cannot be a SUBSTRING of another channel's.
    ///
    /// ⚠️ This is the shape four tests in this file got wrong. They asserted
    /// `contents.contains("sync_\(stamp)")` after writing `devicesync_\(stamp)`,
    /// and `"devicesync_X".contains("sync_X")` is `true` — so the assertion
    /// passed on a completely different channel's entry and the writer it named
    /// could be deleted outright without going red. Delimiting the tag on BOTH
    /// sides makes non-containment structural: `marker-AI-X` is not inside
    /// `marker-BACKFILL-AI-X`, because what follows `marker-` there is `B`.
    static func marker(for channel: AppLogChannel, _ stamp: some StringProtocol) -> String {
        "marker-\(channel.tag)-\(stamp)"
    }

    /// Point the store at a fresh temp file, inside a directory of its own, for
    /// the duration of one test — then restore every override.
    ///
    /// The DIRECTORY is per-test (not just the file) so that "no channel wrote
    /// its own file" is answerable: enumerate the directory and anything beyond
    /// the log itself is a regression. Enumerating the shared temp directory
    /// instead, as this helper used to, can only ever see files this suite
    /// named — which is why the old check could not fail.
    private func withTempLog<T>(_ body: (URL) throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("applog_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tabmail.log")
        AppLogStore.fileURLOverride.withLock { $0 = url }
        defer {
            AppLogStore._resetForTesting()
            try? FileManager.default.removeItem(at: dir)
        }
        return try body(url)
    }

    /// Force the debug gate for the duration of one test, then restore it.
    private func withDebugLogging<T>(_ enabled: Bool, _ body: () throws -> T) rethrows -> T {
        DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = enabled }
        defer { DebugModeManager.loggingEnabledOverrideForTesting.withLock { $0 = nil } }
        return try body()
    }

    /// Everything in `directory`, sorted. Names, not URLs: `contentsOfDirectory`
    /// can hand back a `/private`-resolved URL that compares unequal to the
    /// override's own URL for reasons that have nothing to do with logging.
    private func fileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: - The single-file invariant

    @Test("Every channel writes to ONE file")
    func allChannelsShareOneFile() throws {
        try withTempLog { url in
            try withDebugLogging(true) {
                // One entry per channel, written through the store directly so
                // this covers the full channel set rather than only the channels
                // that happen to have a façade today.
                //
                // `Self.marker` — the collision-safe `marker-<TAG>-<stamp>` shape
                // `facadeWritersShareOneFile` uses — and NOT `marker_<TAG>`. The
                // old spelling made this test vacuous for two channels:
                // `marker_BACKFILL` is a SUBSTRING of `marker_BACKFILL-AI`, so
                // `append` could return early for `.backfill` and the assertion
                // still passed on the BACKFILL-AI entry. Delimiting the tag on
                // both sides is what makes non-containment structural.
                let stamp = UUID().uuidString.prefix(8)
                for channel in AppLogChannel.allCases {
                    AppLogStore.append(Self.marker(for: channel, stamp), channel: channel)
                }
                let contents = AppLogStore.read()
                for channel in AppLogChannel.allCases {
                    #expect(contents.contains(Self.marker(for: channel, stamp)),
                            "\(channel.tag) did not land in the shared file")
                }
                // And `AppLogStore` itself created exactly one file in the
                // directory the override points at.
                //
                // ⚠️ Scope, stated precisely because the earlier wording claimed
                // more than this can deliver: every write here goes through
                // `AppLogStore.append`, so what is proven is that the STORE does
                // not fan out per channel. It does NOT prove that
                // `device_sync.log` cannot reappear beside `tabmail.log` — the
                // shipped `DeviceSyncLogger` path was a hardcoded real
                // Application Support URL, not one derived from
                // `AppLogStore.fileURL`, so a writer that reintroduced it would
                // write outside this override's directory and be invisible here.
                // `facadeWritersShareOneFile` covers the façades, and carries
                // the same caveat.
                let names = try fileNames(in: url.deletingLastPathComponent())
                #expect(names == [url.lastPathComponent],
                        "a sibling log file was created: \(names)")
            }
        }
    }

    @Test("The named writers all land in the same file, and open no second one")
    func facadeWritersShareOneFile() throws {
        try withTempLog { url in
            try withDebugLogging(true) {
                let stamp = UUID().uuidString.prefix(8)
                for writer in Self.alwaysOnWriters + Self.debugGatedWriters {
                    writer.write(Self.marker(for: writer.channel, stamp))
                }

                let contents = AppLogStore.read()
                for writer in Self.alwaysOnWriters + Self.debugGatedWriters {
                    let marker = Self.marker(for: writer.channel, stamp)
                    #expect(contents.contains(marker),
                            "\(writer.channel.tag) writer did not reach the shared file")
                }

                // "Reached the shared file" is only half the invariant. A façade
                // that kept its own `device_sync.log` AND also called
                // `AppLogStore.append` satisfies every substring assertion above
                // while production writes two persistent files — which is the
                // entire thing consolidation was for. Enumerating the directory
                // after the façades have run is what makes that dual write
                // visible.
                //
                // ⚠️ What this cannot see: a writer whose second file is a
                // HARDCODED absolute path (the shape the shipped
                // `DeviceSyncLogger` actually had — real Application Support,
                // not derived from `AppLogStore.fileURL`) lands outside this
                // override's directory and is invisible to any enumeration a
                // test may safely perform. Covered here: a sibling written
                // relative to the log's own directory.
                let names = try fileNames(in: url.deletingLastPathComponent())
                #expect(names == [url.lastPathComponent],
                        "a façade opened a second log file: \(names)")
            }
        }
    }

    @Test("Entries from different channels interleave in append order")
    func entriesInterleaveInCallOrder() {
        withTempLog { _ in
            withDebugLogging(true) {
                AppLogStore.append("first", channel: .sync)
                AppLogStore.append("second", channel: .inbox)
                AppLogStore.append("third", channel: .aiProcessing)

                let contents = AppLogStore.read()
                guard let firstPos = contents.range(of: "first"),
                      let secondPos = contents.range(of: "second"),
                      let thirdPos = contents.range(of: "third") else {
                    Issue.record("markers missing from log")
                    return
                }
                // Cross-channel interleaving is the whole reason for one file —
                // a per-channel file cannot express this ordering at all.
                // ⚠️ These writes are SEQUENTIAL, so append order and call order
                // coincide here. This test pins the interleaving, NOT a concurrent
                // call-order guarantee: across threads a caller preempted between
                // stamping and enqueueing lands after one that stamped later.
                #expect(firstPos.lowerBound < secondPos.lowerBound)
                #expect(secondPos.lowerBound < thirdPos.lowerBound)
            }
        }
    }

    // MARK: - Channel separability

    @Test("read(channel:) returns only that channel's entries")
    func channelFilterIsolatesOneChannel() {
        withTempLog { _ in
            withDebugLogging(true) {
                AppLogStore.append("backfill-first", channel: .backfill)
                AppLogStore.append("push-only", channel: .push)
                AppLogStore.append("backfill-second", channel: .backfill)

                let filtered = AppLogStore.read(channel: .backfill)
                // ⚠️ The markers are deliberately not prefixes of each other.
                // With `keep_me` / `keep_me_too`, a filter that returned only the
                // LAST matching entry still satisfied `contains("keep_me")` —
                // via `keep_me_too` — so both assertions passed while every
                // earlier entry on the channel was being dropped.
                #expect(filtered.contains("backfill-first"))
                #expect(filtered.contains("backfill-second"))
                #expect(!filtered.contains("push-only"))
                // Count too: dropping an entry cannot hide behind a marker that
                // happens to appear inside another one.
                let lines = filtered.split(separator: "\n", omittingEmptySubsequences: true)
                #expect(lines.count == 2, "expected both BACKFILL entries, got: \(filtered)")
            }
        }
    }

    @Test("A multi-line entry stays with its own channel")
    func continuationLinesFollowTheirEntry() {
        // logChatError deliberately emits a second `  User message: …` line.
        // A filter that keyed on every physical line would orphan it, and a
        // filter that mis-attributed it would leak user text into another
        // channel's export.
        let text = """
        [2026-08-25T10:00:00Z] [CHAT] tool failed
          User message: hello world
        [2026-08-25T10:00:01Z] [PUSH] registered

        """
        let chat = AppLogStore.filter(text, keepingChannel: .chatError)
        #expect(chat.contains("tool failed"))
        #expect(chat.contains("User message: hello world"))
        #expect(!chat.contains("registered"))

        let push = AppLogStore.filter(text, keepingChannel: .push)
        #expect(push.contains("registered"))
        #expect(!push.contains("hello world"))
    }

    @Test("entryTag parses a tag only from a line that starts an entry")
    func entryTagParsing() {
        #expect(AppLogStore.entryTag(of: "[2026-08-25T10:00:00Z] [SYNC] hello") == "SYNC")
        #expect(AppLogStore.entryTag(of: "[2026-08-25T10:00:00Z] [BACKFILL-AI] hello") == "BACKFILL-AI")
        // logError nests a source after the channel tag — the CHANNEL still wins.
        #expect(AppLogStore.entryTag(of: "[2026-08-25T10:00:00Z] [ERROR] [SyncEngine] boom") == "ERROR")
        // An entry whose message is empty still ends `] `.
        #expect(AppLogStore.entryTag(of: "[2026-08-25T10:00:00Z] [SYNC] ") == "SYNC")
        // Continuation and malformed lines are not entry starts.
        #expect(AppLogStore.entryTag(of: "  User message: hi") == nil)
        #expect(AppLogStore.entryTag(of: "") == nil)
        #expect(AppLogStore.entryTag(of: "[2026-08-25T10:00:00Z] no bracket") == nil)
        #expect(AppLogStore.entryTag(of: "[2026-08-25T10:00:00Z] [UNTERMINATED") == nil)
    }

    @Test("entryTag rejects a tag that is not delimited or is not a real channel")
    func entryTagRejectsForgedAndUnknownTags() {
        // Both of these used to parse as entry starts, and `read(channel:)` /
        // `clear(channel:)` key off exactly this function — so a continuation
        // line carrying user-authored text could be attributed to, or cleared
        // from, a channel it was never written on.
        //
        // No space after the tag's `]`: the text is a continuation line that
        // merely LOOKS like an entry, not a SYNC entry.
        #expect(AppLogStore.entryTag(of: "[junk] [SYNC]forged") == nil)
        #expect(AppLogStore.entryTag(of: "[2026-08-25T10:00:00Z] [SYNC]x") == nil)
        // A bracketed field that is not an AppLogChannel tag is not a tag.
        #expect(AppLogStore.entryTag(of: "[2026-08-25T10:00:00Z] [NOTACHANNEL] hi") == nil)
        #expect(AppLogStore.entryTag(of: "[2026-08-25T10:00:00Z] [] hi") == nil)
        #expect(AppLogStore.entryTag(of: "[2026-08-25T10:00:00Z] [sync] hi") == nil)
        // And the rejection composes: a forged line is filtered/cleared with the
        // entry above it, never on its own.
        let text = """
        [2026-08-25T10:00:00Z] [CHAT] tool failed
        [x] [SYNC]not really sync
        [2026-08-25T10:00:01Z] [PUSH] registered

        """
        #expect(!AppLogStore.filter(text, keepingChannel: .sync).contains("not really sync"))
        #expect(AppLogStore.filter(text, keepingChannel: .chatError).contains("not really sync"))
    }

    // MARK: - The two bounds on the persisted user span
    //
    // `logChatError` runs TWO different caps over `userMessage`, they answer
    // different questions, and an oracle that conflates them is wrong in one
    // direction or the other. Named here so every assertion below says which
    // one it is measuring.

    /// The PRIVACY cap — `prefix(100)`. It decides how much of what the user
    /// actually TYPED is persisted, and it is the tighter of the two.
    static let userMessagePrivacyCap = 100

    /// The SIZE cap, in unicode scalars. This is the hard ceiling a single
    /// oversized grapheme cannot defeat (`MIS-IOS-013`) — `prefix(100)` counts
    /// extended grapheme clusters and bounds neither scalars nor bytes.
    static let userMessageScalarCap = 400

    /// The most `DebugModeManager.escapedForLogLine` can expand a span by. It
    /// rewrites ONE control scalar as the six characters `\uXXXX` and copies
    /// every other scalar through unchanged.
    static let escapeExpansionFactor = 6

    /// The ceiling on the POST-escape span these tests read back off disk.
    ///
    /// ⚠️ Six times the pre-escape cap, NOT the cap itself, and the difference
    /// is the code's real guarantee rather than a slack allowance. The caps run
    /// BEFORE the escaper on purpose (`chatErrorCapsBeforeEscaping` pins that
    /// order — capping afterwards would slice a generated `\uXXXX` in half), so
    /// a user message of 400 newlines is 2400 scalars on disk and entirely
    /// correct. Asserting the pre-escape number against post-escape text would
    /// fail on CORRECT code for any control-character-heavy message.
    static var persistedUserSpanCeiling: Int { userMessageScalarCap * escapeExpansionFactor }

    @Test("A newline in logChatError's user message cannot forge another channel's entry")
    func chatErrorUserMessageCannotForgeAnotherChannel() {
        // `logChatError`'s `userMessage` is LITERAL user-typed chat input —
        // `AIChat` passes `userText` straight through — and the writer is
        // ALWAYS-ON, so this reaches production on every device. Unescaped, a user
        // who types a newline followed by `[x] [AUTH] …` writes a second PHYSICAL
        // line that `entryTag` parses as a genuine AUTH entry.
        //
        // The INVARIANT, not the mechanism: nothing a user can type produces an
        // entry attributed to a channel they never wrote on, their own text stays
        // wholly inside the CHAT entry that carries it, and clearing CHAT takes
        // all of it. Escaping is one way to get there; the properties are what is
        // pinned.
        //
        // Before consolidation the same forgery was confined to `chat_error.log`
        // and harmless. The shared file is what makes it cross-channel.
        withTempLog { _ in
            withDebugLogging(true) {
                let stamp = UUID().uuidString.prefix(8)
                let chatMarker = Self.marker(for: .chatError, stamp)
                let forged = "forged-\(stamp)"
                BackgroundSyncLogger.logChatError(
                    chatMarker,
                    userMessage: "help\n[x] [AUTH] \(forged) someone@example.com")

                // 1. No AUTH entry carries it. Scoped to this test's own stamp
                //    rather than to the AUTH channel being empty: `AuthDiagnostics`
                //    is always-on, so a task escaping an earlier test can land real
                //    AUTH entries in this same redirected file.
                #expect(!AppLogStore.read(channel: .auth).contains(forged),
                        "user-typed text forged an AUTH entry")

                // 2. The real CHAT entry is still whole — head AND continuation.
                //    A forged line that STARTS a new entry ends the CHAT run, so
                //    the user's own text is cut out of the one channel it belongs
                //    to and the export the reporter reads is silently truncated.
                let chat = AppLogStore.read(channel: .chatError)
                #expect(chat.contains(chatMarker), "the CHAT entry's own head is missing")
                #expect(chat.contains(forged),
                        "the user's text was truncated out of its own channel")

                // 3. Clearing CHAT takes all of it. A forged tail that no channel
                //    owns outlives every clear the UI offers short of "Clear All".
                AppLogStore.clear(channel: .chatError)
                #expect(!AppLogStore.read().contains(forged),
                        "a forged remainder survived clear(channel: .chatError)")
            }
        }
    }

    @Test("logChatError bounds how much of the user's text it persists")
    func chatErrorUserMessageIsCapped() {
        // Nothing in the tree writes a `userMessage` longer than a chat prompt,
        // so deleting the cap outright leaves every other test in this file
        // green. The INVARIANT: what lands on disk is bounded by the CAP, not by
        // how much the user happened to type.
        withTempLog { _ in
            withDebugLogging(true) {
                let stamp = String(UUID().uuidString.prefix(8))
                let chatMarker = Self.marker(for: .chatError, stamp)
                let head = "head-\(stamp)"
                let tail = "tail-\(stamp)"
                // `tail` sits far past the cap, so it can only reach the file if
                // no cap ran at all.
                BackgroundSyncLogger.logChatError(
                    chatMarker,
                    userMessage: head + String(repeating: "a", count: 500) + tail)

                let chat = AppLogStore.read(channel: .chatError)
                #expect(chat.contains(chatMarker), "the CHAT entry is missing entirely")
                // Non-vacuity: the HEAD of the user's text is still there, so
                // this measures a cap rather than a writer that dropped the span.
                #expect(chat.contains(head), "the user span was dropped, not capped")
                #expect(!chat.contains(tail),
                        "the whole user message was persisted — the cap is gone")

                // And the persisted span itself is bounded, independently of
                // where either marker happens to fall inside it. The UNIVERSAL
                // ceiling — what holds for any input at all — is the pre-escape
                // scalar cap times the escaper's maximum expansion. The tighter
                // privacy bound on ordinary text is pinned separately by
                // `chatErrorPrivacyCapBoundsOrdinaryText`, which is where an
                // exact number can honestly be asserted.
                guard let span = Self.userMessageSpan(in: chat, after: chatMarker) else {
                    Issue.record("no `User message:` continuation line in: \(chat)")
                    return
                }
                #expect(span.unicodeScalars.count <= Self.persistedUserSpanCeiling,
                        "persisted user span is \(span.unicodeScalars.count) scalars")
            }
        }
    }

    @Test("The privacy cap bounds ORDINARY text, not just a pathological grapheme")
    func chatErrorPrivacyCapBoundsOrdinaryText() {
        // Two caps run over `userMessage` and only ONE of them answers "how much
        // of what the user typed is persisted". Delete `prefix(100)` and keep the
        // 400-scalar size cap and every other test in this file stays green while
        // four times the intended user text lands on disk — the size cap cannot
        // stand in for the privacy cap, because it was never asking that question.
        //
        // ASCII deliberately: `escapedForLogLine` copies every printable scalar
        // through unchanged, so for this input the on-disk span IS what the
        // pre-escape cap produced and the bound can be stated tightly instead of
        // through the escaper's worst-case expansion.
        withTempLog { _ in
            withDebugLogging(true) {
                let stamp = String(UUID().uuidString.prefix(8))
                let chatMarker = Self.marker(for: .chatError, stamp)
                let head = "head-\(stamp)"
                // Comfortably past the privacy cap but INSIDE the size cap, so
                // only the privacy cap can be what bounds the result.
                let typed = head + String(repeating: "a", count: Self.userMessagePrivacyCap * 3)
                #expect(typed.unicodeScalars.count < Self.userMessageScalarCap,
                        "the input reaches the SIZE cap — this input cannot discriminate")
                BackgroundSyncLogger.logChatError(chatMarker, userMessage: typed)

                let chat = AppLogStore.read(channel: .chatError)
                guard let span = Self.userMessageSpan(in: chat, after: chatMarker) else {
                    Issue.record("no `User message:` continuation line in: \(chat)")
                    return
                }
                // Non-vacuity: the head of the user's text survived, so this is
                // measuring a cap rather than a writer that dropped the span.
                #expect(span.contains(head), "the user span was dropped, not capped")
                #expect(span.unicodeScalars.count <= Self.userMessagePrivacyCap,
                        "persisted span is \(span.unicodeScalars.count) scalars — the \(Self.userMessagePrivacyCap)-character privacy cap is gone")
            }
        }
    }

    @Test("An escaped user span may legitimately exceed the pre-escape scalar cap")
    func escapedUserSpanMayExceedTheScalarCap() {
        // This is the input that makes the ORACLE, not the code, the thing under
        // test. `"\r\n"` is ONE extended grapheme cluster carrying TWO control
        // scalars, so a hundred of them pass `prefix(100)` as 200 scalars, sit
        // inside the 400-scalar size cap untouched, and the escaper then rewrites
        // every one of them as six characters. 1200 scalars on disk, from a
        // completely correct implementation.
        //
        // An assertion of `<= 400` on this post-escape span — which is what two
        // tests here used to make — therefore fails on CORRECT code. The bound
        // the code actually guarantees is the pre-escape cap times the escaper's
        // maximum expansion, and this test is what keeps that constant honest:
        // loosen the ceiling below what escaping can produce and it goes red.
        withTempLog { _ in
            withDebugLogging(true) {
                let stamp = String(UUID().uuidString.prefix(8))
                let chatMarker = Self.marker(for: .chatError, stamp)
                let crlf = String(repeating: "\r\n", count: Self.userMessagePrivacyCap)
                // Precondition, and the whole reason this input discriminates.
                #expect(crlf.count == Self.userMessagePrivacyCap,
                        "the payload is not \(Self.userMessagePrivacyCap) grapheme clusters")
                #expect(crlf.unicodeScalars.count == Self.userMessagePrivacyCap * 2)
                BackgroundSyncLogger.logChatError(chatMarker, userMessage: crlf)

                let chat = AppLogStore.read(channel: .chatError)
                guard let span = Self.userMessageSpan(in: chat, after: chatMarker) else {
                    Issue.record("no `User message:` continuation line in: \(chat)")
                    return
                }
                // Strictly ABOVE the pre-escape cap, and still within the ceiling.
                #expect(span.unicodeScalars.count > Self.userMessageScalarCap,
                        "escaping did not expand the span — this input cannot discriminate")
                #expect(span.unicodeScalars.count <= Self.persistedUserSpanCeiling,
                        "persisted span is \(span.unicodeScalars.count) scalars")
                // Every backslash in it still introduces a COMPLETE escape — the
                // expansion above came from escaping, not from a sliced sequence.
                let truncated = Self.truncatedEscape(in: span)
                #expect(truncated == nil, "a sliced escape survived: \(truncated ?? "")")
            }
        }
    }

    @Test("logChatError caps the user's text BEFORE escaping it, never after")
    func chatErrorCapsBeforeEscaping() {
        // Escape-first-cap-second slices the escape sequence the escaper just
        // generated: 99 `a`s plus a newline escapes to 99 `a`s plus a six-scalar
        // sequence = 105 characters, and a 100-character cap then cuts INSIDE it
        // and leaves a lone backslash behind.
        //
        // The INVARIANT, not the mechanism: whatever survives the cap, every
        // backslash in the persisted span still introduces a COMPLETE escape
        // sequence. A half-written one renders as something the user never typed,
        // and — because the escaper is deliberately not injective — cannot be
        // told apart from text they did.
        withTempLog { _ in
            withDebugLogging(true) {
                let stamp = String(UUID().uuidString.prefix(8))
                let chatMarker = Self.marker(for: .chatError, stamp)
                BackgroundSyncLogger.logChatError(
                    chatMarker,
                    userMessage: String(repeating: "a", count: 99) + "\n")

                let chat = AppLogStore.read(channel: .chatError)
                guard let span = Self.userMessageSpan(in: chat, after: chatMarker) else {
                    Issue.record("no `User message:` continuation line in: \(chat)")
                    return
                }
                // Non-vacuity: the newline WAS escaped, so there is an escape
                // sequence present for a mis-ordering to be able to slice. Without
                // this the assertion below is satisfied by an empty span.
                #expect(span.unicodeScalars.contains("\u{5C}"),
                        "nothing was escaped — this input cannot discriminate")
                let truncated = Self.truncatedEscape(in: span)
                #expect(truncated == nil, "a sliced escape survived: \(truncated ?? "")")
            }
        }
    }

    @Test("One grapheme carrying thousands of combining marks cannot erase the log")
    func chatErrorBoundsOneOversizedGrapheme() {
        // `prefix(100)` counts extended grapheme CLUSTERS, and `"a"` followed by
        // several thousand combining acutes is ONE cluster — so a Character cap
        // passes it through whole (`MIS-IOS-013`: a SIZE question asked with a
        // grapheme-level API).
        //
        // The consequence is not a long line. The entry then has no newline until
        // its own terminal one, so `trimTail` — which keeps the last `keepBytes`
        // and advances past the FIRST newline in that tail — is left with nothing
        // to retain. Before `trimTail` gained its empty guard the rewrite replaced
        // the whole log with an EMPTY file, erasing every channel at once; it now
        // abandons the trim and leaves the log untrimmed instead. This test pins
        // the OUTCOME: an unrelated channel's history survives. ⚠️ It does NOT
        // demonstrate the store's guards — the façade's 400-scalar cap cuts this
        // input long before it reaches either `maxEntryScalars` or the trim
        // threshold, so what is exercised here is the FAÇADE bound alone. The
        // store's two guards are covered separately.
        withTempLog { _ in
            withDebugLogging(true) {
                // Small caps so the oversized-entry path is reachable without megabytes,
                // exactly as `trimKeepsWholeEntries` does.
                AppLogStore.maxBytesOverride.withLock { $0 = 4096 }
                AppLogStore.keepBytesOverride.withLock { $0 = 1024 }

                let stamp = String(UUID().uuidString.prefix(8))
                let survivor = Self.marker(for: .sync, stamp)
                let chatMarker = Self.marker(for: .chatError, stamp)
                AppLogStore.append(survivor, channel: .sync)

                let oneCluster = "a" + String(repeating: "\u{0301}", count: 5000)
                // Precondition, and the whole reason a Character cap is not a size
                // bound: thousands of scalars, ONE Character.
                #expect(oneCluster.count == 1, "the payload is not a single grapheme cluster")
                #expect(oneCluster.unicodeScalars.count == 5001)
                BackgroundSyncLogger.logChatError(chatMarker, userMessage: oneCluster)

                let contents = AppLogStore.read()
                #expect(contents != "(no log)", "one oversized entry erased the whole log")
                #expect(contents.contains(survivor),
                        "an unrelated channel's history was erased by one oversized entry")

                guard let span = Self.userMessageSpan(in: AppLogStore.read(channel: .chatError),
                                                      after: chatMarker) else {
                    Issue.record("no `User message:` continuation line in: \(contents)")
                    return
                }
                // 5001 scalars is what a Character-only cap lets through; the
                // ceiling here is the pre-escape scalar cap times the escaper's
                // maximum expansion, which is the bound the code guarantees for
                // ANY input (combining acutes are not control scalars, so this
                // particular span is not expanded at all).
                #expect(span.unicodeScalars.count <= Self.persistedUserSpanCeiling,
                        "persisted span is \(span.unicodeScalars.count) scalars — unbounded")
            }
        }
    }

    @Test("Channel tags are unique")
    func channelTagsAreUnique() {
        // Two channels sharing a tag would silently merge on every filtered read.
        let tags = AppLogChannel.allCases.map(\.tag)
        #expect(Set(tags).count == tags.count)
    }

    @Test("Every AppLogChannel is classified always-on or debug-gated, exactly once")
    func everyChannelIsClassifiedExactlyOnce() {
        // The two sets above are hand-maintained; `AppLogChannel.allCases` is
        // not. Deriving the oracle from `allCases` is what makes a SIXTEENTH
        // channel visible: added with an ungated writer and no entry here, it
        // used to slip past both gating tests (they only ever iterate their own
        // hand-written marker lists) and ship un-gated in production.
        let alwaysOn = Set(Self.alwaysOnWriters.map(\.channel))
        let gated = Set(Self.debugGatedWriters.map(\.channel))

        #expect(alwaysOn.count == Self.alwaysOnWriters.count, "a channel is listed twice as always-on")
        #expect(gated.count == Self.debugGatedWriters.count, "a channel is listed twice as debug-gated")
        #expect(alwaysOn.isDisjoint(with: gated), "a channel is classified BOTH ways")

        let classified = alwaysOn.union(gated)
        let all = Set(AppLogChannel.allCases)
        #expect(classified == all,
                "unclassified: \(all.subtracting(classified).map(\.tag).sorted())")
    }

    // MARK: - The gating split (IOS-LOG-002) — both sides

    @Test("Always-on channels persist while debug logging is DISABLED")
    func alwaysOnChannelsWriteWhenLocked() {
        withTempLog { _ in
            withDebugLogging(false) {
                let stamp = UUID().uuidString.prefix(8)
                for writer in Self.alwaysOnWriters {
                    writer.write(Self.marker(for: writer.channel, stamp))
                }

                // These five are deliberately always-on: a field failure has to
                // leave a trace. Consolidation must not have gated them.
                //
                // Asserted per CHANNEL, not against the whole file: the whole-file
                // oracle let one channel's entry satisfy another channel's
                // assertion (`devicesync_X` contains `sync_X`), so gating
                // `BackgroundSyncLogger.log` outright left this test green.
                for writer in Self.alwaysOnWriters {
                    let marker = Self.marker(for: writer.channel, stamp)
                    #expect(AppLogStore.read(channel: writer.channel).contains(marker),
                            "\(writer.channel.tag) was silenced while it must stay always-on")
                }
            }
        }
    }

    @Test("Debug-gated channels write NOTHING while debug logging is DISABLED")
    func gatedChannelsAreSilentWhenLocked() {
        withTempLog { _ in
            withDebugLogging(false) {
                let stamp = UUID().uuidString.prefix(8)
                for writer in Self.debugGatedWriters {
                    writer.write(Self.marker(for: writer.channel, stamp))
                }

                let contents = AppLogStore.read()
                for writer in Self.debugGatedWriters {
                    let marker = Self.marker(for: writer.channel, stamp)
                    #expect(!contents.contains(marker),
                            "\(writer.channel.tag) persisted while debug logging was disabled")
                }
            }
        }
    }

    @Test("Debug-gated channels DO write once debug logging is enabled")
    func gatedChannelsWriteWhenUnlocked() {
        // The other side of the pair above. Without this, a writer that was
        // accidentally hard-disabled would pass the silence test and look correct.
        withTempLog { _ in
            withDebugLogging(true) {
                let stamp = UUID().uuidString.prefix(8)
                for writer in Self.debugGatedWriters {
                    writer.write(Self.marker(for: writer.channel, stamp))
                }

                // Per channel, for the same reason as the always-on side: with a
                // whole-file `contains`, `backfillai_X` satisfied the assertion
                // for `ai_X`, so deleting `logAIProcessing`'s append kept this
                // test green.
                for writer in Self.debugGatedWriters {
                    let marker = Self.marker(for: writer.channel, stamp)
                    #expect(AppLogStore.read(channel: writer.channel).contains(marker),
                            "\(writer.channel.tag) did not persist while debug logging was enabled")
                }
            }
        }
    }

    // MARK: - The gate covers the console too (global CLAUDE.md rule 12)

    @Test("Every debug-gated writer gates its print as well as its file write")
    func gatedWritersGateTheirPrintToo() throws {
        // Rule 12 is "a no-op in production", not "writes no file in production".
        // Every behavioural test in this file reads the FILE, so moving a
        // `print` above its `guard` — leaking to the console (and to Console.app
        // on a shipped device) for a channel that is supposed to be silent —
        // is invisible to all of them. This reads the source instead, in the
        // style of `RenderPathLogSinkTests`.
        //
        // ⚠️ Honest statement of the bar this clears. `gateViolation` is a
        // LEXICAL scan for `print(` / `NSLog(` / `os_log(` inside one function
        // body, compared by source offset against the guard's own text. It
        // catches a sink moved above its guard, and a gated writer that has no
        // guard. It does NOT catch an INDIRECT sink: put the `print` in a helper
        // and call `emitPush(message)` above the guard and this reports clean,
        // because no sink token appears in the scanned body. Real dataflow
        // analysis is not attempted and this test does not claim it.
        let source = try Self.projectFile("TabMail/Services/BackgroundSyncLogger.swift")

        var scanned = 0
        var withSink = 0
        for writer in Self.debugGatedWriters {
            guard let name = writer.backgroundSyncLoggerFunction else {
                Issue.record("\(writer.channel.tag) has no BackgroundSyncLogger entry point to scan")
                continue
            }
            guard let body = Self.functionBody(of: name, in: source) else {
                Issue.record("could not find the body of BackgroundSyncLogger.\(name)")
                continue
            }
            scanned += 1
            // Non-vacuity: we found the RIGHT body, not an empty range that
            // trivially satisfies "no print before the guard".
            #expect(body.contains("AppLogStore.append("),
                    "\(name)'s scanned body does not write to AppLogStore — wrong range?")
            if Self.firstConsoleSink(in: body) != nil { withSink += 1 }
            let violation = Self.gateViolation(in: body)
            #expect(violation == nil, "\(name): \(violation ?? "")")
        }
        #expect(scanned == Self.debugGatedWriters.count)
        // If NO gated writer had a console sink at all, the check above would be
        // satisfied by absence and would keep passing after every gate was
        // removed.
        #expect(withSink > 0, "no debug-gated writer writes to the console — the scan proves nothing")
    }

    @Test("The print/guard scanner detects the violations it claims to")
    func gateScannerIsNotVacuous() {
        // A positive control for the scanner used above: it must flag both
        // failure shapes, and must not flag the compliant one.
        let compliant = """
            guard DebugModeManager.isLoggingEnabled() else { return }
            print("[X] \\(message)")
            AppLogStore.append(message, channel: .push)
        """
        let printBeforeGuard = """
            print("[X] \\(message)")
            guard DebugModeManager.isLoggingEnabled() else { return }
            AppLogStore.append(message, channel: .push)
        """
        let noGate = """
            print("[X] \\(message)")
            AppLogStore.append(message, channel: .push)
        """
        // Rule 12 names three sinks, so the scanner must flag all three — a
        // logger that reached for NSLog or os_log instead of print would
        // otherwise pass while writing to the unified log on a shipped device,
        // which is a LOUDER leak than the bare print the scanner started with.
        let nsLogBeforeGuard = """
            NSLog("[X] %@", message)
            guard DebugModeManager.isLoggingEnabled() else { return }
            AppLogStore.append(message, channel: .push)
        """
        let osLogBeforeGuard = """
            os_log("[X] %{public}@", message)
            guard DebugModeManager.isLoggingEnabled() else { return }
            AppLogStore.append(message, channel: .push)
        """
        // The gated forms of the same two must NOT be flagged, or the scanner
        // would be rejecting compliant code rather than discriminating.
        let nsLogAfterGuard = """
            guard DebugModeManager.isLoggingEnabled() else { return }
            NSLog("[X] %@", message)
            AppLogStore.append(message, channel: .push)
        """
        // The documented blind spot, asserted rather than described: an
        // indirect sink reached through a helper is NOT detected. This is the
        // scanner's limit, not a bug to fix here — pinning it keeps a future
        // reader from mistaking a clean scan for a proof.
        let indirectSinkBeforeGuard = """
            emitPush(message)
            guard DebugModeManager.isLoggingEnabled() else { return }
            AppLogStore.append(message, channel: .push)
        """
        #expect(AppLogStoreTests.gateViolation(in: compliant) == nil)
        #expect(AppLogStoreTests.gateViolation(in: printBeforeGuard) != nil)
        #expect(AppLogStoreTests.gateViolation(in: noGate) != nil)
        #expect(AppLogStoreTests.gateViolation(in: nsLogBeforeGuard) != nil)
        #expect(AppLogStoreTests.gateViolation(in: osLogBeforeGuard) != nil)
        #expect(AppLogStoreTests.gateViolation(in: nsLogAfterGuard) == nil)
        #expect(AppLogStoreTests.gateViolation(in: indirectSinkBeforeGuard) == nil,
                "lexical scan: an indirect sink is a KNOWN blind spot, documented above")
        // And the primitive it is built on actually finds tokens.
        #expect(AppLogStoreTests.firstConsoleSink(in: compliant)?.token == "print(")
        #expect(AppLogStoreTests.firstConsoleSink(in: nsLogAfterGuard)?.token == "NSLog(")
        #expect(AppLogStoreTests.firstConsoleSink(in: "no sinks here") == nil)
    }

    // MARK: - Clearing

    @Test("clear(channel:) drops one channel and preserves the rest")
    func clearOneChannelPreservesOthers() {
        withTempLog { _ in
            withDebugLogging(true) {
                AppLogStore.append("stuck_line", channel: .stuckDiag)
                AppLogStore.append("sync_line", channel: .sync)
                AppLogStore.append("stuck_line_two", channel: .stuckDiag)

                AppLogStore.clear(channel: .stuckDiag)

                let contents = AppLogStore.read()
                // StuckMessageDiagnostics.run clears its channel before each
                // scan; with one file that must not take everything else with it.
                #expect(!contents.contains("stuck_line"))
                #expect(!contents.contains("stuck_line_two"))
                #expect(contents.contains("sync_line"))
            }
        }
    }

    @Test("clear(channel:) drops a multi-line entry whole")
    func clearOneChannelDropsContinuationLines() {
        withTempLog { _ in
            withDebugLogging(true) {
                BackgroundSyncLogger.logChatError("tool failed", userMessage: "secret user text")
                AppLogStore.append("sync_line", channel: .sync)

                AppLogStore.clear(channel: .chatError)

                let contents = AppLogStore.read()
                #expect(!contents.contains("tool failed"))
                #expect(!contents.contains("secret user text"))
                #expect(contents.contains("sync_line"))
            }
        }
    }

    @Test("clear(channel:) removes a LEADING orphan for any channel")
    func clearRemovesLeadingOrphanForAnyChannel() throws {
        // A tail-trim that cuts between a `logChatError` entry's two lines leaves
        // the file starting with `  User message: …` and no entry above it.
        // `read(channel:)` drops that orphan for EVERY channel (its filter seeds
        // `including = false`), so no export shows it — and `clear(channel:)`
        // seeded `dropping = false`, so no clear removed it either. Unreadable
        // AND unclearable is how a fragment of user text outlives every clear the
        // UI offers short of "Clear All".
        //
        // EVERY channel, derived from `allCases` rather than from a hand-picked
        // pair, because the claim in the name is "any channel" and a sample cannot
        // support it. Two channels — `.chatError` (where the orphan's text came
        // from) and `.push` (absent from the file entirely) — were enough to catch
        // a `dropping` seed that special-cased the orphan's own channel, and NOT
        // enough to catch one that special-cases any channel they happen to miss:
        // seeding `dropping = channel != .auth` left that pair green while a
        // fragment of user text survived `clear(channel: .auth)`. Deriving the
        // oracle from `allCases` is also what makes a SIXTEENTH channel covered
        // the day it is added, with no edit here.
        for channel in AppLogChannel.allCases {
            // The surviving entry has to sit on a channel OTHER than the one being
            // cleared. With a fixed `.sync` survivor the `.sync` iteration asserts
            // that a LEGITIMATE removal did not happen, which is a bug in the
            // fixture rather than in `clear(channel:)`.
            let survivorChannel: AppLogChannel = (channel == .sync) ? .push : .sync
            try withTempLog { url in
                // The timestamp is generated rather than hardcoded (no fixed dates
                // in tests) — only its SHAPE matters to `entryTag`.
                let orphaned = """
                  User message: secret user text
                [\(Date().iso8601String())] [\(survivorChannel.tag)] survivor

                """
                try Data(orphaned.utf8).write(to: url)

                // Precondition: no channel can read it back (so "it's gone from
                // the export" is not what this test is measuring).
                #expect(!AppLogStore.read(channel: .chatError).contains("secret user text"))
                #expect(!AppLogStore.read(channel: survivorChannel).contains("secret user text"))

                // Clearing a channel the orphan does not belong to still removes
                // it, and leaves the real entries alone.
                AppLogStore.clear(channel: channel)
                #expect(!AppLogStore.read().contains("secret user text"),
                        "clear(channel: .\(channel.tag)) left the orphan behind")
                #expect(AppLogStore.read().contains("survivor"),
                        "clear(channel: .\(channel.tag)) took an unrelated entry with it")
            }
        }
    }

    @Test("Appending after clear(channel:) starts a new line")
    func appendAfterChannelClearStartsANewLine() {
        // The dropped entry must not take the file's trailing newline with it.
        // If it does, the next append lands on the tail of the surviving entry
        // and BOTH become one unparseable line — the surviving entry's text is
        // corrupted and the new entry can never be filtered back out.
        withTempLog { _ in
            withDebugLogging(true) {
                AppLogStore.append("survivor", channel: .sync)
                AppLogStore.append("doomed", channel: .stuckDiag)   // last entry in the file
                AppLogStore.clear(channel: .stuckDiag)
                AppLogStore.append("after_clear", channel: .sync)

                let contents = AppLogStore.read()
                let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
                // Two appends that survived ⇒ two lines. Assert the COUNT, not the
                // absence of a concatenated marker: the merged line reads
                // `…survivor[<timestamp>] [SYNC] after_clear`, so the two markers
                // are never adjacent and a `contains("survivorafter_clear")` check
                // passes even when the entries have merged. It also still parses as
                // a SYNC entry, because `entryTag` only reads the line's head — so
                // neither of those is a usable oracle here.
                //
                // Counted over THIS test's own markers rather than over the whole
                // file: an always-on writer escaping an EARLIER test (a stray
                // `BackgroundSyncLogger.log` from a task that outlived it) lands in
                // the redirected file and would otherwise make this a flake. A
                // merged line contains BOTH markers, so it still counts as one and
                // the assertion keeps its full discriminating power.
                let mine = lines.filter { $0.contains("survivor") || $0.contains("after_clear") }
                #expect(mine.count == 2, "entries merged onto one line: \(contents)")
                #expect(lines.filter { $0.hasSuffix("survivor") }.count == 1)
                #expect(lines.filter { $0.hasSuffix("after_clear") }.count == 1)
                // And the new entry is still separable by channel.
                #expect(AppLogStore.read(channel: .sync).contains("after_clear"))
            }
        }
    }

    @Test("A filtered read ends with exactly one newline")
    func filteredReadHasNoBlankTail() {
        let text = "[2026-08-25T10:00:00Z] [SYNC] only\n"
        #expect(AppLogStore.filter(text, keepingChannel: .sync) == text)
    }

    @Test("clear() empties every channel")
    func clearAllEmptiesFile() {
        withTempLog { _ in
            withDebugLogging(true) {
                AppLogStore.append("a", channel: .sync)
                AppLogStore.append("b", channel: .push)
                AppLogStore.clear()
                #expect(AppLogStore.read() == "(no log)")
            }
        }
    }

    @Test("Reading a MISSING log returns a placeholder, never a crash")
    func readPlaceholdersForAMissingFile() {
        // Named for the case it actually exercises. It used to say "an empty or
        // missing log" while asserting only that the file is ABSENT — the
        // empty-file case is a different code path and belongs to the test below,
        // which does cover it. The overclaim was in the name, not in the coverage.
        withTempLog { url in
            #expect(!FileManager.default.fileExists(atPath: url.path),
                    "this is the MISSING-file case; the empty-file case is a separate test")
            #expect(AppLogStore.read() == "(no log)")
            #expect(AppLogStore.read(channel: .sync) == "(no SYNC log)")
            #expect(AppLogStore.read(channel: .stuckDiag).contains("run the scan"))
        }
    }

    @Test("Reading an EXISTING but empty log returns a placeholder too")
    func readPlaceholdersForAnExistingEmptyFile() throws {
        // Distinct code path from the test above: there the file is absent and
        // `String(contentsOf:)` throws, so `read`/`read(channel:)` never reach
        // their filters. Here the read succeeds and returns "" — which is the
        // state the file is actually left in by `clear()`, and by a first
        // `append` that creates the file before writing.
        try withTempLog { url in
            try Data().write(to: url)
            #expect(FileManager.default.fileExists(atPath: url.path))
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
            #expect(size == 0, "precondition: the file exists and is empty")

            #expect(AppLogStore.read() == "(no log)")
            #expect(AppLogStore.read(channel: .sync) == "(no SYNC log)")
            #expect(AppLogStore.read(channel: .stuckDiag).contains("run the scan"))
        }
    }

    // MARK: - Torn writes

    @Test("An append onto a torn tail starts a new line instead of merging")
    func appendAfterATornWriteStartsANewLine() throws {
        // Every entry ends with `\n`, so a file that does not is one whose last
        // write was cut short — the process died between the write starting and
        // the bytes landing. The INVARIANT: an append onto a torn tail still
        // yields two independently parseable, independently FILTERABLE entries.
        // Merged, the second entry is attributed to the FIRST one's channel and
        // `clear(channel:)` on that channel deletes the survivor with it.
        //
        // New exposure, not a pre-existing bug: at v1.7.14 `AuthDiagnostics` and
        // `DeviceSyncLogger` rewrote their whole file with
        // `write(to:atomically:true)` — an atomic replace cannot leave a partial
        // line — and every other channel appended to a file only IT wrote. All
        // fifteen now append in place to ONE shared file.
        try withTempLog { url in
            try withDebugLogging(true) {
                let stamp = UUID().uuidString.prefix(8)
                let tornMarker = Self.marker(for: .sync, stamp)
                let nextMarker = Self.marker(for: .push, stamp)
                // Deliberately NO trailing newline: this IS the torn tail. The
                // timestamp is generated rather than hardcoded (no fixed dates in
                // tests) — only its SHAPE matters to `entryTag`.
                let torn = "[\(Date().iso8601String())] [SYNC] \(tornMarker)"
                try Data(torn.utf8).write(to: url)

                AppLogStore.append(nextMarker, channel: .push)

                let contents = AppLogStore.read()
                let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
                // Counted over THIS test's own markers, never the whole file: an
                // always-on writer escaping an EARLIER test lands in the
                // redirected file. A merged line contains BOTH markers and still
                // counts as one, so the oracle keeps its full discriminating power.
                let mine = lines.filter { $0.contains(tornMarker) || $0.contains(nextMarker) }
                #expect(mine.count == 2, "the torn tail swallowed the next entry: \(contents)")
                guard mine.count == 2 else { return }

                // Separability is the half that actually hurts: a merged line
                // parses as SYNC, so the PUSH entry can never be filtered back out.
                #expect(AppLogStore.read(channel: .sync).contains(tornMarker))
                #expect(AppLogStore.read(channel: .push).contains(nextMarker))
            }
        }
    }

    @Test("Consecutive appends leave no blank line between entries")
    func consecutiveAppendsDoNotInsertABlankLine() {
        // The torn-tail repair writes its newline only when the file does NOT
        // already end with one. Writing it whenever `size > 0` instead separates
        // EVERY pair of entries with a blank line — and every other test in this
        // file splits with `omittingEmptySubsequences: true`, so all of them stay
        // green while the exported log doubles in height and each blank becomes an
        // unattributed continuation line that `read(channel:)` hands to whichever
        // entry precedes it.
        withTempLog { _ in
            withDebugLogging(true) {
                let stamp = String(UUID().uuidString.prefix(8))
                let first = Self.marker(for: .sync, stamp)
                let second = Self.marker(for: .push, stamp)
                AppLogStore.append(first, channel: .sync)
                AppLogStore.append(second, channel: .push)

                let contents = AppLogStore.read()
                // Empty subsequences KEPT: the blank line IS the thing being
                // measured, so dropping it is exactly the blindness that let this
                // through everywhere else.
                let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
                guard let firstIndex = lines.firstIndex(where: { $0.contains(first) }),
                      let secondIndex = lines.firstIndex(where: { $0.contains(second) }) else {
                    Issue.record("this test's markers are missing from the log: \(contents)")
                    return
                }
                #expect(firstIndex < secondIndex, "the entries landed out of call order")
                guard firstIndex < secondIndex else { return }

                // Scoped to this test's own span rather than to the whole file: an
                // always-on writer escaping an EARLIER test lands in the redirected
                // file, and its entry between these two is a real line, not a blank.
                #expect(lines[firstIndex...secondIndex].allSatisfy { !$0.isEmpty },
                        "a blank line was inserted between consecutive entries: \(contents)")
            }
        }
    }

    @Test("One invalid UTF-8 byte leaves the log readable AND clearable")
    func invalidUTF8ByteDoesNotHideTheWholeLog() throws {
        // A torn write can split a multibyte UTF-8 scalar. The INVARIANT: one bad
        // byte costs that byte, not the file — every other entry stays readable
        // and filterable, and `clear(channel:)` still removes the channel it
        // names. A throwing decode made `read()` return the MISSING-file
        // placeholder for the ENTIRE file and turned `clear(channel:)` into a
        // silent no-op, so a single byte destroyed the whole diagnostic artifact
        // and simultaneously made it unclearable.
        try withTempLog { url in
            try withDebugLogging(true) {
                let stamp = UUID().uuidString.prefix(8)
                let syncMarker = Self.marker(for: .sync, stamp)
                let pushMarker = Self.marker(for: .push, stamp)
                let timestamp = Date().iso8601String()   // generated, never hardcoded

                var bytes = Data("[\(timestamp)] [SYNC] \(syncMarker) ".utf8)
                bytes.append(0xC3)   // a lone UTF-8 lead byte — a scalar cut in half
                bytes.append(contentsOf: Array("\n[\(timestamp)] [PUSH] \(pushMarker)\n".utf8))
                try bytes.write(to: url)

                let contents = AppLogStore.read()
                #expect(contents != "(no log)", "one torn byte hid the ENTIRE log")
                #expect(contents.contains(syncMarker), "the SYNC entry beside the bad byte was lost")
                #expect(contents.contains(pushMarker), "an untouched later entry was lost")
                #expect(AppLogStore.read(channel: .push).contains(pushMarker),
                        "the channel filter cannot reach past the bad byte")

                // The half that fails SILENTLY: an unreadable file makes
                // `clear(channel:)` a no-op that reports nothing.
                AppLogStore.clear(channel: .sync)
                let after = AppLogStore.read()
                #expect(!after.contains(syncMarker), "clear(channel:) silently did nothing")
                #expect(after.contains(pushMarker), "clear(channel:) took another channel with it")
            }
        }
    }

    // MARK: - The serial I/O queue

    @Test("Concurrent writers across channels produce whole, parseable entries")
    func concurrentWritersNeverInterleavePartialEntries() {
        // `AppLogStore`'s own header calls one serial queue for one file
        // "load-bearing rather than merely tidy": `DeviceSyncLogger` used to own a
        // SECOND queue and `AuthDiagnostics` wrote synchronously on the caller's
        // thread, including from `TabMailApp.init` on MainActor.
        //
        // Nothing pinned that claim. Every other test in this file writes from a
        // single thread, so giving `ioQueue` `attributes: .concurrent` leaves all
        // of them green while two `seekToEnd`-then-write pairs race for the same
        // offset AND `read`'s own `ioQueue.sync` stops being a drain — on a
        // concurrent queue it runs one block, it does not wait for the rest.
        //
        // The INVARIANT, not the mechanism: however many threads call `append`,
        // every physical line in the file parses as an entry, and every write this
        // test made is present on exactly one line.
        withTempLog { _ in
            withDebugLogging(true) {
                let stamp = String(UUID().uuidString.prefix(8))
                let channels = AppLogChannel.allCases
                let writes = 300

                DispatchQueue.concurrentPerform(iterations: writes) { iteration in
                    let channel = channels[iteration % channels.count]
                    AppLogStore.append("\(Self.marker(for: channel, stamp))-\(iteration)",
                                       channel: channel)
                }

                // `read()` drains `ioQueue` before decoding, so every enqueued
                // write is on disk by the time this returns.
                let contents = AppLogStore.read()
                let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)

                // Both oracles are scoped to THIS test's own stamp, never to the
                // whole file. An always-on writer escaping an EARLIER test lands in
                // the redirected file, and `logChatError`'s deliberate two-line
                // entry would contribute a continuation line that legitimately does
                // not parse — a whole-file oracle would read that as a torn write.
                let mine = lines.filter { $0.contains(stamp) }

                // 1. No torn or merged line among them. A write landing inside
                //    another entry leaves a line with no valid `[ts] [TAG] ` head,
                //    which is precisely what `entryTag` refuses.
                for line in mine {
                    #expect(AppLogStore.entryTag(of: line) != nil,
                            "a concurrent write left an unparseable line: \(line)")
                }

                // 2. Every write is present, on its own line. Two entries merged
                //    onto one physical line still count as ONE, so the count keeps
                //    its full discriminating power in both directions.
                #expect(mine.count == writes,
                        "expected \(writes) entries from this test, found \(mine.count)")
            }
        }
    }

    // MARK: - Trim

    @Test("The production byte caps are 32 MB, trimmed back to 16 MB")
    func productionByteCapsArePinned() {
        // The cap has to hold FIFTEEN channels now, not the one
        // `background_sync.log` held at 16 MB — and the trim is whole-file with
        // no per-channel reservation, so the ceiling is the only thing standing
        // between a chatty channel and a quiet channel's evicted history.
        #expect(AppLogStore.maxBytes == 32 * 1024 * 1024)
        #expect(AppLogStore.keepBytes == 16 * 1024 * 1024)
        // The 2:1 ratio bounds how often the whole-file atomic rewrite runs.
        #expect(AppLogStore.maxBytes == AppLogStore.keepBytes * 2)
    }

    @Test("Tail trim keeps the newest entries and never leaves a partial physical LINE")
    func trimKeepsWholeEntries() {
        withTempLog { _ in
            withDebugLogging(true) {
                AppLogStore.maxBytesOverride.withLock { $0 = 4096 }
                AppLogStore.keepBytesOverride.withLock { $0 = 1024 }

                for index in 0..<400 {
                    AppLogStore.append("entry_\(index)_\(String(repeating: "x", count: 40))", channel: .sync)
                }

                let contents = AppLogStore.read()
                // The newest entry always survives.
                #expect(contents.contains("entry_399_"))
                // The oldest is gone — the trim actually ran, so this test is
                // not silently measuring an untrimmed file.
                #expect(!contents.contains("entry_0_"))
                // Every surviving line is a complete physical LINE: the trim
                // advances past the first partial line rather than slicing one in
                // half. The oracle is "parses as SOME channel", not "== SYNC": a
                // partial line has no valid `[ts] [TAG] ` head and returns nil,
                // which is exactly the defect being guarded, while an always-on
                // entry that escaped an earlier test into the redirected file
                // parses fine and must not flake this.
                //
                // ⚠️ LINE, not logical ENTRY — the distinction is real and the
                // stronger claim would be false. `logChatError` deliberately emits
                // a TWO-LINE entry, and a cut that lands inside its first line
                // leaves the `  User message: …` continuation as a LEADING ORPHAN:
                // a complete physical line belonging to no entry. That is a known,
                // accepted consequence of a whole-file tail trim, not a defect —
                // `filter(_:keepingChannel:)` seeds `including = false` so no
                // export shows the orphan, and `clear(channel:)` removes it for
                // whichever channel is cleared (pinned by
                // `clearRemovesLeadingOrphanForAnyChannel`).
                for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                    #expect(AppLogStore.entryTag(of: line) != nil,
                            "trim left a partial line: \(line)")
                }
            }
        }
    }

    @Test("One oversized newline-free entry leaves the log untrimmed instead of ERASING it")
    func oneOversizedEntryNeverEmptiesTheLog() {
        // `trimTail` keeps the last `keepBytes` and then advances past the FIRST
        // newline in that tail so it never leaves half a line behind. When the
        // retained tail's only newline is its own TERMINAL byte — which is what
        // one entry longer than `keepBytes` produces — that leaves NOTHING.
        // BEFORE the empty guard, the atomic rewrite then replaced the whole log
        // with an EMPTY file: every channel's history gone at once, from a
        // routine size trim. The guard makes that write not happen at all, so
        // the log stays ABOVE its cap rather than being trimmed — deliberately,
        // because keeping an untrimmed file is strictly better than deleting it,
        // and the next bounded append lets the following trim succeed. The test
        // name says "untrimmed" for exactly that reason.
        //
        // The INVARIANT: a trim only ever removes the OLDEST entries. It never
        // turns a non-empty log into an empty one, whatever the shape of what
        // was written. Nothing here goes through `logChatError` — this is an
        // ordinary façade that bounds nothing of its own, so the entry arrives
        // at the store carrying only the store's bound. ⚠️ The trigger is driven
        // by the 4 KiB/1 KiB test overrides, NOT reachable at production's
        // 32/16 MiB: `maxEntryScalars` caps one entry near 256 KB, far under the
        // 16 MiB retained tail. This is a defence-in-depth test of the guard,
        // not a reproduction of a live production path.
        withTempLog { url in
            withDebugLogging(true) {
                AppLogStore.maxBytesOverride.withLock { $0 = 4096 }
                AppLogStore.keepBytesOverride.withLock { $0 = 1024 }

                let stamp = String(UUID().uuidString.prefix(8))
                let survivor = Self.marker(for: .sync, stamp)
                AppLogStore.append(survivor, channel: .sync)
                AppLogStore.append(String(repeating: "x", count: 8 * 1024), channel: .inbox)

                let contents = AppLogStore.read()
                #expect(contents != "(no log)", "the trim erased the whole log")
                #expect(contents.contains(survivor),
                        "an unrelated channel's history was erased by one oversized entry")
                // Non-vacuity: the file really did pass `maxBytes`, so a trim was
                // attempted rather than skipped for being under the cap.
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
                #expect((size ?? 0) > 4096,
                        "the log is \(size ?? -1) bytes — it never reached maxBytes")
            }
        }
    }

    @Test("The store bounds an entry from a writer that bounds nothing itself")
    func appendBoundsAnUnboundedWriter() {
        // `logChatError` is the only façade that bounds its own spans. The other
        // fourteen hand `AppLogStore.append` whatever they were given, so the
        // SIZE bound belongs at the STORE boundary, where it covers every writer
        // rather than only the one that bounds itself. ⚠️ This is defence in
        // depth, not a live production path: with the bound in place no façade
        // can reach production's 16 MiB retained tail, since one entry now caps
        // near 256 KB. The bound is what MAKES that true — it is not evidence
        // that an unbounded façade is currently producing oversized entries.
        //
        // Deliberately redundant with `logChatError`'s own cap and with
        // `trimTail`'s refusal to write an empty file: three independent things
        // have to fail before one oversized entry can cost the log.
        withTempLog { _ in
            withDebugLogging(true) {
                let stamp = String(UUID().uuidString.prefix(8))
                let head = "head-\(stamp)"
                let tail = "tail-\(stamp)"
                // `tail` sits past the ceiling, so it can only reach the file if
                // no bound ran at all.
                BackgroundSyncLogger.log(
                    head + String(repeating: "a", count: AppLogStore.maxEntryScalars) + tail)

                let sync = AppLogStore.read(channel: .sync)
                // Non-vacuity: the head survived, so this measures a bound rather
                // than a writer that dropped the entry.
                #expect(sync.contains(head), "the entry was dropped, not bounded")
                #expect(!sync.contains(tail),
                        "the whole unbounded entry was persisted — the store bound is gone")

                guard let line = sync.split(separator: "\n", omittingEmptySubsequences: false)
                        .first(where: { $0.contains(head) }) else {
                    Issue.record("the entry is missing entirely from: \(sync.prefix(200))")
                    return
                }
                // The only part of the physical line the message bound does not
                // cover is the `[<ISO8601>] [<TAG>] ` head the store writes itself.
                let entryHead = "[\(Date().iso8601String())] [\(AppLogChannel.sync.tag)] "
                #expect(line.unicodeScalars.count
                            <= AppLogStore.maxEntryScalars + entryHead.unicodeScalars.count,
                        "persisted entry is \(line.unicodeScalars.count) scalars")

                // ⚠️ The façade above cannot LOCATE the bound: an identical bound
                // living only in `BackgroundSyncLogger.log` would satisfy every
                // assertion so far, while `DeviceSyncLogger`, `AuthDiagnostics`
                // and the other twelve went on persisting unbounded entries.
                // Driving `AppLogStore.append` directly is what distinguishes a
                // STORE-boundary bound from a façade-only one, and `appendRaw` is
                // private, so this is the same door all fifteen writers use.
                let direct = "direct-\(stamp)"
                let directTail = "directtail-\(stamp)"
                AppLogStore.append(
                    direct + String(repeating: "b", count: AppLogStore.maxEntryScalars) + directTail,
                    channel: .push)

                let push = AppLogStore.read(channel: .push)
                #expect(push.contains(direct), "the direct entry was dropped, not bounded")
                #expect(!push.contains(directTail),
                        "the bound is not at the store boundary — it lives in the façade")
            }
        }
    }
}

// MARK: - Source scanning for `gatedWritersGateTheirPrintToo`

extension AppLogStoreTests {

    static func projectFile(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // TabMailTests
            .deletingLastPathComponent()   // repository root
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Scalar offset of `token` in `text`, or `nil`. Scalar-wise, per
    /// `MIS-IOS-013`: a grapheme-level `range(of:)` answers a different question
    /// than "where do these source characters appear".
    static func firstIndex(ofToken token: String, in text: String) -> Int? {
        let haystack = Array(text.unicodeScalars)
        let needle = Array(token.unicodeScalars)
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }

    /// The body of `static func <name>(` in `source` — the text between its
    /// opening brace and the matching close — or `nil` when the function is not
    /// found or its braces do not balance.
    ///
    /// Deliberately simple: `BackgroundSyncLogger` is a flat list of small
    /// static functions whose signatures contain no braces and whose bodies
    /// contain no brace inside a string literal. The caller asserts each
    /// recovered body contains `AppLogStore.append(`, which is what rules out a
    /// mis-parsed range rather than trusting the parser.
    static func functionBody(of name: String, in source: String) -> String? {
        let scalars = Array(source.unicodeScalars)
        guard let signature = firstIndex(ofToken: "static func \(name)(", in: source) else { return nil }
        guard var index = scalars[signature...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var body = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "{" {
                depth += 1
                if depth == 1 { index += 1; continue }
            } else if scalar == "}" {
                depth -= 1
                if depth == 0 { return String(body) }
            }
            body.append(scalar)
            index += 1
        }
        return nil
    }

    /// The console sinks global `CLAUDE.md` rule 12 names. All three, not just
    /// `print`: the rule is "a no-op in production", and `NSLog`/`os_log` reach
    /// the unified log on a shipped device where a bare `print` reaches nobody.
    static let consoleSinkTokens = ["print(", "NSLog(", "os_log("]

    /// The earliest console sink in `body`, as (scalar offset, token), or `nil`.
    static func firstConsoleSink(in body: String) -> (offset: Int, token: String)? {
        consoleSinkTokens
            .compactMap { token in firstIndex(ofToken: token, in: body).map { (offset: $0, token: token) } }
            .min { $0.offset < $1.offset }
    }

    /// Why `body` violates "the debug gate covers the console sink too", or
    /// `nil`.
    ///
    /// ⚠️ This is a LEXICAL scan of one function body, and that is all it is. It
    /// answers "does the text `print(` / `NSLog(` / `os_log(` appear before the
    /// text of the guard, inside this body". It does NOT do dataflow: a body
    /// that calls a helper which prints — `emitPush(message)` above the guard,
    /// with the `print` inside `emitPush` — contains no sink token and is
    /// reported clean. Nothing here rules that out; a reviewer reading a new
    /// logger function does. What the scan does buy is the cheap, common
    /// regression: someone moves an existing `print` above its guard, or adds a
    /// gated writer with no guard at all.
    static func gateViolation(in body: String) -> String? {
        let gate = firstIndex(ofToken: "guard DebugModeManager.isLoggingEnabled()", in: body)
        let sink = firstConsoleSink(in: body)
        guard let gate else { return "no DebugModeManager.isLoggingEnabled() guard" }
        guard let sink else { return nil }
        return sink.offset < gate ? "\(sink.token) appears before the debug gate" : nil
    }

    /// The text after `  User message: ` on the continuation line that follows
    /// the entry whose head contains `entryMarker`, or `nil`.
    ///
    /// Anchored on the CALLER'S OWN entry rather than on the first such line in
    /// the text: `logChatError` is always-on, so a task escaping an earlier test
    /// can land another CHAT entry — with its own `User message:` line — in the
    /// same redirected file.
    static func userMessageSpan(in text: String, after entryMarker: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let head = lines.firstIndex(where: { $0.contains(entryMarker) }),
              head + 1 < lines.count else { return nil }
        let prefix = Array("  User message: ".unicodeScalars)
        let scalars = Array(lines[head + 1].unicodeScalars)
        guard scalars.count >= prefix.count, Array(scalars[0..<prefix.count]) == prefix else {
            return nil
        }
        var span = String.UnicodeScalarView()
        for scalar in scalars[prefix.count...] { span.append(scalar) }
        return String(span)
    }

    /// A description of the first backslash in `span` that does NOT introduce a
    /// complete `\uXXXX` escape, or `nil` when every one of them does.
    ///
    /// This is the oracle for "the cap ran BEFORE the escaper", stated as a
    /// property of the persisted text rather than as the order of two statements.
    /// Scalar-wise, per `MIS-IOS-013`: the question is about scalar positions, and
    /// the span may carry combining marks that a grapheme-level walk would fold
    /// into a neighbour.
    static func truncatedEscape(in span: String) -> String? {
        let scalars = Array(span.unicodeScalars)
        let hexDigits = Set("0123456789abcdefABCDEF".unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\u{5C}" else {
                index += 1
                continue
            }
            guard index + 5 < scalars.count else {
                return "backslash at \(index) with only \(scalars.count - index - 1) scalars after it"
            }
            guard scalars[index + 1] == "u" else {
                return "backslash at \(index) is not followed by `u`"
            }
            for offset in 2...5 where !hexDigits.contains(scalars[index + offset]) {
                return "backslash at \(index) is followed by a non-hex digit"
            }
            index += 6
        }
        return nil
    }
}
