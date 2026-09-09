#!/usr/bin/env bash
#
# build-local.sh — build Madeira.ipa on this Mac.
#
# A local translation of .github/workflows/main.yml. Same steps, same order,
# same flags. Differences from CI:
#
#   * actions/cache is replaced by stamp files in .build-stamps/. A stage that
#     already finished is skipped, so re-running after a failure resumes rather
#     than starting over.
#   * The LLVM iOS tree is NOT pruned afterwards (CI prunes it to fit the 10 GB
#     cache budget). Keeping it makes later rebuilds cheap.
#   * Every stage's output goes to build-logs/<stage>.log as well as the screen.
#
# NOTE: do not put IPHONEOS_DEPLOYMENT_TARGET in the environment. Apple's clang
# honours it for *every* compile in the process, including the macOS host build
# of Wine, which then fails configure. That is what broke upstream's CI.
#
# Usage:
#   ./build-local.sh                 # build everything that isn't done yet
#   ./build-local.sh --list          # show stage status and exit
#   ./build-local.sh --only wine     # run just that stage
#   ./build-local.sh --from fex      # run that stage and everything after it
#   ./build-local.sh --force wine    # clear that stage's stamp, then build
#   ./build-local.sh --clean         # clear all stamps (keeps build trees)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

IOS_DEPLOYMENT_TARGET="16.0"
MINGW="llvm-mingw-20260421-ucrt-macos-universal"

# Homebrew's bison and flex are KEG-ONLY: installed, but deliberately not
# symlinked into $(brew --prefix)/bin because macOS ships its own. Apple's
# bison is 2.3 (frozen in 2007 over GPLv3) and Wine's configure rejects it
# with "Your bison version is too old". CI did this via GITHUB_PATH.
if command -v brew >/dev/null 2>&1; then
  for _keg in bison flex; do
    _p="$(brew --prefix "$_keg" 2>/dev/null)/bin"
    [ -d "$_p" ] && PATH="$_p:$PATH"
  done
  export PATH
  unset _keg _p
fi

STAMPS="$ROOT/.build-stamps"
LOGS="$ROOT/build-logs"
mkdir -p "$STAMPS" "$LOGS"

STAGES=(preflight vcruntime ftsrc mingw wine wineverify gnutls freetype
        wineunix wineserver fex llvm shaders dxmt verify app ipa)

# ---------------------------------------------------------------- plumbing --

