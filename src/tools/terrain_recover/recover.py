#!/usr/bin/env python3
"""Recover a level project (terrain/project.odin) from an original map.

The originals were top-down renders of 3D terrain; nothing of the 3D
survives (notes/headless-3d-to-2d-findings.md). This rebuilds a starting
point an artist can take into the editor:

  1. Seed: heights from Depth Anything V2 Large. The map is taller than the
     model sees well, so it runs on overlapping 480x900 windows (the size
     the findings measured on); each window's depth, known only up to scale
     and offset, is fitted to the last on their overlap and feathered in.
  2. Height range: the depth is relative, so its range in map pixels is
     fitted by casting shadows at the measured sun and scoring them
     against the shadows detected in the art.
  3. Water from the shipped media mask, which is exact: one water height
     just above the terrain under it.
  4. Unlit colour: the art with its detected shadows divided by the
     measured ambient light, 0.44. Crude; it leaves halos at shadow edges.

This is the Stage 5 proof of concept of notes/level-editor-plan.md; Stage 6
adds shadow refinement, canopy and a better unlit colour. The depth is
cached in OUT/cache/, keyed by model revision, so a rerun only refits.
OUT/manifest.json records the settings, the versions and the fit.

    python recover.py jum2 --mask jut2 --level .../le07.json --images DIR --out DIR
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import time
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

DEPTH_MODEL = "depth-anything/Depth-Anything-V2-Large-hf"
DEPTH_REVISION = "7581137eff8d4e94f6e796d3baea0e9fa79b22d2"
AMBIENT = 0.44  # shadowed / lit ground, measured on cam1
AZIMUTH, ELEVATION = 36.0, 28.0  # measured on cam1's silos
WINDOW, STRIDE = 900, 600
HEIGHT_UNIT = 1 / 32
RANGES = (80, 120, 160, 240, 320, 480, 640, 960)


def luminance(rgb):
    return rgb @ np.array([0.299, 0.587, 0.114], np.float32)


def detect_shadows(rgb, water, ratio=0.66):
    """As the findings (and terrain/analysis.odin): much darker than the lit
    ground around, and not water."""
    Ls = ndi.uniform_filter(luminance(rgb), 3)
    ref = ndi.percentile_filter(Ls, 85, size=81)
    return ndi.binary_opening((Ls / np.maximum(ref, 1e-3) < ratio) & ~water, iterations=1)


def cast_shadows(H, az, el, steps=240):
    """Hard shadows: terrain above the ray toward the sun."""
    a = np.radians(az)
    dx, dy, rise = np.cos(a), -np.sin(a), np.tan(np.radians(el))
    yy, xx = np.mgrid[0 : H.shape[0], 0 : H.shape[1]].astype(np.float32)
    shadow = np.zeros(H.shape, bool)
    top = H.max()
    for k in range(2, steps):
        if (H + rise * k > top).all():
            break
        Hk = ndi.map_coordinates(H, [yy + dy * k, xx + dx * k], order=1, mode="nearest")
        shadow |= Hk > H + rise * k
    return shadow


def iou(a, b, land):
    return (a & b & land).sum() / max(((a | b) & land).sum(), 1)


def model_input(tile: Image.Image):
    """Depth Anything's preprocessing (its image processor needs
    torchvision): the short side to 518, both sides multiples of 14,
    bicubic, ImageNet mean and deviation."""
    import torch

    scale = 518 / min(tile.size)
    size = [max(14, round(v * scale / 14) * 14) for v in tile.size]
    a = np.asarray(tile.resize(size, Image.BICUBIC), np.float32) / 255
    a = (a - np.array([0.485, 0.456, 0.406], np.float32)) / np.array([0.229, 0.224, 0.225], np.float32)
    return torch.from_numpy(a.transpose(2, 0, 1)[None].copy())


def seed_depth(rgb8, cache: Path, device: str):
    """Depth Anything over overlapping windows, stitched: 0..1, high is near."""
    key = hashlib.sha256(rgb8.tobytes() + DEPTH_REVISION.encode()).hexdigest()[:16]
    path = cache / f"depth-{key}.npy"
    if path.exists():
        return np.load(path)
    import torch
    from transformers import AutoModelForDepthEstimation

    model = AutoModelForDepthEstimation.from_pretrained(DEPTH_MODEL, revision=DEPTH_REVISION).to(device).eval()
    h, w = rgb8.shape[:2]
    starts = list(range(0, max(h - WINDOW, 0) + 1, STRIDE))
    if starts[-1] + WINDOW < h:
        starts.append(h - WINDOW)
    out = np.zeros((h, w), np.float32)
    weight = np.zeros((h, 1), np.float32)
    for y0 in starts:
        tile = Image.fromarray(rgb8[y0 : y0 + WINDOW])
        with torch.no_grad():
            d = model(pixel_values=model_input(tile).to(device)).predicted_depth
        d = torch.nn.functional.interpolate(d[:, None], size=(tile.height, tile.width), mode="bicubic", align_corners=False)
        d = d[0, 0].float().cpu().numpy()
        d = (d - d.min()) / max(d.max() - d.min(), 1e-6)
        # Fit to what is already there on the overlap, then feather.
        seen = weight[y0 : y0 + WINDOW, 0] > 0
        if seen.any():
            so_far = (out[y0 : y0 + WINDOW] / np.maximum(weight[y0 : y0 + WINDOW], 1e-6))[seen].ravel()
            A = np.stack([d[seen].ravel(), np.ones(so_far.size)], 1)
            (a, b), *_ = np.linalg.lstsq(A, so_far, rcond=None)
            d = a * d + b
        ramp = np.minimum(np.arange(WINDOW) + 1, WINDOW - np.arange(WINDOW)).astype(np.float32)
        ramp = np.minimum(ramp / (WINDOW - STRIDE), 1)[:, None]
        out[y0 : y0 + WINDOW] += d * ramp
        weight[y0 : y0 + WINDOW] += ramp
        print(f"depth rows {y0}-{y0 + WINDOW}", flush=True)
    out /= np.maximum(weight, 1e-6)
    out = (out - out.min()) / max(out.max() - out.min(), 1e-6)
    cache.mkdir(parents=True, exist_ok=True)
    np.save(path, out)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("map", help="the map's image id, e.g. jum2")
    ap.add_argument("--mask", required=True, help="the media mask's image id, e.g. jut2")
    ap.add_argument("--level", required=True, help="the level's JSON record, embedded in the project")
    ap.add_argument("--images", required=True, help="the folder holding MAP.png and MASK.png")
    ap.add_argument("--out", required=True)
    ap.add_argument("--device", default=None, help="torch device (default cuda when available)")
    args = ap.parse_args()
    if args.device is None:
        import torch

        args.device = "cuda" if torch.cuda.is_available() else "cpu"
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    t0 = time.time()

    rgb8 = np.asarray(Image.open(Path(args.images) / f"{args.map}.png").convert("RGB"))
    rgb = rgb8.astype(np.float32) / 255
    h, w = rgb.shape[:2]
    m = np.asarray(Image.open(Path(args.images) / f"{args.mask}.png").convert("RGB"))
    cell = w // m.shape[1]
    water = np.kron((m[..., 2] == 255) & (m[..., 0] == 0), np.ones((cell, cell), bool))[:h, :w]
    land = ~water
    shadows = out / "cache" / f"shadows-{hashlib.sha256(rgb8.tobytes() + water.tobytes()).hexdigest()[:16]}.npy"
    if shadows.exists():
        detected = np.load(shadows)
    else:
        detected = detect_shadows(rgb, water)
        shadows.parent.mkdir(parents=True, exist_ok=True)
        np.save(shadows, detected)

    depth = seed_depth(rgb8, out / "cache", args.device)

    # The height range whose shadows fit the art's best, at half size.
    half = lambda a: a[::2, ::2]
    fits = {}
    for r in RANGES:
        fits[r] = float(iou(cast_shadows(half(depth) * r / 2, AZIMUTH, ELEVATION), half(detected), half(land)))
        print(f"height range {r:4d} px: cast-shadow IoU {fits[r]:.3f}", flush=True)
    # The shortest range about as good as the best: past some range the
    # score barely moves, and taller only lengthens the small objects'
    # shadows, which depth already makes too tall.
    best = min(r for r in RANGES if fits[r] >= max(fits.values()) - 0.01)
    H = depth * best

    # Water is level, and the stitched depth drifts along the map: take out
    # the drift of the ground under the water, row by row, smoothed.
    if water.any():
        rows = water.sum(1)
        under = np.array([np.percentile(H[y][water[y]], 90) if rows[y] else 0 for y in range(h)], np.float32)
        wsum = ndi.gaussian_filter1d(rows.astype(np.float32), 150, mode="nearest")
        trend = ndi.gaussian_filter1d(under * rows, 150, mode="nearest") / np.maximum(wsum, 1e-6)
        H = H - trend[:, None]
        H -= H.min()

    # Water just above the ground under it; land kept above it.
    level_h = float(np.percentile(H[water], 90)) + 0.5 if water.any() else 0.0
    if water.any():
        H = np.where(water, np.minimum(H, level_h - 0.5), np.maximum(H, level_h + 0.25))
    water_colour = [int(v) for v in np.median(rgb8[water], 0)] if water.any() else [0, 0, 0]

    albedo = np.where(detected[..., None], rgb / AMBIENT, rgb)
    albedo = (np.clip(albedo, 0, 1) * 255 + 0.5).astype(np.uint8)

    level = json.loads(Path(args.level).read_text())
    level["lighting"] = {
        "sun_azimuth_degrees": AZIMUTH,
        "sun_elevation_degrees": ELEVATION,
        "sun_colour": [255, 255, 255],
        "ambient_colour": [255, 255, 255],
        "ambient": AMBIENT,
        "softness": 3,
    }
    level["water"] = {"height": level_h, "colour": water_colour, "visible": bool(water.any())}
    stem = level.get("id", args.map)
    Image.fromarray(np.clip(H / HEIGHT_UNIT + 0.5, 0, 65535).astype(np.uint16)).save(out / f"{stem}.height.png")
    Image.fromarray(albedo).save(out / f"{stem}.albedo.png")
    project = {
        "format": "deimos-rising.level-project",
        "version": 1,
        "width": w,
        "length": h,
        "height": f"{stem}.height.png",
        "height_unit": HEIGHT_UNIT,
        "albedo": f"{stem}.albedo.png",
        "splat": "",
        "canopy": "",
        "canopy_height": 0,
        "canopy_material": -1,
        "materials": [],
        "cliff": {"material": -1, "from": 0, "to": 0},
        "shore": {"material": -1, "from": 0, "to": 0},
        "level": level,
    }
    (out / f"{stem}.drproj.json").write_text(json.dumps(project, indent=2) + "\n")

    import torch
    import transformers

    manifest = {
        "map": args.map,
        "mask": args.mask,
        "depth_model": DEPTH_MODEL,
        "depth_revision": DEPTH_REVISION,
        "window": WINDOW,
        "stride": STRIDE,
        "sun": {"azimuth": AZIMUTH, "elevation": ELEVATION, "ambient": AMBIENT},
        "height_range_fits": fits,
        "height_range": best,
        "water_drift_removed": bool(water.any()),
        "water_height": level_h,
        "detected_shadow_share": float(detected[land].mean()),
        "versions": {
            "python": platform.python_version(),
            "numpy": np.__version__,
            "torch": torch.__version__,
            "transformers": transformers.__version__,
        },
        "device": args.device,
        "seconds": round(time.time() - t0, 1),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {out / (stem + '.drproj.json')} (height range {best} px, water at {level_h:.1f})")


if __name__ == "__main__":
    main()
