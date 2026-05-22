import CryptoKit
import Foundation

/// A single learned message used as a few-shot example.
struct Example: Codable {
    var sender: String
    var subject: String
    var snippet: String
}

/// A classification guide distilled from the message DB by a larger model
/// (Claude, via `StrangeLove distill`). Injected into the on-device classifier's
/// instructions in place of raw few-shot examples.
struct Digest: Codable {
    var text: String
    var generatedAt: Date
    /// Hash of the examples this guide was distilled from, so `mark` can warn
    /// when the guide is stale relative to the current corpus.
    var sourceHash: String
    var exampleCount: Int
}

/// The persisted spam/ham corpus ("message DB"), stored as JSON at the `-f`
/// database path.
///
/// We control both ends of this file (Wanderlust treats it as opaque), so JSON
/// is fine even though the real spamoracle uses a binary database. Examples are
/// the raw learning material; `distill` summarizes them into `digest`, which is
/// what actually steers classification.
struct Corpus: Codable {
    var spam: [Example] = []
    var good: [Example] = []
    /// Guide distilled from the examples; `nil` until `distill` has run.
    var digest: Digest? = nil

    /// Maximum number of examples retained per category. Examples now feed the
    /// distiller (a large model) rather than the on-device prompt, so we keep a
    /// long history; richer history yields a better guide.
    static let maxPerCategory = 200

    /// Number of examples of each category injected into a prompt when no
    /// distilled guide is available yet (fallback few-shot).
    static let promptSample = 6

    static func load(from path: String) -> Corpus {
        guard let data = FileManager.default.contents(atPath: path),
            let corpus = try? JSONDecoder().decode(Corpus.self, from: data)
        else {
            return Corpus()
        }
        return corpus
    }

    /// Append an example to the chosen category, trimming oldest beyond the cap.
    mutating func add(_ example: Example, spam isSpam: Bool) {
        if isSpam {
            Corpus.appendCapped(&spam, example)
        } else {
            Corpus.appendCapped(&good, example)
        }
    }

    /// Append, then keep only the most-recent `maxPerCategory` (i.e.
    /// `suffix(maxPerCategory)` of the appended list — the same "keep recent N"
    /// operation `recentSpam`/`recentGood` use, done in place to avoid realloc).
    private static func appendCapped(_ list: inout [Example], _ example: Example) {
        list.append(example)
        if list.count > maxPerCategory {
            list.removeFirst(list.count - maxPerCategory)
        }
    }

    func save(to path: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true)
        // Atomic write tolerates Wanderlust's sequential concurrent calls.
        try? data.write(to: url, options: .atomic)
    }

    /// The most recent examples from each category, for fallback few-shot
    /// prompting when no distilled guide exists.
    func recentSpam() -> [Example] { Array(spam.suffix(Corpus.promptSample)) }
    func recentGood() -> [Example] { Array(good.suffix(Corpus.promptSample)) }

    /// A stable hash of all examples, used to stamp a `Digest` and to detect
    /// when the stored guide has fallen behind newly-learned mail.
    func corpusHash() -> String {
        func line(_ e: Example) -> String { "\(e.sender)\u{1}\(e.subject)\u{1}\(e.snippet)" }
        let joined =
            "SPAM\n" + spam.map(line).joined(separator: "\n")
            + "\nGOOD\n" + good.map(line).joined(separator: "\n")
        let hash = SHA256.hash(data: Data(joined.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
