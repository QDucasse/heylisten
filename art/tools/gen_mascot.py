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

# Faces drawn around each eye's centre (the upper pixel of the 2px-tall open eye): left eye's
# offsets as given, right eye's mirrored.
def around(offsets):
    def eyes(to):
        out = []
        for ex, m in ((5, 1), (12, -1)):
            cx, cy = to(ex, 1, 0)
            out += [(cx + m * dx, cy + dy) for dx, dy in offsets]
        return out
    return eyes
FACES["ko"] = around([(-1, -1), (1, -1), (0, 0), (-1, 1), (1, 1)])      # x x
DESC["ko"] = "X eyes (turn stopped on an API error)"
FACES["squint"] = around([(-1, -1), (0, 0), (-1, 1)])                    # > <
DESC["squint"] = "squeezed > < eyes (compacting: chewing on the context)"

# Dizzy (context window filling up): each eye is a 4x4 square spiral over the open eye, the right
# one mirrored. Four frames turn it a quarter each, so the eyes spin.
SPIRAL = ["kkkk",
          "kBBk",
          "kBkk",
          "kBBB"]
def rot(p):   # 90 degrees clockwise
    return ["".join(p[len(p) - 1 - r][c] for r in range(len(p))) for c in range(len(p[0]))]
def spiral_eyes(pat):
    def eyes(to):
        out = []
        for ex, flip in ((5, False), (12, True)):
            x, y = to(ex, 1, 0)
            for dy, row in enumerate(pat):
                for dx, ch in enumerate(row[::-1] if flip else row):
                    if ch == "k":
                        # 4 wide over the 1px eye: one column out from the face's centre line
                        out.append((x - (2 if flip else 1) + dx, y + dy))
        return out
    return eyes
pat = SPIRAL
for i in range(4):
    FACES[f"dizzy{i}"] = spiral_eyes(pat)
    DESC[f"dizzy{i}"] = f"square spiral eyes, frame {i + 1}/4 (context filling up)"
    pat = rot(pat)
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
