#!/usr/bin/env bash
# MemorySanitizer lane — the canonical entry, used by every venue.
#
# MSan needs every linked library instrumented or reads of memory those
# libraries wrote report as uninitialized, so the lane runs inside an image
# carrying an MSan-built libc++/libc++abi/libunwind and zlib
# (test-infrastructure/Dockerfile.msan). Building that image is the expensive
# part, hence the buildx layer cache.
#
# Locally the same lane is reached through the compose service:
#   ./test-infrastructure/run.sh msan
# which shares scripts/msan.sh with this path — one harness, both venues.
#
# Usage: scripts/ci/msan-lane.sh [build|run|all]   (default: all)
set -euo pipefail

cd "$(dirname "$0")/../.."

CACHE_DIR="${MSAN_BUILDX_CACHE:-/tmp/.buildx-msan}"
IMAGE="${MSAN_IMAGE:-cbm-msan:ci}"
BUILDER="${MSAN_BUILDER:-msan-builder}"
MODE="${1:-all}"

build_image() {
    echo "=== MSan image (buildx, cached layers) ==="
    # A builder may already exist from a previous step or a retried job.
    docker buildx create --use --name "$BUILDER" 2>/dev/null || docker buildx use "$BUILDER"
    docker buildx build \
        --cache-from "type=local,src=$CACHE_DIR" \
        --cache-to "type=local,dest=$CACHE_DIR,mode=max" \
        -f test-infrastructure/Dockerfile.msan \
        -t "$IMAGE" --load test-infrastructure/
}

run_suite() {
    # MSAN_EXCLUDE is deliberately empty: a sanitizer that skips code asserts
    # coverage it does not have. scripts/msan.sh warns loudly if it is ever set.
    echo "=== MSan full suite (no exclusions) ==="
    docker run --rm -e MSAN_EXCLUDE="" -v "$PWD:/src" -w /src "$IMAGE"
}

case "$MODE" in
    build) build_image ;;
    run)   run_suite ;;
    all)   build_image; run_suite ;;
    *)     echo "usage: $0 [build|run|all]" >&2; exit 2 ;;
esac
