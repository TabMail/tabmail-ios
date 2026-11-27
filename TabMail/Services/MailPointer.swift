/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Where an email the user sees lives right now.
///
/// One email can change place while a view shows it: a send waits in the
/// outbox, is filed as the app's own Sent copy, and that copy is later
/// replaced by the server's copy; a provider move or a UID repair gives a
/// stored row a new primary key. Each of these is posted as a
/// `MailPointerMove`, and every holder of a pointer (a list, the selection,
/// the undo stack, an open detail, a chat) follows the same posted moves
/// through `MailPointerMoves`, so no stage has follow code of its own.
enum MailPointer: Hashable, Sendable {
    /// `outboxMessage.id`: a send not yet filed.
    case outbox(String)
    /// `messageHeader.id`: a stored email.
    case header(String)
}

/// One committed move of a pointer. Posted on the main actor after the write
/// that made it has committed (`MailPointerMoves.publish`).
enum MailPointerMove: Sendable, Equatable {
    /// A stored row now lives under a new primary key: a provider move's
    /// finish, the sync's UID repair, or the sync replacing a sent or saved
    /// email's placeholder row by the server's copy
    /// (`SyncEngine.placeholderReplacement`).
    case row(HeaderRekeyRecord)
    /// A send finished: its outbox item is now the app's own Sent copy at
    /// `copyHeaderId`, or nil when no copy was written (no Sent folder, or the
    /// write failed). Posted before the outbox row is deleted, so a holder can
    /// tell a finished send from one that was undone or discarded, which post
    /// nothing.
    case sent(outboxId: String, copyHeaderId: String?)

    var from: MailPointer {
        switch self {
        case .row(let record): .header(record.oldHeaderId)
        case .sent(let outboxId, _): .outbox(outboxId)
        }
    }

    /// nil only for a send that finished with no Sent copy.
    var to: MailPointer? {
        switch self {
        case .row(let record): .header(record.newHeaderId)
        case .sent(_, let copyHeaderId): copyHeaderId.map(MailPointer.header)
        }
    }

    /// Whether the provider itself proved the destination. Only such a move
    /// may carry optimistic action state (a hidden or fading row, an undo
    /// member) to the new key. A send's filing is the app's own write, so it
    /// carries none.
    var carriesProviderAuthority: Bool {
        switch self {
        case .row(let record): record.carriesProviderAuthority
        case .sent: false
        }
    }
}

/// The moves of one post, indexed once and read by every holder. When two
/// moves name the same pointer, the first one wins.
struct MailPointerMoves: Sendable, Equatable {
    let moves: [MailPointerMove]
    private let byFrom: [MailPointer: MailPointerMove]

