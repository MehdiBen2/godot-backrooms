"""
Generates a realistic camera lens dirt texture (textures/lens_dirt.png):
- Circular out-of-focus dust specks & bokeh dust motes
- Glass wipe smudges & grease smears
- Water droplet dry-rings & micro-scratches
"""
import math
import random
import os
from PIL import Image, ImageDraw, ImageFilter

def generate_lens_dirt(out_path="textures/lens_dirt.png", size=1024):
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    random.seed(42)

    w = h = size
    base = Image.new('L', (w, h), 0)
    draw = ImageDraw.Draw(base)

    # 1. Subtle grease smudges and wipe arcs across the glass
    for _ in range(8):
        cx = random.uniform(w * 0.2, w * 0.8)
        cy = random.uniform(h * 0.2, h * 0.8)
        rx = random.uniform(120, 280)
        ry = random.uniform(60, 150)
        angle = random.uniform(0, math.pi)

        # Draw an elongated ellipse
        smudge = Image.new('L', (w, h), 0)
        s_draw = ImageDraw.Draw(smudge)
        bbox = [cx - rx, cy - ry, cx + rx, cy + ry]
        s_draw.ellipse(bbox, fill=random.randint(18, 40))
        # Rotate around center
        smudge = smudge.rotate(math.degrees(angle), center=(cx, cy))
        smudge = smudge.filter(ImageFilter.GaussianBlur(radius=random.uniform(40, 70)))

        # Blend
        base = Image.blend(base, smudge, 0.5)

    draw = ImageDraw.Draw(base)

    # 2. Water droplet residue / drying spot rings
    spots_layer = Image.new('L', (w, h), 0)
    sp_draw = ImageDraw.Draw(spots_layer)
    for _ in range(16):
        cx = random.uniform(40, w - 40)
        cy = random.uniform(40, h - 40)
        radius = random.uniform(12, 45)
        # Ring has brighter edge, dimmer center
        edge_brightness = random.randint(35, 75)
        sp_draw.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], outline=edge_brightness, width=random.randint(2, 4))
        sp_draw.ellipse([cx - radius + 3, cy - radius + 3, cx + radius - 3, cy + radius - 3], fill=random.randint(5, 20))

    spots_layer = spots_layer.filter(ImageFilter.GaussianBlur(radius=3.5))

    # 3. Out-of-focus dust motes (bokeh circles on front element)
    dust_layer = Image.new('L', (w, h), 0)
    d_draw = ImageDraw.Draw(dust_layer)

    # Large soft bokeh motes
    for _ in range(35):
        cx = random.uniform(20, w - 20)
        cy = random.uniform(20, h - 20)
        radius = random.uniform(8, 28)
        brightness = random.randint(45, 110)
        # Circular disc with soft edge
        d_draw.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=brightness, outline=int(brightness * 1.25), width=2)

    dust_layer = dust_layer.filter(ImageFilter.GaussianBlur(radius=2.5))

    # Fine sharp dust specks and tiny particles
    d_sharp = ImageDraw.Draw(dust_layer)
    for _ in range(140):
        cx = random.uniform(10, w - 10)
        cy = random.uniform(10, h - 10)
        radius = random.uniform(1.2, 4.0)
        brightness = random.randint(90, 220)
        d_sharp.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=brightness)

    # 4. Hair / fiber particles
    for _ in range(6):
        x0 = random.uniform(50, w - 50)
        y0 = random.uniform(50, h - 50)
        length = random.uniform(30, 80)
        angle = random.uniform(0, math.tau)
        curve = random.uniform(-0.5, 0.5)

        points = []
        for step in range(12):
            t = step / 11.0
            px = x0 + math.cos(angle + t * curve) * length * t
            py = y0 + math.sin(angle + t * curve) * length * t
            points.append((px, py))
        d_sharp.line(points, fill=random.randint(70, 160), width=random.randint(1, 2))

    # Combine all layers with screen-style blend
    def blend_screen(a, b):
        return Image.frombytes('L', (w, h), bytes(
            int(255 - ((255 - p1) * (255 - p2)) / 255.0)
            for p1, p2 in zip(a.tobytes(), b.tobytes())
        ))

    final = blend_screen(base, spots_layer)
    final = blend_screen(final, dust_layer)

    # Subtle contrast stretch so glass has clean black background
    final = final.point(lambda p: int(min(255, max(0, (p - 6) * 1.15))))

    final.save(out_path)
    print("Successfully generated lens dirt texture:", out_path)

if __name__ == "__main__":
    generate_lens_dirt()
