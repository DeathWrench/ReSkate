"""Builds the FPV Drone plugin's OSD pictures (contrib/plugins/fpv-drone/images).

The plugin draws its goggle display with pictures and source rectangles (d:image's uv) rather
than a rectangle per font pixel:

  font.png / font.json  the 5x7 pixel font the C++ drone drew (Extension/Skater/drone_font.h),
                        each glyph once filled and once grown by half a pixel for its outline
  static.png            grey specks on clear, for analogue static and snow
  scanlines.png         a dark line every other row
  vignette.png          dark edges fading to clear, as the C++ drone's four bands

Run it from the repository root: python contrib/plugins/tools/build_fpv_drone_images.py
"""
import json
import random
from pathlib import Path

from PIL import Image

OUT = Path(__file__).resolve().parents[1] / "fpv-drone" / "images"

# Each glyph is 7 rows; in a row, bit 4 is the leftmost pixel (drone_font.h).
GLYPHS = {
    "A": [0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11], "B": [0x1e, 0x11, 0x11, 0x1e, 0x11, 0x11, 0x1e],
    "C": [0x0e, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0e], "D": [0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e],
    "E": [0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f], "F": [0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x10],
    "G": [0x0e, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0e], "H": [0x11, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11],
    "I": [0x0e, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0e], "J": [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0c],
    "K": [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11], "L": [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1f],
    "M": [0x11, 0x1b, 0x15, 0x15, 0x11, 0x11, 0x11], "N": [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11],
    "O": [0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e], "P": [0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10, 0x10],
    "Q": [0x0e, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0d], "R": [0x1e, 0x11, 0x11, 0x1e, 0x14, 0x12, 0x11],
    "S": [0x0f, 0x10, 0x10, 0x0e, 0x01, 0x01, 0x1e], "T": [0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
    "U": [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e], "V": [0x11, 0x11, 0x11, 0x11, 0x11, 0x0a, 0x04],
    "W": [0x11, 0x11, 0x11, 0x15, 0x15, 0x1b, 0x11], "X": [0x11, 0x11, 0x0a, 0x04, 0x0a, 0x11, 0x11],
    "Y": [0x11, 0x11, 0x0a, 0x04, 0x04, 0x04, 0x04], "Z": [0x1f, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1f],
    "0": [0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e], "1": [0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e],
    "2": [0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f], "3": [0x1e, 0x01, 0x01, 0x0e, 0x01, 0x01, 0x1e],
    "4": [0x02, 0x06, 0x0a, 0x12, 0x1f, 0x02, 0x02], "5": [0x1f, 0x10, 0x1e, 0x01, 0x01, 0x11, 0x0e],
    "6": [0x0e, 0x10, 0x10, 0x1e, 0x11, 0x11, 0x0e], "7": [0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
    "8": [0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e], "9": [0x0e, 0x11, 0x11, 0x0f, 0x01, 0x02, 0x0c],
    ".": [0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x0c], ":": [0x00, 0x0c, 0x0c, 0x00, 0x0c, 0x0c, 0x00],
    "%": [0x19, 0x19, 0x02, 0x04, 0x08, 0x13, 0x13], "/": [0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10],
    "-": [0x00, 0x00, 0x00, 0x1f, 0x00, 0x00, 0x00], "+": [0x00, 0x04, 0x04, 0x1f, 0x04, 0x04, 0x00],
    "(": [0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02], ")": [0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08],
}
ORDER = "".join(GLYPHS)

TEXEL = 6          # texels a font pixel
CELL_W, CELL_H = 6 * TEXEL, 8 * TEXEL  # a glyph's 5 x 7 with half a pixel all round for the outline
PAD = 1            # clear texels round each cell, so filtering never reads the next one
COLUMNS = 13


def font():
    cells = 2 * len(ORDER)
    rows = (cells + COLUMNS - 1) // COLUMNS
    pitch_w, pitch_h = CELL_W + 2 * PAD, CELL_H + 2 * PAD
    image = Image.new("RGBA", (COLUMNS * pitch_w, rows * pitch_h), (255, 255, 255, 0))
    pixels = image.load()
    half = TEXEL // 2
    for outline in (False, True):
        for index, ch in enumerate(ORDER):
            cell = index + (len(ORDER) if outline else 0)
            x0 = (cell % COLUMNS) * pitch_w + PAD
            y0 = (cell // COLUMNS) * pitch_h + PAD
            for r, bits in enumerate(GLYPHS[ch]):
                for c in range(5):
                    if not bits & (1 << (4 - c)):
                        continue
                    grow = half if outline else 0
                    left, top = x0 + half + c * TEXEL - grow, y0 + half + r * TEXEL - grow
                    for y in range(top, top + TEXEL + 2 * grow):
                        for x in range(left, left + TEXEL + 2 * grow):
                            pixels[x, y] = (255, 255, 255, 255)
    image.save(OUT / "font.png", optimize=True)
    w, h = image.size
    (OUT / "font.json").write_text(json.dumps({
        "order": ORDER, "columns": COLUMNS, "cell": [CELL_W, CELL_H], "pad": PAD, "size": [w, h],
        "outline_offset": len(ORDER),
    }, indent=2) + "\n")


def static():
    rng = random.Random(7)
    size = 512
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = image.load()
    for y in range(size):
        for x in range(size):
            if rng.random() < 0.012:
                v = 150 + int(rng.random() * 105)
                pixels[x, y] = (v, v, v, 90 + int(rng.random() * 165))
    image.save(OUT / "static.png", optimize=True)


def scanlines():
    image = Image.new("RGBA", (4, 512), (0, 0, 0, 0))
    pixels = image.load()
    for y in range(0, 512, 2):
        for x in range(4):
            pixels[x, y] = (0, 0, 0, 255)
    image.save(OUT / "scanlines.png", optimize=True)


def vignette():
    size = 256
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = image.load()
    for y in range(size):
        for x in range(size):
            u, v = (x + 0.5) / size, (y + 0.5) / size
            # The C++ drone's bands: 20% in from the sides and 24% from the top and bottom.
            bands = [max(0.0, 1 - u / 0.20), max(0.0, 1 - (1 - u) / 0.20), max(0.0, 1 - v / 0.24), max(0.0, 1 - (1 - v) / 0.24)]
            clear = 1.0
            for b in bands:
                clear *= 1 - b
            pixels[x, y] = (0, 0, 0, int(round((1 - clear) * 255)))
    image.save(OUT / "vignette.png", optimize=True)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    font()
    static()
    scanlines()
    vignette()
    print("wrote", ", ".join(sorted(p.name for p in OUT.iterdir())))


if __name__ == "__main__":
    main()