    init(_ moves: [MailPointerMove]) {
        self.moves = moves
        self.byFrom = Dictionary(
            moves.map { ($0.from, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    var isEmpty: Bool { moves.isEmpty }

    /// The move that names `pointer`, if any.
    func move(for pointer: MailPointer) -> MailPointerMove? {
        byFrom[pointer]
    }

    /// Where `pointer` is after these moves: itself when no move names it,
    /// nil when it names a send that finished with no Sent copy.
    func following(_ pointer: MailPointer) -> MailPointer? {
        guard let move = byFrom[pointer] else { return pointer }
        return move.to
    }

    /// The re-key of the stored row at `headerId`, with its new provider
    /// address and epoch; nil when no move names that row.
    func row(movedFrom headerId: String) -> HeaderRekeyRecord? {
        guard case .row(let record)? = byFrom[.header(headerId)] else { return nil }
        return record
    }

    /// A stored row's primary key after these moves.
    func following(header headerId: String) -> String {
        row(movedFrom: headerId)?.newHeaderId ?? headerId
    }

    /// A set of stored rows' primary keys after these moves.
    func following(headers ids: Set<String>) -> Set<String> {
        Set(ids.map { following(header: $0) })
    }

    /// Only the moves the provider proved (`carriesProviderAuthority`).
    var withProviderAuthority: MailPointerMoves {
        MailPointerMoves(moves.filter(\.carriesProviderAuthority))
    }

    /// The stored-row re-keys among these moves.
    var rows: [HeaderRekeyRecord] {
        moves.compactMap { move in
            guard case .row(let record) = move else { return nil }
            return record
        }
    }

    /// The one way a producer announces moves whose write has committed. An
    /// open chat follows its email first (`ChatPillState.followRekeyedEmails`),
    /// then every holder is told (`post`). The stores in the main database
    /// moved in the producer's own transaction (`ChatStore.followRekeyedEmails`);
    /// the stores outside it follow after (`followOutsideStoresInOrder`).
    ///
    /// The moves of one post are not chained: each names a row before this
    /// post, and a lookup takes one step. No producer re-keys one row twice
    /// in one write, so a chain of moves of one email arrives as one post per
    /// write, in order.
    @MainActor static func publish(_ moves: MailPointerMoves) {
        guard !moves.isEmpty else { return }
        ChatPillState.shared.followRekeyedEmails(moves.rows)
        post(moves)
    }

    /// `publish` for a producer that must not wait on the stores outside the
    /// main database (a sync pass, a draft save, a body fetch): the committed
    /// re-keys are published on the main actor, where delivery is synchronous,
    /// so every holder has followed before this returns; those stores then
    /// follow in the background, in order (`followOutsideStoresInOrder`).
    static func publishRekeys(_ records: [HeaderRekeyRecord]) async {
        guard !records.isEmpty else { return }
        let moves = MailPointerMoves(records.map(MailPointerMove.row))
        await MainActor.run {
            publish(moves)
        }
        followOutsideStoresInOrder(records)
    }

    /// Posts `.mailPointersMoved`. Every observer uses the `.main` queue, so
    /// delivery is synchronous: each holder has followed before this returns.
    @MainActor static func post(_ moves: MailPointerMoves) {
        guard !moves.isEmpty else { return }
        NotificationCenter.default.post(name: .mailPointersMoved, object: moves)
    }

    /// The stores outside the main database that name a re-keyed email follow
    /// it: a chat pill keeps its number on the moved row (`ChatIdTranslator`),
    /// and memory.db's copy of a followed chat session id moves
    /// (`MemoryIndex.followSessions`). Batches run one after another in the
    /// order they were handed over, so a chain of re-keys of one email handed
    /// over in commit order ends on its last row. Across producers the
    /// hand-over can trail the commit (the move drain updates the undo stack
    /// first), so a re-key of the same row by another producer in that gap
    /// is followed first and these stores end on the middle row: a rare
    /// timing race, ios#1581. No producer waits for them (the move drain, a
    /// sync pass, a draft save, a body fetch).
    ///
    /// A memory.db follow that fails is not retried: `followSessions` logs and
    /// returns, and that chat stays under its old session id in memory search.
    /// The lane's buffer is unbounded; it holds at most the re-keys not yet
    /// followed.
    static func followOutsideStoresInOrder(_ records: [HeaderRekeyRecord]) {
        guard !records.isEmpty else { return }
        outsideStoresLane.yield(OutsideStoresBatch(records: records, done: nil))
    }

    #if DEBUG
    /// Returns once every batch handed to the lane before this call has run.
    static func outsideStoresSettledForTesting() async {
        await withCheckedContinuation { done in
            outsideStoresLane.yield(OutsideStoresBatch(records: [], done: done))
        }
    }
    #endif

    private struct OutsideStoresBatch: Sendable {
        let records: [HeaderRekeyRecord]
        let done: CheckedContinuation<Void, Never>?
    }

    private static let outsideStoresLane: AsyncStream<OutsideStoresBatch>.Continuation = {
        let (stream, continuation) = AsyncStream<OutsideStoresBatch>.makeStream()
        Task.detached {
            for await batch in stream {
                for record in batch.records {
                    _ = await ChatIdTranslator.shared.remapRealId(
                        from: record.oldHeaderId, to: record.newHeaderId)
                }
                await MemoryIndex.shared.followSessions(batch.records.compactMap { record in
                    guard let ids = record.stableIds, ids.changed else { return nil }
                    return (
                        old: ChatStore.messageSessionId(accountId: ids.accountId, stableId: ids.old),
                        new: ChatStore.messageSessionId(accountId: ids.accountId, stableId: ids.new))
                })
                batch.done?.resume()
            }
        }
        return continuation
    }()

    /// The moves a `.mailPointersMoved` notification carries; nil for any
    /// other object.
    static func posted(in notification: Notification) -> MailPointerMoves? {
        guard let moves = notification.object as? MailPointerMoves,
              !moves.isEmpty else { return nil }
        return moves
    }
}
