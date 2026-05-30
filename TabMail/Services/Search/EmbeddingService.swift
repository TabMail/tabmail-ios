/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import Foundation
import CoreML
import Synchronization

// CoreML embedding service for all-MiniLM-L6-v2.
// Runs on Neural Engine when available, falls back to GPU/CPU.
// Singleton — initialized once at app launch.

final class EmbeddingService: @unchecked Sendable {
    /// Shared instance, nil if model/tokenizer not available.
    /// Mutex-guarded for thread-safe init-once access.
    private static let _shared = Mutex<EmbeddingService?>(nil)
    static var shared: EmbeddingService? {
        _shared.withLock { $0 }
    }

    /// CPU-only model — small model (6-layer MiniLM) runs efficiently on CPU.
    /// GPU/Neural Engine dispatch overhead exceeds benefit for single-item inference.
    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    private let dims: Int

    private init(model: MLModel, tokenizer: WordPieceTokenizer) {
        self.model = model
        self.tokenizer = tokenizer
        self.dims = SearchConfig.embeddingDims
    }

    /// Initialize the shared embedding service. Call once at app launch.
    /// Returns silently if model or tokenizer resources are missing (FTS-only mode).
    static func initialize() {
        guard shared == nil else { return }

        guard let tokenizer = WordPieceTokenizer() else {
            print("[Embedding] tokenizer.json not found in bundle — semantic search disabled")
            return
        }

        guard let modelURL = Bundle.main.url(forResource: "AllMiniLML6v2", withExtension: "mlmodelc") else {
            print("[Embedding] AllMiniLML6v2.mlmodelc not found in bundle — semantic search disabled")
            return
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            let model = try MLModel(contentsOf: modelURL, configuration: config)

            _shared.withLock {
                $0 = EmbeddingService(model: model, tokenizer: tokenizer)
            }
            print("[Embedding] CoreML model loaded — semantic search enabled")
        } catch {
            print("[Embedding] Failed to load CoreML model: \(error) — semantic search disabled")
        }
    }

    /// Generate an embedding vector for text.
    /// Uses CPU-only inference — efficient for small model with single-item batch.
    func embed(_ text: String) throws -> [Float] {
        let (inputIds, attentionMask) = tokenizer.tokenize(text)
        let maxTokens = SearchConfig.maxTokens

        // Create MLMultiArray inputs
        let inputIdsArray = try MLMultiArray(shape: [1, NSNumber(value: maxTokens)], dataType: .int32)
        let attentionMaskArray = try MLMultiArray(shape: [1, NSNumber(value: maxTokens)], dataType: .int32)

        for i in 0..<maxTokens {
            inputIdsArray[i] = NSNumber(value: inputIds[i])
            attentionMaskArray[i] = NSNumber(value: attentionMask[i])
        }

        let featureProvider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIdsArray),
            "attention_mask": MLFeatureValue(multiArray: attentionMaskArray)
        ])

        let prediction = try model.prediction(from: featureProvider)

        // Extract embedding from output (sentence_embedding or last_hidden_state[0])
        // Try "sentence_embedding" first (some models), then "output" / "embeddings"
        let outputArray: MLMultiArray
        if let sentenceEmb = prediction.featureValue(for: "sentence_embedding")?.multiArrayValue {
            outputArray = sentenceEmb
        } else if let output = prediction.featureValue(for: "output")?.multiArrayValue {
            outputArray = output
        } else if let embeddings = prediction.featureValue(for: "embeddings")?.multiArrayValue {
            outputArray = embeddings
        } else {
            // Try first available output
            guard let firstKey = prediction.featureNames.first,
                  let firstOutput = prediction.featureValue(for: firstKey)?.multiArrayValue else {
                throw EmbeddingError.noOutput
            }
            outputArray = firstOutput
        }

        // Extract dims-dimensional vector (may need to handle [1, dims] or [1, seqLen, dims])
        var embedding = [Float](repeating: 0, count: dims)
        let totalCount = outputArray.count

        if totalCount == dims {
            // [dims] or [1, dims]
            for i in 0..<dims {
                embedding[i] = outputArray[i].floatValue
            }
        } else if totalCount >= dims {
            // [1, seqLen, dims] — use CLS token (index 0)
            for i in 0..<dims {
                embedding[i] = outputArray[i].floatValue
            }
        }

        // L2 normalize
        var norm: Float = 0
        for v in embedding { norm += v * v }
        norm = sqrt(norm)
        if norm > 0 {
            for i in 0..<dims { embedding[i] /= norm }
        }

        return embedding
    }

    // MARK: - Text Preparation (mirrors Rust text_prep.rs)

    /// Prepare email text for embedding generation.
    /// Subject repeated for emphasis, body truncated to ~150 words.
    static func prepareEmailText(subject: String, from: String, to: String, body: String) -> String {
        let subject = subject.trimmingCharacters(in: .whitespaces)
        let from = from.trimmingCharacters(in: .whitespaces)
        let to = to.trimmingCharacters(in: .whitespaces)
        let body = body.trimmingCharacters(in: .whitespaces)

        var parts: [String] = []
        if !subject.isEmpty {
            parts.append("Subject: \(subject)")
            parts.append("Subject: \(subject)")
        }
        if !from.isEmpty { parts.append("From: \(from)") }
        if !to.isEmpty { parts.append("To: \(to)") }

        let header = parts.joined(separator: "\n")
        let bodyTruncated = truncateWords(body, maxWords: SearchConfig.bodyMaxWords)

        if bodyTruncated.isEmpty { return header }
        if header.isEmpty { return bodyTruncated }
        return "\(header)\n\n\(bodyTruncated)"
    }

    /// Truncate text to at most maxWords words.
    /// Internal (was private) so memory embedding pipeline can reuse it directly
    /// without duplicating the word-boundary scan logic.
    static func truncateWords(_ text: String, maxWords: Int) -> String {
        var words = 0
        var end = text.startIndex

        for i in text.indices {
            if text[i].isWhitespace {
                words += 1
                if words >= maxWords {
                    end = i
                    return String(text[text.startIndex..<end]).trimmingCharacters(in: .whitespaces)
                }
            }
            end = text.index(after: i)
        }

        return text.trimmingCharacters(in: .whitespaces)
    }

    enum EmbeddingError: Error {
        case noOutput
    }
}
