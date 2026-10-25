import Foundation
import NaturalLanguage

/// On-device text embeddings for "Resume topics", kept apart from the model
/// so the NaturalLanguage dependency stays in one small file.
///
/// Returns nil whenever embeddings are unavailable — missing model assets
/// (never downloaded here; that would be a network surprise for a local
/// feature), unsupported text, or any error. Callers fall back to
/// title-term clustering, so topics degrade honestly instead of vanishing
/// or blocking.
enum NLTopicEmbedder {
    /// Mean-pooled contextual vectors, one per text, in input order.
    static func embed(_ texts: [String]) async -> [[Double]]? {
        // NLContextualEmbedding is synchronous; keep it off the main actor.
        await Task.detached(priority: .utility) { () -> [[Double]]? in
            guard let model = NLContextualEmbedding(language: .english),
                  model.hasAvailableAssets else { return nil }
            var vectors: [[Double]] = []
            for text in texts.prefix(60) {
                let clipped = String(text.prefix(1000))
                guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let result = try? model.embeddingResult(for: clipped, language: .english) else {
                    return nil
                }
                var sum: [Double] = []
                var count = 0
                result.enumerateTokenVectors(in: clipped.startIndex..<clipped.endIndex) { values, _ in
                    guard !values.isEmpty else { return true }
                    if sum.isEmpty {
                        sum = values
                    } else if sum.count == values.count {
                        for index in sum.indices { sum[index] += values[index] }
                    } else {
                        return true
                    }
                    count += 1
                    return true
                }
                guard count > 0, !sum.isEmpty else { return nil }
                vectors.append(sum.map { $0 / Double(count) })
            }
            return vectors.isEmpty ? nil : vectors
        }.value
    }
}
