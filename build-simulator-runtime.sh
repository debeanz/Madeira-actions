#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="$ROOT/build/simulator-runtime"
LIBS="$ROOT/app/Madeira/simulator-libs"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
MIN_FLAG="-mios-simulator-version-min=17.0"

mkdir -p "$RUNTIME" "$LIBS"

echo "==> LLVM (iOS Simulator)"
if [ ! -f "$ROOT/toolchains/llvm-simulator-build/lib/libLLVMCore.a" ]; then
  cmake -S "$ROOT/toolchains/llvm-project/llvm" -B "$ROOT/toolchains/llvm-simulator-build" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DLLVM_TABLEGEN="$ROOT/toolchains/llvm-host/bin/llvm-tblgen" \
    -DLLVM_TARGETS_TO_BUILD="" \
    -DLLVM_BUILD_TOOLS=OFF -DLLVM_INCLUDE_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF -DLLVM_INCLUDE_UTILS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_RUNTIMES=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_ZLIB=OFF
  cmake --build "$ROOT/toolchains/llvm-simulator-build" --parallel "$(sysctl -n hw.ncpu)"
fi

echo "==> FreeType (iOS Simulator)"
if [ ! -f "$RUNTIME/freetype/libfreetype.a" ]; then
  cmake -S "$ROOT/research/freetype" -B "$RUNTIME/freetype" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON \
    -DCMAKE_C_FLAGS="-fno-stack-protector"
  cmake --build "$RUNTIME/freetype" --parallel "$(sysctl -n hw.ncpu)"
fi
mkdir -p "$RUNTIME/freetype-root"
ln -sfn ../freetype "$RUNTIME/freetype-root/build"

echo "==> ntdll unix side (iOS Simulator)"
MADEIRA_SDK_NAME=iphonesimulator \
MADEIRA_OBJ_DIR="$RUNTIME/ntdll-obj" \
MADEIRA_OUTPUT_LIB="$LIBS/libntdll_unix.a" \
MADEIRA_EXTRA_CFLAGS="-DMADEIRA_SIMULATOR_RUNTIME=1" \
  bash "$ROOT/build/ntdll-unix/build.sh"

echo "==> win32u unix side (iOS Simulator)"
MADEIRA_SDK_NAME=iphonesimulator \
MADEIRA_OBJ_DIR="$RUNTIME/win32u-obj" \
MADEIRA_OUTPUT_LIB="$LIBS/libwin32u_unix.a" \
MADEIRA_FREETYPE_DIR="$RUNTIME/freetype-root" \
  bash "$ROOT/build/win32u-unix/build.sh"

echo "==> wineserver base (iOS Simulator)"
WS_OBJ="$RUNTIME/wineserver-obj"
mkdir -p "$WS_OBJ/base"
if [ ! -f "$WS_OBJ/libwineserver.a" ]; then
  flags=(
    -arch arm64 -isysroot "$SDK" "$MIN_FLAG" -O2
    -I"$ROOT/wine/include" -I"$ROOT/wine/include/wine"
    -I"$ROOT/wine/build-macos/include"
    -I"$ROOT/build/wineserver" -I"$ROOT/wine/server"
    -I"$ROOT/build/ntdll-unix/shims"
    -include "$ROOT/build/wineserver/config_ios.h"
    -include stdarg.h
    -include "$ROOT/build/wineserver/unicode_fix.h"
    -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
    -D__WINESRC__ -DWINE_IOS=1 -Dmain=wineserver_main
    -Wno-implicit-function-declaration
  )
  for src in "$ROOT"/wine/server/*.c; do
    name="$(basename "$src" .c)"
    if xcrun -sdk iphonesimulator clang "${flags[@]}" -c "$src" -o "$WS_OBJ/base/$name.o" 2>"$WS_OBJ/base/$name.err"; then
      :
    else
      echo "  skipped server/$name.c (see $WS_OBJ/base/$name.err)"
    fi
  done
  ar rcs "$WS_OBJ/libwineserver.a" "$WS_OBJ"/base/*.o
fi
PATH="$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH" \
MADEIRA_SDK_NAME=iphonesimulator \
MADEIRA_OBJ_DIR="$WS_OBJ" \
MADEIRA_OUTPUT_LIB="$LIBS/libwineserver.a" \
  bash "$ROOT/build/wineserver/build.sh"

echo "==> DXMT unix side (iOS Simulator)"
MADEIRA_SDK_NAME=iphonesimulator \
MADEIRA_OBJ_DIR="$RUNTIME/dxmt-obj" \
MADEIRA_OUTPUT_LIB="$RUNTIME/libdxmt_unix.a" \
MADEIRA_LLVM_BUILD="$ROOT/toolchains/llvm-simulator-build" \
  bash "$ROOT/build/dxmt-ios/build.sh"
xcrun -sdk iphonesimulator libtool -static -o "$LIBS/libdxmt_combined.a" \
  "$RUNTIME/libdxmt_unix.a" "$ROOT"/toolchains/llvm-simulator-build/lib/*.a

echo "Simulator runtime libraries:"
ls -lh "$LIBS"/*.a
