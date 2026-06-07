#!/usr/bin/env python3
"""kilo app icon — 深色圓角 squircle + cyan sparkle（呼應 app 內 reply 的 cyan sparkle）。
重生成：python3 scripts/generate-icon.py && （見檔尾 iconset/icns 步驟）。"""
from PIL import Image, ImageDraw, ImageFilter
import math

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# 深色圓角底（垂直漸層 #20232a → #0c0d10）
bg = Image.new("RGBA", (S, S))
for y in range(S):
    t = y / S
    r = int(0x20 * (1 - t) + 0x0c * t)
    g = int(0x23 * (1 - t) + 0x0d * t)
    b = int(0x2a * (1 - t) + 0x10 * t)
    for x in range(S):
        bg.putpixel((x, y), (r, g, b, 255))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=230, fill=255)
img.paste(bg, (0, 0), mask)


def star(cx, cy, outer, inner):
    pts = []
    for i in range(8):
        ang = math.radians(i * 45 - 90)
        r = outer if i % 2 == 0 else inner
        pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
    return pts


cx = cy = 512
cyan = (94, 215, 245, 255)

glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).polygon(star(cx, cy, 330, 95), fill=(94, 215, 245, 150))
glow = glow.filter(ImageFilter.GaussianBlur(38))
img = Image.alpha_composite(img, glow)

spk = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(spk).polygon(star(cx, cy, 320, 88), fill=cyan)
ImageDraw.Draw(spk).ellipse([cx - 26, cy - 26, cx + 26, cy + 26], fill=(225, 248, 255, 255))
img = Image.alpha_composite(img, spk)
img = img.filter(ImageFilter.GaussianBlur(0.5))

img.save("kilo-icon-1024.png")
print("saved kilo-icon-1024.png — then:")
print("  rm -rf kilo.iconset && mkdir kilo.iconset")
print("  for sz in 16 32 128 256 512; do \\")
print("    sips -z $sz $sz kilo-icon-1024.png --out kilo.iconset/icon_${sz}x${sz}.png; \\")
print("    sips -z $((sz*2)) $((sz*2)) kilo-icon-1024.png --out kilo.iconset/icon_${sz}x${sz}@2x.png; done")
print("  iconutil -c icns kilo.iconset -o Resources/AppIcon.icns")