if [ -t 1 ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; D=""; N=""
fi

say()  { printf '%s\n' "${B}==> $*${N}"; }
ok()   { printf '%s\n' "${G}  ok${N} $*"; }
warn() { printf '%s\n' "${Y}  !! ${N}$*"; }
die()  { printf '%s\n' "${R}FATAL${N} $*" >&2; exit 1; }

done_stage() { [ -f "$STAMPS/$1" ]; }
mark()       { date -u +%Y-%m-%dT%H:%M:%SZ > "$STAMPS/$1"; }
ncpu()       { sysctl -n hw.ncpu; }

# run <stage> — dispatches to stage_<name>, tees to a log, times it
run() {
  local s="$1" t0 rc
  if done_stage "$s" && [ "${FORCED:-}" != "$s" ]; then
    printf '%s\n' "${D}--- $s (already done, $(cat "$STAMPS/$s"))${N}"
    return 0
  fi
  say "$s"
  t0=$(date +%s)
  set +e
  ( set -euxo pipefail; "stage_$s" ) 2>&1 | tee "$LOGS/$s.log"
  rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "${R}FAILED${N} stage '$s' (exit $rc) — see build-logs/$s.log"
    printf '%s\n' "  last errors:"
    grep -iE 'error:|fatal|FAILED|No such file' "$LOGS/$s.log" | tail -15 || true
    printf '\n  resume with: ./build-local.sh --from %s\n' "$s"
    exit "$rc"
  fi
  mark "$s"
  ok "$s ($(( $(date +%s) - t0 ))s)"
}

# ------------------------------------------------------------------ stages --

stage_preflight() {
  [ "$(uname -s)" = "Darwin" ] || { echo "this script must run on macOS"; exit 1; }
  sw_vers
  uname -m

  xcode-select -p
  xcodebuild -version
  SDKV="$(xcrun --sdk iphoneos --show-sdk-version)"
  echo "iphoneos SDK: $SDKV"

  # ContentView.swift uses glassEffect() (iOS 26). Older SDKs get it stripped
  # in the 'app' stage, so this is informational only.
  case "${SDKV%%.*}" in
    2[6-9]|[3-9][0-9]) echo "SDK supports glassEffect" ;;
    *) echo "NOTE: SDK < 26 — glassEffect calls will be stripped from ContentView.swift" ;;
  esac

  command -v brew >/dev/null || { echo "Homebrew required: https://brew.sh"; exit 1; }
  local missing=()
  for f in cmake ninja meson pkg-config sevenzip bison flex; do
    brew list --formula "$f" >/dev/null 2>&1 || missing+=("$f")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "installing: ${missing[*]}"
    brew install "${missing[@]}"
  fi
  command -v 7zz >/dev/null || { echo "7zz not on PATH after installing sevenzip"; exit 1; }

  # Wine's configure needs bison >= 3.0; Apple's /usr/bin/bison is 2.3.
  echo "bison: $(command -v bison) -> $(bison --version | head -1)"
  BV="$(bison --version | head -1 | awk '{print $NF}')"
  case "${BV%%.*}" in
    ''|0|1|2) echo "FATAL: bison $BV is too old for Wine's configure."
              echo "       Homebrew's bison is keg-only; this script prepends"
              echo "       $(brew --prefix bison)/bin to PATH. Check that it installed:"
              echo "         brew install bison && ls $(brew --prefix bison)/bin"
              exit 1 ;;
  esac
  echo "flex:  $(command -v flex) -> $(flex --version)"

  # Metal compiler — needed by the 'shaders' stage.
  xcrun -sdk macosx metal --version >/dev/null 2>&1 \
    || xcodebuild -downloadComponent MetalToolchain \
    || echo "WARNING: Metal toolchain unavailable; the 'shaders' stage will fail"

  # Submodules
  for d in FEX wine research/dxmt; do
    [ -n "$(ls -A "$d" 2>/dev/null)" ] || {
      echo "submodule $d is empty — run: git submodule update --init --recursive"; exit 1; }
  done

  df -h "$ROOT" | tail -1
  echo "Budget roughly 40-60 GB of disk and 1-3 hours on a laptop; LLVM is the long pole."
}

stage_vcruntime() {
  DEST="$ROOT/app/Madeira/x86_64-vcruntime"
  if [ "$(ls "$DEST"/*.dll 2>/dev/null | wc -l | tr -d ' ')" = "12" ]; then
    echo "12 DLLs already present"; return 0
  fi
  mkdir -p "$DEST"
  WORK="$ROOT/.build-tmp/vcr"; rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
  curl -sL -o vc.exe https://aka.ms/vs/17/release/vc_redist.x64.exe

  # The redist is a Burn bundle: the payload cab is APPENDED after the UX cab,
  # invisible to 7-Zip's PE handler. Carve at every MSCF magic and expand
  # repeatedly until nothing new comes out.
  python3 - <<'PY'
import re
d = open('vc.exe', 'rb').read()
offs = [m.start() for m in re.finditer(b'MSCF\x00\x00\x00\x00', d)]
print('cab offsets:', offs)
for i, o in enumerate(offs):
    open('carve%d.cab' % i, 'wb').write(d[o:])
PY
  for c in carve*.cab; do 7zz x "$c" -o"${c}.x" -y >/dev/null 2>&1 || true; done
  for pass in 1 2 3; do
    expanded=0
    while IFS= read -r f; do
      out="${f}.x"; [ -d "$out" ] && continue
      if 7zz x "$f" -o"$out" -y >/dev/null 2>&1; then expanded=1; else rm -rf "$out"; fi
    done < <(find . -type f -size +4k ! -name 'vc.exe' ! -name 'carve*.cab')
    [ "$expanded" -eq 0 ] && break
  done

  # MSI file keys carry a .dll_amd64 suffix with arm64 twins in a sibling cab.
  python3 - "$DEST" <<'PY'
import os, re, shutil, sys
dest = sys.argv[1]
want = ["concrt140", "msvcp140", "msvcp140_1", "msvcp140_2",
        "msvcp140_atomic_wait", "msvcp140_codecvt_ids", "vcamp140",
        "vccorlib140", "vcomp140", "vcruntime140", "vcruntime140_1",
        "vcruntime140_threads"]
found = {}
for root, _, files in os.walk('.'):
    for fn in files:
        low = fn.lower()
        if 'arm64' in low:
            continue
        p = os.path.join(root, fn)
        try:
            with open(p, 'rb') as fh:
                if fh.read(2) != b'MZ':
                    continue
        except OSError:
            continue
        k = re.sub(r'^f_central_', '', low)
        k = re.sub(r'_(amd64|x64)$', '', k)
        k = re.sub(r'\.dll$', '', k)
        k = re.sub(r'_(amd64|x64)$', '', k)
        if k in want and k not in found:
            found[k] = p
for k in sorted(found):
    shutil.copy(found[k], os.path.join(dest, k + '.dll'))
missing = [w for w in want if w not in found]
if missing:
    print('MISSING:', missing)
    sys.exit(1)
print('all 12 extracted')
PY
  ls "$DEST" | wc -l
  cd "$ROOT"; rm -rf "$WORK"
}

