#!/usr/bin/env python3
"""text-to-pixel-art renderer (Python 3 standard library only, no Pillow).

    render.py check  DIR                          validate every DIR/*.tile
    render.py render DIR OUT [--scale N] [--split] [--body HEX]

Tile format:
    # <id>: description
    # border: #3b82f6          (optional frame colour, contact sheet only)
    k=#222222                  (palette: one char = one colour, at most 6; '.' = transparent)
    ---
    <N rows of N chars>

--split: the palette char 'B' marks tintable "body" pixels. For every tile, also write
<id>_mask.png (B pixels white, rest transparent) and <id>_detail.png (non-B pixels),
both at scale 1, for runtime tinting. The preview <id>.png renders B with --body.
"""
import os
import struct
import sys
import zlib

MAX_COLOURS = 6


def parse_tile(path):
    errors = []
    palette = {}
    grid = []
    border = None
    seen_sep = False
    with open(path) as f:
        lines = f.read().splitlines()
    for ln, raw in enumerate(lines, 1):
        line = raw.rstrip()
        if not seen_sep:
            s = line.strip()
            if not s:
                continue
            if s.startswith("#"):
                body = s[1:].strip()
                if body.lower().startswith("border:"):
                    border = body.split(":", 1)[1].split()[0].strip()
                continue
            if s == "---":
                seen_sep = True
                continue
            if len(s) >= 9 and s[1] == "=":
                ch, hexv = s[0], s[2:].split()[0]
                if ch == ".":
                    errors.append(f"line {ln}: '.' is reserved for background")
                elif not (len(hexv) == 7 and hexv[0] == "#"):
                    errors.append(f"line {ln}: bad colour {hexv!r}")
                else:
                    try:
                        int(hexv[1:], 16)
                        palette[ch] = hexv
                    except ValueError:
                        errors.append(f"line {ln}: bad colour {hexv!r}")
                continue
            errors.append(f"line {ln}: unexpected header line {s!r}")
        else:
            if line == "" and not grid:
                continue
            grid.append(line)
    while grid and grid[-1] == "":
        grid.pop()
    if not seen_sep:
        errors.append("missing '---' separator")
    n = len(grid)
    if n == 0:
        errors.append("empty grid")
    for i, row in enumerate(grid, 1):
        if len(row) != n:
            errors.append(f"row {i}: {len(row)} chars, expected {n} (grid has {n} rows)")
        for ch in set(row):
            if ch != "." and ch not in palette:
                errors.append(f"row {i}: char {ch!r} not in palette")
    if len(palette) > MAX_COLOURS:
        errors.append(f"{len(palette)} colours (max {MAX_COLOURS})")
    if grid and all(set(r) <= {"."} for r in grid):
        errors.append("grid is blank")
    return {"palette": palette, "grid": grid, "border": border, "size": n}, errors


def hex_rgba(h, a=255):
    return (int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16), a)


def write_png(path, w, h, pixels):
    """pixels: list of rows, each a list of (r,g,b,a)."""
    raw = b"".join(b"\x00" + bytes(c for px in row for c in px) for row in pixels)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


CLEAR = (0, 0, 0, 0)


def tile_pixels(tile, colour_of):
    return [[colour_of(ch) for ch in row] for row in tile["grid"]]


def scale(pixels, s):
    out = []
    for row in pixels:
        big = [px for px in row for _ in range(s)]
        out.extend([list(big) for _ in range(s)])
    return out


def load_dir(d):
    tiles = {}
    errs = {}
    for name in sorted(os.listdir(d)):
        if not name.endswith(".tile"):
            continue
        tid = name[:-5]
        t, e = parse_tile(os.path.join(d, name))
        tiles[tid] = t
        if e:
            errs[tid] = e
    return tiles, errs


