#!/usr/bin/env python3
"""Generate the heylisten app icon and menu bar icon: an original glowing fairy
(orb + four wings) as a nod to "Hey! Listen!", in Claude orange.

    art/icon/app/fairy_app.tile    32x32, dark rounded-square background (app icon)
    art/icon/app16/fairy_app16.tile 16x16 hand-drawn version for the 16 px icon slot
    art/icon/menu/fairy_menu.tile  16x16, one-colour silhouette (menu bar template image)
"""
import math, os
here = os.path.dirname(os.path.abspath(__file__))

def ellipse(x, y, cx, cy, a, b, angle):
    """Inside a rotated ellipse with semi-axes a (along angle) and b."""
    dx, dy = x - cx, y - cy
    c, s = math.cos(angle), math.sin(angle)
    u, v = dx * c + dy * s, -dx * s + dy * c
    return (u / a) ** 2 + (v / b) ** 2 <= 1.0

def fairy(N, k):
    """Return a char grid: 'c' core, 'o' orb, 'h' halo, 'w' wing, 'e' wing edge, '.' empty.
    k scales the geometry (1 for 16px, 2 for 32px)."""
    C = (N - 1) / 2
    g = [["."] * N for _ in range(N)]
    wings = [  # (cx, cy, a, b, angle) relative to centre
        (-3.6 * k, -3.4 * k, 3.4 * k, 1.7 * k, math.radians(45)),
        (3.6 * k, -3.4 * k, 3.4 * k, 1.7 * k, math.radians(-45)),
        (-3.0 * k, 3.4 * k, 2.4 * k, 1.25 * k, math.radians(-40)),
        (3.0 * k, 3.4 * k, 2.4 * k, 1.25 * k, math.radians(40)),
    ]
    for y in range(N):
        for x in range(N):
            r = math.hypot(x - C, y - C)
            for (wx, wy, a, b, ang) in wings:
                if ellipse(x, y, C + wx, C + wy, a, b, ang):
                    inner = ellipse(x, y, C + wx, C + wy, a - 0.9, max(b - 0.9, 0.3), ang)
                    g[y][x] = "w" if inner else "e"
            if r <= 2.4 * k + 0.9:
                g[y][x] = "h"
            if r <= 2.4 * k:
                g[y][x] = "o"
            if r <= 1.1 * k:
                g[y][x] = "c"
    return g

def write(path, desc, pal, rows):
    N = len(rows)
    assert all(len(r) == N for r in rows)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(f"# {desc}\n" + "".join(f"{k}={v}\n" for k, v in pal.items()) + "---\n" + "\n".join(rows) + "\n")

# --- app icon: 32x32 on a dark rounded square -------------------------------
N = 32
g = fairy(N, 2)
bg = [["."] * N for _ in range(N)]
R = 6  # corner radius
for y in range(N):
    for x in range(N):
        cx = min(max(x, R), N - 1 - R); cy = min(max(y, R), N - 1 - R)
        d = math.hypot(x - cx, y - cy)
        if d <= R:
            bg[y][x] = "D"
rows = []
for y in range(N):
    row = ""
    for x in range(N):
        ch = g[y][x]
        row += ch if ch != "." else bg[y][x]
    rows.append(row)
# a few sparkles
rows = [list(r) for r in rows]
for (x, y) in [(6, 15), (25, 16), (15, 27), (16, 4)]:
    if rows[y][x] == "D":
        rows[y][x] = "c"
rows = ["".join(r) for r in rows]
write(os.path.join(here, "..", "icon", "app", "fairy_app.tile"),
      "fairy_app: glowing fairy orb with wings on a dark rounded square (app icon)",
      {"D": "#141824", "c": "#fff8ef", "o": "#ffb347", "h": "#d97757",
       "w": "#cfe6ff", "e": "#8fb8e8"}, rows)

# --- menu bar icon: 16x16 silhouette, hand-drawn (procedural wings are too thin at 16 px) ---
rows = [
    "................",
    ".kkk........kkk.",
    ".kkkk......kkkk.",
    "..kkkk....kkkk..",
    "...kkk....kkk...",
    "......kkkk......",
    ".....kkkkkk.....",
    ".....kkkkkk.....",
    ".....kkkkkk.....",
    ".....kkkkkk.....",
    "......kkkk......",
    "...kkk....kkk...",
    "..kkkk....kkkk..",
    "..kkk......kkk..",
    "................",
    "................",
]
write(os.path.join(here, "..", "icon", "menu", "fairy_menu.tile"),
      "fairy_menu: fairy silhouette (menu bar template image)", {"k": "#000000"}, rows)

# --- 16 px app icon: the same silhouette, coloured, on the dark rounded square ----------------
# (downscaling the 32 px icon would blur the pixel art; 32 -> 16 needs its own drawing)
app16 = []
for y, r in enumerate(rows):
    line = ""
    for x, ch in enumerate(r):
        corner = (x in (0, 15) and y in (0, 1, 14, 15)) or (y in (0, 15) and x in (0, 1, 14, 15))
        if ch == ".":
            line += "." if corner else "D"
        elif 5 <= y <= 10 and 5 <= x <= 10:          # orb
            line += "c" if 7 <= y <= 8 and 7 <= x <= 8 else "o"
        else:                                        # wings
            line += "w"
    app16.append(line)
write(os.path.join(here, "..", "icon", "app16", "fairy_app16.tile"),
      "fairy_app16: 16x16 fairy on a dark rounded square (16 px app icon slot)",
      {"D": "#141824", "c": "#fff8ef", "o": "#ffb347", "w": "#cfe6ff"}, app16)
print("ok")
