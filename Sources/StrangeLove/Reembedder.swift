import Foundation

/// Computes (or refreshes) sentence embeddings for every example in the corpus.
///
/// This is the out-of-band `reembed` subcommand: run manually or from cron / an
/// Emacs hook, never by Wanderlust. Keeping NLEmbedding off the `add` hot path
/// avoids paying the encoder's cold-load latency on every Wanderlust-spawned
/// process. Run `reembed` after adding new examples, or after an OS update that
/// may have changed the on-device embedding models.
enum Reembedder {
    /// Returns true on success. Saves the corpus only when at least one
    /// embedding was filled in, so a no-op run leaves the file mtime alone.
    static func run(databasePath: String) -> Bool {
        var corpus = Corpus.load(from: databasePath)
        var filled = 0
        var skipped = 0

        fill(&corpus.spam, filled: &filled, skipped: &skipped)
        fill(&corpus.good, filled: &filled, skipped: &skipped)

        if filled > 0 {
            corpus.save(to: databasePath)
        }
        FileHandle.standardError.write(
            Data(
                "\(StrangeLove.executableName): reembed filled \(filled), skipped \(skipped) (no encoder for detected language); \(corpus.spam.count) spam / \(corpus.good.count) good total.\n"
                    .utf8))
        return true
    }

    private static func fill(
        _ list: inout [Example],
        filled: inout Int,
        skipped: inout Int
    ) {
        for i in list.indices {
            if let emb = Embedder.embed(list[i].subject + "\n" + list[i].snippet) {
                list[i].embedding = emb.vector
                list[i].embeddingLanguage = emb.language
                filled += 1
            } else {
                skipped += 1
            }
        }
    }
}
