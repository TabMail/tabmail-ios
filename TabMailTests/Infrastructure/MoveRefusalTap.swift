/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import Synchronization
@testable import TabMail

/// Collects every `.messageMovesRefused` delivery naming one of the watched header
/// ids, read through the view's own extraction (`MoveRefusalReceiver.refusedIds`).
/// Filtering to the watched ids keeps another suite's refusals out of the result.
///
/// `@unchecked`: `observer` is written once in `init` and cleared once in `stop()`,
/// both by the owning test; `received` is the only state the observer block
/// touches, and it is a `Mutex`.
final class MoveRefusalTap: @unchecked Sendable {
    private let received = Mutex<Set<String>>([])
    private let ids: Set<String>
    private var observer: NSObjectProtocol?

    init(watching ids: Set<String>) {
        self.ids = ids
        observer = NotificationCenter.default.addObserver(
            forName: .messageMovesRefused, object: nil, queue: nil
        ) { [self] notification in
            guard let refused = MoveRefusalReceiver.refusedIds(from: notification) else { return }
            received.withLock { $0.formUnion(refused.intersection(self.ids)) }
        }
    }

    var snapshot: Set<String> { received.withLock { $0 } }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
