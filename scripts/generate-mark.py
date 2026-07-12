#!/usr/bin/env python3
"""SenseMark — zyx logo 單色 template PNG（狀態欄 + feed icon 用，可 tint）。
來源 scripts/zyx.svg。qlmanage 點陣黑 logo/白底 → 亮度反推 alpha → 輸出純白 + alpha mask
（SwiftUI/NSImage 當 template，染色靠 foregroundStyle / tint）。輸出 Resources/SenseMark.png（512 高清，resizable）。
用法：python3 scripts/generate-mark.py
"""
import subprocess, tempfile, os
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(HERE, "zyx.svg")
OUT = os.path.join(HERE, "..", "Resources", "SenseMark.png")

svg = open(SVG).read().replace(' filter="url(#filter0_d_1_18)"', "")
with tempfile.TemporaryDirectory() as tmp:
    src = os.path.join(tmp, "m.svg")
    open(src, "w").write(svg)
    subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp, src], check=True, capture_output=True)
    raw = Image.open(os.path.join(tmp, "m.svg.png")).convert("L")

alpha = raw.point(lambda v: 255 - v)        # 黑 logo→不透明、白底→透明
mark = Image.new("RGBA", raw.size, (255, 255, 255, 255))
mark.putalpha(alpha)
mark = mark.crop(mark.getbbox())
# 縮到最長邊 512（高清，view 端 resizable 縮小）
w, h = mark.size
s = 512 / max(w, h)
mark = mark.resize((round(w * s), round(h * s)), Image.LANCZOS)
mark.save(OUT)
print("saved", OUT, mark.size)
