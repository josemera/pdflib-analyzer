# Replacement-risk questions

What synthesis exists to answer. Also the test for any schema change: if a new
field does not help answer one of these, it is probably not worth the
re-extraction it costs.

Answer every question with its evidence — which repos, how many call sites —
and say "insufficient data" rather than guessing. State coverage at the top of
every synthesis report: how many repos of how many, and which.

## Scope and feasibility

1. Which product tier does the installed binary provide, and does any repo's
   usage require a higher tier than the corpus average? (Tier is settled in
   setup; this checks that usage matches.)
2. What is the union of distinct methods called across all analyzed repos, and
   how many? Fifteen methods is a very different project from two hundred.
3. Which methods appear in only one repo? Those are candidates for rewriting a
   single call site rather than implementing the method.
4. Which methods are called most? Those must be correct first.
5. Does any repo import existing PDFs (PDI) or fill Blocks (PPS)? Either
   changes the estimate by an order of magnitude.

## The option-list surface

6. What is the union of option keys, per method? This is the parser
   specification for the replacement.
7. Which options take composite or nested values rather than simple scalars?
8. How many option strings are built dynamically rather than written as
   literals, and where? Those cannot be enumerated statically and need manual
   review before any replacement is considered complete.
9. Which `set_option` / `set_parameter` calls configure global behaviour, and
   do repos configure it differently?

## Hard features

10. Which of the features in `pdflib-primer.md` appear anywhere in the corpus,
    in which repos, and at how many call sites?
11. For each, could the affected call sites be rewritten instead of the feature
    being reimplemented? (This is the one place where relaxing the
    no-changes-to-calling-code constraint may be worth costing out — present it
    as a trade-off, not a recommendation.)

## Migration mechanics

12. What fonts are loaded, from where, with what embedding settings? Are any
    supplied by the base image rather than by a repo?
13. How is error handling done — exceptions, return-value checks, or neither?
    Does it vary across repos?
14. Where does the wrapper boundary sit in each repo? Which repos are
    concentrated behind an abstraction and which are scattered raw? Concentrated
    repos can tolerate a wrapper-compatible replacement; scattered ones require
    an API-perfect one.
15. Do any wrapper classes appear in more than one repo — copy-pasted or via a
    shared internal package? A shared wrapper is a much better shim insertion
    point than fifteen separate ones.
16. Do all repos pin the same base image, and does any repo override PDFlib
    configuration locally?
17. What else in the estate depends on the `pdflib` extension being loaded, and
    would break when it is removed?

## Output for the reader

Synthesis should produce a document that someone who has never seen this
analysis can act on: coverage, the tier verdict, the method inventory with
frequencies, the option-key inventory, the hard-feature list with affected
repos, the wrapper-boundary picture, and an explicit list of open unknowns
carried over from `needs-review.md` files.

Do not produce an effort estimate in hours. Produce the facts an estimate would
be built from, and name the specific unknowns that would have to be resolved
first.
