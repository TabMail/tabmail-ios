/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Persistent diagnostic log for Device Sync events (connection, probes, responses).
/// Writes timestamped entries to a file in Application Support so they survive
/// app restarts and can be viewed in Settings > Debug > Device Sync Logs.
enum DeviceSyncLogger {
    private static let maxEntries = 300
    private static let fileName = "device_sync.log"

    /// Serial queue for off-main file I/O. Callers include WebSocket handlers
    /// which can run on the main thread — the existing sync read-modify-write
    /// was blocking MainActor. See BackgroundSyncLogger.ioQueue for rationale.
    private static let ioQueue = DispatchQueue(label: "tabmail.logger.devicesync.io", qos: .utility)

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    /// Append a Device Sync event. File I/O dispatched off-main on the serial
    /// `ioQueue`. Timestamp is captured at call time so on-disk ordering
    /// matches call ordering.
    static func log(_ message: String) {
        let entry = "[\(Date().iso8601String())] \(message)\n"
        let url = fileURL
        ioQueue.async {
            if var existing = try? String(contentsOf: url, encoding: .utf8) {
                existing += entry
                let lines = existing.components(separatedBy: "\n").filter { !$0.isEmpty }
                let trimmed = lines.suffix(maxEntries).joined(separator: "\n") + "\n"
                try? trimmed.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try? entry.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    static func readLog() -> String {
        // Drain pending async writes so a write-then-read roundtrip sees the entry.
        ioQueue.sync { /* serial queue → .sync drains everything queued */ }
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "(no Device Sync log)"
    }

    static func clearLog() {
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