stage_ftsrc() {
  if [ -f research/freetype/CMakeLists.txt ]; then echo "already cloned"; return 0; fi
  rm -rf research/freetype
  git clone --depth 1 --branch VER-2-13-3 \
    https://github.com/freetype/freetype.git research/freetype
}

stage_mingw() {
  mkdir -p toolchains
  if [ ! -d "toolchains/$MINGW" ]; then
    curl -fL "https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/${MINGW}.tar.xz" \
      | tar -xJ -C toolchains/
  fi
  "toolchains/$MINGW/bin/aarch64-w64-mingw32-clang" --version
}

# A plain `make` CANNOT succeed here. dlls/win32u/win32u.so is the macOS HOST
# .so and the fork's patched bitblt.c references ios_srcwatch_arm /
# ios_srcwatch_arm_geom / winios_dump_srcbits — iOS-only symbols that exist
# only in Madeira's own iOS build. `make -k` keeps going and still produces
# the two things actually consumed: the PE static libs (winecrt0, for DXMT's
# meson) and the widl-generated headers.
stage_wine() {
  export PATH="$ROOT/toolchains/$MINGW/bin:$PATH"
  # Explicitly NOT exporting IPHONEOS_DEPLOYMENT_TARGET: this is a host build.
  unset IPHONEOS_DEPLOYMENT_TARGET || true
  cd wine
  mkdir -p build-macos && cd build-macos
  if [ ! -f include/config.h ]; then
    if ! ../configure --enable-win64 --disable-tests --without-x --without-freetype; then
      echo "=== configure failed; tail of config.log ==="
      tail -n 120 config.log
      exit 1
    fi
  fi
  test -f include/config.h
  make -k -j"$(ncpu)" 2>&1 | tail -40 || true
  echo "=== host-side link failures above are expected; the PE side is what matters ==="
}

stage_wineverify() {
  cd wine/build-macos
  echo "=== winecrt0 (DXMT meson dependency) ==="
  CRT0="$(find . -name 'libwinecrt0.a' -print -quit)"
  if [ -z "$CRT0" ]; then
    echo "libwinecrt0.a not built by the -k pass; building it explicitly"
    export PATH="$ROOT/toolchains/$MINGW/bin:$PATH"
    make -j"$(ncpu)" dlls/winecrt0/aarch64-windows/libwinecrt0.a || true
    CRT0="$(find . -name 'libwinecrt0.a' -print -quit)"
  fi
  test -n "$CRT0" || { echo "FATAL: no libwinecrt0.a — DXMT cannot link"; \
    find . -name '*.a' | head -30; exit 1; }
  echo "found: $CRT0"

  echo "=== widl headers (dwrite_unixlib dependency) ==="
  ls include/dwrite*.h || {
    echo "dwrite headers missing; generating explicitly"
    export PATH="$ROOT/toolchains/$MINGW/bin:$PATH"
    make include/dwrite.h include/dwrite_1.h include/dwrite_2.h include/dwrite_3.h || true
    ls include/dwrite*.h || { echo "FATAL: no dwrite headers"; exit 1; }
  }

  cd "$ROOT"
  # build-arm64ec is only ever read for $build/include, and widl output is
  # arch-independent, so a symlink is enough.
  ln -sfn build-macos wine/build-arm64ec
  echo "build-arm64ec -> $(readlink wine/build-arm64ec)"
}

