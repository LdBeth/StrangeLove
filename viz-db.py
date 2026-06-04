#!/usr/bin/env python3
"""Visualize a StrangeLove spam database (JSON corpus)."""

import json
import math
import os
import sys
import hashlib
import textwrap
from datetime import datetime, timezone

# ── ANSI colours ────────────────────────────────────────────────────────────
RESET  = "\033[0m"
BOLD   = "\033[1m"
DIM    = "\033[2m"
RED    = "\033[31m"
GREEN  = "\033[32m"
YELLOW = "\033[33m"
CYAN   = "\033[36m"
WHITE  = "\033[37m"

def bold(s):    return f"{BOLD}{s}{RESET}"
def dim(s):     return f"{DIM}{s}{RESET}"
def red(s):     return f"{RED}{s}{RESET}"
def green(s):   return f"{GREEN}{s}{RESET}"
def yellow(s):  return f"{YELLOW}{s}{RESET}"
def cyan(s):    return f"{CYAN}{s}{RESET}"

# ── helpers ──────────────────────────────────────────────────────────────────

def bar(count, total, width=24, fill="█", empty="░"):
    if total == 0:
        filled = 0
    else:
        filled = round(count / total * width)
    return fill * filled + dim(empty * (width - filled))

def trunc(s, n=72):
    s = s.replace("\n", " ").strip()
    return s if len(s) <= n else s[:n - 1] + "…"

def corpus_hash(spam, good):
    def line(e):
        return "\x01".join([
            e.get("sender",""), e.get("subject",""), e.get("snippet",""),
            e.get("replyTo",""), e.get("returnPath",""), e.get("authSummary",""),
        ])
    joined = "SPAM\n" + "\n".join(line(e) for e in spam) \
           + "\nGOOD\n" + "\n".join(line(e) for e in good)
    return hashlib.sha256(joined.encode()).hexdigest()

def fmt_date(val):
    try:
        if isinstance(val, (int, float)):
            # Swift JSONEncoder stores Date as timeIntervalSinceReferenceDate (epoch 2001-01-01)
            dt = datetime.fromtimestamp(val + 978307200, tz=timezone.utc)
        else:
            dt = datetime.fromisoformat(str(val).replace("Z", "+00:00"))
        return dt.astimezone().strftime("%Y-%m-%d %H:%M %Z")
    except Exception:
        return str(val)

def lang_stats(examples):
    langs = {}
    no_emb = 0
    for e in examples:
        if e.get("embedding") is None:
            no_emb += 1
        else:
            lang = e.get("embeddingLanguage") or "?"
            langs[lang] = langs.get(lang, 0) + 1
    return langs, no_emb

