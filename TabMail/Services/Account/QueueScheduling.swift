/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

/// Equality only: scheduling must never inspect or manufacture domain addresses.
struct QueueDependencyKey: Hashable, Sendable {
    private let value: String
    init(_ value: String) { self.value = value }
}

struct QueueJob: Sendable {
    let id: String
    let accountId: String
    let queuePosition: Int
    var status: String
    let dependencyKeys: [QueueDependencyKey]
}

enum QueueAttemptDisposition: Sendable, Equatable {
    case completed
    case progressed
    case retryLater(scope: RetryScope, chargeRetry: Bool)
    case blockedOnCommit

    enum RetryScope: Sendable, Equatable { case relatedChain, account }
}

enum QueueScheduling {
    /// Input order is durable FIFO order. Empty keys form a singleton component.
    static func relatedChains(_ ops: [QueueJob]) -> [[QueueJob]] {
        // Union-Find over address keys, with path compression.
        var parent: [QueueDependencyKey: QueueDependencyKey] = [:]

        func find(_ x: QueueDependencyKey) -> QueueDependencyKey {
            var root = x
            while let p = parent[root], p != root {
                root = p
            }
            var current = x
            while let p = parent[current], p != root {
                parent[current] = root
                current = p
            }
            return root
        }

        func union(_ a: QueueDependencyKey, _ b: QueueDependencyKey) {
            let rootA = find(a)
            let rootB = find(b)
            if rootA != rootB { parent[rootA] = rootB }
        }

        for op in ops {
            let keys = op.dependencyKeys
            guard !keys.isEmpty else { continue }
            for key in keys where parent[key] == nil {
                parent[key] = key
            }
            for key in keys.dropFirst() {
                union(keys[0], key)
            }
        }

        // Assign each op to its component's group, in the caller's ORIGINAL order
        // (every production caller passes rows read `ORDER BY queuePosition ASC`).
        var chainIndexForRoot: [QueueDependencyKey: Int] = [:]
        var chains: [[QueueJob]] = []
        for op in ops {
            guard let firstKey = op.dependencyKeys.first else {
                // No dependency keys — always its own singleton chain.
                chains.append([op])
                continue
            }
            let root = find(firstKey)
            if let idx = chainIndexForRoot[root] {
                chains[idx].append(op)
            } else {
                chainIndexForRoot[root] = chains.count
                chains.append([op])
            }
        }
        return chains
    }
}