# GnuTLS must precede wineunix: bcrypt, secur32 and crypt32 include
# toolchains/gnutls-ios/include. Source tarballs are committed in build/gnutls-ios/src.
stage_gnutls() {
  if ls toolchains/gnutls-ios/lib/*.a >/dev/null 2>&1; then echo "already built"; return 0; fi
  bash build/gnutls-ios/build.sh
  ls toolchains/gnutls-ios/lib/*.a
}

stage_freetype() {
  if [ -f build/freetype-ios/build/libfreetype.a ]; then echo "already built"; return 0; fi
  bash build/freetype-ios/build.sh
  test -f build/freetype-ios/build/libfreetype.a
}

stage_wineunix() {
  bash build/ntdll-unix/build.sh
  bash build/win32u-unix/build.sh
  ls -l app/Madeira/libntdll_unix.a app/Madeira/libwin32u_unix.a
}

# build/wineserver/build.sh does NOT build wineserver from scratch — it
# compiles ~20 patched files and swaps them into a PREBUILT libwineserver.a,
# which is gitignored and was never committed. So synthesise the base archive
# from every wine/server/*.c with the same flags the script uses, then let the
# script do its replacement pass on top.
stage_wineserver() {
  BUILD_DIR="$ROOT/build/wineserver"
  WINE_SRC="$ROOT/wine"
  SHIMS_DIR="$ROOT/build/ntdll-unix/shims"
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  OBJ="$BUILD_DIR/obj"
  mkdir -p "$OBJ/base"

  if [ ! -f "$OBJ/libwineserver.a" ]; then
    FLAGS=(
      -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
      -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
      -I"$WINE_SRC/build-macos/include"
      -I"$BUILD_DIR" -I"$WINE_SRC/server"
      -I"$SHIMS_DIR"
      -include "$BUILD_DIR/config_ios.h"
      -include stdarg.h
      -include "$BUILD_DIR/unicode_fix.h"
      -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
      -D__WINESRC__ -DWINE_IOS=1
      -Dmain=wineserver_main
      -Wno-implicit-function-declaration
    )
    ok=0; bad=0; badlist=""
    for src in "$WINE_SRC"/server/*.c; do
      n="$(basename "$src" .c)"
      if xcrun -sdk iphoneos clang "${FLAGS[@]}" \
           -c "$src" -o "$OBJ/base/$n.o" 2>"$OBJ/base/$n.err"; then
        ok=$((ok+1))
      else
        bad=$((bad+1)); badlist="$badlist $n"
      fi
    done
    echo "base: $ok compiled, $bad failed"
    [ -n "$badlist" ] && echo "failed:$badlist"
    for n in $badlist; do echo "--- $n.err ---"; head -15 "$OBJ/base/$n.err"; done
    ls "$OBJ"/base/*.o >/dev/null 2>&1 || { echo "FATAL: no server objects"; exit 1; }
    ar rcs "$OBJ/libwineserver.a" "$OBJ"/base/*.o
  fi
  ls -l "$OBJ/libwineserver.a"

  # build.sh probes Homebrew paths for llvm-objcopy that may not exist;
  # llvm-mingw ships one, so put it on PATH first.
  export PATH="$ROOT/toolchains/$MINGW/bin:$PATH"
  command -v llvm-objcopy
  bash build/wineserver/build.sh
  ls -l app/Madeira/libwineserver.a
}

# FEX_IOS_HOST: the fork gates its iOS externs (IosCbEntryLog, IosFfsBypassLog,
# IosJitReverseTranslate) behind this define while the code USING them is
# ungated — without it Core.cpp throws 14 undeclared-identifier errors.
stage_fex() {
  # IosLogUnimplementedCASPAL (Arm64.cpp) sits OUTSIDE every #ifdef
  # FEX_IOS_HOST yet calls Win32 VirtualQuery — left over from the author's
  # ARM64EC-on-Windows work. Pure diagnostic, so stub it.
  python3 - <<'PY'
from pathlib import Path
p = Path("FEX/FEXCore/Source/Utils/ArchHelpers/Arm64.cpp")
s = p.read_text()
sig = "static void IosLogUnimplementedCASPAL(uint32_t Size, uint64_t* GPRs, uint32_t AddressReg) {"
if "MADEIRA_CASPAL_STUB" in s:
    print("already patched")
    raise SystemExit(0)
i = s.find(sig)
if i == -1:
    raise SystemExit("ERROR: IosLogUnimplementedCASPAL not found")
j = s.find("\n}\n", i)
if j == -1:
    raise SystemExit("ERROR: could not find end of function")
stub = (sig + "\n"
        "  /* MADEIRA_CASPAL_STUB: original body used Win32 VirtualQuery,\n"
        "   * unavailable on iOS. Diagnostic only. */\n"
        "  (void)Size; (void)GPRs; (void)AddressReg;\n")
