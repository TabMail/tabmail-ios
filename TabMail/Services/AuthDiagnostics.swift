/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Diagnostic log writer for auth-related events (launch session state, token
/// refresh outcomes, Keychain save failures).
///
/// Writes to the single app log via `AppLogStore` on the `.auth` channel, so it
/// survives app restarts and can be retrieved after an unexpected logout —
/// which is the entire reason this channel is persistent and always-on.
///
/// Consolidating onto the shared file gave this channel a UI ROUTE it never
/// had — **not** a reader. ⚠️ It always had one: `v1.7.14`'s `AuthDiagnostics`
/// declares `readLog()`. What it lacked was any surface that CALLED it; the doc
/// comment named a "Settings > Maintenance" row that does not exist in the tree,
/// and `auth_diagnostics.log` was the only one of the fifteen log files with no
/// share button anywhere. So its entries were written and UNREACHABLE, not
/// unreadable. They are now part of the App Logs share.
///
/// The symmetric half, recorded because an earlier draft stated only the
/// widening: those entries also gained a DESTROYER. They previously sat outside
/// every clear surface in the app; they are now inside `tabmail.log`, which
/// "Clear All Logs" wipes — so "clear the logs, reproduce, share" now destroys
/// the auth history that predates the repro. Kept deliberately (owner decision,
/// 2026-08-25); do not re-add an exclusion without re-opening `IOS-LOG-002`.
///
/// The write is dispatched off-main by `AppLogStore`; the previous
/// implementation did a synchronous read-modify-write on the caller's thread,
/// including from `TabMailApp.init` on MainActor.
enum AuthDiagnostics {
    /// Append an auth diagnostic event.
    ///
    /// **ASYNCHRONOUS, and that is a deliberate durability trade** — the exact
    /// opposite of the call `NSELogStore` makes, so it is stated here in the
    /// same terms.
    ///
    /// Until `v1.7.14` this did a synchronous atomic read-modify-write of
    /// `auth_diagnostics.log` on the caller's thread, including from
    /// `TabMailApp.init` — i.e. file I/O on MainActor on the launch path. It now
    /// hands the entry to `AppLogStore.ioQueue` (`.utility`) and returns
    /// immediately.
    ///
    /// **The cost:** an entry enqueued and not yet flushed is lost if the
    /// process dies first — a crash, a jetsam kill, a force-quit. The entries
    /// most likely to be lost are the ones written last, which on the auth path
    /// is precisely the sequence before an unexpected logout, the thing this
    /// channel exists to explain.
    ///
    /// **Why it is still the right call here, where it is the wrong one for the
    /// NSE:** the main app is not hard-killed on a budget the way the NSE is
    /// (0xdead10cc suspension, watchdog, ~30 s OS budget), so the window is a
    /// scheduling gap rather than a guaranteed truncation; and blocking
    /// MainActor at launch is a cost every user pays on every launch, while the
    /// lost tail line costs only the rare crash. If a future change makes the
    /// tail line load-bearing, the fix is a synchronous FLUSH at a known-risky
    /// point, not a return to synchronous appends.
    static func log(_ message: String) {
        print("[AuthDiag] \(message)")
        AppLogStore.append(message, channel: .auth)
    }
}
