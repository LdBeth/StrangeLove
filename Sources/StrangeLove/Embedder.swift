import Foundation
import NaturalLanguage

/// Sentence-embedding fast-path used by `Classifier` to short-circuit the
/// FoundationModels round-trip when an incoming message clearly matches stored
/// examples. Purely on-device, no Apple-Intelligence requirement.
///
/// Different-language sentence-embedding models inhabit different vector
/// spaces, so a Japanese vector compared against an English one is noise; the
/// k-NN partitions the corpus on `embeddingLanguage` to avoid that.
enum Embedder {
    struct Embedding {
        var vector: [Float]
        /// `NLLanguage.rawValue` (e.g. "en", "ja", "zh-Hans") of the model that
        /// produced `vector`.
        var language: String
    }

    struct Neighbour {
        var similarity: Float
        var isSpam: Bool
    }

    /// Embed `text` with the sentence encoder for its detected dominant
    /// language. Returns nil whenever the fast-path should be skipped for this
    /// message: language undetected, no encoder for that language on this host,
    /// or the encoder returned no vector.
    static func embed(_ text: String) -> Embedding? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage,
            let model = NLEmbedding.sentenceEmbedding(for: language),
            let vector = model.vector(for: text)
        else {
            return nil
        }
        return Embedding(
            vector: vector.map { Float($0) },
            language: language.rawValue)
    }

    /// Return the up to `k` highest-cosine neighbours from the same-language
    /// partition of the corpus, sorted by similarity descending. The classifier
    /// applies its own voting policy on top of this raw result so it can log
    /// the neighbourhood whether or not it ends up firing.
    static func topNeighbours(
        query: Embedding,
        corpus: Corpus,
        k: Int
    ) -> [Neighbour] {
        var pool: [Neighbour] = []
        pool.reserveCapacity(corpus.spam.count + corpus.good.count)
        collect(from: corpus.spam, isSpam: true, query: query, into: &pool)
        collect(from: corpus.good, isSpam: false, query: query, into: &pool)
        pool.sort { $0.similarity > $1.similarity }
        return Array(pool.prefix(k))
    }

    /// Count examples in each category that have an embedding tagged with
    /// `language`. Used by the classifier's counterweight check: an
    /// "all-agree" verdict is only informative when the opposing class has
    /// enough candidates to have competed for the top-k slots.
    static func partitionSizes(corpus: Corpus, language: String) -> (spam: Int, ham: Int) {
        func count(_ examples: [Example]) -> Int {
            examples.reduce(0) { acc, ex in
                acc + ((ex.embedding != nil && ex.embeddingLanguage == language) ? 1 : 0)
            }
        }
        return (spam: count(corpus.spam), ham: count(corpus.good))
    }

    /// Cosine similarity. NLEmbedding vectors are length-normalized in
    /// practice, but we still divide by the magnitudes to be defensive against
    /// model changes and against Float→Double round-trips through JSON.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    private static func collect(
        from examples: [Example],
        isSpam: Bool,
        query: Embedding,
        into pool: inout [Neighbour]
    ) {
        for ex in examples {
            guard let vec = ex.embedding,
                ex.embeddingLanguage == query.language
            else { continue }
            pool.append(
                Neighbour(
                    similarity: cosine(query.vector, vec),
                    isSpam: isSpam))
        }
    }
}
