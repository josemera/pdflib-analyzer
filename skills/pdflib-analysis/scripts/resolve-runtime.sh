#!/usr/bin/env bash
#
# Resolve a runnable PHP runtime that has the PDFlib extension loaded.
#
# The base repo builds a `cli-pdflib` target: PHP CLI with PDFlib and no web
# server. That target runs `php -r` directly, so it is the natural probe target
# and no donor repo is needed in the normal case.
#
# Fallbacks exist because a local build may not be possible. Any image carrying
# the same PDFlib build works — the reflected method list is a property of the
# extension, not of the application. Prefer CLI-flavoured images: the Apache
# variants may not enable the extension for the CLI SAPI, which looks identical
# to the extension being absent.
#
# This is needed exactly once, during /pdflib-setup. Nothing after that touches
# a container.
#
# Usage:
#   resolve-runtime.sh                     auto: local images, then cli-pdflib
#   resolve-runtime.sh <donor-repo-dir> [compose-service]
#   resolve-runtime.sh --verify            re-check the recorded runtime
#
# Strategies, tried in order:
#   0. PDFLIB_RUNTIME_IMAGE                 an explicit tag, if set
#   1. a local image already carrying pdflib on the CLI SAPI
#   2. docker build --target cli-pdflib     from the base repo
#   3. docker compose run --rm --no-deps    in a donor repo
#   4. docker build the donor's Dockerfile
#
# Records the winning strategy in analysis/reference/runtime.txt so run-php.sh
# --image can reuse it without rediscovering anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYSIS_DIR="$(dirname "$SCRIPT_DIR")"
PARENT_DIR="$(dirname "$ANALYSIS_DIR")"
REF_DIR="$ANALYSIS_DIR/reference"
RUNTIME_FILE="$REF_DIR/runtime.txt"

mkdir -p "$REF_DIR"

# One-line PHP that says whether the extension is really there. Kept tiny so it
# can be passed with -r through any invocation style.
CHECK_CODE='echo extension_loaded("pdflib") ? "PDFLIB_OK" : "PDFLIB_MISSING";'

