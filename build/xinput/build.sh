#!/bin/bash
# Build Madeira's replacement XInput DLLs with the llvm-mingw toolchain CI
# already downloads for DXMT, under every name a game might import:
#   - ARM64EC PE images into the arm64ec-windows bundle (x86-64 games), and
#   - i386 PE images into the i386-windows bundle (32-bit games, WoW64).
# Both talk to the same unix-side pad table (build/ntdll-unix/xinput_ios.c),
# which Gamepad.swift fills. Wine's original built-ins stay in git history.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
MINGW="${MINGW:-llvm-mingw-20260421-ucrt-macos-universal}"
TC="$ROOT/toolchains/$MINGW/bin"
CC="$TC/arm64ec-w64-mingw32-clang"
CC32="$TC/i686-w64-mingw32-clang"
OUT="${MADEIRA_XINPUT_OUT:-$ROOT/app/Madeira/arm64ec-windows}"
OUT32="${MADEIRA_XINPUT_OUT32:-$ROOT/app/Madeira/i386-windows}"
NAMES="xinput1_4 xinput1_3 xinput1_2 xinput1_1 xinput9_1_0"

for cc in "$CC" "$CC32"; do
    if [ ! -x "$cc" ]; then
        echo "ERROR: no compiler at $cc"
        echo "available clang wrappers:"
        ls "$TC" | grep -i clang || true
        exit 1
    fi
done

show() {   # machine type, imports and the export table of what we produced
    "$TC/llvm-readobj" --file-headers "$1" | grep -E "Machine|Characteristics" | head -3
    "$TC/llvm-readobj" --coff-imports "$1" | grep -E "^\s*Name:" | sort -u
    "$TC/llvm-readobj" --coff-exports "$1" | grep -E "Ordinal|Name:" | paste - - | head -20
}

mkdir -p "$OUT"
for name in $NAMES; do
    echo "=== $name.dll (ARM64EC) ==="
    # One .def per DLL name: each Microsoft XInput DLL has its own fixed
    # ordinal layout and programs import by ordinal (OneShot's Steam layer
    # imported xinput1_4 ordinal 2 and hit "unimplemented function").
    "$CC" -shared -O2 -Wall -Wno-unused-parameter -s \
        -I"$DIR" \
        -o "$OUT/$name.dll" "$DIR/xinput.c" "$DIR/$name.def"
    show "$OUT/$name.dll"
done
ls -l "$OUT"/xinput*.dll

# ---- i386 (32-bit games) ----------------------------------------------------
# The exports are stdcall, so on i386 their symbols are decorated
# (_XInputGetState@8). The shared .def files name them undecorated; rather
# than depend on the linker's stdcall fix-up, write a decorated copy of each
# .def (NAME -> NAME@<argument bytes>) and link with --kill-at so the EXPORTED
# names stay undecorated, as in Microsoft's DLLs. Ordinals are untouched.
DECOR="DllMain:12 XInputGetState:8 XInputSetState:8 XInputGetCapabilities:12
       XInputEnable:4 XInputGetDSoundAudioDeviceGuids:12 XInputGetBatteryInformation:12
       XInputGetKeystroke:12 XInputGetAudioDeviceIds:20 XInputGetStateEx:8
       XInputWaitForGuideButton:12 XInputCancelGuideButtonWait:4
       XInputPowerOffController:4 XInputGetBaseBusInformation:8 XInputGetCapabilitiesEx:16"
TMP="$(mktemp -d)"
SEDARGS=()
for pair in $DECOR; do
    fn="${pair%%:*}"; bytes="${pair##*:}"
    SEDARGS+=(-e "s/^([[:space:]]+)${fn}([[:space:]]|\$)/\\1${fn}@${bytes}\\2/")
done

mkdir -p "$OUT32"
for name in $NAMES; do
    echo "=== $name.dll (i386) ==="
    sed -E "${SEDARGS[@]}" "$DIR/$name.def" > "$TMP/$name.def"
    if ! "$CC32" -shared -O2 -Wall -Wno-unused-parameter -s -Wl,--kill-at \
            -I"$DIR" \
            -o "$OUT32/$name.dll" "$DIR/xinput.c" "$TMP/$name.def" 2>"$TMP/$name.err"; then
        cat "$TMP/$name.err"
        echo "--- decorated .def that was used:"; cat "$TMP/$name.def"
        bash "$ROOT/build/ci-report-errors.sh" "xinput-i386" "$TMP" "$name"
        exit 1
    fi
    cat "$TMP/$name.err"
    show "$OUT32/$name.dll"
    # A 32-bit game that finds an ARM64EC or x64 image under this name gets
    # "not a valid Win32 application"; make a wrong target fatal here instead.
    "$TC/llvm-readobj" --file-headers "$OUT32/$name.dll" | grep -q "IMAGE_FILE_MACHINE_I386" \
        || { echo "ERROR: $OUT32/$name.dll is not an i386 image"; exit 1; }
done
ls -l "$OUT32"/xinput*.dll
rm -rf "$TMP"
