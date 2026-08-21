# pdflib-analysis

A Claude Code skill and command set for inventorying how a set of PHP
repositories uses the commercial PDFlib extension, working toward an open source
drop-in replacement.

**The binding constraint: the calling code must not change.** The replacement
has to match PDFlib's API shape, argument conventions, option-list grammar,
error semantics, and return values — not merely produce similar PDFs. Every
design decision here follows from that.

---

## What problem this solves

Fifteen PHP repositories share a Docker base image that provides PDFlib. You
want to know exactly what API surface a replacement would have to satisfy,
without opening fifteen codebases at once (they will not fit in context) and
without an LLM re-deriving the extraction fifteen times (which produces fifteen
different completeness levels that nobody can tell apart).

The approach: a deterministic parser does the extraction, an authoritative
reflection of the installed extension defines what PDFlib even is, two
independent extractions cross-check each other, and one repo at a time
accumulates into a findings corpus that a final pass synthesises.

---

## Installation

This package contains two directories, `skills/` and `commands/`. Both belong
under `.claude/` in the parent directory, so you end up with:

```
parent/
└── .claude/
    ├── commands/
    │   ├── pdflib-setup.md
    │   ├── pdflib-bootstrap.md
    │   ├── pdflib-analyze.md
    │   ├── pdflib-status.md
    │   ├── pdflib-reextract.md
    │   └── pdflib-synthesize.md
    └── skills/
        └── pdflib-analysis/
            ├── SKILL.md
            ├── references/
            └── scripts/
```

The command files sit directly in `.claude/commands/` — not in a subdirectory,
or the slash commands won't be found. The skill keeps its own
`pdflib-analysis/` folder under `.claude/skills/`, with `SKILL.md` at its root.

Once the files are in place, make the shell scripts executable — the executable
bit often doesn't survive a trip through GitHub:

```bash
chmod +x .claude/skills/pdflib-analysis/scripts/*.sh
```

Open the **parent** directory in VS Code as a plain single-folder workspace —
not a multi-root workspace, since the Claude Code extension takes its working
directory from the first workspace folder and cannot be overridden.

You do not need to clone this as a git repo. `/pdflib-setup` runs `git init`
inside `analysis/`, which is where version history actually matters.

---

## Workspace layout

```
parent/                          <- open this in VS Code; Claude Code runs here
├── .claude/
│   ├── commands/pdflib-*.md
│   └── skills/pdflib-analysis/
├── pcw-pce-php-pdflib/          <- permanent: the repo that builds the PDFlib base image
├── <repo-under-analysis>/       <- the repo you are working on right now
├── analyzed/                    <- repos already done (kept, not deleted)
└── analysis/                    <- permanent hub; git repo
    ├── reference/               <- probe output, reflected methods, base image
    │                               notes, locked schema
    ├── scripts/                 <- runtime scripts including the parser
    ├── fixtures/                <- parser test cases
    ├── findings/<repo>/         <- one directory per analyzed repo
    ├── PROGRESS.md              <- written by every command
    ├── GLOSSARY.md              <- accumulated; how you learn PDFlib
    └── SYNTHESIS.md             <- written by /pdflib-synthesize
```

There is no top-level notes file. `findings/<repo>/notes.md` is the per-repo
prose interpretation; cross-repo conclusions live in `SYNTHESIS.md`, which is
regenerated on each run with git keeping the history.

Clone repos **without running `composer install`**. No `vendor/` means nothing
to exclude. If a repo commits `vendor/` anyway (common in at least one legacy
PHP repo out of fifteen), the analysis will flag it.

Keep analyzed repos. They make re-extraction cheap and let synthesis drop back
to source for questions the schema did not anticipate. Moving them into
`analyzed/` keeps ad-hoc searches scoped to the current repo.

### Recommended VS Code settings

`parent/.vscode/settings.json` — with 15 nested git repos, source control
detection gets noisy:

```json
{
  "git.autoRepositoryDetection": false,
  "git.detectSubmodules": false,
  "files.watcherExclude": { "**/vendor/**": true, "**/node_modules/**": true },
  "search.exclude": { "**/vendor": true, "**/node_modules": true }
}
```

### Recommended Claude Code settings

`parent/.claude/settings.json` — the analysis is read-only over the repos:

```json
{
  "permissions": {
    "deny": [
      "Edit(./analyzed/**)",
      "Write(./analyzed/**)",
      "Read(**/vendor/**)",
      "Read(**/.env)",
      "Read(**/.env.*)"
    ]
  }
}
```

