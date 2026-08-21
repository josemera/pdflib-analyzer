# Environment

Facts about the estate, supplied by the user from the base image repo's README.
Verify against the repo during `/pdflib-setup` and correct this file if it has
drifted — it is a starting point, not an authority.

## Base image targets

`pcw-pce-php-pdflib` builds several targets:

| Target | Contents |
|---|---|
| `cli-base` | PHP 8.2 CLI (trixie), CA certs, ImageMagick, msmtp, git, pdo_mysql, zip, pcntl, bcmath, gmp, imagick, Xdebug (installed, not enabled), Composer 2.5.8, PHPUnit 10.3.2 |
| `apache-base` | `cli-base` + Apache 2 (mod_headers, mod_rewrite), vhost on `/var/www/html/web`. Extensions are copied from `cli-base`, not recompiled. |
| `cli-pdflib` | `cli-base` + **PDFlib 10.0.1**, fonts, `pdflib.upr`, license keys |
| `apache-pdflib` | `apache-base` + **PDFlib 10.0.1**, fonts, `pdflib.upr`, license keys |
| `full` | `apache-pdflib` + Oracle Instant Client 21 + `pdo_oci`, Snowflake PDO driver, Gearman (pecl), Swoole (pecl) |

**Nothing in this workflow requires the base image to be built or run
standalone.** `cli-pdflib` is the *preferred* probe target because it is the
cleanest, but the reflected method list can come from any image carrying the
same PDFlib build — including an already-built application image, which a
working dev environment will have. If the base repo cannot be built, that is a
recorded fact about the estate, not a blocker.

**`cli-pdflib` is the probe target when available.** It is PHP CLI with no web server, so
`php -r` works directly and `extension_loaded("pdflib")` is guaranteed true.
The base image does not need to run standalone as a service; this target is a
command-line image by construction.

The PDFlib build is the same 10.0.1 across every pdflib target, so the reflected
method list is identical whichever one is probed.

## Resources that ship with the image

`pdflib.upr`, fonts, and license keys are baked into the pdflib targets — not
supplied by any application repo. All three are part of the replacement surface
and invisible from the PHP side:

- **`pdflib.upr`** is a PDFlib resource file mapping logical resource names
  (fonts, encodings, ICC profiles) to paths. A replacement has to honour
  whatever it declares, or font lookups that work today will fail.
- **Fonts** shipped in the image mean a repo can `load_font("Helvetica")` with
  no font file anywhere in its own tree.
- **License keys** baked into the image explain why no repo may appear to
  supply one.

Read the `.upr` file during `/pdflib-setup` and record what it declares.

## Application inventory

Fifteen apps, all named `pcw-ppe-*`. Note the infix differs from the base repo's
`pcw-pce-` — a reason to match names exactly rather than fuzzily.

| Base image | Repos |
|---|---|
| `php-apache-pdflib` (8) | `pcw-ppe-pdicat`, `pcw-ppe-signing-api`, `pcw-ppe-signs-cosmetics`, `pcw-ppe-signs-dsd`, `pcw-ppe-signs-offshelf`, `pcw-ppe-signs-promo`, `pcw-ppe-store-nametagger`, `pcw-ppe-storesigns` |
| `php-apache-pdflib-full` (6) | `pcw-ppe-athena`, `pcw-ppe-datamart-etl`, `pcw-ppe-imagetool-etl` (transitive), `pcw-ppe-planograms`, `pcw-ppe-signs-etl`, `pcw-ppe-signs-service-api` |
| `php-cli-pdflib` (1) | `pcw-ppe-signs-pdfgen` |

### Consequences for the analysis

**Ingestion is a three-way split, not uniform.** Each repo records which variant
it pins. Still cheap — one `FROM` line — but do not assert uniformity, because
it is not true. The PDFlib binary is identical across the three, which is what
matters for the API surface; the variants differ in web server and extras.

**`pcw-ppe-imagetool-etl` inherits transitively.** Its `FROM` points at
`pcw-ppe-datamart-etl`, not at a pdflib image. `/pdflib-analyze` must follow the
chain rather than reporting "no pdflib base found". This is a legitimate
pattern, not an anomaly — record the chain and the variant it resolves to.

**`pcw-ppe-signs-pdfgen` is the heaviest PDFlib user in the estate**, and is the
designated bootstrap repo. Being the widest real usage available, it gives the
parser and schema the most to be validated against. It is simultaneously the
only app on a CLI image, so it is also the fallback runtime donor.

Treat its findings as rich but atypical: it is a CLI worker and the other
fourteen are Apache web apps, so synthesis should not generalise its call
pattern to the estate without checking.

**Only `pcw-ppe-signs-pdfgen` runs on a CLI image.** Every other app is on an
Apache variant. Whether those images enable the extension for the CLI SAPI is a
build detail — if a probe against one of them reports the extension missing,
that is a SAPI question, not evidence the extension is absent. Probe
`cli-pdflib` (or `pcw-ppe-signs-pdfgen`) instead of debugging it.

**`full` adds Oracle, Snowflake, Gearman, and Swoole.** Irrelevant to PDFlib,
but relevant to the migration prerequisite of removing the extension: six apps
are on an image with substantially more in it, so the blast radius of changing
that image is wider.
