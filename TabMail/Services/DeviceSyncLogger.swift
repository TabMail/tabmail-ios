/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Diagnostic log writer for Device Sync events (connection, probes, responses).
///
/// Writes to the single app log via `AppLogStore` on the `.deviceSync` channel;
/// read back from the Debug menu's App Logs share, or filtered with
/// `AppLogStore.read(channel: .deviceSync)`.
///
/// Always-on, unchanged by the move off its own `device_sync.log` file: Device
/// Sync failures are reported from the field and there is no second channel that
/// records them (`IOS-LOG-002`).
enum DeviceSyncLogger {
    /// Append a Device Sync event. File I/O is dispatched off-main by
    /// `AppLogStore`; callers include WebSocket handlers that run on the main
    /// thread. The timestamp is captured at call time, but on-disk ordering is
    /// APPEND order rather than call order — see `AppLogStore.append`.
    static func log(_ message: String) {
        AppLogStore.append(message, channel: .deviceSync)
    }
}
