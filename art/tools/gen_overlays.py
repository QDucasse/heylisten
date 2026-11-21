#!/usr/bin/env python3
"""9x9 overlay badges, two frames each (<id> and <id>_b; the app alternates them).
Shown at 2x (18 pt). Shapes marked auto=True get a 1px 'k' outline added automatically."""
import os
here = os.path.dirname(os.path.abspath(__file__))
N = 9

def outline(rows):
    g = [list(r) for r in rows]
    for y in range(N):
        for x in range(N):
            if g[y][x] == "." and any(0 <= y+j < N and 0 <= x+i < N and rows[y+j][x+i] not in ".k"
                                      for j in (-1,0,1) for i in (-1,0,1)):
                g[y][x] = "k"
    return ["".join(r) for r in g]

def write(name, desc, pal, rows, auto=False):
    rows = outline(rows) if auto else rows
    assert len(rows) == N and all(len(r) == N for r in rows), (name, [len(r) for r in rows])
    with open(os.path.join(here, "..", "overlays", f"{name}.tile"), "w") as f:
        f.write(f"# {name}: {desc}\n" + "".join(f"{k}={v}\n" for k, v in pal.items()) + "---\n" + "\n".join(rows) + "\n")

K = {"k": "#1f1a17"}
RED = {**K, "r": "#e5484d", "w": "#ffffff"}
excl = [
    "..kkkkk..",
    ".krrwrrk.",
    "krrrwrrrk",
    "krrrwrrrk",
    "krrrwrrrk",
    "krrrrrrrk",
    "krrrwrrrk",
    ".krrrrrk.",
    "..kkkkk..",
]
write("excl", "white ! in a red disc: needs permission", RED, excl)
write("excl_b", "red ! in a white disc (blink frame)", RED,
      [r.translate(str.maketrans("rw", "wr")) for r in excl])

Q = {**K, "w": "#ffffff", "o": "#d97757"}
write("question", "speech bubble with a centred ?: waiting for your reply", Q, [
    ".kkkkkkk.",
    "kwwooowwk",
    "kwwwwowwk",
    "kwwwowwwk",
    "kwwwwwwwk",
    "kwwwowwwk",
    "kwwwwwwwk",
    ".kwkkkkk.",
    ".kk......",
])
write("question_b", "speech bubble, ? one pixel lower (bob frame)", Q, [
    ".kkkkkkk.",
    "kwwwwwwwk",
    "kwwooowwk",
    "kwwwwowwk",
    "kwwwowwwk",
    "kwwwwwwwk",
    "kwwwowwwk",
    ".kwkkkkk.",
    ".kk......",
])

Z = {"w": "#f4f4f4"}   # white: never matches a project colour
write("zzz", "big Z top-right, small z bottom-left: asleep", Z, [
    "....wwwww",
    ".......w.",
    "......w..",
    ".....w...",
    "....wwwww",
    "wwww.....",
    "..w......",
    ".w.......",
    "wwww.....",
])
write("zzz_b", "small z top-right, big Z bottom-left (breathing frame)", Z, [
    ".....wwww",
    ".......w.",
    "......w..",
    ".....wwww",
    "wwwww....",
    "...w.....",
    "..w......",
    ".w.......",
    "wwwww....",
])

plug = [
    "..g...g..",
    "..g...g..",
    ".ggggggg.",
    ".ggggygg.",
    ".gggyggg.",
    ".ggyyygg.",
    "..ggygg..",
    "...ygg...",
    "....g....",
]
P = {**K, "g": "#9a9a9a", "y": "#ffd23f"}
write("unplugged", "grey plug with a yellow lightning bolt: host offline", P, plug, auto=True)
write("unplugged_b", "grey plug, bolt off (blink frame)", {**K, "g": "#9a9a9a"},
      [r.replace("y", "g") for r in plug], auto=True)
# --- unread mark (top-left of "just finished, not seen yet" avatars): 5x5 sparkle, two frames ---
def write_mark(name, desc, rows):
    assert len(rows) == 5 and all(len(r) == 5 for r in rows), name
    d = os.path.join(here, "..", "marks")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, f"{name}.tile"), "w") as f:
        f.write(f"# {name}: {desc}\nw=#ffffff\ny=#ffd23f\n---\n" + "\n".join(rows) + "\n")

write_mark("unread", "white sparkle with a yellow heart: new, not seen yet", [
    "..w..",
    "..w..",
    "wwyww",
    "..w..",
    "..w..",
])
write_mark("unread_b", "small sparkle (twinkle frame)", [
    ".....",
    "..w..",
    ".wyw.",
    "..w..",
    ".....",
])
print("ok")
