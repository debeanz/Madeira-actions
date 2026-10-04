#!/usr/bin/env python3
"""Add 30 and 40 fps present caps to DXMT's winemetal unix side.

research/dxmt is a submodule, so the change is applied in place at build
time (idempotent, marker-guarded) rather than committed there. Modes:

    1 = locked 60 (existing)     3 = locked 30   4 = locked 40
    0 = MAX (existing)           2 = RAW (existing)

A cap below 60 is the single biggest heat lever for CPU-bound titles:
the game's frame loop blocks on present, so the FEX translation work per
second halves at 30. On a 120 Hz panel 40 fps lands on every third
refresh, so it stays evenly paced.
"""
import sys

MARKER = "MADEIRA_FRAME_CAP"
ANCHOR = "  } else if (mode == 2) {\n"
INSERT = """  } else if (mode == 3 || mode == 4) { /* MADEIRA_FRAME_CAP: 30 / 40 fps locks */
    madeira_log_present_cadence(mode == 3 ? "presentDrawable30" : "presentDrawable40", 0.0);
    [(id<MTLCommandBuffer>)params->handle presentDrawable:(id<MTLDrawable>)params->arg
                                     afterMinimumDuration:(mode == 3 ? (1.0 / 30.0) : (1.0 / 40.0))];
"""


def main(path):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    if MARKER in src:
        print(f"{path}: frame-cap patch already applied")
        return 0
    if src.count(ANCHOR) != 1:
        print(f"ERROR: expected exactly one anchor in {path}, found {src.count(ANCHOR)}")
        return 1
    src = src.replace(ANCHOR, INSERT + ANCHOR)
    src = src.replace('"[iOS DXMT] vsync_mode=%d (1=locked60 0=max 2=raw)\\n"',
                      '"[iOS DXMT] vsync_mode=%d (1=locked60 3=locked30 4=locked40 0=max 2=raw)\\n"')
    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    print(f"{path}: frame-cap patch applied")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
