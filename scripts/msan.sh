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
# VENUES: the CI test-msan job (x86-64) is AUTHORITATIVE and runs with no
# exclusions. The local container is arm64, where deep-recursion suites
# overflow their thread stacks under instrumentation — MSan's shadow/stack
# handling is materially better supported on x86-64, so that limitation may
# be architectural, and the local ladder has no faithful x86-64 emulation to
# decide it. An accepted venue divergence for this lane specifically: the
# exclusions below are the LOCAL default only, and CI overrides them away.
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
# MSAN_ORIGINS: 2 = full origin chains (best reports, heaviest frames),
# 1 = immediate origin only, 0 = none. Detection is IDENTICAL at every level;
# only report quality differs, so lowering it is the first lever to try when
# frame inflation overflows a deep-recursion suite.
MSAN_ORIGINS="${MSAN_ORIGINS:-2}"
if [ "$MSAN_ORIGINS" = "0" ]; then
    MSAN_ORIGIN_FLAG=""
else
    MSAN_ORIGIN_FLAG="-fsanitize-memory-track-origins=$MSAN_ORIGINS"
fi
MSAN_SAN="-fsanitize=memory $MSAN_ORIGIN_FLAG -fno-omit-frame-pointer -isystem $MSAN_PREFIX/include"

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
#   grammar_regression, grammar_labels, pipeline — each overflows its thread
#   stack under MSan (in grammar_regression_all / grammar_label_goldens /
#   githistory_coupling_limits_output respectively).
#   NOTE these are SUITE names: the runner selects suites, and naming a test
#   here silently excludes nothing (the guard below now catches that).
#   Excluding `pipeline` is a REAL coverage cost — it is a large suite — which
#   is the strongest argument for fixing the thread-stack root cause rather
#   than growing this list.
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
#  4. MSAN_ORIGINS=1 (added above). Detection is identical at any origin
#     level, so this is pure frame savings. It MOVED the wall rather than
#     removing it: a full run at origins=1 got past both grammar suites and
#     died later in githistory_coupling_limits_output, yet running the two
#     grammar suites DIRECTLY at origins=1 still overflowed. Same flags, same
#     binary, different outcome by run context — so the trigger is cumulative
#     process state (thread ordinals T475 vs T486), not any one suite's depth.
#
# NEXT STEP: that context dependence is the real lead — it points at threads
# accumulating across a long-lived runner process rather than at recursion in
# any single suite. Find the creator of these threads (not cbm_thread_create,
# see 2 above) and give it a sanitized-build stack floor. Sharding the lane
# one suite per process would also sidestep it. Then delete this block.
MSAN_EXCLUDE="${MSAN_EXCLUDE:-grammar_regression grammar_labels pipeline}"

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