Deny rules gate the built-in file tools, not Bash — `Read(**/vendor/**)` will
not stop `cat vendor/whatever.php`. Add matching `Bash()` rules if that matters
to you. Note these are VS Code's and Claude Code's settings respectively; they
are different files and neither reads the other.

---

## The workflow

### Phase 0 — Setup, once

```
/pdflib-setup <donor-repo-dir>
```

Two halves. **Blocking**: resolve a runtime and probe it for the reflected
method list, which everything downstream validates against. **Enriching**: read
the base repo for the build recipe and, most valuably, the vendor API reference
if a PDFlib GmbH bundle supplied one — that is what grounds the glossary.

No application repo is needed: the runtime comes from the base repo's
`cli-pdflib` target. If that build proves awkward, `pcw-ppe-signs-pdfgen` is the
fallback donor.

Reads `pcw-pce-php-pdflib/` for the build recipe and probes the image itself.
Touches no application repo.

Produces `analysis/reference/`: the build recipe, the resolved image digest,
`php --ri pdflib` output, and — most importantly — `pdflib-methods.txt`, the
reflected method list.

Because all repos share this base image, **PDFlib version and product tier are
settled here, globally**. They are not per-repo questions.

**Gate: the reflected method list must be non-empty.**

### Phase 1 — Bootstrap, once, on the first repo

```
/pdflib-bootstrap invoicing-service
```

Builds the extraction parser against real code and locks the findings schema.
Deliberately interactive and several sessions long. Later repos take one
session — do not be alarmed by the asymmetry.

Order matters here: orient, grep baseline, fixtures, parser, differential
validation, schema, findings.

**Pause and read the diff report.** This is the one step worth your attention
— see "Why the parser is not shipped" below.

### Phase 2 — Per repo, repeated

```
/pdflib-analyze billing-api
```

Ingestion, extraction, gates, interpretation, glossary, commit. One session.
Refuses to overwrite existing findings without explicit confirmation.

### Phase 3 — Synthesis, repeated

```
/pdflib-synthesize
```

Run after roughly the third and seventh repos, not only at the end. Writes
`analysis/SYNTHESIS.md` and leads with its coverage. Refuses to run on a
mixed-parser-version corpus.

### Maintenance

```
/pdflib-status
/pdflib-reextract billing-api
```

---

## The design rules, and why

**Extraction is deterministic, not conversational.** A committed
`nikic/php-parser` script produces the call-site inventory; the agent
interprets on top of it. Regex cannot tell whether `->load_font(` belongs to a
PDFlib instance or a `FontManager` someone wrote in 2014, and it breaks on
multi-line calls, heredocs, and concatenated option strings. Under a
no-changes-to-calling-code constraint, a missed call site is a runtime fatal
after the migration ships.

**The reflected method list is the only authority.**
`get_class_methods('PDFlib')` inside the base image returns the exact API of the
binary installed — not documentation, not recall. It also settles the tier
question immediately: no `pdi` methods means no repo can be importing PDFs,
whatever the code appears to do.

**Both gates run on every analysis.** False positives (a method not in the
reflected list) are a hard stop. False negatives (grep finds more occurrences
than the parser) are a warning, and are the more important signal — that is the
failure mode that survives the whole exercise.

**Findings stand alone.** Synthesis runs over `findings/`, not over source,
because fifteen repos of PHP will not fit in context. Call sites carry
surrounding code; wrapper boundaries are described in prose.

**`parser_version` is a hash of the parser's own source.** A hand-maintained
constant can be forgotten; a hash cannot.

---

## The parser fix loop

When a deficiency surfaces — a gate warning, a `needs_review` entry, something
you spot:

1. **Write the fixture first**, with expected output, and confirm it fails.
   A fixture written after the fix gets shaped by the implementation and proves
   nothing.
2. Fix the parser.
3. Confirm the new fixture passes and every existing fixture still does.
4. The version hash changes automatically.
5. `/pdflib-reextract <repo>` for each completed repo, reviewing each diff.

Because `analysis/` is a git repo, step 5 is a reviewable diff. If a fix meant
to change three call sites changes forty, it had a side effect — and you find
that out before it propagates through the rest.

You do not have to re-extract immediately. But `/pdflib-synthesize` refuses to
run on a mixed-version corpus, so the debt has to clear before the next
synthesis.

---

## How you find out something is wrong

Not by an agent noticing. By mechanical checks that run every time:

| Signal | Where it comes from | Severity |
|---|---|---|
| Method not in reflected list | `crosscheck.php` gate 1 | hard stop |
| Grep count exceeds parser count | `crosscheck.php` gate 2 | warning; investigate every one |
| `needs_review` non-empty | the parser's own admission | review before committing |
| `parser_version` mismatch | `/pdflib-status`, `/pdflib-analyze` startup | re-extract before synthesis |
| HEAD differs from recorded SHA | `/pdflib-status` | findings describe code no longer on disk |

