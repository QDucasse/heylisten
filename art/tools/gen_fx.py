#!/usr/bin/env python3
"""16x16 effect layers drawn over the mascot tile (same grid, transparent elsewhere).
snow0..7: flakes drifting down over the whole tile (prompt cache gone cold).
flame_s / flame_sb, flame_l / flame_lb: a flame on top of the head, two flicker frames each
(context filling up: small; auto-compaction close: large)."""
import os
here = os.path.dirname(os.path.abspath(__file__))
N = 16
out = os.path.join(here, "..", "fx")

def write(name, desc, pal, g):
    assert len(g) == N and all(len(r) == N for r in g), name
    with open(os.path.join(out, f"{name}.tile"), "w") as f:
        f.write(f"# {name}: {desc}\n" + "".join(f"{k}={v}\n" for k, v in pal.items()) + "---\n")
        f.write("\n".join("".join(r) for r in g) + "\n")

def blank():
    return [["."] * N for _ in range(N)]

def stamp(g, pat, x0, y0, wrap=False):
    for dy, row in enumerate(pat):
        for dx, ch in enumerate(row):
            if ch == ".":
                continue
            x, y = x0 + dx, y0 + dy
            if wrap:
                y %= N
            if 0 <= x < N and 0 <= y < N and (x, y) not in EYES:
                g[y][x] = ch

# Snow: 8 frames, each flake falls 2 rows a frame (16 rows: a seamless loop) with a slight sway.
SNOW = {"b": "#7cc6ff", "w": "#ffffff"}
PLUS = [".b.", "bwb", ".b."]
DOT = ["b"]
EYES = {(4, 5), (4, 6), (11, 5), (11, 6)}   # flakes pass behind the eyes, so the face stays readable
FLAKES = [(PLUS, 1, 0), (PLUS, 8, 9), (DOT, 13, 3), (DOT, 5, 13)]   # shape, x, starting y
SWAY = [0, 0, 1, 1, 0, 0, -1, -1]
for f in range(8):
    g = blank()
    for i, (pat, x, y) in enumerate(FLAKES):
        s = SWAY[(f + 2 * i) % 8] * (1 if i % 2 == 0 else -1)
        stamp(g, pat, x + s, y + 2 * f, wrap=True)
    write(f"snow{f}", f"snowflakes drifting down, frame {f + 1}/8 (prompt cache gone cold)", SNOW, g)

# Flame: sits on the head (top body row is 3), centred on the 12px-wide body (columns 2..13).
FIRE = {"r": "#e5482e", "y": "#ffd23f"}
SMALL = (6, 0, ["..r.",
                ".ryr",
                "ryyr"],
               [".r..",
                "ryr.",
                "ryyr"])
LARGE = (5, 0, ["...r..",
                "..rr.r",
                ".ryyrr",
                "ryyyyr"],
               ["..r...",
                "r.rr..",
                "rryyr.",
                "ryyyyr"])
for name, (x, y, a, b), desc in (("flame_s", SMALL, "small flame on the head (context filling up)"),
                                 ("flame_l", LARGE, "big flame on the head (auto-compaction close)")):
    for suffix, pat in (("", a), ("_b", b)):
        g = blank()
        stamp(g, pat, x, y)
        write(name + suffix, desc + ("" if not suffix else ", flicker frame"), FIRE, g)
print("ok")
