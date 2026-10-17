"""Recolours the survivor suit's yellow cloth (models/player/survivor_suit_basecolor.jpg) into the lobby's
colour variants, leaving the black straps, pouches, boots and visor as they are.

    python godot-backrooms/tools/gen_hazmat_variants.py

Writes models/player/survivor_suit_<name>.jpg beside the original (SurvivorAnim.SUIT_VARIANTS lists the names).
"""
import os

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.join(HERE, "..", "models", "player")
SRC = os.path.join(DIR, "survivor_suit_basecolor.jpg")

YELLOW = 0.15                 # the cloth's hue (0..1)
# name: (hue it moves to, saturation x, value x); hue None keeps the cloth's own, desaturated
VARIANTS = {
    "orange": (0.065, 1.05, 1.0),
    "red": (0.995, 0.95, 0.82),
    "green": (0.33, 0.85, 0.85),
    "blue": (0.58, 0.9, 0.9),
    "white": (None, 0.10, 1.25),
}


def main():
    img = Image.open(SRC).convert("RGB")
    hsv = np.asarray(img.convert("HSV")).astype(np.float32) / 255.0
    h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    # how much a pixel is cloth: yellow hue, properly saturated (the black gear and the dull brown boots score 0)
    dh = np.abs((h - YELLOW + 0.5) % 1.0 - 0.5)
    cloth = np.clip(1.0 - dh / 0.06, 0.0, 1.0) * np.clip((s - 0.25) / 0.25, 0.0, 1.0)
    for name, (hue, sm, vm) in VARIANTS.items():
        nh = h if hue is None else (h + (hue - YELLOW)) % 1.0
        out = np.stack([
            nh,
            np.clip(s * (1.0 + (sm - 1.0) * cloth), 0, 1),
            np.clip(v * (1.0 + (vm - 1.0) * cloth), 0, 1),
        ], axis=-1)
        out[..., 0] = np.where(cloth > 0, nh, h)
        rgb = Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), "HSV").convert("RGB")
        path = os.path.join(DIR, "survivor_suit_%s.jpg" % name)
        rgb.save(path, quality=92)
        print("wrote", path)


main()