---

## Why the parser is not shipped with this skill

`extract-pdflib-calls.php` is written during `/pdflib-bootstrap`, against real
code, and lives in `analysis/scripts/`. A parser written speculatively would
encode guesses about a codebase nobody has looked at yet, and you would write
it twice.

The specification it must satisfy is in
`skills/pdflib-analysis/references/parser-spec.md`.

Bootstrap is also the step most worth your attention, for a specific reason: an
agent asked to make two extractions agree can satisfy that by weakening either
one. Three things blunt it — the reflected method list is external and cannot be
edited, fixtures must precede fixes, and the diff report must enumerate every
discrepancy individually rather than summarise. "All resolved" is easy to write;
a numbered list of twelve explanations is not.

If you want one human checkpoint in the entire workflow, put it there.

---

## Requirements

- Claude Code with the VS Code extension, or the CLI
- PHP on the host (any 7.4+) — used for the parser and the cross-check, which
  need no extensions. Not strictly required: `run-php.sh` falls back to the
  base image when the host has no PHP.
- Docker. Needed for one thing only: reflecting the PDFlib extension during
  `/pdflib-setup`, which can only happen where the extension exists. See the
  note on donors below — the base image itself does not need to be runnable.
- Composer, or docker (the official `composer:2` image is used as a fallback)

**The base image does not have to run standalone.** The base repo builds a
`cli-pdflib` target — PHP CLI with PDFlib and no web server — which runs
`php -r` directly. That is the probe target, and no application repo is needed
for it.

`resolve-runtime.sh` tries, in order:

0. `PDFLIB_RUNTIME_IMAGE`, if you set it
1. any local image already carrying pdflib on the CLI SAPI (you probably have
   these built already)
2. `docker build --target cli-pdflib` from the base repo
3. compose or a direct build from a donor repo, if one is passed

It verifies the extension actually loads before accepting a runtime, and records
the choice in `analysis/reference/runtime.txt`.

**None of this requires the base image to be buildable or runnable standalone.**
Step 2 is preferred, not required — steps 0, 1, and 3 all bypass the base repo
entirely. In practice step 1 usually wins: a working dev environment already has
application images built, and any of them carries the same PDFlib build. The
only hard requirement is one obtainable image with the extension loaded for the
CLI SAPI.

**Why CLI-flavoured images are tried first.** Fourteen of the fifteen apps run
Apache variants, which may enable the extension for FPM but not CLI — so a probe
against one can report the extension as missing when it is installed and working.
If you do need a donor, use `pcw-ppe-signs-pdfgen`: it is the only app on
`php-cli-pdflib`.

No container ever needs to be left running.

`analysis/scripts/run-php.sh --which` reports which PHP will be used, whether
the image is known, and whether php-parser is installed.

---

## Files

```
skills/pdflib-analysis/
├── SKILL.md                          workflow, design rules, layout
├── references/
│   ├── findings-schema.md            per-repo output contract
│   ├── parser-spec.md                what the parser must handle
│   ├── environment.md                base image targets and the app inventory
│   ├── pdflib-primer.md              tiers, option lists, hard features
│   └── replacement-questions.md      what synthesis must answer
└── scripts/
    ├── run-php.sh                    run PHP: host by default, --image when needed
    ├── probe.php                     reflect the installed extension
    ├── resolve-runtime.sh            find a runtime via an inheriting repo
    ├── probe-runtime.sh              host wrapper; writes reference files
    ├── crosscheck.php                both validation gates
    └── parser-version.sh             hash the parser

commands/
├── pdflib-setup.md
├── pdflib-bootstrap.md
├── pdflib-analyze.md
├── pdflib-status.md
├── pdflib-reextract.md
└── pdflib-synthesize.md
```

`/pdflib-setup` copies `scripts/` into `analysis/scripts/` so the analysis
directory becomes a self-contained, versioned unit. Once the parser is written
and stable, copying it back into this skill makes the whole thing reusable.

---

## A note on scope

This skill inventories. It does not build the replacement, and it deliberately
produces no effort estimate — only the facts an estimate would be built from,
plus a named list of the unknowns that would have to be resolved first.

Two of those unknowns are worth knowing about before you start. Option strings
built dynamically from config or user data cannot be enumerated statically, and
no replacement can be called complete until they are resolved by hand. And a
PHP class named `PDFlib` cannot be declared while the extension is loaded, so
the replacement necessarily means removing the extension from the base image —
which makes finding everything *else* that depends on it a migration
prerequisite rather than a detail.
