/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Persistent diagnostic log for background sync events (BGAppRefreshTask, BGProcessingTask, silent push).
/// Modeled after `AuthDiagnostics` — writes timestamped entries to a file in Application Support
/// so they survive app restarts and can be viewed in the Debug menu.
enum BackgroundSyncLogger {
    /// Hard cap on log file size before tail-trim kicks in.
    private static let maxBytes = 16 * 1024 * 1024
    /// Bytes to retain after a tail-trim. Trim happens at most once per (maxBytes - keepBytes) of growth.
    private static let keepBytes = 8 * 1024 * 1024
    private static let fileName = "background_sync.log"

    /// Shared serial queue for ALL persistent log file I/O.
    ///
    /// Even though appends are now O(entry size) (`FileHandle.seekToEnd` + write),
    /// disk I/O on MainActor during rapid SwiftUI renders (e.g. `InboxViewModel.init`
    /// during fast nav) can still produce visible stalls. Serializing on a background
    /// `utility`-QoS queue keeps log I/O off MainActor. Timestamps are captured at
    /// call time so on-disk ordering still reflects real call ordering even though
    /// writes are async. `print()` stays on the caller's thread for immediate
    /// Xcode-console visibility.
    private static let ioQueue = DispatchQueue(label: "tabmail.logger.io", qos: .utility)

