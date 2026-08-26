/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Diagnostic log writers for the main app's background and queue subsystems.
///
/// Every function here writes to the ONE app log file — see `AppLogStore`, which
/// owns the file, the serial I/O queue, the byte cap and the readers. This type
/// is now only the set of named entry points and, more importantly, the record of
/// **which channels are debug-gated and which are always-on**.
///
/// That split is a registered decision (`IOS-LOG-002`), not an accident:
/// `log`, `logError` and `logChatError` persist in production because a failure
/// that only reproduces in the field has to leave a trace, while every channel
/// added for investigation is a no-op unless debug mode is unlocked by an allowed
/// user (global `CLAUDE.md` rule 12). Consolidating the files changed neither set.
///
/// MOST writers also `print` for immediate Xcode-console visibility, on the
/// caller's thread; `logBackfill` and `logBoot` deliberately do NOT, because
/// their callers already echo to the console themselves. Every writer that DOES
/// have a console sink and is debug-gated gates the `print` too — a debug-gated
/// channel must be a no-op in production on BOTH channels, not just on disk.
enum BackgroundSyncLogger {

    // MARK: - Background sync (always-on)

    /// Append a background sync event (BGAppRefreshTask, BGProcessingTask, silent push).
    static func log(_ message: String) {
        print("[BGSyncLog] \(message)")
        AppLogStore.append(message, channel: .sync)
    }

    // MARK: - Errors (always-on)

    /// Log an error with source context. Captures sync errors, NIO errors, API errors, etc.
    static func logError(_ message: String, source: String) {
        print("[ErrorLog:\(source)] \(message)")
        AppLogStore.append("[\(source)] \(message)", channel: .error)
    }

    // MARK: - Chat errors (always-on)

