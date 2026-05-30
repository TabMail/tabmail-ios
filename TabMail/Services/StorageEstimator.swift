/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

enum StorageEstimator {
    /// Minimum messages per folder that are never pruned
    static let floorPerFolder = 50

    /// Global storage budget key in UserDefaults
    static let storageBudgetKey = "globalStorageBudgetMB"

    /// Default global storage budget: unlimited
    static let defaultBudgetMB = Int.max

    /// Get the user-configured global storage budget in MB.
    static var budgetMB: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: storageBudgetKey)
            return val > 0 ? val : defaultBudgetMB
        }
        set {
            UserDefaults.standard.set(newValue, forKey: storageBudgetKey)
        }
    }

    /// Measure disk usage of our stored data (GRDB + FTS) in Application Support.
    /// Excludes system-managed caches (Apple Intelligence e5rt, WebKit, etc.) that iOS
    /// can purge independently and that don't count toward our storage budget.
    static func totalSizeMB() -> Double {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return 0 }
        return allocatedSizeMB(of: appSupport)
    }

    /// Recursively measure allocated disk size of a directory in MB.
    private static func allocatedSizeMB(of directory: URL) -> Double {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return 0 }

        var totalBytes: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let allocated = values.totalFileAllocatedSize else { continue }
            totalBytes += UInt64(allocated)
        }
        return Double(totalBytes) / (1024.0 * 1024.0)
    }

    /// Whether total storage exceeds the global budget.
    static func isOverBudget() -> Bool {
        budgetMB != Int.max && totalSizeMB() >= Double(budgetMB)
    }
}
