#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "Resources"
ICONSET = ROOT / "build" / "AppIcon.iconset"
RES.mkdir(parents=True, exist_ok=True)
ICONSET.mkdir(parents=True, exist_ok=True)

# Vertical gradient: deep navy -> teal
top = (13, 34, 51)
bottom = (24, 122, 156)
base = Image.new("RGB", (SIZE, SIZE), top)
px = base.load()
for y in range(SIZE):
    t = y / (SIZE - 1)
    # ease
    t = t * t * (3 - 2 * t)
    r = int(top[0] + (bottom[0] - top[0]) * t)
    g = int(top[1] + (bottom[1] - top[1]) * t)
    b = int(top[2] + (bottom[2] - top[2]) * t)
    for x in range(SIZE):
        px[x, y] = (r, g, b)

# Rounded-square mask
mask = Image.new("L", (SIZE, SIZE), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=228, fill=255)
icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
icon.paste(base, (0, 0), mask)

# Soft top highlight
highlight = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
hd = ImageDraw.Draw(highlight)
hd.ellipse([-260, -520, SIZE + 260, 300], fill=(255, 255, 255, 22))
highlight = highlight.filter(ImageFilter.GaussianBlur(80))
icon = Image.alpha_composite(icon, Image.composite(highlight, Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0)), mask))

draw = ImageDraw.Draw(icon)

# Inward corner brackets ("compress" focus)
w = 44
length = 168
inset = 196
white = (255, 255, 255, 235)
for (x, y, dx, dy) in [
    (inset, inset, 1, 1),
    (SIZE - inset, inset, -1, 1),
    (inset, SIZE - inset, 1, -1),
    (SIZE - inset, SIZE - inset, -1, -1),
]:
    draw.line([(x, y), (x + dx * length, y)], fill=white, width=w)
    draw.line([(x, y), (x, y + dy * length)], fill=white, width=w)

# Center play triangle
tri = [(424, 382), (424, 642), (664, 512)]
draw.polygon(tri, fill=(255, 255, 255, 245))

# Bottom subtle shadow inside the rounded square
shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.ellipse([120, 760, SIZE - 120, 1120], fill=(0, 0, 0, 55))
shadow = shadow.filter(ImageFilter.GaussianBlur(60))
icon = Image.alpha_composite(icon, Image.composite(shadow, Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0)), mask))

# Clip final to rounded square
final = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
final.paste(icon, (0, 0), mask)

final.save(RES / "icon-1024.png")
sizes = [16, 32, 128, 256, 512]
for s in sizes:
    final.resize((s, s), Image.LANCZOS).save(ICONSET / f"icon_{s}x{s}.png")
    final.resize((s * 2, s * 2), Image.LANCZOS).save(ICONSET / f"icon_{s}x{s}@2x.png")
print("wrote", RES / "icon-1024.png")
