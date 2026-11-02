#!/usr/bin/env python3
"""How empty a page is, in window shots from scripts/harness.sh, sidebar and bar left out.
Usage: uv run --with pillow --with numpy python scripts/measure.py *.png
bare3, bare6: % of pixels within 3 or 6 levels of the page's most common colour.
rawrect: largest rectangle of bare3 pixels, % of the page.
blobrect: the same with content grown 4 px so text reads as a solid block; the number the sweep's targets use."""
import sys

import numpy as np
from PIL import Image, ImageFilter


def largest_rectangle(mask):
    height, width = mask.shape
    heights = np.zeros(width + 1, int)
    best = (0, 0, 0, 0, 0)
    for y in range(height):
        heights[:-1] = np.where(mask[y], heights[:-1] + 1, 0)
        stack = []
        for x in range(width + 1):
            start = x
            while stack and stack[-1][1] >= heights[x]:
                left, tall = stack.pop()
                area = tall * (x - left)
                if area > best[0]:
                    best = (area, left, y - tall + 1, x - left, tall)
                start = left
            stack.append((start, heights[x]))
    return best


for path in sys.argv[1:]:
    shot = Image.open(path)
    # a Retina shot says so in its dpi; sizes below are points, and 1x and 2x shots of one page should compare
    scale = round(shot.info.get("dpi", (72, 72))[0] / 72)
    shot = shot.convert("RGBA")
    shot = shot.resize((shot.width // scale, shot.height // scale), Image.BOX)
    width, height = shot.size
    # the sidebar narrows below a 1040 window; 53 is the bar, 2 the window's rounded foot
    left = 176 if width < 1040 else 216
    page = np.array(shot.crop((left, 53, width, height - 2))).astype(int)
    rgb, alpha = page[..., :3], page[..., 3]
    colours, counts = np.unique(rgb[alpha > 200].reshape(-1, 3), axis=0, return_counts=True)
    ground = colours[counts.argmax()]
    distance = np.abs(rgb - ground).max(axis=2)
    bare3 = (distance <= 3) | (alpha < 200)
    bare6 = (distance <= 6) | (alpha < 200)
    blob = np.array(Image.fromarray((~bare6 * 255).astype("uint8")).filter(ImageFilter.MaxFilter(9))) > 0
    raw_area, *_ = largest_rectangle(bare3)
    blob_area, x, y, w, h = largest_rectangle(~blob)
    print(f"{path.split('/')[-1]:30} {width}x{height} bare3 {bare3.mean() * 100:5.1f} bare6 {bare6.mean() * 100:5.1f} "
          f"rawrect {100 * raw_area / bare3.size:5.1f} blobrect {100 * blob_area / blob.size:5.1f} at x{x + left} y{y + 53} {w}x{h}")