    /// Log a chat/AI error with context. Captures tool failures, empty responses, connection errors.
    ///
    /// **BOTH spans this writes are outside our control, and both are bounded and
    /// escaped here — in the façade — rather than at each call site:**
    ///
    /// * `userMessage` is literal user-typed chat input (`AIChat` passes
    ///   `userText` straight through); and
    /// * `message` carries REMOTE text at most production call sites. `AIChat`
    ///   interpolates the backend's own `response.error` string
    ///   (`"Server error: \(error)"`, `"Server error (resume): \(error)"`) and
    ///   `DynamicIslandChatButton` interpolates `error.localizedDescription`
    ///   (`"Chat error: …"`, `"Connection lost (resumable): …"`,
    ///   `"Resume failed: …"`). Stated with its negative case, because "every"
    ///   was wrong and a reader would have checked it: `BackendClient`'s
    ///   `"SSE stream ended without final event …"` interpolates nothing at all.
    ///   That one is safe TODAY by accident of its argument, not by contract —
    ///   which is exactly why the bound-and-escape lives HERE and not at the
    ///   call sites that happen to need it.
    ///
    /// The app log is now a LINE-ORIENTED sink shared by every channel, so an
    /// unescaped newline in EITHER span is a forgery rather than a formatting
    /// nit: a value carrying `"\n[x] [AUTH] …"` produces a second PHYSICAL line
    /// that `AppLogStore.entryTag` parses as a genuine AUTH entry — it surfaces
    /// in `read(channel: .auth)`, it truncates the real entry in
    /// `read(channel: .chatError)`, and `clear(channel: .chatError)` leaves the
    /// forged remainder behind. Before consolidation that forgery was confined to
    /// `chat_error.log` and harmless; the shared file is what makes it
    /// cross-channel. Escaping only `userMessage` closed one of the two doors.
    ///
    /// The `\n  User message: ` separator BETWEEN the two spans is deliberate and
    /// stays a literal: `AppLogStore.read(channel:)` attributes a continuation
    /// line upward to this entry, so escaping the newline we write ourselves
    /// would destroy the two-line shape the reader needs. Escape the spans, never
    /// the separator you write yourself.
    static func logChatError(_ message: String, userMessage: String? = nil) {
        // ⚠️ BOUND BEFORE ESCAPE, AND BOUND BY UNICODE SCALAR — both halves matter.
        //
        // Escaping collapses a multi-line span into ONE physical line, which is
        // the point, and it also removes the newlines `AppLogStore.trimTail`
        // depends on. `trimTail` keeps the last `keepBytes` and then advances past
        // the first newline in that tail, so an entry whose only newline is its
        // own terminal one leaves NOTHING to retain. That outcome is now owned by
        // the STORE, not by this façade: `AppLogStore.append` bounds every channel
        // at `maxEntryScalars`, and `trimTail` refuses to write an empty file, so
        // such a trim is abandoned and the log is left untrimmed rather than
        // erased. Bounding each span here is the tightest of the three guards,
        // not the only one standing between this writer and a whole-file erase.
        //
        // The ceiling is over `unicodeScalars`, not `Characters`. `prefix(100)`
        // counts extended grapheme CLUSTERS, and a single cluster can carry an
        // unbounded run of combining marks, so one pasted grapheme passes a
        // Character cap intact (`MIS-IOS-013` — a SIZE question asked with a
        // grapheme-level `String` API). Slicing SCALARS cannot split a UTF-8
        // sequence, and it runs BEFORE escaping so it can never slice a generated
        // `\uXXXX` in half.
        //
        // 4000 scalars is a ceiling, not a budget: every call site writes a short
        // developer line plus one error string, so ordinary text never reaches it,
        // while the escaped worst case (six characters per escaped scalar) still
        // stays three orders of magnitude below `AppLogStore.keepBytes`.
        var entry = DebugModeManager.escapedForLogLine(
            String(String.UnicodeScalarView(message.unicodeScalars.prefix(4000))))
        if let userMessage {
            // ORDER: cap FIRST, escape SECOND. `prefix(100)` carries the INTENT —
            // roughly a hundred characters of the user's own text is what the log
            // needs — and escaping afterwards can only expand what survived (one
            // control scalar becomes six characters, `\u000a`), so the
            // cap can never slice an escape sequence in half. Escaping first would
            // also let a message of 100 newlines spend the whole budget on escape
            // sequences and preserve ~16 characters of actual evidence.
            //
            // The scalar cap after it is the HARD ceiling that a single grapheme
            // cannot defeat, for the reason spelled out above: `prefix(100)` alone
            // bounds neither scalars nor bytes.
            let capped = String(userMessage.prefix(100))
            let bounded = String(String.UnicodeScalarView(capped.unicodeScalars.prefix(400)))
            entry += "\n  User message: \(DebugModeManager.escapedForLogLine(bounded))"
        }
        print("[ChatErrorLog] \(message)")
        AppLogStore.append(entry, channel: .chatError)
    }

    // MARK: - BG App Refresh (debug-gated)

    /// Log a BGAppRefreshTask lifecycle event (schedule, start, expire, complete, silent push).
    static func logBGAppRefresh(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        print("[BGAppRefreshLog] \(message)")
        AppLogStore.append(message, channel: .bgAppRefresh)
    }

    // MARK: - BG Processing (debug-gated)

    /// Log a BGProcessingTask lifecycle event (schedule, start, phase progress, expire, complete).
    static func logBGProcessing(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        print("[BGProcessingLog] \(message)")
        AppLogStore.append(message, channel: .bgProcessing)
    }

    // MARK: - AI Processing (debug-gated)

    /// Log an AI processing queue event (enqueue, dispatch, dequeue, complete, retry, context).
    static func logAIProcessing(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        print("[AIProcessingLog] \(message)")
        AppLogStore.append(message, channel: .aiProcessing)
    }

    // MARK: - Push notifications (debug-gated)

    /// Log a push notification event (registration, subscription, silent push processing).
    static func logPush(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        print("[PushLog] \(message)")
        AppLogStore.append(message, channel: .push)
    }

    // MARK: - Backfill AI refinement (debug-gated)

    /// Log a BackfillAIQueue event (enqueue, claim, success, skip, retry, drop, repopulate).
    static func logBackfillAI(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        print("[BackfillAILog] \(message)")
        AppLogStore.append(message, channel: .backfillAI)
    }