say()  { printf '%s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker not found on PATH."

# --- verification mode ----------------------------------------------------

if [[ "${1:-}" == "--verify" ]]; then
    [[ -f "$RUNTIME_FILE" ]] || fail "no runtime recorded; run resolve-runtime.sh <donor-repo-dir> first."
    say "Recorded runtime:"
    cat "$RUNTIME_FILE" >&2
    out="$("$SCRIPT_DIR/run-php.sh" --image -r "$CHECK_CODE" 2>/dev/null || true)"
    if [[ "$out" == *PDFLIB_OK* ]]; then
        say "VERIFIED: pdflib extension is loaded in the recorded runtime."
        exit 0
    fi
    fail "recorded runtime does not have the pdflib extension loaded."
fi

record() {
    {
        echo "# resolved $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '%s\n' "$@"
    } > "$RUNTIME_FILE"
    say "Recorded runtime:"; sed 's/^/  /' "$RUNTIME_FILE" >&2
}

image_has_cli_pdflib() {
    local out
    out="$(docker run --rm -i --entrypoint php "$1" -r "$CHECK_CODE" 2>/dev/null || true)"
    [[ "$out" == *PDFLIB_OK* ]]
}

# --- strategy 0: an explicit tag ------------------------------------------

if [[ -n "${PDFLIB_RUNTIME_IMAGE:-}" ]]; then
    say "Trying PDFLIB_RUNTIME_IMAGE=$PDFLIB_RUNTIME_IMAGE"
    if image_has_cli_pdflib "$PDFLIB_RUNTIME_IMAGE"; then
        record "strategy: image" "donor: (explicit tag)" "image: $PDFLIB_RUNTIME_IMAGE"
        exit 0
    fi
    say "That image does not expose pdflib to the CLI SAPI; continuing."
fi

# --- strategy 1: a local image that already works -------------------------
#
# Usually the winner, and it needs nothing from the base repo. A working dev
# environment has these built already.
#
# The name filter is deliberately loose: a compose-built app image is typically
# named <project>-<service> (e.g. pcw-ppe-signs-pdfgen-app) and contains no
# "pdflib" at all, so matching only on that would miss exactly the images most
# likely to be present.
#
# Ordering matters. CLI-flavoured images are tried first because the Apache
# variants may enable the extension for FPM but not CLI, which is
# indistinguishable from the extension being absent.

CANDIDATE_IMAGES="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -v '<none>' \
    | grep -iE 'pdflib|pdfgen|pcw|php' || true)"

if [[ -n "$CANDIDATE_IMAGES" ]]; then
    # Tiers, best first. Each tried image costs a container start, so this is
    # capped rather than exhaustive.
    tier() { printf '%s\n' "$CANDIDATE_IMAGES" | grep -iE "$1" || true; }
    ORDERED="$(printf '%s\n%s\n%s\n%s\n%s\n' \
        "$(tier 'cli.*pdflib|pdflib.*cli')" \
        "$(tier 'pdfgen')" \
        "$(tier 'cli')" \
        "$(tier 'pdflib')" \
        "$CANDIDATE_IMAGES" | awk 'NF && !seen[$0]++' | head -n 12)"

    say "Testing local images for pdflib on the CLI SAPI..."
    for img in $ORDERED; do
        say "  trying $img"
        if image_has_cli_pdflib "$img"; then
            record "strategy: image" "donor: (local image)" "image: $img"
            exit 0
        fi
    done
    say "No local image exposed pdflib to the CLI SAPI."
fi

# --- strategy 2: build cli-pdflib from the base repo ----------------------

BASE_REPO=""
for cand in "$PARENT_DIR/pcw-pce-php-pdflib" "$PARENT_DIR/php-pdflib"; do
    [[ -d "$cand" ]] && { BASE_REPO="$cand"; break; }
done

if [[ -n "$BASE_REPO" ]]; then
    BASE_DOCKERFILE=""
    for f in Dockerfile docker/Dockerfile; do
        [[ -f "$BASE_REPO/$f" ]] && { BASE_DOCKERFILE="$f"; break; }
    done
    if [[ -n "$BASE_DOCKERFILE" ]]; then
        TAG="pdflib-analysis-runtime:cli-pdflib"
        say "Trying: docker build --target cli-pdflib in $(basename "$BASE_REPO")"
        say "(cli-pdflib is PHP CLI with PDFlib and no web server — the ideal probe target)"
        if (cd "$BASE_REPO" && docker build --target cli-pdflib -f "$BASE_DOCKERFILE" -t "$TAG" . >&2); then
            if image_has_cli_pdflib "$TAG"; then
                record "strategy: image" "donor: pcw-pce-php-pdflib (cli-pdflib target)" \
                       "image: $TAG" "dockerfile: $BASE_DOCKERFILE"
                exit 0
            fi
            say "Built cli-pdflib but pdflib is not loaded — check the target name."
        else
            say "Could not build the cli-pdflib target. It may be built by a Makefile"
            say "or build script rather than a plain multi-stage Dockerfile."
        fi
    fi
fi

# --- strategies 3 and 4 need a donor repo ---------------------------------

DONOR="${1:-}"
SERVICE="${2:-}"
if [[ -z "$DONOR" ]]; then
    cat >&2 <<'NODONOR'

No runtime found automatically, and no donor repo was given.

Pass a repo that inherits a pdflib image. The best choice is
pcw-ppe-signs-pdfgen — it is the only app on php-cli-pdflib, so the extension
is certain to be enabled for the CLI SAPI:

  resolve-runtime.sh pcw-ppe-signs-pdfgen

Any other app repo also works, but they run Apache variants where the CLI SAPI
may not have the extension enabled.
NODONOR
    exit 1
fi
[[ -d "$PARENT_DIR/$DONOR" || -d "$DONOR" ]] || fail "donor repo not found: $DONOR"

DONOR_PATH="$(cd "${DONOR#$PARENT_DIR/}" 2>/dev/null && pwd || cd "$PARENT_DIR/$DONOR" && pwd)"
DONOR_NAME="$(basename "$DONOR_PATH")"

say "Donor repo: $DONOR_PATH"

# --- record what the donor inherits from ---------------------------------
#
# The whole substitution rests on the donor inheriting the expected base. If it
# pins something else, the reflected methods could differ and the corpus would
# be built on the wrong API surface.

FROM_LINES="$(grep -rhn '^[[:space:]]*FROM' "$DONOR_PATH" --include='Dockerfile*' 2>/dev/null || true)"
if [[ -n "$FROM_LINES" ]]; then
    say "Donor FROM lines:"
    printf '%s\n' "$FROM_LINES" | sed 's/^/  /' >&2
else
    say "WARNING: no FROM lines found in $DONOR_NAME — cannot confirm what it inherits."
fi

if [[ -f "$REF_DIR/base-image.txt" ]]; then
    EXPECTED="$(grep -v '^\s*#' "$REF_DIR/base-image.txt" | grep -v '^\s*$' | head -n1 | tr -d '[:space:]')"
    if [[ -n "$EXPECTED" ]]; then
        if printf '%s' "$FROM_LINES" | grep -qF "$EXPECTED"; then
            say "Donor inherits the expected base: $EXPECTED"
        else
            say "WARNING: donor does not appear to inherit '$EXPECTED'."
            say "         Confirm this before trusting the reflected method list."
        fi
    fi
fi

# --- strategy 3: docker compose run in the donor repo ---------------------

COMPOSE_FILE=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    [[ -f "$DONOR_PATH/$f" ]] && { COMPOSE_FILE="$DONOR_PATH/$f"; break; }
done

try_compose() {
    local svc="$1"
    say "Trying: docker compose run --rm --no-deps --entrypoint php ($svc)"
    local out
    out="$(cd "$DONOR_PATH" && docker compose run --rm -T --no-deps --quiet-pull \
        --entrypoint php "$svc" -r "$CHECK_CODE" 2>/dev/null || true)"
    [[ "$out" == *PDFLIB_OK* ]]
}

if [[ -n "$COMPOSE_FILE" ]]; then
    say "Found compose file: $COMPOSE_FILE"
    if [[ -n "$SERVICE" ]]; then
        CANDIDATES="$SERVICE"
    else
        CANDIDATES="$(cd "$DONOR_PATH" && docker compose config --services 2>/dev/null || true)"
        # Try PHP-ish services first; a db or redis service will never match.
        CANDIDATES="$(printf '%s\n' $CANDIDATES | grep -Ei 'php|app|web|fpm|api|worker|cli' || printf '%s\n' $CANDIDATES)"
    fi
    for svc in $CANDIDATES; do
        if try_compose "$svc"; then
            record "strategy: compose" "donor: $DONOR_NAME" "donor_path: $DONOR_PATH" \
                   "service: $svc" "compose_file: $COMPOSE_FILE"
            exit 0
        fi
    done
    say "No compose service exposed a working pdflib; trying a direct build."
fi

# --- strategy 4: build the donor Dockerfile ------------------------------

DOCKERFILE=""
for f in Dockerfile docker/Dockerfile Dockerfile.dev; do
    [[ -f "$DONOR_PATH/$f" ]] && { DOCKERFILE="$f"; break; }
done

if [[ -n "$DOCKERFILE" ]]; then
    TAG="pdflib-analysis-runtime:$DONOR_NAME"
    say "Trying: docker build -f $DOCKERFILE -t $TAG"
    if (cd "$DONOR_PATH" && docker build -f "$DOCKERFILE" -t "$TAG" . >&2); then
        out="$(docker run --rm -i --entrypoint php "$TAG" -r "$CHECK_CODE" 2>/dev/null || true)"
        if [[ "$out" == *PDFLIB_OK* ]]; then
            record "strategy: image" "donor: $DONOR_NAME" "image: $TAG" "dockerfile: $DOCKERFILE"
            exit 0
        fi
        say "Built image does not have pdflib loaded for the CLI SAPI."
        say "Check whether the extension is enabled only for FPM."
    else
        say "Build failed. It may need build args, secrets, or registry access."
    fi
fi

cat >&2 <<'EOF'

FAILED: could not find a runtime with pdflib loaded for the CLI SAPI.

Most likely cause: the image probed is an Apache variant (php-apache-pdflib or
php-apache-pdflib-full) that enables the extension for FPM but not CLI. That
looks exactly like the extension being absent. Confirm with:

    docker run --rm --entrypoint php <image> -m | grep -i pdf

Things to try, in order of effort:

  1. Use pcw-ppe-signs-pdfgen as the donor. It is the only app on
     php-cli-pdflib, so its image has the extension on the CLI SAPI:
       resolve-runtime.sh pcw-ppe-signs-pdfgen

  2. Build the cli-pdflib target directly from the base repo, if it is built by
     a Makefile or script rather than a plain multi-stage Dockerfile. Check the
     base repo's README for the build command, then:
       PDFLIB_RUNTIME_IMAGE=<tag> resolve-runtime.sh

  3. Point at any already-built image, CLI-flavoured if possible:
       docker images | grep -i pdflib

This is needed once, during /pdflib-setup, to produce the reflected method
list. Nothing after Phase 1 touches a container.
EOF
exit 1
