"""What the HD textures tools share: the upscaler models, and how an image with
transparency goes through one.

Every job runs on the CPU. The models are small convolutional networks
(spandrel loads them from their published weights), so the whole game's
textures take minutes to an hour, not a GPU.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch
from PIL import Image
from scipy import ndimage as ndi

# name -> (Hugging Face repo, file, licence); None is plain resampling.
MODELS: dict[str, tuple[str, str, str] | None] = {
    "lanczos": None,
    "bicubic": None,
    "realesrgan_x4plus": ("Comfy-Org/Real-ESRGAN_repackaged", "RealESRGAN_x4plus.safetensors", "BSD-3-Clause"),
    "nomos_esrgan": ("Phips/2xNomosUni_esrgan_multijpg", "2xNomosUni_esrgan_multijpg.safetensors", "CC-BY-4.0"),
    "nomos_span": ("Phips/2xNomosUni_span_multijpg", "2xNomosUni_span_multijpg.safetensors", "CC-BY-4.0"),
    "nomos_compact": ("Phips/2xNomosUni_compact_multijpg", "2xNomosUni_compact_multijpg.safetensors", "CC-BY-4.0"),
    "hfa2k_span": ("Phips/2xHFA2k_LUDVAE_SPAN", "2xHFA2k_LUDVAE_SPAN.safetensors", "CC-BY-4.0"),
}


@dataclass
class Upscaler:
    name: str
    model: object | None  # a spandrel ImageModelDescriptor, or None for resampling
    scale: int  # what the network scales by (the result is brought to 2x)


def load(name: str) -> Upscaler:
    spec = MODELS[name]
    if spec is None:
        return Upscaler(name, None, 2)
    from huggingface_hub import hf_hub_download
    from spandrel import ModelLoader

    path = hf_hub_download(spec[0], spec[1])
    model = ModelLoader().load_from_file(path)
    model.eval()
    return Upscaler(name, model, model.scale)


def bleed(rgb: np.ndarray, alpha: np.ndarray) -> np.ndarray:
    """Fills the transparent pixels with the nearest opaque colour, so the
    network sees no hard edge against black and does not halo the sprite."""
    solid = alpha > 0
    if solid.all() or not solid.any():
        return rgb
    idx = ndi.distance_transform_edt(~solid, return_distances=False, return_indices=True)
    return rgb[idx[0], idx[1]]


def _run(up: Upscaler, rgb: np.ndarray, tile: int = 192, pad: int = 12) -> np.ndarray:
    """rgb: HxWx3 uint8 -> the network's output (H*s)x(W*s)x3 uint8, tiled."""
    h, w, _ = rgb.shape
    s = up.scale
    x = torch.from_numpy(rgb).permute(2, 0, 1).float().div(255)[None]
    out = torch.zeros(1, 3, h * s, w * s)
    with torch.inference_mode():
        for y0 in range(0, h, tile):
            for x0 in range(0, w, tile):
                ya, xa = max(y0 - pad, 0), max(x0 - pad, 0)
                yb, xb = min(y0 + tile + pad, h), min(x0 + tile + pad, w)
                piece = up.model(x[:, :, ya:yb, xa:xb])
                ty0, tx0 = (y0 - ya) * s, (x0 - xa) * s
                th, tw = (min(y0 + tile, h) - y0) * s, (min(x0 + tile, w) - x0) * s
                out[:, :, y0 * s : y0 * s + th, x0 * s : x0 * s + tw] = piece[:, :, ty0 : ty0 + th, tx0 : tx0 + tw]
    return (out[0].permute(1, 2, 0).clamp(0, 1).numpy() * 255 + 0.5).astype(np.uint8)


def upscale(up: Upscaler, img: Image.Image) -> Image.Image:
    """An RGBA or RGB image brought to exactly twice its size. Transparency is
    kept: the colour goes through the network (transparent pixels bled over),
    the alpha is resampled."""
    img = img.convert("RGBA")
    w, h = img.size
    size = (w * 2, h * 2)
    a = img.getchannel("A")
    alpha = a.resize(size, Image.BICUBIC)
    if up.model is None:
        method = Image.LANCZOS if up.name == "lanczos" else Image.BICUBIC
        rgb = img.convert("RGB").resize(size, method)
    else:
        arr = np.asarray(img)
        out = _run(up, bleed(arr[:, :, :3], arr[:, :, 3]))
        rgb = Image.fromarray(out)
        if rgb.size != size:
            rgb = rgb.resize(size, Image.LANCZOS)
    rgb.putalpha(alpha)
    return rgb


def timed(fn, *args):
    t = time.perf_counter()
    r = fn(*args)
    return r, time.perf_counter() - t


def sprite_files(assets: Path) -> list[Path]:
    return sorted((assets / "sprites" / "im08").glob("*.png"))
