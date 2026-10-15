"""The emergency launch panel retextured for T.S.R.A., and the text its little screen shows.

    python tools/make_tsra_branding.py

Uses the agency emblem the field terminal shows (godot-backrooms/textures/ui/tsra_logo.png, drawn by
godot-backrooms/tools/gen_tsra_logo.py: two crystal shards split down the middle, ringed by an orbit).

Writes
  godot-backrooms/textures/tsra/tsra_screen_status.png  the screen's text lines, one per row (white, tinted in the shader)
  godot-backrooms/models/props/tsra/tsra_emergency_panel.glb  the Sketchfab emergency lever panel with "ONLY USE IN AN
      EMERGENCY" painted out for "T.S.R.A." and the Helix screen replaced by the emblem (the in-game screen animation is
      shaders/tsra_panel_screen.gdshader, drawn over that rectangle)
"""
import json
import struct
from io import BytesIO
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / "godot-backrooms"
EMBLEM = GAME / "textures" / "ui" / "tsra_logo.png"
TEX_OUT = GAME / "textures" / "tsra"
PANEL_IN = ROOT / "asetsuimprot" / "tsraroom" / "emergency_panel_with_lever(to edit texwture).glb"
PANEL_OUT = GAME / "models" / "props" / "tsra" / "tsra_emergency_panel.glb"

AMBER = (240, 168, 56)                       # terminal_machine.gd AMBER
FONT = "C:/Windows/Fonts/bahnschrift.ttf"
FONT_FALLBACK = "C:/Windows/Fonts/arialbd.ttf"

# Screen text rows, in the order of tsra_panel_screen.gdshader's `state` (the last row is the wordmark)
STATUS = ["STANDBY", "PULL LEVER", "CHARGING", "OPEN", "T.S.R.A."]
STATUS_W, STATUS_ROW_H = 512, 96

# Panel atlas (1024 px, stored upside down: the model reads it flipped vertically)
TEXT_BOX = (790, 750, 952, 768)              # "ONLY USE IN AN EMERGENCY", x0 y0 x1 y1
SCREEN_SEARCH = (420, 768, 560, 845)         # the blue screen sits inside this


def font(size, bold=True):
    try:
        f = ImageFont.truetype(FONT, size)
        try:
            f.set_variation_by_name("Bold" if bold else "SemiBold")
        except Exception:
            pass
        return f
    except OSError:
        return ImageFont.truetype(FONT_FALLBACK, size)


def spaced_text(draw, cx, y, text, f, spacing, fill, left=None):
    """Text centred on cx (or starting at `left`) with extra tracking between letters"""
    widths = [draw.textlength(ch, font=f) for ch in text]
    total = sum(widths) + spacing * (len(text) - 1)
    x = left if left is not None else cx - total / 2
    for ch, w in zip(text, widths):
        draw.text((x, y), ch, font=f, fill=fill)
        x += w + spacing


def draw_status():
    """The screen's text, one line per row, left-aligned, white on transparent"""
    ss = 4
    img = Image.new("L", (STATUS_W * ss, STATUS_ROW_H * len(STATUS) * ss), 0)
    d = ImageDraw.Draw(img)
    for i, t in enumerate(STATUS):
        size = 0.78 if t == "T.S.R.A." else 0.62
        spaced_text(d, 0, (i * STATUS_ROW_H + STATUS_ROW_H * (0.5 - size * 0.62)) * ss, t,
                    font(int(STATUS_ROW_H * size) * ss), 6 * ss, 255, left=4 * ss)
    mask = img.resize((STATUS_W, STATUS_ROW_H * len(STATUS)), Image.LANCZOS)
    out = Image.new("RGBA", mask.size, (255, 255, 255, 0))
    out.putalpha(mask)
    return out


# ------------------------------------------------------------------------------------------------ the panel
def read_glb(path):
    b = path.read_bytes()
    jl = struct.unpack("<I", b[12:16])[0]
    doc = json.loads(b[20:20 + jl])
    bl = struct.unpack("<I", b[20 + jl:24 + jl])[0]
    return doc, b[28 + jl:28 + jl + bl]


def write_glb(path, doc, blob):
    js = json.dumps(doc, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    blob += b"\0" * (-len(blob) % 4)
    out = struct.pack("<III", 0x46546C67, 2, 28 + len(js) + len(blob))
    out += struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(blob), 0x004E4942) + blob
    path.write_bytes(out)


def image_of(doc, blob, idx):
    v = doc["bufferViews"][doc["images"][idx]["bufferView"]]
    o = v.get("byteOffset", 0)
    return Image.open(BytesIO(blob[o:o + v["byteLength"]]))


def replace_images(doc, blob, new):
    """new: {image index: PNG bytes}. Rebuilds the buffer with every view kept in order"""
    out = bytearray()
    for i, v in enumerate(doc["bufferViews"]):
        img = next((k for k, im in enumerate(doc["images"]) if im.get("bufferView") == i), None)
        o = v.get("byteOffset", 0)
        data = new[img] if img in new else blob[o:o + v["byteLength"]]
        out += b"\0" * (-len(out) % 4)
        v["byteOffset"] = len(out)
        v["byteLength"] = len(data)
        out += data
    doc["buffers"][0]["byteLength"] = len(out)
    doc["buffers"][0].pop("uri", None)
    return bytes(out)


def png(img):
    bio = BytesIO()
    img.save(bio, "PNG", optimize=True)
    return bio.getvalue()


