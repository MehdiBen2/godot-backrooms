"""
Generates high-resolution PBR textures for the Backrooms commercial floor tiles:
- tiles_color.png: Warm cream/amber commercial vinyl composite tile (VCT) with subtle mottle and per-tile variation
- tiles_normal.png: Beveled tile edges and surface waviness
- tiles_rough.png: High-gloss wax finish with matte seams and subtle wear
- tiles_ao.png: Ambient occlusion darkening in grout joints
"""
import math
import random
import os
from PIL import Image

def generate_textures(out_dir="textures", size=1024, tiles_per_side=4):
    os.makedirs(out_dir, exist_ok=True)
    random.seed(1989) # Authentic retro seed

    w = h = size
    tile_sz = size // tiles_per_side
    seam_half = 2

    # Buffers
    color_pixels = bytearray(w * h * 3)
    height_pixels = bytearray(w * h)
    rough_pixels = bytearray(w * h)
    ao_pixels = bytearray(w * h)

    # Base palette: classic Backrooms VCT floor tile (warm pale buff/cream with amber undertones)
    base_r, base_g, base_b = 214, 201, 162

    # Pre-generate per-tile properties
    tile_props = {}
    for ty in range(tiles_per_side):
        for tx in range(tiles_per_side):
            # Subtle variation in brightness and tint per tile (box to box variation)
            v_shift = random.uniform(-0.04, 0.04)
            r_shift = random.uniform(-0.02, 0.02)
            b_shift = random.uniform(-0.03, 0.01)
            # Grain direction / pattern seed
            t_seed = random.randint(0, 10000)
            tile_props[(tx, ty)] = (v_shift, r_shift, b_shift, t_seed)

    # Simple 2D value noise for seamless marbling
    def noise(x, y, freq):
        fx = (x * freq) % 1.0
        fy = (y * freq) % 1.0
        ix = int(x * freq)
        iy = int(y * freq)
        def h(cx, cy):
            n = (cx * 374761393 + cy * 668265263) ^ 0x5bf03635
            n = (n ^ (n >> 13)) * 1274126177
            return ((n ^ (n >> 16)) & 0x7fffffff) / float(0x7fffffff)
        # Bilinear interp
        tl = h(ix, iy)
        tr = h(ix + 1, iy)
        bl = h(ix, iy + 1)
        br = h(ix + 1, iy + 1)
        sx = fx * fx * (3.0 - 2.0 * fx)
        sy = fy * fy * (3.0 - 2.0 * fy)
        return (tl * (1 - sx) + tr * sx) * (1 - sy) + (bl * (1 - sx) + br * sx) * sy

    def fbm(x, y):
        n = 0.0
        amp = 0.5
        freq = 1.0
        for _ in range(4):
            n += amp * noise(x, y, freq)
            amp *= 0.5
            freq *= 2.0
        return n

    for y in range(h):
        ty = y // tile_sz
        py = y % tile_sz
        dist_y = min(py, tile_sz - 1 - py)

        for x in range(w):
            tx = x // tile_sz
            px = x % tile_sz
            dist_x = min(px, tile_sz - 1 - px)

            # Distance to nearest tile seam
            dist_seam = min(dist_x, dist_y)

            v_shift, r_shift, b_shift, t_seed = tile_props[(tx, ty)]

            # Seamless UV coords for macro noise
            nx = float(x) / w
            ny = float(y) / h
            mottle = fbm(nx * 8.0, ny * 8.0)
            flecks = noise(nx * 32.0, ny * 32.0, 1.0)

            # Calculate height profile (bevel at edges)
            # Center of tile is ~255, edges taper down smoothly
            if dist_seam <= seam_half:
                # Deep in the seam
                h_val = 140 + int(dist_seam * 25)
                seam_factor = 1.0
            elif dist_seam <= seam_half + 6:
                # Bevel slope
                t = (dist_seam - seam_half) / 6.0
                # Smoothstep
                s = t * t * (3.0 - 2.0 * t)
                h_val = int(190 + s * 55)
                seam_factor = 1.0 - s
            else:
                # Flat surface with subtle wax waviness
                wave = (fbm(nx * 4.0, ny * 4.0) - 0.5) * 8.0
                h_val = int(min(255, max(240, 248 + wave)))
                seam_factor = 0.0

            # Color calculation
            # Base color + tile variation + organic flecks
            lum = (1.0 + v_shift) * (0.95 + 0.10 * mottle)
            # Add fine vinyl composition flecks (darker/warmer specks)
            if flecks > 0.72:
                fleck_darkness = (flecks - 0.72) / 0.28
                lum *= (1.0 - 0.15 * fleck_darkness)

            cr = int(min(255, max(0, base_r * lum * (1.0 + r_shift))))
            cg = int(min(255, max(0, base_g * lum)))
            cb = int(min(255, max(0, base_b * lum * (1.0 + b_shift))))

            # Seam grout color: darker, muted gray-brown
            if seam_factor > 0.0:
                grout_r, grout_g, grout_b = 95, 88, 72
                cr = int(cr * (1.0 - seam_factor * 0.75) + grout_r * seam_factor * 0.75)
                cg = int(cg * (1.0 - seam_factor * 0.75) + grout_g * seam_factor * 0.75)
                cb = int(cb * (1.0 - seam_factor * 0.75) + grout_b * seam_factor * 0.75)

            idx = y * w + x
            color_pixels[idx * 3] = cr
            color_pixels[idx * 3 + 1] = cg
            color_pixels[idx * 3 + 2] = cb

            height_pixels[idx] = h_val

            # Roughness calculation:
            # Polished commercial floor wax is smooth and reflective (value 35-55 = 0.14-0.22)
            # Seams are rough/matte (value 180 = 0.70)
            # Subtle traffic scuffs and micro-wear
            wax_rough = 42 + int(18 * mottle)
            if seam_factor > 0.0:
                r_val = int(wax_rough * (1.0 - seam_factor) + 185 * seam_factor)
            else:
                r_val = wax_rough
            rough_pixels[idx] = min(255, max(0, r_val))

            # AO: dark in the seams, 255 elsewhere
            ao_val = int(255 - seam_factor * 110)
            ao_pixels[idx] = ao_val

    # Convert heightmap to Normal Map via Sobel operator
    normal_pixels = bytearray(w * h * 3)
    for y in range(h):
        y_prev = (y - 1) % h
        y_next = (y + 1) % h
        for x in range(w):
            x_prev = (x - 1) % w
            x_next = (x + 1) % w

            # Sobel sampling for height
            tl = height_pixels[y_prev * w + x_prev]
            tc = height_pixels[y_prev * w + x]
            tr = height_pixels[y_prev * w + x_next]
            ml = height_pixels[y * w + x_prev]
            mr = height_pixels[y * w + x_next]
            bl = height_pixels[y_next * w + x_prev]
            bc = height_pixels[y_next * w + x]
            br = height_pixels[y_next * w + x_next]

            # dx and dy
            dx = (tr + 2 * mr + br) - (tl + 2 * ml + bl)
            dy = (bl + 2 * bc + br) - (tl + 2 * tc + tr)

            # Normal strength scale
            nx = -dx * 0.08
            ny = -dy * 0.08
            nz = 255.0

            # Normalize
            l = math.sqrt(nx * nx + ny * ny + nz * nz)
            nx /= l
            ny /= l
            nz /= l

            # Map from [-1, 1] to [0, 255]
            nr = int((nx * 0.5 + 0.5) * 255)
            ng = int((ny * 0.5 + 0.5) * 255)
            nb = int((nz * 0.5 + 0.5) * 255)

            idx = (y * w + x) * 3
            normal_pixels[idx] = nr
            normal_pixels[idx + 1] = ng
            normal_pixels[idx + 2] = nb

    # Save images
    Image.frombytes('RGB', (w, h), bytes(color_pixels)).save(os.path.join(out_dir, "tiles_color.png"))
    Image.frombytes('RGB', (w, h), bytes(normal_pixels)).save(os.path.join(out_dir, "tiles_normal.png"))
    Image.frombytes('L', (w, h), bytes(rough_pixels)).save(os.path.join(out_dir, "tiles_rough.png"))
    Image.frombytes('L', (w, h), bytes(ao_pixels)).save(os.path.join(out_dir, "tiles_ao.png"))
    print("Successfully generated tiles PBR textures in", out_dir)

if __name__ == "__main__":
    generate_textures()
