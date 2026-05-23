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
    static func classify(_ message: ParsedMessage, corpus: Corpus) async -> Bool {
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
