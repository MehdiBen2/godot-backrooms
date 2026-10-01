"""
Generates high-resolution PBR textures for the Backrooms acoustic drop-ceiling tiles:
- l0_ceiling_color.webp: Classic commercial mineral fiber acoustic tiles with T-bar grid,
  dense acoustic stippling, pinholes, and darkened fissures.
- l0_ceiling_normal.webp: Crisp micro-grain and deep acoustic fissures that react
  strongly to directional flashlight / torch illumination.
- l0_ceiling_rough.webp: Rough porous fissures contrasting with satin sheen on the
  painted tile surface so the torch catches the grain.
- l0_ceiling_ao.webp: Ambient occlusion darkening in fissures, pinholes, and grid seams.
"""

import os
import math
import random
import numpy as np
from PIL import Image

def generate_ceiling_textures(out_dir="godot-backrooms/textures", size=2048, tiles_per_side=6):
    os.makedirs(out_dir, exist_ok=True)
    random.seed(1337)
    np.random.seed(1337)

    tile_sz = size // tiles_per_side
    print(f"Generating {size}x{size} acoustic ceiling textures ({tiles_per_side}x{tiles_per_side} tiles, {tile_sz}px each)...")

    # 1. Height map initialized to flat surface (0.75 base)
    height = np.full((size, size), 0.75, dtype=np.float32)

    # 2. Rich acoustic stipple micro-grain across the entire surface
    print("Synthesizing acoustic mineral fiber micro-grain...")
    # Fast seamless grid noise
    noise_raw = np.random.normal(0.0, 1.0, (size, size)).astype(np.float32)

    def blur2d(arr, r):
        res = arr.copy()
        for _ in range(r):
            res = (np.roll(res, 1, 0) + np.roll(res, -1, 0) + np.roll(res, 1, 1) + np.roll(res, -1, 1) + 4.0 * res) / 8.0
        return res

    # Multi-scale mineral texture:
    # - Ultra-fine grain (per-pixel sand grit)
    grit = noise_raw - blur2d(noise_raw, 1)
    grit /= (grit.std() + 1e-5)

    # - Fine stipple (small 2-3px bumps)
    fine = blur2d(np.random.normal(0.0, 1.0, (size, size)).astype(np.float32), 2)
    fine /= (fine.std() + 1e-5)

    # - Medium porous clumps (5-8px clusters)
    med = blur2d(np.random.normal(0.0, 1.0, (size, size)).astype(np.float32), 5)
    med /= (med.std() + 1e-5)

    # - Broad waviness (15-25px subtle panel unflatness)
    broad = blur2d(np.random.normal(0.0, 1.0, (size, size)).astype(np.float32), 12)
    broad /= (broad.std() + 1e-5)

    # Combine into surface stipple with pronounced tactile grit
    stipple = grit * 0.08 + fine * 0.05 + med * 0.03 + broad * 0.015
    height += stipple

    # 3. Dense acoustic fissures and needle pinholes
    print("Carving acoustic fissures and needle pinholes...")
    fissure_mask = np.zeros((size, size), dtype=np.float32)

    # Generate organic worm fissures and pinholes per tile
    for ty in range(tiles_per_side):
        for tx in range(tiles_per_side):
            x_min = tx * tile_sz
            y_min = ty * tile_sz

            # Margin from T-bar grid rail (rail is ~11px wide, leave 14px border)
            inner_pad = 14
            x0 = x_min + inner_pad
            x1 = x_min + tile_sz - inner_pad
            y0 = y_min + inner_pad
            y1 = y_min + tile_sz - inner_pad

            # 70-110 fissures per tile for rich acoustic pattern
            num_fissures = random.randint(70, 110)
            for _ in range(num_fissures):
                cx = random.uniform(x0, x1)
                cy = random.uniform(y0, y1)

                # Preferred orientation with some variation
                angle = random.choice([0.0, math.pi * 0.5, math.pi * 0.25, -math.pi * 0.25]) + random.gauss(0, 0.3)
                length = random.uniform(6, 26)
                steps = int(length)

                px, py = cx, cy
                depth = random.uniform(0.25, 0.48)
                radius = random.uniform(1.0, 2.2)

                for step in range(steps):
                    ix = int(round(px)) % size
                    iy = int(round(py)) % size

                    r_int = int(math.ceil(radius))
                    for dy in range(-r_int, r_int + 1):
                        for dx in range(-r_int, r_int + 1):
                            dist_sq = dx * dx + dy * dy
                            if dist_sq <= radius * radius:
                                factor = 1.0 - math.sqrt(dist_sq) / radius
                                gx = (ix + dx) % size
                                gy = (iy + dy) % size
                                fissure_mask[gy, gx] = max(fissure_mask[gy, gx], depth * factor)

                    angle += random.gauss(0, 0.4)
                    step_len = 0.8
                    px += math.cos(angle) * step_len
                    py += math.sin(angle) * step_len

            # 150-240 needle pinholes per tile (characteristic of USG / Armstrong acoustic tiles)
            num_pinholes = random.randint(150, 240)
            for _ in range(num_pinholes):
                px = random.randint(x0, x1)
                py = random.randint(y0, y1)
                p_depth = random.uniform(0.35, 0.55)
                p_rad = random.uniform(0.9, 1.6)
                r_int = int(math.ceil(p_rad))
                for dy in range(-r_int, r_int + 1):
                    for dx in range(-r_int, r_int + 1):
                        dist_sq = dx * dx + dy * dy
                        if dist_sq <= p_rad * p_rad:
                            f = 1.0 - math.sqrt(dist_sq) / p_rad
                            gx = (px + dx) % size
                            gy = (py + dy) % size
                            fissure_mask[gy, gx] = max(fissure_mask[gy, gx], p_depth * f)

    # Subtract fissures from height
    height -= fissure_mask

    # 4. T-bar metal grid suspension runners
    print("Constructing T-bar grid rails...")
    rail_half = 5 # 10-11px total rail width
    bevel_width = 7 # Tile bevel into grid

    y_coords, x_coords = np.indices((size, size))
    dist_x = np.minimum(x_coords % tile_sz, tile_sz - (x_coords % tile_sz))
    dist_y = np.minimum(y_coords % tile_sz, tile_sz - (y_coords % tile_sz))
    dist_grid = np.minimum(dist_x, dist_y)

    is_rail = dist_grid <= rail_half
    is_bevel = (dist_grid > rail_half) & (dist_grid <= rail_half + bevel_width)

    # Rail face is flat at 0.73
    height[is_rail] = 0.73
    # Bevel slopes up to tile face
    bevel_t = (dist_grid[is_bevel] - rail_half) / float(bevel_width)
    height[is_bevel] = np.minimum(height[is_bevel], 0.64 + bevel_t * 0.11)
    # Recess groove
    is_groove = (dist_grid == rail_half) | (dist_grid == rail_half + 1)
    height[is_groove] = 0.60

    # 5. Compute Normal Map via central differences (Sobel/derivative)
    print("Computing normal map...")
    # Strong normal strength for tactile micro-relief in torch beam
    normal_strength = 32.0

    dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5 * normal_strength
    dy = -(np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5 * normal_strength
    dz = np.ones_like(dx)

    length = np.sqrt(dx * dx + dy * dy + dz * dz)
    nx = dx / length
    ny = dy / length
    nz = dz / length

    # Encode to RGB [0..255]
    norm_r = np.clip((nx * 0.5 + 0.5) * 255.0, 0, 255).astype(np.uint8)
    norm_g = np.clip((ny * 0.5 + 0.5) * 255.0, 0, 255).astype(np.uint8)
    norm_b = np.clip((nz * 0.5 + 0.5) * 255.0, 0, 255).astype(np.uint8)
    normal_img = np.stack([norm_r, norm_g, norm_b], axis=-1)

    # 6. Roughness Map
    # Base painted tile: 0.54 (subtle satin sheen so the flashlight beam catches the micro-grain!)
    # Fissures / pinholes: 0.98 - 1.0 (matte porous cavities that absorb and scatter light)
    # T-bar metal rail: 0.35 (smooth powder-coated metal)
    print("Generating roughness map...")
    roughness = np.full((size, size), 0.54, dtype=np.float32)
    # Fine grain roughness variation (the gritty peaks catch glints)
    roughness += stipple * 0.7
    # Fissures are very rough / matte
    roughness = np.maximum(roughness, 0.54 + fissure_mask * 1.2)
    # T-bar metal rail is smooth
    roughness[is_rail] = 0.35
    roughness[is_groove] = 0.90
    rough_u8 = np.clip(roughness * 255.0, 0, 255).astype(np.uint8)
    rough_img = np.stack([rough_u8, rough_u8, rough_u8], axis=-1)

    # 7. Ambient Occlusion (AO)
    print("Generating ambient occlusion map...")
    ao = np.ones((size, size), dtype=np.float32)
    ao -= fissure_mask * 1.6
    ao[is_groove] = 0.35
    ao[is_bevel] = np.minimum(ao[is_bevel], 0.55 + bevel_t * 0.45)
    ao_u8 = np.clip(ao * 255.0, 0, 255).astype(np.uint8)
    ao_img = np.stack([ao_u8, ao_u8, ao_u8], axis=-1)

    # 8. Albedo / Color Map
    print("Generating albedo color map...")
    base_color = np.array([242.0, 240.0, 234.0], dtype=np.float32)
    fissure_color = np.array([140.0, 135.0, 125.0], dtype=np.float32)
    rail_color = np.array([246.0, 245.0, 242.0], dtype=np.float32)

    color_map = np.tile(base_color, (size, size, 1))
    for ty in range(tiles_per_side):
        for tx in range(tiles_per_side):
            x0 = tx * tile_sz
            y0 = ty * tile_sz
            v_shift = random.uniform(-3.5, 3.5)
            color_map[y0:y0+tile_sz, x0:x0+tile_sz] += v_shift

    # Add acoustic surface grit to albedo
    color_map += stipple[:, :, np.newaxis] * 40.0

    # Blend fissure color
    f_weight = np.clip(fissure_mask[:, :, np.newaxis] * 2.5, 0.0, 1.0)
    color_map = color_map * (1.0 - f_weight) + fissure_color * f_weight

    # Blend rail color
    color_map[is_rail] = rail_color
    color_map[is_groove] = fissure_color * 0.8

    color_u8 = np.clip(color_map, 0, 255).astype(np.uint8)

    # 9. Save as WebP
    print("Saving textures...")
    Image.fromarray(color_u8).save(os.path.join(out_dir, "l0_ceiling_color.webp"), "WEBP", quality=92)
    Image.fromarray(normal_img).save(os.path.join(out_dir, "l0_ceiling_normal.webp"), "WEBP", quality=95)
    Image.fromarray(rough_img).save(os.path.join(out_dir, "l0_ceiling_rough.webp"), "WEBP", quality=90)
    Image.fromarray(ao_img).save(os.path.join(out_dir, "l0_ceiling_ao.webp"), "WEBP", quality=90)
    print("All textures saved successfully!")

if __name__ == "__main__":
    generate_ceiling_textures()
