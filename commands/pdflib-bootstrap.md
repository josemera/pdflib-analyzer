---
description: One-time — build and validate the extraction parser against the first real repo, then lock the findings schema
argument-hint: "<repo-dir>"
---

Use the **pdflib-analysis** skill. Read its SKILL.md,
`references/parser-spec.md`, and `references/findings-schema.md` before
starting.

Target repository: `$1`

This runs **once**, on the first repository. It is deliberately interactive.
The parser must be shaped by what real code contains, and the schema must be
shaped by real extraction output — writing either speculatively means writing
them twice.

Requires `/pdflib-setup` to have completed. If
`analysis/reference/pdflib-methods.txt` is missing or empty, stop and say so.

## 1. Preflight

Confirm `$1` exists under the parent directory, is a git repo, contains PHP,
and has a Dockerfile or compose file. Record its branch and commit SHA. Fresh
clones have no `vendor/`; if one exists, note it — that repo commits its
dependencies and its scanning needs exclusions.

## 2. Orient before extracting

Read enough of the repo to answer, and tell the user:

- What documents does this repo produce?
- Walk the typical document lifecycle in order — instantiate, begin document,
  load resources, begin page, place content, end page, end document. Annotate
  it with the actual calls in this repo.
- Is there a wrapper class, or are calls scattered raw?
- OO style, procedural style, or both?

The user does not know PDFlib. This narrative is how they learn it, and it is
worth more than any method list. Take it seriously rather than treating it as
preamble.

## 3. Baseline grep extraction

Produce a grep-based candidate list of call sites — file, line, method name,
arguments — filtered against the reflected method list. Save it to
`analysis/findings/<repo>/baseline-grep.json`.

Also save, separately, the near-miss names: method calls whose names are *not*
in the reflected list but which look PDFlib-adjacent. Those are the wrapper
class methods, and identifying them is a deliverable, not noise.

This is the one sanctioned use of grep for extraction, and it exists only to
give the parser something independent to be checked against.

## 4. Install the parser dependency

```bash
analysis/scripts/run-php.sh --composer require nikic/php-parser
```

If composer is not present in the base image, use the fallback the script
prints. This is `analysis/`'s dependency only — the repos stay clean.

## 5. Write fixtures first

Before writing the parser, create `analysis/fixtures/` with the cases from
`references/parser-spec.md`, each with its expected output. Confirm they fail
against a stub. Fixtures written after the parser get shaped by the
implementation and prove nothing.

Add any additional ugly cases discovered in step 2 from this repo's real code.

## 6. Write the parser

Write `analysis/scripts/extract-pdflib-calls.php` per `references/parser-spec.md`.
Iterate against the fixtures until all pass, then run it on the repo.

## 7. Differential validation

Run:

```bash
analysis/scripts/run-php.sh analysis/scripts/crosscheck.php \
  --repo "$1" \
  --extraction analysis/findings/<repo>/extraction.json \
  --methods analysis/reference/pdflib-methods.txt \
  --functions analysis/reference/pdflib-functions.txt \
  --json-out analysis/findings/<repo>/crosscheck.json
```

Then diff the parser output against the step 3 grep baseline and write
`analysis/findings/<repo>/diff-report.md`.

**Enumerate every discrepancy individually** with file, line, which side found
it, and the explanation. Do not summarise as a count. "All resolved" is easy to
write; a numbered list of twelve explanations is not, and the list is what makes
this checkable.

For every discrepancy that is a real parser bug: add the fixture first, confirm
it fails, fix, confirm all fixtures pass. Re-run.

**This is the step most worth the user's attention.** An agent asked to make two
extractions agree can satisfy that by weakening either one. The reflected method
list is external and cannot be edited; the fixtures must precede the fixes; the
diff report must enumerate. Present the diff report and pause for the user
before continuing.

## 8. Lock the schema

With real output in hand, finalise the per-repo schema. Compare it against
`references/replacement-questions.md`: for each question, confirm the schema
carries the fields needed to answer it. Record the final schema in
`analysis/reference/schema.md` and note any deliberate deviation from the
skill's version and why.

## 9. Complete the repo

Produce the full findings set for this repo per `references/findings-schema.md`
— `meta.json` (with `parser_version` from `analysis/scripts/parser-version.sh`),
`ingestion.json`, `extraction.json`, `needs-review.md`, `notes.md`.

Start `analysis/GLOSSARY.md`: every method this repo calls, what it does, the
option keys seen with it here, and its product tier. Ground it against the
PDFlib API reference if setup found one on disk; otherwise mark entries as
unverified rather than writing from recall.

## 10. Hand off

Update `PROGRESS.md`, commit `analysis/`, move the repo to `analyzed/`, and
report:

- what the parser had to special-case
- what grep missed and what the parser missed
- anything that suggests other repos will differ
- the current `parser_version`

Then note that subsequent repos use `/pdflib-analyze <repo-dir>` and should take
a single session.