s = s[:i] + stub + s[j + 1:]
p.write_text(s)
print("stubbed IosLogUnimplementedCASPAL")
PY
  grep -n -A4 "MADEIRA_CASPAL_STUB" FEX/FEXCore/Source/Utils/ArchHelpers/Arm64.cpp

  cmake -S FEX -B FEX/build-ios -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_C_FLAGS="-DFEX_IOS_HOST=1" \
    -DCMAKE_CXX_FLAGS="-DFEX_IOS_HOST=1" \
    -DBUILD_TESTING=OFF \
    -DBUILD_TESTS=False \
    -DBUILD_THUNKS=OFF \
    -DENABLE_VIXL_DISASSEMBLER=OFF \
    -DENABLE_VIXL_SIMULATOR=OFF \
    -DENABLE_CCACHE=OFF \
    -DENABLE_LTO=False \
    -DTUNE_CPU=none \
    -DTUNE_ARCH=generic

  set +e
  cmake --build FEX/build-ios \
    --target FEXCore FEXCore_Base JemallocLibs \
    --parallel "$(ncpu)" 2>&1 | tee "$LOGS/fex-compile.log"
  rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -ne 0 ] && { grep -n "error:" "$LOGS/fex-compile.log" | head -40; exit "$rc"; }

  for n in libFEXCore.a libFEXCore_Base.a libJemallocLibs.a \
           libfmt.a libcephes_128bit.a libxxhash.a libsoftfloat_3e.a; do
    f="$(find FEX/build-ios -name "$n" -type f -print -quit)"
    test -n "$f" || { echo "MISSING $n"; exit 1; }
    lipo -info "$f"
  done
}

