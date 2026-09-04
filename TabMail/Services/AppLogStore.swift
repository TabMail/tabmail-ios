/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization

/// The main app's SINGLE persistent diagnostic log file (`tabmail.log`) in
/// Application Support, and the counterpart to `NSELogStore`'s single `nse.log`
/// in the App Group container. Two processes, two files, and no more than that.
///
/// Before this existed the main app wrote **fifteen** separate files
/// (`background_sync.log`, `error.log`, `chat_error.log`, `bg_app_refresh.log`,
/// `bg_processing.log`, `ai_processing.log`, `push.log`, `backfill_ai.log`,
/// `backfill.log`, `inbox.log`, `boot.log`, `body_render.log`,
/// `stuck_messages.log`, `device_sync.log`, `auth_diagnostics.log`), each with
/// its own retention policy and its own reader. ⚠️ NOT "each with its own BYTE
/// cap" — thirteen were byte-capped, `device_sync.log` used a 300-LINE ring and
/// `auth_diagnostics.log` a 50-ENTRY ring — and NOT "each with its own share
/// button": `auth_diagnostics.log` had none, which is precisely why its entries
/// were unreachable rather than unreadable. Diagnosing anything that crossed two
/// subsystems — a stalled backfill that shows up as an inbox reload storm, a
/// push that arrives while a BG refresh is running — meant exporting several
/// files and re-interleaving them by hand from their timestamps. One file
/// interleaved in append order is the whole point. Those fifteen files are
/// unlinked once, on the first launch after upgrade, by
/// `StartupMigrations.deleteLegacyLogFiles(in:)` — stranded, they would still
/// count toward `StorageEstimator`'s budget and could buy their size in pruned
/// mail. CONDITIONALLY: `isOverBudget()` is
/// `budgetMB != Int.max && totalSizeMB() >= budgetMB` and `defaultBudgetMB` is
/// `Int.max`, so that consequence exists only for a user who has configured a
/// finite budget. Stating it categorically is wrong.
///
/// Each entry is `[<ISO8601>] [<TAG>] <message>`, where `<TAG>` is an
/// `AppLogChannel`. The tag is what replaces the old per-file separation:
/// `read(channel:)` filters back to a single subsystem when that is what you
/// want, and `read()` gives you everything in order when it is not.
///
/// **This type does NOT gate.** Whether a channel writes in production is the
/// caller's decision and is unchanged by consolidation: `BackgroundSyncLogger`,
/// `DeviceSyncLogger` and `AuthDiagnostics` keep the exact
/// `DebugModeManager.isLoggingEnabled()` guards they had per channel, so the
/// always-on set (sync, error, chat error, device sync, auth) and the
/// debug-gated set are the same sets as before. That split is a deliberate,
/// registered decision (`IOS-LOG-002`) — a consolidation must not quietly widen
/// either side of it.
///
/// ⚠️ Line-forgery caveat, inherited and NOT introduced here: a message that
/// itself contains a newline produces additional physical lines. Continuation
/// lines are attributed to the entry above them (see `read(channel:)`), which is
/// what `BackgroundSyncLogger.logChatError`'s deliberate two-line entry needs.
/// Sender-authored values interpolated into a log line must still be passed
/// through `DebugModeManager.escapedForLogLine`; that is the pre-existing rule
/// and this file neither strengthens nor weakens it.
///
/// TWO channels do NOT leave that to their call sites. `logChatError` bounds and
/// escapes BOTH of its spans inside the façade — the literal user-typed
/// `userMessage`, AND the `message` line, which carries the backend's own error
/// string at most of its production call sites — because that writer is always-on:
/// unescaped, a newline followed by `[x] [AUTH] …` in EITHER span forges an entry
/// on ANOTHER channel in this shared file. `logQueue` escapes its FULLY RENDERED
/// line for the same reason with a different trigger: its lines interpolate IMAP
/// mailbox paths, folder names and provider error descriptions, all
/// server/user-authored, at dozens of sites that would each have to remember. The
/// other fourteen channels' interpolations remain a call-site duty.
///
/// SIZE, unlike escaping, is bounded HERE for every channel: `append` truncates
/// at `maxEntryScalars`, so no façade can hand the file an entry longer than a
/// trim's retained tail. `logChatError`'s own caps stay where they are and are
/// deliberately redundant with it.
enum AppLogStore {
    /// Filename in Application Support / TabMail.
    private static let fileName = "tabmail.log"

