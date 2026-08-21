#!/usr/bin/env bash
#
# Emit the current parser version: a short hash of the parser script's own
# source.
#
# A hash rather than a hand-maintained constant, because a constant can be
# forgotten and a hash cannot. Change the parser, the version changes, and every
# findings file produced by the old version is provably stale.
#
# Usage: parser-version.sh [path-to-parser]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="${1:-$SCRIPT_DIR/extract-pdflib-calls.php}"

if [[ ! -f "$PARSER" ]]; then
    echo "ERROR: parser not found at $PARSER" >&2
    echo "The parser is written during /pdflib-bootstrap, not shipped with the skill." >&2
    exit 2
fi

if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$PARSER" | cut -c1-12
elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$PARSER" | cut -c1-12
else
    echo "ERROR: no sha256sum or shasum on PATH." >&2
    exit 2
fi
