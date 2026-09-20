#!/bin/bash
# Publish compiler errors as GitHub "error" annotations.
#
# The job log of this repository needs admin rights to read, while check-run
# annotations are public. Build scripts keep each source's stderr in
# <obj_dir>/<name>.err (wineserver: <obj_dir>/err-<name>.txt); this re-emits the
# interesting lines so a failed run can be diagnosed from the annotations API.
#
# Usage: ci-report-errors.sh <label> <obj_dir> <name> [<name> ...]
# GitHub keeps 10 error annotations per step, so at most 8 files are reported,
# 12 lines each, error lines first.

label="$1"; dir="$2"; shift 2
reported=0
for name in "$@"; do
    f="$dir/$name.err"
    [ -f "$f" ] || f="$dir/err-$name.txt"
    [ -f "$f" ] || continue
    body="$(grep -E "error|undefined|fatal|unknown type|no member|implicit" "$f" | head -12)"
    [ -n "$body" ] || body="$(head -12 "$f")"
    msg="$(printf '%s: %s\n%s\n' "$label" "$name" "$body" \
           | sed 's/%/%25/g; s/\r/%0D/g' | awk '{ printf "%s%%0A", $0 }' | cut -c1-3800)"
    echo "::error::$msg"
    reported=$((reported + 1))
    [ "$reported" -ge 8 ] && break
done
exit 0
