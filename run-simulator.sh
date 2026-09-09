#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_MODE=0
if [ "${1:-}" = "--runtime" ]; then
  RUNTIME_MODE=1
  shift
fi
DEVICE="${1:-}"

if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
devices = [d for group in data.values() for d in group if d.get("isAvailable") and d["name"].startswith("iPhone")]
booted = next((d for d in devices if d["state"] == "Booted"), None)
print((booted or devices[0])["udid"] if devices else "")
')"
fi

[ -n "$DEVICE" ] || { echo "No available iPhone Simulator found" >&2; exit 1; }

TMP_PROJECT="$ROOT/app/MadeiraSimulator.xcodeproj"
mkdir -p "$TMP_PROJECT"
trap 'rm -rf "$TMP_PROJECT"' EXIT
cp "$ROOT/app/Madeira.xcodeproj/project.pbxproj" "$TMP_PROJECT/project.pbxproj"

python3 - "$TMP_PROJECT/project.pbxproj" "$RUNTIME_MODE" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
runtime = sys.argv[2] == "1"
s = p.read_text()
if runtime:
    remove = {
        "A1000010", "A1000011", "A1000012", "A1000013", "A1000014",
        "A1000015", "A1000017", "A1000021", "A1000031", "A1000034",
        "A1000051", "A1000054", "A1000060", "A1000090", "A1000091",
        "A1000092", "A1000093",
    }
else:
    remove = {
        "A1000010", "A1000011", "A1000012", "A1000013", "A1000014",
        "A1000015", "A1000017", "A1000021", "A1000031", "A1000034",
        "A1000051", "A1000054", "A1000060", "A1000090", "A1000091",
        "A1000092", "A1000093",
    }
lines = []
in_frameworks = False
for line in s.splitlines(keepends=True):
    if "/* Begin PBXFrameworksBuildPhase section */" in line:
        in_frameworks = True
    if in_frameworks and any(key in line for key in remove):
        continue
    lines.append(line)
    if "/* End PBXFrameworksBuildPhase section */" in line:
        in_frameworks = False
p.write_text("".join(lines))
PY

if [ "$RUNTIME_MODE" = 1 ]; then
  test -f "$ROOT/app/Madeira/simulator-libs/libdxmt_combined.a" || bash "$ROOT/build-simulator-runtime.sh"
  EXCLUDED='JITAllocator.c FEXBridge.mm'
  EXTRA_BUILD_SETTINGS=(
    'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) MADEIRA_SIMULATOR_REAL_RUNTIME=1'
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MADEIRA_SIMULATOR_REAL_RUNTIME'
    "LIBRARY_SEARCH_PATHS=$ROOT/app/Madeira/simulator-libs"
    'OTHER_LDFLAGS=$(inherited) -lwineserver -lntdll_unix -lwin32u_unix -ldxmt_combined'
  )
else
  EXCLUDED='JITAllocator.c FEXBridge.mm WineServerBridge.m WineProcessBridge.m wine_stubs.c PrefixExtractor.c IOSDisplayShim.m Winios.m'
  EXTRA_BUILD_SETTINGS=()
fi

xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator
xcrun simctl bootstatus "$DEVICE" -b

xcodebuild \
  -project "$TMP_PROJECT" \
  -target Madeira \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$DEVICE" \
  CONFIGURATION_BUILD_DIR="$ROOT/out-simulator" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  "EXCLUDED_SOURCE_FILE_NAMES=$EXCLUDED" \
  "${EXTRA_BUILD_SETTINGS[@]}" \
  build

xcrun simctl uninstall "$DEVICE" com.willfaust.mythicemu 2>/dev/null || true
xcrun simctl install "$DEVICE" "$ROOT/out-simulator/Madeira.app"
xcrun simctl launch "$DEVICE" com.willfaust.mythicemu
if [ "$RUNTIME_MODE" = 1 ]; then
  echo "Madeira simulator runtime launched on $DEVICE"
else
  echo "Madeira simulator preview launched on $DEVICE"
fi
