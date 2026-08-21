---
description: Aggregate all repo findings into a cross-repo replacement analysis
---

Use the **pdflib-analysis** skill. Read its SKILL.md,
`references/replacement-questions.md`, and `references/pdflib-primer.md` before
starting.

Runs over whatever findings exist. **Run it early** — after roughly the third
and seventh repos, not only at the end. A missing schema field discovered at
repo three costs three re-extractions; the same discovery at the last repo
costs one per completed repo.

## 0. Version gate

Read every `analysis/findings/*/meta.json` and compare `parser_version` against
`analysis/scripts/parser-version.sh`.

**If any repo is stale, refuse to run.** List the stale repos and the
`/pdflib-reextract` commands needed. Aggregating findings produced by different
parser versions silently mixes different extraction rules into one conclusion,
and nothing downstream can detect it. This is the enforcement point for the
whole staleness mechanism — everything upstream is advisory.

## 1. Work from findings, not source

The repositories' PHP will not fit in context. The findings are the
compressed representation and are designed to stand alone.

Dropping into `analyzed/<repo>/` for a *specific* question is legitimate and is
why the repos are kept — but do it deliberately, for a named question, and
record the answer in the findings so the next synthesis does not have to repeat
it. Never read source wholesale.

## 2. Answer the questions

Work through `references/replacement-questions.md` in order. For each: the
answer, the evidence (which repos, how many call sites), and "insufficient
data" where that is the honest answer.

## 3. Write the report

`analysis/SYNTHESIS.md`, overwriting the previous one — git keeps the history.

**Lead with coverage**: how many repos of how many, named, and the parser
version. Anyone reading this needs to know immediately whether it describes
three repos or the whole estate.

Then:

- **Tier verdict** — what the installed binary provides, what usage actually
  requires, and what that means for difficulty
- **Method inventory** — the union, with call frequency per method and how many
  repos use each. Rank by frequency: the top of that list must be correct
  first, and single-repo methods are candidates for rewriting one call site
  instead of implementing a method.
- **Option-key inventory** — per method. Call this out as the real
  specification, because it is consistently larger and more demanding than the
  method list and is the part most likely to be underestimated.
- **Hard features** — which appear, in which repos, at how many call sites,
  with the trade-off of rewriting those call sites versus reimplementing the
  feature. Present it as a trade-off, not a recommendation.
- **Wrapper boundaries** — which repos are concentrated and which are
  scattered; whether any wrapper is shared or copy-pasted across repos, since a
  shared wrapper is a far better shim insertion point than one per repo
  ones.
- **Ingestion** — the split across the three pdflib variants, any repo whose
  variant differs from expectation, every transitive inheritance chain, and
  every local override found. The PDFlib binary being identical across variants
  is the claim that matters for the API surface; state whether the findings
  actually support it.
- **Error-handling contract** — how repos detect failure, and whether it varies.
  A replacement has to match the failure mode, not just the success path.
- **Migration prerequisites** — including that removing the extension is
  mandatory (a PHP class named `PDFlib` cannot be declared while the extension
  is loaded), and anything else in the estate that depends on it.
- **Open unknowns** — every item carried over from the `needs-review.md` files,
  consolidated. Dynamic option strings deserve their own list: they cannot be
  enumerated statically and no replacement can be called complete until they
  are resolved by hand.

No effort estimate in hours. Produce the facts an estimate would be built from,
and name the specific unknowns that would have to be resolved first.

## 4. Schema check

For each question you could not answer because the data was not captured,
propose the schema field that would fix it, and say plainly what re-extracting
the completed repos would cost. That check is most of the value of running this
early.

## 5. Report and commit

Commit `analysis/`. Summarise for the user in plain language, remembering they
are learning PDFlib from this work: what has become clearer, what has become
harder, and what the next repo is most likely to change.
