#!/usr/bin/env bash
# av-endpoint-verify.sh — verify release binaries on a REAL Microsoft Defender
# endpoint (the local Windows test VM) and produce the hash-pinned evidence
# file that scripts/ci/check-virustotal.sh accepts for pre-release ML false
# positives.
#
# VirusTotal's "Microsoft" engine and the shipping Defender product can
# disagree: VT runs a differently-configured engine instance, and for our
# large binaries it sits at an unstable ML decision boundary (Wacatac!ml came
# and went across four release cycles with no code-side cause). This script
# asks the authoritative source — Defender itself, signatures updated minutes
# before the scan, real-time protection on — about the exact bytes VT flagged,
# and records the answer:
#
#   defender-endpoint-verification.txt
#     # release/engine/signature header lines
#     <sha256>  <asset-name>  CLEAN|DETECTED
#
# The release gate downgrades a pre-release BLOCK to TOLERATED only when every
# flagged binary's sha256 appears here as CLEAN.
#
# Usage: scripts/ci/av-endpoint-verify.sh <version> <asset-name...> [--upload]
#   version     release tag holding the draft assets (e.g. v0.9.1-rc.1)
#   asset-name  archive basename without extension, as printed by the gate
#               (e.g. codebase-memory-mcp-ui-linux-amd64)
#   --upload    attach/replace the evidence file on the (draft) release
#
# Runs on the dev machine: needs gh (authenticated) and the local Windows VM
# (test-infrastructure/vm/win.sh), plus ~300 MB VM disk per binary.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
WIN=test-infrastructure/vm/win.sh
[ -x "$WIN" ] || { echo "av-endpoint-verify: $WIN not found — this runs on the dev machine" >&2; exit 2; }

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: scripts/ci/av-endpoint-verify.sh <version> <asset-name...> [--upload]" >&2; exit 2; }
shift
UPLOAD=false
NAMES=()
for arg in "$@"; do
  case "$arg" in
  --upload) UPLOAD=true ;;
  *) NAMES+=("$arg") ;;
  esac
