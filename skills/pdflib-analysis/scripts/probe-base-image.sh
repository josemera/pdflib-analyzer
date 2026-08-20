#!/usr/bin/env bash
#
# Probe the PDFlib base image and write the reference files the rest of the
# workflow depends on.
#
# Produces, under analysis/reference/:
#   probe.json           full probe output
#   pdflib-methods.txt   the reflected OO method list (the authority)
#   pdflib-functions.txt the procedural function list
#   php-ri-pdflib.txt    raw `php --ri pdflib` output
#   image-digest.txt     resolved digest, in case the tag floats
#
# Usage: probe-base-image.sh [image-ref]
#   With no argument, reads analysis/reference/base-image.txt.

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

if [[ $# -ge 1 ]]; then
    printf '%s\n' "$1" > "$REF_DIR/base-image.txt"
fi

if [[ ! -f "$REF_DIR/base-image.txt" ]]; then
    echo "ERROR: no base image recorded." >&2
    echo "Pass it as an argument, e.g.:" >&2
    echo "  probe-base-image.sh registry.internal/php-base:8.2-pdflib10" >&2
    exit 2
fi

IMAGE="$(grep -v '^\s*#' "$REF_DIR/base-image.txt" | grep -v '^\s*$' | head -n1 | tr -d '[:space:]')"
echo "Probing image: $IMAGE"

# Resolve the digest. If the tag floats, two repos built at different times can
# run different PDFlib versions despite identical Dockerfile lines.
{
    echo "# resolved $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "image: $IMAGE"
    docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null | sed 's/^/local_id: /' || true
    docker image inspect "$IMAGE" --format '{{join .RepoDigests "\n"}}' 2>/dev/null | sed 's/^/repo_digest: /' || true
} > "$REF_DIR/image-digest.txt"

"$SCRIPT_DIR/run-php.sh" analysis/scripts/probe.php > "$REF_DIR/probe.json"

# php --ri gives the extension's own build configuration, which the reflection
# probe cannot see.
"$SCRIPT_DIR/run-php.sh" --raw php --ri pdflib > "$REF_DIR/php-ri-pdflib.txt" 2>&1 || {
    echo "NOTE: 'php --ri pdflib' returned non-zero; see php-ri-pdflib.txt" >&2
}

# Extract the flat lists the gates consume. Done in PHP to avoid depending on
# jq being present on the host.
"$SCRIPT_DIR/run-php.sh" -r '
$d = json_decode(file_get_contents("analysis/reference/probe.json"), true);
file_put_contents("analysis/reference/pdflib-methods.txt",
    implode(PHP_EOL, $d["methods"] ?? []) . PHP_EOL);
file_put_contents("analysis/reference/pdflib-functions.txt",
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
