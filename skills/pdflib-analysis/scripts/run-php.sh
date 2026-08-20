#!/usr/bin/env bash
#
# Run a PHP script inside the PDFlib base image, with the parent workspace
# mounted at /work.
#
# The dev environment is dockerized and the host may have no PHP at all. Running
# through the base image also guarantees the same PHP and PDFlib version as
# production, which matters when the whole exercise is about matching an API
# exactly.
#
# Usage:
#   run-php.sh <script.php> [args...]        run a script (paths relative to parent)
#   run-php.sh --composer <composer-args>    run composer inside the image
#   run-php.sh --shell                       interactive shell in the image
#   run-php.sh --raw <command> [args...]     arbitrary command in the image
#
# The image is read from analysis/reference/base-image.txt, written by
# /pdflib-setup. Override with PDFLIB_BASE_IMAGE.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# analysis/scripts -> analysis -> parent
ANALYSIS_DIR="$(dirname "$SCRIPT_DIR")"
PARENT_DIR="$(dirname "$ANALYSIS_DIR")"

IMAGE_FILE="$ANALYSIS_DIR/reference/base-image.txt"

if [[ -n "${PDFLIB_BASE_IMAGE:-}" ]]; then
    IMAGE="$PDFLIB_BASE_IMAGE"
elif [[ -f "$IMAGE_FILE" ]]; then
    IMAGE="$(grep -v '^\s*#' "$IMAGE_FILE" | grep -v '^\s*$' | head -n1 | tr -d '[:space:]')"
else
    echo "ERROR: no base image known." >&2
    echo "Run /pdflib-setup first, or set PDFLIB_BASE_IMAGE." >&2
    exit 2
fi

if [[ -z "$IMAGE" ]]; then
    echo "ERROR: $IMAGE_FILE is empty." >&2
    exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found on PATH." >&2
    exit 2
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "NOTE: image '$IMAGE' not present locally; attempting pull..." >&2
    docker pull "$IMAGE" >&2 || {
        echo "ERROR: could not pull '$IMAGE'." >&2
        echo "If the base image is built locally, build it first from the base image repo." >&2
        exit 2
    }
fi

# Run as the invoking user so files written into the workspace are not
# root-owned. Not all images tolerate this; fall back if it fails.
USER_FLAG=(--user "$(id -u):$(id -g)")

docker_run() {
    docker run --rm -i \
        "${USER_FLAG[@]}" \
        -v "$PARENT_DIR":/work \
        -w /work \
        -e COMPOSER_HOME=/tmp/composer \
        -e COMPOSER_ALLOW_SUPERUSER=1 \
        "$IMAGE" "$@"
}

if [[ $# -eq 0 ]]; then
    echo "Usage: run-php.sh <script.php> [args...] | --composer ... | --shell | --raw ..." >&2
    exit 64
fi

case "$1" in
    --composer)
        shift
        if ! docker_run composer "$@"; then
            echo "NOTE: composer may not be installed in the base image." >&2
            echo "If so, install php-parser on the host, or add a one-off image:" >&2
            echo "  docker run --rm -v \"$ANALYSIS_DIR\":/app -w /app composer:2 require nikic/php-parser" >&2
            exit 1
        fi
        ;;
    --shell)
        docker run --rm -it "${USER_FLAG[@]}" -v "$PARENT_DIR":/work -w /work "$IMAGE" sh
        ;;
    --raw)
        shift
        docker_run "$@"
        ;;
    *)
        docker_run php "$@"
        ;;
esac
