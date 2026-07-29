#!/usr/bin/env bash
# Wait for VirusTotal scans to complete and check results.
# Expects: VT_API_KEY, VT_ANALYSIS (comma-separated "file=URL" pairs)
# Optional: VERSION (release tag) + GH_TOKEN — these enable the PRE-RELEASE
#           single-ML-detection tolerance described below.
set -euo pipefail

MIN_ENGINES=60
rm -f /tmp/vt_gate_fail /tmp/vt_suspects.tsv /tmp/vt_tolerated.tsv

# ── Pre-release ML false-positive tolerance ──────────────────────────────────
# A verdict may be downgraded from BLOCKED to TOLERATED only when ALL of:
#   1. the version is a pre-release (-rc. / -pre / -alpha / -beta),
#   2. every failing file was flagged by exactly ONE engine,
#   3. that engine is Microsoft and the verdict is a machine-learning
#      heuristic (result string ends in "!ml") — never a signature name,
#   4. an up-to-date Microsoft Defender ENDPOINT has scanned the identical
#      bytes clean, proven by a hash-pinned evidence file attached to the
#      draft release (defender-endpoint-verification.txt, produced by
#      scripts/ci/av-endpoint-verify.sh).
#
# Why this is sound: VT's "Microsoft" engine is a differently-configured
# instance of the same engine that ships in Windows, and for our large
# binaries it sits at an unstable ML decision boundary — across four release
# cycles the Wacatac!ml flag appeared and disappeared with no code-side cause
# (stripping, downloader removal and metadata changes each "fixed" it only
# until the next build). The shipping product's verdict on identical bytes,
# with signatures updated minutes before the scan, is the stronger statement
# of Microsoft's own estimate. Multi-engine hits, signature-named verdicts,
# non-Microsoft engines, timeouts and stable releases ALWAYS block.
TOLERANCE_ELIGIBLE=false
case "${VERSION:-}" in
*-rc.* | *-pre* | *-alpha* | *-beta*) TOLERANCE_ELIGIBLE=true ;;
esac

echo "=== Waiting for VirusTotal scans to fully complete ==="

echo "$VT_ANALYSIS" | tr ',' '\n' | while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  FILE=$(echo "$entry" | cut -d'=' -f1)
  URL=$(echo "$entry" | cut -d'=' -f2-)
  BASENAME=$(basename "$FILE")

  # Extract base64 analysis ID from URL
  ANALYSIS_ID=$(echo "$URL" | sed -n 's|.*/file-analysis/\([^/]*\)/.*|\1|p')
  if [ -z "$ANALYSIS_ID" ]; then
    ANALYSIS_ID=$(echo "$URL" | grep -oE '[a-f0-9]{64}')
    if [ -z "$ANALYSIS_ID" ]; then
      echo "BLOCKED: Cannot parse VirusTotal URL: $URL"
      echo "FAIL" >> /tmp/vt_gate_fail
      continue
    fi
  fi

  # Poll until completed (max 120 min)
  SCAN_COMPLETE=false
  for attempt in $(seq 1 720); do
    RESULT=$(curl -sf --max-time 10 \
      -H "x-apikey: $VT_API_KEY" \
      "https://www.virustotal.com/api/v3/analyses/$ANALYSIS_ID" 2>/dev/null || echo "")

    if [ -z "$RESULT" ]; then
      echo "  $BASENAME: waiting (attempt $attempt)..."
      sleep 10
      continue
    fi

    STATS=$(echo "$RESULT" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
attrs = d.get('data', {}).get('attributes', {})
status = attrs.get('status', 'queued')
stats = attrs.get('stats', {})
malicious = stats.get('malicious', 0)
suspicious = stats.get('suspicious', 0)
undetected = stats.get('undetected', 0)
harmless = stats.get('harmless', 0)
total = sum(stats.values())
completed = malicious + suspicious + undetected + harmless
print(f'{status},{malicious},{suspicious},{completed},{total}')
" 2>/dev/null || echo "queued,0,0,0,0")

    STATUS=$(echo "$STATS" | cut -d',' -f1)
    MALICIOUS=$(echo "$STATS" | cut -d',' -f2)
    SUSPICIOUS=$(echo "$STATS" | cut -d',' -f3)
    COMPLETED=$(echo "$STATS" | cut -d',' -f4)
    TOTAL=$(echo "$STATS" | cut -d',' -f5)

    if [ "$STATUS" = "completed" ]; then
      SCAN_COMPLETE=true
      if [ "$COMPLETED" -lt "$MIN_ENGINES" ]; then
        echo "NOTE: $BASENAME completed with only $COMPLETED/$TOTAL engines (< $MIN_ENGINES)"
      fi
      if [ "$MALICIOUS" -gt 0 ] || [ "$SUSPICIOUS" -gt 0 ]; then
        echo "BLOCKED: $BASENAME flagged ($MALICIOUS malicious, $SUSPICIOUS suspicious / $COMPLETED engines)"
        echo "  $URL"
        echo "FAIL" >> /tmp/vt_gate_fail
        # Record WHO flagged it so the tolerance can classify the failure.
        FLAG_INFO=$(echo "$RESULT" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
res = d.get('data', {}).get('attributes', {}).get('results', {})
flagged = [(e, (r.get('result') or '?')) for e, r in res.items()
           if r.get('category') in ('malicious', 'suspicious')]
engines = ';'.join(e for e, _ in flagged)
verdicts = ';'.join(v for _, v in flagged)
print(f'{len(flagged)}\t{engines}\t{verdicts}')
" 2>/dev/null || printf 'parse-error\tparse-error\tparse-error\n')
        SHA256=$( (sha256sum "$FILE" 2>/dev/null || shasum -a 256 "$FILE" 2>/dev/null) \
          | awk 'NR==1{print $1}')
        [ -n "$SHA256" ] || SHA256="unknown"
        printf '%s\t%s\t%s\t%s\n' "$BASENAME" "$SHA256" "$FLAG_INFO" "$COMPLETED" \
          >> /tmp/vt_suspects.tsv
      else
        echo "OK: $BASENAME clean ($COMPLETED engines, 0 detections)"
      fi
      break
    fi

    echo "  $BASENAME: $COMPLETED/$TOTAL engines ($STATUS, attempt $attempt)..."
    sleep 10
  done

  if [ "$SCAN_COMPLETE" != "true" ]; then
    echo "WARNING: $BASENAME scan did not complete in time"
    echo "FAIL" >> /tmp/vt_gate_fail
  fi
done

if [ ! -f /tmp/vt_gate_fail ]; then
  echo "=== All VirusTotal scans passed ==="
  exit 0
fi

# ── Classify the failures against the tolerance conditions ──────────────────
FAILS=$(wc -l < /tmp/vt_gate_fail | tr -d ' ')
SUSPECTS=0
[ -f /tmp/vt_suspects.tsv ] && SUSPECTS=$(wc -l < /tmp/vt_suspects.tsv | tr -d ' ')

TOLERABLE="$TOLERANCE_ELIGIBLE"
# Timeouts and unparseable URLs produce FAIL lines with no suspect record —
# those are never tolerable, and the counts diverging catches them.
[ "$FAILS" -eq "$SUSPECTS" ] || TOLERABLE=false
if [ "$TOLERABLE" = "true" ]; then
  while IFS=$'\t' read -r _name _sha nflagged engines verdicts _completed; do
    [ "$nflagged" = "1" ] || TOLERABLE=false
    [ "$engines" = "Microsoft" ] || TOLERABLE=false
    case "$verdicts" in
    *'!ml') ;;
    *) TOLERABLE=false ;;
    esac
  done < /tmp/vt_suspects.tsv
