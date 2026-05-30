/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("StorageEstimator")
struct StorageEstimatorTests {

    @Test("floorPerFolder is reasonable")
    func floorPerFolder() {
        #expect(StorageEstimator.floorPerFolder > 0)
        #expect(StorageEstimator.floorPerFolder == 50)
    }

    @Test("defaultBudgetMB is Int.max (unlimited)")
    func defaultBudgetUnlimited() {
        #expect(StorageEstimator.defaultBudgetMB == Int.max)
    }

    @Test("totalSizeMB returns non-negative value")
    func totalSizeNonNegative() {
        let size = StorageEstimator.totalSizeMB()
        #expect(size >= 0)
    }

    @Test("storageBudgetKey is non-empty string")
    func storageBudgetKey() {
        #expect(!StorageEstimator.storageBudgetKey.isEmpty)
    }

    @Test("isOverBudget returns false when budget is unlimited")
    func notOverBudgetWhenUnlimited() {
        // With default budget (Int.max), should never be over budget
        let savedBudget = UserDefaults.standard.integer(forKey: StorageEstimator.storageBudgetKey)
        defer { UserDefaults.standard.set(savedBudget, forKey: StorageEstimator.storageBudgetKey) }

        UserDefaults.standard.removeObject(forKey: StorageEstimator.storageBudgetKey)
        #expect(StorageEstimator.isOverBudget() == false)
    }
}