def screen_rect(a):
    """The blue LCD inside SCREEN_SEARCH (rows / columns that are mostly blue) and its 1 px rim"""
    x0, y0, x1, y1 = SCREEN_SEARCH
    sub = a[y0:y1, x0:x1].astype(int)
    blue = (sub[..., 2] > 90) & (sub[..., 2] > sub[..., 0] + 40)
    cols = np.where(blue.mean(0) > 0.5)[0]
    rows = np.where(blue.mean(1) > 0.5)[0]
    return x0 + cols[0] - 1, y0 + rows[0] - 1, x0 + cols[-1] + 2, y0 + rows[-1] + 2


def fill_masked(a, mask, iters=60):
    """Paint masked pixels out by diffusing their unmasked neighbours in"""
    out = a.astype(np.float32)
    known = ~mask
    for _ in range(iters):
        acc = np.zeros_like(out)
        cnt = np.zeros(mask.shape, np.float32)
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0), (0, 2), (0, -2)):
            sh = np.roll(np.roll(out, dy, 0), dx, 1)
            k = np.roll(np.roll(known, dy, 0), dx, 1)
            acc += sh * k[..., None]
            cnt += k
        fill = mask & ~known & (cnt > 0)
        out[fill] = acc[fill] / cnt[fill][:, None]
        known = known | fill
    return out


def lcd_still(sw, sh):
    """The screen at rest, upright: the emblem on the left, the wordmark beside it (the shader's layout)"""
    ss = 4
    W, H = sw * ss, sh * ss
    lcd = Image.new("RGB", (W, H), (10, 12, 14))
    emb = Image.open(EMBLEM).convert("RGBA")
    e = int(H * 0.84)
    emb = emb.resize((e, e), Image.NEAREST)
    lcd.paste(emb, (int(W * 0.05), (H - e) // 2), emb)
    d = ImageDraw.Draw(lcd)
    spaced_text(d, 0, H * 0.30, "T.S.R.A.", font(int(H * 0.2)), 2 * ss, AMBER, left=int(W * 0.52))
    spaced_text(d, 0, H * 0.56, "STANDBY", font(int(H * 0.14)), 2 * ss, (150, 104, 34), left=int(W * 0.52))
    return lcd.resize((sw, sh), Image.LANCZOS)


def retexture_panel():
    doc, blob = read_glb(PANEL_IN)
    mat = doc["materials"][0]
    base_i = doc["textures"][mat["pbrMetallicRoughness"]["baseColorTexture"]["index"]]["source"]
    emit_i = doc["textures"][mat["emissiveTexture"]["index"]]["source"]
    base = np.array(image_of(doc, blob, base_i).convert("RGB"))
    emit = np.array(image_of(doc, blob, emit_i).convert("RGB"))

    # -- "ONLY USE IN AN EMERGENCY" -> "T.S.R.A."
    x0, y0, x1, y1 = TEXT_BOX
    region = base[y0:y1, x0:x1].astype(int)
    red = (region[..., 0] > 110) & (region[..., 0] > region[..., 1] + 45)
    strong = red & (region[..., 0] > region[..., 1] + 90)          # the letters' cores, not their soft edges
    ink = tuple(int(c) for c in np.median(region[strong], 0)) if strong.any() else (170, 30, 25)
    m = np.zeros(base.shape[:2], bool)
    m[y0:y1, x0:x1] = red
    m = np.array(Image.fromarray(m.astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(5))) > 0
    filled = fill_masked(base, m)
    grain = np.random.default_rng(7).normal(0, 6, base.shape).astype(np.float32)
    base = np.where(m[..., None], np.clip(filled + grain, 0, 255), base).astype(np.uint8)

    ss = 8
    w, h = x1 - x0, y1 - y0
    lab = Image.new("L", (w * ss, h * ss), 0)
    spaced_text(ImageDraw.Draw(lab), w * ss / 2, -h * ss * 0.06, "T.S.R.A.", font(int(h * ss * 0.86)), 5 * ss, 255)
    lab = lab.resize((w, h), Image.LANCZOS).transpose(Image.FLIP_TOP_BOTTOM)
    al = np.clip(np.array(lab, np.float32)[..., None] / 255.0 * 1.25, 0, 1)
    patch = base[y0:y1, x0:x1].astype(np.float32)
    base[y0:y1, x0:x1] = (patch * (1 - al) + np.array(ink, np.float32) * al).astype(np.uint8)

    # -- the Helix screen -> the emblem on a dark LCD (the still look; the shader animates over it)
    sx0, sy0, sx1, sy1 = screen_rect(base)
    lcd = lcd_still(sx1 - sx0, sy1 - sy0).transpose(Image.FLIP_TOP_BOTTOM)
    base[sy0:sy1, sx0:sx1] = np.array(lcd)
    emit[sy0:sy1, sx0:sx1] = (np.array(lcd, np.float32) * 0.8).astype(np.uint8)   # the LCD lights itself

    blob = replace_images(doc, blob, {base_i: png(Image.fromarray(base)), emit_i: png(Image.fromarray(emit))})
    PANEL_OUT.parent.mkdir(parents=True, exist_ok=True)
    write_glb(PANEL_OUT, doc, blob)
    return sx0, sy0, sx1, sy1


def main():
    TEX_OUT.mkdir(parents=True, exist_ok=True)
    draw_status().save(TEX_OUT / "tsra_screen_status.png")
    rect = retexture_panel()
    print("screen rect (atlas px):", rect, " uv:", tuple(round(v / 1024, 5) for v in rect))


if __name__ == "__main__":
    main()