    /// Hard cap on log file size before tail-trim kicks in.
    ///
    /// Doubled from the 16 MB the per-subsystem `background_sync.log` used,
    /// because that cap now has to hold SIXTEEN channels instead of one (FIFTEEN
    /// at consolidation; `.queue` was added for `IOS-QUEUE-008`). The
    /// trim is a whole-file tail-trim with no per-channel reservation, so a
    /// chatty channel can evict a quiet one's history — accepted deliberately
    /// (owner, 2026-08-25: "just diagnostics, don't overcomplicate"). Raising
    /// the ceiling is the mitigation; per-channel floors or quotas are NOT.
    /// Still far below the old worst case of fifteen independently-capped files.
    static let maxBytes = 32 * 1024 * 1024
    /// Bytes to retain after a tail-trim. Trim happens at most once per
    /// (maxBytes - keepBytes) of growth, so the 2:1 ratio is what bounds how
    /// often the (whole-file, atomic) rewrite runs — keep it when changing
    /// either constant.
    static let keepBytes = 16 * 1024 * 1024

    /// Hard ceiling on how many unicode scalars ONE entry's message may
    /// contribute, applied at the STORE boundary so it covers all sixteen
    /// façades (fifteen at consolidation, plus `logQueue`) rather than only the
    /// one that bounds its own spans.
    ///
    /// This is a SIZE bound and only a size bound.
    /// `BackgroundSyncLogger.logChatError` keeps its own, far tighter
    /// `prefix(100)` on `userMessage`; that one is a PRIVACY bound — it decides
    /// how much of what the user actually typed is persisted — and neither
    /// substitutes for the other.
    ///
    /// Deliberately redundant with both that bound and with `trimTail`'s refusal
    /// to write an empty file: three independent things have to fail before one
    /// oversized entry can cost the log. Scalars, never `Character`s —
    /// `prefix(n)` counts extended grapheme clusters and one cluster can carry an
    /// unbounded run of combining marks (`MIS-IOS-013`), so a grapheme-level cap
    /// bounds neither scalars nor bytes.
    ///
    /// 64 Ki scalars is a ceiling, not a budget: the longest line any channel
    /// writes is one of `StuckMessageDiagnostics`' per-folder histograms, and
    /// even at four UTF-8 bytes per scalar the worst case is 256 KB — 1/64th of
    /// `keepBytes`, so a bounded entry can never be the tail a trim retains.
    static let maxEntryScalars = 64 * 1024

    /// Shared serial queue for ALL persistent log file I/O.
    ///
    /// Appends are O(entry size) (`FileHandle.seekToEnd` + write), but disk I/O
    /// on MainActor during rapid SwiftUI renders (e.g. `InboxViewModel.init`
    /// during fast nav) can still produce visible stalls, and Device Sync's
    /// WebSocket handlers log from the main thread. Serializing on a background
    /// `utility`-QoS queue keeps log I/O off MainActor. Timestamps are captured
    /// at call time. ⚠️ On-disk ordering is APPEND ORDER — the order work reached
    /// `ioQueue` — NOT call order: a caller preempted between stamping and
    /// enqueueing lands after one that stamped later, so timestamps can even read
    /// as decreasing. Line order is the oracle, not the timestamp. This holds
    /// though writes are async. `print()` stays on the caller's thread for
    /// immediate Xcode-console visibility.
    ///
    /// One queue for one file is now load-bearing rather than merely tidy:
    /// `DeviceSyncLogger` and `AuthDiagnostics` used to own their own file, and
    /// `AuthDiagnostics` wrote synchronously on the caller's thread (including
    /// from `TabMailApp.init` on MainActor). Sharing a file without sharing a
    /// serial queue would interleave partial writes.
    private static let ioQueue = DispatchQueue(label: "tabmail.logger.io", qos: .utility)

    // MARK: - Test seams
    //
    // `nil` = use the real Application Support container / real byte caps,
    // which is exactly what production starts with. Mirrors `NSELogStore`'s
    // seams so both log stores are overridden the same way.