fi

if [ "$TOLERABLE" != "true" ]; then
  echo "BLOCKED: One or more VirusTotal checks failed"
  exit 1
fi

# ── Every failure matches the ML-FP pattern: require endpoint evidence ──────
EVIDENCE=/tmp/defender-endpoint-verification.txt
rm -f "$EVIDENCE"
if ! gh release download "${VERSION:?}" \
  --pattern defender-endpoint-verification.txt \
  --output "$EVIDENCE" --repo "${GITHUB_REPOSITORY:-DeusData/codebase-memory-mcp}" \
  2>/dev/null; then
  echo "BLOCKED: all detections match the pre-release ML false-positive pattern"
  echo "  (single engine, Microsoft, '!ml' verdict) but the release carries no"
  echo "  Defender endpoint evidence. To verify Microsoft's shipping product"
  echo "  against these exact bytes and attach the proof, run locally:"
  echo ""
  NAMES=$(cut -f1 /tmp/vt_suspects.tsv | sed 's/\.exe$//' | tr '\n' ' ')
  echo "    scripts/ci/av-endpoint-verify.sh $VERSION $NAMES--upload"
  echo ""
  echo "  then RE-RUN THIS JOB (Re-run failed jobs — it does not rebuild, so"
  echo "  the bytes and hashes stay identical)."
  exit 1
fi

MISSING=false
while IFS=$'\t' read -r name sha _rest; do
  if grep -qE "^${sha}[[:space:]]+[^[:space:]]+[[:space:]]+CLEAN[[:space:]]*$" "$EVIDENCE"; then
    echo "ENDPOINT-VERIFIED: $name ($sha) clean on a current Defender endpoint"
  else
    echo "BLOCKED: $name ($sha) has no CLEAN endpoint-evidence line"
    MISSING=true
  fi
done < /tmp/vt_suspects.tsv
if [ "$MISSING" = "true" ]; then
  echo "  Evidence file present but stale or incomplete — regenerate it with"
  echo "  scripts/ci/av-endpoint-verify.sh (hashes must match this build)."
  exit 1
fi

cp /tmp/vt_suspects.tsv /tmp/vt_tolerated.tsv
echo "=== TOLERATED (pre-release ML false-positive policy) ==="
sed -n 's/^# //p' "$EVIDENCE"
echo "Every remaining engine reports clean; the detections above are Microsoft"
echo "ML heuristics that Microsoft's own shipping Defender does not reproduce."
echo "The release notes will state this transparently, with the evidence file"
echo "attached as a release asset."
exit 0
