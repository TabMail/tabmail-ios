/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

#if DEBUG
import SwiftUI
import GRDB

// Previews for the Outbox row's held/queued/sending/failed states.
//
// What to look for:
//   - Held rows show "Sending in Xs" with an hourglass icon, counting down
//     each second (the Timer publisher in OutboxRow drives the redraw).
//   - Swipe left: label should read "Cancel Send" while held, "Discard"
//     after hold expires or for non-held rows.

/// Seed a held OutboxMessage with holdUntil at `secondsFromNow` in the future.
private func seedHeld(
    account: Account,
    to: [String] = ["alice@example.com"],
    subject: String,
    secondsFromNow: TimeInterval
) throws {
    var msg = OutboxMessage(
        accountId: account.id,
        draft: DraftMessage(to: to, subject: subject, body: "Preview body.")
    )
    msg.status = OutboxStatus.queued.rawValue
    msg.holdUntil = Date().addingTimeInterval(secondsFromNow)
    msg.draftId = "preview-draft-\(UUID().uuidString)"
    try AppDatabase.dbPool.write { try msg.save($0) }
}

/// Seed a plain queued message (past-hold, awaiting drain). Simulates a
/// transient-failure row or a legacy pre-v49 message.
private func seedQueued(
    account: Account,
    to: [String] = ["carol@example.com"],
    subject: String
) throws {
    var msg = OutboxMessage(
        accountId: account.id,
        draft: DraftMessage(to: to, subject: subject, body: "Preview body.")
    )
    msg.status = OutboxStatus.queued.rawValue
    msg.holdUntil = Date().addingTimeInterval(-10)  // hold expired 10 s ago
    try AppDatabase.dbPool.write { try msg.save($0) }
}

/// Seed a .sending message (drain claimed, SMTP in flight).
private func seedSending(
    account: Account,
    to: [String] = ["dave@example.com"],
    subject: String
) throws {
    var msg = OutboxMessage(
        accountId: account.id,
        draft: DraftMessage(to: to, subject: subject, body: "Preview body.")
    )
    msg.status = OutboxStatus.sending.rawValue
    try AppDatabase.dbPool.write { try msg.save($0) }
}

/// Seed a .failed message with error text.
private func seedFailed(
    account: Account,
    to: [String] = ["eve@example.com"],
    subject: String,
    error: String
) throws {
    var msg = OutboxMessage(
        accountId: account.id,
        draft: DraftMessage(to: to, subject: subject, body: "Preview body.")
    )
    msg.status = OutboxStatus.failed.rawValue
    msg.errorMessage = error
    msg.retryCount = 3
    try AppDatabase.dbPool.write { try msg.save($0) }
}

#Preview("Held — 5 s countdown (just queued)") {
    let scenario = PreviewMocks.seedInbox()
    let navStore = PreviewMocks.navigationStore()
    try? seedHeld(account: scenario.account, subject: "Weekly team sync notes", secondsFromNow: 5)
    navStore.refreshOutbox()
    return NavigationStack {
        OutboxView(accountId: nil)
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}

#Preview("Held — near end (2 s remaining)") {
    let scenario = PreviewMocks.seedInbox()
    let navStore = PreviewMocks.navigationStore()
    try? seedHeld(account: scenario.account, subject: "Q3 planning review", secondsFromNow: 2)
    navStore.refreshOutbox()
    return NavigationStack {
        OutboxView(accountId: nil)
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}

#Preview("Mixed states — held + queued + sending + failed") {
    let scenario = PreviewMocks.seedInbox()
    let navStore = PreviewMocks.navigationStore()
    try? seedHeld(
        account: scenario.account,
        to: ["alice@example.com"],
        subject: "Held: 5s countdown",
        secondsFromNow: 5
    )
    try? seedHeld(
        account: scenario.account,
        to: ["bob@example.com"],
        subject: "Held: 3s countdown",
        secondsFromNow: 3
    )
    try? seedQueued(
        account: scenario.account,
        to: ["carol@example.com"],
        subject: "Queued (past-hold, awaiting drain)"
    )
    try? seedSending(
        account: scenario.account,
        to: ["dave@example.com"],
        subject: "Sending (SMTP in flight)"
    )
    try? seedFailed(
        account: scenario.account,
        to: ["eve@example.com"],
        subject: "Failed — bad recipient",
        error: "SMTP: invalid recipient address"
    )
    navStore.refreshOutbox()
    return NavigationStack {
        OutboxView(accountId: nil)
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}

#Preview("Empty outbox") {
    _ = PreviewMocks.seedInbox()
    let navStore = PreviewMocks.navigationStore()
    return NavigationStack {
        OutboxView(accountId: nil)
    }
    .environment(navStore)
    .environment(\.hasTabMailSession, true)
}
#endif