    /// Shared write helper — appends via `FileHandle.seekToEnd`, periodic byte-cap trim, all on ioQueue.
    private static func appendAsync(to url: URL, entry: String) {
        ioQueue.async {
            guard let data = entry.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                try? Data().write(to: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    // Drop on write error; next append will retry.
                }
                try? handle.close()
            }
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size > maxBytes {
                trimTail(url: url)
            }
        }
    }

    /// Atomically replace `url` with its last `keepBytes`, advanced past the first
    /// partial line so we never split a log entry. Caller must run this on `ioQueue`.
    private static func trimTail(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > UInt64(keepBytes) else { return }
        let offset = size - UInt64(keepBytes)
        do { try handle.seek(toOffset: offset) } catch { return }
        guard var data = try? handle.readToEnd() else { return }
        if let newline = data.firstIndex(of: 0x0A) {
            data = data.subdata(in: (newline + 1)..<data.count)
        }
        try? data.write(to: url, options: .atomic)
    }

    /// Drain all pending async writes before returning. Call this from `read*`
    /// methods so a log-then-read roundtrip (tests, debug-menu view) sees the
    /// just-written entry rather than racing the async flush.
    private static func flushPendingWrites() {
        ioQueue.sync { /* serial queue → .sync drains everything queued */ }
    }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    /// Append a background sync event. Thread-safe via atomic file writes.
    static func log(_ message: String) {
        let entry = "[\(Date().iso8601String())] \(message)\n"
        print("[BGSyncLog] \(message)")
        appendAsync(to: fileURL, entry: entry)
    }

    /// Read the full log. Returns empty message if no log exists.
    /// Flushes any pending async writes first so a log-then-read roundtrip is consistent.
    static func readLog() -> String {
        flushPendingWrites()
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "(no background sync log)"
    }

    /// Clear the log file.
    static func clearLog() {
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Error Log

    private static let errorFileName = "error.log"

    private static var errorFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(errorFileName)
    }

    /// Log an error with source context. Captures sync errors, NIO errors, API errors, etc.
    static func logError(_ message: String, source: String) {
        let entry = "[\(Date().iso8601String())] [\(source)] \(message)\n"
        print("[ErrorLog:\(source)] \(message)")
        appendAsync(to: errorFileURL, entry: entry)
    }

    static func readErrorLog() -> String {
        flushPendingWrites()
        return (try? String(contentsOf: errorFileURL, encoding: .utf8)) ?? "(no errors logged)"
    }

    static func clearErrorLog() {
        try? "".write(to: errorFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Chat Error Log

    private static let chatErrorFileName = "chat_error.log"

    private static var chatErrorFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(chatErrorFileName)
    }

    /// Log a chat/AI error with context. Captures tool failures, empty responses, connection errors, etc.
    static func logChatError(_ message: String, userMessage: String? = nil) {
        var entry = "[\(Date().iso8601String())] \(message)"
        if let userMessage {
            entry += "\n  User message: \(userMessage.prefix(100))"
        }
        entry += "\n"
        print("[ChatErrorLog] \(message)")
        appendAsync(to: chatErrorFileURL, entry: entry)
    }

    static func readChatErrorLog() -> String {
        flushPendingWrites()
        return (try? String(contentsOf: chatErrorFileURL, encoding: .utf8)) ?? "(no chat errors logged)"
    }

    static func clearChatErrorLog() {
        try? "".write(to: chatErrorFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - BG App Refresh Log

    private static let bgAppRefreshFileName = "bg_app_refresh.log"

    private static var bgAppRefreshFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(bgAppRefreshFileName)
    }

    /// Log a BGAppRefreshTask lifecycle event (schedule, start, expire, complete, silent push).
    /// Only writes to disk when debug mode is unlocked by an allowed user.
    static func logBGAppRefresh(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        let entry = "[\(Date().iso8601String())] \(message)\n"
        print("[BGAppRefreshLog] \(message)")
        appendAsync(to: bgAppRefreshFileURL, entry: entry)
    }

    static func readBGAppRefreshLog() -> String {
        flushPendingWrites()
        return (try? String(contentsOf: bgAppRefreshFileURL, encoding: .utf8)) ?? "(no BG App Refresh log)"
    }

    static func clearBGAppRefreshLog() {
        try? "".write(to: bgAppRefreshFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - BG Processing Log

    private static let bgProcessingFileName = "bg_processing.log"

    private static var bgProcessingFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(bgProcessingFileName)
    }

    /// Log a BGProcessingTask lifecycle event (schedule, start, phase progress, expire, complete).
    /// Only writes to disk when debug mode is unlocked by an allowed user.
    static func logBGProcessing(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        let entry = "[\(Date().iso8601String())] \(message)\n"
        print("[BGProcessingLog] \(message)")
        appendAsync(to: bgProcessingFileURL, entry: entry)
    }

    static func readBGProcessingLog() -> String {
        flushPendingWrites()
        return (try? String(contentsOf: bgProcessingFileURL, encoding: .utf8)) ?? "(no BG Processing log)"
    }

    static func clearBGProcessingLog() {
        try? "".write(to: bgProcessingFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - AI Processing Log

    private static let aiProcessingFileName = "ai_processing.log"

    private static var aiProcessingFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(aiProcessingFileName)
    }

    /// Log an AI processing queue event (enqueue, dispatch, dequeue, complete, retry, context).
    /// Only writes to disk when debug mode is unlocked by an allowed user.
    static func logAIProcessing(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        let entry = "[\(Date().iso8601String())] \(message)\n"
        print("[AIProcessingLog] \(message)")
        appendAsync(to: aiProcessingFileURL, entry: entry)
    }

    static func readAIProcessingLog() -> String {
        flushPendingWrites()
        return (try? String(contentsOf: aiProcessingFileURL, encoding: .utf8)) ?? "(no AI processing log)"
    }

    static func clearAIProcessingLog() {
        try? "".write(to: aiProcessingFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Push Notification Log

    private static let pushFileName = "push.log"

    private static var pushFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(pushFileName)
    }

    /// Log a push notification event (registration, subscription, silent push processing).
    /// Only writes to disk when debug mode is unlocked by an allowed user.
    static func logPush(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        let entry = "[\(Date().iso8601String())] \(message)\n"
        print("[PushLog] \(message)")
        appendAsync(to: pushFileURL, entry: entry)
    }

    static func readPushLog() -> String {
        flushPendingWrites()
        return (try? String(contentsOf: pushFileURL, encoding: .utf8)) ?? "(no push notification log)"
    }

    static func clearPushLog() {
        try? "".write(to: pushFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Backfill AI Refinement Log

    private static let backfillAIFileName = "backfill_ai.log"

    private static var backfillAIFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(backfillAIFileName)
    }

    /// Log a BackfillAIQueue event (enqueue, claim, success, skip, retry, drop, repopulate).
    /// Only writes to disk when debug mode is unlocked by an allowed user.
    static func logBackfillAI(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        let entry = "[\(Date().iso8601String())] \(message)\n"
        print("[BackfillAILog] \(message)")
        appendAsync(to: backfillAIFileURL, entry: entry)
    }

    static func readBackfillAILog() -> String {
        flushPendingWrites()
        return (try? String(contentsOf: backfillAIFileURL, encoding: .utf8)) ?? "(no backfill AI log)"
    }

    static func clearBackfillAILog() {
        try? "".write(to: backfillAIFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Inbox ViewModel Log

    private static let inboxFileName = "inbox.log"

    private static var inboxFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(inboxFileName)
    }

    /// Log an InboxViewModel lifecycle or reload event.
    /// Covers: folder-set transitions, observer registration, reload counts, partial-set heals,
    /// ValueObservation emissions. Only writes when debug mode is unlocked.
    static func logInbox(_ message: String) {
        guard DebugModeManager.isLoggingEnabled() else { return }
        let entry = "[\(Date().iso8601String())] \(message)\n"
        print("[InboxLog] \(message)")
        appendAsync(to: inboxFileURL, entry: entry)
    }

    static func readInboxLog() -> String {
        flushPendingWrites()
        return (try? String(contentsOf: inboxFileURL, encoding: .utf8)) ?? "(no inbox log)"
    }

    static func clearInboxLog() {
        try? "".write(to: inboxFileURL, atomically: true, encoding: .utf8)
    }
}
