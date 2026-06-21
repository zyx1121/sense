#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""App icon 產生器 —— zyx 品牌標 + 深色 squircle，輸出 Resources/AppIcon.icns。

來源 scripts/zyx.svg（白 zyx logo，原 fill=black + drop-shadow）。流程：去 drop-shadow →
qlmanage 渲成黑 logo / 白底 png → 亮度反推 alpha 抠成白 logo 透明底 → 疊到深色圓角漸層底 + glow →
1024 png → sips/iconutil 打成 .icns。改 brand mark 就換 zyx.svg。

用法：./scripts/generate-icon.py   （經 uv 自動取 Pillow）
"""
import os
import re
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SVG = os.path.join(HERE, "zyx.svg")
OUT_ICNS = os.path.join(ROOT, "Resources", "AppIcon.icns")
OUT_MENUBAR = os.path.join(ROOT, "Resources", "MenubarIcon.pdf")
S = 1024

# 深色圓角底（垂直漸層 #20232a → #0c0d10）、圓角比例、logo 佔畫布比例 —— 全家統一視覺簽名。
TOP = (0x20, 0x23, 0x2A)
BOT = (0x0C, 0x0D, 0x10)
RADIUS = int(S * 0.225)
LOGO_COVERAGE = 0.60
# 選單列 mark:方形畫布,字符佔此比例、四周留白 —— 貼邊會被選單列切掉底部。
MENUBAR_COVERAGE = 0.72


def render_logo() -> Image.Image:
    """SVG → 白 logo / 透明底 RGBA（去 drop-shadow，亮度反推 alpha 含抗鋸齒）。"""
    with open(SVG) as f:
        svg = f.read().replace(' filter="url(#filter0_d_1_18)"', "")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "mark.svg")
        with open(src, "w") as f:
            f.write(svg)
        subprocess.run(["qlmanage", "-t", "-s", str(S), "-o", tmp, src],
                       check=True, capture_output=True)
        raw = Image.open(os.path.join(tmp, "mark.svg.png")).convert("L")
    alpha = raw.point(lambda v: 255 - v)            # 黑 logo(0)→不透明(255)、白底(255)→透明(0)
    logo = Image.new("RGBA", raw.size, (255, 255, 255, 255))
    logo.putalpha(alpha)
    logo = logo.crop(logo.getbbox())
    target = int(S * LOGO_COVERAGE)
    lw, lh = logo.size
    scale = target / max(lw, lh)
    return logo.resize((max(1, int(lw * scale)), max(1, int(lh * scale))), Image.LANCZOS)


def compose(logo: Image.Image) -> Image.Image:
    bg = Image.new("RGBA", (S, S))
    for y in range(S):
        t = y / S
        bg.paste(tuple(int(TOP[i] * (1 - t) + BOT[i] * t) for i in range(3)) + (255,),
                 (0, y, S, y + 1))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=RADIUS, fill=255)
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    img.paste(bg, (0, 0), mask)

    gx, gy = (S - logo.width) // 2, (S - logo.height) // 2
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    glow.paste(logo, (gx, gy), logo)
    glow = glow.filter(ImageFilter.GaussianBlur(20))
    img = Image.alpha_composite(img, glow)
    img.paste(logo, (gx, gy), logo)
    return img


def to_icns(png_1024: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "icon.iconset")
        os.makedirs(iconset)
        for sz in (16, 32, 128, 256, 512):
            for scale, suffix in ((1, f"{sz}x{sz}"), (2, f"{sz}x{sz}@2x")):
                px = sz * scale
                subprocess.run(["sips", "-z", str(px), str(px), png_1024,
                                "--out", os.path.join(iconset, f"icon_{suffix}.png")],
                               check=True, capture_output=True)
        os.makedirs(os.path.dirname(OUT_ICNS), exist_ok=True)
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", OUT_ICNS], check=True)


def make_menubar_pdf() -> None:
    """選單列 template mark:vector PDF(zyx 字符,緊 bbox)。

    vector 而非 raster —— 小尺寸(選單列 18pt、overlay 12pt)rasterize 在繪製尺寸發生,
    不走 bitmap 縮放,不糊。先量 mark 緊 bbox(去原 svg 四周 padding)再 rsvg-convert。
    """
    with open(SVG) as f:
        svg = f.read().replace(' filter="url(#filter0_d_1_18)"', "")
    # 緊 bbox:用 rsvg(跟最終輸出同一 renderer,量測才跟渲染一致 → 置中準)render → alpha getbbox。
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "mark.svg")
        with open(src, "w") as f:
            f.write(svg)
        meas = os.path.join(tmp, "measure.png")
        subprocess.run(["rsvg-convert", "-w", str(S), src, "-o", meas], check=True)
        raw = Image.open(meas).convert("RGBA")
    l, t, r, b = raw.split()[-1].getbbox()
    vx0, vy0, vbw, vbh = (float(x) for x in re.search(r'viewBox="([\d.\s-]+)"', svg).group(1).split())
    sx, sy = vbw / raw.width, vbh / raw.height
    gx, gy, gw, gh = vx0 + l * sx, vy0 + t * sy, (r - l) * sx, (b - t) * sy
    # 方形畫布 + padding:字符置中佔 MENUBAR_COVERAGE,四周留白(否則貼邊被選單列切底)。
    side = max(gw, gh) / MENUBAR_COVERAGE
    ox, oy = gx - (side - gw) / 2, gy - (side - gh) / 2
    svg = re.sub(r'viewBox="[^"]*"', f'viewBox="{ox:.2f} {oy:.2f} {side:.2f} {side:.2f}"', svg, count=1)
    svg = re.sub(r'\swidth="[^"]*"', f' width="{side:.2f}"', svg, count=1)
    svg = re.sub(r'\sheight="[^"]*"', f' height="{side:.2f}"', svg, count=1)
    os.makedirs(os.path.dirname(OUT_MENUBAR), exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        tight = os.path.join(tmp, "tight.svg")
        with open(tight, "w") as f:
            f.write(svg)
        subprocess.run(["rsvg-convert", "-f", "pdf", "-o", OUT_MENUBAR, tight], check=True)


def main() -> None:
    logo = render_logo()
    make_menubar_pdf()
    img = compose(logo)
    with tempfile.TemporaryDirectory() as tmp:
        png = os.path.join(tmp, "icon-1024.png")
        img.save(png)
        to_icns(png)
    print(f"[OK] {os.path.relpath(OUT_ICNS, ROOT)} + {os.path.relpath(OUT_MENUBAR, ROOT)}")


if __name__ == "__main__":
    main()
