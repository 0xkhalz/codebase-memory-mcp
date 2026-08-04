#!/usr/bin/env bash
# #1388: a hook client that cannot join because the active daemon runs a
# DIFFERENT build must say so on stdout (systemMessage) - stdout is the only
# hook channel Claude Code surfaces, so stderr-only reporting reads as eternal
# silence in-session. Requires a TEST_SEAMS=1 binary (scripts/test.sh step 5
# builds one): CBM_TEST_HOOK_CLIENT_BUILD forces the client fingerprint.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${ROOT}/build/c/codebase-memory-mcp"
if [[ ! -x "${BINARY}" && -x "${BINARY}.exe" ]]; then
  BINARY="${BINARY}.exe"
fi
if [[ ! -x "${BINARY}" ]]; then
  echo "missing binary: ${BINARY}" >&2
  exit 2
fi

tmpdir="$(mktemp -d)"
cleanup() {
  CBM_CACHE_DIR="${tmpdir}/cache" "${BINARY}" daemon stop >/dev/null 2>&1 || true
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

if ! CBM_CACHE_DIR="${tmpdir}/cache" "${BINARY}" daemon start >"${tmpdir}/daemon-start.log" 2>&1; then
  echo "daemon start failed on this host - cannot exercise the conflict path" >&2
  cat "${tmpdir}/daemon-start.log" >&2
  exit 2
fi
payload='{"session_id":"probe","hook_event_name":"PreToolUse","tool_name":"Grep","tool_input":{"pattern":"x","path":"/tmp"},"cwd":"/tmp"}'
forced_build="$(printf 'f%.0s' $(seq 1 64))"

# The daemon's cohort join completes asynchronously after `daemon start`
# returns. Wait for the STATE the assertion needs - a probe that observes the
# build conflict - with a bounded liveness backstop; never a bare sleep. The
# throttled notice marker is cleared before each probe so the stdout
# assertion stays valid on whichever probe first observes the conflict.
rc=0
out=""
for _attempt in $(seq 1 40); do
  rm -f "${tmpdir}/cache/.hook-daemon-absent-notice"
  set +e
  out="$(printf '%s' "${payload}" | CBM_CACHE_DIR="${tmpdir}/cache" \
    CBM_TEST_HOOK_CLIENT_BUILD="${forced_build}" \
    "${BINARY}" hook-augment 2>"${tmpdir}/probe.err")"
  rc=$?
  set -e
  if [[ ${rc} -ne 0 ]]; then
    echo "hook-augment must fail open (exit 0); got ${rc}" >&2
    cat "${tmpdir}/probe.err" >&2
    exit 1
  fi
  if grep -q "conflicting CBM process" "${tmpdir}/probe.err"; then
    break
  fi
  sleep 0.5
done

if ! grep -q "conflicting CBM process" "${tmpdir}/probe.err"; then
  echo "no probe observed the build conflict within the backstop - daemon cohort" >&2
  echo "never became active, or this is not a TEST_SEAMS=1 binary" >&2
  echo "--- daemon-start.log ---" >&2
  cat "${tmpdir}/daemon-start.log" >&2
  echo "--- last probe stderr ---" >&2
  cat "${tmpdir}/probe.err" >&2
  exit 2
fi
if ! printf '%s' "${out}" | grep -q "systemMessage"; then
  echo "conflicted daemon must surface a stdout systemMessage to the hook caller (#1388)" >&2
  echo "stdout was: ${out}" >&2
  exit 1
fi
if ! printf '%s' "${out}" | grep -q "daemon stop"; then
  echo "the systemMessage must carry the daemon-restart guidance (#1388)" >&2
  echo "stdout was: ${out}" >&2
  exit 1
fi

echo "ok: daemon build conflicts reach the hook caller as a systemMessage"
