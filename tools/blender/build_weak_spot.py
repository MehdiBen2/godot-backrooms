"""The weak spot in the Level 0 wallpaper: the hole the player breaks open and the cramped cavity behind it.

Writes to godot-backrooms/models/props/weak_spot/:
  weak_spot_rim.glb     node "Rim":    the torn, roughly arched opening frame (broken plasterboard, gypsum core at
                                        the break, torn wallpaper lip curling out, a few hanging shards); it covers
                                        the cut rectangle's border on all three sides
  weak_spot_cavity.glb  node "Cavity": a walk-in void inside the wall block, x in [-2.4, -0.03], z in [-1.2, 1.2],
                                        y in [0, 2.9], open only at the front: crooked plank walls at uneven
                                        depths, studs, a brace, sagging joists, torn fibreglass, an uneven dusty
                                        board floor with debris, cobwebs, an old conduit
  weak_spot_debris.glb  nodes "Debris_0".."Debris_N": the pieces that fall out into the room
Godot axes in every file: Y up, metres; origin = bottom centre of the hole on the wall face (x = 0), +X out of the
wall into the room. The hole is z in [-0.45, 0.45], y in [0, 2.1].
Materials are procedural and baked by Cycles into embedded textures (baked maps and the .blend sources are kept
under assetsimported/weak_spot/). The wallpaper faces use the material "Wallpaper" (textures/wall_color.png with UV0
in wall_wallpaper.gdshader's world projection), so in Godot they can take the wall's own ShaderMaterial.

    "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe" -b --factory-startup --python tools/blender/build_weak_spot.py -- <preview dir> [woodtest] [cavity] [rim] [debris] [preview]

With no part named it builds cavity, rim, debris and renders the previews. The decals are build_weak_spot_decals.py.
"""
import math
import os
import random
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Vector, Matrix, Euler, noise as mnoise

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import weak_spot_common as C  # noqa: E402

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
PREVIEW = ARGS[0] if ARGS else str(C.ROOT / "assetsimported" / "weak_spot" / "previews")
PARTS = set(ARGS[1:]) or {"cavity", "rim", "debris", "preview"}


# ---------------------------------------------------------------------------------------------------------------
# materials (procedural, for baking)

def wood_material(name, tone=0.0, grey=0.35, dust=0.6, knots=0.25, damp=0.5, rings=150.0):
    """Old, dry, rough-sawn softwood. Grain runs along the object's local X (board() builds them that way).
    tone: -1 darker .. +1 lighter; grey: weathering to silver-grey; dust: dust on up-facing faces."""
    m, nb = C.new_mat(name)
    co = nb.coord("Object")
    rnd = nb.rand()
    off = nb.comb(nb.mul(rnd, 37.0), nb.mul(rnd, 0.0), nb.mul(rnd, 0.0))
    co = nb.vmath("ADD", co, off)
    x, y, z = nb.sep(co)
    # low-frequency waviness of the growth rings (so they are not perfect cylinders)
    wav = nb.noise(nb.vscale(co, (0.7, 2.5, 2.5)), 1.0, detail=3.0, rough=0.55)
    wv = nb.sub(wav.outputs[0], 0.5)
    # the pith runs along X, off the board: (py, pz) set by the per-object random
    py = nb.add(nb.mul(nb.math("SINE", nb.mul(rnd, 91.0)), 0.09), 0.0)
    pz = nb.add(nb.mul(nb.math("COSINE", nb.mul(rnd, 53.0)), 0.06), -0.11)
    # the log's axis is not quite parallel to the board (run-out): rings cut the faces in arches
    sly = nb.mul(nb.sub(nb.math("FRACT", nb.mul(rnd, 3.7)), 0.5), 0.12)
    slz = nb.mul(nb.sub(nb.math("FRACT", nb.mul(rnd, 5.3)), 0.5), 0.10)
    dy = nb.add(nb.add(nb.sub(y, py), nb.mul(wv, 0.035)), nb.mul(x, sly))
    dz = nb.add(nb.add(nb.sub(z, pz), nb.mul(wv, 0.025)), nb.mul(x, slz))
    r = nb.vmath("LENGTH", nb.comb(dy, dz, 0.0))
    # ring spacing varies (fat and thin years)
    yr = nb.noise(nb.comb(nb.mul(r, 6.0), nb.mul(rnd, 9.0), 0.0), 1.0, detail=1.0)
    rc = nb.mul(r, nb.add(rings, nb.mul(nb.sub(yr.outputs[0], 0.5), rings * 0.6)))
    ring = nb.math("FRACT", rc)
    # earlywood fades into latewood, which ends abruptly
    late = nb.mul(nb.mapr(ring, 0.5, 0.9, smooth=True), nb.mapr(ring, 0.93, 1.0, 1.0, 0.0))
    # fibres: long thin streaks along X
    fib = nb.noise(nb.vscale(co, (3.0, 260.0, 260.0)), 1.0, detail=4.0, rough=0.6)
    fibf = fib.outputs[0]
    fine = nb.noise(nb.vscale(co, (8.0, 1400.0, 1400.0)), 1.0, detail=2.0, rough=0.5)
    pores = nb.mapr(fine.outputs[0], 0.62, 0.75)
    # checks / splits along the grain
    chk = nb.noise(nb.vscale(co, (0.9, 34.0, 34.0)), 1.0, detail=2.0, rough=0.4)
    chkline = nb.mapr(nb.math("ABSOLUTE", nb.sub(chk.outputs[0], 0.5)), 0.0, 0.012, 1.0, 0.0)
    chkmask = nb.mapr(nb.noise(nb.vscale(co, (2.2, 6.0, 6.0)), 1.0, detail=1.0).outputs[0], 0.55, 0.68)
    split = nb.mul(chkline, chkmask)
    # knots: elongated along the grain on the faces
    kv = nb.voronoi(nb.vscale(co, (0.35, 1.0, 1.0)), 3.2)
    kd = kv.outputs["Distance"]
    kc = nb.sep(kv.outputs["Color"])[0]
    kon = nb.math("LESS_THAN", kc, knots)
    knot = nb.mul(nb.mapr(kd, 0.045, 0.075, 1.0, 0.0, smooth=True), kon)
    halo = nb.mul(nb.mapr(kd, 0.06, 0.16, 1.0, 0.0, smooth=True), kon)
    knotring = nb.mul(nb.mul(nb.math("SINE", nb.mul(kd, 260.0)), 0.5), halo)
    # nail holes and their rust
    nv = nb.voronoi(co, 7.0)
    nd = nv.outputs["Distance"]
    non = nb.math("LESS_THAN", nb.sep(nv.outputs["Color"])[1], 0.12)
    nail = nb.mul(nb.mapr(nd, 0.018, 0.03, 1.0, 0.0), non)
    rust = nb.mul(nb.mapr(nd, 0.02, 0.12, 1.0, 0.0, smooth=True), non)
    # circular saw marks: arcs across the faces
    saw_c = nb.comb(nb.mul(rnd, 3.0), 0.0, -0.7)
    sawd = nb.vmath("LENGTH", nb.vmath("SUBTRACT", nb.vscale(co, (1.0, 0.0, 1.0)), saw_c))
    saw = nb.math("SINE", nb.mul(sawd, 2 * math.pi / 0.009))
    sawamt = nb.mapr(nb.noise(nb.vscale(co, (1.5, 3, 3)), 1.0, detail=1.0).outputs[0], 0.45, 0.65, 0.0, 1.0)
    saw = nb.mul(saw, sawamt)

    # colour
    k = 1.0 + 0.18 * tone
    early = (0.17 * k, 0.125 * k, 0.08 * k, 1)
    latec = (0.075 * k, 0.046 * k, 0.026 * k, 1)
    col = nb.mix(late, early, latec)
    col = nb.mix(nb.mul(fibf, 0.5), col, (0.6, 0.55, 0.5, 1), blend="MULTIPLY")
    col = nb.mix(nb.mapr(fibf, 0.3, 0.7, 0.0, 0.35), col, (0.24 * k, 0.18 * k, 0.12 * k, 1))
    col = nb.mix(nb.mul(pores, 0.5), col, (0.08, 0.055, 0.035, 1))
    # each board its own shade
    shade = nb.add(0.72, nb.mul(nb.math("FRACT", nb.mul(rnd, 7.31)), 0.5))
    col = nb.mix(1.0, col, nb.comb(shade, shade, shade), blend="MULTIPLY")
    # weathering to grey, patchy and streaked along the grain
    gw = nb.noise(nb.vscale(co, (0.9, 14.0, 14.0)), 1.0, detail=4.0, rough=0.6)
    gw2 = nb.noise(nb.vscale(co, (1.2, 3.0, 3.0)), 1.0, detail=2.0)
    gfac = nb.mul(nb.mul(nb.mapr(gw.outputs[0], 0.35, 0.65), nb.mapr(gw2.outputs[0], 0.3, 0.6, 0.4, 1.0)), grey)
    col = nb.mix(gfac, col, (0.13, 0.12, 0.105, 1))
    # knots
    col = nb.mix(nb.mul(halo, 0.35), col, (0.15, 0.09, 0.05, 1))
    col = nb.mix(nb.mul(nb.math("ABSOLUTE", knotring), 0.6), col, (0.10, 0.06, 0.035, 1))
    col = nb.mix(knot, col, (0.07, 0.035, 0.018, 1))
    # rust bleed and holes
    col = nb.mix(nb.mul(rust, 0.55), col, (0.17, 0.065, 0.02, 1))
    col = nb.mix(nail, col, (0.015, 0.01, 0.008, 1))
    # dirt: large blotches and grime
    pos = nb.geo("Position")
    nrm = nb.geo("Normal")
    px, py_, pzw = nb.sep(pos)
    dirt = nb.noise(pos, 2.2, detail=5.0, rough=0.65)
    col = nb.mix(nb.mul(nb.mapr(dirt.outputs[0], 0.40, 0.70), 0.85), col, (0.035, 0.03, 0.024, 1))
    # grime run down the vertical faces
    vert = nb.mapr(nb.math("ABSOLUTE", nb.sep(nb.geo("Normal"))[2]), 0.6, 0.2)
    drip = nb.noise(nb.vscale(pos, (14.0, 14.0, 0.5)), 1.0, detail=3.0, rough=0.6)
    dripf = nb.mul(nb.mapr(drip.outputs[0], 0.55, 0.75), vert)
    col = nb.mix(nb.mul(dripf, 0.5), col, (0.04, 0.032, 0.024, 1))
    # black mould speckles where it was damp
    mv = nb.voronoi(pos, 140.0)
    mmask = nb.mapr(nb.noise(pos, 3.0, detail=2.0).outputs[0], 0.55, 0.7)
    mould = nb.mul(nb.mapr(mv.outputs["Distance"], 0.12, 0.3, 1.0, 0.0), nb.mul(mmask, damp))
    col = nb.mix(nb.mul(mould, 0.85), col, (0.012, 0.012, 0.01, 1))
    # damp / water stains low down: darker below a ragged tide line
    tide_h = nb.add(0.25, nb.mul(nb.noise(nb.vscale(pos, (3.0, 3.0, 0.2)), 1.0, detail=3.0).outputs[0], 0.35))
    below = nb.mapr(nb.sub(tide_h, pzw), -0.01, 0.05)
    line = nb.mapr(nb.math("ABSOLUTE", nb.sub(pzw, tide_h)), 0.0, 0.012, 1.0, 0.0)
    col = nb.mix(nb.mul(below, 0.45 * damp), col, (0.06, 0.045, 0.03, 1), blend="MULTIPLY")
    col = nb.mix(nb.mul(line, 0.5 * damp), col, (0.08, 0.05, 0.025, 1))
    # dust settles on up-facing faces (and fuzzes the grain)
    up = nb.mapr(nb.sep(nrm)[2], 0.35, 0.9)
    dn = nb.noise(pos, 9.0, detail=4.0, rough=0.7)
    dfac = nb.mul(nb.mul(up, nb.mapr(dn.outputs[0], 0.3, 0.6, 0.55, 1.0)), dust)
    col = nb.mix(dfac, col, (0.22, 0.20, 0.17, 1))
    # a little fine dust everywhere
    col = nb.mix(nb.mul(nb.mapr(dn.outputs[0], 0.5, 0.8), 0.18 * dust), col, (0.26, 0.245, 0.22, 1))

    # roughness
    rough = nb.add(0.78, nb.mul(late, -0.08))
    rough = nb.add(rough, nb.mul(dfac, 0.15))
    rough = nb.math("MINIMUM", nb.add(rough, nb.mul(knot, -0.15)), 1.0)

    # height: raised latewood (weathered grain), fibres, saw marks; minus splits, holes
    h = nb.mul(late, 0.6)
    h = nb.add(h, nb.mul(fibf, 0.35))
    h = nb.add(h, nb.mul(pores, -0.15))
    h = nb.add(h, nb.mul(saw, 0.10))
    h = nb.add(h, nb.mul(split, -1.4))
    h = nb.add(h, nb.mul(nail, -1.5))
    h = nb.add(h, nb.mul(knot, 0.2))
    h = nb.add(h, nb.mul(knotring, 0.25))
    h = nb.lerp(nb.mul(dfac, 0.6), h, nb.mul(dn.outputs[0], 0.4))
    nrm_out = nb.bump(h, 1.0, 0.0024)
    return nb.finish(col, rough, nrm_out)


