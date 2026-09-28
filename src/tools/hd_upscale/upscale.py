#!/usr/bin/env python3
"""Upscale a level map by Flux detail transfer (the "frequency-split hybrid").

    result = blur(bicubic upscale of the original) + fine detail of a Flux re-render

The original supplies every colour, shadow and position; Flux supplies only
the grain below 1.5 source pixels. The map is cut into overlapping tiles.
Each tile goes to FLUX.2 [klein] 4B at the output size, with the tile as the
reference image and a prompt asking for the same image, sharper. The detail
layers are feather-blended across the overlaps, so tile seams do not show.

Why this design, measured in notes/headless-3d-to-2d-findings.md:
  - Flux on its own restyles the ground (lawn grass, grey gravel);
    re-adding the original's low frequencies keeps the colours exact.
  - A prompt that names materials ("foliage, rock, water") made Flux invent
    ferns and a pool on bare rock. The conservative prompt below keeps the
    content and still adds grain.

Rendered tiles are cached under OUT/tiles-<params hash>/, so an interrupted
run resumes, and a run with different settings never mixes tiles. Missing
tiles fall back to plain bicubic when assembling, so a partial run still
gives a full-size preview. OUT/manifest.json records the settings, the
software versions, per-tile timings and the checks.

Run it through mise (`mise run hd:setup`, then `MAP=jum2 mise run hd:upscale`);
see README.md next to this file.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import time
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

MODEL = "black-forest-labs/FLUX.2-klein-4B"
# Pinned so a rerun downloads the same weights (Apache-2.0, not gated).
MODEL_REVISION = "e7b7dc27f91deacad38e78976d1f2b499d76a294"
PROMPT = "A sharper, higher-resolution version of this exact image. Do not add, remove or move anything."


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("map", help="map name, e.g. jum2 (level 1); read from IMAGES/<map>.png")
    p.add_argument("--images", default=os.environ.get("DR_ASSETS", "assets") + "/images/im16",
                   help="folder of the extracted 480x3600 maps (default: $DR_ASSETS/images/im16)")
    p.add_argument("--out", default=None, help="output folder (default: ../work/hd/<map>)")
    p.add_argument("--scale", type=int, default=4)
    p.add_argument("--tile", type=int, default=256, help="tile size in source pixels")
    p.add_argument("--overlap", type=int, default=32, help="tile overlap in source pixels")
    p.add_argument("--split", type=float, default=1.5,
                   help="detail/colour split, as a Gaussian sigma in source pixels")
    p.add_argument("--prompt", default=PROMPT)
    p.add_argument("--seed", type=int, default=1, help="the same seed for every tile keeps the grain consistent")
    p.add_argument("--steps", type=int, default=4, help="klein 4B is step-distilled: 4 steps, guidance 1")
    p.add_argument("--guidance", type=float, default=1.0)
    p.add_argument("--limit", type=int, default=None, help="render at most N new tiles this run")
    p.add_argument("--only", nargs="*", default=None, metavar="Y,X",
                   help="render only these tiles, by source origin (e.g. 0,0 896,224)")
    p.add_argument("--assemble-only", action="store_true", help="render nothing; assemble what is cached")
    p.add_argument("--device", default=None, help="torch device (default: cuda if available, else mps, else cpu)")
    p.add_argument("--offload", action="store_true",
                   help="enable_model_cpu_offload(): fits ~12 GB of VRAM, slower")
    return p.parse_args()


def tile_origins(n: int, tile: int, overlap: int) -> list[int]:
    """Start positions covering 0..n with at least `overlap` between neighbours."""
    if n <= tile:
        return [0]
    count = -(-(n - overlap) // (tile - overlap))  # ceil
    return sorted({round(i * (n - tile) / (count - 1)) for i in range(count)})


def lowpass(a: np.ndarray, sigma: float) -> np.ndarray:
    return np.stack([ndi.gaussian_filter(a[..., c], sigma) for c in range(a.shape[-1])], -1)


def ramp(size: int, ramp: int, start: bool, end: bool) -> np.ndarray:
    """1D weight: 1, falling linearly to ~0 over `ramp` px at each flagged end."""
    i = np.arange(size, dtype=np.float32)
    w = np.ones(size, np.float32)
    if start:
        w = np.minimum(w, (i + 1) / ramp)
    if end:
        w = np.minimum(w, (size - i) / ramp)
    return np.clip(w, 1e-3, 1.0)


def feather(size: int, ramp_px: int, top: bool, bottom: bool, left: bool, right: bool) -> np.ndarray:
    """2D tile weight, feathered only on sides that meet a neighbouring tile.

    Neighbours overlap by more than the ramp, so in a full render the weights
    sum to at least 1 everywhere. Where they sum to less, a neighbour is
    missing, and the result fades to plain bicubic instead of cutting off."""
    return np.outer(ramp(size, ramp_px, top, bottom), ramp(size, ramp_px, left, right))[..., None]


def psnr(a: np.ndarray, b: np.ndarray) -> float:
    return float(10 * np.log10(1.0 / max(np.mean((a - b) ** 2), 1e-12)))


class Flux:
    """FLUX.2 [klein] 4B image editing through diffusers, one tile at a time."""

    def __init__(self, device: str | None, offload: bool):
        # AMD (ROCm) builds of torch need two switches on RDNA 3.5 (gfx1151),
        # measured on a Radeon 8060S: flash attention is behind an
        # experimental flag (without it attention at 1024 px needs 8 GB per
        # layer), and MIOpen's convolution search fails outright. Harmless on
        # CUDA. The flag must be set before torch is imported.
        os.environ.setdefault("TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL", "1")
        import torch
        from diffusers import Flux2KleinPipeline

        if torch.version.hip:
            torch.backends.cudnn.enabled = False
        self.torch = torch
        if device is None:
            device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
        self.device = device
        dtype = torch.bfloat16 if device != "cpu" else torch.float32
        self.pipe = Flux2KleinPipeline.from_pretrained(MODEL, revision=MODEL_REVISION, torch_dtype=dtype)
        if offload:
            self.pipe.enable_model_cpu_offload()
        else:
            self.pipe.to(device)
        self.pipe.set_progress_bar_config(disable=True)
        self.device_name = torch.cuda.get_device_name(0) if device.startswith("cuda") else device

    def edit(self, image: Image.Image, prompt: str, seed: int, steps: int, guidance: float) -> Image.Image:
        g = self.torch.Generator(device="cpu").manual_seed(seed)
        return self.pipe(image=image, prompt=prompt, width=image.width, height=image.height,
                         num_inference_steps=steps, guidance_scale=guidance, generator=g).images[0]


def main() -> None:
    a = parse_args()
    src_path = Path(a.images) / f"{a.map}.png"
    src = np.asarray(Image.open(src_path).convert("RGB"))
    H, W, _ = src.shape
    K, T = a.scale, a.tile
    out = Path(a.out or Path(__file__).resolve().parents[3] / "work" / "hd" / a.map).resolve()

    # Everything that changes a rendered tile goes into the cache key.
    params = {"model": MODEL, "revision": MODEL_REVISION, "prompt": a.prompt, "seed": a.seed,
              "steps": a.steps, "guidance": a.guidance, "scale": K, "tile": T}
    key = hashlib.sha256(json.dumps(params, sort_keys=True).encode()).hexdigest()[:10]
    tiles_dir = out / f"tiles-{key}"
    tiles_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = out / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    if manifest.get("key") != key:
        manifest = {"key": key, "tiles": {}}
    manifest["tile_origins"] = {"y": tile_origins(H, T, a.overlap), "x": tile_origins(W, T, a.overlap)}
    manifest.update({"map": a.map, "source": str(src_path), "source_size": [W, H], "params": params,
                     "overlap": a.overlap, "split_sigma_source_px": a.split})

    origins = [(y, x) for y in tile_origins(H, T, a.overlap) for x in tile_origins(W, T, a.overlap)]
    name = lambda y, x: f"{y:04d}_{x:04d}"
    todo = [(y, x) for y, x in origins if not (tiles_dir / f"{name(y, x)}.png").exists()]
    cached = len(origins) - len(todo)
    if a.assemble_only:
        todo = []
    if a.only is not None:
        wanted = {tuple(int(v) for v in s.split(",")) for s in a.only}
        todo = [t for t in todo if t in wanted]
    if a.limit is not None:
        todo = todo[: a.limit]
    print(f"{a.map}: {W}x{H} -> {W * K}x{H * K}, {len(origins)} tiles of {T} px, "
          f"{cached} cached, {len(todo)} to render now; cache {tiles_dir}", flush=True)

    sig = a.split * K
    if todo:
        flux = Flux(a.device, a.offload)
        import diffusers, torch, transformers
        manifest["software"] = {"python": platform.python_version(), "torch": torch.__version__,
                                "diffusers": diffusers.__version__, "transformers": transformers.__version__,
                                "device": flux.device_name}
        for n, (y, x) in enumerate(todo, 1):
            t0 = time.time()
            tile = Image.fromarray(src[y:y + T, x:x + T]).resize((T * K, T * K), Image.BICUBIC)
            hd = flux.edit(tile, a.prompt, a.seed, a.steps, a.guidance).convert("RGB")
            if hd.size != tile.size:
                hd = hd.resize(tile.size, Image.BICUBIC)
            hd.save(tiles_dir / f"{name(y, x)}.png")
            # Layout check: does the raw re-render still match its input at
            # coarse scale? A low score means Flux changed the content there.
            f = lambda im: np.asarray(im, np.float32) / 255
            layout = psnr(lowpass(f(hd), 3 * K), lowpass(f(tile), 3 * K))
            manifest["tiles"][name(y, x)] = {"seconds": round(time.time() - t0, 1), "layout_psnr": round(layout, 2)}
            if flux.device.startswith("cuda"):
                manifest["software"]["peak_vram_gb"] = round(torch.cuda.max_memory_allocated() / 2**30, 1)
            manifest_path.write_text(json.dumps(manifest, indent=2))
            print(f"  tile {n}/{len(todo)} at ({y},{x}): {time.time() - t0:.0f}s, layout {layout:.1f} dB", flush=True)

    # Assemble: blurred bicubic base + feather-blended detail layers.
    base = np.asarray(Image.fromarray(src).resize((W * K, H * K), Image.BICUBIC), np.float32) / 255
    detail = np.zeros_like(base)
    weight = np.zeros(base.shape[:2] + (1,), np.float32)
    ys, xs = sorted({y for y, _ in origins}), sorted({x for _, x in origins})
    have = 0
    for y, x in origins:
        p = tiles_dir / f"{name(y, x)}.png"
        if not p.exists():
            continue
        hd = np.asarray(Image.open(p).convert("RGB"), np.float32) / 255
        wt = feather(T * K, a.overlap * K, y != ys[0], y != ys[-1], x != xs[0], x != xs[-1])
        detail[y * K:(y + T) * K, x * K:(x + T) * K] += (hd - lowpass(hd, sig)) * wt
        weight[y * K:(y + T) * K, x * K:(x + T) * K] += wt
        have += 1
    hybrid = lowpass(base, sig) + detail / np.maximum(weight, 1e-6)
    cover = np.clip(weight, 0.0, 1.0)
    result = hybrid * cover + base * (1 - cover)
    result = (np.clip(result, 0, 1) * 255).round().astype(np.uint8)
    suffix = "" if have == len(origins) else f"_partial{have}of{len(origins)}"
    dst = out / f"{a.map}_{K}x{suffix}.png"
    Image.fromarray(result).save(dst)

    # Faithfulness: shrink the result back and compare with the original.
    back = np.asarray(Image.fromarray(result).resize((W, H), Image.BOX), np.float32) / 255
    orig = src.astype(np.float32) / 255
    checks = {"tiles_rendered": have, "tiles_total": len(origins),
              "shrink_back_psnr": round(psnr(back, orig), 2),
              "shrink_back_mean_abs_levels": round(float(np.abs(back - orig).mean() * 255), 2),
              "mean_colour_shift_levels": round(float(np.abs(back.mean((0, 1)) - orig.mean((0, 1))).max() * 255), 2)}
    layouts = sorted(manifest["tiles"].items(), key=lambda kv: kv[1]["layout_psnr"])
    checks["lowest_layout_tiles"] = [f"{k}: {v['layout_psnr']} dB" for k, v in layouts[:5]]
    manifest["output"] = {"file": dst.name, **checks}
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print(f"wrote {dst} ({W * K}x{H * K}); {have}/{len(origins)} tiles; shrunk back vs original: "
          f"{checks['shrink_back_psnr']} dB, mean error {checks['shrink_back_mean_abs_levels']} levels, "
          f"colour shift {checks['mean_colour_shift_levels']} levels")
    if layouts:
        print("lowest layout scores (inspect these tiles first):", ", ".join(checks["lowest_layout_tiles"]))


if __name__ == "__main__":
    main()
