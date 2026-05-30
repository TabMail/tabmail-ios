/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("Array.chunked(into:)")
struct ArrayChunkedTests {

    @Test("Even split")
    func evenSplit() {
        let result = [1, 2, 3, 4, 5, 6].chunked(into: 2)
        #expect(result == [[1, 2], [3, 4], [5, 6]])
    }

    @Test("Uneven split has smaller last chunk")
    func unevenSplit() {
        let result = [1, 2, 3, 4, 5].chunked(into: 2)
        #expect(result == [[1, 2], [3, 4], [5]])
    }

    @Test("Chunk size equals array length")
    func chunkSizeEqualsLength() {
        let result = [1, 2, 3].chunked(into: 3)
        #expect(result == [[1, 2, 3]])
    }

    @Test("Chunk size larger than array")
    func chunkSizeLarger() {
        let result = [1, 2].chunked(into: 10)
        #expect(result == [[1, 2]])
    }

    @Test("Single element array")
    func singleElement() {
        let result = [42].chunked(into: 1)
        #expect(result == [[42]])
    }

    @Test("Empty array returns empty")
    func emptyArray() {
        let result: [[Int]] = [Int]().chunked(into: 5)
        #expect(result.isEmpty)
    }

    @Test("Chunk size of 1 returns individual elements")
    func chunkSizeOne() {
        let result = ["a", "b", "c"].chunked(into: 1)
        #expect(result == [["a"], ["b"], ["c"]])
    }

    @Test("Works with strings")
    func worksWithStrings() {
        let result = ["a", "b", "c", "d", "e"].chunked(into: 3)
        #expect(result == [["a", "b", "c"], ["d", "e"]])
    }

    @Test("Large chunk count")
    func largeArray() {
        let arr = Array(0..<100)
        let result = arr.chunked(into: 25)
        #expect(result.count == 4)
        #expect(result[0].count == 25)
        #expect(result[3].count == 25)
        #expect(result[0].first == 0)
        #expect(result[3].last == 99)
    }

    @Test("Preserves element order")
    func preservesOrder() {
        let arr = [10, 20, 30, 40, 50]
        let result = arr.chunked(into: 2)
        let flattened = result.flatMap { $0 }
        #expect(flattened == arr)
    }
}
