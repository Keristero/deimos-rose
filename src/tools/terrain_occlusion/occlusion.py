#!/usr/bin/env python3
"""Bake a level project's occlusion layer: how open to the sky each map
pixel is, inferred from its colour by FLUX.2 [klein] 4B.

The renderer multiplies the ambient light by this layer (terrain/render.odin).
It is inferred from the colour, not computed from the heights, because the
colour shows what the heights do not have: stones, cracks and ruts, the gaps
between tree crowns, the foot of a bank. Measured on three crops of le07,
le01 and le03 (work/reports/level-recovery.md, chapter 6):

  GTAO (Jimenez et al. 2016) on the heights   sees only the geometry; heavy
                                               on the jungle, whose crowns
                                               stand on exaggerated heights
  Marigold V2 normals of the colour,          adds under a pixel of relief:
  integrated to relief, plus GTAO              AO changed by 0.002
  Flux, from the lit render                    paints the cast shadows in
  Flux, from the colour and the normals        follows the geometry's steps,
                                               less the texture
  Flux, from the colour (this)                 reads the texture; registered
                                               to within a pixel

The colour is the renderer's albedo output, so a painted level and a
recovered one are baked alike. The map is cut into overlapping tiles at most
TILE pixels a side; each goes to Flux with PROMPT, the same seed for every
tile, and the tiles are feather-blended across their overlaps. Flux's white
is open ground (255 on flat sand), so its grey is the layer as it is.

Tiles are cached under OUT/cache/occlusion-<key>/, keyed by the colour and
every setting, so a rerun only reassembles. Writes <stem>.occlusion.png beside
the project, names it in the project, and records the settings in
<stem>.occlusion.json.

    python occlusion.py work/recovered/le07/le07.drproj.json --renderer build/terrain
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "hd_upscale"))
from upscale import MODEL, MODEL_REVISION, Flux, ramp, tile_origins  # noqa: E402

PROMPT = (
    "Turn this top-down aerial game map into a greyscale ambient occlusion pass: "
    "white where the ground is open to the sky, soft dark grey in crevices and cracks, "
    "between rocks and stones, between and under trees, bushes and leaves, and at the "
    "foot of cliffs, banks and walls. No colour, no sunlight, no cast shadows. "
    "Keep every shape exactly where it is."
)
# The crops the prompt was chosen on were 480 x 528; Flux wants multiples of 16.
TILE = 528
OVERLAP = 128
SEED = 0
STEPS = 4


def albedo(renderer: str, project: Path, cache: Path) -> np.ndarray:
    """The project's unlit colour as the renderer draws it, headless."""
    cmd = [renderer, "render", str(project), str(cache / "albedo"), "-output=albedo"]
    if shutil.which("xvfb-run"):
        cmd = ["xvfb-run", "-a", "-s", "-screen 0 1280x1024x24", *cmd]
    subprocess.run(cmd, env=dict(os.environ, DISPLAY="", WAYLAND_DISPLAY=""), check=True, stdout=subprocess.DEVNULL)
    return np.asarray(Image.open(cache / "albedo.png").convert("RGB"))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("project", help="the level project, …/<stem>.drproj.json")
    ap.add_argument("--renderer", required=True, help="the terrain tool (tools/terrain), which draws the colour")
    ap.add_argument("--device", default=None, help="torch device (default: cuda if available)")
    ap.add_argument("--offload", action="store_true", help="enable_model_cpu_offload(): less VRAM, slower")
    args = ap.parse_args()

    project = Path(args.project).resolve()
    out = project.parent
    stem = project.name.removesuffix(".drproj.json")
    cache = out / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    rgb8 = albedo(args.renderer, project, cache)
    h, w = rgb8.shape[:2]
    th, tw = min(TILE, h // 16 * 16), min(TILE, w // 16 * 16)

    params = {"model": MODEL, "revision": MODEL_REVISION, "prompt": PROMPT, "seed": SEED, "steps": STEPS, "tile": [th, tw]}
    key = hashlib.sha256(rgb8.tobytes() + json.dumps(params, sort_keys=True).encode()).hexdigest()[:16]
    tiles = cache / f"occlusion-{key}"
    tiles.mkdir(exist_ok=True)

    ys, xs = tile_origins(h, th, OVERLAP), tile_origins(w, tw, OVERLAP)
    flux, timings = None, []
    total = np.zeros((h, w), np.float32)
    weight = np.zeros((h, w), np.float32)
    for y0 in ys:
        for x0 in xs:
            path = tiles / f"{y0:05d}_{x0:05d}.png"
            if not path.exists():
                if flux is None:
                    flux = Flux(args.device, args.offload)
                t0 = time.time()
                tile = Image.fromarray(rgb8[y0 : y0 + th, x0 : x0 + tw])
                flux.edit(tile, PROMPT, SEED, STEPS, 1.0).convert("L").save(path)
                timings.append(time.time() - t0)
                print(f"occlusion tile {y0},{x0}: {timings[-1]:.1f} s", flush=True)
            g = np.asarray(Image.open(path).convert("L"), np.float32) / 255
            f = np.outer(ramp(th, OVERLAP // 2, y0 > 0, y0 + th < h), ramp(tw, OVERLAP // 2, x0 > 0, x0 + tw < w))
            total[y0 : y0 + th, x0 : x0 + tw] += g * f
            weight[y0 : y0 + th, x0 : x0 + tw] += f
    layer = (np.clip(total / weight, 0, 1) * 255 + 0.5).astype(np.uint8)
    Image.fromarray(layer).save(out / f"{stem}.occlusion.png")

    j = json.loads(project.read_text())
    j["occlusion"] = f"{stem}.occlusion.png"
    project.write_text(json.dumps(j, indent=2) + "\n")

    import diffusers
    import torch

    (out / f"{stem}.occlusion.json").write_text(json.dumps({
        **params,
        "overlap": OVERLAP,
        "tiles": len(ys) * len(xs),
        "rendered_this_run": len(timings),
        "seconds_per_tile": float(np.mean(timings)) if timings else None,
        "mean": float(layer.mean()) / 255,
        "device": flux.device_name if flux else None,
        "versions": {"python": platform.python_version(), "torch": torch.__version__, "diffusers": diffusers.__version__},
    }, indent=2) + "\n")
    print(f"wrote {out / f'{stem}.occlusion.png'}: {len(ys) * len(xs)} tiles, mean {layer.mean() / 255:.2f}")


if __name__ == "__main__":
    main()