# Libraries only: with CMAKE_SYSTEM_NAME=iOS every executable is treated as
# MACOSX_BUNDLE and LLVM's install() for each tool fails with "no BUNDLE
# DESTINATION". airconv links the libs, not the tools.
#
# Unlike CI, nothing is pruned afterwards — disk is cheap here and keeping the
# trees makes a rebuild incremental.
stage_llvm() {
  if [ ! -d toolchains/llvm-project/llvm ]; then
    git clone --depth 1 --branch llvmorg-15.0.7 \
      https://github.com/llvm/llvm-project toolchains/llvm-project
  fi
  # BSD sed. Idempotent: the second run finds nothing to replace.
  grep -q 'MATCHES "Darwin|iOS"' toolchains/llvm-project/llvm/cmake/modules/AddLLVM.cmake \
    || sed -i '' 's/MATCHES "Darwin"/MATCHES "Darwin|iOS"/' \
         toolchains/llvm-project/llvm/cmake/modules/AddLLVM.cmake

  if [ ! -x toolchains/llvm-host/bin/llvm-tblgen ]; then
    cmake -S toolchains/llvm-project/llvm -B toolchains/llvm-host -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
      -DLLVM_INCLUDE_BENCHMARKS=OFF
    cmake --build toolchains/llvm-host --target llvm-tblgen
  fi

  cmake -S toolchains/llvm-project/llvm -B toolchains/llvm-ios-build -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TABLEGEN="$ROOT/toolchains/llvm-host/bin/llvm-tblgen" \
    -DLLVM_TARGETS_TO_BUILD="" \
    -DLLVM_BUILD_TOOLS=OFF -DLLVM_INCLUDE_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF -DLLVM_INCLUDE_UTILS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_RUNTIMES=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_ZLIB=OFF
  cmake --build toolchains/llvm-ios-build
  ls toolchains/llvm-ios-build/lib/*.a | head
  du -sh toolchains/llvm-ios-build toolchains/llvm-project
}

# airconv_context.cpp is the ONLY file including air_msad.h / air_samplepos.h /
# air_tessellation.h. They are generated, not committed, and only by dxmt's own
# meson airconv target — which Madeira does not use. Produce them with the same
# two commands meson would run.
stage_shaders() {
  SH="$ROOT/build/dxmt-ios/shader-headers"
  SRC="$ROOT/research/dxmt/src/airconv/shaders"
  mkdir -p "$SH"
  cat > "$ROOT/.build-tmp/hexdump.py" <<'PY'
import sys
air, hdr, name = sys.argv[1], sys.argv[2], sys.argv[3]
d = open(air, 'rb').read()
rows = [', '.join('0x%02x' % b for b in d[i:i+12])
        for i in range(0, len(d), 12)]
with open(hdr, 'w') as f:
    f.write('unsigned char %s[] = {\n  %s\n};\n' % (name, ',\n  '.join(rows)))
    f.write('unsigned int %s_len = %d;\n' % (name, len(d)))
print('%s -> %s (%d bytes)' % (air, hdr, len(d)))
PY
  for m in "$SRC"/*.metal; do
    n="$(basename "$m" .metal)"
    xcrun -sdk macosx metal -o "$SH/$n.air" -c "$m" \
      -std=metal3.1 --target=air64-apple-macos14.0
    python3 "$ROOT/.build-tmp/hexdump.py" "$SH/$n.air" "$SH/$n.h" "$n"
  done
  ls -l "$SH"
  head -2 "$SH/air_msad.h"
}

# PE modules via meson (needs Wine's winecrt0), then the unix side, then merged
# with the LLVM iOS archives into libdxmt_combined.a, which is what the pbxproj
# links.
stage_dxmt() {
  ln -sfn ../../toolchains research/dxmt/toolchains
  export PATH="$ROOT/toolchains/$MINGW/bin:/opt/homebrew/bin:$PATH"
  export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  mkdir -p app/Madeira/aarch64-windows
  cd research/dxmt
  rm -rf build-pe
  meson setup --cross-file build-aarch64-win.txt --native-file build-osx.txt \
    -Dwine_build_path=../../wine/build-macos build-pe
  meson compile -C build-pe
  cp build-pe/src/d3d11/d3d11.dll \
     build-pe/src/dxgi/dxgi.dll \
     build-pe/src/winemetal/winemetal.dll \
     build-pe/src/d3d10/d3d10core.dll \
     ../../app/Madeira/aarch64-windows/
  cd "$ROOT/build/dxmt-ios"
  ./build.sh
  xcrun -sdk iphoneos libtool -static -o libdxmt_combined.a \
    obj/*.o "$ROOT"/toolchains/llvm-ios-build/lib/*.a
  cp libdxmt_combined.a "$ROOT/app/Madeira/"
}

stage_verify() {
  for l in libgmp libgnutls libhogweed libnettle \
           libntdll_unix libwin32u_unix libwineserver libdxmt_combined; do
    test -f "app/Madeira/$l.a" || { echo "MISSING app/Madeira/$l.a"; exit 1; }
    ls -lh "app/Madeira/$l.a"
  done
}

# ContentView.swift calls glassEffect(.regular, in:) — an iOS 26 Liquid Glass
# API. On an older SDK the symbol does not exist and the Swift build fails. It
# is purely cosmetic (a blur behind two Circles), so strip it when unsupported.
stage_app() {
  SDKV="$(xcrun --sdk iphoneos --show-sdk-version | cut -d. -f1)"
  echo "iphoneos SDK major: $SDKV"
  if [ "$SDKV" -lt 26 ]; then
    F=app/Madeira/ContentView.swift
    cp "$F" "$F.orig-glasseffect" 2>/dev/null || true
    grep -n "glassEffect" "$F" || true
    python3 - "$F" <<'PY'
import re, sys
f = sys.argv[1]
s = open(f).read()
n = s.count('.glassEffect(')
s2 = re.sub(r'\.glassEffect\([^()]*(?:\([^()]*\)[^()]*)*\)', '', s)
open(f, 'w').write(s2)
print('removed %d glassEffect call(s); %d remain' % (n, s2.count('.glassEffect(')))
PY
    grep -n "glassEffect" "$F" && { echo "FATAL: calls remain"; exit 1; } || true
  else
    echo "SDK supports glassEffect; leaving source untouched"
  fi

  rm -rf out
  # xcodebuild auto-creates a scheme from the target even though the project
  # ships no xcshareddata/xcschemes, so -target works.
  xcodebuild \
    -project app/Madeira.xcodeproj \
    -target Madeira \
    -configuration Release \
    -sdk iphoneos \
    CONFIGURATION_BUILD_DIR="$ROOT/out" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    build
}

stage_ipa() {
  test -d out/Madeira.app
  lipo -info out/Madeira.app/Madeira
  rm -rf artifacts && mkdir -p artifacts/Payload
  cp -R out/Madeira.app artifacts/Payload/Madeira.app
  cd artifacts && zip -qry Madeira.ipa Payload
  unzip -Z1 Madeira.ipa | awk '$0 == "Payload/Madeira.app/Madeira" { found=1 } END { exit !found }'
  ls -lh Madeira.ipa
}

# -------------------------------------------------------------------- main --

mkdir -p "$ROOT/.build-tmp"

ONLY=""; FROM=""; FORCED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list)
      printf '%-12s %s\n' STAGE STATUS
      for s in "${STAGES[@]}"; do
        if done_stage "$s"; then printf '%-12s %sdone%s  %s\n' "$s" "$G" "$N" "$(cat "$STAMPS/$s")"
        else printf '%-12s %spending%s\n' "$s" "$Y" "$N"; fi
      done
      exit 0 ;;
    --clean)  rm -f "$STAMPS"/*; echo "stamps cleared (build trees kept)"; exit 0 ;;
    --only)   ONLY="$2"; shift 2 ;;
    --from)   FROM="$2"; shift 2 ;;
    --force)  FORCED="$2"; rm -f "$STAMPS/$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

valid() { local n="$1"; for s in "${STAGES[@]}"; do [ "$s" = "$n" ] && return 0; done; return 1; }
for n in "$ONLY" "$FROM" "$FORCED"; do
  [ -n "$n" ] && ! valid "$n" && die "no such stage '$n'. Stages: ${STAGES[*]}"
done

START=$(date +%s)

if [ -n "$ONLY" ]; then
  rm -f "$STAMPS/$ONLY"; FORCED="$ONLY"; run "$ONLY"
else
  started=0
  for s in "${STAGES[@]}"; do
    if [ -n "$FROM" ] && [ "$started" -eq 0 ]; then
      [ "$s" = "$FROM" ] || continue
      started=1
      rm -f "$STAMPS/$s"
    fi
    run "$s"
  done
fi

echo
say "done in $(( ($(date +%s) - START) / 60 ))m"
[ -f artifacts/Madeira.ipa ] && ls -lh artifacts/Madeira.ipa
echo
echo "The IPA is unsigned (CODE_SIGNING_ALLOWED=NO), which is what you want:"
echo "sign it with your Apple ID via your sideloader, then attach StikDebug for JIT."
