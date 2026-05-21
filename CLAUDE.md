# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`EModels` is a Swift command-line spam filter for the Emacs **Wanderlust** mail
client. It is a drop-in replacement for the `spamoracle` program that
Wanderlust's `elsp-spamoracle` backend shells out to, but classifies mail with
Apple's on-device `FoundationModels` LLM instead of a Bayesian database.
Requires macOS 26 with Apple Intelligence enabled.

## Build & run

```sh
swift build                 # debug -> .build/debug/EModels
swift build -c release      # release -> .build/release/EModels (used by Wanderlust)
```

There are no automated tests; verify by piping a raw email to the binary:

```sh
# classify (header block of stdout gets X-Spam: yes; iff spam)
printf 'From: x\nSubject: Win a FREE iPhone!!!\n\nClaim your prize\n' \
  | .build/debug/EModels -f /tmp/spam.db mark | head -1
# learn
... | .build/debug/EModels -f /tmp/spam.db add -v -spam
... | .build/debug/EModels -f /tmp/spam.db add -v -good
# distill the learned examples into a classification guide (out-of-band; needs `claude` CLI)
.build/debug/EModels -f /tmp/spam.db distill [--model NAME]
```

The host has pkgsrc (no Homebrew); ask the user before installing toolchain packages.

## The Wanderlust contract (do not break)

This binary's CLI must stay compatible with how `elsp-spamoracle.el`'s
`elmo-spam-spamoracle-call` invokes it (see the user's Wanderlust install under
`~/.emacs.d/elpa/wanderlust-*/elsp-spamoracle.el`). The **entire raw message is
fed on stdin** and we are called three ways:

| argv tail | meaning | required output |
|-----------|---------|-----------------|
| `mark` | classify | echo a header block containing `X-Spam: yes;` iff spam (matched by `^X-Spam: yes;`) |
| `add -v -spam` | learn as spam | stdout ignored |
| `add -v -good` | learn as good | stdout ignored |

Each may be preceded by `-config FILE` (ignored) and `-f DBFILE`. Exit code is
not inspected by Wanderlust; we exit 0 on success, 2 on bad args.

The `distill` subcommand (below) is **ours alone** — Wanderlust never calls it.

## How classification is steered: distilled guide, not raw few-shot

The on-device `FoundationModels` model is weak at in-context learning from raw
examples; feeding it the learned messages directly *lowered* accuracy on a real
spam corpus (66% → 27%). So learning and prompt-synthesis are separated:

1. `add` accumulates raw labelled examples in the message DB (`Corpus`).
2. `distill` (out-of-band: manual, cron, or an Emacs hook — **never** Wanderlust)
   shells out to the `claude` CLI (`claude -p`, prompt on stdin) to summarize the
   whole DB into a compact natural-language **guide** describing *this user's*
   spam vs. ham, stored as `Corpus.digest`.
3. `mark` injects `digest.text` into the classifier instructions (no network).
   With a distilled guide, held-out detection rose to ~97% at 0 false positives.

If no digest exists yet, `mark` falls back to a few raw few-shot examples.
`distill` uses `$EMODELS_CLAUDE` for the binary if set, else `claude` on PATH.

## Architecture

Single executable target, files under `Sources/EModels/`, each one concern:

- **`EModels.swift`** — `@main async`. Reads stdin, parses argv, dispatches. In
  `mark` it prepends the `X-Spam:` header to the *original* bytes (keeping it
  inside the header block); `add` appends an example; `distill` operates on the
  stored corpus and reads no message from stdin.
- **`Arguments.swift`** — parses the spamoracle grammar above plus our `distill`
  subcommand (`--model` optional); unknown flags are ignored on purpose so new
  spamoracle options don't break us.
- **`MessageParser.swift`** — turns raw RFC 822/MIME bytes into
  `ParsedMessage(sender, subject, body)`: RFC 2047 header decode, MIME walk to
  the `text/plain` part (HTML fallback), quoted-printable/base64, charset
  handling, HTML strip, body truncation. NB: multipart walk skips the preamble
  (parts before the first boundary) and headerless/empty parts.
- **`Classifier.swift`** — wraps `FoundationModels`. Builds a
  `LanguageModelSession` whose instructions carry the distilled guide (or raw
  few-shot fallback), asks for a one-word `SPAM`/`HAM` answer, and parses it.
- **`Distiller.swift`** — the `distill` path: builds the summarization prompt
  from the corpus, runs the `claude` CLI, saves the guide into `Corpus.digest`.
  Failures are non-fatal and never corrupt the DB (atomic write only on success).
- **`Corpus.swift`** — `Codable` JSON store at the `-f` path (default
  `~/.elmo/.spamoracle.db`): FIFO-capped example lists plus the optional
  `digest`; `corpusHash()` stamps the digest so `mark` can warn when it's stale.
  Atomic write.

## Key invariants

- **Fail-open.** If the model is unavailable or generation throws, classify as
  *not* spam and emit only a warning to stderr — never lose legitimate mail to a
  filter error. Keep this behavior in any `Classifier` change.
- **No guided-generation macros.** `@Generable`/`@Guide` require the
  `FoundationModelsMacros` compiler plugin, which is absent from this toolchain
  (build fails: "plugin for module 'FoundationModelsMacros' not found"). Use
  plain text responses and parse them; do not reintroduce the macros.
- The corpus JSON format is private to this tool (Wanderlust treats the `-f`
  file as opaque), so it can change freely — but keep writes atomic, since
  Wanderlust may call `add` repeatedly.
- **Only `distill` may reach the network / spawn `claude`.** `mark` and `add`
  must stay fast and offline (the `Distiller` is reached solely from the
  `.distill` dispatch branch). Don't move distillation into the `mark`/`add`
  hot paths that Wanderlust drives.
