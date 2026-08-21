#!/usr/bin/env bash
#
# Run PHP for the analysis workflow, on the host where that works and inside the
# PDFlib base image where it does not.
#
# There are two kinds of PHP in this workflow and they have different needs:
#
#   Plain PHP  — the extraction parser and crosscheck.php. These only read
#                source files and need nikic/php-parser. Host PHP is the better
#                choice: faster, no docker round-trip, no image required.
#
#   In-image   — probe.php. The PDFlib extension exists ONLY inside the base
#                image, so reflecting it has to happen there. Use --image.
#
# A host/container PHP version mismatch does not affect extraction: php-parser
# ships its own lexer and parses target syntax independently of the runtime it
# executes on. It does affect the probe, which is why the probe is pinned to the
# image.
#
# Docker note: `docker run --rm` does not require a running container. It
# creates a throwaway one from the image. A base image meant to be inherited
# from works fine, provided its ENTRYPOINT does not swallow the command — this
# script overrides the entrypoint to avoid that.
#
# Usage:
#   run-php.sh <script.php> [args...]         host PHP if available, else image
#   run-php.sh --image <script.php> [args...] force the base image
#   run-php.sh --host  <script.php> [args...] force host PHP
#   run-php.sh -r '<code>'                    inline code (same preference)
#   run-php.sh --composer <args...>           composer, host or containerised
#   run-php.sh --raw <command> [args...]      arbitrary command in the image
#   run-php.sh --shell                        interactive shell in the image
#   run-php.sh --which                        report what would be used
#
# Environment:
#   PDFLIB_BASE_IMAGE    override the image reference
#   PDFLIB_PHP_BIN       override the host PHP binary
#   PDFLIB_FORCE_DOCKER  set to 1 to never use host PHP

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYSIS_DIR="$(dirname "$SCRIPT_DIR")"
PARENT_DIR="$(dirname "$ANALYSIS_DIR")"
IMAGE_FILE="$ANALYSIS_DIR/reference/base-image.txt"

PHP_BIN="${PDFLIB_PHP_BIN:-php}"

host_php_available() {
    [[ "${PDFLIB_FORCE_DOCKER:-0}" != "1" ]] && command -v "$PHP_BIN" >/dev/null 2>&1
}

host_php_version() {
    "$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null || echo "unknown"
}

resolve_image() {
    if [[ -n "${PDFLIB_BASE_IMAGE:-}" ]]; then
        printf '%s' "$PDFLIB_BASE_IMAGE"
        return 0
    fi
    if [[ -f "$IMAGE_FILE" ]]; then
        grep -v '^\s*#' "$IMAGE_FILE" | grep -v '^\s*$' | head -n1 | tr -d '[:space:]'
        return 0
    fi
    return 1
}

require_image() {
    local image
    if ! image="$(resolve_image)" || [[ -z "$image" ]]; then
        echo "ERROR: no base image known." >&2
        echo "Record it in $IMAGE_FILE (or set PDFLIB_BASE_IMAGE) — /pdflib-setup does this." >&2
        exit 2
    fi
    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: docker not found on PATH, and this operation needs the base image." >&2
        exit 2
    fi
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        echo "NOTE: image '$image' not present locally; attempting pull..." >&2
        if ! docker pull "$image" >&2; then
            echo "ERROR: could not obtain '$image'." >&2
            echo "If it is built locally, build it first from pcw-pce-php-pdflib/." >&2
            echo "Alternatively, any application image built FROM this base also" >&2
            echo "carries the extension — set PDFLIB_BASE_IMAGE to one of those." >&2
            exit 2
        fi
    fi
    printf '%s' "$image"
}

RUNTIME_FILE="$ANALYSIS_DIR/reference/runtime.txt"

runtime_field() {
    [[ -f "$RUNTIME_FILE" ]] || return 1
    grep "^$1:" "$RUNTIME_FILE" 2>/dev/null | head -n1 | cut -d: -f2- | sed 's/^ *//'
}