    // MARK: - Backfill header walk + body queue (debug-gated)

    /// Log a backfill lifecycle event (worker start/exit, cycle start, pause reason,
    /// folder complete, connection backoff, body-queue batch/miss/confirm-gone outcomes).
    /// Deliberately does NOT `print` — the header/body backfill already echoes to the
    /// console elsewhere, and this is the file channel that makes an exported log
    /// useful for diagnosing stalls.
    static func logBackfill(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        AppLogStore.append(message, channel: .backfill)
    }

    // MARK: - Inbox view model (debug-gated)

    /// Log an InboxViewModel lifecycle or reload event.
    /// Covers: folder-set transitions, observer registration, reload counts, partial-set heals,
    /// ValueObservation emissions.
    static func logInbox(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        print("[InboxLog] \(message)")
        AppLogStore.append(message, channel: .inbox)
    }

    // MARK: - Boot profile (debug-gated)

    /// Append a `BootProfiler` timeline line. Gated on DebugModeManager so it
    /// captures on-device / TestFlight, where no Xcode console is attached and
    /// BootProfiler's `print` goes nowhere observable — this file channel is the
    /// only way to read a cold-launch timeline there. Called from
    /// `BootProfiler.mark`; does not print (BootProfiler handles the console echo).
    static func logBoot(_ line: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        AppLogStore.append(line, channel: .boot)
    }

    // MARK: - Body render / HTML double-escape (debug-gated)

    /// Append a body-render diagnostic line for the rare "HTML body shows literal
    /// `&amp;` / `&nbsp;` / visible tags" bug. The symptom is
    /// `EmailFilter.plainTextToHTML` escaping content that was ALREADY HTML. The
    /// clean fix makes `BodyRenderer` the single conversion authority, so the
    /// storage factory no longer re-converts — but we keep this channel to catch
    /// any double-escaped body that still reaches storage (e.g. a sender that put
    /// HTML in a text/plain part with no html alternative), via `diagnoseStoredBody`.
    /// Prefer `diagnoseStoredBody` at call sites — it gates on the dangerous
    /// condition before formatting.
    static func logBodyRender(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        print("[BodyRenderLog] \(message)")
        AppLogStore.append(message, channel: .bodyRender)
    }

    // MARK: - Stuck message diagnostics (debug-gated)

    /// Append a line from `StuckMessageDiagnostics` — the read-only scan for
    /// "searchable but can't open / no snippet / not in its folder" rows. Only
    /// written by the Debug-menu scan.
    static func logStuckDiag(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        print("[StuckDiag] \(message)")
        AppLogStore.append(message, channel: .stuckDiag)
    }

    // MARK: - Body double-escape detector (pure / ungated — unit-testable)

    /// True when `html` is ALREADY double-escaped — it contains `&amp;amp;`,
    /// `&amp;lt;`, `&amp;nbsp;`, etc. These sequences essentially never occur in
    /// legitimate HTML, so a hit means a `plainTextToHTML`/`escapeHTML` pass ran over
    /// content that was already HTML — the exact "literal `&amp;`/`&nbsp;`/visible
    /// tags" symptom.
    static func htmlLooksDoubleEscaped(_ html: String) -> Bool {
        return html.contains("&amp;amp;") || html.contains("&amp;lt;")
            || html.contains("&amp;gt;") || html.contains("&amp;nbsp;")
            || html.contains("&amp;quot;") || html.contains("&amp;#")
    }

    /// Inspect a body about to be STORED and log to the body-render channel only if
    /// it is already double-escaped. Path-agnostic — catches the bug no matter which
    /// route produced the body. Debug-mode-gated; a no-op (allocates nothing) in
    /// production / when locked.
    static func diagnoseStoredBody(source: String, headerId: String, htmlContent: String?) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        guard let html = htmlContent, htmlLooksDoubleEscaped(html) else { return }
        logBodyRender(
            "⚠️ DOUBLE-ESCAPE in stored body [\(source)] headerId=\(headerId.prefix(48)) "
            + "htmlLen=\(html.count) htmlHead=\(String(html.prefix(200)).debugDescription)"
        )
    }
}
