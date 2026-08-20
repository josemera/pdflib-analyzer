---
description: One-time setup — read the PDFlib base image repo and probe the image for the authoritative API surface
argument-hint: "[base-image-ref]"
---

Use the **pdflib-analysis** skill. Read its SKILL.md and
`references/pdflib-primer.md` before starting.

This command touches **no application repository**. It establishes the facts
that are global to the whole exercise: which PDFlib is installed, which product
tier, and what its exact API surface is. All application repos share this base
image, so version and tier are settled here once and are never per-repo
questions afterwards.

Base image reference, if supplied: `$1`

## 1. Create the analysis hub

If `analysis/` does not exist, create it with `reference/`, `scripts/`,
`fixtures/`, and `findings/` subdirectories, then `git init` inside `analysis/`.
Copy the skill's `scripts/` into `analysis/scripts/` and make the `.sh` files
executable, so the analysis directory is a self-contained versioned unit.

Write a `.gitignore` in `analysis/` covering `vendor/` and `composer.lock` is
**not** ignored — the lock file is part of reproducibility.

## 2. Find the base image repo

Look in the parent directory for the repo that builds the PDFlib base image
(commonly named something containing `base`, `php-base`, or `pdflib`). If you
cannot identify it confidently, list the candidate directories and ask rather
than guessing.

## 3. Read the build recipe

From that repo, determine and record in `analysis/reference/base-image.md`,
with `file:line` evidence for every claim:

- How PDFlib is installed: PECL, a vendored `.so`, a distro package, a PDFlib
  GmbH bundle, or compiled from source
- The exact PDFlib version and, if visible, which product tier binary
- How the license key is supplied (env var, mounted file, `set_option` call,
  baked into the image)
- Any `SearchPath`, font directories, encoding files, or UPR resource
  configuration baked in — these are runtime dependencies a replacement
  inherits and they are invisible from the PHP side
- Whether a PDFlib GmbH bundle is present in the repo. If so, note where the
  API reference PDF and sample code live — that documentation is worth more
  than recall for everything downstream.
- The image name and tag this repo publishes

Where the trail leaves the repo, write "could not determine" and say where it
went. Do not guess.

## 4. Probe the image

Record the image reference in `analysis/reference/base-image.txt` (use `$1` if
given, otherwise what step 3 found), then run:

```bash
analysis/scripts/probe-base-image.sh
```

This writes `probe.json`, `pdflib-methods.txt`, `pdflib-functions.txt`,
`php-ri-pdflib.txt`, and `image-digest.txt` into `analysis/reference/`.

If the image is built locally rather than pulled, build it from the base image
repo first and say so.

Check the digest output. If the tag floats (`latest`, or a branch-named tag),
note it — repos built at different times could then be running different PDFlib
versions despite identical Dockerfile lines. That is the one version question
this design does not otherwise catch.

## 5. Report

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
- Anything recorded as "could not determine"

Remember the user does not know PDFlib. Explain what the tier means rather than
naming it and moving on.

## 6. Commit

Initialise `analysis/PROGRESS.md` with the setup date, the image reference and
digest, the tier, the method count, and an empty repo table. Commit everything
in `analysis/` with a message noting the image and tier.

Then tell the user the next step is `/pdflib-bootstrap <repo-dir>` on the first
repository — and that the first repo takes several sessions because it is where
the parser gets built, while later repos take one.
