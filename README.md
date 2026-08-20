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

Copy the two directories into the workspace parent directory:

```bash
cd /path/to/parent
mkdir -p .claude/skills .claude/commands
cp -r pdflib-analysis/skills/pdflib-analysis .claude/skills/
cp    pdflib-analysis/commands/*.md          .claude/commands/
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
├── pdflib-base-image/           <- permanent: the repo that builds the base image
├── <repo-under-analysis>/       <- the repo you are working on right now
├── analyzed/                    <- repos already done (kept, not deleted)
└── analysis/                    <- permanent hub; git repo
    ├── reference/               <- probe output, reflected methods, base image notes
    ├── scripts/                 <- runtime scripts including the parser
    ├── fixtures/                <- parser test cases
    ├── findings/<repo>/         <- one directory per analyzed repo
    ├── PROGRESS.md
    ├── GLOSSARY.md
    └── SYNTHESIS.md
```

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
/pdflib-setup [registry.internal/php-base:8.2-pdflib10]
```

Reads the base image repo for the build recipe and probes the image itself.
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

- Docker, with the PDFlib base image available (pullable or locally buildable)
- Claude Code with the VS Code extension, or the CLI
- No host PHP required — everything runs inside the base image via
  `run-php.sh`, which also guarantees the same PHP and PDFlib version as
  production

---

## Files

```
skills/pdflib-analysis/
├── SKILL.md                          workflow, design rules, layout
├── references/
│   ├── findings-schema.md            per-repo output contract
│   ├── parser-spec.md                what the parser must handle
│   ├── pdflib-primer.md              tiers, option lists, hard features
│   └── replacement-questions.md      what synthesis must answer
└── scripts/
    ├── run-php.sh                    run PHP inside the base image
    ├── probe.php                     reflect the installed extension
    ├── probe-base-image.sh           host wrapper; writes reference files
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
