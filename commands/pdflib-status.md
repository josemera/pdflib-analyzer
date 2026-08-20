---
description: Report analysis progress, parser-version staleness, and repo drift
---

Use the **pdflib-analysis** skill.

Read-only. Never modify findings, never re-run extraction. This command exists
so staleness is visible rather than remembered.

## Gather

1. Current parser version: `analysis/scripts/parser-version.sh`. If the parser
   does not exist yet, say bootstrap has not run.
2. Every `analysis/findings/*/meta.json`.
3. For each analyzed repo still on disk (in `analyzed/` or the parent), its
   current `git rev-parse HEAD`.
4. `analysis/reference/base-image.txt` and `image-digest.txt`.
5. Whether `analysis/` has uncommitted changes.

## Report

A table of repos with: analyzed date, call-site count, recorded
`parser_version`, and status.

Status values:

- **current** — `parser_version` matches, HEAD matches recorded commit
- **stale (parser)** — extracted with an older parser; needs
  `/pdflib-reextract <repo-dir>`
- **drifted (source)** — HEAD no longer matches the recorded commit, so the
  findings describe code that is no longer on disk. Usually means someone
  pulled. Either check out the recorded SHA or re-analyze deliberately.
- **missing (source)** — findings exist but the repo is no longer present.
  Re-extraction needs a re-clone at the recorded SHA.

Then summarise:

- repos analyzed, and how many are current
- total distinct methods and option keys across all findings so far
- whether the corpus is single-version (synthesis will run) or mixed
  (`/pdflib-synthesize` will refuse)
- uncommitted changes in `analysis/`, if any

## Advise

If anything is stale, name the specific `/pdflib-reextract` commands to run.
Re-extraction does not have to happen immediately — batching is fine — but
`/pdflib-synthesize` will not run on a mixed-version corpus, so the debt has to
be cleared before the next synthesis.

If everything is current, say so plainly and note how many repos remain.
