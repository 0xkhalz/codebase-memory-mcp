#!/usr/bin/env bash
#
# memlab.sh — deterministic memory-attribution run for #581.
#
# The soak answers "did memory grow over eight minutes"; this answers "which
# allocation sites retained it", in about a minute, with a fixed request count
# so two runs are directly comparable. Everything that made soak numbers hard
# to compare — wall-clock duration, background reindexes, crash-recovery
# phases, throughput differences between builds — is deliberately absent.
#
# Usage: scripts/memlab.sh <binary> [requests] [label]
#
# Output: memlab-<label>.jsonl  (profiler records, one block per sample)
#         memlab-<label>.log    (daemon log with mem.census lines)
# Analyse with: scripts/memlab-report.py memlab-<label>.jsonl --census memlab-<label>.log
set -u

BINARY="${1:?usage: memlab.sh <binary> [requests] [label]}"
REQUESTS="${2:-200}"
LABEL="${3:-$(uname -s | tr '[:upper:]' '[:lower:]')}"

if [ ! -x "$BINARY" ]; then
    echo "FAIL: $BINARY is not executable" >&2
    exit 2
fi

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t memlab)
PROFILE_OUT="$PWD/memlab-${LABEL}.jsonl"
RUN_LOG="$PWD/memlab-${LABEL}.log"
rm -f "$PROFILE_OUT" "$RUN_LOG"

cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# A fixed corpus: same file count and content on every platform, so a
# difference in the output cannot come from a difference in the input.
CORPUS="$WORK/corpus"
mkdir -p "$CORPUS/src"
for i in $(seq 1 60); do
    cat > "$CORPUS/src/module_$i.py" <<EOF
class Widget$i:
    """Fixed corpus file $i."""
    def __init__(self, name):
        self.name = name
        self.parts = []

    def attach(self, part):
        self.parts.append(part)
        return self

    def render(self):
        return "-".join(str(p) for p in self.parts)

def build_$i(count):
    widget = Widget$i("w$i")
    for index in range(count):
        widget.attach(index)
    return widget.render()
EOF
done

echo "=== memlab: binary=$BINARY requests=$REQUESTS label=$LABEL ==="
echo "corpus: $(find "$CORPUS" -name '*.py' | wc -l | tr -d ' ') files"

export CBM_CACHE_DIR="$WORK/cache"
export CBM_MEM_PROFILE=1
export CBM_MEM_PROFILE_OUT="$PROFILE_OUT"
export CBM_MEM_CENSUS=1
export CBM_LOG_LEVEL=info
export CBM_LOG_FORMAT=text
mkdir -p "$CBM_CACHE_DIR"

# Drive the MCP stdio path via the request/response driver (see its header for
# why batching into a closed stdin does not work).
python3 "$(dirname "$0")/memlab-drive.py" "$BINARY" "$CORPUS" "$REQUESTS" > "$WORK/drive.out" 2>&1
RC=$?
# With CBM_CACHE_DIR set the process logs to its own file rather than stderr,
# so fold that in or the census series is invisible.
cat "$CBM_CACHE_DIR"/logs/*.log >> "$RUN_LOG" 2>/dev/null || true
RESPONSES=$(sed -n "s/.*served=\\([0-9]*\\).*/\\1/p" "$WORK/drive.out" | head -1); RESPONSES=${RESPONSES:-0}
CENSUS=$(grep -c "mem.census" "$RUN_LOG" 2>/dev/null | head -1); CENSUS=${CENSUS:-0}
SITES=$(grep -c '"site"' "$PROFILE_OUT" 2>/dev/null | head -1); SITES=${SITES:-0}

echo "exit=$RC responses=$RESPONSES census_samples=$CENSUS profile_records=$SITES"
if [ "$CENSUS" -eq 0 ]; then
    echo "WARN: no census samples — check CBM_MEM_CENSUS wiring" >&2
fi
if [ "$SITES" -eq 0 ]; then
    # Not fatal, but never silent: on macOS there is no --wrap, so the
    # profiler legitimately has no observation point.
    echo "WARN: no profiler records — expected on macOS (no --wrap); a gap anywhere else" >&2
fi
echo "profile: $PROFILE_OUT"
echo "log:     $RUN_LOG"
