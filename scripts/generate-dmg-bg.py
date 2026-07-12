#!/usr/bin/env python3
"""DMG 背景圖 — 深色漸層 + Sense(mono) + 👉 emoji，1x/2x retina。
用法：python3 scripts/generate-dmg-bg.py
然後：tiffutil -cathidpicheck /tmp/dmg-bg.png /tmp/dmg-bg@2x.png -out Resources/dmg-background.tiff
佈局數值（icon 位置 / size）對應 scripts/make-dmg.sh 的 osascript。
"""
from PIL import Image, ImageDraw, ImageFont

W, H = 600, 400
EMOJI_H = 48          # 👉 高度（point）— 跟左右圖示視覺平衡
EMOJI_CENTER = (300, 210)
MONO = "/System/Library/Fonts/Menlo.ttc"
EMOJI = "/System/Library/Fonts/Apple Color Emoji.ttc"

# 👉 高清渲染（160 strike）一次，crop 緊貼，之後依比例縮放（retina 一致）
_ef = ImageFont.truetype(EMOJI, 160)
_em = Image.new("RGBA", (220, 220), (0, 0, 0, 0))
try:
    ImageDraw.Draw(_em).text((110, 110), "👉", font=_ef, embedded_color=True, anchor="mm")
except TypeError:
    ImageDraw.Draw(_em).text((30, 30), "👉", font=_ef, embedded_color=True)
_em = _em.crop(_em.getbbox())


def render(s):
    img = Image.new("RGB", (W * s, H * s))
    for y in range(H * s):
        t = y / (H * s)
        r = int(0x1c * (1 - t) + 0x0d * t)
        g = int(0x1d * (1 - t) + 0x0e * t)
        b = int(0x22 * (1 - t) + 0x11 * t)
        for x in range(W * s):
            img.putpixel((x, y), (r, g, b))
    d = ImageDraw.Draw(img)

    def f(sz, idx=0):
        return ImageFont.truetype(MONO, sz * s, index=idx)

    d.text((W * s / 2, 72 * s), "Sense", font=f(30, 1), fill=(240, 244, 250), anchor="mm")
    d.text((W * s / 2, 108 * s), "Drag Sense into Applications",
           font=f(13), fill=(150, 156, 168), anchor="mm")

    th = EMOJI_H * s
    ew, eh = _em.size
    ew2 = max(1, int(ew * th / eh))
    e = _em.resize((ew2, th), Image.LANCZOS)
    img = img.convert("RGBA")
    cx, cy = EMOJI_CENTER
    img.paste(e, (int(cx * s - ew2 / 2), int(cy * s - th / 2)), e)
    return img.convert("RGB")


render(1).save("/tmp/dmg-bg.png")
render(2).save("/tmp/dmg-bg@2x.png")
print(f"saved /tmp/dmg-bg.png (+@2x), emoji height {EMOJI_H}")
