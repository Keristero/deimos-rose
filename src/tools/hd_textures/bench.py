#!/usr/bin/env python3
"""Compare 2x upscalers on the game's own art, on the CPU.

The test has an answer key. Each image is shrunk 2x (a box filter), each
upscaler brings it back to the original's size, and the result is scored
against the original: PSNR and SSIM on the pixels that are opaque, which
measure how faithful it is. The sheets in OUT show how it looks, which the
numbers cannot: a model can score well and smear, or score poorly and look
like the sprite did when the artist drew it.

Limits: the art was already low resolution when it was drawn, so shrinking it
tests restoring detail at a finer scale than the real job, 2x of the
original. The ranking is the evidence, the sheets are the check.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image
from skimage.metrics import peak_signal_noise_ratio, structural_similarity

import common


def shrink(img: Image.Image) -> Image.Image:
    """2x smaller by a box filter over premultiplied colour."""
    a = np.asarray(img.convert("RGBA")).astype(np.float32)
    al = a[:, :, 3:4] / 255
    pre = np.concatenate([a[:, :, :3] * al, a[:, :, 3:4]], axis=2)
    h, w = pre.shape[0] // 2 * 2, pre.shape[1] // 2 * 2
    pre = pre[:h, :w].reshape(h // 2, 2, w // 2, 2, 4).mean(axis=(1, 3))
    al = pre[:, :, 3:4] / 255
    rgb = np.where(al > 0, pre[:, :, :3] / np.maximum(al, 1e-6), 0)
    return Image.fromarray(np.concatenate([rgb, pre[:, :, 3:4]], axis=2).clip(0, 255).astype(np.uint8), "RGBA")


def crop_even(img: Image.Image, limit: int) -> Image.Image:
    """The busiest window of at most `limit` px, with even sides."""
    img = img.convert("RGBA")
    a = np.asarray(img.getchannel("A")) > 0
    ys, xs = np.nonzero(a)
    if len(ys) == 0:
        return img.crop((0, 0, 2, 2))
    y0, x0 = ys.min(), xs.min()
    w = min(img.width - x0, limit) // 2 * 2
    h = min(img.height - y0, limit) // 2 * 2
    return img.crop((x0, y0, x0 + w, y0 + h))


def score(truth: Image.Image, got: Image.Image) -> tuple[float, float]:
    t = np.asarray(truth.convert("RGBA")).astype(np.float32)
    g = np.asarray(got.convert("RGBA")).astype(np.float32)
    mask = t[:, :, 3] > 127
    if mask.sum() < 16:
        return float("nan"), float("nan")
    al = t[:, :, 3:4] / 255
    grey = 128.0
    tc = t[:, :, :3] * al + grey * (1 - al)
    gc = g[:, :, :3] * al + grey * (1 - al)
    mse = ((t[:, :, :3] - g[:, :, :3]) ** 2)[mask].mean()
    psnr = 10 * np.log10(255 * 255 / max(mse, 1e-9))
    ssim = structural_similarity(tc, gc, channel_axis=2, data_range=255, win_size=7)
    return float(psnr), float(ssim)


def backdrop(img: Image.Image, zoom: int) -> Image.Image:
    bg = Image.new("RGBA", img.size, (48, 52, 60, 255))
    bg.alpha_composite(img.convert("RGBA"))
    return bg.resize((img.width * zoom, img.height * zoom), Image.NEAREST)


def sheet(rows: list[tuple[str, dict[str, Image.Image]]], names: list[str], path: Path, zoom: int = 3, win: int = 96) -> None:
    """One row a sample: the original, then every upscaler, over a dark ground."""
    cols = ["original"] + names
    panels = []
    for _, imgs in rows:
        ref = imgs["original"]
        cx, cy = max((ref.width - win) // 2, 0), max((ref.height - win) // 2, 0)
        w, h = min(win, ref.width), min(win, ref.height)
        panels.append([backdrop(imgs[c].crop((cx, cy, cx + w, cy + h)), zoom) for c in cols])
    pw, ph = win * zoom, win * zoom
    out = Image.new("RGB", (len(cols) * (pw + 4), len(rows) * (ph + 4)), (0, 0, 0))
    for r, row in enumerate(panels):
        for c, p in enumerate(row):
            out.paste(p.convert("RGB"), (c * (pw + 4), r * (ph + 4)))
    out.save(path)
    print("wrote", path, "columns:", ", ".join(cols))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--assets", required=True, type=Path)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--count", type=int, default=24, help="sprites in the sample")
    p.add_argument("--limit", type=int, default=160, help="largest sample window, in px")
    p.add_argument("--models", nargs="*", default=list(common.MODELS))
    p.add_argument("--sheet-rows", type=int, default=6)
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    files = common.sprite_files(args.assets)
    pick = [files[int(i)] for i in np.linspace(0, len(files) - 1, args.count)]
    samples: list[tuple[str, Image.Image]] = []
    for f in pick:
        im = crop_even(Image.open(f), args.limit)
        if im.width >= 32 and im.height >= 32:
            samples.append((f.stem, im))
    # A piece of a level map and a menu backdrop: ground and interface art.
    for rel in ("images/im16/back.png",):
        f = args.assets / rel
        if f.exists():
            im = Image.open(f).convert("RGBA")
            samples.append((f.stem, im.crop((0, 0, min(im.width, 192) // 2 * 2, min(im.height, 192) // 2 * 2))))
    print(f"{len(samples)} samples; threads:", __import__("torch").get_num_threads())

    results: dict[str, dict] = {}
    shown: dict[str, dict[str, Image.Image]] = {name: {"original": im} for name, im in samples}
    for name in args.models:
        up = common.load(name)
        psnrs, ssims, seconds, pixels = [], [], 0.0, 0
        for sname, truth in samples:
            small = shrink(truth)
            got, dt = common.timed(common.upscale, up, small)
            got = got.resize(truth.size) if got.size != truth.size else got
            ps, ss = score(truth, got)
            psnrs.append(ps)
            ssims.append(ss)
            seconds += dt
            pixels += small.width * small.height
            shown[sname][name] = got
        results[name] = {
            "psnr": float(np.nanmean(psnrs)),
            "ssim": float(np.nanmean(ssims)),
            "seconds_per_megapixel_in": seconds / (pixels / 1e6),
            "licence": (common.MODELS[name] or ("", "", "n/a"))[2],
        }
        r = results[name]
        print(f"{name:20s} PSNR {r['psnr']:.2f}  SSIM {r['ssim']:.4f}  {r['seconds_per_megapixel_in']:.1f} s/MP  [{r['licence']}]")
    (args.out / "scores.json").write_text(json.dumps(results, indent=2))

    rows = [(n, shown[n]) for n, _ in samples][:: max(len(samples) // args.sheet_rows, 1)][: args.sheet_rows]
    sheet(rows, args.models, args.out / "sheet.png")


if __name__ == "__main__":
    main()
