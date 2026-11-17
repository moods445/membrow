#!/usr/bin/env python3
"""生成 Membrow 应用图标。

用法：python3 scripts/make-icon.py assets/AppIcon.icns

只依赖标准库（zlib 写 PNG）+ 系统自带 sips / iconutil。
设计：Big Sur 圆角底 + 冷色渐变；前景三层堆叠页面卡（多会话同存），
顶层卡片内是内存条状的内容行，呼应「页面临时驻留内存、按 LRU 淘汰」。
坐标按 1024 设计稿、左上原点书写，SDF 解析抗锯齿，其余尺寸交给 sips。
"""

import math
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

SIZE = 1024


def clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else (hi if v > hi else v)


def smoothstep(e0, e1, x):
    t = clamp((x - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)


def sd_round_rect(px, py, cx, cy, hw, hh, r):
    qx = abs(px - cx) - (hw - r)
    qy = abs(py - cy) - (hh - r)
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


def mix(c0, c1, t):
    return tuple(c0[i] + (c1[i] - c0[i]) * t for i in range(3))


def hex_rgb(h):
    return ((h >> 16 & 255) / 255.0, (h >> 8 & 255) / 255.0, (h & 255) / 255.0)


# ---- 设计稿参数 ----
BODY = (512, 512, 412, 412, 185)          # cx, cy, hw, hh, r
GRAD_A, GRAD_B = (320, 120), (780, 900)   # 左上亮 -> 右下暗
GRAD_C0, GRAD_C1, GRAD_C2 = hex_rgb(0x205C90), hex_rgb(0x143F63), hex_rgb(0x0C2234)
GLOW_C = (512, 164)
GLOW_R = 560.0
GLOW_RGB = hex_rgb(0x5FB6EC)

CARD_W, CARD_H, CARD_R = 440.0, 320.0, 44.0
CARDS = [  # (cx, cy, 白色不透明度, 阴影强度, 阴影模糊)：后两层往左上错开
    (480, 484, 0.16, 0.18, 14.0),
    (504, 515, 0.26, 0.22, 18.0),
]
FRONT = (528, 546)
FRONT_C0, FRONT_C1 = hex_rgb(0xFFFFFF), hex_rgb(0xD7EAF7)
ACCENT = hex_rgb(0x2AA9C8)
ROW_GREY = hex_rgb(0x6E8CA6)
ROWS = [(230, ACCENT, 0.95), (330, ROW_GREY, 0.65), (285, ROW_GREY, 0.65), (165, ROW_GREY, 0.65)]


def body_sd(px, py):
    return sd_round_rect(px, py, *BODY)


def body_color(px, py):
    # 线性渐变投影：沿 A->B 方向的归一化位置，分三段 interpolate
    dx, dy = GRAD_B[0] - GRAD_A[0], GRAD_B[1] - GRAD_A[1]
    t = clamp(((px - GRAD_A[0]) * dx + (py - GRAD_A[1]) * dy) / float(dx * dx + dy * dy))
    c = mix(GRAD_C0, GRAD_C1, t / 0.55) if t < 0.55 else mix(GRAD_C1, GRAD_C2, (t - 0.55) / 0.45)
    # 顶部径向环境光
    gl = clamp(1.0 - math.hypot(px - GLOW_C[0], py - GLOW_C[1]) / GLOW_R) ** 2 * 0.42
    return mix(c, GLOW_RGB, gl)


def render():
    # 每层：(sdf 函数, 颜色函数, 不透明度, 阴影强度, 阴影位移, 阴影模糊)
    cards = []
    for cx, cy, alpha, sh_str, blur in CARDS:
        sd = lambda px, py, cx=cx, cy=cy: sd_round_rect(px, py, cx, cy, CARD_W / 2, CARD_H / 2, CARD_R)
        cards.append((sd, lambda px, py: (1.0, 1.0, 1.0), alpha, sh_str, 8.0, blur))

    fsd = lambda px, py: sd_round_rect(px, py, FRONT[0], FRONT[1], CARD_W / 2, CARD_H / 2, CARD_R)
    fcolor = lambda px, py: mix(
        FRONT_C0, FRONT_C1,
        clamp(((px - (FRONT[0] - CARD_W / 2)) + (py - (FRONT[1] - CARD_H / 2))) / (CARD_W + CARD_H)),
    )

    row_layers = []
    card_top = FRONT[1] - CARD_H / 2
    row_x = FRONT[0] - CARD_W / 2 + 56
    for i, (w, rgb, alpha) in enumerate(ROWS):
        cy = card_top + 70 + i * 60
        row_layers.append((
            lambda px, py, cy=cy, w=w: sd_round_rect(px, py, row_x + w / 2, cy, w / 2, 10, 10),
            lambda px, py, rgb=rgb: rgb, alpha, 0.0, 0.0, 0.0,
        ))

    layers = [(body_sd, body_color, 1.0, 0.38, 14.0, 34.0)] + cards + [(fsd, fcolor, 1.0, 0.30, 10.0, 28.0)] + row_layers

    buf = bytearray()
    for y in range(SIZE):
        py = y + 0.5
        for x in range(SIZE):
            px = x + 0.5
            # 预乘累加：dst = src*a + dst*(1-a)
            orr = og = ob = oa = 0.0
            for sd, color, alpha, sh_str, sh_off, sh_blur in layers:
                d = sd(px, py)
                cov = clamp(0.5 - d) * alpha
                if sh_str:
                    s = sd(px, py - sh_off)
                    sa = sh_str * smoothstep(0.5, -0.5, s / sh_blur)
                    if sa > 0.001:
                        orr *= 1 - sa; og *= 1 - sa; ob *= 1 - sa
                        oa = sa + oa * (1 - sa)
                if cov > 0.001:
                    c = color(px, py)
                    orr = c[0] * cov + orr * (1 - cov)
                    og = c[1] * cov + og * (1 - cov)
                    ob = c[2] * cov + ob * (1 - cov)
                    oa = cov + oa * (1 - cov)
            if oa <= 0.0:
                buf += b"\x00\x00\x00\x00"
            else:
                buf += bytes((
                    int(clamp(orr / oa) * 255 + 0.5),
                    int(clamp(og / oa) * 255 + 0.5),
                    int(clamp(ob / oa) * 255 + 0.5),
                    int(clamp(oa) * 255 + 0.5),
                ))
    return bytes(buf)


def write_png(path, raw):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    stride = SIZE * 4  # 每行插一个 filter 字节（0 = None）
    raw = b"".join(b"\x00" + raw[i:i + stride] for i in range(0, len(raw), stride))
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    Path(path).write_bytes(png)


VARIANTS = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "assets/AppIcon.icns")
    preview = Path(sys.argv[2]) if len(sys.argv) > 2 else None  # 可选：另存 1024 PNG 便于人工复验
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        big = Path(tmp) / "icon_1024.png"
        write_png(big, render())
        if preview:
            preview.write_bytes(big.read_bytes())
        for name, px in VARIANTS:
            subprocess.run(["sips", "-z", str(px), str(px), str(big), "--out", str(iconset / name)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        out.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["iconutil", "-c", "icns", "-o", str(out), str(iconset)], check=True)
    print(f"已生成：{out}")


if __name__ == "__main__":
    main()
