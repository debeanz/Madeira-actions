#!/bin/bash
# Build the Madeira session agent as a native AArch64 Windows GUI program
# with the llvm-mingw toolchain CI already downloads, and drop it into the
# aarch64-windows bundle (the desktop session's arch; every file there is
# symlinked to C:\windows\system32 at launch). See madeira-agent.c.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
MINGW="${MINGW:-llvm-mingw-20260421-ucrt-macos-universal}"
TC="$ROOT/toolchains/$MINGW/bin"
CC="$TC/aarch64-w64-mingw32-clang"
OUT="${MADEIRA_AGENT_OUT:-$ROOT/app/Madeira/aarch64-windows}"

if [ ! -x "$CC" ]; then
    echo "ERROR: no AArch64 mingw compiler at $CC"
    ls "$TC" | grep -i clang || true
    exit 1
fi

mkdir -p "$OUT"
echo "=== madeira-agent.exe ==="
# -municode: wWinMain entry; -mwindows: GUI subsystem, so Wine never gives
# it a console window.
"$CC" -O2 -Wall -municode -mwindows -s \
    -o "$OUT/madeira-agent.exe" "$DIR/madeira-agent.c"
"$TC/llvm-readobj" --file-headers "$OUT/madeira-agent.exe" | grep -E "Machine|Subsystem|Characteristics" | head -4
"$TC/llvm-readobj" --coff-imports "$OUT/madeira-agent.exe" | grep -E "^\s*Name:" | sort -u
ls -l "$OUT/madeira-agent.exe"
