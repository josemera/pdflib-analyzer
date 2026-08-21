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
├── pcw-pce-php-pdflib/     # permanent: builds the PDFlib base image
├── <repo-under-analysis>/  # the repo currently being worked on
├── analyzed/               # repos already done (kept, not deleted)
└── analysis/               # permanent hub — git init here
    ├── reference/          # probe output, reflected methods, base image
    │                       #   notes, locked schema
    ├── scripts/            # runtime scripts incl. the parser
    ├── fixtures/           # parser test cases
    ├── findings/<repo>/    # one directory per analyzed repo
    ├── PROGRESS.md         # written by every command
    ├── GLOSSARY.md         # accumulated; the user learns PDFlib from this
    └── SYNTHESIS.md        # written by /pdflib-synthesize, overwritten each run
```

Note the two different `notes` files: `findings/<repo>/notes.md` is the per-repo
prose interpretation, written once per repo. There is no top-level notes file —
cross-repo conclusions belong in `SYNTHESIS.md`, which is regenerated rather
than appended to, with git keeping the history.

Analyzed repos stay on disk. They make re-extraction cheap and let synthesis
drop back to source for questions the schema did not anticipate. Move them into
`analyzed/` once done so ad-hoc searches at the parent stay scoped to the
current repo.

## Running PHP

Two kinds of PHP in this workflow, with different requirements:

**Plain PHP** — the extraction parser and `crosscheck.php`. These only read
source files and need `nikic/php-parser`. Host PHP is preferred: faster, no
docker round-trip, no image needed.

```bash
analysis/scripts/run-php.sh analysis/scripts/extract-pdflib-calls.php ...
```

**In-image PHP** — `probe.php` only. The PDFlib extension exists *only* inside
the base image, so reflecting it has to happen there:

```bash
analysis/scripts/run-php.sh --image analysis/scripts/probe.php
```

`run-php.sh` uses host PHP when available and falls back to the image otherwise;
`--image` forces the image, `--host` forces the host, `--which` reports what it
would do. A host/container PHP version mismatch does not affect extraction —
php-parser ships its own lexer and parses target syntax independently of the
runtime it runs on. It very much affects the probe, which is why the probe is
pinned to the image.

### Finding a runtime

Read `references/environment.md` first — it records the base image targets and
which app uses which.

The base repo builds a **`cli-pdflib`** target: PHP CLI with PDFlib and no web
server. That runs `php -r` directly, so it is the natural probe target and no
application repo is needed in the normal case.

`resolve-runtime.sh` tries, in order: an explicit `PDFLIB_RUNTIME_IMAGE`, any
local image already carrying pdflib on the CLI SAPI, a
`docker build --target cli-pdflib` from the base repo, then — only if a donor
repo is passed — compose or a direct build from that repo. It verifies
`extension_loaded("pdflib")` before accepting anything, and records the winner in
`analysis/reference/runtime.txt` for `run-php.sh --image` to reuse.

**CLI-flavoured images first, deliberately.** Fourteen of the fifteen apps run
Apache variants, which may enable the extension for FPM but not CLI. A probe
against one of those can report the extension missing when it is installed and
working — a false negative that looks identical to a real one. If a donor is
needed, `pcw-ppe-signs-pdfgen` is the right one: it is the only app on
`php-cli-pdflib`.

No container ever needs to be left running, and `/pdflib-setup` takes the donor
as an optional argument only.

### When a container is needed

Once. During `/pdflib-setup`, to produce the reflected method list. Phase 1
consumes that list (the parser takes `--methods`; both crosscheck gates validate
against it) so it cannot be deferred — but Phase 1 already has an inheriting
repo present, which is exactly the donor. Phase 2 onward is pure host PHP and
touches no container at all.

## Phases

### Phase 0 — Setup (once)

`/pdflib-setup`. Two halves with different weight:

**Blocking**: resolve a runtime and probe it for the reflected method list.
Everything downstream depends on that list — the parser takes `--methods`, both
crosscheck gates validate against it. The runtime comes from the base repo's
`cli-pdflib` target, or any image carrying the extension on the CLI SAPI.

**Enriching**: read the base repo for the build recipe, license provenance, and
— the item that matters most — whether a PDFlib GmbH bundle supplied the API
reference PDF. `GLOSSARY.md` is grounded against that reference; without it,
entries stay unverified. Nothing is blocked on this half, and the `.upr`, fonts,
and ini config can be read from inside the runtime as a cross-check or fallback.

Because all repos share the same PDFlib build, version and tier are settled here
globally and are not per-repo questions. The image *variant* still is — see
`references/environment.md`.

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
- `references/environment.md` — base image targets, the app inventory, and
  which repo uses which. Read during setup and whenever an ingestion question
  comes up.
- `references/pdflib-primer.md` — product tiers, option-list grammar, and the
  features that are hard to reimplement. Read before interpretation or
  synthesis.
- `references/replacement-questions.md` — the questions synthesis must answer.
  Read before synthesis, and consult during schema changes to check that the
  schema can still answer them.

## Scripts

Shipped in `scripts/` and copied to `analysis/scripts/` by `/pdflib-setup` so
the analysis directory is a self-contained, versioned unit:

- `run-php.sh` — execute PHP; host by default, `--image` for the probe
- `probe.php` — reflect the installed PDFlib and report tier, version, methods
- `resolve-runtime.sh` — find a runtime with the extension loaded for CLI
- `probe-runtime.sh` — host wrapper around `probe.php`
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
