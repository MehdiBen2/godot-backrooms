"""Builds textures/pbr/Ceiling_Office_Lit from ambientCG OfficeCeiling002 (asetsuimprot/texturesnew).

The game draws a lit-panel ceiling with shaders/panel_ceiling.gdshader, which is laid out for Ceiling_Light_Panels:
6 x 6 tiles a 4.5 m cell, tile k centred at UV k / 6 (the grid lines half a tile off the texture's edges), light
panels on tiles (1,1) (5,1) (1,5) (5,5) and (3,3) (level_fixtures.gd PANEL_OFFSETS), and AO / roughness / metal
packed in one ORM map. OfficeCeiling002 is also 6 x 6 tiles, but its grid lines sit on the texture's edges and its
four panels are on tiles (2,2) (5,2) (2,5) (5,5). This cuts its tiles out and lays them again in the game's layout,
every map the same way, so the shader's lit panels, dead panels and borrowed plain tiles all land on real tiles.

    python tools/build_office_ceiling.py
"""
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

N = 6                     # tiles a side
WORK = 512                # px a tile while cutting (the 1K source upscaled 3x, so every cut is on a whole pixel)
SIZE = 2048               # output, as Ceiling_Light_Panels
EMIT_SIZE = 1024
SRC_PANELS = [(2, 2), (5, 2), (2, 5), (5, 5)]
DST_PANELS = {(1, 1): (2, 2), (5, 1): (5, 2), (1, 5): (2, 5), (5, 5): (5, 5), (3, 3): (5, 5)}


def load(z, key, mode):
    name = "OfficeCeiling002_1K-JPG_%s.jpg" % key
    im = Image.open(io.BytesIO(z.read(name))).convert(mode)
    return im.resize((N * WORK, N * WORK), Image.LANCZOS)


def relay(im, plan, size):
    """lay the source's tiles out by `plan` (dst tile -> src tile), tile k centred at k / N"""
    out = Image.new(im.mode, (N * WORK, N * WORK))
    for (dx, dy), (sx, sy) in plan.items():
        out.paste(im.crop((sx * WORK, sy * WORK, (sx + 1) * WORK, (sy + 1) * WORK)), (dx * WORK, dy * WORK))
    # tiles were pasted on the texture's grid: shift half a tile so tile k is centred at k / N
    a = np.roll(np.asarray(out), (-WORK // 2, -WORK // 2), axis=(0, 1))
    return Image.fromarray(a, im.mode).resize((size, size), Image.LANCZOS)


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
    z = zipfile.ZipFile(SRC)
    plain = [(x, y) for y in range(N) for x in range(N) if (x, y) not in SRC_PANELS]
    random.Random(2).shuffle(plain)
    plan = dict(DST_PANELS)
    for t in [(x, y) for y in range(N) for x in range(N) if (x, y) not in DST_PANELS]:
        plan[t] = plain.pop()

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
