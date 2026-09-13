#!/usr/bin/env python3
"""[GPU_STATS] probe for DXMT's winemetal unix present path (measurement only).

Adds madeira_frame_probe(cmdbuf, drawable) right before the presentDrawable
message send of the locked-60 branch ("presentDrawable60") and of the
DXMT-duration branch ("presentDrawableAfterMinDuration", used by games that
Present with SyncInterval>0). The probe registers a completed handler (GPU
time, error count) and a presented handler (display interval histogram).

Never fails the build: a site whose shape does not match is skipped with a
WARNING, and the missing [GPU_STATS] line in the device log says so.
"""
import re
import sys

MARKER = "MADEIRA_FRAME_PROBE"
LABELS = ("presentDrawable60", "presentDrawableAfterMinDuration")
SEND = re.compile(
    r"\[\s*\(id<MTLCommandBuffer>\)\s*(?P<cb>[A-Za-z_]\w*(?:(?:->|\.)\w+)*)\s+"
    r"presentDrawable:\s*\(id<MTLDrawable>\)\s*(?P<dr>[A-Za-z_]\w*(?:(?:->|\.)\w+)*)")

PROTO = "void madeira_frame_probe(void *cmdbuf, void *drawable); /* MADEIRA_FRAME_PROBE */\n"

DEFN = r"""
/* MADEIRA_FRAME_PROBE: GPU time + display intervals, one line per 64 probed presents. */
#include <stdio.h>
#include <stdint.h>
static uint64_t mfp_calls, mfp_gpu_n, mfp_gpu_us, mfp_gpu_max, mfp_cb_err, mfp_dropped, mfp_prev_pt;
static uint64_t mfp_disp[5];
void madeira_frame_probe(void *cmdbuf, void *drawable)
{
  id<MTLCommandBuffer> cb = (id<MTLCommandBuffer>)cmdbuf;
  if (cb && [cb status] <= MTLCommandBufferStatusEnqueued) {
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
      if ([done status] == MTLCommandBufferStatusError) { __sync_fetch_and_add(&mfp_cb_err, 1); return; }
      CFTimeInterval s = done.GPUStartTime, e = done.GPUEndTime;
      if (s > 0 && e > s) {
        uint64_t us = (uint64_t)((e - s) * 1e6);
        __sync_fetch_and_add(&mfp_gpu_us, us);
        __sync_fetch_and_add(&mfp_gpu_n, 1);
        if (us > mfp_gpu_max) mfp_gpu_max = us;
      }
    }];
  }
  if (drawable) {
    [(id<MTLDrawable>)drawable addPresentedHandler:^(id<MTLDrawable> d) {
      CFTimeInterval t = d.presentedTime;
      if (t <= 0) { __sync_fetch_and_add(&mfp_dropped, 1); return; }
      uint64_t us = (uint64_t)(t * 1e6);
      uint64_t prev = __sync_lock_test_and_set(&mfp_prev_pt, us);
      if (prev && us > prev) {
        uint64_t dl = us - prev;
        int b = dl <= 12500 ? 0 : dl <= 20800 ? 1 : dl <= 29200 ? 2 : dl <= 37500 ? 3 : 4;
        __sync_fetch_and_add(&mfp_disp[b], 1);
      }
    }];
  }
  if ((__sync_add_and_fetch(&mfp_calls, 1) & 63) == 0) {
    uint64_t n = __sync_lock_test_and_set(&mfp_gpu_n, 0);
    uint64_t sum = __sync_lock_test_and_set(&mfp_gpu_us, 0);
    uint64_t mx = __sync_lock_test_and_set(&mfp_gpu_max, 0);
    dprintf(2, "[GPU_STATS] mode=%d n=%llu gpu_avg=%.2fms gpu_max=%.2fms cb_err=%llu "
               "disp8=%llu disp17=%llu disp25=%llu disp33=%llu disp_slow=%llu dropped=%llu\n",
            (int)g_madeira_vsync_mode, (unsigned long long)n, n ? sum / 1000.0 / n : 0.0, mx / 1000.0,
            (unsigned long long)__sync_lock_test_and_set(&mfp_cb_err, 0),
            (unsigned long long)__sync_lock_test_and_set(&mfp_disp[0], 0),
            (unsigned long long)__sync_lock_test_and_set(&mfp_disp[1], 0),
            (unsigned long long)__sync_lock_test_and_set(&mfp_disp[2], 0),
            (unsigned long long)__sync_lock_test_and_set(&mfp_disp[3], 0),
            (unsigned long long)__sync_lock_test_and_set(&mfp_disp[4], 0),
            (unsigned long long)__sync_lock_test_and_set(&mfp_dropped, 0));
  }
}
"""


def main(path):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    if MARKER in src:
        print(f"{path}: frame-probe patch already applied")
        return 0
    if "g_madeira_vsync_mode" not in src:
        print(f"WARNING: {path}: no g_madeira_vsync_mode; frame probe NOT applied")
        return 0
    inserts = []
    for label in LABELS:
        hits = [m.start() for m in re.finditer(re.escape('"%s"' % label), src)]
        if len(hits) != 1:
            print(f"WARNING: {label}: {len(hits)} label sites (want 1); site skipped")
            continue
        m = SEND.search(src, hits[0], hits[0] + 800)
        if not m:
            print(f"WARNING: {label}: no cast presentDrawable send within 800 chars; site skipped")
            continue
        line_start = src.rfind("\n", 0, m.start()) + 1
        if src[line_start:m.start()].strip():
            print(f"WARNING: {label}: send is not at statement start; site skipped")
            continue
        before = src[:line_start].rstrip()
        if not before or before[-1] not in ";{}":
            print(f"WARNING: {label}: send may be a braceless if/else body; site skipped")
            continue
        indent = src[line_start:m.start()]
        call = f"{indent}madeira_frame_probe((void *)(uintptr_t)({m.group('cb')}), (void *)(uintptr_t)({m.group('dr')}));\n"
        inserts.append((line_start, call, label))
    if not inserts:
        print(f"WARNING: {path}: no probe site matched; frame probe NOT applied")
        return 0
    for pos, call, label in sorted(inserts, reverse=True):
        src = src[:pos] + call + src[pos:]
        print(f"{path}: frame probe inserted at {label}")
    src = PROTO + src + DEFN
    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
