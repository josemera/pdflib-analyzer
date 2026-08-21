---
description: One-time setup — read the pcw-pce-php-pdflib base image repo and probe the image for the authoritative API surface
argument-hint: "[donor-repo-dir]"
---

Use the **pdflib-analysis** skill. Read its SKILL.md,
`references/environment.md`, and `references/pdflib-primer.md` before starting.

This command touches **no application repository**. It establishes the facts
that are global to the whole exercise: which PDFlib is installed, which product
tier, and what its exact API surface is. All application repos share this base
image, so version and tier are settled here once and are never per-repo
questions afterwards.

Optional runtime donor for the runtime probe: `$1`. Usually unnecessary — the base
repo's `cli-pdflib` target is the normal probe path. Only needed if that build
cannot be made to work.

## 1. Create the analysis hub

If `analysis/` does not exist, create it with `reference/`, `scripts/`,
`fixtures/`, and `findings/` subdirectories, then `git init` inside `analysis/`.
Copy the skill's `scripts/` into `analysis/scripts/` and make the `.sh` files
executable, so the analysis directory is a self-contained versioned unit.

Write a `.gitignore` in `analysis/` covering `vendor/` and `composer.lock` is
**not** ignored — the lock file is part of reproducibility.

## 2. Locate the base image repo

The base image repo is `pcw-pce-php-pdflib/`, in the parent directory.

If it is not there, note it and continue — step 5 is enriching, not blocking.
Do not substitute another directory: reading the wrong repo would record a build
recipe that does not describe the extension actually installed.

## 3. Resolve a runtime

Read `references/environment.md`. The base repo builds a **`cli-pdflib`** target
— PHP CLI with PDFlib and no web server — which is the natural probe target: it
runs `php -r` directly and no application repo is involved.

Record what step 3 found in `analysis/reference/base-image.txt`, then:

```bash
analysis/scripts/resolve-runtime.sh
```

With no argument it tries `PDFLIB_RUNTIME_IMAGE`, then local images already
carrying pdflib on the CLI SAPI, then `docker build --target cli-pdflib` from the
base repo. Pass a runtime donor only if all of those fail.

If the base repo builds its targets through a Makefile or build script rather
than a plain multi-stage Dockerfile, read that build definition (step 3 should
have surfaced it), build `cli-pdflib` the way the repo intends, and re-run with
`PDFLIB_RUNTIME_IMAGE=<tag>`.

**If a donor is needed, use `pcw-ppe-signs-pdfgen`** — the only app on
`php-cli-pdflib`. The other fourteen run Apache variants where the extension may
be enabled for FPM but not CLI, which reports as the extension being missing.
Do not conclude from such a probe that PDFlib is absent.

## 4. Probe

```bash
analysis/scripts/probe-runtime.sh
```

Writes `probe.json`, `pdflib-methods.txt`, `pdflib-functions.txt`,
`php-ri-pdflib.txt`, and `image-digest.txt` into `analysis/reference/`.

Check the digest output. If the base tag floats (`latest`, or a branch-named
tag), note it — repos built at different times could then be running different
PDFlib versions despite identical Dockerfile lines. That is the one version
question this design does not otherwise catch.

## 5. Read the build recipe (enriching, not blocking)

Nothing downstream is blocked on this step — the reflected method list from
step 4 is what Phase 1 needs. This step adds provenance and, most importantly,
may locate the vendor's API reference. If the base repo is unavailable, record
that and continue; the cost is that glossary entries stay unverified.

Much of what follows can also be read from inside the runtime — the `.upr`,
fonts, and ini files are *in* the image. Use the container as a cross-check, and
as a fallback if the repo cannot be read:

```bash
analysis/scripts/run-php.sh --raw sh -c 'php --ri pdflib; find / -name "*.upr" -o -name "pdflib*" 2>/dev/null | head -40'
```

From the repo, determine and record in `analysis/reference/base-image.md`,
with `file:line` evidence for every claim:

- How PDFlib is installed: PECL, a vendored `.so`, a distro package, a PDFlib
  GmbH bundle, or compiled from source
- The exact PDFlib version and, if visible, which product tier binary
- How the license key is supplied (env var, mounted file, `set_option` call,
  baked into the image)
- The `pdflib.upr` resource file, the bundled fonts, and the license keys —
  these ship inside the image, not in any app repo, and are invisible from the
  PHP side. Read the `.upr` and record what it declares: it maps logical
  resource names to paths, so a replacement that ignores it will fail font
  lookups that work today. Bundled fonts also explain why a repo can
  `load_font("Helvetica")` with no font file in its own tree, and baked-in
  license keys explain why no repo may appear to supply one.
- Which targets the repo builds and how (multi-stage target, Makefile, script)
- **Whether a PDFlib GmbH bundle is present in the repo.** This is the highest
  value item in this step. That bundle ships the API reference PDF and sample
  code, and it is the only place the vendor's documentation is likely to exist —
  the image itself probably does not retain the docs. `GLOSSARY.md` is grounded
  against it; without it, every entry stays marked unverified and the user ends
  up learning PDFlib from a model's recall instead. Copy it somewhere stable
  under `analysis/reference/` and record the path.
- The image name and tag this repo publishes

Where the trail leaves the repo, write "could not determine" and say where it
went. Do not guess.

## 6. Report

**Gate: the reflected method list must be non-empty.** If it is empty, stop and
report — nothing downstream can be trusted.

Then tell the user, in plain language:

- Which product tier is installed and what that implies for difficulty. If
  there are no `pdi` methods, no repo can be importing PDFs regardless of what
  any code appears to do — the binary cannot do it. Say so explicitly; it
  removes a whole class of risk before any repo is analyzed.
- The method count and the procedural function count
- Which of the hard features from `pdflib-primer.md` the binary even supports
- The PDFlib version, license mechanism, and any baked-in resource paths
- Which base image targets exist and which apps use which, cross-checked
  against `references/environment.md`. Correct that file if it has drifted.
- Anything recorded as "could not determine"

Remember the user does not know PDFlib. Explain what the tier means rather than
naming it and moving on.

## 7. Commit

Initialise `analysis/PROGRESS.md` with the setup date, the image reference and
digest, the tier, the method count, and an empty repo table. Commit everything
in `analysis/` with a message noting the image and tier.

Then tell the user the next step is `/pdflib-bootstrap <repo-dir>` on whichever
repo they want to start with — and that the first repo takes several sessions
because it is where the parser gets built, while later repos take one.

Note explicitly that this was the only step needing a container. Everything from
bootstrap onward runs on host PHP.
