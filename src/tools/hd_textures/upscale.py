#!/usr/bin/env python3
"""Make the HD textures plugin's pictures: the game's sprite plates and its
interface images at twice their size.

Every PNG in ASSETS/sprites/im08 and ASSETS/images/im16 goes through the
upscaler bench.py chose (Nomos SPAN, 2x) and is written to OUT/textures/ under
the same relative path, which is how the game finds what replaces what. The
frame rectangles stay the original's: the game draws the plate at its own
size, with more pixels in it. Transparency is kept: the colour goes through
the network with the transparent pixels bled over, the alpha is resampled.

Not here: the level maps (images/im16 of the Classic Levels plugin and the
recovered levels), which the game burns marks into at the map's own
resolution.

Runs on the CPU and resumes: a picture already written by the same model is
skipped.
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

from PIL import Image

import common

MODEL = "nomos_span"


FOLDERS = ("sprites/im08", "images/im16")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--assets", required=True, type=Path)
    p.add_argument("--out", required=True, type=Path, help="the plugin's folder")
    p.add_argument("--model", default=MODEL, choices=[m for m in common.MODELS if common.MODELS[m]])
    p.add_argument("--only", nargs="*", help="file stems, for a quick look")
    args = p.parse_args()

    up = common.load(args.model)
    stamp = f"{args.model} {common.MODELS[args.model][1]}"
    files = [f for sub in FOLDERS for f in sorted((args.assets / sub).glob("*.png")) if not args.only or f.stem in args.only]
    marker = args.out / "textures" / ".model"
    redo = not marker.exists() or marker.read_text() != stamp
    start, pixels = time.time(), 0
    for n, src in enumerate(files):
        rel = src.relative_to(args.assets)
        dst = args.out / "textures" / rel
        if not redo and dst.exists():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        img = Image.open(src).convert("RGBA")
        common.upscale(up, img).save(dst, optimize=True)
        pixels += img.width * img.height
        print(f"[{n + 1}/{len(files)}] {rel} {img.width}x{img.height}  {time.time() - start:.0f} s", flush=True)
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(stamp)
    print(f"{len(files)} pictures, {pixels / 1e6:.2f} MP processed, {time.time() - start:.0f} s")


if __name__ == "__main__":
    main()
