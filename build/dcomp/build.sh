#!/bin/bash
# Build the stub dcomp.dll (DirectComposition) as an ARM64EC PE image with
# the llvm-mingw toolchain and drop it into the arm64ec-windows bundle.
# See dcomp.c for why it exists (Rhythm Doctor's multiwindow_unity plugin
# imports it and cannot load without it).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
MINGW="${MINGW:-llvm-mingw-20260421-ucrt-macos-universal}"
TC="$ROOT/toolchains/$MINGW/bin"
CC="$TC/arm64ec-w64-mingw32-clang"
OUT="${MADEIRA_DCOMP_OUT:-$ROOT/app/Madeira/arm64ec-windows}"

if [ ! -x "$CC" ]; then
    echo "ERROR: no ARM64EC compiler at $CC"
    ls "$TC" | grep -i clang || true
    exit 1
fi

mkdir -p "$OUT"
echo "=== dcomp.dll ==="
"$CC" -shared -O2 -Wall -Wno-unused-parameter -s \
    -o "$OUT/dcomp.dll" "$DIR/dcomp.c" "$DIR/dcomp.def" -lole32
"$TC/llvm-readobj" --file-headers "$OUT/dcomp.dll" | grep -E "Machine|Characteristics" | head -3
"$TC/llvm-readobj" --coff-imports "$OUT/dcomp.dll" | grep -E "^\s*Name:" | sort -u
"$TC/llvm-readobj" --coff-exports "$OUT/dcomp.dll" | grep -E "Name:" | head -20
ls -l "$OUT/dcomp.dll"
