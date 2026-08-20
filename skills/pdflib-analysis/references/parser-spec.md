# Extraction parser specification

Read this during `/pdflib-bootstrap` and whenever fixing the parser.

## Why a parser and not grep

Regex sees characters. It cannot tell whether `->load_font(` belongs to a
PDFlib instance or to a `FontManager` someone wrote in 2014. It also breaks on
things that are entirely normal in production PHP: a call split across lines, an
option string built by concatenation, a heredoc, a method name inside a comment
or a docblock. Each of those is a silently missed call site, and under a
no-changes-to-calling-code constraint a missed call site is a runtime fatal
after the migration ships.

An AST — abstract syntax tree — is the structured form of source code after
parsing: a tree of typed nodes where a method call knows its receiver, its name,
and its arguments as distinct things rather than as text.

## Dependency

`nikic/php-parser`, the de facto PHP AST library (PHPStan, Rector, and
PHP-CS-Fixer are all built on it). Install into `analysis/`:

```bash
analysis/scripts/run-php.sh --composer require nikic/php-parser
```

This is `analysis/`'s own dependency and has nothing to do with the fifteen
repositories, which stay as fresh clones with no `vendor/` directory.

## Invocation contract

```
extract-pdflib-calls.php <repo-path> --methods <reflected-methods-file> [--json-out <path>]
```

Writes `extraction.json` per `references/findings-schema.md`. Exits non-zero
only on catastrophic failure. A file it cannot parse produces a `needs_review`
entry and the run continues — one bad file must never abort a repo.

## Node types to visit

- **`MethodCall`** — the OO form, `$p->begin_page_ext(...)`
- **`FuncCall`** — the procedural form, `PDF_begin_page_ext($p, ...)`. Match
  case-insensitively on a `PDF_` prefix; PHP function names are not case
  sensitive and real code is inconsistent.
- **`StaticCall`** — rare, but catches a static facade wrapping the instance
- **`New_`** — `new PDFlib()` and `new pdflib()`, to identify which variables
  hold instances
- **`Assign`** — to trace instance variables to properties and locals

## Receiver resolution

The hard part. A `MethodCall` node gives you a receiver expression, not a type.
Resolve in this order and record `confidence` honestly:

1. **certain** — receiver traces to a `new PDFlib()` in the same scope, or to a
   property assigned from one in the constructor, or the method name exists in
   the reflected list and appears nowhere else in the codebase as a
   user-defined method.
2. **likely** — method name is in the reflected list and the receiver is a
   property or variable named suggestively (`$pdf`, `$p`, `$this->pdflib`), but
   the assignment is not visible in the file.
3. **uncertain** — method name is in the reflected list but the receiver is
   ambiguous. Emit it, flag it, and add a `needs_review` entry.

A name collision with a user-defined class is not a hypothetical. Check for
user-defined methods sharing PDFlib names and report them; they are usually the
wrapper class, which is itself a deliverable.

## Argument handling

For each argument, record position and `kind`:

- `literal` — a `Scalar\String_`, `Int_`, or `Float_`; record the value
- `concat` — a `BinaryOp\Concat`; record the literal fragments and mark the
  dynamic parts
- `variable`, `constant`, `array`, `unknown` — record the source text

Option strings are usually the last string argument. Parse `key=value` pairs,
allowing braced composite values such as `SearchPath={/a} {/b}` and nested
suboptions. Record both the raw string and the extracted keys. When an option
string is not fully literal, record what is known and add a `needs_review`
entry — those are the ones that cannot be enumerated statically.

## Fixtures

Build `analysis/fixtures/` as you go. Write each fixture with its expected
output **before** fixing the parser to handle it, and confirm it fails first.
Otherwise the test gets shaped by the implementation and proves nothing.

Cases to have covered before leaving bootstrap:

- both OO and procedural calling styles in one file
- a call split across several lines
- a chained call, e.g. `$this->pdf()->fit_textline(...)`
- an option string in a heredoc or nowdoc
- an option string built by concatenation from a config value
- a decoy: a user-defined class with a method named the same as a PDFlib method
- a PDFlib method name appearing only in a comment or docblock
- a braced composite option value
- a file with a syntax error, to prove the run continues

## Validation gates

Both implemented in `crosscheck.php`, run automatically by `/pdflib-analyze`.

**False positives (hard gate).** Every method in `extraction.json` must appear
in the reflected methods file. A failure means the parser has misattributed a
wrapper method to PDFlib. Fix the parser — never edit the methods file.

**False negatives (warning, but the important one).** For each reflected method
name, grep the repo's PHP files and compare the hit count to the parser's count.
Benign mismatches exist (comments, strings, docblocks), so this warns. But a
parser count *below* the grep count means a real call site was missed, which is
the failure mode that survives the whole exercise and breaks in production.
Investigate every instance and either fix the parser or record in
`needs-review.md` why the extra grep hits are not call sites.

## Determinism

Same input, same output. Sort keys, sort arrays, do not embed timestamps or
absolute paths in `extraction.json`. Re-extraction diffs are only useful if
unrelated noise stays out of them.
