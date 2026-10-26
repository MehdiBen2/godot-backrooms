"""Builds textures/pbr/Ceiling_Office_Lit from ambientCG OfficeCeiling002 (asetsuimprot/texturesnew).

The game draws a lit-panel ceiling with shaders/panel_ceiling.gdshader. Ceiling_Light_Panels is laid out 6 x 6 tiles
a 4.5 m cell, tile k centred at UV k / 6 (grid lines half a tile off the texture's edges). Ceiling_Office_Lit uses the
shader's edge_grid layout (the .tres says "metadata/tile_layout" = "edge7"): 7 x 7 tiles of 0.643 m a cell, tile k
covering UV k / 7 .. (k + 1) / 7, so the grid lines sit ON the texture's edges, i.e. on the cell borders where the walls
stand. One-tile light panels on tiles (3,3) (1,1) (5,1) (1,5) (5,5) (level_fixtures.gd _panel_offsets: 0 and +-2 tiles
from the cell's middle); AO / roughness / metal packed in one ORM map. OfficeCeiling002 is 6 x 6 tiles with its grid
lines on the texture's edges too and four panels on tiles (2,2) (5,2) (2,5) (5,5). This cuts its tiles out and lays
them again in the 7 x 7 layout, every map the same way, so the shader's lit panels, dead panels and borrowed plain
tiles all land on real tiles. No shift is needed: the tiles go down on the texture's own grid.

    python tools/build_office_ceiling.py
    python tools/build_office_ceiling.py OLD_DIR      # without the zip: re-lay a set built by the old 6 x 6 centred layout

OLD_DIR holds Ceiling_Office_Lit_{Color,NormalGL,ORM,Emission}.png as that layout wrote them (tile k centred at UV k / 6,
panels on (1,1) (5,1) (1,5) (5,5) (3,3)); the tiles are shifted half a tile back onto the texture's grid, then laid again.
"""
import sys
import io
import os
import random
import zipfile

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "..", "asetsuimprot", "texturesnew", "OfficeCeiling002_1K-JPG.zip")
NAME = "Ceiling_Office_Lit"
OUT = os.path.join(ROOT, "textures", "pbr", NAME)
REF = os.path.join(ROOT, "textures", "pbr", "Ceiling_Light_Panels")

SRC_N = 6                 # the source's tiles a side
N = 7                     # tiles a side in the output
WORK = 512                # px a tile while cutting (the 1K source upscaled 3x, so every cut is on a whole pixel)
SIZE = 2352               # output: 7 x 336 px a tile
EMIT_SIZE = 1176
SRC_PANELS = [(2, 2), (5, 2), (2, 5), (5, 5)]
DST_PANELS = {(3, 3): (5, 5), (1, 1): (2, 2), (5, 1): (5, 2), (1, 5): (2, 5), (5, 5): (5, 5)}


# without the zip, from a set in the old centred layout (OLD_DIR): panels and the 6 x 6 tile grid after the shift back
OLD_PANELS = [(1, 1), (5, 1), (1, 5), (5, 5), (3, 3)]
OLD_DST_PANELS = {(3, 3): (3, 3), (1, 1): (1, 1), (5, 1): (5, 1), (1, 5): (1, 5), (5, 5): (5, 5)}
OLD_FILES = {"Color": ("Color", None), "NormalGL": ("NormalGL", None), "Emission": ("Emission", None),
             "AmbientOcclusion": ("ORM", 0), "Roughness": ("ORM", 1), "Metalness": ("ORM", 2)}