# ---------------------------------------------------------------------------------------------------------------
# wood test: three boards close up

def woodtest():
    C.reset_scene()
    rng = random.Random(4)
    stud = wood_material("WoodStud", tone=0.0, grey=0.65, dust=0.6)
    plank = wood_material("WoodPlank", tone=-0.5, grey=0.8, dust=0.3, knots=0.45)
    obs = []
    b = C.board("Stud", 1.4, 0.10, 0.05, stud, segs=8, rng=rng, bow=0.003, twist=0.02, bevel=0.005)
    C.orient(b, "Z", "X", (0, 0, 0))     # standing up: length up, 10 cm deep along X
    obs.append(b)
    for i in range(3):
        p = C.board(f"Plank{i}", 1.2, 0.17, 0.022, plank, segs=8, rng=rng, bow=0.004, twist=0.03, bevel=0.003)
        C.orient(p, "Y", "Z", (-0.07, -0.6, 0.3 + i * 0.185))
        obs.append(p)
    obs = C.apply_all(obs)
    C.uv_unwrap(obs)
    C.bake_atlas(obs, "woodtest", 1024)
    for o in obs:
        print(o.name, "px/m", round(C.texel_density(o, 1024)))
    sc, cam = C.preview_setup("CYCLES", (1000, 800), 64)
    C.area_light("Key", (1.0, 0.6, 1.6), (0, 0, 0.6), 60, 0.6)
    C.area_light("Fill", (0.8, -1.2, 0.6), (0, 0, 0.6), 15, 1.0)
    C.shoot(cam, (0.55, 0.25, 0.9), (-0.02, -0.1, 0.62), os.path.join(PREVIEW, "woodtest.png"), lens=35)


# ---------------------------------------------------------------------------------------------------------------
# other procedural materials

def paper_back_material(name, base=(0.20, 0.17, 0.125), stains=1.0, dust=0.5):
    """The back of plasterboard: grey-brown kraft paper, water tide marks, grime toward the floor, dust"""
    m, nb = C.new_mat(name)
    pos = nb.geo("Position")
    nrm = nb.geo("Normal")
    x, y, z = nb.sep(pos)
    fib = nb.noise(pos, 380.0, detail=4.0, rough=0.7)
    blot = nb.noise(pos, 6.0, detail=5.0, rough=0.6)
    col = nb.mix(nb.mapr(blot.outputs[0], 0.3, 0.7), (*base, 1), (base[0] * 0.8, base[1] * 0.8, base[2] * 0.82, 1))
    col = nb.mix(nb.mul(fib.outputs[0], 0.4), col, (base[0] * 0.7, base[1] * 0.7, base[2] * 0.7, 1), blend="MULTIPLY")
    # tide-line water stains: noisy contours of a field, darker band at the edge, tinted brown inside
    st = nb.noise(nb.vscale(pos, (1.0, 1.0, 0.6)), 1.6, detail=4.0, rough=0.6, dist=0.4)
    sf = st.outputs[0]
    inside = nb.mapr(sf, 0.56, 0.6)
    edge = nb.mul(nb.mapr(sf, 0.55, 0.585), nb.mapr(sf, 0.59, 0.61, 1.0, 0.0))
    edge2 = nb.mul(nb.mapr(sf, 0.6, 0.62), nb.mapr(sf, 0.625, 0.64, 1.0, 0.0))
    col = nb.mix(nb.mul(inside, 0.4 * stains), col, (0.11, 0.075, 0.04, 1))
    col = nb.mix(nb.mul(nb.add(edge, nb.mul(edge2, 0.6)), 0.75 * stains), col, (0.07, 0.045, 0.022, 1))
    # grime rising from the floor, and drips
    low = nb.mapr(z, 0.0, 0.7, 1.0, 0.0, smooth=True)
    col = nb.mix(nb.mul(low, 0.6), col, (0.04, 0.032, 0.025, 1))
    drip = nb.noise(nb.vscale(pos, (16.0, 16.0, 0.4)), 1.0, detail=3.0)
    col = nb.mix(nb.mul(nb.mapr(drip.outputs[0], 0.58, 0.75), 0.5), col, (0.05, 0.04, 0.03, 1))
    # mould spots
    mv = nb.voronoi(pos, 90.0)
    mm = nb.mapr(nb.noise(pos, 2.5, detail=2.0).outputs[0], 0.58, 0.7)
    mould = nb.mul(nb.mapr(mv.outputs["Distance"], 0.1, 0.35, 1.0, 0.0), mm)
    col = nb.mix(nb.mul(mould, 0.8), col, (0.015, 0.015, 0.012, 1))
    # dust
    dn = nb.noise(pos, 12.0, detail=4.0, rough=0.7)
    up = nb.mapr(nb.sep(nrm)[2], 0.3, 0.9)
    dfac = nb.mul(nb.add(nb.mul(up, 0.8), 0.2), nb.mul(nb.mapr(dn.outputs[0], 0.35, 0.7), dust))
    col = nb.mix(dfac, col, (0.20, 0.19, 0.17, 1))
    rough = nb.add(0.88, nb.mul(inside, -0.08))
    h = nb.add(nb.mul(fib.outputs[0], 0.4), nb.mul(blot.outputs[0], 0.6))
    h = nb.add(h, nb.mul(edge, 0.3))
    return nb.finish(col, rough, nb.bump(h, 0.6, 0.0015))


def flat_material(name, color, rough=0.95, bump_scale=60.0, bump=0.3, var=0.3):
    m, nb = C.new_mat(name)
    pos = nb.geo("Position")
    n = nb.noise(pos, bump_scale, detail=5.0, rough=0.65)
    b = nb.noise(pos, 4.0, detail=3.0)
    col = nb.mix(nb.mul(b.outputs[0], var), (*color, 1), (color[0] * 0.5, color[1] * 0.5, color[2] * 0.5, 1))
    return nb.finish(col, rough, nb.bump(n.outputs[0], bump, 0.002))


def gypsum_material(name, dirty=0.5):
    """Broken plaster core: chalky off-white, grainy, crumbs of darker aggregate, dirt"""
    m, nb = C.new_mat(name)
    pos = nb.geo("Position")
    gr = nb.noise(pos, 900.0, detail=2.0)
    pits = nb.voronoi(pos, 450.0)
    pitf = nb.mapr(pits.outputs["Distance"], 0.05, 0.25, 1.0, 0.0)
    blot = nb.noise(pos, 8.0, detail=4.0)
    col = nb.mix(nb.mul(gr.outputs[0], 0.35), (0.62, 0.60, 0.55, 1), (0.42, 0.40, 0.36, 1))
    col = nb.mix(nb.mul(pitf, 0.5), col, (0.30, 0.28, 0.25, 1))
    col = nb.mix(nb.mul(nb.mapr(blot.outputs[0], 0.4, 0.7), dirty), col, (0.30, 0.27, 0.22, 1))
    h = nb.add(nb.mul(gr.outputs[0], 0.5), nb.mul(pitf, -0.6))
    return nb.finish(col, 0.97, nb.bump(h, 0.8, 0.0012))


def rust_material(name, paint=(0.05, 0.05, 0.048), rustiness=0.6):
    m, nb = C.new_mat(name)
    pos = nb.geo("Position")
    r1 = nb.noise(pos, 9.0, detail=6.0, rough=0.65)
    r2 = nb.noise(pos, 70.0, detail=3.0)
    rf = nb.mapr(nb.add(r1.outputs[0], nb.mul(nb.sub(r2.outputs[0], 0.5), 0.3)), 0.62 - rustiness * 0.2, 0.72 - rustiness * 0.2)
    rcol = nb.mix(r2.outputs[0], (0.10, 0.035, 0.012, 1), (0.20, 0.08, 0.025, 1))
    col = nb.mix(rf, (*paint, 1), rcol)
    _, _, z = nb.sep(pos)
    col = nb.mix(nb.mul(nb.mapr(nb.noise(pos, 20.0, detail=3.0).outputs[0], 0.5, 0.7), 0.5), col, (0.18, 0.17, 0.15, 1))
    rough = nb.add(0.55, nb.mul(rf, 0.4))
    h = nb.add(nb.mul(rf, 0.6), nb.mul(r2.outputs[0], 0.3))
    return nb.finish(col, rough, nb.bump(h, 0.7, 0.0015))


def cloth_material(name):
    m, nb = C.new_mat(name)
    co = nb.coord("Object")
    w = nb.noise(nb.vscale(co, (400.0, 400.0, 400.0)), 1.0, detail=2.0)
    col = nb.mix(nb.mul(w.outputs[0], 0.6), (0.025, 0.022, 0.02, 1), (0.08, 0.07, 0.06, 1))
    return nb.finish(col, 0.9, nb.bump(w.outputs[0], 0.5, 0.001))


def insulation_material(name):
    """Old fibreglass batt: yellow-pink, fibrous and tufty, dusty grey patches"""
    m, nb = C.new_mat(name)
    pos = nb.geo("Position")
    # fibres in many directions: two stretched noises crossed
    f1 = nb.noise(nb.vscale(pos, (120.0, 30.0, 300.0)), 1.0, detail=6.0, rough=0.75, dist=1.2)
    f2 = nb.noise(nb.vscale(pos, (300.0, 140.0, 40.0)), 1.0, detail=6.0, rough=0.75, dist=1.2)
    fib = nb.math("MAXIMUM", f1.outputs[0], f2.outputs[0])
    clump = nb.voronoi(pos, 22.0, feature="SMOOTH_F1")
    cl = clump.outputs["Distance"]
    hue = nb.noise(pos, 3.0, detail=3.0)
    base = nb.mix(nb.mapr(hue.outputs[0], 0.35, 0.65), srgb(214, 172, 112), srgb(206, 138, 128))
    col = nb.mix(nb.mapr(fib, 0.45, 0.8), base, srgb(236, 214, 170))
    col = nb.mix(nb.mul(nb.mapr(cl, 0.2, 0.6), 0.55), col, srgb(110, 78, 58), blend="MULTIPLY")
    grime = nb.noise(pos, 5.0, detail=4.0, rough=0.6)
    col = nb.mix(nb.mul(nb.mapr(grime.outputs[0], 0.48, 0.7), 0.75), col, srgb(70, 62, 54))
    h = nb.add(nb.mul(fib, 0.8), nb.mul(cl, -0.9))
    return nb.finish(col, 0.96, nb.bump(h, 1.0, 0.004))


