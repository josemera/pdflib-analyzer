# Findings schema

The contract between `/pdflib-analyze` and `/pdflib-synthesize`. Synthesis can
only answer questions the extraction recorded, so this schema defines the
ceiling on what the whole exercise can conclude.

Treat it as a starting point that `/pdflib-bootstrap` finalizes against real
extraction output, and revise it deliberately after that — a schema change means
every completed repo needs re-extraction.

```
analysis/findings/<repo>/
├── meta.json          # provenance
├── ingestion.json     # how PDFlib reaches this repo's runtime
├── extraction.json    # the call surface (parser output)
├── needs-review.md    # what the parser could not resolve
└── notes.md           # prose interpretation
```

## meta.json

```json
{
  "repo": "invoicing-service",
  "path": "analyzed/invoicing-service",
  "branch": "main",
  "commit": "9f3c1ab2e4d5f6a7b8c9d0e1f2a3b4c5d6e7f8a9",
  "analyzed_at": "2026-08-19T14:02:11Z",
  "parser_version": "a3f9c1e20b74",
  "php_files_scanned": 412,
  "reflected_methods_file": "reference/pdflib-methods.txt"
}
```

`commit` is what makes a finding reproducible. `parser_version` is what makes
staleness detectable. Neither is optional.

## ingestion.json

Nearly free to produce, because all repos share the base image. Record it
anyway so the corpus can *demonstrate* uniformity rather than assume it.

```json
{
  "dockerfiles": [
    { "path": "Dockerfile", "from_lines": ["FROM registry.internal/php-base:8.2-pdflib10"], "stage": "runtime" }
  ],
  "compose_files": [
    { "path": "docker-compose.yml", "uses_build": true, "direct_image": null }
  ],
  "base_image": "registry.internal/php-base:8.2-pdflib10",
  "matches_expected_base": true,
  "local_overrides": {
    "own_ini_files": ["docker/php/conf.d/zz-app.ini"],
    "installs_extensions": false,
    "sets_searchpath": true,
    "license_key_source": "env PDFLIB_LICENSE",
    "bootstrap_configuration_calls": ["app/Providers/PdfServiceProvider.php:31"]
  },
  "notes": "conf.d file raises memory_limit only; SearchPath set at runtime not build time",
  "could_not_determine": []
}
```

`local_overrides` is the part that is not redundant. A shared base image
guarantees the same PDFlib *binary*; it does not guarantee the same PDFlib
*configuration*. Font directories, `SearchPath`, license source, and
`set_option()` calls at bootstrap all change what a replacement must reproduce
and none of them are visible from the base image.

## extraction.json

Parser output. The shape below is the target; bootstrap confirms it.

```json
{
  "repo": "invoicing-service",
  "parser_version": "a3f9c1e20b74",
  "api_style": "mixed",
  "instances": [
    { "file": "app/Services/InvoicePdf.php", "line": 22, "variable": "$p", "confidence": "certain" }
  ],
  "wrapper_classes": [
    {
      "fqcn": "App\\Pdf\\DocumentBuilder",
      "file": "app/Pdf/DocumentBuilder.php",
      "holds_instance_as": "$this->pdf",
      "public_methods": ["addPage", "writeLine", "render"],
      "description": "Thin facade; every PDFlib call in the repo goes through it except the two in ReportExport.php"
    }
  ],
  "call_sites": [
    {
      "file": "app/Pdf/DocumentBuilder.php",
      "line": 47,
      "method": "load_font",
      "style": "oo",
      "receiver": "$this->pdf",
      "args": [
        { "position": 0, "kind": "literal", "value": "Helvetica" },
        { "position": 1, "kind": "literal", "value": "winansi" },
        { "position": 2, "kind": "literal", "value": "embedding=true" }
      ],
      "option_string": "embedding=true",
      "option_keys": ["embedding"],
      "context": "        $font = $this->pdf->load_font(\"Helvetica\", \"winansi\", \"embedding=true\");\n        if ($font === 0) {\n            throw new PdfException($this->pdf->get_errmsg());\n        }",
      "confidence": "certain"
    }
  ],
  "method_counts": { "load_font": 6, "fit_textline": 41, "set_option": 12 },
  "option_keys_seen": { "embedding": 6, "fontname": 3, "fillcolor": 18 },
  "configuration_calls": [
    { "file": "app/Providers/PdfServiceProvider.php", "line": 31, "call": "set_option", "option_string": "SearchPath={/usr/share/fonts}", "kind": "literal" }
  ],
  "needs_review": [
    { "file": "app/Reports/Legacy.php", "line": 88, "reason": "option string built by concatenation from config('pdf.fonts')" }
  ]
}
```

Field notes:

- **`context`** is what makes a finding self-contained. A few lines around the
  call, verbatim. Without it, synthesis has to open source files it may not be
  able to fit in context.
- **`args[].kind`** distinguishes `literal` from `variable`, `concat`,
  `constant`, or `unknown`. Non-literal arguments cannot be enumerated
  statically and are exactly what needs human eyes.
- **`option_string` and `option_keys`** are the real specification. PDFlib
  routes most configuration through option-list strings rather than function
  parameters, so the union of option keys across all repos is a larger and more
  demanding surface than the union of method names.
- **`configuration_calls`** collects both `set_option()` and `set_parameter()`,
  distinguished by the `call` field. They are broken out from `call_sites`
  because they configure global behaviour rather than emitting content, and are
  easy to overlook while focusing on drawing primitives. Keep them
  distinguishable rather than merged: `set_parameter` is the older API and a
  repo still using it may be pinned to older idioms elsewhere too. These calls
  also still appear in `call_sites` — this array is an index into them, not a
  replacement.
- **`api_style`** is `oo`, `procedural`, or `mixed`. If any repo is `mixed` or
  the corpus contains both, the replacement must provide both surfaces.
- **`confidence`** lets the parser be honest instead of silent.

## needs-review.md

One section per unresolved item: file, line, the code, why the parser could not
resolve it, and what a human would need to check. This exists so that one
unparseable file never aborts a run — the parser continues and flags.

## notes.md

Prose, written by the agent, covering:

- What documents this repo produces and the typical document lifecycle in order
- Where the wrapper boundary sits, and whether calls are concentrated or
  scattered — this determines whether the replacement must be API-perfect or
  merely wrapper-compatible
- Which hard features appear (see `pdflib-primer.md`)
- How errors are handled: exceptions, return-value checks, or neither
- Anything surprising, including anything that contradicts an earlier repo

Write it so it is still useful to someone who cannot open the repository.