def load(z, key, mode):
    if isinstance(z, str):
        fname, ch = OLD_FILES[key]
        im = Image.open(os.path.join(z, "%s_%s.png" % (NAME, fname))).convert("RGB")
        if ch is not None: im = im.split()[ch]
        im = im.convert(mode)
        # tile k is centred at k / 6: wrap the picture 2 x 2 and cut it again half a tile back, so tile k covers k / 6 .. (k + 1) / 6
        w = im.size[0]
        wrap = Image.new(mode, (2 * w, 2 * w))
        for ox in (0, w):
            for oy in (0, w):
                wrap.paste(im, (ox, oy))
        h = w - w / (2.0 * SRC_N)         # tile 0 straddles the wrap: start half a tile before it
        return wrap.resize((SRC_N * WORK, SRC_N * WORK), Image.LANCZOS, box=(h, h, h + w, h + w))
    name = "OfficeCeiling002_1K-JPG_%s.jpg" % key
    im = Image.open(io.BytesIO(z.read(name))).convert(mode)
    return im.resize((SRC_N * WORK, SRC_N * WORK), Image.LANCZOS)


def relay(im, plan, size):
    """lay the source's tiles out by `plan` (dst tile -> src tile), tile k covering k / N .. (k + 1) / N"""
    out = Image.new(im.mode, (N * WORK, N * WORK))
    for (dx, dy), (sx, sy) in plan.items():
        out.paste(im.crop((sx * WORK, sy * WORK, (sx + 1) * WORK, (sy + 1) * WORK)), (dx * WORK, dy * WORK))
    return out.resize((size, size), Image.LANCZOS)


def write_import(fname, ref_fname, normal_map=False):
    """the reference set's import settings (high quality BPTC, roughness filtered by the normal map)"""
    lines = []
    for ln in open(os.path.join(REF, ref_fname + ".import"), encoding="utf-8").read().splitlines():
        if ln.startswith(("uid=", "path", "dest_files=")) or ln.startswith(("metadata=", "\"imported_formats", "\"vram_texture", "}")):
            continue
        ln = ln.replace("Ceiling_Light_Panels", NAME)
        if ln.startswith("compress/normal_map="): ln = "compress/normal_map=%d" % (1 if normal_map else 0)
        lines.append(ln)
    with open(os.path.join(OUT, fname + ".import"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def main():
    old = len(sys.argv) > 1
    z = sys.argv[1] if old else zipfile.ZipFile(SRC)
    src_panels = OLD_PANELS if old else SRC_PANELS
    plain = [(x, y) for y in range(SRC_N) for x in range(SRC_N) if (x, y) not in src_panels]
    rng = random.Random(2)
    bag = []
    dst_panels = OLD_DST_PANELS if old else DST_PANELS
    plan = dict(dst_panels)
    for t in [(x, y) for y in range(N) for x in range(N) if (x, y) not in dst_panels]:
        if not bag:                       # ~32 plain source tiles, 44 plain slots: deal the tiles again, reshuffled
            bag = plain[:]
            rng.shuffle(bag)
        plan[t] = bag.pop()

    color = relay(load(z, "Color", "RGB"), plan, SIZE)
    normal = relay(load(z, "NormalGL", "RGB"), plan, SIZE)
    ao = relay(load(z, "AmbientOcclusion", "L"), plan, SIZE)
    rough = relay(load(z, "Roughness", "L"), plan, SIZE)
    metal = relay(load(z, "Metalness", "L"), plan, SIZE)
    emit = relay(load(z, "Emission", "RGB"), plan, EMIT_SIZE)
    orm = Image.merge("RGB", (ao, rough, metal))

    # re-normalise the resampled normals
    n = np.asarray(normal).astype(np.float32) / 127.5 - 1.0
    n /= np.maximum(np.linalg.norm(n, axis=2, keepdims=True), 1e-6)
    normal = Image.fromarray(np.clip((n + 1.0) * 127.5 + 0.5, 0, 255).astype(np.uint8), "RGB")

    os.makedirs(OUT, exist_ok=True)
    for im, key in ((color, "Color"), (normal, "NormalGL"), (orm, "ORM"), (emit, "Emission")):
        fname = "%s_%s.png" % (NAME, key)
        im.save(os.path.join(OUT, fname), optimize=True)
        if not os.path.exists(os.path.join(OUT, fname + ".import")):
            write_import(fname, "Ceiling_Light_Panels_%s.png" % key, key == "NormalGL")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
