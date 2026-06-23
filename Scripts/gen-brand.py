#!/usr/bin/env python3
"""Regenerate all Sudoor brand assets from the master dino+wordmark lockup."""
import os, subprocess, tempfile
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Master lockup (dino + "Sudoor" wordmark, transparent bg). Override with MASTER=...
SRC = os.environ.get("MASTER", os.path.join(REPO, "assets/logo-master.png"))

master = Image.open(SRC).convert("RGBA")

# --- Split dino vs wordmark by column occupancy ---
W, H = master.size
px = master.load()
occ = [any(px[x, y][3] > 30 for y in range(H)) for x in range(W)]
runs = []
s = None
for x, o in enumerate(occ):
    if o and s is None: s = x
    if not o and s is not None: runs.append((s, x - 1)); s = None
if s is not None: runs.append((s, W - 1))
dino_end = runs[0][1]                 # last column of the dino
text_start = runs[1][0]               # first column of "S"
split = (dino_end + text_start) // 2  # gap midpoint

def trim(img):
    bb = img.getbbox()
    return img.crop(bb) if bb else img

def save(img, *paths):
    for p in paths:
        full = os.path.join(REPO, p)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        img.save(full)
        print("wrote", p, img.size)

# --- A. Black lockup (tight crop of the master) ---
lockup_black = trim(master)
save(lockup_black, "assets/logo-black.png", "site/logo-black.png")

# --- B. White-text lockup (dino stays green, wordmark -> white) ---
wl = master.copy()
wpx = wl.load()
for x in range(split, W):
    for y in range(H):
        r, g, b, a = wpx[x, y]
        if a > 0:
            wpx[x, y] = (255, 255, 255, a)
lockup_white = trim(wl)
save(lockup_white, "assets/logo-white.png", "site/logo-white.png")

# --- C. Dino square icon (transparent, padded) ---
dino = trim(master.crop((0, 0, split, H)))
side = max(dino.size)
pad = int(side * 0.12)
canvas = side + pad * 2
dino_sq = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
dino_sq.paste(dino, ((canvas - dino.width) // 2, (canvas - dino.height) // 2), dino)
save(dino_sq.resize((512, 512), Image.LANCZOS),
     "site/logo-brand.png", "site/favicon-color.png")
save(dino_sq.resize((256, 256), Image.LANCZOS),
     "site/favicon.png", "assets/favicon.png")

# --- D. App icon (.icns): dino on a white rounded tile (macOS style) ---
def rounded_tile(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = int(size * 0.225)  # Big Sur squircle-ish radius
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=(255, 255, 255, 255))
    inset = int(size * 0.20)
    avail = size - inset * 2
    scale = avail / max(dino.width, dino.height)
    dd = dino.resize((max(1, round(dino.width * scale)),
                      max(1, round(dino.height * scale))), Image.LANCZOS)
    img.paste(dd, ((size - dd.width) // 2, (size - dd.height) // 2), dd)
    return img

with tempfile.TemporaryDirectory() as td:
    iconset = os.path.join(td, "icon.iconset")
    os.makedirs(iconset)
    for sz in (16, 32, 64, 128, 256, 512, 1024):
        rounded_tile(sz).save(os.path.join(iconset, f"icon_{sz}x{sz}.png"))
        if sz <= 512:
            rounded_tile(sz * 2).save(os.path.join(iconset, f"icon_{sz}x{sz}@2x.png"))
    out = os.path.join(REPO, "assets/AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    print("wrote assets/AppIcon.icns")

# --- E. OG social card (1200x630) ---
def font(path, sz):
    return ImageFont.truetype(path, sz)

SF = "/System/Library/Fonts/SFNS.ttf"
og = Image.new("RGBA", (1200, 630), (10, 10, 10, 255))
d = ImageDraw.Draw(og)
lw = lockup_white.copy()
target_w = 620
lw = lw.resize((target_w, int(target_w * lw.height / lw.width)), Image.LANCZOS)
og.paste(lw, ((1200 - lw.width) // 2, 215), lw)
tag = "Stop babysitting the terminal."
f_tag = font(SF, 34)
tb = d.textbbox((0, 0), tag, font=f_tag)
d.text(((1200 - (tb[2] - tb[0])) // 2, 410), tag, font=f_tag, fill=(150, 150, 150, 255))
url = "sudoor.bar"
f_url = font(SF, 28)
ub = d.textbbox((0, 0), url, font=f_url)
d.text(((1200 - (ub[2] - ub[0])) // 2, 530), url, font=f_url, fill=(255, 85, 0, 255))
save(og.convert("RGB").convert("RGBA"), "site/og.png", "assets/og.png")

print("done. split at x=%d (dino_end=%d, text_start=%d)" % (split, dino_end, text_start))
