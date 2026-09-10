#!/bin/bash
# Build DXMT winemetal unix side + airconv + dxbc_parser as iOS-aarch64
# static library, for linking into Madeira.app.
#
# Produces: libdxmt_unix.a
set -eu

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
DXMT_SRC="$REPO_ROOT/research/dxmt/src"
DXMT_ROOT="$REPO_ROOT/research/dxmt"
LLVM_SRC="$REPO_ROOT/toolchains/llvm-project/llvm"
LLVM_BUILD="${MADEIRA_LLVM_BUILD:-$REPO_ROOT/toolchains/llvm-ios-build}"
SDK_NAME="${MADEIRA_SDK_NAME:-iphoneos}"
SDK=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)
if [ "$SDK_NAME" = "iphonesimulator" ]; then
    MIN_FLAG="-mios-simulator-version-min=18.0"
    PLATFORM_DEFS="-DMADEIRA_SIMULATOR_RUNTIME=1"
else
    MIN_FLAG="-miphoneos-version-min=18.0"
    PLATFORM_DEFS=""
fi
OBJ_DIR="${MADEIRA_OBJ_DIR:-$BUILD_DIR/obj}"
OUT_LIB="${MADEIRA_OUTPUT_LIB:-$BUILD_DIR/libdxmt_unix.a}"

mkdir -p "$OBJ_DIR"

# In-place, idempotent submodule patch: 30/40 fps present caps (modes 3/4).
python3 "$BUILD_DIR/patch_present_cap.py" "$DXMT_SRC/winemetal/unix/winemetal_unix.c"

COMMON_FLAGS="-arch arm64 -isysroot $SDK $MIN_FLAG -fblocks -O2 $PLATFORM_DEFS"
INCLUDES="-I$OBJ_DIR -I$DXMT_ROOT/include -I$DXMT_ROOT/libs -I$DXMT_SRC/winemetal -I$DXMT_SRC/airconv"
INCLUDES_DIRECTX="-I$DXMT_ROOT/include/native/directx -I$DXMT_ROOT/include/native/windows"
INCLUDES_SHADERS="-I$BUILD_DIR/shader-headers"
LLVM_INCLUDES="-I$LLVM_BUILD/include -I$LLVM_SRC/include"
AIRCONV_DEFS="-D_FILE_OFFSET_BITS=64 -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS"
CXX_FLAGS="-std=c++20 -fno-exceptions -fno-rtti"

SUCCEEDED=0
FAILED=0
FAILED_FILES=""

if [ "$SDK_NAME" = "iphonesimulator" ]; then
    # dxmt_command.metal is embedded in the Windows-side DXMT library, which is
    # built for the device/macOS Metal ABI. Embed a Simulator-native copy in
    # the Unix bridge so it can be substituted without changing device DLLs.
    xcrun -sdk iphonesimulator metal -std=metal4.1 -c \
        "$DXMT_SRC/dxmt/dxmt_command.metal" -o "$OBJ_DIR/dxmt_command_sim.air"
    xcrun -sdk iphonesimulator metallib "$OBJ_DIR/dxmt_command_sim.air" \
        -o "$OBJ_DIR/dxmt_command_sim.metallib"
    xxd -i -n dxmt_command_sim "$OBJ_DIR/dxmt_command_sim.metallib" \
        "$OBJ_DIR/dxmt_command_sim.h"
fi

compile_objc() {
    local src=$1 name=$2
    printf "  %-40s " "$name"
    if xcrun -sdk "$SDK_NAME" clang $COMMON_FLAGS -x objective-c $INCLUDES \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"; SUCCEEDED=$((SUCCEEDED+1))
    else
        echo "FAILED"; FAILED=$((FAILED+1)); FAILED_FILES="$FAILED_FILES $name"
    fi
}

compile_cxx() {
    local src=$1 name=$2 extra="${3:-}"
    printf "  %-40s " "$name"
    if xcrun -sdk "$SDK_NAME" clang++ $COMMON_FLAGS $CXX_FLAGS $INCLUDES $INCLUDES_DIRECTX $INCLUDES_SHADERS $LLVM_INCLUDES $AIRCONV_DEFS $extra \
        -c "$src" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"; SUCCEEDED=$((SUCCEEDED+1))
    else
        echo "FAILED"; FAILED=$((FAILED+1)); FAILED_FILES="$FAILED_FILES $name"
    fi
}

echo "=== winemetal unix (Objective-C) ==="
compile_objc "$DXMT_SRC/winemetal/unix/winemetal_unix.c" winemetal_unix
compile_objc "$DXMT_SRC/winemetal/unix/cache.c"          cache

echo "=== airconv (C++ 20, needs LLVM headers) ==="
for cpp in airconv_context.cpp air_type.cpp air_signature.cpp air_operations.cpp \
           dxbc_converter.cpp dxbc_converter_gs.cpp dxbc_converter_ts.cpp \
           dxbc_converter_basicblock.cpp dxbc_converter_cfg.cpp \
           dxbc_instructions.cpp dxbc_signature.cpp metallib_writer.cpp; do
    name=$(basename "$cpp" .cpp)
    compile_cxx "$DXMT_SRC/airconv/$cpp" "$name"
done
compile_cxx "$DXMT_SRC/airconv/nt/air_builder.cpp" air_builder
compile_cxx "$DXMT_SRC/airconv/nt/dxbc_converter_base.cpp" dxbc_converter_base
compile_cxx "$DXMT_SRC/airconv/transforms/lower_16bit_texread.cpp" lower_16bit_texread

echo "=== DXBCParser (uses exceptions — override) ==="
for cpp in BlobContainer.cpp DXBCUtils.cpp ShaderBinary.cpp; do
    name=dxbc_$(basename "$cpp" .cpp)
    # ShaderBinary uses `throw`, so we can't use -fno-exceptions from CXX_FLAGS.
    printf "  %-40s " "$name"
    if xcrun -sdk "$SDK_NAME" clang++ $COMMON_FLAGS -std=c++20 -fno-rtti \
            $INCLUDES $INCLUDES_DIRECTX $AIRCONV_DEFS \
            -c "$DXMT_ROOT/libs/DXBCParser/$cpp" -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
        echo "OK"; SUCCEEDED=$((SUCCEEDED+1))
    else
        echo "FAILED"; FAILED=$((FAILED+1)); FAILED_FILES="$FAILED_FILES $name"
    fi
done

echo ""
echo "Results: $SUCCEEDED succeeded, $FAILED failed"
if [ -n "$FAILED_FILES" ]; then
    echo "Failed:$FAILED_FILES"
    echo "See .err files in $OBJ_DIR/"
    exit 1
fi

echo ""
echo "=== Archiving libdxmt_unix.a ==="
xcrun -sdk "$SDK_NAME" ar rcs "$OUT_LIB" "$OBJ_DIR"/*.o
echo "Built: $OUT_LIB ($(wc -c < "$OUT_LIB" | tr -d ' ') bytes)"
