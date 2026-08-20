---
description: Re-run the current parser over an already-analyzed repo and review the diff
argument-hint: "<repo-dir>"
---

Use the **pdflib-analysis** skill.

Target repository: `$1`

Run after a parser fix, to bring an already-analyzed repo up to the current
parser version. This is why analyzed repos are kept on disk and why `analysis/`
is a git repo: re-extraction becomes a reviewable diff rather than a blind
overwrite.

## 1. Locate and verify

Find the repo — it may be in `analyzed/` or the parent. Read
`analysis/findings/<repo>/meta.json`.

Compare the repo's current HEAD to the recorded commit. If they differ, stop
and tell the user: re-extracting against different source silently changes what
the findings describe and conflates a parser change with a code change. Offer to
check out the recorded SHA, or to re-analyze deliberately as a new snapshot.

If the repo is no longer on disk, say so and offer to re-clone at the recorded
SHA.

## 2. Confirm `analysis/` is clean

Uncommitted changes will make the re-extraction diff unreadable. Ask the user to
commit or stash first.

## 3. Re-extract and re-gate

Run the parser and then `crosscheck.php`, exactly as `/pdflib-analyze` does.
Update `meta.json` with the new `parser_version` and timestamp. Leave `notes.md`
alone unless the new output contradicts it — the interpretation is still valid.

## 4. Review the diff

Show `git diff` for this repo's findings and characterise it:

- **Expected** — the change touches only what the parser fix was meant to
  affect. Say which call sites and why.
- **Unexpected** — the fix had side effects. Enumerate them individually. This
  is the whole reason for reviewing rather than overwriting: a fix that was
  meant to change three call sites and changed forty has a problem, and finding
  that now is much cheaper than finding it across the remaining repos.

If the diff is unexpected, do not commit. Report and let the user decide whether
to revisit the parser.

## 5. Finish

Once the diff is understood, commit with a message naming the repo, the old and
new parser versions, and what changed. Update `PROGRESS.md`.

Then run the equivalent of `/pdflib-status` and report which repos are still
stale, so the user can see the remaining debt in one place.
