#!/usr/bin/env bash
#
# Probe the PDFlib runtime and write the reference files the rest of the
# workflow depends on.
#
# The runtime is whatever resolve-runtime.sh settled on — normally an
# application image or compose service that inherits the base image, since the
# base is built to be inherited from and may not run standalone. The extension
# binary is the same either way, which is what makes the substitution sound.
#
# Produces, under analysis/reference/:
#   probe.json           full probe output
#   pdflib-methods.txt   the reflected OO method list (the authority)
#   pdflib-functions.txt the procedural function list
#   php-ri-pdflib.txt    raw `php --ri pdflib` output
#   image-digest.txt     resolved digest, in case the tag floats
#
# Requires resolve-runtime.sh to have run first.
#
# Usage: probe-runtime.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYSIS_DIR="$(dirname "$SCRIPT_DIR")"
REF_DIR="$ANALYSIS_DIR/reference"

# These scripts are designed to run from analysis/scripts/, not from the skill
# directory — run-php.sh mounts the parent of analysis/ into the container, so
# running from the wrong place silently mounts the wrong tree.
if [[ "$(basename "$ANALYSIS_DIR")" != "analysis" ]]; then
    echo "ERROR: expected to be running from analysis/scripts/, but found:" >&2
    echo "  $SCRIPT_DIR" >&2
    echo "Run /pdflib-setup first — it copies these scripts into analysis/scripts/." >&2
    exit 2
fi

mkdir -p "$REF_DIR"

if [[ ! -f "$REF_DIR/runtime.txt" ]]; then
    echo "ERROR: no runtime resolved." >&2
    echo "Run this first:" >&2
    echo "  analysis/scripts/resolve-runtime.sh <donor-repo-dir>" >&2
    echo >&2
    echo "The donor is any repo that inherits the PDFlib base image — normally" >&2
    echo "the first repo you are about to bootstrap on." >&2
    exit 2
fi

echo "Probing runtime:"
sed 's/^/  /' "$REF_DIR/runtime.txt"

IMAGE="$(grep -v '^\s*#' "$REF_DIR/base-image.txt" 2>/dev/null | grep -v '^\s*$' | head -n1 | tr -d '[:space:]' || true)"

# Resolve the digest. If the tag floats, two repos built at different times can
# run different PDFlib versions despite identical Dockerfile lines.
{
    echo "# resolved $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "declared_base: ${IMAGE:-(unknown)}"
    echo "probed_via:"
    sed 's/^/  /' "$REF_DIR/runtime.txt"
    docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null | sed 's/^/local_id: /' || true
    docker image inspect "$IMAGE" --format '{{join .RepoDigests "\n"}}' 2>/dev/null | sed 's/^/repo_digest: /' || true
} > "$REF_DIR/image-digest.txt"

"$SCRIPT_DIR/run-php.sh" --image analysis/scripts/probe.php > "$REF_DIR/probe.json"

# php --ri gives the extension's own build configuration, which the reflection
# probe cannot see.
"$SCRIPT_DIR/run-php.sh" --raw php --ri pdflib > "$REF_DIR/php-ri-pdflib.txt" 2>&1 || {
    echo "NOTE: 'php --ri pdflib' returned non-zero; see php-ri-pdflib.txt" >&2
}

# Extract the flat lists the gates consume. Done in PHP to avoid depending on
# jq being present on the host.
# Plain PHP — runs on the host when available, so paths must be absolute
# rather than relative to the container's /work mount.
PROBE_JSON="$REF_DIR/probe.json" METHODS_TXT="$REF_DIR/pdflib-methods.txt" \
FUNCTIONS_TXT="$REF_DIR/pdflib-functions.txt" \
"$SCRIPT_DIR/run-php.sh" -r '
$d = json_decode(file_get_contents(getenv("PROBE_JSON")), true);
file_put_contents(getenv("METHODS_TXT"),
    implode(PHP_EOL, $d["methods"] ?? []) . PHP_EOL);
file_put_contents(getenv("FUNCTIONS_TXT"),
    implode(PHP_EOL, $d["procedural_functions"] ?? []) . PHP_EOL);
printf("extension_loaded: %s%sclass_exists: %s%stier: %s%smethods: %d%sprocedural: %d%s",
    var_export($d["extension_loaded"] ?? false, true), PHP_EOL,
    var_export($d["class_exists"] ?? false, true), PHP_EOL,
    $d["tier"] ?? "unknown", PHP_EOL,
    count($d["methods"] ?? []), PHP_EOL,
    count($d["procedural_functions"] ?? []), PHP_EOL);
foreach (($d["notes"] ?? []) as $n) { fwrite(STDERR, "NOTE: $n" . PHP_EOL); }
'

echo
echo "Wrote:"
ls -1 "$REF_DIR"

METHOD_COUNT=$(grep -c . "$REF_DIR/pdflib-methods.txt" 2>/dev/null || echo 0)
if [[ "$METHOD_COUNT" -eq 0 ]]; then
    echo >&2
    echo "GATE FAILED: reflected method list is empty." >&2
    echo "Nothing downstream can be trusted until this is resolved." >&2
    exit 1
fi
echo
echo "GATE PASSED: reflected method list has $METHOD_COUNT entries."
