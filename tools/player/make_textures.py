"""Converts the Rocketbox man's textures (2048 px TGA) into the game's player textures.

    python3 tools/player/make_textures.py <rocketbox checkout>

Writes godot/assets/player/: colour and normal maps as JPEG, the specular maps turned into roughness,
and the hair cards (with alpha) as PNG. Sizes are picked for phones: the clothes keep 2048 px because
the camera sits right behind them, the head and hair get 1024 px.
"""
import os
import sys

import numpy as np
from PIL import Image

AVATAR = "Male_Adult_07"
PREFIX = "m013"

src = os.path.join(sys.argv[1], "Assets/Avatars/Adults", AVATAR, "Textures")
out = os.path.join(os.path.dirname(__file__), "../../godot/assets/player")
os.makedirs(out, exist_ok=True)


def tex(name):
    return Image.open(os.path.join(src, "%s_%s.tga" % (PREFIX, name)))


def save_jpg(im, name, size, q=90):
    im.convert("RGB").resize((size, size), Image.LANCZOS).save(os.path.join(out, name), quality=q, optimize=True)


def roughness(name, size):
    # the specular maps are dim grey (mean ~9/255): brighter means shinier, so roughness falls with it
    s = np.asarray(tex(name).convert("L")).astype(np.float32) / 255.0
    r = np.clip(0.92 - s * 2.2, 0.35, 0.95)
    Image.fromarray((r * 255).astype(np.uint8)).resize((size, size), Image.LANCZOS).save(
        os.path.join(out, name.replace("specular", "rough") + ".jpg"), quality=90)


save_jpg(tex("body_color"), "body_color.jpg", 2048, 88)
save_jpg(tex("body_normal"), "body_normal.jpg", 2048, 92)
save_jpg(tex("head_color"), "head_color.jpg", 1024, 92)
save_jpg(tex("head_normal"), "head_normal.jpg", 1024, 92)
roughness("body_specular", 1024)
roughness("head_specular", 512)
tex("opacity_color").resize((1024, 1024), Image.LANCZOS).save(os.path.join(out, "hair.png"), optimize=True)
for f in sorted(os.listdir(out)):
    print("%-18s %6d KB" % (f, os.path.getsize(os.path.join(out, f)) // 1024))
