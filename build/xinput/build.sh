#!/bin/bash
# Build Madeira's replacement XInput DLLs as ARM64EC PE images with the
# llvm-mingw toolchain CI already downloads for DXMT, and drop them into
# the arm64ec-windows bundle (the one x86-64 games use) under every name
# a game might import. Wine's original built-ins stay in git history.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
MINGW="${MINGW:-llvm-mingw-20260421-ucrt-macos-universal}"
TC="$ROOT/toolchains/$MINGW/bin"
CC="$TC/arm64ec-w64-mingw32-clang"
OUT="${MADEIRA_XINPUT_OUT:-$ROOT/app/Madeira/arm64ec-windows}"

if [ ! -x "$CC" ]; then
    echo "ERROR: no ARM64EC compiler at $CC"
    echo "available clang wrappers:"
    ls "$TC" | grep -i clang || true
    exit 1
fi

mkdir -p "$OUT"
for name in xinput1_4 xinput1_3 xinput1_2 xinput1_1 xinput9_1_0; do
    echo "=== $name.dll ==="
    "$CC" -shared -O2 -Wall -Wno-unused-parameter -s \
        -I"$DIR" \
        -o "$OUT/$name.dll" "$DIR/xinput.c" "$DIR/xinput.def"
    # Show what we produced: machine type, imports and the export table.
    "$TC/llvm-readobj" --file-headers "$OUT/$name.dll" | grep -E "Machine|Characteristics" | head -3
    "$TC/llvm-readobj" --coff-imports "$OUT/$name.dll" | grep -E "^\s*Name:" | sort -u
    "$TC/llvm-readobj" --coff-exports "$OUT/$name.dll" | grep -E "Ordinal|Name:" | paste - - | head -20
done
ls -l "$OUT"/xinput*.dll
