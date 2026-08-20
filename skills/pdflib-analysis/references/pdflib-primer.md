# PDFlib primer

Enough domain framing to interpret findings. The user does not know PDFlib, so
explain rather than assume, and correct anything here against the official API
reference — which may be on disk if the base image installed from a PDFlib GmbH
bundle. Prefer the reflected method list and the reference PDF over this file
or over recall.

## Product tiers

PDFlib GmbH sells three tiers of the same library. Which one the base image
installs is the single biggest determinant of how hard the replacement is, and
`/pdflib-setup` settles it globally.

**PDFlib (base)** — generate PDFs from scratch. Text, fonts, vector graphics,
raster images, colour. Hard but bounded: this is a PDF *writer*.

**PDFlib+PDI** — adds importing pages from existing PDFs and reusing them.
Categorically harder, because it requires *reading* arbitrary PDFs produced by
anything, including malformed ones. Method names contain `pdi`.

**PPS (Personalization Server)** — adds Blocks: placeholder regions a designer
marks up in Acrobat that code fills with variable data. Requires understanding
the Block markup format as well as everything below it. Method names contain
`block`, e.g. `fill_textblock`.

If the reflected list contains no `pdi` methods, no repo can be using PDI,
regardless of what any code appears to do — the binary cannot do it.

## Option lists are the real API

Most PDFlib configuration travels in option-list strings rather than function
parameters:

```php
$p->load_font("Helvetica", "winansi", "embedding=true subsetting=true");
$p->fit_textline($text, $x, $y, "fontsize=11 fillcolor={rgb 0 0 0} position={left bottom}");
```

Consequences for the analysis:

- The union of option **keys** across the corpus is a far larger surface than
  the union of method names, and it is the actual parser specification for the
  replacement.
- Values can be composite — braced lists, nested suboptions, colour
  specifications with their own grammar.
- Options built dynamically from config or user data cannot be enumerated
  statically. They belong in `needs_review`.

A replacement that implements every method but mishandles option grammar
satisfies nothing.

## Document lifecycle

Typical flow, useful for reading a repo's PDF code in order:

1. instantiate, set global options and the license
2. begin a document (to a file or in memory)
3. load fonts, images, and other resources
4. begin a page → place content → end the page, repeated
5. end the document, retrieve the buffer if in-memory

Errors surface either as exceptions or as sentinel return values depending on
how the instance was configured. **How a repo handles errors is part of the API
surface** — a replacement must match the failure mode, not just the success
path.

## Features that change the estimate

Flag any of these in `notes.md` when they appear. Each is a substantial
subsystem, and any one of them materially changes the scope of a replacement:

- **PDI** — importing existing PDFs
- **Blocks / PPS** — designer-marked placeholder filling
- **PDF/A or PDF/X** — archival and print compliance, externally validated
- **Tagged PDF / PDF/UA** — accessibility structure
- **Textflow** — the multi-column reflowing text formatter
- **Table formatter** — automatic table layout
- **Form fields and annotations** — interactive PDF elements
- **ICC colour management** — colour profiles and conversion
- **CJK or complex-script text** — shaping, bidirectional text, encodings
- **SVG import**
- **Encryption** — permissions and password protection

## The class-name problem

You cannot declare a PHP class named `PDFlib` while the extension is loaded.
So a drop-in replacement necessarily means **removing the extension from the
base image**. That in turn means anything *else* in the estate that depends on
the extension being present has to be found before the swap — a migration
prerequisite, not a detail.

Related: font licensing and embedding is where "drop-in" quietly stops being
drop-in. Matching output requires matching font handling, and the fonts may be
supplied by the base image rather than by any repository. Record font names,
sources, and embedding settings wherever they appear.
