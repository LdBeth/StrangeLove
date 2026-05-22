# StrangeLove

Apple on-device LLM spam filter for the
[Wanderlust](https://github.com/wanderlust/wanderlust) Emacs mail client.
Drop-in replacement for the `spamoracle` binary that Wanderlust's
`elsp-spamoracle` backend shells out to, using macOS
[FoundationModels](https://developer.apple.com/documentation/foundationmodels)
instead of a Bayesian database.

## Requirements

- macOS 26 or later
- Apple Intelligence enabled (System Settings → Apple Intelligence)
- Swift 6.2 toolchain (comes with Xcode or `pkgsrc lang/swift62`)

## Build

```sh
swift build                 # debug   → .build/debug/StrangeLove
swift build -c release      # release → .build/release/StrangeLove  (use for Wanderlust)
```

## Wanderlust setup

Add to your Emacs config:

```elisp
(require 'wl-spam)
(setq elmo-spam-scheme 'spamoracle)
(setq elmo-spam-spamoracle-program
      "/path/to/eModels/.build/release/StrangeLove")
```

Wanderlust keybindings in summary buffer:

| key   | action                  |
| ----- | ----------------------- |
| `k c` | classify as spam (test) |
| `k s` | register as spam        |
| `k n` | register as good        |

## CLI reference

```
StrangeLove [-config FILE] [-f DBFILE] mark
StrangeLove [-config FILE] [-f DBFILE] add -v -spam
StrangeLove [-config FILE] [-f DBFILE] add -v -good
StrangeLove [-config FILE] [-f DBFILE] distill [--model NAME]
```

- **`mark`** — classify a raw email piped on stdin. Prints the message back with
  an `X-Spam: yes; StrangeLove` or `X-Spam: no; StrangeLove` header prepended.
- **`add -v -spam` / `add -v -good`** — learn a message as spam or ham. The
  sender, subject, and body snippet are stored as an example. Stdout is ignored.
- **`distill`** — (our subcommand, never called by Wanderlust) summarizes all
  stored examples into a compact natural-language classification guide by
  shelling out to the `claude` CLI. See below.

Default database: `~/.elmo/.spamoracle.db` (same location Wanderlust's original
spamoracle uses).

## How classification works

**Learning pipeline (out-of-band):**

1. `add` accumulates labelled examples (sender, subject, 200-char body snippet)
   in a JSON corpus, FIFO-capped at 200 per category.
2. `distill` sends the full corpus to `claude -p` to produce a concise
   natural-language guide (~300 words) describing _this user's_ spam vs. ham
   patterns: sender domains, subject patterns, topics, tone, link styles.
3. The guide is saved as `Corpus.digest` alongside the examples.

**Classification hot path (`mark`, offline):**

1. The raw email is parsed: RFC 2047-encoded headers, MIME multipart traversal,
   text/plain extraction (HTML fallback), quoted-printable and base64 decoding.
2. The on-device `SystemLanguageModel` is prompted with the distilled guide (or
   a few raw examples as fallback) and asked for a one-word verdict: `SPAM` or
   `HAM`.
3. The `X-Spam:` header is prepended to the original bytes and written to
   stdout.

**Why distill?** The on-device model is weak at in-context learning from raw
examples — feeding it stored messages directly _lowers_ accuracy. A distilled
guide articulating the patterns works much better.

**Fail-open.** If the model is unavailable (downloading, device not eligible) or
errors, classification always returns "not spam" so legitimate mail is never
lost.

## Architecture

```
Sources/StrangeLove/
├── StrangeLove.swift   — @main entry point, stdin/stdout, argv dispatch
├── Arguments.swift     — spamoracle CLI parser
├── MessageParser.swift — RFC 822/2047/MIME parsing
├── Classifier.swift    — on-device model wrapper (instructions + prompt + interpret)
├── Distiller.swift     — distill subcommand (claude CLI integration)
└── Corpus.swift        — JSON corpus store + Digest model
```

## Environment

- `STRANGELOVE_CLAUDE` — path to a `claude` binary for `distill` (default:
  `claude` resolved from `PATH`).

## License

MIT
