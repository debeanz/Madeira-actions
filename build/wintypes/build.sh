#!/bin/bash
# Build the stub wintypes.dll (WinRT type helpers) as an ARM64EC PE image
# with the llvm-mingw toolchain and drop it into the arm64ec-windows bundle.
# See wintypes.c for why it exists (Unity IL2CPP games import it through
# api-ms-win-core-winrt-robuffer-l1-1-0 and cannot load without it).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
MINGW="${MINGW:-llvm-mingw-20260421-ucrt-macos-universal}"
TC="$ROOT/toolchains/$MINGW/bin"
CC="$TC/arm64ec-w64-mingw32-clang"
OUT="${MADEIRA_WINTYPES_OUT:-$ROOT/app/Madeira/arm64ec-windows}"

if [ ! -x "$CC" ]; then
    echo "ERROR: no ARM64EC compiler at $CC"
    ls "$TC" | grep -i clang || true
    exit 1
fi

mkdir -p "$OUT"
echo "=== wintypes.dll ==="
"$CC" -shared -O2 -Wall -Wno-unused-parameter -s \
    -o "$OUT/wintypes.dll" "$DIR/wintypes.c" "$DIR/wintypes.def"
"$TC/llvm-readobj" --file-headers "$OUT/wintypes.dll" | grep -E "Machine|Characteristics" | head -3
"$TC/llvm-readobj" --coff-exports "$OUT/wintypes.dll" | grep -E "Name:" | head -10
ls -l "$OUT/wintypes.dll"
