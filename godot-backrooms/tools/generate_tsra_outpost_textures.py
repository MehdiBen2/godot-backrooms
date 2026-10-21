"""
The T.S.R.A. outpost's three seamless PBR sets, in textures/pbr/<Name>/ (the level editor lists any folder there):

- Outpost_Wall: dull grey-beige painted drywall, a joint every 1.11 m, fine roller stipple, scuffs.
- Outpost_Floor: speckled grey vinyl / terrazzo, as in the security-office photos, worn in patches.
- Outpost_Ceiling: a suspended acoustic tile ceiling, 8 x 8 tiles per 2.25 m repeat, dark T-grid; "tile_panels"
  makes the level's light panels 4 x 4 blocks of its own tiles glowing (as Tile_White_Grid_Lit).

Usage: python tools/generate_tsra_outpost_textures.py   (run from godot-backrooms/)
"""
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import generate_tsra_hub_textures as g

rng, SIZE = g.rng, g.SIZE
noise, coarse, blur, save = g.noise, g.coarse, g.blur, g.save


def outpost_wall():
    ys, xs = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    dx = np.minimum(xs % (SIZE / 2), SIZE / 2 - xs % (SIZE / 2))
    joint = g.groove(dx, 2.5)
    stipple = noise(0) * 0.5 + noise(2) * 0.5
    mottle = coarse(5) * 0.6 + coarse(13) * 0.4
    scuff = np.clip(coarse(9) * 0.7 + noise(5) * 0.3 - 0.85, 0, None)
    base = np.array([0.50, 0.50, 0.46], np.float32)
    lum = 1.0 + 0.03 * mottle + 0.02 * stipple - 0.1 * scuff - 0.12 * joint
    save("Outpost_Wall", base[None, None, :] * lum[..., None], 0.5 + 0.02 * stipple - 0.5 * joint,
         0.78 + 0.06 * stipple + 0.1 * scuff, 1.4)


def outpost_floor():
    speck = (rng.random((SIZE, SIZE)) > 0.93).astype(np.float32)
    dark = blur(speck, 1) * 2.0
    light = blur((rng.random((SIZE, SIZE)) > 0.95).astype(np.float32), 1) * 2.0
    mottle = coarse(7) * 0.6 + coarse(16) * 0.4
    wear = np.clip(coarse(4) * 0.7 + noise(4) * 0.3 - 0.6, 0, None)
    base = np.array([0.40, 0.41, 0.40], np.float32)
    lum = 1.0 + 0.04 * mottle - 0.28 * dark + 0.3 * light + 0.15 * wear
    save("Outpost_Floor", base[None, None, :] * lum[..., None], 0.5 + 0.03 * noise(1) + 0.01 * dark,
         0.55 - 0.2 * wear + 0.1 * mottle, 1.2)


def outpost_ceiling():
    ys, xs = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    t = SIZE / 8.0
    d = np.minimum(np.minimum(xs % t, t - xs % t), np.minimum(ys % t, t - ys % t))
    grid = np.clip(1.0 - (d - 2.0) / 2.0, 0, 1)                    # the dark T-grid
    lip = np.clip(1.0 - (d - 4.0) / 6.0, 0, 1)                      # tile edge rebate
    tone = rng.normal(0, 1, (8, 8)).astype(np.float32)[(ys // t).astype(int), (xs // t).astype(int)]
    fiss = noise(0) * 0.6 + noise(2) * 0.4
    stain = np.clip(coarse(6) - 0.15, 0, None)
    base = np.array([0.66, 0.66, 0.63], np.float32)
    lum = 1.0 + 0.015 * tone + 0.045 * fiss - 0.12 * stain
    lum *= 1.0 - 0.7 * grid - 0.1 * lip
    save("Outpost_Ceiling", base[None, None, :] * lum[..., None], 0.5 + 0.02 * fiss - 0.6 * lip - grid,
         0.9 - 0.2 * grid + 0.04 * fiss, 1.5)
    p = os.path.join(g.OUT, "Outpost_Ceiling", "Outpost_Ceiling.tres")
    with open(p, "a", newline="\n") as f:
        f.write('emission_enabled = true\nemission = Color(1, 0.97, 0.9, 1)\n'
                'metadata/tile_panels = true\nmetadata/panel_tiles = 4\n')


if __name__ == "__main__":
    outpost_wall()
    outpost_floor()
    outpost_ceiling()
