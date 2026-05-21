import Foundation

/// Distills the message DB into a compact, natural-language classification guide
/// by shelling out to a larger model (the `claude` CLI in headless `-p` mode).
///
/// This is the out-of-band `distill` subcommand: run manually or from cron / an
/// Emacs hook, never by Wanderlust. `mark`/`add` never reach this code, so the
/// classification hot path makes no network calls. The resulting guide is the
/// only thing injected into the on-device classifier (see `Classifier`), which
/// the small model follows far more reliably than it imitates raw examples.
enum Distiller {
    /// Cap on the stored guide so the on-device prompt stays small.
    static let guideLimit = 4000

    /// Returns true on success (guide generated and saved).
    static func run(databasePath: String, model: String?) async -> Bool {
        var corpus = Corpus.load(from: databasePath)
        guard !corpus.spam.isEmpty || !corpus.good.isEmpty else {
            warn("nothing to distill: corpus has no examples at \(databasePath).")
            return false
        }

        let prompt = distillPrompt(corpus: corpus)
        let guide: String
        do {
            guide = try invokeClaude(prompt: prompt, model: model)
        } catch {
            warn("distill failed (\(error)); leaving existing guide untouched.")
            return false
        }

        let trimmed = guide.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            warn("distill produced an empty guide; leaving existing guide untouched.")
            return false
        }

        corpus.digest = Digest(text: String(trimmed.prefix(guideLimit)),
                               generatedAt: Date(),
                               sourceHash: corpus.corpusHash(),
                               exampleCount: corpus.spam.count + corpus.good.count)
        corpus.save(to: databasePath)
        FileHandle.standardError.write(Data(
            "EModels: distilled \(corpus.spam.count) spam / \(corpus.good.count) good examples into a guide.\n".utf8))
        return true
    }

    // MARK: - Prompt

    private static func distillPrompt(corpus: Corpus) -> String {
        var text = """
        You are tuning a personal email spam filter. Below are messages the user \
        has labelled SPAM (junk/scams/phishing/unsolicited bulk or marketing) and \
        LEGITIMATE (ham). Write a concise guide that a small, less capable model \
        can follow to classify *this user's* incoming mail the same way.

        Describe the concrete, observable traits that separate this user's spam \
        from their legitimate mail: sender names/domains, subject patterns, \
        topics, link styles, tone, language. Call out non-obvious rules (e.g. if \
        the user treats branded marketing newsletters from real companies as \
        spam). Keep it under ~300 words, plain prose or bullet points, no preamble \
        or sign-off. Output only the guide.

        """

        if !corpus.spam.isEmpty {
            text += "\n=== Messages the user labelled SPAM ===\n"
            for ex in corpus.spam { text += exampleLine(ex) + "\n" }
        }
        if !corpus.good.isEmpty {
            text += "\n=== Messages the user labelled LEGITIMATE ===\n"
            for ex in corpus.good { text += exampleLine(ex) + "\n" }
        }
        return text
    }

    private static func exampleLine(_ ex: Example) -> String {
        "- From: \(ex.sender) | Subject: \(ex.subject) | \(ex.snippet)"
    }

    // MARK: - claude CLI

    /// Run `claude -p [--model NAME]` with the prompt on stdin, returning stdout.
    /// The binary is `$EMODELS_CLAUDE` if set, else `claude` resolved on PATH.
    private static func invokeClaude(prompt: String, model: String?) throws -> String {
        let process = Process()
        var arguments = ["-p"]
        if let model { arguments += ["--model", model] }

        if let override = ProcessInfo.processInfo.environment["EMODELS_CLAUDE"], !override.isEmpty {
            process.executableURL = URL(fileURLWithPath: override)
            process.arguments = arguments
        } else {
            // Resolve `claude` via PATH without assuming an absolute location.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["claude"] + arguments
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError

        try process.run()
        // Feed the (potentially large) prompt on stdin to avoid argv size limits.
        stdinPipe.fileHandleForWriting.write(Data(prompt.utf8))
        stdinPipe.fileHandleForWriting.closeFile()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DistillError.claudeFailed(status: process.terminationStatus)
        }
        return String(decoding: outData, as: UTF8.self)
    }

    enum DistillError: Error, CustomStringConvertible {
        case claudeFailed(status: Int32)
        var description: String {
            switch self {
            case .claudeFailed(let status): return "claude CLI exited with status \(status)"
            }
        }
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data(("EModels: " + message + "\n").utf8))
    }
}
