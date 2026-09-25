"""Generate the custom Backrooms boot splash screen for Godot."""
from PIL import Image, ImageFont, ImageDraw

def generate_splash():
    w, h = 1920, 1080
    img = Image.new("RGB", (w, h), (0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Fonts from res://fonts/vcr.ttf
    font_title = ImageFont.truetype("fonts/vcr.ttf", 136)
    font_sub = ImageFont.truetype("fonts/vcr.ttf", 24)

    title_text = "THE BACKROOMS"
    sub_text = "THRESHOLD SECTOR • NON-EUCLIDEAN ZONE"

    # Measure title
    tb = draw.textbbox((0, 0), title_text, font=font_title)
    tw = tb[2] - tb[0]
    th = tb[3] - tb[1]

    # Measure subtitle with letter spacing
    sub_spacing = 4
    sub_chars = list(sub_text)
    char_widths = [draw.textbbox((0, 0), ch, font=font_sub)[2] - draw.textbbox((0, 0), ch, font=font_sub)[0] for ch in sub_chars]
    total_sub_w = sum(char_widths) + sub_spacing * (len(sub_chars) - 1)
    sb = draw.textbbox((0, 0), sub_text, font=font_sub)
    sub_h = sb[3] - sb[1]

    # Center vertical block
    total_block_h = th + 40 + sub_h
    block_top = (h - total_block_h) // 2

    tx = (w - tw) // 2
    ty = block_top

    # VHS chromatic aberration fringe (matching menu.gd)
    # Red fringe (+3px)
    draw.text((tx + 3, ty), title_text, font=font_title, fill=(160, 24, 18))
    # Teal fringe (-3px)
    draw.text((tx - 3, ty), title_text, font=font_title, fill=(35, 92, 112))
    # Main title (#d8d3bd)
    draw.text((tx, ty), title_text, font=font_title, fill=(216, 211, 189))

    # Subtitle
    curr_sx = (w - total_sub_w) // 2
    curr_sy = ty + th + 40
    for i, ch in enumerate(sub_chars):
        draw.text((curr_sx, curr_sy), ch, font=font_sub, fill=(145, 138, 115))
        curr_sx += char_widths[i] + sub_spacing

    img.save("splash.png")
    print("Saved splash.png (1920x1080)")

if __name__ == "__main__":
    generate_splash()
