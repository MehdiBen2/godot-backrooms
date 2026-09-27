"""
High-speed vectorized PBR texture generator for the Bacteria entity:
- bacteria_color.png: Fibrous necrotic biomatter, organic charcoal/tendril grain
- bacteria_normal.png: Detailed organic relief, fibrous striations, cellular pitting
- bacteria_rough.png: Wet glistening channels mixed with dry fibrous grain
"""
import os
import numpy as np
from PIL import Image

def generate(out_dir="godot-backrooms/textures", size=1024):
    os.makedirs(out_dir, exist_ok=True)
    np.random.seed(1971)

    print(f"Generating Bacteria PBR textures ({size}x{size}) with NumPy...")

    def seamless_noise(res, grid_sz):
        grid = np.random.uniform(-1.0, 1.0, (grid_sz, grid_sz)).astype(np.float32)
        grid = np.pad(grid, 2, mode='wrap')
        img = Image.fromarray(grid, mode='F')
        img = img.resize((res + 4 * (res // grid_sz), res + 4 * (res // grid_sz)), Image.BICUBIC)
        arr = np.array(img)[2 * (res // grid_sz):2 * (res // grid_sz) + res, 2 * (res // grid_sz):2 * (res // grid_sz) + res]
        return arr

    macro = seamless_noise(size, 8) * 0.45
    fiber_raw = np.random.uniform(-1.0, 1.0, (64, 16)).astype(np.float32)
    fiber_pad = np.pad(fiber_raw, 2, mode='wrap')
    fiber_img = Image.fromarray(fiber_pad, mode='F').resize((size + 4 * (size // 16), size + 4 * (size // 64)), Image.BICUBIC)
    fiber = np.array(fiber_img)[2 * (size // 64):2 * (size // 64) + size, 2 * (size // 16):2 * (size // 16) + size] * 0.4

    grain = seamless_noise(size, 64) * 0.25
    micro = np.random.uniform(-0.08, 0.08, (size, size)).astype(np.float32)

    height = macro + fiber + grain + micro
    h_min, h_max = height.min(), height.max()
    height = (height - h_min) / (h_max - h_min)

    # 1. Color Map
    r = 10.0 + height * 38.0 + micro * 35.0
    g = 9.0 + height * 33.0 + micro * 30.0
    b = 7.0 + height * 24.0 + micro * 25.0
    color_arr = np.stack([
        np.clip(r, 4, 255).astype(np.uint8),
        np.clip(g, 4, 255).astype(np.uint8),
        np.clip(b, 4, 255).astype(np.uint8)
    ], axis=-1)

    # 2. Roughness Map
    rough = 0.38 + height * 0.44 + grain * 0.12
    rough_arr = np.clip(rough * 255.0, 40, 240).astype(np.uint8)

    # 3. Normal Map with Sobel filter
    strength = 7.0
    dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * strength
    dy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * strength
    dz = np.ones_like(height)

    length = np.sqrt(dx * dx + dy * dy + dz * dz)
    nx = -dx / length
    ny = -dy / length
    nz = dz / length

    normal_arr = np.stack([
        ((nx * 0.5 + 0.5) * 255.0).astype(np.uint8),
        ((ny * 0.5 + 0.5) * 255.0).astype(np.uint8),
        ((nz * 0.5 + 0.5) * 255.0).astype(np.uint8)
    ], axis=-1)

    c_path = os.path.join(out_dir, "bacteria_color.png")
    n_path = os.path.join(out_dir, "bacteria_normal.png")
    r_path = os.path.join(out_dir, "bacteria_rough.png")

    Image.fromarray(color_arr).save(c_path)
    Image.fromarray(normal_arr).save(n_path)
    Image.fromarray(rough_arr).save(r_path)
    print(f"Generated textures successfully:\n  {c_path}\n  {n_path}\n  {r_path}")

if __name__ == "__main__":
    generate()
