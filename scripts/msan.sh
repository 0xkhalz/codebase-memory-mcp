#!/usr/bin/env bash
# msan.sh — MemorySanitizer lane (stage 2: full coverage incl. the C++ paths).
#
# Runs inside the cbm-msan image (test-infrastructure/Dockerfile.msan), which
# provides MSan-instrumented libc++/libc++abi/libunwind and zlib in /opt/msan.
# Vendored C deps compile in-tree and are instrumented by the build itself.
#
# MSan detects uninitialized READS — the one memory-error class ASan/LSan and
# the clang-analyzer lane do not cover dynamically. halt_on_error stays ON:
# a finding is a bug (or an interceptor gap to triage), never board data.
#
# Usage: scripts/msan.sh [suite ...]   (default: full suite)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MSAN_PREFIX="${MSAN_PREFIX:-/opt/msan}"
if [ ! -d "$MSAN_PREFIX/lib" ]; then
    echo "FATAL: MSan-instrumented runtime not found at $MSAN_PREFIX (build test-infrastructure/Dockerfile.msan)" >&2
    exit 1
fi

# -isystem: the image deliberately has no system zlib (so the instrumented
# one cannot be shadowed); its headers live under the MSan prefix.
MSAN_SAN="-fsanitize=memory -fsanitize-memory-track-origins=2 -fno-omit-frame-pointer -isystem $MSAN_PREFIX/include"

# Always clean: make does not encode flags into dependencies, so a build dir
# populated under different stdlib/sanitizer flags silently mixes objects
# (observed: a stage-1 probe's libstdc++ objects surviving into the libc++
# lane and producing an unattributable report). Correctness over speed here.
make -f Makefile.cbm clean-c BUILD_DIR=build/msan >/dev/null 2>&1 || true

make -j"$(nproc)" -f Makefile.cbm build/msan/test-runner \
    CC=clang CXX=clang++ BUILD_DIR=build/msan \
    SANITIZE="$MSAN_SAN" \
    CXX_STDLIB_FLAGS="-stdlib=libc++ -nostdinc++ -isystem $MSAN_PREFIX/include/c++/v1" \
    CXX_STDLIB="-L$MSAN_PREFIX/lib -Wl,-rpath,$MSAN_PREFIX/lib -lc++ -lc++abi"

export MSAN_OPTIONS="${MSAN_OPTIONS:-halt_on_error=1:print_stats=0}"
export LD_LIBRARY_PATH="$MSAN_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "=== MSan lane: $(clang --version | head -1) ==="
./build/msan/test-runner "$@"
