import Foundation

/// Parsed command line, modelled on the subset of the `spamoracle` CLI that
/// Wanderlust's `elsp-spamoracle` backend actually invokes
/// (see elsp-spamoracle.el `elmo-spam-spamoracle-call`).
///
/// Observed invocations:
///   PROG [-config FILE] [-f DBFILE] mark
///   PROG [-config FILE] [-f DBFILE] add -v -spam
///   PROG [-config FILE] [-f DBFILE] add -v -good
struct Arguments {
    enum Command {
        case mark
        case add(spam: Bool)
        /// Out-of-band: distill the message DB into a guide via a larger model.
        /// Never invoked by Wanderlust.
        case distill
    }

    var command: Command
    var databasePath: String
    /// Optional model override for `distill` (passed to `claude --model`).
    var model: String? = nil

    /// Default database location matches `elmo-spam-spamoracle-database-filename`
    /// (~/.elmo/.spamoracle.db).
    static var defaultDatabasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.elmo/.spamoracle.db"
    }

    /// Parse argv (excluding the program name). Returns nil if no recognizable
    /// subcommand is present.
    static func parse(_ argv: [String]) -> Arguments? {
        var dbPath: String? = nil
        var sawMark = false
        var sawAdd = false
        var sawDistill = false
        var isSpam: Bool? = nil
        var model: String? = nil

        var i = 0
        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "-config":
                // Consume the config filename; we don't use it.
                i += 1
            case "-f":
                if i + 1 < argv.count { dbPath = argv[i + 1] }
                i += 1
            case "-v":
                break  // verbosity flag, ignored
            case "mark":
                sawMark = true
            case "add":
                sawAdd = true
            case "distill":
                sawDistill = true
            case "--model":
                if i + 1 < argv.count { model = argv[i + 1] }
                i += 1
            case "-spam":
                isSpam = true
            case "-good":
                isSpam = false
            default:
                // Unknown flags/args are ignored so future spamoracle options
                // don't break classification.
                break
            }
            i += 1
        }

        let path = dbPath ?? defaultDatabasePath

        if sawAdd, let spam = isSpam {
            return Arguments(command: .add(spam: spam), databasePath: path)
        }
        if sawDistill {
            return Arguments(command: .distill, databasePath: path, model: model)
        }
        if sawMark {
            return Arguments(command: .mark, databasePath: path)
        }
        return nil
    }
}