def cosine_sim(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    return dot / (na * nb) if na and nb else 0.0

# ── section printers ─────────────────────────────────────────────────────────

WRAP = 76

def rule(title=""):
    if title:
        pad = (WRAP - len(title) - 2) // 2
        print(f"{dim('─' * pad)} {bold(title)} {dim('─' * (WRAP - pad - len(title) - 2))}")
    else:
        print(dim("─" * WRAP))

def print_summary(spam, good, digest):
    total = len(spam) + len(good)
    rule("Summary")
    print(f"  Spam examples : {bold(str(len(spam))):>6}  {red(bar(len(spam), total, 20))}")
    print(f"  Ham  examples : {bold(str(len(good))):>6}  {green(bar(len(good), total, 20))}")
    print(f"  Total         : {bold(str(total)):>6}")
    print()

    # embedding coverage per class
    for label, examples, color in [("spam", spam, red), ("ham ", good, green)]:
        langs, no_emb = lang_stats(examples)
        embedded = len(examples) - no_emb
        pct = embedded / len(examples) * 100 if examples else 0
        lang_str = ", ".join(f"{k}:{v}" for k, v in sorted(langs.items()))
        print(f"  {color(label)} embeddings: {embedded}/{len(examples)} ({pct:.0f}%)"
              + (f"  [{lang_str}]" if lang_str else ""))

def print_digest(digest, spam, good):
    rule("Digest")
    if not digest:
        print(f"  {yellow('No digest yet')} — run `StrangeLove distill` to generate one.")
        return

    gen_at = fmt_date(digest.get("generatedAt","?"))
    ex_cnt = digest.get("exampleCount", "?")
    src_hash = digest.get("sourceHash","")
    cur_hash = corpus_hash(spam, good)
    stale = src_hash and cur_hash and src_hash != cur_hash

    status = red("STALE — re-run distill") if stale else green("fresh")
    print(f"  Generated  : {gen_at}  [{status}]")
    print(f"  Based on   : {ex_cnt} examples")
    if stale:
        print(f"  {dim('stored hash:')} {src_hash[:16]}…")
        print(f"  {dim('current hash:')} {cur_hash[:16]}…")
    print()
    text = digest.get("text","")
    for line in textwrap.wrap(text, width=WRAP - 4):
        print(f"  {line}")

def print_examples(examples, label, color, n=8):
    rule(f"Recent {label} ({min(n, len(examples))} of {len(examples)})")
    recent = examples[-n:]
    for i, e in enumerate(recent, 1):
        sender  = trunc(e.get("sender",""), 40)
        subject = trunc(e.get("subject",""), 50)
        snippet = trunc(e.get("snippet",""), 72)
        reply   = e.get("replyTo","")
        auth    = e.get("authSummary","")
        has_emb = "●" if e.get("embedding") else dim("○")
        lang    = e.get("embeddingLanguage") or ""

        print(f"  {color(str(i).rjust(2))}. {bold(subject)}")
        print(f"     {dim('from:')} {sender}"
              + (f"  {dim('reply-to:')} {trunc(reply,30)}" if reply else ""))
        if auth:
            print(f"     {dim('auth:')} {trunc(auth,65)}")
        print(f"     {dim('↳')} {snippet}")
        emb_tag = f" {has_emb}{dim(lang)}" if lang else f" {has_emb}"
        print(f"     {dim('emb:')}{emb_tag}")
        if i < len(recent):
            print()

def print_topk_neighbours(spam, good, k=3):
    """Show which spam/ham pairs are most similar by embedding cosine sim."""
    s_emb = [(e, e["embedding"]) for e in spam if e.get("embedding")]
    g_emb = [(e, e["embedding"]) for e in good if e.get("embedding")]
    if not s_emb or not g_emb:
        return
    rule("Closest spam↔ham pairs (embedding cosine similarity)")
    pairs = []
    for se, sv in s_emb:
        for ge, gv in g_emb:
            if se.get("embeddingLanguage") != ge.get("embeddingLanguage"):
                continue
            sim = cosine_sim(sv, gv)
            pairs.append((sim, se, ge))
    pairs.sort(reverse=True)
    for sim, se, ge in pairs[:k]:
        print(f"  {yellow(f'{sim:.3f}')}  spam: {trunc(se.get('subject',''),36)}"
              f"  ↔  ham: {trunc(ge.get('subject',''),36)}")

# ── main ──────────────────────────────────────────────────────────────────────

def main():
    default_path = os.path.expanduser("~/.elmo/.spamoracle.db")
    path = sys.argv[1] if len(sys.argv) > 1 else default_path

    if not os.path.exists(path):
        print(red(f"Database not found: {path}"), file=sys.stderr)
        sys.exit(1)

    with open(path) as f:
        db = json.load(f)

    spam   = db.get("spam", [])
    good   = db.get("good", [])
    digest = db.get("digest")

    print()
    print(bold(f"  StrangeLove DB — {path}"))
    print(dim(f"  {datetime.now().strftime('%Y-%m-%d %H:%M')}"))
    print()

    print_summary(spam, good, digest)
    print()
    print_digest(digest, spam, good)
    print()
    print_examples(spam, "spam", red)
    print()
    print_examples(good, "ham", green)
    print()
    print_topk_neighbours(spam, good)
    rule()
    print()

if __name__ == "__main__":
    main()
