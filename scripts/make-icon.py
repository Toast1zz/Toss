#!/usr/bin/env python3
"""Renders the Toss app icon (Resources/AppIcon.iconset) from code.

A dark frosted squircle with a dot grid, and a white card flicked upward
leaving a mint motion glow. Laid out on Apple's macOS grid: an 824 pt body
centred on a 1024 pt canvas, with a soft drop shadow. Sizes of 32 px and
below use a simplified drawing (no dot grid, larger card) so they stay
legible.

Usage: python3 scripts/make-icon.py [out_dir]   (needs Pillow and numpy)
Then:  iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 2048           # working canvas (2x of the 1024 grid)
U = S / 1024       # one grid unit
BODY = 824 * U
INSET = (S - BODY) / 2


def squircle(size, n=5.0, steps=720):
    """Points of a superellipse filling `size` (close to Apple's continuous corners)."""
    a = size / 2
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = a * math.copysign(abs(c) ** (2 / n), c)
        y = a * math.copysign(abs(s) ** (2 / n), s)
        pts.append((x, y))
    return pts


def body_points(size):
    """Apple-style rounded square: straight sides, corners with a continuous
    (superellipse) curve, corner extent ~22.5% of the side."""
    half = size / 2
    r = size * 0.225 * 1.45          # continuous corners start earlier than a circular radius would
    n = 3.4
    pts = []
    corners = [(1, 1), (-1, 1), (-1, -1), (1, -1)]
    for qi, (sx, sy) in enumerate(corners):
        ccx, ccy = sx * (half - r), sy * (half - r)
        for i in range(91):
            t = (qi * 90 + i) * math.pi / 180
            c, s_ = math.cos(t), math.sin(t)
            x = ccx + r * math.copysign(abs(c) ** (2 / n), c)
            y = ccy + r * math.copysign(abs(s_) ** (2 / n), s_)
            pts.append((x, y))
    return pts


def body_mask():
    m = Image.new("L", (S * 2, S * 2), 0)
    pts = [((INSET + BODY / 2 + x) * 2, (INSET + BODY / 2 + y) * 2) for x, y in body_points(BODY)]
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m.resize((S, S), Image.LANCZOS)


def vertical_gradient(top, bottom):
    t = np.linspace(0, 1, S)[:, None, None]
    arr = (np.array(top)[None, None, :] * (1 - t) + np.array(bottom)[None, None, :] * t)
    arr = np.broadcast_to(arr, (S, S, 3)).astype(np.uint8)
    return Image.fromarray(arr, "RGB").convert("RGBA")


def layer():
    return Image.new("RGBA", (S, S), (0, 0, 0, 0))


def rounded_card(w, h, r, angle, center, fill):
    """A rotated rounded rectangle as its own RGBA layer."""
    pad = int(max(w, h))
    tile = Image.new("RGBA", (pad * 2, pad * 2), (0, 0, 0, 0))
    ImageDraw.Draw(tile).rounded_rectangle(
        (pad - w / 2, pad - h / 2, pad + w / 2, pad + h / 2), radius=r, fill=fill)
    tile = tile.rotate(angle, resample=Image.BICUBIC)
    out = layer()
    out.alpha_composite(tile, (int(center[0] - pad), int(center[1] - pad)))
    return out


def render(simple=False):
    canvas = layer()
    mask = body_mask()

    # Drop shadow under the body.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(mask.point(lambda v: v * 0.42))
    shadow = shadow.transform(shadow.size, Image.AFFINE, (1, 0, 0, 0, 1, -10 * U))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14 * U))
    canvas.alpha_composite(shadow)

    # Body: dark slate, lighter at the top, like frosted glass over a dark desk.
    body = vertical_gradient((60, 66, 78), (24, 28, 35))
    sheen = layer()
    ImageDraw.Draw(sheen).ellipse((INSET - 200 * U, INSET - 420 * U, S - INSET + 200 * U, INSET + 380 * U),
                                  fill=(255, 255, 255, 22))
    body.alpha_composite(sheen.filter(ImageFilter.GaussianBlur(90 * U)))

    cx, cy = 532 * U, 548 * U          # card centre
    if simple:
        cx, cy = 528 * U, 540 * U

    # Dot grid, fading out toward the bottom.
    if not simple:
        dots = layer()
        d = ImageDraw.Draw(dots)
        step, r = 42.5 * U, 4.2 * U
        start = INSET + 44 * U
        y = start
        while y < S - INSET - 30 * U:
            x = start
            fade = max(0.0, 1 - (y - start) / (BODY * 0.78))
            while x < S - INSET - 30 * U:
                d.ellipse((x - r, y - r, x + r, y + r), fill=(170, 185, 205, int(70 * fade)))
                x += step
            y += step
        body.alpha_composite(dots)

    # Mint glow pooled under and behind the card.
    mint = (126, 230, 184)
    glow = layer()
    g = ImageDraw.Draw(glow)
    gx, gy = cx + 20 * U, cy + 150 * U
    g.ellipse((gx - 170 * U, gy - 80 * U, gx + 170 * U, gy + 80 * U), fill=mint + (190,))
    glow = glow.filter(ImageFilter.GaussianBlur(60 * U))
    body.alpha_composite(glow)
    core = layer()
    ImageDraw.Draw(core).ellipse((gx - 80 * U, gy - 34 * U, gx + 80 * U, gy + 34 * U), fill=(170, 245, 210, 200))
    body.alpha_composite(core.filter(ImageFilter.GaussianBlur(30 * U)))

    # Motion arcs sweeping up from the lower left into the card.
    arcs = layer()
    a = ImageDraw.Draw(arcs)
    widths = [42, 34, 26] if not simple else [60, 44]
    for i, wdt in enumerate(widths):
        rad = (300 + i * 58) * U
        ox, oy = cx + 170 * U, cy + 250 * U
        box = (ox - rad - 90 * U, oy - rad, ox + rad - 90 * U, oy + rad)
        alpha = [205, 150, 105][i] if not simple else [190, 120][i]
        a.arc(box, start=190, end=262, fill=mint + (alpha,), width=int(wdt * U))
    arcs = arcs.filter(ImageFilter.GaussianBlur((15 if not simple else 14) * U))
    body.alpha_composite(arcs)

    # The card: a soft shadow, then the white face with a faint bottom edge.
    w, h, rr = (318 * U, 240 * U, 46 * U) if not simple else (390 * U, 296 * U, 60 * U)
    angle = 24
    cshadow = rounded_card(w, h, rr, angle, (cx + 6 * U, cy + 26 * U), (0, 0, 0, 120))
    body.alpha_composite(cshadow.filter(ImageFilter.GaussianBlur(26 * U)))
    edge = rounded_card(w, h, rr, angle, (cx, cy + 5 * U), (196, 204, 212, 255))
    body.alpha_composite(edge)
    face = rounded_card(w, h, rr, angle, (cx, cy), (250, 251, 252, 255))
    # Very light top-to-bottom shading on the face.
    shade = vertical_gradient((255, 255, 255), (232, 236, 240))
    shade.putalpha(face.getchannel("A"))
    body.alpha_composite(shade)
    # Mint light catching the card's lower edge.
    tint = rounded_card(w, h, rr, angle, (cx, cy), mint + (255,))
    tmask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(tmask).ellipse((cx - 260 * U, cy + 40 * U, cx + 200 * U, cy + 330 * U), fill=34)
    tmask = ImageChops.multiply(tmask.filter(ImageFilter.GaussianBlur(40 * U)), face.getchannel("A"))
    tint.putalpha(tmask)
    body.alpha_composite(tint)

    # Clip to the squircle and add a hairline rim.
    body.putalpha(mask)
    canvas.alpha_composite(body)
    rim = layer()
    pts = [(INSET + BODY / 2 + x, INSET + BODY / 2 + y) for x, y in body_points(BODY - 3 * U)]
    ImageDraw.Draw(rim).line(pts + [pts[0]], fill=(255, 255, 255, 34), width=int(2.5 * U))
    rim_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(rim_mask).rectangle((0, 0, S, S / 2), fill=255)
    rim.putalpha(ImageChops.multiply(rim.getchannel("A"), rim_mask.filter(ImageFilter.GaussianBlur(300 * U))))
    canvas.alpha_composite(rim)
    return canvas


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "Resources", "AppIcon.iconset")
    os.makedirs(out, exist_ok=True)
    full, simple = render(False), render(True)
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            src = simple if px <= 32 else full
            img = src.resize((px, px), Image.LANCZOS)
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            img.save(os.path.join(out, name))
    print("wrote", out)


if __name__ == "__main__":
    main()
