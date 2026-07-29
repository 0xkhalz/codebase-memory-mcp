#!/usr/bin/env bash
# Append the Security Verification section to the release notes: per-binary
# sha256 + VirusTotal links, and — when the pre-release ML false-positive
# tolerance fired (scripts/ci/check-virustotal.sh wrote /tmp/vt_tolerated.tsv)
# — an honest annotation instead of a blanket "0 detections" claim.
# Expects: GH_TOKEN, VERSION; run from the verify job workspace (binaries/).
set -euo pipefail

TOL=/tmp/vt_tolerated.tsv

TABLE="\n\n## Security Verification\n\n"
if [ -s "$TOL" ]; then
  N=$(wc -l < "$TOL" | tr -d ' ')
  TABLE+="All release binaries were scanned with 70+ antivirus engines. "
  TABLE+="**${N} of them currently show a single machine-learning heuristic detection** "
  TABLE+="(Microsoft \`Wacatac!ml\`) that we have verified to be a false positive: "
  TABLE+="an up-to-date Microsoft Defender endpoint — signatures updated at scan time, "
  TABLE+="real-time protection on — scans the identical bytes clean. The hash-pinned "
  TABLE+="evidence is attached to this release as \`defender-endpoint-verification.txt\`, "
  TABLE+="and a false-positive report for these exact hashes has been submitted to "
  TABLE+="Microsoft. See **Antivirus false positives on release binaries** in the notes "
  TABLE+="above for the full story and what we are doing about it.\n\n"
else
  TABLE+="All release binaries scanned with 70+ antivirus engines — **0 detections**.\n\n"
fi
TABLE+="| Binary | SHA-256 | VirusTotal |\n"
TABLE+="|--------|---------|------------|\n"

for bin in binaries/codebase-memory-mcp-*; do
  [ -f "$bin" ] || continue
  name=$(basename "$bin")
  sha256=$(sha256sum "$bin" 2>/dev/null | awk '{print $1}' \
    || shasum -a 256 "$bin" | awk '{print $1}')
  label=$(echo "$name" | sed 's/^codebase-memory-mcp-//' | sed 's/\.exe$//')
  short="${sha256:0:20}..."
  vt_url="https://www.virustotal.com/gui/file/${sha256}/detection"
  if [ -s "$TOL" ] && grep -q "^${name}	" "$TOL"; then
    completed=$(grep "^${name}	" "$TOL" | cut -f6)
    cell="[1/${completed} ⚠️ ML false positive, endpoint-verified clean](${vt_url})"
  else
    cell="[0 detections ✅](${vt_url})"
  fi
  TABLE+="| \`${label}\` | \`${short}\` | ${cell} |\n"
done

CURRENT=$(gh release view "$VERSION" \
  --json body --jq '.body // ""' --repo "$GITHUB_REPOSITORY")
printf '%s%b' "$CURRENT" "$TABLE" > /tmp/release_notes.md
gh release edit "$VERSION" \
  --notes-file /tmp/release_notes.md --repo "$GITHUB_REPOSITORY"