# Run PHP where the PDFlib extension actually lives.
#
# The base image is built to be inherited from and may not run standalone, so
# the runtime is normally an application image or compose service that inherits
# it — resolved once by resolve-runtime.sh and recorded in runtime.txt. The
# extension binary is identical either way, which is what makes the substitution
# sound.
#
# The script is piped in on stdin rather than mounted, so this works regardless
# of how the runtime donor's volumes are arranged.
docker_php() {
    local strategy; strategy="$(runtime_field strategy || true)"

    case "$strategy" in
        compose)
            local svc donor_path
            svc="$(runtime_field service)"
            donor_path="$(runtime_field donor_path)"
            [[ -n "$svc" && -d "$donor_path" ]] || { echo "ERROR: runtime.txt is incomplete; re-run resolve-runtime.sh." >&2; exit 2; }
            (cd "$donor_path" && docker compose run --rm -T --no-deps --quiet-pull \
                --entrypoint php "$svc" "$@")
            return
            ;;
        image)
            local img; img="$(runtime_field image)"
            [[ -n "$img" ]] || { echo "ERROR: runtime.txt names no image; re-run resolve-runtime.sh." >&2; exit 2; }
            docker run --rm -i --entrypoint php \
                --user "$(id -u):$(id -g)" \
                -v "$PARENT_DIR":/work -w /work "$img" "$@"
            return
            ;;
    esac

    # No resolved runtime: fall back to the base image directly. This works only
    # if the base image happens to run standalone, which is not guaranteed.
    local image; image="$(require_image)"
    docker run --rm -i \
        --entrypoint php \
        --user "$(id -u):$(id -g)" \
        -v "$PARENT_DIR":/work \
        -w /work \
        -e COMPOSER_HOME=/tmp/composer \
        -e COMPOSER_ALLOW_SUPERUSER=1 \
        "$image" "$@"
}

# Arbitrary command in the image (not php). Only meaningful for the image
# strategy and the base-image fallback.
docker_raw() {
    local strategy; strategy="$(runtime_field strategy || true)"
    if [[ "$strategy" == "compose" ]]; then
        local svc donor_path
        svc="$(runtime_field service)"; donor_path="$(runtime_field donor_path)"
        (cd "$donor_path" && docker compose run --rm -T --no-deps --quiet-pull \
            --entrypoint "$1" "$svc" "${@:2}")
        return
    fi
    local img
    img="$(runtime_field image || true)"
    [[ -n "$img" ]] || img="$(require_image)"
    docker run --rm -i --entrypoint "$1" \
        --user "$(id -u):$(id -g)" \
        -v "$PARENT_DIR":/work -w /work "$img" "${@:2}"
}

run_preferred() {
    if host_php_available; then
        "$PHP_BIN" "$@"
    else
        echo "NOTE: no host PHP found; falling back to the base image." >&2
        docker_php "$@"
    fi
}

[[ $# -eq 0 ]] && { sed -n '/^# Usage:/,/^# Environment:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }

case "$1" in
    --which)
        echo "parent dir:    $PARENT_DIR"
        if host_php_available; then
            echo "host php:      $(command -v "$PHP_BIN") ($(host_php_version))"
            echo "default:       host PHP"
        else
            echo "host php:      not available"
            echo "default:       base image"
        fi
        echo "base image:    $(resolve_image || echo '(not recorded)')"
        if [[ -f "$RUNTIME_FILE" ]]; then
            echo "runtime:       $(runtime_field strategy) via $(runtime_field donor 2>/dev/null || echo '?')"
        else
            echo "runtime:       (not resolved — run resolve-runtime.sh <donor-repo>)"
        fi
        echo "php-parser:    $([[ -d "$ANALYSIS_DIR/vendor/nikic/php-parser" ]] && echo installed || echo 'not installed')"
        ;;

    --image)
        shift
        docker_php "$@"
        ;;

    --host)
        shift
        if ! host_php_available; then
            echo "ERROR: host PHP requested but '$PHP_BIN' not found." >&2
            exit 2
        fi
        "$PHP_BIN" "$@"
        ;;

    --composer)
        shift
        if command -v composer >/dev/null 2>&1; then
            (cd "$ANALYSIS_DIR" && composer "$@")
        elif command -v docker >/dev/null 2>&1; then
            echo "NOTE: no host composer; using the official composer image." >&2
            docker run --rm -i \
                --user "$(id -u):$(id -g)" \
                -v "$ANALYSIS_DIR":/app -w /app \
                -e COMPOSER_HOME=/tmp/composer \
                composer:2 "$@"
        else
            echo "ERROR: neither composer nor docker is available." >&2
            echo "Install composer, or fetch composer.phar and run it with host PHP." >&2
            exit 2
        fi
        ;;

    --raw)
        shift
        docker_raw "$@"
        ;;

    --shell)
        shell_img="$(runtime_field image || true)"
        [[ -n "$shell_img" ]] || shell_img="$(require_image)"
        docker run --rm -it --entrypoint sh \
            --user "$(id -u):$(id -g)" \
            -v "$PARENT_DIR":/work -w /work "$shell_img"
        ;;

    *)
        run_preferred "$@"
        ;;
esac
