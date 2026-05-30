/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Testing
import Foundation
@testable import TabMail

@Suite("WordPieceTokenizer")
struct WordPieceTokenizerTests {

    // Note: WordPieceTokenizer requires tokenizer.json in the bundle.
    // In test environment the resource may not be available, so we test
    // the init returns nil gracefully when the resource is missing.

    @Test("Init returns nil when tokenizer.json is missing")
    func initNilWhenMissing() {
        let tokenizer = WordPieceTokenizer(resourceName: "nonexistent_tokenizer")
        #expect(tokenizer == nil)
    }

    @Test("Init with default resource name attempts to load tokenizer.json")
    func initDefault() {
        // This test documents the expected behavior: either loads successfully
        // (if the resource is bundled in the test target) or returns nil gracefully.
        let tokenizer = WordPieceTokenizer()
        // Either outcome is valid — just ensuring no crash
        if let tokenizer {
            #expect(tokenizer.vocab.count > 0)
            #expect(tokenizer.clsTokenId >= 0)
            #expect(tokenizer.sepTokenId >= 0)
        }
    }

    @Test("If tokenizer loads, tokenize produces valid output shape")
    func tokenizeOutputShape() {
        guard let tokenizer = WordPieceTokenizer() else { return } // Skip if no resource
        let (inputIds, attentionMask) = tokenizer.tokenize("Hello world")
        #expect(inputIds.count == SearchConfig.maxTokens)
        #expect(attentionMask.count == SearchConfig.maxTokens)
        // First token should be [CLS]
        #expect(inputIds[0] == Int32(tokenizer.clsTokenId))
        // Attention mask should start with 1s
        #expect(attentionMask[0] == 1)
    }

    @Test("If tokenizer loads, empty string produces [CLS][SEP] only")
    func tokenizeEmptyString() {
        guard let tokenizer = WordPieceTokenizer() else { return }
        let (inputIds, attentionMask) = tokenizer.tokenize("")
        #expect(inputIds[0] == Int32(tokenizer.clsTokenId))
        #expect(inputIds[1] == Int32(tokenizer.sepTokenId))
        // Rest should be padding
        #expect(attentionMask[2] == 0)
    }
}
