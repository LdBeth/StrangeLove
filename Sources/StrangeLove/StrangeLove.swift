import Foundation

/// spamoracle-compatible CLI spam filter for Emacs Wanderlust, backed by the
/// on-device Apple Intelligence model.
///
/// Wanderlust's `elsp-spamoracle` backend feeds the entire raw message on stdin
/// and invokes us as:
///   StrangeLove [-config FILE] [-f DBFILE] mark
///   StrangeLove [-config FILE] [-f DBFILE] add -v -spam
///   StrangeLove [-config FILE] [-f DBFILE] add -v -good
/// In `mark` mode the header block of stdout must contain `X-Spam: yes;` iff spam.
@main
struct StrangeLove {
    static let executableName = "StrangeLove"
    static let claudeEnvVar = "STRANGELOVE_CLAUDE"
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())

        guard let args = Arguments.parse(argv) else {
            FileHandle.standardError.write(
                Data(
                    "Usage: \(executableName) [-config FILE] [-f DBFILE] (mark | add -v (-spam|-good) | distill [--model NAME] | reembed)\n"
                        .utf8))
            exit(2)
        }

        // `distill` and `reembed` operate on the stored corpus, not on a piped
        // message.
        switch args.command {
        case .distill:
            let ok = await Distiller.run(databasePath: args.databasePath, model: args.model)
            exit(ok ? 0 : 1)
        case .reembed:
            let ok = Reembedder.run(databasePath: args.databasePath)
            exit(ok ? 0 : 1)
        default:
            break
        }

        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        let message = MessageParser.parse(stdin)

        switch args.command {
        case .mark:
            let corpus = Corpus.load(from: args.databasePath)
            let isSpam = await Classifier.classify(message, corpus: corpus)
            emitMarked(rawMessage: stdin, isSpam: isSpam)

        case .add(let spam):
            var corpus = Corpus.load(from: args.databasePath)
            // Embeddings are backfilled out-of-band by `reembed`, mirroring how
            // `distill` works: the Wanderlust-driven `add` hot path stays a
            // pure structural write with no NLEmbedding cold-load.
            corpus.add(
                Example(
                    sender: message.sender,
                    subject: message.subject,
                    snippet: message.snippet,
                    replyTo: message.replyTo,
                    returnPath: message.returnPath,
                    authSummary: message.authSummary),
                spam: spam)
            corpus.save(to: args.databasePath)

        case .distill, .reembed:
            break  // handled above
        }

        exit(0)
    }

    /// Write the verdict header followed by the original message. Prepending the
    /// header keeps it inside the header block (before the first blank line),
    /// where `elmo-spam-spamoracle-spam-header-regexp` ("^X-Spam: yes;") looks.
    private static func emitMarked(rawMessage: Data, isSpam: Bool) {
        let header = isSpam ? "X-Spam: yes; \(executableName)\n" : "X-Spam: no; \(executableName)\n"
        let out = FileHandle.standardOutput
        out.write(Data(header.utf8))
        out.write(rawMessage)
    }
}