    /// Test-only override for the log file location.
    static let fileURLOverride = Mutex<URL?>(nil)
    /// Test-only override for `maxBytes` — lets trim tests use small caps
    /// instead of writing multi-megabyte payloads.
    static let maxBytesOverride = Mutex<Int?>(nil)
    /// Test-only override for `keepBytes`.
    static let keepBytesOverride = Mutex<Int?>(nil)

    private static var effectiveMaxBytes: Int { maxBytesOverride.withLock { $0 } ?? maxBytes }
    private static var effectiveKeepBytes: Int { keepBytesOverride.withLock { $0 } ?? keepBytes }

    static var fileURL: URL {
        if let override = fileURLOverride.withLock({ $0 }) { return override }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    // MARK: - Write

    /// Append one timestamped, channel-tagged entry. Never gates — the caller
    /// owns the `DebugModeManager.isLoggingEnabled()` decision for its channel.
    ///
    /// `message` may span multiple lines; only the first carries the tag, and
    /// `read(channel:)` attributes the rest to it.
    static func append(_ message: String, channel: AppLogChannel) {
        // SIZE bound, applied to EVERY channel — see `maxEntryScalars`. The
        // PRIVACY bound on the one span of literal user text lives in
        // `BackgroundSyncLogger.logChatError` and is a different, tighter thing.
        let bounded = String(String.UnicodeScalarView(message.unicodeScalars.prefix(maxEntryScalars)))
        let entry = "[\(Date().iso8601String())] [\(channel.tag)] \(bounded)\n"
        appendRaw(entry)
    }

    /// Shared write helper — appends via `FileHandle.seekToEnd`, repairs a torn
    /// tail first, periodic byte-cap trim, all on `ioQueue`.
    ///
    /// Opened `forUpdating` (`O_RDWR`) rather than `forWritingTo` (`O_WRONLY`)
    /// for one reason: the torn-tail repair below has to READ the file's last
    /// byte, and a write-only handle cannot.
    private static func appendRaw(_ entry: String) {
        let url = fileURL
        ioQueue.async {
            guard let data = entry.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                try? Data().write(to: url)
            }
            if let handle = try? FileHandle(forUpdating: url) {
                do {
                    let size = try handle.seekToEnd()
                    // TORN-TAIL REPAIR. Every entry ends with `\n`, so a file that
                    // does not is a file whose last write was cut short — the
                    // process died between `write` starting and the bytes landing.
                    // Without this, the next entry is concatenated onto that
                    // partial line: two entries become one physical line that
                    // `entryTag` reads as the FIRST one's channel, so the second is
                    // misattributed, cannot be filtered back out, and
                    // `clear(channel:)` on the first channel deletes the survivor
                    // along with it.
                    //
                    // This is NEW exposure, not a pre-existing bug being papered
                    // over. At v1.7.14 `AuthDiagnostics` and `DeviceSyncLogger`
                    // rewrote their whole file with `write(to:atomically:true)` —
                    // an atomic replace can never leave a partial line — and every
                    // other channel appended to a file only IT wrote. Now all
                    // sixteen append in place to one shared file, so one channel's
                    // torn write corrupts the NEXT channel's entry.
                    //
                    // One extra 1-byte read per append is the whole cost.
                    if size > 0 {
                        try handle.seek(toOffset: size - 1)
                        let lastByte = try handle.read(upToCount: 1)
                        try handle.seekToEnd()
                        if lastByte != Data([0x0A]) {
                            try handle.write(contentsOf: Data([0x0A]))
                        }
                    }
                    try handle.write(contentsOf: data)
                } catch {
                    // Drop on write error; next append will retry.
                }
                try? handle.close()
            }
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size > effectiveMaxBytes {
                trimTail(url: url)
            }
        }
    }

