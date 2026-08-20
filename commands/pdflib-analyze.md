---
description: Analyze one repository's PDFlib usage and write its findings set
argument-hint: "<repo-dir>"
---

Use the **pdflib-analysis** skill. Read its SKILL.md,
`references/findings-schema.md`, and `references/pdflib-primer.md` before
starting.

Target repository: `$1`

The repeatable per-repo command. Run once per repository, as each is cloned
into the parent directory.

## 0. Preconditions

Stop and report if any of these fail:

- `analysis/reference/pdflib-methods.txt` exists and is non-empty
  (`/pdflib-setup` has run)
- `analysis/scripts/extract-pdflib-calls.php` exists
  (`/pdflib-bootstrap` has run)
- `$1` exists under the parent directory, is a git repo, contains PHP, and has
  a Dockerfile or compose file
- `analysis/findings/<repo>/` does not already exist — refuse to overwrite
  without the user explicitly confirming. With repos cycling through the same
  parent directory, an accidental re-run on a half-analyzed repo is the easy
  mistake.

Run `analysis/scripts/parser-version.sh` and compare against every existing
`findings/*/meta.json`. If any completed repo is on an older version, say so
now — the user can carry on and batch the re-extraction, but should know before
adding another repo to a mixed-version corpus.

## 1. Ingestion

Cheap, because all repos share the base image. Record it anyway so the corpus
can demonstrate uniformity rather than assume it.

- Every `FROM` line in every Dockerfile, verbatim, with path and stage. In
  multi-stage builds the last stage is usually the runtime one, but a build
  stage can be where an extension is compiled and copied forward — record all
  of them.
- Whether any compose file bypasses the build with a direct `image:` key
- Whether the base matches what `/pdflib-setup` recorded

Then the part that is **not** redundant — local overrides. A shared base image
guarantees the same PDFlib binary, not the same PDFlib configuration. Check for:

- the repo's own `php.ini` or `conf.d/*.ini`
- its own Dockerfile stage installing or enabling anything
- `SearchPath`, font directories, or encoding paths set by the repo
- a different license key source
- `set_option()` / `set_parameter()` calls at bootstrap or in a service provider

Write `analysis/findings/<repo>/ingestion.json`.

## 2. Extract

```bash
analysis/scripts/run-php.sh analysis/scripts/extract-pdflib-calls.php "$1" \
  --methods analysis/reference/pdflib-methods.txt \
  --json-out analysis/findings/<repo>/extraction.json
```

Do not hand-extract call sites. If the parser fails on a file it should emit a
`needs_review` entry and continue; if it aborts, that is a parser bug — report
it rather than working around it manually.

## 3. Gates

```bash
analysis/scripts/run-php.sh analysis/scripts/crosscheck.php \
  --repo "$1" \
  --extraction analysis/findings/<repo>/extraction.json \
  --methods analysis/reference/pdflib-methods.txt \
  --functions analysis/reference/pdflib-functions.txt \
  --json-out analysis/findings/<repo>/crosscheck.json
```

**False positives are a hard stop.** Every extracted method must exist in the
reflected list. A failure means the parser attributed a wrapper method to
PDFlib. Fix the parser via the fixture-first loop; never edit the methods file.

**False negatives are a warning and the more important signal.** A parser count
below the grep count means a real call site may have been missed — the failure
mode that survives this exercise and breaks after the migration ships.
Investigate each. Benign explanations (a name in a comment, a docblock, a
string) go in `needs-review.md` with the reason. Real misses are parser bugs:
fixture first, then fix, then re-run this command.

## 4. Interpret

Write `analysis/findings/<repo>/notes.md`. Prose, useful to someone who cannot
open the repository:

- What this repo produces, and the document lifecycle in order
- Where the wrapper boundary sits and whether calls are concentrated or
  scattered — this decides whether the replacement must be API-perfect or
  merely wrapper-compatible
- Which hard features from `pdflib-primer.md` appear, and where
- How errors are handled: exceptions, return-value checks, or neither. This is
  part of the API surface a replacement must match.
- Anything surprising, especially anything contradicting an earlier repo
- Whether any wrapper class resembles one seen in a previous repo — a shared or
  copy-pasted wrapper is a much better shim insertion point than fifteen
  separate ones

Write `needs-review.md` with every unresolved item: file, line, the code, why
it could not be resolved, what a human would need to check.

## 5. Glossary

Add any method this repo calls that is not yet in `analysis/GLOSSARY.md`: what
it does, the option keys seen with it, its product tier. Ground entries against
the PDFlib API reference if one is on disk; mark anything unverified as
unverified rather than writing from recall. The user is learning PDFlib from
this file — it is a deliverable.

## 6. Finish

Write `meta.json` with repo, path, branch, commit SHA, timestamp,
`parser_version`, and files scanned.

Update `PROGRESS.md`. Commit `analysis/` with a message naming the repo, its
call-site count, and the parser version. Move the repo into `analyzed/`.

Report to the user: call sites found, distinct methods, new methods not seen in
previous repos, new option keys, hard features present, gate results in full,
and open items in `needs-review.md`.

If this is roughly the third or seventh repo, suggest running
`/pdflib-synthesize` now. A missing schema field found at repo three costs three
re-runs; found at repo fifteen it costs fifteen.
