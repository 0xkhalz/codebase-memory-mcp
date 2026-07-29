#!/usr/bin/env bash
# Contract: the VirusTotal gate's pre-release ML false-positive tolerance
# (scripts/ci/check-virustotal.sh) fails CLOSED in every direction.
#
# The tolerance may downgrade a BLOCK to TOLERATED only for the exact pattern
#   pre-release version AND single engine AND Microsoft AND "!ml" verdict
#   AND hash-pinned Defender endpoint evidence attached to the release.
# Anything else — stable version, multi-engine, signature-named verdict,
# non-Microsoft engine, missing or stale evidence — must still block. A bug in
# the tolerating direction ships a flagged binary, so every branch is pinned
# here with a stubbed VT API (curl) and release store (gh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/scripts/ci/check-virustotal.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/vt-gate-contract.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# ── Stub venue ──────────────────────────────────────────────────────────────
mkdir -p "$FIX/bin" "$FIX/work/binaries" "$FIX/responses"

# curl: serve the canned VT analysis JSON selected by the analysis id in the URL.
cat > "$FIX/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
id="${url##*/analyses/}"
resp="$STUB_RESPONSES/$id.json"
[ -f "$resp" ] || exit 22
cat "$resp"
EOF

# gh: "release download" delivers the evidence fixture if the scenario has one.
cat > "$FIX/bin/gh" <<'EOF'
#!/usr/bin/env bash
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "--output" ] && out="$a"
  prev="$a"
done
[ -n "$STUB_EVIDENCE" ] && [ -f "$STUB_EVIDENCE" ] || exit 1
cp "$STUB_EVIDENCE" "$out"
EOF
chmod +x "$FIX/bin/curl" "$FIX/bin/gh"

mk_response() { # id malicious results-json
  cat > "$FIX/responses/$1.json" <<EOF
{"data":{"attributes":{"status":"completed",
  "stats":{"malicious":$2,"suspicious":0,"undetected":60,"harmless":0},
  "results":{$3}}}}
EOF
}
MS_ML='"Microsoft":{"category":"malicious","result":"Trojan:Script/Wacatac.B!ml"}'
MS_SIG='"Microsoft":{"category":"malicious","result":"Trojan:Win32/Emotet.A"}'
BKAV_ML='"Bkav":{"category":"malicious","result":"W64.AIDetectMalware!ml"}'
TWO="$MS_ML,$BKAV_ML"

mk_response clean 0 ''
mk_response msml 1 "$MS_ML"
mk_response mssig 1 "$MS_SIG"
mk_response bkav 1 "$BKAV_ML"
mk_response two 2 "$TWO"

echo "flagged-bytes" > "$FIX/work/binaries/probe"
PROBE_SHA=$( (sha256sum "$FIX/work/binaries/probe" 2>/dev/null \
  || shasum -a 256 "$FIX/work/binaries/probe") | awk 'NR==1{print $1}')

good_evidence() {
  printf '# defender-endpoint-verification\n# engine: 1.1.1\n# signatures: 1.2.3\n%s  probe  CLEAN\n' "$PROBE_SHA"
}

run_gate() { # version analysis-id evidence-file(optional) -> echoes exit code
  rm -f /tmp/vt_gate_fail /tmp/vt_suspects.tsv /tmp/vt_tolerated.tsv
  local rc=0
  (cd "$FIX/work" &&
    PATH="$FIX/bin:$PATH" \
      STUB_RESPONSES="$FIX/responses" \
      STUB_EVIDENCE="${3:-}" \
      GITHUB_REPOSITORY="stub/repo" \
      VT_API_KEY="stub" \
      VERSION="$1" \
      VT_ANALYSIS="binaries/probe=https://www.virustotal.com/gui/file-analysis/$2/detection" \
      bash "$GATE" >"$FIX/last.log" 2>&1) || rc=$?
  echo "$rc"
}

# ── 1. Clean scan passes, no tolerance involved ─────────────────────────────
[ "$(run_gate v0.9.1-rc.1 clean)" = "0" ] || fail "clean scan must pass"
[ ! -f /tmp/vt_tolerated.tsv ] || fail "clean scan must not write a tolerance record"

# ── 2. Stable version: the exact ML-FP pattern with evidence still blocks ───
good_evidence > "$FIX/evidence.txt"
[ "$(run_gate v0.9.1 msml "$FIX/evidence.txt")" != "0" ] || \
  fail "stable release must never tolerate"

# ── 3. Pre-release + pattern + NO evidence blocks, with operator instructions ─
[ "$(run_gate v0.9.1-rc.1 msml)" != "0" ] || fail "missing evidence must block"
grep -q "av-endpoint-verify.sh" "$FIX/last.log" || \
  fail "missing-evidence block must print the endpoint-verify instructions"

# ── 4. Pre-release + pattern + matching evidence tolerates ──────────────────
[ "$(run_gate v0.9.1-rc.1 msml "$FIX/evidence.txt")" = "0" ] || \
  fail "pattern + evidence must tolerate (got a block)"
[ -s /tmp/vt_tolerated.tsv ] || fail "tolerance must record what it tolerated"
grep -q "TOLERATED" "$FIX/last.log" || fail "tolerance must announce itself"

# ── 5. Stale evidence (wrong hash) blocks ───────────────────────────────────
printf '0000000000000000000000000000000000000000000000000000000000000000  probe  CLEAN\n' \
  > "$FIX/stale.txt"
[ "$(run_gate v0.9.1-rc.1 msml "$FIX/stale.txt")" != "0" ] || \
  fail "evidence for different bytes must block"

# ── 6. Evidence that says DETECTED blocks ───────────────────────────────────
printf '%s  probe  DETECTED\n' "$PROBE_SHA" > "$FIX/detected.txt"
[ "$(run_gate v0.9.1-rc.1 msml "$FIX/detected.txt")" != "0" ] || \
  fail "endpoint DETECTED must block"

# ── 7. Signature-named Microsoft verdict blocks even with evidence ──────────
[ "$(run_gate v0.9.1-rc.1 mssig "$FIX/evidence.txt")" != "0" ] || \
  fail "non-!ml (signature) verdict must block"

# ── 8. Non-Microsoft single-engine !ml blocks ───────────────────────────────
[ "$(run_gate v0.9.1-rc.1 bkav "$FIX/evidence.txt")" != "0" ] || \
  fail "non-Microsoft engine must block"

# ── 9. Multi-engine blocks ──────────────────────────────────────────────────
[ "$(run_gate v0.9.1-rc.1 two "$FIX/evidence.txt")" != "0" ] || \
  fail "multi-engine detection must block"

rm -f /tmp/vt_gate_fail /tmp/vt_suspects.tsv /tmp/vt_tolerated.tsv
echo "PASS: VT gate tolerance fails closed in all nine pinned directions"
