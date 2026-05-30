/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation

// Minimal WordPiece tokenizer for all-MiniLM-L6-v2 CoreML input.
// Loads vocabulary from bundled tokenizer.json (HuggingFace format).

final class WordPieceTokenizer {
    let vocab: [String: Int]
    let idToToken: [Int: String]
    let unkTokenId: Int
    let clsTokenId: Int
    let sepTokenId: Int
    let padTokenId: Int
    private let maxTokens: Int

    init?(resourceName: String = "tokenizer", maxTokens: Int = SearchConfig.maxTokens) {
        self.maxTokens = maxTokens

        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? [String: Any],
              let vocabDict = model["vocab"] as? [String: Int] else {
            return nil
        }

        self.vocab = vocabDict
        var reverse = [Int: String]()
        for (token, id) in vocabDict {
            reverse[id] = token
        }
        self.idToToken = reverse

        self.unkTokenId = vocabDict["[UNK]"] ?? 100
        self.clsTokenId = vocabDict["[CLS]"] ?? 101
        self.sepTokenId = vocabDict["[SEP]"] ?? 102
        self.padTokenId = vocabDict["[PAD]"] ?? 0
    }

    /// Tokenize text into token IDs with [CLS] and [SEP] markers.
    /// Returns (inputIds, attentionMask) both of length maxTokens.
    func tokenize(_ text: String) -> (inputIds: [Int32], attentionMask: [Int32]) {
        let wordPieceIds = wordPieceTokenize(text)

        // Truncate to fit [CLS] ... [SEP] within maxTokens
        let maxContentTokens = maxTokens - 2
        let truncated = Array(wordPieceIds.prefix(maxContentTokens))

        var inputIds = [Int32](repeating: Int32(padTokenId), count: maxTokens)
        var attentionMask = [Int32](repeating: 0, count: maxTokens)

        inputIds[0] = Int32(clsTokenId)
        attentionMask[0] = 1
        for (i, id) in truncated.enumerated() {
            inputIds[i + 1] = Int32(id)
            attentionMask[i + 1] = 1
        }
        inputIds[truncated.count + 1] = Int32(sepTokenId)
        attentionMask[truncated.count + 1] = 1

        return (inputIds, attentionMask)
    }

    /// WordPiece tokenization: split text into subword pieces.
    private func wordPieceTokenize(_ text: String) -> [Int] {
        let words = basicTokenize(text)
        var ids: [Int] = []

        for word in words {
            let subIds = wordPieceForWord(word)
            ids.append(contentsOf: subIds)
        }

        return ids
    }

    /// Basic pre-tokenization: lowercase, split on whitespace + punctuation.
    private func basicTokenize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        var tokens: [String] = []
        var current = ""

        for ch in lowered {
            if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else if ch.isPunctuation || isChineseLike(ch) {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                tokens.append(String(ch))
            } else if ch.isASCII && ch.asciiValue.map({ $0 < 32 || $0 == 127 }) == true {
                // Skip control characters
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    /// WordPiece for a single word: greedy longest-match.
    private func wordPieceForWord(_ word: String) -> [Int] {
        if word.isEmpty { return [] }

        var ids: [Int] = []
        var start = word.startIndex
        let end = word.endIndex

        while start < end {
            var found = false
            var subEnd = end

            while subEnd > start {
                var substr: String
                if start == word.startIndex {
                    substr = String(word[start..<subEnd])
                } else {
                    substr = "##" + String(word[start..<subEnd])
                }

                if let id = vocab[substr] {
                    ids.append(id)
                    start = subEnd
                    found = true
                    break
                }

                // Try one character fewer
                subEnd = word.index(before: subEnd)
            }

            if !found {
                ids.append(unkTokenId)
                start = word.index(after: start)
            }
        }

        return ids
    }

    /// Check if character is in CJK Unified Ideographs range.
    private func isChineseLike(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        return (v >= 0x4E00 && v <= 0x9FFF) ||
               (v >= 0x3400 && v <= 0x4DBF) ||
               (v >= 0x20000 && v <= 0x2A6DF) ||
               (v >= 0x2A700 && v <= 0x2B73F) ||
               (v >= 0x2B740 && v <= 0x2B81F) ||
               (v >= 0x2B820 && v <= 0x2CEAF) ||
               (v >= 0xF900 && v <= 0xFAFF) ||
               (v >= 0x2F800 && v <= 0x2FA1F)
    }
}