def srgb(r, g, b):
    return C.srgb(r, g, b)


# ---------------------------------------------------------------------------------------------------------------
# geometry helpers

def shell_quad(bm, pts, inward):
    """A quad (any order) whose normal is forced to point along `inward`"""
    vs = [bm.verts.new(p) for p in pts]
    f = bm.faces.new(vs)
    f.normal_update()
    if f.normal.dot(Vector(inward)) < 0:
        f.normal_flip()
    return f


def grid_quad(name, corner, du, dv, nu, nv, inward, mat):
    """A subdivided rectangle corner + s*du + t*dv, normal along inward"""
    bm = bmesh.new()
    corner, du, dv = Vector(corner), Vector(du), Vector(dv)
    vs = [[bm.verts.new(corner + du * (i / nu) + dv * (j / nv)) for j in range(nv + 1)] for i in range(nu + 1)]
    for i in range(nu):
        for j in range(nv):
            f = bm.faces.new((vs[i][j], vs[i + 1][j], vs[i + 1][j + 1], vs[i][j + 1]))
            f.normal_update()
            if f.normal.dot(Vector(inward)) < 0:
                f.normal_flip()
    return C.mesh_from_bm(name, bm, [mat])


def lumpy(name, center, radii, mat, subdiv=3, amp=0.25, freq=3.0, seed=0, flat_bottom=None, rot=(0, 0, 0)):
    """A displaced, squashed icosphere: crumbs, tufts, dust piles"""
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0)
    off = Vector((seed * 7.13, seed * 3.71, seed * 1.93))
    R = Euler(rot).to_matrix()
    for v in bm.verts:
        n = v.co.normalized()
        d = mnoise.fractal(n * freq + off, 0.6, 2.0, 4)
        p = n * (1.0 + amp * d)
        p = Vector((p.x * radii[0], p.y * radii[1], p.z * radii[2]))
        p = R @ p + Vector(center)
        if flat_bottom is not None and p.z < flat_bottom:
            p.z = flat_bottom + (p.z - flat_bottom) * 0.05
        v.co = p
    return C.mesh_from_bm(name, bm, [mat])


