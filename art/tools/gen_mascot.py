#!/usr/bin/env python3
"""Decode the Claude Code welcome mascot (quadrant block characters) into 16x16 tiles.
Each quadrant becomes 1px wide x 2px tall (terminal cells are ~1:2). Body = 'B' (tinted at
runtime), eyes = 'k'. Only the eye pixels differ between expressions."""
import os
ART = [" ▐▛███▜▌", "▝▜█████▛▘", "  ▘▘ ▝▝"]
Q = {" ": "0000", "█": "1111", "▐": "0101", "▌": "1010", "▛": "1110", "▜": "1101",
     "▝": "0100", "▘": "1000", "▙": "1011", "▟": "0111", "▀": "1100", "▄": "0011",
     "▖": "0010", "▗": "0001"}
N = 16
here = os.path.dirname(os.path.abspath(__file__))

def body():
    w = 2 * max(len(l) for l in ART)
    qx = [[0] * w for _ in range(2 * len(ART))]
    for r, line in enumerate(ART):
        for c, ch in enumerate(line):
            ul, ur, ll, lr = (int(b) for b in Q[ch])
            qx[2*r][2*c], qx[2*r][2*c+1], qx[2*r+1][2*c], qx[2*r+1][2*c+1] = ul, ur, ll, lr
    cols = [x for x in range(w) if any(row[x] for row in qx)]
    rows = [y for y in range(len(qx)) if any(qx[y])]
    x0, y0 = cols[0], rows[0]
    bw, bh = cols[-1] - x0 + 1, 2 * (rows[-1] - y0 + 1)
    ox, oy = (N - bw) // 2, (N - bh) // 2
    g = [["."] * N for _ in range(N)]
    for y in rows:
        for x in cols:
            if qx[y][x]:
                for dy in (0, 1):
                    g[oy + 2*(y - y0) + dy][ox + x - x0] = "B"
    # eye holes: quadrant (5,1) and (12,1) relative to the art
    to = lambda qx_, qy_, dy: (ox + qx_ - x0, oy + 2*(qy_ - y0) + dy)
    return g, to

FACES = {
    "awake":    lambda to: [to(5,1,0), to(5,1,1), to(12,1,0), to(12,1,1)],
    "sleeping": lambda to: [to(4,1,1), to(5,1,1), to(12,1,1), to(13,1,1)],
    "alarmed":  lambda to: [to(5,0,1), to(5,1,0), to(5,1,1), to(12,0,1), to(12,1,0), to(12,1,1)],
}
DESC = {"awake": "eyes open", "sleeping": "eyes closed (lids)", "alarmed": "tall wide-open eyes"}
for name, eyes in FACES.items():
    g, to = body()
    # restore the original eye holes to body first, then draw this expression's eyes
    for (x, y) in FACES["awake"](to):
        g[y][x] = "B"
    for (x, y) in eyes(to):
        g[y][x] = "k"
    with open(os.path.join(here, "..", "tiles", f"mascot_{name}.tile"), "w") as f:
        f.write(f"# mascot_{name}: Claude Code welcome mascot, {DESC[name]}\nk=#1f1a17\nB=#d97757\n---\n")
        f.write("\n".join("".join(r) for r in g) + "\n")
print("ok")
