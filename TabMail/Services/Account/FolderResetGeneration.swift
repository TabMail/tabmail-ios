import Foundation
import Synchronization

/// Refuses a gesture against a row the user saw before its IMAP folder's
/// UIDVALIDITY reset.
///
/// A reset renumbers the folder: the resync re-seats a different email at the
/// same header id (`account:folder:UID`), carrying the new epoch, so the epoch
/// check in `AccountManager.admittedOrdinaryActionTargets` admits it. What the
/// replacement cannot carry is WHEN the user's view of the row was taken. This
/// type records that time as a serial (the stamp) and the serial at which each
/// folder last finished a reset; an admission whose stamp predates the folder's
/// reset is refused.
///
/// - The stamp is a task-local. `AccountManager`'s write queue captures it when a
///   gesture is enqueued and runs the queued work under it, so every admission
///   inside that work sees it, including inside `dbPool.write` (GRDB runs the
///   block as a job of the calling task). A surface that outlives the purge's
///   list reload (detail view, Move sheet, label sheet, AI confirmation card)
///   binds the stamp from when it was opened around its gestures.
/// - No stamp bound means no check: sync, outbox and other non-gesture work act
///   on rows read at execution time, not on a row someone was shown.
/// - In memory only: after a relaunch no queued closure or open surface
///   survives, and durable queued operations are already invalidated by their
///   recorded epoch.
enum FolderResetGeneration {
    @TaskLocal static var gestureStamp: UInt64?

    private struct State {
        var serial: UInt64 = 0
        var lastReset: [String: UInt64] = [:]
    }
    private static let state = Mutex(State())

    /// The serial a gesture taken now is stamped with.
    static func current() -> UInt64 {
        state.withLock { $0.serial }
    }

    /// The stamp to record for a gesture enqueued now: the bound one when a
    /// surface or an outer queued closure supplied it, otherwise the current
    /// serial.
    static func stampForNewWork() -> UInt64 {
        gestureStamp ?? current()
    }

    /// Called by the reset reaction immediately before the new epoch becomes
    /// admissible. Every stamp taken before this call is refused for `folderId`.
    static func recordReset(folderId: String) {
        state.withLock { state in
            state.serial &+= 1
            state.lastReset[folderId] = state.serial
        }
    }

    /// True when a stamp is bound and `folderId` finished a reset after it.
    static func refuses(folderId: String) -> Bool {
        guard let stamp = gestureStamp else { return false }
        return state.withLock { state in
            guard let reset = state.lastReset[folderId] else { return false }
            return reset > stamp
        }
    }
}
