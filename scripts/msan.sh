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
# Origin tracking inflates every frame; the grammar-corpus suites drive the
# deepest parser recursion in the tree. Raise what can be raised (main-thread
# stack via RLIMIT_STACK, worker stacks via the sanitized-build-only knob in
# cbm_thread_create) — see the exclusion note below for what this does NOT fix.
ulimit -s 262144 2>/dev/null || true
export CBM_THREAD_STACK_MB="${CBM_THREAD_STACK_MB:-256}"
export LD_LIBRARY_PATH="$MSAN_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "=== MSan lane: $(clang --version | head -1) ==="

# KNOWN-EXCLUDED SUITES (O10 whitelist — excluded, never silently skipped):
#
#   grammar_regression, grammar_labels — both overflow their thread stack
#   under MSan (in the cases grammar_regression_all / grammar_label_goldens).
#   NOTE these are SUITE names: the runner selects suites, and naming a test
#   here silently excludes nothing.
#
# WHY: origin tracking inflates every frame, and these suites drive the
# deepest parser recursion in the tree (one extract per grammar across ~160
# languages). It is an INSTRUMENTATION limit, not a product defect: the same
# corpora pass under ASan+UBSan on all three OS and in production builds, and
# the recursion-depth contract has its own gating home in the stack_overflow
# suites.
#
# WHAT WAS TRIED:
#  1. RLIMIT_STACK 8→64→256 MiB. Verified applied in-container; no effect,
#     the crash address barely moved. Stacks here are sized in code, so the
#     rlimit never reaches them.
#  2. CBM_THREAD_STACK_MB (added to compat_thread.c for exactly this). First
#     as a DEFAULT-only override — which silently did nothing, because
#     worker_pool/runtime/main all pass an explicit size — then as a FLOOR on
#     every thread, confirmed compiled in. Still overflows. That narrows it
#     usefully: the crashing thread is not created through cbm_thread_create,
#     and our tree has only one other pthread_create (daemon/bootstrap.c,
#     unrelated), so the creator is most likely inside a vendored library or
#     the test harness.
#  3. Clean-rebuild hygiene — which DID resolve a separate false report at
#     preprocessor.cpp:168 (mixed libstdc++/libc++ objects).
#
# NEXT STEP: find that creator (MSan labels the thread T473-T484, i.e. late in
# a long-lived process), or test -track-origins=1, which detects identically
# and only shortens the origin chain — the cheapest untried lever. Then delete
# this block and confirm both suites run.
MSAN_EXCLUDE="${MSAN_EXCLUDE:-grammar_regression grammar_labels}"

if [ "$#" -gt 0 ]; then
    ./build/msan/test-runner "$@"
else
    excl_pattern="$(printf '%s\n' $MSAN_EXCLUDE | tr '\n' '|' | sed 's/|$//')"
    suites="$(./build/msan/test-runner --list-suites | grep -Evx "$excl_pattern")"
    # Fail loudly if an entry matched no suite: a typo (or a TEST name given
    # where a SUITE name is required) would otherwise exclude nothing silently.
    for e in $MSAN_EXCLUDE; do
        ./build/msan/test-runner --list-suites | grep -qx "$e" || {
            echo "FATAL: MSAN_EXCLUDE entry '$e' is not a suite name" >&2; exit 1; }
    done
    echo "--- excluded: $MSAN_EXCLUDE (see the comment in $0) ---"
    # shellcheck disable=SC2086  # deliberate word-splitting of the suite list
    ./build/msan/test-runner $suites
fi
