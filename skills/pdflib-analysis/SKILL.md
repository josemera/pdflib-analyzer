---
name: pdflib-analysis
description: Analyze how PHP repositories use the commercial PDFlib extension, one repository at a time, building a cross-repo inventory of the API surface that an open source drop-in replacement would have to satisfy. Use this skill whenever the user mentions PDFlib, PDF_ function calls, a PDFlib replacement or migration, analyzing PDF generation code across repos, or runs any of the /pdflib-* commands. Also use it when the user asks about the findings directory, the extraction parser, the option-string inventory, or the analysis progress file in a PDFlib migration workspace.
---

# PDFlib Analysis

## What this is for

The user maintains a set of PHP repositories that all depend on the commercial
PDFlib extension, installed through a shared Docker base image. The goal is an
open source replacement.

**The binding constraint on everything: the calling code must not change.** The
replacement has to match PDFlib's API shape, argument conventions, option-list
grammar, error semantics, and return values — not merely produce similar PDFs.
Every design decision in this workflow follows from that. When a judgement call
comes up, ask "does this help us know exactly what the replacement must
implement?"

The user is an experienced PHP engineer but does **not** know PDFlib. Learning
the library is an explicit goal of the exercise, not a prerequisite. Never
assume shared PDFlib vocabulary; explain what a method does when you name it,
and treat `GLOSSARY.md` as a real deliverable rather than a byproduct.

## Non-negotiable design rules

Read these before doing anything. They are what make fifteen separate runs
comparable to each other.

**1. Extraction is deterministic, not conversational.** A committed PHP script
using `nikic/php-parser` produces the call-site inventory. Never hand-extract
call sites with grep and present them as findings. Grep has exactly one
sanctioned role: an independent cross-check against the parser (see rule 3).
The reason is that an LLM re-deriving the extraction fifteen times produces
fifteen different completeness levels, and nobody can tell which ones are wrong.

**2. The reflected method list is the only authority on what PDFlib is.**
`get_class_methods('PDFlib')` run inside the base image returns the exact API
of the binary actually installed. It is not documentation, not recall, not a
guess. Any method name in an extraction that does not appear in that list is by
definition not PDFlib — it is a wrapper class, a false positive, or a bug.
Never edit that file to make a check pass.

**3. Every analysis run self-tests in both directions.**
- *False positives*: every extracted method name must appear in the reflected
  list. This is a hard gate.
- *False negatives*: for each reflected method name, grep the repo and compare
  the hit count to the parser's count. Mismatches warn rather than fail (a name
  can legitimately appear in a comment or a string), but a parser count *lower*
  than the grep count is the silent failure mode that breaks a drop-in
  replacement in production. Investigate every one.

**4. Findings must stand alone.** Synthesis runs over `findings/`, not over
source. Fifteen PHP repositories will not fit in a context window. Capture
surrounding code context with each call site and describe the wrapper boundary
in prose, so a later session can reason about a repo without opening it.

**5. Say "could not determine".** A recorded unknown is useful. A confident
guess poisons a corpus that later decisions rest on. This applies especially to
ingestion questions whose answer lives outside the repository.

## Workspace layout

Claude Code runs from the **parent directory**. It is not itself a git repo.

```
parent/
├── .claude/
│   ├── commands/           # the /pdflib-* commands
│   └── skills/pdflib-analysis/
├── pdflib-base-image/      # permanent: the repo that builds the base image
├── <repo-under-analysis>/  # the repo currently being worked on
├── analyzed/               # repos already done (kept, not deleted)
└── analysis/               # permanent hub — git init here
    ├── reference/          # probe output, reflected methods, base image notes
    ├── scripts/            # runtime scripts incl. the parser
    ├── fixtures/           # parser test cases
    ├── findings/<repo>/    # one directory per analyzed repo
    ├── PROGRESS.md
    ├── GLOSSARY.md
    └── NOTES.md
```

Analyzed repos stay on disk. They make re-extraction cheap and let synthesis
drop back to source for questions the schema did not anticipate. Move them into
`analyzed/` once done so ad-hoc searches at the parent stay scoped to the
current repo.

## Running PHP

