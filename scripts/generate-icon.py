#!/usr/bin/env python3
"""kilo app icon — 黑底 squircle + 白色 zyx logo（Loki 的 brand mark）。

來源 scripts/zyx.svg（從 zyx.icon Icon Composer bundle 抽出，原 fill=black）。
qlmanage 渲染 svg 為黑 logo / 白底（不透明），再用亮度反推 alpha 抠成白 logo 透明底。

用法：python3 scripts/generate-icon.py
然後（見檔尾）iconset → Resources/AppIcon.icns。
"""
import subprocess
import tempfile
import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(HERE, "zyx.svg")
S = 1024

# svg 去 drop-shadow filter（白底上會變灰干擾抠圖），渲染成黑 logo / 白底 png
with open(SVG) as f:
    svg = f.read().replace(' filter="url(#filter0_d_1_18)"', "")
with tempfile.TemporaryDirectory() as tmp:
    src = os.path.join(tmp, "zyx-black.svg")
    with open(src, "w") as f:
        f.write(svg)
    subprocess.run(["qlmanage", "-t", "-s", str(S), "-o", tmp, src],
                   check=True, capture_output=True)
    raw = Image.open(os.path.join(tmp, "zyx-black.svg.png")).convert("L")

# 亮度反推 alpha：黑 logo(0)→不透明白(255)、白底(255)→透明(0)，邊緣灰→半透明（抗鋸齒）
alpha = raw.point(lambda v: 255 - v)
logo = Image.new("RGBA", raw.size, (255, 255, 255, 255))
logo.putalpha(alpha)
logo = logo.crop(logo.getbbox())

target = int(S * 0.60)  # logo 占畫布比例
lw, lh = logo.size
scale = target / max(lw, lh)
logo = logo.resize((max(1, int(lw * scale)), max(1, int(lh * scale))), Image.LANCZOS)

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
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
img.paste(bg, (0, 0), mask)

gx, gy = (S - logo.width) // 2, (S - logo.height) // 2
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
glow.paste(logo, (gx, gy), logo)
glow = glow.filter(ImageFilter.GaussianBlur(20))
img = Image.alpha_composite(img, glow)
img.paste(logo, (gx, gy), logo)

img.save("kilo-icon-1024.png")
print("saved kilo-icon-1024.png — then:")
print("  rm -rf kilo.iconset && mkdir kilo.iconset")
print("  for sz in 16 32 128 256 512; do \\")
print("    sips -z $sz $sz kilo-icon-1024.png --out kilo.iconset/icon_${sz}x${sz}.png; \\")
print("    sips -z $((sz*2)) $((sz*2)) kilo-icon-1024.png --out kilo.iconset/icon_${sz}x${sz}@2x.png; done")
print("  iconutil -c icns kilo.iconset -o Resources/AppIcon.icns")
