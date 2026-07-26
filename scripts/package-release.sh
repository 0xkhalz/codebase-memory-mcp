#!/usr/bin/env bash
# package-release.sh — THE canonical release-archive step. Every venue that
# turns built binaries into a release archive (release/_build.yml, the local
# artifact-flow smoke lane) runs this file; workflows provide only
# checkout/toolchain/upload around it. Archive names and contents are defined
# HERE, nowhere else, so a local artifact smoke provably exercises the same
# bytes-layout the release publishes.
#
# This script ARCHIVES what scripts/build.sh already produced — it never
# builds the product itself (the Windows launcher image is the one deliberate
# exception: it is part of the archive, not of the product build).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
    cat <<'EOF'
Usage: scripts/package-release.sh <goos> <goarch> [--variant standard|ui]
                                  [--out-dir DIR] [VAR=VAL ...]

The canonical release-archive step: identical in the release build and the
local artifact-flow smoke lane.

  goos       linux | darwin | windows
  goarch     arch label used verbatim in the archive name (amd64, arm64,
             arm64-portable, ...)
  --variant  standard (default) | ui — selects the archive NAME prefix; the
             matching binary must already have been built (--with-ui for ui).
  --out-dir  where to place the archive (default: repository root).

Make passthrough (VAR=VAL, forwarded to the Windows launcher build):
  CC= CXX=   compiler override, e.g. CC=clang CXX=clang++.

Environment:
  BUILD_DIR  build tree to archive from (default build/c).

Archive contents (defined here, canonical):
  unix:    codebase-memory-mcp LICENSE install.sh THIRD_PARTY_NOTICES.md (.tar.gz)
  windows: codebase-memory-mcp.exe (launcher) codebase-memory-mcp.payload.exe
           LICENSE install.ps1 THIRD_PARTY_NOTICES.md (.zip)
EOF
}

GOOS=""
GOARCH=""
VARIANT="standard"
OUT_DIR="$ROOT"
MAKE_ARGS=()
expect_value=""
for arg in "$@"; do
    case "$expect_value" in
    variant) VARIANT="$arg"; expect_value=""; continue ;;
    out-dir) OUT_DIR="$arg"; expect_value=""; continue ;;
    esac
    case "$arg" in
    -h | --help) usage; exit 0 ;;
    --variant) expect_value="variant" ;;
    --variant=*) VARIANT="${arg#--variant=}" ;;
    --out-dir) expect_value="out-dir" ;;
    --out-dir=*) OUT_DIR="${arg#--out-dir=}" ;;
    -*)
        echo "package-release: unknown option '$arg'. Please consult --help." >&2
        exit 2
        ;;
    *=*) MAKE_ARGS+=("$arg") ;;
    *)
        if [ -z "$GOOS" ]; then GOOS="$arg"
        elif [ -z "$GOARCH" ]; then GOARCH="$arg"
        else
            echo "package-release: unexpected argument '$arg'. Please consult --help." >&2
            exit 2
        fi
        ;;
    esac
done
[ -n "$GOOS" ] && [ -n "$GOARCH" ] || { usage >&2; exit 2; }
case "$GOOS" in
linux | darwin | windows) ;;
*) echo "package-release: goos must be linux, darwin or windows." >&2; exit 2 ;;
esac
case "$VARIANT" in
standard) SUFFIX="" ;;
ui) SUFFIX="-ui" ;;
*) echo "package-release: variant must be 'standard' or 'ui'." >&2; exit 2 ;;
esac
[ -n "$expect_value" ] && { echo "package-release: --$expect_value needs a value." >&2; exit 2; }

BUILD_DIR="${BUILD_DIR:-build/c}"
OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
NAME="codebase-memory-mcp${SUFFIX}-${GOOS}-${GOARCH}"

if [ "$GOOS" = "windows" ]; then
    # The launcher is part of the ARCHIVE layout (launcher fronts the payload),
    # so it is built here, exactly as the release venue does.
    make -f Makefile.cbm "$BUILD_DIR/codebase-memory-mcp-launcher.exe" \
        BUILD_DIR="$BUILD_DIR" ${MAKE_ARGS[@]+"${MAKE_ARGS[@]}"}
    PAYLOAD="$BUILD_DIR/codebase-memory-mcp"
    [ -f "${PAYLOAD}.exe" ] && PAYLOAD="${PAYLOAD}.exe"
    [ -f "$PAYLOAD" ] || { echo "package-release: build first; missing $PAYLOAD" >&2; exit 2; }
    PACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cbm-package.XXXXXX")"
    trap 'rm -rf "$PACK_DIR"' EXIT
    cp "$BUILD_DIR/codebase-memory-mcp-launcher.exe" "$PACK_DIR/codebase-memory-mcp.exe"
    cp "$PAYLOAD" "$PACK_DIR/codebase-memory-mcp.payload.exe"
    cp LICENSE install.ps1 "$PACK_DIR/"
    scripts/gen-third-party-notices.sh "$PACK_DIR/THIRD_PARTY_NOTICES.md"
    (
        cd "$PACK_DIR"
        rm -f "$OUT_DIR/$NAME.zip"
        zip -q "$OUT_DIR/$NAME.zip" \
            codebase-memory-mcp.exe codebase-memory-mcp.payload.exe \
            LICENSE install.ps1 THIRD_PARTY_NOTICES.md
    )
    echo "=== package-release: $OUT_DIR/$NAME.zip ==="
else
    [ -f "$BUILD_DIR/codebase-memory-mcp" ] ||
        { echo "package-release: build first; missing $BUILD_DIR/codebase-memory-mcp" >&2; exit 2; }
    cp LICENSE install.sh "$BUILD_DIR/"
    scripts/gen-third-party-notices.sh "$BUILD_DIR/THIRD_PARTY_NOTICES.md"
    tar -czf "$OUT_DIR/$NAME.tar.gz" -C "$BUILD_DIR" \
        codebase-memory-mcp LICENSE install.sh THIRD_PARTY_NOTICES.md
    echo "=== package-release: $OUT_DIR/$NAME.tar.gz ==="
fi
