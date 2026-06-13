#!/usr/bin/env python3
"""Generate the ScreenToolMac app icon set (screenshot theme)."""
import os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__),
                   "ScreenToolMac/Assets.xcassets/AppIcon.appiconset")
SS = 8  # supersample factor for crisp anti-aliasing


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def make_master(px):
    """Render a single icon at px*px (no rounding mask applied yet -> apply at end)."""
    S = px * SS
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # 1. Vertical blue -> purple gradient background
    top = (10, 132, 255)     # systemBlue
    bot = (124, 58, 237)     # violet
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=lerp(top, bot, y / S) + (255,))
    radius = int(S * 0.225)  # Apple "squircle"-ish corner
    mask = rounded_mask(S, radius)
    img.paste(grad, (0, 0), mask)

    draw = ImageDraw.Draw(img)

    white = (255, 255, 255, 255)
    soft = (255, 255, 255, 235)

    # 2. Camera viewfinder corner brackets (four L shapes)
    m = S * 0.20            # margin
    lw = max(2, int(S * 0.035))   # line width
    arm = S * 0.16          # bracket arm length
    L, T, R, B = m, m, S - m, S - m

    def bracket(cx, cy, dx, dy):
        # horizontal arm
        draw.line([(cx, cy), (cx + dx * arm, cy)], fill=soft, width=lw)
        # vertical arm
        draw.line([(cx, cy), (cx, cy + dy * arm)], fill=soft, width=lw)

    bracket(L, T, 1, 1)
    bracket(R, T, -1, 1)
    bracket(L, B, 1, -1)
    bracket(R, B, -1, -1)

    # 3. Dashed selection marquee (inner irregular-ish lasso loop -> use rounded rect dashes)
    iL, iT, iR, iB = S * 0.33, S * 0.33, S * 0.67, S * 0.67
    dash = S * 0.05
    gap = S * 0.035
    dlw = max(2, int(S * 0.028))

    def dashed_line(x0, y0, x1, y1):
        length = ((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5
        if length == 0:
            return
        ux, uy = (x1 - x0) / length, (y1 - y0) / length
        d = 0.0
        while d < length:
            seg = min(dash, length - d)
            sx, sy = x0 + ux * d, y0 + uy * d
            ex, ey = x0 + ux * (d + seg), y0 + uy * (d + seg)
            draw.line([(sx, sy), (ex, ey)], fill=white, width=dlw)
            d += dash + gap

    dashed_line(iL, iT, iR, iT)
    dashed_line(iR, iT, iR, iB)
    dashed_line(iR, iB, iL, iB)
    dashed_line(iL, iB, iL, iT)

    # 4. Small camera-shutter dot in the center
    r = S * 0.055
    cx, cy = S / 2, S / 2
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=white)

    # Downsample for anti-aliasing, re-apply rounding mask at final size
    final = img.resize((px, px), Image.LANCZOS)
    fmask = rounded_mask(px, max(1, int(px * 0.225)))
    out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    out.paste(final, (0, 0), fmask)
    return out


# macOS icon set: (px, filename)
SPECS = [
    (16,   "icon_16.png"),
    (32,   "icon_16@2x.png"),
    (32,   "icon_32.png"),
    (64,   "icon_32@2x.png"),
    (128,  "icon_128.png"),
    (256,  "icon_128@2x.png"),
    (256,  "icon_256.png"),
    (512,  "icon_256@2x.png"),
    (512,  "icon_512.png"),
    (1024, "icon_512@2x.png"),
]

os.makedirs(OUT, exist_ok=True)
cache = {}
for px, name in SPECS:
    if px not in cache:
        cache[px] = make_master(px)
    cache[px].save(os.path.join(OUT, name))
    print("wrote", name, px)

print("done")