def cmd_check(d):
    tiles, errs = load_dir(d)
    if not tiles:
        print(f"no .tile files in {d}")
        return 1
    sizes = {t["size"] for t in tiles.values()}
    seen = {}
    for tid, t in tiles.items():
        key = "\n".join(t["grid"])
        if key in seen:
            errs.setdefault(tid, []).append(f"duplicate of {seen[key]}")
        else:
            seen[key] = tid
    for tid in tiles:
        if tid in errs:
            print(f"FAIL {tid}")
            for e in errs[tid]:
                print(f"     {e}")
        else:
            print(f"ok   {tid} ({tiles[tid]['size']}px, {len(tiles[tid]['palette'])} colours)")
    if len(sizes) > 1:
        print(f"WARN mixed grid sizes: {sorted(sizes)}")
    return 1 if errs else 0


def cmd_render(d, out, s, split, body):
    tiles, errs = load_dir(d)
    if not tiles:
        print(f"no .tile files in {d}")
        return 1
    if errs:
        cmd_check(d)
        print("fix FAILs before rendering")
        return 1
    os.makedirs(out, exist_ok=True)
    sheet_tiles = []
    for tid, t in tiles.items():
        pal = {k: hex_rgba(v) for k, v in t["palette"].items()}
        if split:
            pal["B"] = hex_rgba(body)  # preview shows the body in the default tint
        prev = tile_pixels(t, lambda ch: pal.get(ch, CLEAR) if ch != "." else CLEAR)
        n = t["size"]
        big = scale(prev, s)
        write_png(os.path.join(out, f"{tid}.png"), n * s, n * s, big)
        if split:
            mask = tile_pixels(t, lambda ch: (255, 255, 255, 255) if ch == "B" else CLEAR)
            detail = tile_pixels(t, lambda ch: pal[ch] if ch not in (".", "B") else CLEAR)
            write_png(os.path.join(out, f"{tid}_mask.png"), n, n, mask)
            write_png(os.path.join(out, f"{tid}_detail.png"), n, n, detail)
        sheet_tiles.append((tid, big, n * s, t["border"]))
    # contact sheet
    gap, cols = 8, min(6, len(sheet_tiles))
    cell = max(sz for _, _, sz, _ in sheet_tiles) + 2 * 2
    rows = (len(sheet_tiles) + cols - 1) // cols
    W = cols * cell + (cols + 1) * gap
    H = rows * cell + (rows + 1) * gap
    bg = (236, 236, 232, 255)
    sheet = [[bg] * W for _ in range(H)]
    for i, (tid, big, sz, border) in enumerate(sheet_tiles):
        cx = gap + (i % cols) * (cell + gap)
        cy = gap + (i // cols) * (cell + gap)
        frame = hex_rgba(border) if border else (200, 200, 196, 255)
        for y in range(cell):
            for x in range(cell):
                if x < 2 or y < 2 or x >= cell - 2 or y >= cell - 2:
                    sheet[cy + y][cx + x] = frame
                else:
                    sheet[cy + y][cx + x] = (255, 255, 255, 255)
        ox, oy = cx + (cell - sz) // 2, cy + (cell - sz) // 2
        for y in range(sz):
            for x in range(sz):
                px = big[y][x]
                if px[3]:
                    sheet[oy + y][ox + x] = px
    write_png(os.path.join(out, "sheet.png"), W, H, sheet)
    print(f"rendered {len(sheet_tiles)} tiles -> {out}/ (sheet.png{', masks' if split else ''})")
    return 0


def main(argv):
    if len(argv) < 2 or argv[0] not in ("check", "render"):
        print(__doc__)
        return 2
    if argv[0] == "check":
        return cmd_check(argv[1])
    if len(argv) < 3:
        print(__doc__)
        return 2
    s, split, body = 10, False, "#d97757"
    rest = argv[3:]
    i = 0
    while i < len(rest):
        if rest[i] == "--scale":
            s = int(rest[i + 1]); i += 2
        elif rest[i] == "--split":
            split = True; i += 1
        elif rest[i] == "--body":
            body = rest[i + 1]; i += 2
        else:
            print(f"unknown option {rest[i]}"); return 2
    return cmd_render(argv[1], argv[2], s, split, body)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
