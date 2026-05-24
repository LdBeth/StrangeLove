import Foundation
import FoundationModels

/// Classifies a parsed message as spam or ham using Apple's on-device model,
/// biased by the few-shot examples in the corpus. Fails open (returns false /
/// not-spam) whenever the model is unavailable or errors.
///
/// We constrain the model to a one-word answer ("SPAM"/"HAM") and parse it,
/// rather than using the `@Generable` guided-generation macros, which require a
/// compiler-plugin not present in every Swift toolchain.
enum Classifier {
    /// k-NN fast-path policy. **Asymmetric on purpose**: the project's hard
    /// invariant is fail-open (never flag legitimate mail as spam), so a SPAM
    /// short-circuit that bypasses the LLM is much costlier than a HAM one. We
    /// therefore require a tighter, larger SPAM neighbourhood than HAM:
    ///   - HAM verdict: k=3 all-agree, mean cosine ≥ 0.75.
    ///   - SPAM verdict: k=5 all-agree, mean cosine ≥ 0.88.
    /// Anything else defers to the LLM, which keeps the FP discipline of the
    /// distilled-guide path. The embedding ignores sender/Reply-To/auth
    /// headers the LLM weighs, so over-trusting it on SPAM would regress FPs.
    static let hamNeighbours = 3
    static let hamThreshold: Float = 0.75
    static let spamNeighbours = 5
    static let spamThreshold: Float = 0.88

    static func classify(_ message: ParsedMessage, corpus: Corpus) async -> Bool {
        if let verdict = fastPathVerdict(for: message, corpus: corpus) {
            return verdict
        }

        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            warn("Apple Intelligence unavailable: device not eligible; treating as not spam.")
            return false
        case .unavailable(.appleIntelligenceNotEnabled):
            warn("Apple Intelligence not enabled; treating as not spam.")
            return false
        case .unavailable(.modelNotReady):
            warn("Model not ready (still downloading?); treating as not spam.")
            return false
        case .unavailable(let other):
            warn("Model unavailable (\(other)); treating as not spam.")
            return false
        }

        let session = LanguageModelSession(instructions: instructions(corpus: corpus))
        let prompt = userPrompt(for: message)

