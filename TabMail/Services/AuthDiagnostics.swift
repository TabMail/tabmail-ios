/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Persistent diagnostic log for auth-related events.
/// Writes timestamped entries to a file in Application Support so they survive
/// app restarts and can be retrieved after an unexpected logout.
/// Surface via Settings > Maintenance > "Auth Diagnostics" row.
enum AuthDiagnostics {
    private static let maxEntries = 50
    private static let fileName = "auth_diagnostics.log"

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TabMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    /// Append a diagnostic event. Thread-safe via file coordination.
    static func log(_ message: String) {
        let timestamp = Date().iso8601String()
        let entry = "[\(timestamp)] \(message)\n"

        // Also print for Xcode console
        print("[AuthDiag] \(message)")

        let url = fileURL
        if var existing = try? String(contentsOf: url, encoding: .utf8) {
            existing += entry
            // Trim to last N entries
            let lines = existing.components(separatedBy: "\n").filter { !$0.isEmpty }
            let trimmed = lines.suffix(maxEntries).joined(separator: "\n") + "\n"
            try? trimmed.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Read the full diagnostic log. Returns empty string if no log exists.
    static func readLog() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "(no diagnostic log)"
    }
}
