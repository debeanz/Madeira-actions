#!/usr/bin/env python3
"""Frame caps on DXMT's winemetal unix side: 30/40 locks, a 1/120 s mode 0
and a 1/120 s uncapped gate (ml899).

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


# ml899: mode 0 is a real 120 fps cap (it presented with no pacing at all,
# so nothing told the panel to run at 120), and uncapped (2) lets a frame
# through every 1/120 s instead of every 18 ms (about 55 a second on screen,
# below the 60 cap). Applied independently of the 30/40 insert above.
MARKER_120 = "MADEIRA_FRAME_CAP_120"
MODE0_OLD = """    madeira_log_present_cadence("presentDrawable", 0.0);
    [(id<MTLCommandBuffer>)params->handle presentDrawable:(id<MTLDrawable>)params->arg];
"""
MODE0_NEW = """    madeira_log_present_cadence("presentDrawable120", 0.0); /* MADEIRA_FRAME_CAP_120 */
    [(id<MTLCommandBuffer>)params->handle presentDrawable:(id<MTLDrawable>)params->arg
                                     afterMinimumDuration:(1.0 / 120.0)];
"""
RAW_OLD = "    if (since < 0.018) {\n"
RAW_NEW = "    if (since < (1.0 / 120.0)) { /* MADEIRA_FRAME_CAP_120: uncapped shows up to 120 */\n"


def main(path):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    changed = False
    if MARKER in src:
        print(f"{path}: frame-cap patch already applied")
    else:
        if src.count(ANCHOR) != 1:
            print(f"ERROR: expected exactly one anchor in {path}, found {src.count(ANCHOR)}")
            return 1
        src = src.replace(ANCHOR, INSERT + ANCHOR)
        changed = True
        print(f"{path}: frame-cap patch applied")
    if MARKER_120 in src:
        print(f"{path}: 120/uncapped patch already applied")
    else:
        for old, new, what in ((MODE0_OLD, MODE0_NEW, "mode 0"), (RAW_OLD, RAW_NEW, "raw gate")):
            if src.count(old) != 1:
                print(f"ERROR: expected exactly one {what} anchor in {path}, found {src.count(old)}")
                return 1
            src = src.replace(old, new)
        changed = True
        print(f"{path}: 120/uncapped patch applied")
    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