        // We only need a single word ("SPAM"/"HAM"), so cap generation hard and
        // run greedily for a deterministic, fast verdict.
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 5)

        do {
            let response = try await session.respond(to: prompt, options: options)
            return interpret(response.content)
        } catch {
            warn("Classification failed (\(error)); treating as not spam.")
            return false
        }
    }

    /// Sentence-embedding k-NN fast-path. Returns the verdict when one of the
    /// asymmetric conditions fires; nil to defer to the LLM. Always logs the
    /// neighbourhood so the thresholds can be tuned from real traffic.
    private static func fastPathVerdict(
        for message: ParsedMessage,
        corpus: Corpus
    ) -> Bool? {
        guard let query = Embedder.embed(message.subject + "\n" + message.snippet) else {
            warn("fast-path skipped: no sentence encoder for detected language.")
            return nil
        }

        // Fetch enough neighbours for the larger (SPAM) check; the HAM check
        // reads only the first `hamNeighbours` of the same sorted list.
        let neighbours = Embedder.topNeighbours(
            query: query, corpus: corpus, k: spamNeighbours)
        let neighbourhood = formatNeighbours(neighbours)

        let sizes = Embedder.partitionSizes(corpus: corpus, language: query.language)

        // HAM short-circuit (looser)
        if let (verdict, mean) = tryPath(
            k: hamNeighbours, threshold: hamThreshold,
            targetIsSpam: false, counterweight: sizes.spam,
            neighbours: neighbours)
        {
            warn(
                "kNN lang=\(query.language) HAM-path k=\(hamNeighbours) "
                    + String(format: "mean=%.3f", mean)
                    + " pool=\(sizes.spam)S/\(sizes.ham)H"
                    + " neighbours=[\(neighbourhood)]."
            )
            return verdict
        }

        // SPAM short-circuit (stricter)
        if let (verdict, mean) = tryPath(
            k: spamNeighbours, threshold: spamThreshold,
            targetIsSpam: true, counterweight: sizes.ham,
            neighbours: neighbours)
        {
            warn(
                "kNN lang=\(query.language) SPAM-path k=\(spamNeighbours) "
                    + String(format: "mean=%.3f", mean)
                    + " pool=\(sizes.spam)S/\(sizes.ham)H"
                    + " neighbours=[\(neighbourhood)]."
            )
            return verdict
        }

        warn(
            "kNN lang=\(query.language) deferring to LLM; "
                + "pool=\(sizes.spam)S/\(sizes.ham)H "
                + "neighbours=[\(neighbourhood)]."
        )
        return nil
    }

    /// One asymmetric k-NN check. Returns `(verdict, meanSimilarity)` when the
    /// top-`k` neighbours all agree on `targetIsSpam` with mean ≥ threshold AND
    /// the opposing class has ≥`k` same-language examples in the pool
    /// (counterweight). Returns nil to defer.
    private static func tryPath(
        k: Int,
        threshold: Float,
        targetIsSpam: Bool,
        counterweight: Int,
        neighbours: [Embedder.Neighbour]
    ) -> (verdict: Bool, mean: Float)? {
        let top = neighbours.prefix(k)
        guard top.count == k,
            top.allSatisfy({ $0.isSpam == targetIsSpam }),
            counterweight >= k
        else { return nil }
        let mean = top.reduce(Float(0)) { $0 + $1.similarity } / Float(top.count)
        guard mean >= threshold else { return nil }
        return (targetIsSpam, mean)
    }

    private static func formatNeighbours(_ ns: [Embedder.Neighbour]) -> String {
        ns.map { String(format: "%.3f(%@)", $0.similarity, $0.isSpam ? "S" : "H") }
            .joined(separator: " ")
    }

    /// Map the model's free-text answer to a boolean. Fail-open: only an explicit
    /// spam signal yields true.
    private static func interpret(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard let first = lower.range(of: #"\b(spam|ham|yes|no)\b"#, options: .regularExpression)
        else {
            return false
        }
        let word = lower[first]
        return word == "spam" || word == "yes"
    }

    // MARK: - Prompt construction

    private static func instructions(corpus: Corpus) -> String {
        var text = """
            You are an email spam classifier. Decide whether a single email message \
            is spam (junk, scams, phishing, or unsolicited bulk/marketing mail) or \
            legitimate (ham). Base your decision on the sender, subject, and body. \
            Reply with exactly one word: SPAM or HAM. Do not explain.

            Fraud signals to weight heavily: Reply-To or Return-Path whose domain \
            disagrees with From; SPF, DKIM, or DMARC marked fail/softfail/none on a \
            mail claiming to be from a real brand; lookalike or unrelated domains in \
            the From line; bait links where the visible anchor text disagrees with \
            the bracketed [\u{2192} URL] that follows it (e.g. text says "paypal.com" \
            but the URL points to a different host).
            """

        // Preferred: the guide distilled from the message DB by a larger model
        // (`StrangeLove distill`). A small model follows articulated guidance far
        // better than it imitates raw examples, so the guide replaces few-shot.
        if let digest = corpus.digest {
            if digest.sourceHash != corpus.corpusHash() {
                warn(
                    "classification guide is stale (corpus changed since last distill); using it anyway."
                )
            }
            text += "\n\nGuide to this user's spam vs. legitimate mail:\n" + digest.text
            return text
        }

        // Fallback until the first `distill`: a few raw examples per category.
        let spamExamples = corpus.recentSpam()
        let goodExamples = corpus.recentGood()

        if !spamExamples.isEmpty {
            text += "\n\nExamples the user has marked as SPAM:"
            text += spamExamples.map { "\n- \(exampleLine($0))" }.joined()
        }
        if !goodExamples.isEmpty {
            text += "\n\nExamples the user has marked as LEGITIMATE (not spam):"
            text += goodExamples.map { "\n- \(exampleLine($0))" }.joined()
        }
        return text
    }

    private static func exampleLine(_ ex: Example) -> String {
        var parts = ["From: \(ex.sender)"]
        if !ex.replyTo.isEmpty { parts.append("Reply-To: \(ex.replyTo)") }
        if !ex.returnPath.isEmpty { parts.append("Return-Path: \(ex.returnPath)") }
        if !ex.authSummary.isEmpty { parts.append("Auth: \(ex.authSummary)") }
        parts.append("Subject: \(ex.subject)")
        parts.append(ex.snippet)
        return parts.joined(separator: " | ")
    }

    private static func userPrompt(for message: ParsedMessage) -> String {
        var text = "Classify this email.\n\nFrom: \(message.sender)"
        if !message.replyTo.isEmpty {
            text += "\nReply-To: \(message.replyTo)"
        }
        if !message.returnPath.isEmpty {
            text += "\nReturn-Path: \(message.returnPath)"
        }
        if !message.authSummary.isEmpty {
            text += "\nAuthentication: \(message.authSummary)"
        }
        text += "\nSubject: \(message.subject)\n\nBody:\n\(message.body)"
        return text
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(
            Data(("\(StrangeLove.executableName): " + message + "\n").utf8))
    }
}