The user's environment is dockerized and may have no host PHP. Run PHP through
the base image, which also guarantees the same PHP and PDFlib version as
production:

```bash
analysis/scripts/run-php.sh <script.php> [args...]
```

That wrapper mounts the parent directory and executes inside the base image.
Use it for the probe, the parser, and the cross-check.

## Phases

### Phase 0 — Setup (once)

`/pdflib-setup`. Reads the base image repo for the build recipe and probes the
image for the reflected method list, version, and product tier. Touches no
application repo. All repos share this base image, so version and tier are
settled globally here and are not per-repo questions.

### Phase 1 — Bootstrap (once, interactive, on the first repo)

`/pdflib-bootstrap <repo-dir>`. Builds and validates the extraction parser
against real code, then locks the findings schema. This phase is deliberately
interactive: the parser must be shaped by what real repositories actually
contain, and the schema must be shaped by real extraction output.

Read `references/parser-spec.md` before starting.

### Phase 2 — Per-repo analysis (repeated)

`/pdflib-analyze <repo-dir>`. Run once per repository, manually, as each new
repo is cloned into the parent directory.

### Phase 3 — Synthesis (repeated, not just at the end)

`/pdflib-synthesize`. Runs over whatever findings exist and states its coverage.
Run it early — after roughly the third and seventh repos — so a missing schema
field is discovered when it costs three re-runs instead of fifteen.

### Maintenance

`/pdflib-status` reports progress and staleness. `/pdflib-reextract <repo-dir>`
re-runs a changed parser over an already-analyzed repo.

## Parser versioning and the fix loop

`parser_version` is a hash of the parser script's own source, emitted by
`analysis/scripts/parser-version.sh`. It cannot be forgotten, because changing
the script changes the hash. Every `findings/<repo>/meta.json` records the
version it was produced with.

When a deficiency surfaces:

1. Add the case to `analysis/fixtures/` **with its expected output first**, and
   confirm it fails. Writing the fixture after the fix lets the test be shaped
   by the implementation, which defeats the point.
2. Fix the parser.
3. Confirm the new fixture passes and every existing fixture still does.
4. The version hash changes automatically.
5. Re-extract the repo that surfaced the problem, then the others in
   `analyzed/` at a convenient point.

Because `analysis/` is a git repo, re-extraction is a reviewable diff rather
than a blind overwrite. Commit after each repo completes. If a parser fix
changes three call sites, the diff shows three; if it changes forty, the fix had
a side effect and you have found out before it propagated.

**`/pdflib-synthesize` refuses to run on a mixed-version corpus.** That is the
enforcement point; everything upstream is advisory.

## Reference files

Read these when the phase calls for them:

- `references/findings-schema.md` — the per-repo output contract. Read before
  writing any findings file.
- `references/parser-spec.md` — what the extraction parser must handle and how
  to validate it. Read during bootstrap and whenever fixing the parser.
- `references/pdflib-primer.md` — product tiers, option-list grammar, and the
  features that are hard to reimplement. Read before interpretation or
  synthesis.
- `references/replacement-questions.md` — the questions synthesis must answer.
  Read before synthesis, and consult during schema changes to check that the
  schema can still answer them.

## Scripts

Shipped in `scripts/` and copied to `analysis/scripts/` by `/pdflib-setup` so
the analysis directory is a self-contained, versioned unit:

- `run-php.sh` — execute a PHP script inside the base image
- `probe.php` — reflect the installed PDFlib and report tier, version, methods
- `probe-base-image.sh` — host wrapper around `probe.php`
- `crosscheck.php` — the false-positive and false-negative gates
- `parser-version.sh` — hash the parser script

`extract-pdflib-calls.php` does **not** ship with this skill. It is written
during bootstrap, against real code, and lives in `analysis/scripts/`. A parser
written speculatively would encode guesses about a codebase nobody has looked at
yet.

## Tone with the user

Report gate results plainly, including failures. A run that reports "12
discrepancies, here they are" is more valuable than one that reports success.
Never summarize discrepancies as a count alone — enumerate them, because "all
resolved" is easy to write and a numbered list of twelve explanations is not.