def chunk(name, outline_r, thick, mat, seed, jag=0.35, n=9):
    """A broken flat fragment: a jagged polygon extruded (centred on the origin, lying in XY, thickness Z)"""
    rng = random.Random(seed)
    pts = []
    for i in range(n):
        a = 2 * math.pi * (i + rng.uniform(-0.3, 0.3)) / n
        r = outline_r * rng.uniform(1.0 - jag, 1.0 + jag * 0.5)
        pts.append((math.cos(a) * r, math.sin(a) * r * rng.uniform(0.6, 1.0)))
    bm = bmesh.new()
    top = [bm.verts.new((x, y, thick / 2 + rng.uniform(-0.002, 0.002))) for x, y in pts]
    bot = [bm.verts.new((x + rng.uniform(-0.004, 0.004), y + rng.uniform(-0.004, 0.004), -thick / 2)) for x, y in pts]
    bm.faces.new(top)
    bm.faces.new(bot[::-1])
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((top[j], top[i], bot[i], bot[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return C.mesh_from_bm(name, bm, [mat] if not isinstance(mat, (list, tuple)) else list(mat))


def tube(name, pts, radius, mat, segs=8):
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    sp = cu.splines.new("POLY")
    sp.points.add(len(pts) - 1)
    for p, co in zip(sp.points, pts):
        p.co = (*co, 1.0)
    cu.bevel_depth = radius
    cu.bevel_resolution = max(0, segs // 4 - 1)
    cu.use_fill_caps = True
    ob = C.link(bpy.data.objects.new(name, cu))
    cu.materials.append(mat)
    bpy.context.view_layer.update()
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(bpy.context.evaluated_depsgraph_get()))
    bpy.data.objects.remove(ob)
    new = C.link(bpy.data.objects.new(name, me))
    return new


def batt(name, w, h, thick, mat, seed, torn_top=None, torn_bottom=None, sag=0.0, nu=12, nv=16):
    """A fibreglass batt, lying in the local YZ plane (x = depth toward +X), y from 0..w, z from 0..h.
    torn_top / torn_bottom: ragged edge amplitude. sag: the free bottom bulges toward +X by this much."""
    rng = random.Random(seed)
    off = Vector((seed * 3.1, seed * 1.7, seed * 5.3))
    bm = bmesh.new()
    cols = []
    for i in range(nu + 1):
        u = i / nu
        top = h - (abs(mnoise.fractal(Vector((u * 4.0, seed, 0.3)) + off, 0.5, 2.0, 3)) * torn_top + rng.uniform(0, torn_top * 0.4) if torn_top else 0.0)
        bot = (abs(mnoise.fractal(Vector((u * 4.0, seed, 1.7)) + off, 0.5, 2.0, 3)) * torn_bottom + rng.uniform(0, torn_bottom * 0.5)) if torn_bottom else 0.0
        col = []
        for j in range(nv + 1):
            t = j / nv
            zz = bot + (top - bot) * t
            yy = u * w
            # puffy: thick in the middle, thinner at the edges
            puff = math.sin(math.pi * min(max(u, 0.02), 0.98)) ** 0.5 * math.sin(math.pi * min(max(t, 0.04), 0.96)) ** 0.4
            n = mnoise.fractal(Vector((yy * 9, zz * 9, 0.0)) + off, 0.6, 2.0, 4)
            front = thick * (0.45 + 0.55 * puff) * (1.0 + 0.45 * n)
            bow = sag * (1.0 - t) ** 2
            col.append((yy, zz, front + bow, bow * 0.6))
        cols.append(col)
    fv = [[bm.verts.new((c[2], c[0], c[1])) for c in col] for col in cols]
    bv = [[bm.verts.new((c[3], c[0], c[1])) for c in col] for col in cols]
    for i in range(nu):
        for j in range(nv):
            bm.faces.new((fv[i][j], fv[i + 1][j], fv[i + 1][j + 1], fv[i][j + 1]))
            bm.faces.new((bv[i][j + 1], bv[i + 1][j + 1], bv[i + 1][j], bv[i][j]))
    for i in range(nu):        # bottom and top edges
        bm.faces.new((bv[i][0], bv[i + 1][0], fv[i + 1][0], fv[i][0]))
        bm.faces.new((fv[i][nv], fv[i + 1][nv], bv[i + 1][nv], bv[i][nv]))
    for j in range(nv):        # sides
        bm.faces.new((fv[0][j], fv[0][j + 1], bv[0][j + 1], bv[0][j]))
        bm.faces.new((bv[nu][j], bv[nu][j + 1], fv[nu][j + 1], fv[nu][j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # fuzz every vertex a little
    for v in bm.verts:
        v.co += Vector(mnoise.random_unit_vector()) * 0.004 * rng.random()
    return C.mesh_from_bm(name, bm, [mat])


# ---------------------------------------------------------------------------------------------------------------
# cobweb texture (numpy) and drawing helpers

def cobweb_texture(path, size=1024, seed=3):
    """A corner web: radial threads fanning from the top-left corner, sagging cross threads, loose strands,
    dust caught in it. Row 0 = top; the web's anchor corner is pixel (0, 0) = UV (0, 1)."""
    rng = random.Random(seed)
    S = size
    lines_fine, lines_thick = [], []
    nrad = 13
    angs = sorted(rng.uniform(0.02, math.pi / 2 - 0.02) for _ in range(nrad))
    rad_len = [rng.uniform(0.75, 1.35) * S for _ in angs]
    for a, L in zip(angs, rad_len):
        pts = [(0.0, 0.0)]
        for t in np.linspace(0.05, 1.0, 12):
            pts.append((math.cos(a) * L * t + rng.uniform(-2, 2), math.sin(a) * L * t + rng.uniform(-2, 2)))
        lines_thick.append(np.array(pts))
    # cross threads: from one radial to the next, sagging toward the corner
    r = 40.0
    while r < S * 1.25:
        for i in range(nrad - 1):
            if rng.random() < 0.18:
                continue
            a0, a1 = angs[i], angs[i + 1]
            r0 = r * rng.uniform(0.92, 1.08)
            r1 = r * rng.uniform(0.92, 1.08)
            if r0 > rad_len[i] or r1 > rad_len[i + 1]:
                continue
            p0 = np.array((math.cos(a0) * r0, math.sin(a0) * r0))
            p1 = np.array((math.cos(a1) * r1, math.sin(a1) * r1))
            mid = (p0 + p1) / 2
            sag = -mid / np.linalg.norm(mid) * np.linalg.norm(p1 - p0) * rng.uniform(0.05, 0.2)
            ts = np.linspace(0, 1, 8)[:, None]
            lines_fine.append(p0 * (1 - ts) + p1 * ts + sag * (4 * ts * (1 - ts)))
        r += rng.uniform(18, 46) * (1 + r / S)
    # loose, broken strands
    for _ in range(26):
        p = np.array((rng.uniform(0, S), rng.uniform(0, S)))
        a = rng.uniform(0, 2 * math.pi)
        L = rng.uniform(40, 260)
        q = p + np.array((math.cos(a), math.sin(a))) * L
        ts = np.linspace(0, 1, 10)[:, None]
        lines_fine.append(p * (1 - ts) + q * ts + np.array((0, rng.uniform(5, 30))) * (4 * ts * (1 - ts)))
    a1 = C.splat_lines((S, S), lines_thick, 1.1, 0.85)
    a2 = C.splat_lines((S, S), lines_fine, 0.75, 0.6)
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    rr = np.hypot(xx, yy) / S
    # dusty sheet near the corner, thinning out
    dust = np.clip(1.0 - rr / 0.55, 0, 1) ** 2 * 0.35
    rngn = np.random.default_rng(seed)
    speck = C.gauss_blur((rngn.random((S, S)) > 0.9985).astype(np.float32), 1.2) * 6.0
    alpha = np.clip(a1 + a2 + dust * (0.6 + 0.4 * C.gauss_blur(rngn.random((S, S)).astype(np.float32), 6)) + speck * (rr < 0.9), 0, 1)
    alpha *= np.clip((1.3 - rr) / 0.4, 0, 1)
    col = np.zeros((S, S, 4), np.float32)
    shade = 0.62 + 0.18 * np.clip(1 - rr, 0, 1)
    col[..., 0] = shade * 0.95
    col[..., 1] = shade * 0.93
    col[..., 2] = shade * 0.88
    col[..., 3] = alpha
    C.save_rgba(path, col)


def web_material(name, path):
    m, nb = C.new_mat(name)
    t = nb.image(path, "sRGB", ext="EXTEND")
    nb.finish(t.outputs[0], 1.0, alpha=t.outputs[1])
    m.use_backface_culling = False
    try:
        m.surface_render_method = "BLENDED"
    except (AttributeError, TypeError):
        m.blend_method = "BLEND"
    return m


def web_sheet(name, corner, a, b, mat, sag=(0, 0, 0), n=5, seed=0):
    """A web stretched from `corner` along edge vectors a and b (UV (0,1) at the corner), billowing by `sag`"""
    rng = random.Random(seed)
    bm = bmesh.new()
    corner, a, b, sag = Vector(corner), Vector(a), Vector(b), Vector(sag)
    vs = []
    uvs = {}
    for i in range(n + 1):
        row = []
        for j in range(n + 1):
            s, t = i / n, j / n
            p = corner + a * s + b * t + sag * (math.sin(math.pi * min(1, s + t) * 0.5) * s * t * 4 if s + t > 0 else 0)
            p += Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1))) * 0.003 * (s + t)
            v = bm.verts.new(p)
            uvs[v] = (s, 1.0 - t)
            row.append(v)
        vs.append(row)
    uvl = bm.loops.layers.uv.new("UVMap")
    for i in range(n):
        for j in range(n):
            if i / n + j / n > 1.25:            # the far corner of the quad is not web (its texture fades out)
                continue
            f = bm.faces.new((vs[i][j], vs[i + 1][j], vs[i + 1][j + 1], vs[i][j + 1]))
            for l in f.loops:
                l[uvl].uv = uvs[l.vert]
    return C.mesh_from_bm(name, bm, [mat])


# ---------------------------------------------------------------------------------------------------------------
# the cavity

def build_cavity():
    """A walk-in void inside the 4.5 m wall block: x in [-2.4, -0.03], y (Godot -z) in [-1.2, 1.2], z in [0, 2.9].
    Not a box: the back is two plank walls at different depths, the side walls lean and run a little crooked, rough
    horizontal planks of varying length / width / tilt with gaps, a broken one hanging, one leaning on the back,
    crooked studs, a diagonal brace, sagging joists, torn fibreglass bulging between studs, dust and debris on an
    uneven board floor. A black inward-facing box behind it all closes it (the gaps show darkness). The floor stays
    clear about x in [-1.8, -0.1], y in [-0.8, 0.8]."""
    C.reset_scene()
    rng = random.Random(11)
    frame = wood_material("WoodFrame", tone=0.0, grey=0.6, dust=0.7, damp=0.6)
    frame2 = wood_material("WoodFrameDark", tone=-0.6, grey=0.5, dust=0.6, damp=0.9, knots=0.35)
    sheath = wood_material("WoodSheath", tone=-0.7, grey=0.85, dust=0.35, knots=0.5, damp=0.8, rings=120.0)
    sheath2 = wood_material("WoodSheathWarm", tone=-0.2, grey=0.55, dust=0.4, knots=0.4, damp=0.7, rings=170.0)
    floorw = wood_material("WoodFloor", tone=-0.3, grey=0.7, dust=1.0, damp=0.5)
    X0, X1, Y0, Y1, ZT = -2.4, -0.03, -1.2, 1.2, 2.9
    HW, HH = C.HOLE_W / 2, C.HOLE_H
    near, walls_a, walls_b = [], [], []        # three wood atlases

    def frame_m(origin, u, n, lean=0.0):
        """wall frame: columns u (along the wall), up (leaning by `lean` rad toward n), n (into the room)"""
        u, n = Vector(u).normalized(), Vector(n).normalized()
        up = Vector((0, 0, 1))
        up = (up * math.cos(lean) + n * math.sin(lean)).normalized()
        n = u.cross(up).normalized() if u.cross(up).dot(n) > 0 else -u.cross(up).normalized()
        return u, up, n, Vector(origin)

    def wboard(lst, name, F, kind, s, h, L, w, t, mat, d=0.0, tilt=0.0, **kw):
        """a board in wall frame F: kind "plank" (along the wall, s..s+L at height h centre) or "stud" (upright at s,
        from h up L, depth w into the room from d) or "flat" (lying along the wall, w tall, facing the room)"""
        u, up, n, o = F
        kw.setdefault("rng", rng)
        kw.setdefault("segs", max(2, int(L / 0.5)))
        b = C.board(name, L, w, t, mat, **kw)
        if kind == "plank":
            X, Y = u, up
            pos = o + u * s + up * h + n * (d + t / 2)
        elif kind == "stud":
            X, Y = up, n
            pos = o + u * s + up * h + n * (d + w / 2)
        else:
            X, Y = u, n
            pos = o + u * s + up * h + n * (d + w / 2)
        Z = X.cross(Y)
        m = Matrix((X, Y, Z)).transposed().to_4x4()
        m = m @ Matrix.Rotation(tilt, 4, "Z")
        m.translation = pos
        b.matrix_world = m
        lst.append(b)
        return b

    def plank_wall(lst, prefix, F, length, mats, top=ZT - 0.01, broken=(), missing=(), z0=0.014, depth=0.0):
        """rows of rough horizontal planks, butt-jointed in random lengths; returns the rows' (h, hh) list"""
        h = z0
        row = 0
        rows = []
        while h < top - 0.02:
            hgt = min(rng.uniform(0.14, 0.26), top - h)
            gap = rng.uniform(0.004, 0.02) if rng.random() < 0.75 else rng.uniform(0.025, 0.055)
            hh = max(0.04, hgt - gap)
            s = -0.02
            seg = 0
            while s < length - 0.05:
                L = min(rng.uniform(0.7, 1.7), length + 0.02 - s)
                if L < 0.25:
                    break
                key = (row, seg)
                if key not in missing:
                    wboard(lst, f"{prefix}{row}_{seg}", F, "plank", s, h + hh / 2, L, hh * rng.uniform(0.94, 1.0),
                           rng.uniform(0.018, 0.026), rng.choice(mats), d=depth + rng.uniform(-0.006, 0.012),
                           tilt=rng.gauss(0, 0.008), bow=rng.uniform(0.002, 0.008), twist=rng.uniform(-0.05, 0.05),
                           bevel=0.003, end_rough=0.03 if key in broken else 0.006, segs=max(2, int(L / 0.45)))
                s += L + rng.uniform(0.004, 0.03)
                seg += 1
            rows.append((h, hh))
            h += hgt
            row += 1
        return rows

    # ---- the walls: back in two sections at different depths, sides leaning and a little crooked
    FB1 = frame_m((-2.27, Y0 + 0.025, 0), (math.sin(math.radians(2.5)), 1, 0), (1, 0, 0), lean=math.radians(1.0))
    FB2 = frame_m((-2.32, 0.05, 0), (math.sin(math.radians(-2.0)), 1, 0), (1, 0, 0), lean=math.radians(-0.8))
    FL = frame_m((X0 + 0.025, -1.19, 0), (1, math.sin(math.radians(2.5)), 0), (0, 1, 0), lean=math.radians(1.5))
    FR = frame_m((X1 - 0.04, 1.17, 0), (-1, math.sin(math.radians(-2.0)), 0), (0, -1, 0), lean=math.radians(1.2))
    rows = {}
    rows["B1"] = plank_wall(walls_a, "PB1_", FB1, 1.22, [sheath, sheath2], broken={(4, 0)}, missing={(9, 0)})
    rows["B2"] = plank_wall(walls_a, "PB2_", FB2, 1.1, [sheath, sheath2], broken={(6, 0)})
    rows["L"] = plank_wall(walls_a, "PL_", FL, 2.33, [sheath, sheath2], broken={(3, 1), (11, 0)}, missing={(7, 1)})
    rows["R"] = plank_wall(walls_b, "PR_", FR, 2.3, [sheath2, sheath], broken={(8, 0)}, missing={(5, 0), (5, 1)})
    # studs: crooked (bowed, twisted, leaning a degree or two)
    for F, lst, tag, ss_, mats in ((FB1, walls_a, "SB1_", (0.1, 0.62, 1.2), (frame, frame2)),
                                   (FB2, walls_a, "SB2_", (0.02, 0.55, 1.08), (frame2, frame)),
                                   (FL, walls_b, "SL_", (0.25, 0.85, 1.45, 2.05), (frame, frame2)),
                                   (FR, walls_b, "SR_", (0.3, 0.9, 1.5, 2.1), (frame2, frame))):
        for i, s in enumerate(ss_):
            wboard(lst, f"{tag}{i}", F, "stud", s, 0.006, 2.71 + rng.uniform(-0.03, 0.03), 0.10, 0.05, mats[i % 2],
                   d=0.026, tilt=rng.gauss(0, 0.012), bow=rng.uniform(0.006, 0.016), twist=rng.uniform(-0.06, 0.06),
                   bevel=0.005, segs=6)
    # a let-in diagonal brace across the left wall's studs
    bl = math.hypot(1.75, 2.45)
    wboard(walls_b, "Brace", FL, "plank", 0.2, 0.08, bl, 0.09, 0.04, frame2, d=0.126,
           tilt=math.atan2(2.45, 1.75), bevel=0.004, segs=6, bow=0.004)
    # blocking between studs, at odd heights
    for F, lst, tag, specs in ((FB1, walls_a, "BkB1_", ((0.15, 1.22, 0.45), (0.67, 1.3, 0.51))),
                               (FR, walls_b, "BkR_", ((0.35, 1.25, 0.53), (1.55, 1.18, 0.53)))):
        for i, (s, h, L) in enumerate(specs):
            wboard(lst, f"{tag}{i}", F, "plank", s, h, L, 0.10, 0.05, frame2 if i else frame, d=0.03,
                   tilt=rng.gauss(0, 0.02), bevel=0.004, end_rough=0.005, segs=2)
    # a broken plank hanging off one nail on the right wall, another leaning on the back
    wboard(walls_b, "Hanging", FR, "plank", 1.0, 1.95, 0.95, 0.17, 0.022, sheath, d=0.13, tilt=math.radians(-38),
           bevel=0.003, end_rough=0.05, bow=0.01, segs=3)
    lean_b = C.board("Leaning", 1.5, 0.2, 0.024, sheath2, segs=4, bevel=0.003, end_rough=0.03, rng=rng, bow=0.006)
    bot_, top_ = Vector((-1.99, 0.85, 0.02)), Vector((-2.29, 0.87, 1.49))
    LX = (top_ - bot_).normalized()
    LY = Vector((0, 1, 0))
    LY = (LY - LX * LY.dot(LX)).normalized()
    LZ = LX.cross(LY)
    mlean = Matrix((LX, LY, LZ)).transposed().to_4x4()
    mlean.translation = bot_ + LZ * 0.012
    lean_b.matrix_world = mlean
    walls_a.append(lean_b)

    # ---- front wall (inside of the room's wall): studs, plates, firestop over the hole
    Z1 = 2.74
    for i, yc in enumerate((-1.0, -0.50, 0.50, 1.0)):
        b = C.board(f"StudF{i}", Z1 - 0.068, 0.10, 0.05, frame if i % 2 else frame2, rng=rng, segs=6,
                    bow=rng.uniform(0.004, 0.01), twist=0.04, bevel=0.005)
        C.orient(b, "Z", "X", (-0.08, yc, 0.068))
        near.append(b)
    for i, (y0, y1) in enumerate(((Y0 + 0.08, -0.47), (0.47, Y1 - 0.08))):
        b = C.board(f"SoleF{i}", y1 - y0, 0.10, 0.05, frame2, rng=rng, segs=2, bevel=0.004, end_rough=0.01)
        C.orient(b, "Y", "X", (-0.08, y0, 0.043))
        near.append(b)
    b = C.board("TopF", 2.24, 0.10, 0.05, frame, rng=rng, segs=4, bevel=0.004)
    C.orient(b, "Y", "X", (-0.08, -1.12, Z1 + 0.025))
    near.append(b)
    b = C.board("Firestop", 0.95, 0.10, 0.05, frame2, rng=rng, segs=2, bevel=0.004, bow=0.003)
    C.orient(b, "Y", "Z", (-0.057, -0.475, 2.27))
    near.append(b)
    # ---- the floor: boards along X, not quite level, one missing near the right wall
    y = Y0 + 0.001
    i = 0
    while y < Y1 - 0.01:
        w = min(rng.uniform(0.12, 0.18), Y1 - 0.001 - y)
        if not (0.9 < y < 1.05):
            b = C.board(f"Floor{i}", X1 - X0 - 0.005, w - 0.005, 0.02, floorw, rng=rng, segs=5, bevel=0.003,
                        twist=0.02, bow=rng.uniform(0.0, 0.004), jitter=0.0015)
            C.orient(b, "X", "Y", (X0 + 0.002, y + w / 2, 0.0135 + rng.uniform(0.0, 0.004)))
            b.matrix_world = b.matrix_world @ Matrix.Rotation(rng.gauss(0, 0.004), 4, "X")
            near.append(b)
        y += w
        i += 1
    # ---- ceiling: joists sagging at uneven heights, boards above
    for i, yc in enumerate((-0.95, -0.33, 0.3, 0.92)):
        b = C.board(f"Joist{i}", 2.3, 0.18, 0.05, frame2 if i % 2 else frame, rng=rng, segs=5, bevel=0.005,
                    twist=0.03)
        C.orient(b, "X", "Z", (X0 + 0.03, yc, 2.79 + rng.uniform(-0.04, 0.02)))
        for v in b.data.vertices:            # sag in the middle
            v.co.y -= 0.035 * math.sin(math.pi * min(max(v.co.x / 2.3, 0), 1))
        b.matrix_world = b.matrix_world @ Matrix.Rotation(rng.gauss(0, 0.015), 4, "X")
        walls_b.append(b)
    x = X0 + 0.001
    i = 0
    while x < X1 - 0.01:
        w = min(rng.uniform(0.14, 0.21), X1 - 0.001 - x)
        b = C.board(f"Ceil{i}", 2.398, w - 0.008, 0.02, sheath, rng=rng, segs=3, bevel=0.003, bow=0.006)
        C.orient(b, "Y", "X", (x + w / 2, Y0 + 0.001, ZT - 0.03 + rng.uniform(-0.008, 0.008)))
        walls_b.append(b)
        x += w
        i += 1
    # scraps on the floor, off the walking line
    for i, (sx, sy) in enumerate(((-1.95, -0.85), (-2.0, 0.3), (-0.6, 0.98), (-1.4, -0.98))):
        L = rng.uniform(0.15, 0.4)
        b = C.board(f"Scrap{i}", L, rng.uniform(0.04, 0.09), 0.02, frame, rng=rng, segs=1, bevel=0.002, end_rough=0.01)
        C.orient(b, "X", "Y", (sx, sy, 0.032))
        c_ = b.matrix_world.translation.copy()
        b.matrix_world = Matrix.Translation(c_) @ Matrix.Rotation(rng.uniform(0, 3.1), 4, "Z") @ Matrix.Translation(-c_) @ b.matrix_world
        near.append(b)

    near = C.apply_all(near)
    walls_a = C.apply_all(walls_a)
    walls_b = C.apply_all(walls_b)

    def cull(objs):
        """drop board faces turned to the black void behind (plank backs) and board tops above the ceiling"""
        for o in objs:
            nm = o.name
            if nm.startswith(("PB1_", "PB2_")):
                C.delete_faces(o, lambda c, n: n.x < -0.9)
            elif nm.startswith("PL_"):
                C.delete_faces(o, lambda c, n: n.y < -0.9)
            elif nm.startswith("PR_"):
                C.delete_faces(o, lambda c, n: n.y > 0.9)
            elif nm.startswith("Ceil"):
                C.delete_faces(o, lambda c, n: n.z > 0.9)
            elif nm.startswith("Floor"):
                C.delete_faces(o, lambda c, n: n.z < -0.9)
    cull(near + walls_a + walls_b)

    # ---- the shell: black inward-facing box closing everything, plasterboard back round the hole
    pback = paper_back_material("PaperBack")
    void = flat_material("Void", (0.006, 0.005, 0.004), 1.0, var=0.4)
    shell = []
    shell.append(grid_quad("Backing", (X0, Y0, 0), (0, Y1 - Y0, 0), (0, 0, ZT), 1, 1, (1, 0, 0), void))
    shell.append(grid_quad("BackingL", (X0, Y0, 0), (X1 - X0, 0, 0), (0, 0, ZT), 1, 1, (0, 1, 0), void))
    shell.append(grid_quad("BackingR", (X0, Y1, 0), (X1 - X0, 0, 0), (0, 0, ZT), 1, 1, (0, -1, 0), void))
    shell.append(grid_quad("BackingT", (X0, Y0, ZT), (X1 - X0, 0, 0), (0, Y1 - Y0, 0), 1, 1, (0, 0, -1), void))
    shell.append(grid_quad("FloorUnder", (X0, Y0, 0.0005), (X1 - X0, 0, 0), (0, Y1 - Y0, 0), 1, 1, (0, 0, 1), void))
    shell.append(grid_quad("FrontL", (X1, Y0, 0), (0, Y0 * -1 - HW, 0), (0, 0, ZT), 2, 6, (-1, 0, 0), pback))
    shell.append(grid_quad("FrontR", (X1, HW, 0), (0, Y1 - HW, 0), (0, 0, ZT), 2, 6, (-1, 0, 0), pback))
    shell.append(grid_quad("FrontT", (X1, -HW, HH), (0, 2 * HW, 0), (0, 0, ZT - HH), 3, 1, (-1, 0, 0), pback))
    rust = rust_material("Rust", rustiness=0.7)
    cloth = cloth_material("Cloth")
    px_, py_ = -2.2, 1.0
    shell.append(tube("Conduit", [(px_, py_, 0.0), (px_, py_, 2.5), (px_ + 0.06, py_, 2.64), (px_ + 0.5, py_, 2.66)], 0.021, rust, segs=12))
    for i, zc in enumerate((0.85, 1.95)):
        shell.append(tube(f"Coupling{i}", [(px_, py_, zc - 0.03), (px_, py_, zc + 0.03)], 0.025, rust, segs=12))
    wire = [(-0.10, -0.97, Z1)]
    for k, zz in enumerate(np.linspace(2.55, 1.30, 6)):
        wire.append((-0.10 + rng.uniform(-0.005, 0.005), -0.966 + (0.008 if k % 2 else 0.0), zz))
    wire += [(-0.095, -0.94, 1.2), (-0.09, -0.93, 1.16)]
    shell.append(tube("Wire", wire, 0.006, cloth, segs=8))
    jb = C.board("JBox", 0.11, 0.07, 0.05, rust, segs=1, bevel=0.004, jitter=0.0)
    C.orient(jb, "Z", "X", (-0.09, -0.95, 1.05))
    shell.append(jb)
    gyp = gypsum_material("Gypsum", dirty=0.6)
    dustm = flat_material("Dust", (0.16, 0.15, 0.135), 1.0, bump_scale=140.0, bump=0.5, var=0.35)
    for i in range(10):
        r = rng.uniform(0.012, 0.04)
        shell.append(lumpy(f"Crumb{i}", (rng.uniform(-0.45, -0.08), rng.uniform(-0.45, 0.45), 0.02 + r * 0.3),
                           (r * 1.3, r, r * 0.45), gyp, subdiv=1, amp=0.5, seed=i, flat_bottom=0.02))
    for i, (cx, cy, rx, ry) in enumerate(((-2.15, -0.5, 0.12, 0.55), (-2.2, 0.55, 0.1, 0.4), (-1.2, 1.0, 0.7, 0.1),
                                         (-1.0, -1.02, 0.75, 0.09), (-1.9, -0.9, 0.25, 0.2))):
        shell.append(lumpy(f"DustHeap{i}", (cx, cy, 0.02), (rx, ry, 0.025), dustm, subdiv=2, amp=0.3, freq=4.0,
                           seed=20 + i, flat_bottom=0.016))

    # ---- fibreglass bulging out between studs, torn; loose tufts
    ins = insulation_material("Fibreglass")
    fibre = []

    def batt_in(F, name, s, h, w, hgt, seed, **kw):
        u, up, n, o = F
        b = batt(name, w, hgt, kw.pop("thick", 0.09), ins, seed, **kw)
        # batt(): depth +X, width +Y, height +Z  ->  n, u, up (mirror u if that frame is left-handed)
        uu = u if n.cross(u).dot(up) > 0 else -u
        start = o + u * (s if uu is u else s + w) + up * h + n * 0.03
        m = Matrix((n, uu, up)).transposed().to_4x4()
        m.translation = start
        b.matrix_world = m
        fibre.append(b)
    batt_in(FB1, "BattA", 0.16, 1.36, 0.43, 1.3, 1, torn_bottom=0.4, sag=0.14, nu=9, nv=12)
    batt_in(FB1, "BattB", 0.66, 0.08, 0.5, 1.15, 2, torn_top=0.35, sag=0.04, nu=9, nv=11)
    batt_in(FB2, "BattC", 0.58, 1.6, 0.45, 1.05, 3, torn_bottom=0.3, sag=0.08, nu=8, nv=10)
    batt_in(FR, "BattD", 0.36, 0.1, 0.5, 1.05, 4, torn_top=0.25, sag=0.05, nu=8, nv=10)
    batt_in(FR, "BattE", 1.56, 1.45, 0.5, 1.2, 5, torn_bottom=0.45, sag=0.15, nu=8, nv=12)
    batt_in(FL, "BattF", 1.5, 0.1, 0.5, 1.25, 6, torn_top=0.3, sag=0.06, nu=8, nv=10)
    for i, (c, r, rot) in enumerate((((-2.0, -0.2, 0.05), (0.12, 0.09, 0.05), (0, 0, 0.4)),
                                     ((-1.6, 0.85, 0.04), (0.09, 0.07, 0.04), (0, 0, 1.2)),
                                     ((-0.17, -0.30, 2.39), (0.10, 0.03, 0.05), (0.2, 0.3, 0.0)),
                                     ((-0.17, 0.32, 2.37), (0.07, 0.025, 0.06), (0.0, -0.2, 0.0)),
                                     ((-0.7, -0.98, 0.035), (0.08, 0.06, 0.035), (0, 0, 2.0)),
                                     ((-2.1, 0.85, 0.04), (0.1, 0.08, 0.04), (0, 0, 0.9)))):
        fibre.append(lumpy(f"Tuft{i}", c, r, ins, subdiv=2, amp=0.55, freq=2.5, seed=40 + i, rot=rot,
                           flat_bottom=0.02 if c[2] < 0.1 else None))
    for o in fibre:
        smooth(o, 70)
    shell = C.apply_all(shell)
    fibre = C.apply_all(fibre)

    # ---- bake (AO from everything together), light on the CPU
    C.uv_unwrap(near, weights={"*": 1.0, **{o.name: 0.6 for o in near if o.name.startswith(("Floor", "Scrap"))}})
    C.uv_unwrap(walls_a)
    C.uv_unwrap(walls_b, weights={"*": 1.0, **{o.name: 0.5 for o in walls_b if o.name.startswith(("Ceil", "Joist"))}})
    C.uv_unwrap(shell, weights={"*": 1.0, "Backing": 0.05, "BackingL": 0.05, "BackingR": 0.05, "BackingT": 0.05,
                                "FloorUnder": 0.05})
    C.uv_unwrap(fibre)
    for grp, stem, size in () if "dry" in PARTS else ((near, "cavity_wood_near", 2048), (walls_a, "cavity_wood_walls_a", 1536),
                            (walls_b, "cavity_wood_walls_b", 1536), (shell, "cavity_shell", 1024),
                            (fibre, "cavity_fibreglass", 1024)):
        C.bake_atlas(grp, stem, size, ao_amount=0.8, ao_dist=0.4, samples=1, ao_samples=8)
        dens = sorted(round(C.texel_density(o, size)) for o in grp)
        print(stem, "texel px/m min/median/max", dens[0], dens[len(dens) // 2], dens[-1], flush=True)

    C.SRC_DIR.mkdir(parents=True, exist_ok=True)
    webp = C.SRC_DIR / "cavity_cobweb.png"
    cobweb_texture(webp, 1024)
    web = web_material("Cobweb", webp)
    webs = [
        web_sheet("Web0", (-2.25, -1.1, 2.72), (0.5, 0, 0), (0, 0.45, -0.2), web, sag=(0.02, 0.02, -0.06), seed=1),
        web_sheet("Web1", (-0.04, 1.12, 2.72), (-0.35, 0, 0), (0, -0.3, -0.45), web, sag=(-0.02, 0, -0.05), seed=2),
        web_sheet("Web2", (-2.3, 0.95, 0.07), (0.35, 0, 0), (0, 0, 0.42), web, sag=(0.03, -0.03, 0.0), seed=3),
        web_sheet("Web3", (-0.08, -0.475, 2.22), (0, 0.32, 0), (-0.25, 0, -0.18), web, sag=(-0.02, 0.0, -0.03), seed=4),
        web_sheet("Web4", (-1.5, -0.33, 2.72), (0.0, 0.6, 0), (0.35, 0, -0.25), web, sag=(0.0, 0.0, -0.08), seed=5),
    ]
    allm = C.apply_all(near + walls_a + walls_b + shell + fibre + webs, transforms=True)
    for o in allm:
        lo_ = [min(v.co[a] for v in o.data.vertices) for a in range(3)]
        hi_ = [max(v.co[a] for v in o.data.vertices) for a in range(3)]
        if lo_[0] < X0 - 1e-3 or hi_[0] > X1 + 1e-3 or lo_[1] < Y0 - 1e-3 or hi_[1] > Y1 + 1e-3 or lo_[2] < -1e-3 or hi_[2] > ZT + 1e-3:
            print("outside the box:", o.name, [round(c, 3) for c in lo_], [round(c, 3) for c in hi_])
    cav = C.join(allm, "Cavity")
    # keep inside the contract box
    lo = Vector([min(v.co[a] for v in cav.data.vertices) for a in range(3)])
    hi = Vector([max(v.co[a] for v in cav.data.vertices) for a in range(3)])
    print("Cavity tris", C.tri_count([cav]), "bbox", tuple(round(c, 3) for c in lo), tuple(round(c, 3) for c in hi), flush=True)
    if "dry" in PARTS:
        bpy.ops.wm.save_as_mainfile(filepath=str(C.SRC_DIR / "weak_spot_cavity_dry.blend"))
        return cav
    bpy.ops.wm.save_as_mainfile(filepath=str(C.SRC_DIR / "weak_spot_cavity.blend"))
    out = C.export_glb([cav], C.OUT_DIR / "weak_spot_cavity.glb")
    C.glb_report(out)
    return cav


# ---------------------------------------------------------------------------------------------------------------
# the rim

class MB:
    """Mesh builder: shared vertices by key, faces oriented to a wanted direction, optional per-corner UVs"""

    def __init__(self):
        self.co = []
        self.keys = {}
        self.faces = []

    def v(self, key, co):
        if key is None or key not in self.keys:
            self.co.append(Vector(co))
            if key is not None:
                self.keys[key] = len(self.co) - 1
            return len(self.co) - 1
        return self.keys[key]

    def f(self, ids, want=None, mat=0, uvs=None):
        if len(set(ids)) < 3:
            return
        if want is not None:
            n = Vector((0, 0, 0))
            for i in range(len(ids)):
                a, b = self.co[ids[i]], self.co[ids[(i + 1) % len(ids)]]
                n += Vector(((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y)))
            if n.dot(Vector(want)) < 0:
                ids = ids[::-1]
                uvs = uvs[::-1] if uvs else uvs
        self.faces.append((list(ids), mat, uvs))

    def build(self, name, mats, smooth_angle=None):
        me = bpy.data.meshes.new(name)
        used = sorted({i for f in self.faces for i in f[0]})
        remap = {o: n for n, o in enumerate(used)}
        me.from_pydata([self.co[i] for i in used], [], [[remap[i] for i in f[0]] for f in self.faces])
        for m in mats:
            me.materials.append(m)
        uvl = me.uv_layers.new(name="UVMap")
        for p, (ids, mat, uvs) in zip(me.polygons, self.faces):
            p.material_index = mat
            if uvs:
                for li, uv in zip(p.loop_indices, uvs):
                    uvl.data[li].uv = uv
        me.validate()
        ob = C.link(bpy.data.objects.new(name, me))
        if smooth_angle is not None:
            smooth(ob, smooth_angle)
        return ob


def smooth(ob, angle_deg):
    for p in ob.data.polygons:
        p.use_smooth = True
    try:
        ob.data.set_sharp_from_angle(angle=math.radians(angle_deg))
    except AttributeError:
        pass


def paper_uv(co):
    """wall_wallpaper.gdshader's projection for a point on the wall (Blender coords), as a Blender UV"""
    return ((-co[1]) / C.PAPER_W, max(co[2] / C.WALL_H, C.SKIRT_HIDE / C.WALL_H))


def face_paper_material(name):
    """Plasterboard face paper where the wallpaper tore away: ivory-grey, paste stains, shreds of olive paper"""
    m, nb = C.new_mat(name)
    pos = nb.geo("Position")
    fib = nb.noise(pos, 500.0, detail=3.0)
    paste = nb.noise(pos, 30.0, detail=4.0, rough=0.6)
    col = nb.mix(nb.mul(fib.outputs[0], 0.3), srgb(176, 170, 152), srgb(140, 132, 112))
    col = nb.mix(nb.mul(nb.mapr(paste.outputs[0], 0.45, 0.7), 0.7), col, srgb(150, 130, 85))
    shred = nb.noise(pos, 60.0, detail=5.0, rough=0.7)
    col = nb.mix(nb.mapr(shred.outputs[0], 0.62, 0.66), col, srgb(128, 128, 72))
    dirt = nb.noise(pos, 7.0, detail=4.0)
    col = nb.mix(nb.mul(nb.mapr(dirt.outputs[0], 0.4, 0.75), 0.5), col, srgb(70, 62, 50))
    h = nb.add(nb.mul(fib.outputs[0], 0.4), nb.mul(nb.mapr(shred.outputs[0], 0.62, 0.66), 0.5))
    return nb.finish(col, 0.85, nb.bump(h, 0.6, 0.0008))


def lip_back_material(name):
    """The back of torn wallpaper: off-white paper, dried paste, a little gypsum dust stuck to it"""
    m, nb = C.new_mat(name)
    pos = nb.geo("Position")
    fib = nb.noise(pos, 700.0, detail=3.0)
    paste = nb.noise(pos, 25.0, detail=4.0)
    col = nb.mix(nb.mul(fib.outputs[0], 0.3), srgb(196, 188, 165), srgb(160, 150, 128))
    col = nb.mix(nb.mul(nb.mapr(paste.outputs[0], 0.4, 0.7), 0.6), col, srgb(170, 150, 105))
    return nb.finish(col, 0.9, nb.bump(fib.outputs[0], 0.4, 0.0006))


def noise1(s, seed, freq=1.0):
    return mnoise.noise(Vector((s * freq, seed * 1.37, seed * 0.71)))       # about -0.7 .. 0.7


def build_rim():
    C.reset_scene()
    rng = random.Random(7)
    # an arched opening: big, unequal corner radii, the break ragged round it
    HW, HH = C.HOLE_W / 2, C.HOLE_H
    RL, RR = 0.40, 0.29
    sl, sr = HH - RL, HH - RR
    al, ar = math.pi / 2 * RL, math.pi / 2 * RR
    top = 2 * HW - RL - RR
    L = sl + al + top + ar + sr
    straight = sl

    def path(s):
        """point (y, z) on the arched hole outline and its outward normal; s from the floor on the left (y < 0)"""
        if s < sl:
            return Vector((-HW, s)), Vector((-1, 0))
        s -= sl
        if s < al:
            a = math.pi - s / RL
            c = Vector((-HW + RL, HH - RL))
            n = Vector((math.cos(a), math.sin(a)))
            return c + n * RL, n
        s -= al
        if s < top:
            return Vector((-HW + RL + s, HH)), Vector((0, 1))
        s -= top
        if s < ar:
            a = math.pi / 2 - s / RR
            c = Vector((HW - RR, HH - RR))
            n = Vector((math.cos(a), math.sin(a)))
            return c + n * RR, n
        s -= ar
        return Vector((HW, HH - RR - s)), Vector((1, 0))

    def in_corner(s):
        return sl - 0.06 < s < sl + al + 0.06 or L - sr - ar - 0.06 < s < L - sr + 0.06

    def delta(p):
        """how far inside the cut rectangle the point (y, z) is (negative outside)"""
        return min(HW - abs(p.x), HH - p.y)

    # columns along the outline; break line is piecewise straight between random breakpoints (gypsum snaps)
    N = 125
    ss = [L * i / N for i in range(N + 1)]
    bps = [0.0]
    while bps[-1] < L:
        bps.append(bps[-1] + rng.uniform(0.03, 0.10))
    bvals = []
    for b in bps:
        base = 0.04 + 0.025 * noise1(b, 1, 2.0)
        v = base + rng.uniform(-0.03, 0.03)
        if rng.random() < 0.15:
            v += rng.uniform(0.03, 0.06)            # a tooth of board sticking into the hole
        bvals.append(min(max(v, 0.012), 0.105))
    # make every breakpoint a column too: merge and sort
    ss = sorted(set([round(s, 5) for s in ss] + [round(b, 5) for b in bps if b < L]))
    ss = [s for i, s in enumerate(ss) if i == 0 or s - ss[i - 1] > 0.006]
    if ss[-1] < L - 1e-4:
        ss.append(L)

    def d_in(s):
        for i in range(len(bps) - 1):
            if bps[i] <= s <= bps[i + 1]:
                t = (s - bps[i]) / (bps[i + 1] - bps[i])
                return bvals[i] * (1 - t) + bvals[i + 1] * t
        return bvals[-1]

    cols = []
    for k, s in enumerate(ss):
        p, n = path(s)
        din = d_in(s) + rng.uniform(-0.002, 0.002)
        if in_corner(s):
            din *= 0.6                               # the arch is already inside the corner
        # the break must stay inside the cut rectangle (by >= 1 cm), or the cut wall would show
        while s not in (ss[0], ss[-1]) and delta(p - n * din) < 0.01:
            din += 0.002
        wt = 0.006 + 0.04 * max(0.0, noise1(s, 2, 3.0) + 0.3) + rng.uniform(0, 0.004)
        out = 0.06 + 0.12 * (noise1(s, 3, 1.4) + 0.7) / 1.4 + rng.uniform(-0.008, 0.008)
        while s not in (ss[0], ss[-1]) and delta(p + n * out) > -0.03:
            out += 0.005
        push = max(0.0, 0.018 * (noise1(s, 4, 1.8) + 0.25)) + rng.uniform(0, 0.004)
        slant = 0.006 * noise1(s, 5, 6.0) + rng.uniform(-0.004, 0.004)
        curl = max(0.002, 0.03 * (noise1(s, 6, 2.5) + 0.2))
        over = 0.03 * max(0.0, noise1(s, 7, 3.5) + 0.1) + rng.uniform(-0.004, 0.004)
        r0 = -din
        r1 = r0 + wt
        r2 = max(r1 + 0.012, min(r1 + 0.04, 0.0))
        r3 = max(r2 + 0.01, 0.015)
        r4 = max(r3 + 0.02, out)
        # bottom ends: flatten onto the floor
        if s == ss[0] or s == ss[-1]:
            n = Vector((-1, 0)) if s == ss[0] else Vector((1, 0))
        cols.append(dict(p=p, n=n, r=(r0, r1, r2, r3, r4), push=push, slant=slant, curl=curl, over=over, s=s))

    def pt(c, r):
        q = c["p"] + c["n"] * r
        if c["s"] == ss[0] or c["s"] == ss[-1]:
            q.y = 0.0
        return q

    def xf(c, q):
        """front surface x at (y, z): flush outside the cut, pushed in toward the break"""
        d = delta(q)
        t = min(max(d / 0.07, 0.0), 1.0)
        t = t * t * (3 - 2 * t)
        return 0.002 - c["push"] * t

    TH = 0.025
    paper, broken, backm = MB(), MB(), MB()
    nc = len(cols)
    for k in range(nc):
        c = cols[k]
        r0, r1, r2, r3, r4 = c["r"]
        P = [pt(c, r) for r in (r0, r1, r2, r3, r4)]
        c["front"] = [Vector((xf(c, q), q.x, q.y)) for q in P]
        # broken edge: front corner, a crumbly middle, the back corner (slanted)
        qm = pt(c, r0 + c["slant"] * 0.5 + rng.uniform(-0.005, 0.005))
        qb = pt(c, r0 + c["slant"])
        c["edge"] = [c["front"][0],
                     Vector((xf(c, qm) - TH * 0.5 + rng.uniform(-0.003, 0.003), qm.x, qm.y)),
                     Vector((xf(c, qb) - TH, qb.x, qb.y))]
        c["back"] = [c["edge"][2]] + [Vector((f.x - TH, f.y, f.z)) for f in c["front"][2:]]
        # wallpaper lip from the tear line inward, curling out
        Lp = (r1 - r0) + c["over"] + rng.uniform(-0.004, 0.004)
        Lp = max(Lp, 0.004)
        lip = []
        for t in (0.0, 0.5, 1.0):
            q = pt(c, r1 - Lp * t)
            x = c["front"][1].x + 0.0007 + c["curl"] * t * t
            lip.append(Vector((x, q.x, q.y)))
        c["lip"] = lip
    for k in range(nc - 1):
        a, b = cols[k], cols[k + 1]
        # wallpaper: tear line to the outer edge
        for j in range(1, 4):
            ids = [paper.v(("f", k, j), a["front"][j]), paper.v(("f", k + 1, j), b["front"][j]),
                   paper.v(("f", k + 1, j + 1), b["front"][j + 1]), paper.v(("f", k, j + 1), a["front"][j + 1])]
            uvs = [paper_uv(paper.co[i]) for i in ids]
            paper.f(ids, (1, 0, 0), 0, uvs)
        # lip front (wallpaper) and back
        for j in range(2):
            ids = [paper.v(("l", k, j), a["lip"][j]), paper.v(("l", k + 1, j), b["lip"][j]),
                   paper.v(("l", k + 1, j + 1), b["lip"][j + 1]), paper.v(("l", k, j + 1), a["lip"][j + 1])]
            paper.f(ids, (1, 0, 0), 0, [paper_uv(paper.co[i]) for i in ids])
            back = lambda v: Vector((v.x - 0.0006, v.y, v.z))
            ids = [broken.v(("lb", k, j), back(a["lip"][j])), broken.v(("lb", k + 1, j), back(b["lip"][j])),
                   broken.v(("lb", k + 1, j + 1), back(b["lip"][j + 1])), broken.v(("lb", k, j + 1), back(a["lip"][j + 1]))]
            broken.f(ids, (-1, 0, 0), 2)
        # exposed face paper between the break and the tear
        ids = [broken.v(("f", k, 0), a["front"][0]), broken.v(("f", k + 1, 0), b["front"][0]),
               broken.v(("f", k + 1, 1), b["front"][1]), broken.v(("f", k, 1), a["front"][1])]
        broken.f(ids, (1, 0, 0), 0)
        # the broken gypsum edge, facing into the hole
        cen = Vector((0, 0, 1.0))
        for j in range(2):
            ids = [broken.v(("e", k, j), a["edge"][j]), broken.v(("e", k + 1, j), b["edge"][j]),
                   broken.v(("e", k + 1, j + 1), b["edge"][j + 1]), broken.v(("e", k, j + 1), a["edge"][j + 1])]
            inward = -Vector((0, a["n"].x, a["n"].y))
            broken.f(ids, inward, 1)
        # back paper
        for j in range(3):
            ids = [backm.v(("b", k, j), a["back"][j]), backm.v(("b", k + 1, j), b["back"][j]),
                   backm.v(("b", k + 1, j + 1), b["back"][j + 1]), backm.v(("b", k, j + 1), a["back"][j + 1])]
            backm.f(ids, (-1, 0, 0), 0)

    # hanging shards: pieces of board still held by the wallpaper, dangling into the hole
    shard_paper, shard_broken = MB(), MB()
    shard_specs = [(-0.02, 0.12, 0.10, "top"), (0.13, 0.11, 0.08, "top"), (0.85, 0.12, 0.09, "left"),
                   (1.35, 0.10, 0.08, "right")]
    for si, (pos, w, h, side) in enumerate(shard_specs):
        srng = random.Random(100 + si)
        # outline in the wall plane, (along, down from the hinge) coordinates
        n = 7
        outline = [(0.0, 0.0), (w, 0.0)]
        for i in range(n):
            t = 1 - i / (n - 1)
            outline.append((w * t + srng.uniform(-0.01, 0.01), -h * (0.35 + 0.65 * math.sin(math.pi * (0.15 + 0.7 * t))) * srng.uniform(0.75, 1.15)))
        if side == "top":
            cc = min((c for c in cols if c["p"].y > HH - 0.45), key=lambda c: abs(pt(c, c["r"][0]).x - pos))
            hinge_z = pt(cc, cc["r"][0]).y - 0.004
            to_world = lambda u, v, x: Vector((x, pos + u - w / 2, hinge_z + v))
            axis, pivot = Vector((0, 1, 0)), Vector((0.0, 0, hinge_z))
            ang = math.radians(srng.uniform(10, 15))
        else:
            sgn = -1 if side == "left" else 1
            cc = min((c for c in cols if c["p"].x * sgn > HW - 0.01 and c["p"].y < HH - 0.45),
                     key=lambda c: abs(pt(c, c["r"][0]).y - pos))
            hinge_y = pt(cc, cc["r"][0]).x - sgn * 0.004
            to_world = lambda u, v, x, sgn=sgn, hinge_y=hinge_y: Vector((x, hinge_y + v * sgn, pos + u - w / 2))
            axis, pivot = Vector((0, 0, 1)), Vector((0.0, hinge_y, 0))
            ang = -sgn * math.radians(srng.uniform(10, 16))
        rot = Matrix.Translation(pivot) @ Matrix.Rotation(ang, 4, axis) @ Matrix.Translation(-pivot)
        fr = [to_world(u, v, 0.002) for u, v in outline]
        bk = [to_world(u, v, 0.002 - TH) for u, v in outline]
        uvs = [paper_uv(p) for p in fr]
        frw = [rot @ p for p in fr]
        bkw = [rot @ p for p in bk]
        normal_front = (rot.to_3x3() @ Vector((1, 0, 0)))
        ids = [shard_paper.v(None, p) for p in frw]
        shard_paper.f(ids, normal_front, 0, uvs)
        ids = [shard_broken.v(None, p) for p in bkw]
        shard_broken.f(ids, -normal_front, 0)
        cen = sum(frw, Vector()) / len(frw)
        m = len(frw)
        for i in range(m):
            j = (i + 1) % m
            ids = [shard_broken.v(None, frw[i]), shard_broken.v(None, frw[j]), shard_broken.v(None, bkw[j]), shard_broken.v(None, bkw[i])]
            mid = (frw[i] + frw[j]) / 2
            shard_broken.f(ids, mid - cen, 1)

    wall = C.wallpaper_material("Wallpaper")
    fpm = face_paper_material("FacePaper")
    gyp = gypsum_material("GypsumCore", dirty=0.3)
    lbm = lip_back_material("LipBack")
    bpm = paper_back_material("BackPaper", stains=0.6, dust=0.3)
    o_paper = paper.build("RimPaper", [wall], smooth_angle=35)
    o_broken = broken.build("RimBroken", [fpm, gyp, lbm], smooth_angle=30)
    o_back = backm.build("RimBack", [bpm], smooth_angle=35)
    o_sp = shard_paper.build("ShardPaper", [wall])
    o_sb = shard_broken.build("ShardBroken", [bpm, gyp])
    bake = [o_broken, o_back, o_sb]
    C.uv_unwrap(bake, weights={"*": 1.0, "RimBack": 0.45}, angle=60.0)
    C.bake_atlas(bake, "rim_broken", 1024, ao_amount=0.6, ao_dist=0.05)
    for o in bake:
        print(o.name, "px/m", round(C.texel_density(o, 1024)))
    rim = C.join(C.apply_all([o_paper, o_broken, o_back, o_sp, o_sb], transforms=True), "Rim")
    print("Rim tris", C.tri_count([rim]))
    # coverage check: every point of the cut rectangle's border (3 sides) must be under the rim band
    me = rim.data
    bm = bmesh.new()
    bm.from_mesh(me)
    import mathutils.bvhtree as bvh
    tree = bvh.BVHTree.FromBMesh(bm)
    miss = []
    for i in range(400):
        t = i / 399
        per = 2 * HH + 2 * HW
        d = t * per
        if d < HH:
            y, z = -HW, d
        elif d < HH + 2 * HW:
            y, z = -HW + (d - HH), HH
        else:
            y, z = HW, HH - (d - HH - 2 * HW)
        for dy, dz in ((0, 0), (0.003, 0), (-0.003, 0), (0, 0.003), (0, -0.003)):
            hit = tree.ray_cast(Vector((0.5, y + dy, max(z + dz, 0.0005))), Vector((-1, 0, 0)), 1.0)
            if hit[0] is None:
                miss.append((round(y + dy, 3), round(z + dz, 3)))
    bm.free()
    print("rim coverage misses:", len(miss), miss[:10])
    bpy.ops.wm.save_as_mainfile(filepath=str(C.SRC_DIR / "weak_spot_rim.blend"))
    out = C.export_glb([rim], C.OUT_DIR / "weak_spot_rim.glb")
    C.glb_report(out)


# ---------------------------------------------------------------------------------------------------------------
# debris

def build_debris():
    C.reset_scene()
    rng = random.Random(21)
    wall = C.wallpaper_material("Wallpaper")
    gyp = gypsum_material("GypsumCore", dirty=0.3)
    bpm = paper_back_material("BackPaper", stains=0.5, dust=0.3)
    lbm = lip_back_material("LipBack")
    frame = wood_material("WoodFrame", tone=0.2, grey=0.4, dust=0.3, damp=0.2)
    TH = 0.025
    pieces = []          # (paper object or None, broken object)
    places = [(0.18, -0.12), (0.32, 0.22), (0.55, -0.35), (0.26, 0.5), (0.72, 0.08), (0.95, -0.55),
              (0.12, 0.33), (0.45, -0.6), (1.15, 0.3), (0.62, 0.48), (0.4, 0.0), (0.85, -0.15)]
    kinds = ["chunk", "chunk", "chunk", "chunk", "chunk", "chunk", "crumb", "crumb", "crumb", "splinter", "splinter", "scrap"]
    for i, (kind, (px, py)) in enumerate(zip(kinds, places)):
        prng = random.Random(300 + i)
        src = Vector((0.0, prng.uniform(-0.4, 0.4), prng.uniform(0.3, 2.0)))       # where it was in the wall
        yaw = prng.uniform(0, 2 * math.pi)
        if kind == "chunk":
            size = [0.2, 0.15, 0.11, 0.09, 0.13, 0.07][i]
            n = prng.randint(6, 9)
            outline = []
            for k in range(n):
                a = 2 * math.pi * (k + prng.uniform(-0.25, 0.25)) / n
                r = size * 0.5 * prng.uniform(0.6, 1.1)
                outline.append((math.cos(a) * r, math.sin(a) * r * prng.uniform(0.55, 0.9)))
            flip = (i == 4)
            pm, bm_ = MB(), MB()
            top = [Vector((u, v, TH / 2 + prng.uniform(-0.0015, 0.0015))) for u, v in outline]
            bot = [Vector((u + prng.uniform(-0.005, 0.005), v + prng.uniform(-0.005, 0.005), -TH / 2)) for u, v in outline]
            uvs = [paper_uv(Vector((0, src.y + u, src.z + v))) for u, v in outline]
            tgt_top, tgt_bot = (bm_, pm) if flip else (pm, bm_)
            ids = [pm.v(None, p) for p in top]
            pm.f(ids, (0, 0, 1), 0, uvs)
            ids = [bm_.v(None, p) for p in bot]
            bm_.f(ids, (0, 0, -1), 0)
            # crumbly edge: a middle ring pushed in or out
            mid = [Vector((u * prng.uniform(0.9, 1.05), v * prng.uniform(0.9, 1.05), prng.uniform(-0.004, 0.004))) for u, v in outline]
            for k in range(n):
                j = (k + 1) % n
                for ring_a, ring_b in ((top, mid), (mid, bot)):
                    ids = [bm_.v(None, ring_a[k]), bm_.v(None, ring_a[j]), bm_.v(None, ring_b[j]), bm_.v(None, ring_b[k])]
                    c = (ring_a[k] + ring_a[j]) / 2
                    bm_.f(ids, Vector((c.x, c.y, 0)), 1)
            po = pm.build(f"P{i}", [wall])
            bo = bm_.build(f"B{i}", [bpm, gyp])
            tilt = Euler((prng.uniform(-0.12, 0.12) + (math.pi if flip else 0.0), prng.uniform(-0.12, 0.12), yaw))
            for o in (po, bo):
                o.matrix_world = tilt.to_matrix().to_4x4()
            pieces.append(([po, bo], (px, py)))
        elif kind == "crumb":
            r = prng.uniform(0.015, 0.03)
            o = lumpy(f"B{i}", (0, 0, 0), (r * 1.4, r, r * 0.6), gyp, subdiv=2, amp=0.45, seed=60 + i, rot=(0, 0, yaw))
            smooth(o, 40)
            pieces.append(([o], (px, py)))
        elif kind == "splinter":
            L = prng.uniform(0.16, 0.3)
            o = C.board(f"B{i}", L, prng.uniform(0.018, 0.03), prng.uniform(0.006, 0.01), frame, segs=4,
                        bevel=0.0015, rng=prng, twist=0.15)
            # taper both ends to ragged points
            for v in o.data.vertices:
                t = v.co.x / L
                k = min(1.0, min(t, 1 - t) / 0.3)
                v.co.y *= 0.25 + 0.75 * k
                v.co.z *= 0.5 + 0.5 * k
            o.matrix_world = Matrix.Translation((-L / 2, 0, 0))
            o.matrix_world = Matrix.Rotation(yaw, 4, "Z") @ o.matrix_world
            pieces.append(([o], (px, py)))
        else:                                    # a torn, curled scrap of wallpaper
            pm, bm_ = MB(), MB()
            nu, nv = 5, 3
            W, H = 0.14, 0.09
            grid = {}
            for a_ in range(nu + 1):
                for b_ in range(nv + 1):
                    u, v = (a_ / nu - 0.5) * W, (b_ / nv - 0.5) * H
                    edge = 0.012 * prng.uniform(-1, 1) if a_ in (0, nu) or b_ in (0, nv) else 0.0
                    curl = 0.6 * (u / W + 0.5) ** 2 * W
                    grid[(a_, b_)] = (Vector((u + edge, v + edge, curl * 0.5)), (u, v))
            for a_ in range(nu):
                for b_ in range(nv):
                    q = [(a_, b_), (a_ + 1, b_), (a_ + 1, b_ + 1), (a_, b_ + 1)]
                    ids = [pm.v(k, grid[k][0]) for k in q]
                    pm.f(ids, (0, 0, 1), 0, [paper_uv(Vector((0, src.y + grid[k][1][0], src.z + grid[k][1][1]))) for k in q])
                    ids = [bm_.v(k, grid[k][0] - Vector((0, 0, 0.0006))) for k in q]
                    bm_.f(ids, (0, 0, -1), 0)
            po = pm.build(f"P{i}", [wall], smooth_angle=60)
            bo = bm_.build(f"B{i}", [lbm], smooth_angle=60)
            for o in (po, bo):
                o.matrix_world = Matrix.Rotation(yaw, 4, "Z")
            pieces.append(([po, bo], (px, py)))
    # bake every non-wallpaper part into one atlas
    names = [([o.name for o in objs], p) for objs, p in pieces]
    bake = C.apply_all([o for objs, _ in pieces for o in objs if o.name.startswith("B")])
    pieces = [([bpy.data.objects[n] for n in ns], p) for ns, p in names]
    # lay each piece out first (AO between pieces and the floor), then bake
    floor = grid_quad("BakeFloor", (-1, -1.5, 0), (3, 0, 0), (0, 3, 0), 1, 1, (0, 0, 1), flat_material("F", (0.1, 0.1, 0.1)))
    for objs, (px, py) in pieces:
        lo = min((o.matrix_world @ v.co).z for o in objs for v in o.data.vertices)
        for o in objs:
            o.matrix_world = Matrix.Translation((px, py, -lo)) @ o.matrix_world
    C.uv_unwrap(bake)
    C.bake_atlas(bake, "debris", 1024, ao_amount=0.5, ao_dist=0.05)
    bpy.data.objects.remove(floor)
    out = []
    for i, (objs, _) in enumerate(pieces):
        objs = C.apply_all(objs, transforms=True)
        o = C.join(objs, f"Debris_{i}") if len(objs) > 1 else objs[0]
        o.name = o.data.name = f"Debris_{i}"
        lo = Vector([min(v.co[a] for v in o.data.vertices) for a in range(3)])
        hi = Vector([max(v.co[a] for v in o.data.vertices) for a in range(3)])
        c = (lo + hi) / 2
        o.data.transform(Matrix.Translation(-c))
        o.location = c
        out.append(o)
    print("Debris tris", C.tri_count(out))
    bpy.ops.wm.save_as_mainfile(filepath=str(C.SRC_DIR / "weak_spot_debris.blend"))
    path = C.export_glb(out, C.OUT_DIR / "weak_spot_debris.glb")
    C.glb_report(path)


# ---------------------------------------------------------------------------------------------------------------
# preview: the exported files in a bit of Level 0

def preview():
    C.reset_scene()
    for f in ("weak_spot_cavity.glb", "weak_spot_rim.glb", "weak_spot_debris.glb"):
        p = C.OUT_DIR / f
        if p.exists():
            bpy.ops.import_scene.gltf(filepath=str(p))
    # the wall: x = 0 face with the cut rectangle, wallpaper in the game's projection; carpet; ceiling
    wall = C.wallpaper_material("WallPreview")
    HW, HH = C.HOLE_W / 2, C.HOLE_H
    mb = MB()
    Y0, Y1, ZT = -4.0, 4.0, C.WALL_H
    for (a, b, c, d) in (((Y0, 0), (-HW, 0), (-HW, ZT), (Y0, ZT)), ((HW, 0), (Y1, 0), (Y1, ZT), (HW, ZT)),
                         ((-HW, HH), (HW, HH), (HW, ZT), (-HW, ZT))):
        pts = [Vector((0, p[0], p[1])) for p in (a, b, c, d)]
        ids = [mb.v(None, p) for p in pts]
        mb.f(ids, (1, 0, 0), 0, [paper_uv(p) for p in pts])
    # wall thickness behind (the cut's sides), so the hole reads as a hole in a thick wall
    for (y,) in ((-HW,), (HW,)):
        pts = [Vector((0, y, 0)), Vector((-0.03, y, 0)), Vector((-0.03, y, HH)), Vector((0, y, HH))]
        mb.f([mb.v(None, p) for p in pts], (0, -math.copysign(1, y), 0), 0, [paper_uv(p) for p in pts])
    mb.build("Wall", [wall])
    m, nb = C.new_mat("Carpet")
    uv = nb.vscale(nb.geo("Position"), (1 / 1.2, 1 / 1.2, 1))
    t = nb.image(C.CARPET, "sRGB", uv)
    nb.finish(t.outputs[0], 0.95)
    grid_quad("Floor", (0, -4, 0), (8, 0, 0), (0, 8, 0), 1, 1, (0, 0, 1), m)
    grid_quad("CeilingP", (0, -4, C.WALL_H), (8, 0, 0), (0, 8, 0), 1, 1, (0, 0, -1), flat_material("CeilP", (0.5, 0.48, 0.4)))
    grid_quad("WallBack", (6, -4, 0), (0, 8, 0), (0, 0, C.WALL_H), 1, 1, (-1, 0, 0), wall)
    sc, cam = C.preview_setup("EEVEE", (1280, 720))       # EEVEE: light on the CPU
    try:
        sc.eevee.taa_render_samples = 32
        sc.eevee.use_raytracing = True
        sc.eevee.use_shadows = True
    except AttributeError:
        pass
    for i, (lx, ly) in enumerate(((2.2, -1.2), (2.2, 1.6), (4.6, 0.0))):
        lo = C.area_light(f"Panel{i}", (lx, ly, C.WALL_H - 0.02), (lx, ly, 0), 380, 0.9, color=(1.0, 0.96, 0.82))
        lo.data.shape = "RECTANGLE"
        lo.data.size_y = 0.45
    os.makedirs(PREVIEW, exist_ok=True)
    shots = [
        ("outside_front", (2.0, 0.0, 1.6), (0.0, 0.0, 1.15), 28),
        ("outside_three_quarter", (1.7, -1.3, 1.6), (0.0, 0.0, 1.1), 28),
        ("inside_looking_out", (-0.55, 0.0, 1.6), (1.0, 0.0, 1.25), 24),
        ("inside_looking_back", (-0.15, 0.32, 1.55), (-0.95, -0.3, 1.05), 22),
        ("inside_up", (-0.5, 0.0, 1.55), (-0.2, 0.0, 2.7), 20),
        ("rim_closeup", (0.65, 0.45, 2.05), (0.0, -0.25, 1.8), 30),
        ("debris_closeup", (1.45, -0.55, 0.75), (0.5, 0.0, 0.0), 32),
    ]
    only = [a for a in ARGS[1:] if a.startswith("shot=")]
    want = {a[5:] for a in only}
    for name, loc, tgt, lens in shots:
        if want and name not in want:
            continue
        C.shoot(cam, loc, tgt, os.path.join(PREVIEW, f"{name}.png"), lens=lens)


if __name__ == "__main__":
    if "woodtest" in PARTS:
        woodtest()
    if "cavity" in PARTS:
        build_cavity()
    if "rim" in PARTS:
        build_rim()
    if "debris" in PARTS:
        build_debris()
    if "preview" in PARTS or any(a.startswith("shot=") for a in ARGS[1:]):
        preview()