    /// Atomically replace `url` with its last `effectiveKeepBytes`, advanced past
    /// the first partial line so we never retain a PARTIAL PHYSICAL LINE. Note
    /// the unit: a physical line, not a logical entry. `logChatError` writes a
    /// deliberate two-line entry, and a cut inside its tagged head leaves the
    /// `User message:` continuation as a leading orphan. Caller must run this
    /// on `ioQueue`.
    private static func trimTail(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > UInt64(effectiveKeepBytes) else { return }
        let offset = size - UInt64(effectiveKeepBytes)
        do { try handle.seek(toOffset: offset) } catch { return }
        guard var data = try? handle.readToEnd() else { return }
        if let newline = data.firstIndex(of: 0x0A) {
            data = data.subdata(in: (newline + 1)..<data.count)
        }
        // NEVER replace a non-empty log with an empty file. When the retained
        // tail's only newline is its own TERMINAL byte — what one entry longer
        // than `keepBytes` produces — the line above leaves NOTHING, and this
        // write would erase every channel's history at once from a routine size
        // trim. Unconditional, and deliberately incurious about WHY the tail came
        // out empty: keeping the untrimmed file is strictly better than deleting
        // it, and it self-corrects, because the next append puts a newline inside
        // the tail and the trim after that one succeeds.
        guard !data.isEmpty else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Read

    /// The whole log file, decoded LOSSILY, or `nil` when the bytes could not be
    /// read at all. ⚠️ `nil` is NOT reserved for the missing-file case — an
    /// earlier wording said it was. `try? Data(contentsOf:)` yields `nil` for ANY
    /// read failure (permissions, a vanished directory, an I/O error), and the
    /// callers' placeholder is therefore "no readable log", not "no log was ever
    /// written". The two are indistinguishable here by construction.
    ///
    /// Lossy is the correct decode here, and the throwing one was a wildly
    /// disproportionate failure. Every channel now appends in place to one shared
    /// file, so a process death mid-`write` can split a multibyte UTF-8 scalar
    /// across the tail. `String(contentsOf:encoding:)` throws on that ONE bad
    /// byte — which made `read()` report "(no log)" for the ENTIRE file and turned
    /// `clear(channel:)` into a silent no-op, so a single torn byte destroyed the
    /// whole diagnostic artifact and simultaneously made it unclearable.
    /// `String(decoding:as:)` substitutes U+FFFD for the invalid sequence and
    /// every other entry stays readable, filterable and clearable. A subsequent
    /// `clear(channel:)` rewrites the file with the replacement character in place
    /// of the torn bytes: that scalar was unrecoverable either way, and losing it
    /// is strictly better than losing the file.
    ///
    /// Every caller runs this ON `ioQueue`, never after it. A bare drain-and-
    /// return barrier only proves the appends queued BEFORE it have landed: an
    /// append queued after it runs concurrently with the decode, and
    /// `Data(contentsOf:)` then reads a file that a `FileHandle.write` is part
    /// way through. Reading INSIDE the queue is what makes the snapshot whole,
    /// and it is why there is no separate flush helper — the `sync` that
    /// serialises the read has already drained everything queued ahead of it.
    private static func decodedFileText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The whole log, every channel, in append order. This is what the Debug
    /// menu's single "App Logs" share button exports.
    static func read() -> String {
        guard let text = ioQueue.sync(execute: { decodedFileText(at: fileURL) }),
              !text.isEmpty else {
            return "(no log)"
        }
        return text
    }

    /// Only the entries written on `channel`, in append order.
    ///
    /// A physical line that does not begin a new entry (no `[timestamp] [TAG] `
    /// prefix) is a continuation of the entry above it and is kept or dropped
    /// with that entry — `BackgroundSyncLogger.logChatError` deliberately emits a
    /// second `  User message: …` line, and splitting it off would attribute it
    /// to nothing.
    static func read(channel: AppLogChannel) -> String {
        guard let text = ioQueue.sync(execute: { decodedFileText(at: fileURL) }),
              !text.isEmpty else {
            return channel.emptyPlaceholder
        }
        let kept = filter(text, keepingChannel: channel)
        return kept.isEmpty ? channel.emptyPlaceholder : kept
    }

    /// Pure line filter behind `read(channel:)` — separated so it is testable
    /// without touching the filesystem.
    static func filter(_ text: String, keepingChannel channel: AppLogChannel) -> String {
        var kept: [Substring] = []
        var including = false
        for line in bodyLines(of: text) {
            if let tag = entryTag(of: line) {
                including = (tag == channel.tag)
            }
            if including { kept.append(line) }
        }
        return rejoin(kept)
    }

    /// Split into lines with the file's single trailing newline removed, so the
    /// empty tail element `split` would otherwise produce is not mistaken for a
    /// continuation line.
    ///
    /// That mistake is not cosmetic. The tail element carries no `[ts] [TAG] `
    /// prefix, so `entryTag` reports `nil` and the line is attributed to the
    /// entry above it. When that entry is the one being DROPPED, the newline
    /// goes with it, `clear(channel:)` writes a file with no trailing newline,
    /// and the next `append` lands on the same physical line — merging two
    /// entries into one that no longer parses. Pinned by "Appending after
    /// clear(channel:) starts a new line".
    private static func bodyLines(of text: String) -> [Substring] {
        var body = Substring(text)
        if body.last == "\n" { body = body.dropLast() }
        return body.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Rejoin lines into a file body that ends with exactly one newline, or is
    /// empty. The inverse of `bodyLines`.
    private static func rejoin(_ lines: [Substring]) -> String {
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Every tag `entryTag` will accept. Derived from `AppLogChannel.allCases`
    /// so a new channel is admitted by adding the case and nothing else, and so
    /// arbitrary bracketed text can never be mistaken for a channel.
    static let knownTags: Set<String> = Set(AppLogChannel.allCases.map(\.tag))

    /// The channel tag of a line that STARTS an entry, or `nil` for a
    /// continuation line. Parsed over `unicodeScalars` rather than with
    /// `hasPrefix`/`split`, per `MIS-IOS-013` — the delimiters are ASCII but the
    /// timestamp and message around them need not be.
    ///
    /// Two checks beyond "there is a second bracketed field", because
    /// `read(channel:)` and `clear(channel:)` both key off this and a line that
    /// merely LOOKS like an entry start would be attributed to — or cleared
    /// from — the wrong channel:
    ///
    /// * the tag's closing `]` must be followed by a space or end the line, so
    ///   `[…] [SYNC]forged` is a continuation line rather than a SYNC entry; and
    /// * the tag must be a real `AppLogChannel` tag, so `[…] [junk] …` is a
    ///   continuation line rather than an entry on a channel that cannot be
    ///   read back or cleared.
    ///
    /// Both failures return `nil` — i.e. the line is treated as a continuation
    /// of the entry above it, exactly as an unparseable line always was. The
    /// timestamp field is deliberately NOT validated: this runs once per
    /// physical line of a file capped at `maxBytes`, and date parsing per line
    /// is not a cost a debug reader should pay.
    static func entryTag(of line: Substring) -> String? {
        let scalars = Array(line.unicodeScalars)
        guard scalars.first == "[" else { return nil }
        guard let timestampEnd = scalars.firstIndex(of: "]") else { return nil }
        var index = timestampEnd + 1
        guard index < scalars.count, scalars[index] == " " else { return nil }
        index += 1
        guard index < scalars.count, scalars[index] == "[" else { return nil }
        index += 1
        var tag = String.UnicodeScalarView()
        while index < scalars.count, scalars[index] != "]" {
            tag.append(scalars[index])
            index += 1
        }
        guard index < scalars.count else { return nil }
        // Past the tag's closing `]`: a real entry has `] ` (the separator
        // `append` writes) or nothing at all (an entry whose message is empty
        // still ends with that space, so end-of-line only happens for a
        // hand-written line — accepted, it is unambiguous).
        index += 1
        guard index == scalars.count || scalars[index] == " " else { return nil }
        let parsed = String(tag)
        guard knownTags.contains(parsed) else { return nil }
        return parsed
    }

    // MARK: - Clear

    /// Clear the entire log — every channel. The Debug menu's "Clear All Logs".
    static func clear() {
        ioQueue.sync {
            try? Data().write(to: fileURL, options: .atomic)
        }
    }

    /// Drop just one channel's entries, preserving every other channel.
    ///
    /// `StuckMessageDiagnostics.run` clears its own channel before each scan so
    /// the shared report is that run's output rather than an accumulation. With
    /// one file, clearing the file to achieve that would destroy every other
    /// subsystem's history along with it.
    ///
    /// A LEADING orphan — a continuation line with no entry above it, which a
    /// tail-trim leaves behind whenever it cuts between a multi-line entry's
    /// first and second lines (`logChatError`'s `  User message: …`) — belongs
    /// to no channel and is dropped whichever channel is being cleared. That
    /// matches `filter(_:keepingChannel:)`, which seeds `including = false` and
    /// so already drops it on every filtered read. Seeding `dropping = false`
    /// here instead made the orphan unreadable but unclearable: no channel's
    /// export showed it, and no channel's clear removed it, so a fragment of
    /// user text could survive every clear the UI offers short of "Clear All".
    static func clear(channel: AppLogChannel) {
        ioQueue.sync {
            let url = fileURL
            guard let text = decodedFileText(at: url), !text.isEmpty else { return }
            var kept: [Substring] = []
            var dropping = true
            for line in bodyLines(of: text) {
                if let tag = entryTag(of: line) {
                    dropping = (tag == channel.tag)
                }
                if !dropping { kept.append(line) }
            }
            try? Data(rejoin(kept).utf8).write(to: url, options: .atomic)
        }
    }

    /// Test-only: reset every override to its default. It does NOT empty the
    /// log — each caller owns the temp file it pointed the store at and deletes
    /// it. The overrides are process-lifetime state, so without this a test
    /// sharing the test-host process would leak a prior test's temp file URL or
    /// byte cap into the next one.
    static func _resetForTesting() {
        fileURLOverride.withLock { $0 = nil }
        maxBytesOverride.withLock { $0 = nil }
        keepBytesOverride.withLock { $0 = nil }
    }
}

/// The subsystem an `AppLogStore` entry came from. One case per file that the
/// main app used to write separately; the raw tag is what makes a single file
/// separable again.
enum AppLogChannel: String, CaseIterable, Sendable {
    /// Background sync events (BGAppRefreshTask, BGProcessingTask, silent push).
    case sync
    /// Errors with source context — sync, NIO, API. Always-on (`IOS-LOG-002`).
    case error
    /// Chat / AI errors: tool failures, empty responses, connection errors.
    case chatError
    /// Device Sync connection, probes and responses.
    case deviceSync
    /// Auth events, retained so they survive an unexpected logout.
    case auth
    /// `BGAppRefreshTask` lifecycle.
    case bgAppRefresh
    /// `BGProcessingTask` lifecycle.
    case bgProcessing
    /// AI processing queue: enqueue, dispatch, dequeue, complete, retry.
    case aiProcessing
    /// Push registration, subscription and silent-push processing.
    case push
    /// `BackfillAIQueue`: enqueue, claim, success, skip, retry, drop, repopulate.
    case backfillAI
    /// Backfill header walk and body queue.
    case backfill
    /// `InboxViewModel` lifecycle and reloads.
    case inbox
    /// `BootProfiler` cold-launch timeline.
    case boot
    /// Body-render / HTML double-escape diagnostics.
    case bodyRender
    /// `StuckMessageDiagnostics` scan output.
    case stuckDiag
    /// Action-queue drain and the sync-side move-convergence traces that must
    /// interleave with it (`IOS-QUEUE-008`).
    ///
    /// ONE channel for both halves on purpose. The question a reappearing
    /// message poses — "which drain lane ran which op, in what order, and which
    /// sync arm re-inserted the row" — can only be answered by reading the
    /// drain's lane lines and the sync's `[MoveTrace]` verdicts INTERLEAVED, and
    /// `AppLogStore`'s single file preserves exactly that append ordering while
    /// `read(channel: .queue)` filters the pair away from the always-on `.sync`
    /// traffic that would otherwise bury them. Debug-gated: written by
    /// `BackgroundSyncLogger.logQueue` only.
    case queue

    /// The literal written between brackets on every entry. Stable — a reader
    /// looking at an exported log from an older build matches on these, so
    /// renaming one silently orphans that build's history.
    var tag: String {
        switch self {
        case .sync: return "SYNC"
        case .error: return "ERROR"
        case .chatError: return "CHAT"
        case .deviceSync: return "DEVICESYNC"
        case .auth: return "AUTH"
        case .bgAppRefresh: return "BGREFRESH"
        case .bgProcessing: return "BGPROC"
        case .aiProcessing: return "AI"
        case .push: return "PUSH"
        case .backfillAI: return "BACKFILL-AI"
        case .backfill: return "BACKFILL"
        case .inbox: return "INBOX"
        case .boot: return "BOOT"
        case .bodyRender: return "RENDER"
        case .stuckDiag: return "STUCK"
        case .queue: return "QUEUE"
        }
    }

    /// Shown by `AppLogStore.read(channel:)` when this channel has no entries.
    var emptyPlaceholder: String {
        switch self {
        case .stuckDiag:
            return "(no stuck-message diagnostics — run the scan from the Debug menu)"
        default:
            return "(no \(tag) log)"
        }
    }
}