done
[ "${#NAMES[@]}" -ge 1 ] || { echo "av-endpoint-verify: no asset names given" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/av-endpoint.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── Fetch + extract the exact release bytes ─────────────────────────────────
declare -a SHAS
for name in "${NAMES[@]}"; do
  if gh release download "$VERSION" --pattern "$name.tar.gz" --dir "$TMP" 2>/dev/null; then
    mkdir -p "$TMP/x-$name"
    tar -xzf "$TMP/$name.tar.gz" -C "$TMP/x-$name"
    BIN="$TMP/x-$name/codebase-memory-mcp"
  elif gh release download "$VERSION" --pattern "$name.zip" --dir "$TMP" 2>/dev/null; then
    mkdir -p "$TMP/x-$name"
    unzip -oq "$TMP/$name.zip" -d "$TMP/x-$name"
    BIN="$TMP/x-$name/codebase-memory-mcp.exe"
  else
    echo "av-endpoint-verify: no $name.tar.gz or $name.zip on release $VERSION" >&2
    exit 2
  fi
  [ -f "$BIN" ] || { echo "av-endpoint-verify: archive $name held no binary" >&2; exit 2; }
  mv "$BIN" "$TMP/probe-$name"
  SHAS+=("$(shasum -a 256 "$TMP/probe-$name" | awk '{print $1}')")
  echo "=== fetched $name (${SHAS[${#SHAS[@]}-1]}) ==="
done

# ── Build the scan driver (pure ASCII: PowerShell 5.1 decodes BOM-less .ps1
# as ANSI, and a stray non-ASCII byte corrupts the parse) ────────────────────
PS1="$TMP/av-verify.ps1"
{
  echo '$mp = Join-Path $env:ProgramFiles "Windows Defender\MpCmdRun.exe"'
  echo '& $mp -SignatureUpdate | Out-Null'
  echo '$s = Get-MpComputerStatus'
  echo 'Write-Output ("ENGINE=" + $s.AMEngineVersion)'
  echo 'Write-Output ("SIGNATURES=" + $s.AntivirusSignatureVersion)'
  echo 'Write-Output ("SIG_UPDATED=" + $s.AntivirusSignatureLastUpdated.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))'
  echo 'Write-Output ("RTP=" + $s.RealTimeProtectionEnabled)'
  for name in "${NAMES[@]}"; do
    echo '$f = "C:\Users\test\av-verify-'"$name"'"'
    echo 'if (-not (Test-Path $f)) { Write-Output ("RESULT '"$name"' MISSING") } else {'
    echo '  & $mp -Scan -ScanType 3 -File $f | Out-Null'
    echo '  $code = $LASTEXITCODE'
    # RTP quarantining the file between push and scan is itself a detection.
    echo '  if ($code -eq 0 -and (Test-Path $f)) { Write-Output ("RESULT '"$name"' CLEAN") }'
    echo '  else { Write-Output ("RESULT '"$name"' DETECTED code=" + $code) }'
    echo '  Remove-Item $f -Force -ErrorAction SilentlyContinue'
    echo '}'
  done
} > "$PS1"
LC_ALL=C grep -q '[^ -~]' "$PS1" && { echo "av-endpoint-verify: driver is not pure ASCII" >&2; exit 2; }

# ── Push and scan ───────────────────────────────────────────────────────────
for name in "${NAMES[@]}"; do
  echo "=== pushing $name to the VM ==="
  "$WIN" push-file "$TMP/probe-$name" "C:/Users/test/av-verify-$name"
done
"$WIN" push-file "$PS1" "C:/Users/test/av-verify.ps1"
echo "=== updating signatures + scanning on the endpoint ==="
SCAN_OUT="$TMP/scan-out.txt"
"$WIN" sh "powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/test/av-verify.ps1" | tee "$SCAN_OUT"

ENGINE=$(sed -n 's/^ENGINE=//p' "$SCAN_OUT" | tr -d '\r' | tail -1)
SIGS=$(sed -n 's/^SIGNATURES=//p' "$SCAN_OUT" | tr -d '\r' | tail -1)
SIG_UPDATED=$(sed -n 's/^SIG_UPDATED=//p' "$SCAN_OUT" | tr -d '\r' | tail -1)
RTP=$(sed -n 's/^RTP=//p' "$SCAN_OUT" | tr -d '\r' | tail -1)
[ -n "$ENGINE" ] && [ -n "$SIGS" ] || { echo "av-endpoint-verify: endpoint did not report engine/signature versions" >&2; exit 1; }
[ "$RTP" = "True" ] || { echo "av-endpoint-verify: real-time protection is OFF on the VM — evidence would be meaningless" >&2; exit 1; }

# ── Write the evidence file ─────────────────────────────────────────────────
OUT="defender-endpoint-verification.txt"
{
  echo "# defender-endpoint-verification"
  echo "# release: $VERSION"
  echo "# generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# venue: local Windows 11 ARM64 VM, Microsoft Defender endpoint, real-time protection on"
  echo "# engine: $ENGINE"
  echo "# signatures: $SIGS (updated $SIG_UPDATED)"
} > "$OUT"

FAILED=false
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"
  verdict=$(sed -n "s/^RESULT $name //p" "$SCAN_OUT" | tr -d '\r' | tail -1)
  case "$verdict" in
  CLEAN) printf '%s  %s  CLEAN\n' "${SHAS[$i]}" "$name" >> "$OUT" ;;
  *)
    printf '%s  %s  DETECTED\n' "${SHAS[$i]}" "$name" >> "$OUT"
    echo "av-endpoint-verify: $name verdict '$verdict' — NOT clean" >&2
    FAILED=true
    ;;
  esac
done

echo "=== evidence written: $OUT ==="
cat "$OUT"

if [ "$FAILED" = "true" ]; then
  echo "av-endpoint-verify: Defender itself reports a detection — this is NOT" >&2
  echo "the false-positive pattern; do not release these binaries." >&2
  exit 1
fi

if [ "$UPLOAD" = "true" ]; then
  gh release upload "$VERSION" "$OUT" --clobber
  echo "=== uploaded $OUT to release $VERSION ==="
fi
