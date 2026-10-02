#!/usr/bin/env python3
"""Recover a level project (terrain/project.odin) from an original map.

The originals were top-down renders of 3D terrain; nothing of the 3D
survives (notes/headless-3d-to-2d-findings.md). This rebuilds a starting
point an artist can take into the editor:

  1. Seed: heights from Marigold V2 depth (the findings' best: shadow IoU
     0.55 against Depth Anything V2 Large's 0.50, which is the fallback,
     --seed depth-anything). The map is taller than the models see well,
     so they run on overlapping 480x900 windows (the size the findings
     measured on); each window's depth, known only up to scale and offset,
     is fitted to the last on their overlap and feathered in. Marigold V2
     runs in its own checkout (terrain:marigold-setup), as its authors'
     scripts/infer.py.
  2. Height range: the depth is relative, so its range in map pixels is
     fitted by casting shadows at the measured sun and scoring them
     against the shadows detected in the art.
  3. Refinement: smooth offsets fitted, through a differentiable render,
     so the heights' shadows match the detected ones (refine()).
  4. Water from the shipped media mask, which is exact to its 5 px cells,
     moved to the art's shoreline by colour within a cell of their edge
     (shoreline()): one water height just above the terrain under it.
  5. Unlit colour: the art divided by the renderer's light at the art's
     sun, slope term and all, with the heights' cast shadow counted as far
     as the art is in shadow (sunlight(), unlit()).
  6. Canopy: CLIPSeg's "trees" says where it is (canopy_mask()); the
     heights are split there into a smooth ground and the canopy's cover
     above it, losslessly (split_canopy()), so it can be edited as
     vegetation and the render is unchanged.
  7. Water layer: the art's water is translucent, the sand showing
     through at the shore. Its opacity is fitted per pixel against the
     land carried in from the shore and the deep water's own colour
     (water_opacity()); the layer holds that colour, the art's grain and
     all, over the bed as the renderer lights it, and the colour under the
     water becomes the unlit bed (water_layer()). The renderer draws the
     layer over the bed, its surface unshadowed as the originals' is.
  8. Relight (--relight, terrain:relight), after terrain:occlusion has
     baked the occlusion from this colour: the layer fitted to the art
     (fit_occlusion(), occlusion_floor()), and steps 5 and 7 again with it
     in the light. No model runs.

This is Stage 6 of notes/level-editor-plan.md; terrain:recover-all runs it
on all 12 levels.

The unlit colour matters only for relighting the originals faithfully: a
new level's colour is painted unlit. Tried on le07 (and on a shadowed
256 px tile of each of cam1, jum2, ism1 and inm2), scored by the share of
the detected shadow still detected afterwards and by its light against
the lit ground's (the art: 1.0 and 0.30):

  the detected shadows divided by 0.44        0.40, 0.68: canopy gaps
                                               turn to bright speckle
  the art divided by the rendered light        0.59, 0.50: brightens lit
                                               ground (12%) where the
                                               heights cast false shadows
  both: the rendered light, in the detected    0.50, 0.53: lit ground as
  shadows only                                 it was, no speckle; but the
                                               slopes are shaded twice
                                               (le01 renders at shadow IoU
                                               0.709)
  as above, and the slope term everywhere      le01 at 0.922, shadow light
  (this)                                       0.43 as the art's
  Marigold IID's shading                       0.83, 0.37 over the whole
                                               map (good on the tiles
                                               only, at 3x its scale)
  Flux 2 [klein] 4B edits, 12 prompts          keep the scene only where
                                               they keep the shadows

What stays dark is mostly canopy, dark in its own colour, and the shadows
the heights do not cast.

For the canopy, k-means on colour and texture (the findings') could not
tell grass from jungle, nor cam1's autumn trees from its cliffs, without a
rule per map; one CLIPSeg prompt finds them all.

The depth and the canopy are cached in OUT/cache/, keyed by model
revisions, so a rerun only refits.
OUT/manifest.json records the settings, the versions and the fit.

    python recover.py jum2 --mask jut2 --level .../le07.json --images DIR --out DIR
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import time
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

DEPTH_MODEL = "depth-anything/Depth-Anything-V2-Large-hf"
DEPTH_REVISION = "7581137eff8d4e94f6e796d3baea0e9fa79b22d2"
CANOPY_MODEL = "CIDAS/clipseg-rd64-refined"
CANOPY_REVISION = "999e0328d9e10b484360c477313983f9afdd7050"
CANOPY_PROMPT = "trees"
# A tree crown's radius, in map pixels: le07's palms are about 30-40 across.
CROWN = 20
AMBIENT = 0.44  # shadowed / lit ground, measured on cam1
# The sun: azimuth measured on cam1's silos; elevation fitted on le07 (the
# silos said about 28, but at 40 the shadows fit as well and their darkness
# matches the art's). data.LIGHTING_MEASURED.
AZIMUTH, ELEVATION = 36.0, 40.0
WINDOW, STRIDE = 900, 600
HEIGHT_UNIT = 1 / 32
RANGES = (80, 120, 160, 240, 320, 480, 640, 960)
# The refinement: Adam steps and rate, the offset grids (1/N of the
# half-size map), the sun ray's steps (half-size pixels), the weight of the
# curvature along the sun, and of the shading's fit to the art's light. That
# fit (the findings' 0.5) is off: it explains the painted colour as slopes,
# banding le07's clearings across the sun, for no gain in shadow IoU.
REFINE_ITERS, REFINE_LR = 300, 1.0
REFINE_GRIDS = (16, 8, 4)
REFINE_STEPS = 120
REFINE_CURVATURE = 1.0
REFINE_SHADING = 0.0
# The water, as translucent (water_opacity()): past WATER_DEEP map pixels
# from the shore it is deep, and its own colour is the lit deep water's,
# smoothed over WATER_REACH.
WATER_DEEP = 12
WATER_REACH = 48
# The art's shadows, by their light against the lit ground's (shadow_ratio()):
# detected below SHADOW_DETECTED (the findings'), lit above SHADOW_LIT, the
# lit ground's taken over SHADOW_WINDOW px and, for shadow_weight(), also
# over SHADOW_WIDE.
SHADOW_DETECTED = 0.66
SHADOW_LIT = 0.9
SHADOW_WINDOW = 81
SHADOW_WIDE = 241
# fit_occlusion(): the reach, in map pixels, of the occlusion's mean inside
# and beside the art's shadows.
OCCLUSION_REACH = 24


def luminance(rgb):
    return rgb @ np.array([0.299, 0.587, 0.114], np.float32)


def shoreline(rgb8, water, cell):
    """The media mask's water, moved to the art's own shoreline. The mask is
    exact to its cells only, so it steps along every shore. Within a cell
    of its edge, each pixel is taken as water where its colour (Lab, blurred
    a little) is nearer the water's around it than the land's, both the
    local means of pixels more than a cell from the edge; the choice is
    then smoothed. Farther out the mask is kept as it is."""
    from skimage.color import rgb2lab

    lab = rgb2lab(rgb8).astype(np.float32)
    inside = ndi.distance_transform_edt(water)
    outside = ndi.distance_transform_edt(~water)
    band = ((inside > 0) & (inside <= cell)) | ((outside > 0) & (outside <= cell))

    def around(known):
        wt = ndi.gaussian_filter(known.astype(np.float32), 2 * cell)
        return np.dstack([ndi.gaussian_filter(np.where(known, lab[..., c], 0), 2 * cell) for c in range(3)]) / np.maximum(wt, 1e-6)[..., None]

    near = np.dstack([ndi.gaussian_filter(lab[..., c], 1.5) for c in range(3)])
    wet = np.linalg.norm(near - around(inside > cell), axis=2) < np.linalg.norm(near - around(outside > cell), axis=2)
    return np.where(band, ndi.gaussian_filter(wet.astype(np.float32), 2.0) > 0.5, water)


def water_opacity(rgb, water):
    """How opaque the art's water is, 0..1 per pixel. Each water pixel is
    taken as s * ((1 - A) * bed + A * W): the bed is the land's colour at
    the shore carried in, W the water's own colour (the lit deep water's,
    slowly varying), A the opacity and s a brightness, which takes up the
    art's grain and the bed's shadows. A and s are fitted per pixel (least
    squares over A in steps of 0.02, s in closed form), and A smoothed a
    little. The originals' water is mostly opaque, the sand showing through
    only in a band at the shore, and its surface takes no cast shadow:
    where the recovered heights shade 52% of le01's water, its s is 0.99."""
    inside = ndi.distance_transform_edt(water)
    shore = ~water & (ndi.distance_transform_edt(~water) <= 4)
    bed = np.dstack([ndi.gaussian_filter(fill(rgb[..., c], shore), 3) for c in range(3)])
    deep = water & (inside > WATER_DEEP)
    L = ndi.gaussian_filter(luminance(rgb), 1.5)
    lit = deep & (L > 0.8 * ndi.maximum_filter(np.where(deep, L, 0), 41))
    wt = ndi.gaussian_filter(lit.astype(np.float32), WATER_REACH)
    W = np.dstack([fill(ndi.gaussian_filter(np.where(lit, rgb[..., c], 0), WATER_REACH) / np.maximum(wt, 1e-6), wt > 0.02) for c in range(3)])
    ys, xs = np.nonzero(water)
    a, b, w = rgb[ys, xs], bed[ys, xs], W[ys, xs]
    best = np.full(len(ys), np.inf, np.float32)
    A = np.zeros(len(ys), np.float32)
    for t in np.linspace(0, 1, 51, dtype=np.float32):
        m = (1 - t) * b + t * w
        s = np.clip((a * m).sum(1) / np.maximum((m * m).sum(1), 1e-9), 0, 1.5)
        r = ((a - s[:, None] * m) ** 2).sum(1)
        take = r < best
        best[take], A[take] = r[take], t
    Am = np.zeros(water.shape, np.float32)
    Am[ys, xs] = A
    wf = ndi.gaussian_filter(water.astype(np.float32), 1.0)
    return np.where(water, ndi.gaussian_filter(Am, 1.0) / np.maximum(wf, 1e-6), 0)


def water_layer(rgb, unlit_rgb, water, A, bed_light):
    """The water layer the renderer draws over the bed (terrain/render.odin),
    and the bed. The bed, for the colour under the water, is the unlit land
    at the shore carried in. The layer's RGB is the water's own colour,
    grain and all, and its A the opacity, so that (1 - A) * bed * bed_light
    + A * RGB is the art again: its surface is lit alike everywhere, and
    bed_light is the light the renderer gives the bed (bed_light()). Fitted
    against the carried lit land instead, the shallows showed a tan band
    where the renderer shades the bed and the art did not: the error in
    the first water pixel was 14-20 (of 255) on le01, le03 and le11, and is
    now 1-3.5 (D59). All 0..1."""
    shore = ~water & (ndi.distance_transform_edt(~water) <= 4)
    bed = np.dstack([ndi.gaussian_filter(fill(unlit_rgb[..., k], shore), 3) for k in range(3)])
    rgb = np.clip((rgb - (1 - A[..., None]) * bed * bed_light[..., None]) / np.maximum(A, 0.05)[..., None], 0, 1)
    return np.dstack([np.where(water[..., None], rgb, 0), np.where(water, A, 0)]), bed


def shadow_ratio(rgb, size=SHADOW_WINDOW):
    """Each pixel's light against the lit ground's around it: the 85th
    percentile over `size` px, as the findings (and terrain/analysis.odin)
    at 81. A wider window is taken at a quarter of the size, as the filter
    is slow."""
    Ls = ndi.uniform_filter(luminance(rgb), 3)
    if size <= SHADOW_WINDOW:
        ref = ndi.percentile_filter(Ls, 85, size=size)
    else:
        ref = ndi.zoom(ndi.percentile_filter(Ls[::4, ::4], 85, size=size // 4), 4, order=1)[: Ls.shape[0], : Ls.shape[1]]
    return Ls / np.maximum(ref, 1e-3)


def detect_shadows(ratio, water):
    """As the findings: much darker than the lit ground around (below
    SHADOW_DETECTED of it), and not water."""
    return ndi.binary_opening((ratio < SHADOW_DETECTED) & ~water, iterations=1)


def shadow_weight(ratio, wide, detected):
    """How far the art is in shadow, 0..1: all of it where detected, none
    where it is as light as the lit ground's SHADOW_LIT, and between the
    two in proportion. unlit() counts the renderer's cast shadow by this.
    A shadow's edge in the art is soft, and the detection's cut misses it;
    counted as lit there, the rendered shadow drew it dark, a line along
    most shadows. And a shadow as wide as the detection's window darkens
    the lit ground it is measured against: at the foot of le01's cliffs
    the art reads 0.83-1.03 of it, in shadow. So the light is the lower of
    the ratio over the window and over SHADOW_WIDE (`wide`). Only where
    the renderer casts a shadow does this count: dark ground in the sun is
    lit whatever it reads (D59)."""
    soft = np.clip((SHADOW_LIT - np.minimum(ratio, wide)) / (SHADOW_LIT - SHADOW_DETECTED), 0, 1)
    return np.where(detected, 1.0, soft).astype(np.float32)


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


def refine(H, detected, land, rgb, device, az, el, floor, iters=REFINE_ITERS, curvature=REFINE_CURVATURE, shading=REFINE_SHADING, log=print):
    """Heights changed so that their shadows match the detected ones, at
    half size (the findings' refinement): a differentiable render, the sun
    ray's horizon as a soft maximum over its steps and Lambert shading, is
    fitted by Adam to the detected shadows and to the art's light.

    Per pixel it cheats, carving thin walls along the sun that cast just
    the shadows wanted, so the change is only smooth offsets, on grids of
    1/16, 1/8 and 1/4 of the half-size map, and its curvature along the sun
    direction is penalised. The water's bed is left as it is, and the land
    kept at or above `floor`. Returns the new heights at full size and each
    step's scores."""
    import torch
    import torch.nn.functional as F

    half = lambda a: torch.tensor(np.ascontiguousarray(a[::2, ::2]), device=device)
    H0 = half(H.astype(np.float32)) / 2  # half-size pixels
    obs, lnd, lum = half(detected).float(), half(land), half(luminance(rgb))
    h, w = H0.shape
    a = np.radians(az)
    dx, dy, rise = float(np.cos(a)), float(-np.sin(a)), float(np.tan(np.radians(el)))
    ks = torch.arange(1, REFINE_STEPS + 1, dtype=torch.float32, device=device)
    yy, xx = torch.meshgrid(torch.arange(h, dtype=torch.float32, device=device), torch.arange(w, dtype=torch.float32, device=device), indexing="ij")
    grid = torch.stack([(xx[None] + dx * ks[:, None, None]) / (w - 1) * 2 - 1, (yy[None] + dy * ks[:, None, None]) / (h - 1) * 2 - 1], -1)
    e = np.radians(el)
    sun = torch.tensor([np.cos(a) * np.cos(e), -np.sin(a) * np.cos(e), np.sin(e)], dtype=torch.float32, device=device)

    def render(H, tau=0.7):
        Hs = F.grid_sample(H[None, None].expand(REFINE_STEPS, 1, h, w), grid, mode="bilinear", padding_mode="border", align_corners=True)[:, 0]
        horizon = Hs - ks[:, None, None] * rise - H[None]  # > 0: the ray is blocked
        m = tau * torch.logsumexp(horizon / tau, 0)
        shadow = torch.sigmoid(m / 0.5)
        gy, gx = torch.gradient(H)
        n = torch.stack([-gx, -gy, torch.ones_like(H)], -1)
        lam = ((n / n.norm(dim=-1, keepdim=True)) @ sun).clamp(min=0)
        return shadow, AMBIENT + (1 - AMBIENT) * lam * (1 - shadow), horizon.amax(0) > 0

    def along_sun(d):
        """The second derivative along the sun direction."""
        dyy = d[2:, 1:-1] - 2 * d[1:-1, 1:-1] + d[:-2, 1:-1]
        dxx = d[1:-1, 2:] - 2 * d[1:-1, 1:-1] + d[1:-1, :-2]
        dxy = (d[2:, 2:] - d[2:, :-2] - d[:-2, 2:] + d[:-2, :-2]) / 4
        return dx * dx * dxx + 2 * dx * dy * dxy + dy * dy * dyy

    def corr(a, b):
        a, b = a - a.mean(), b - b.mean()
        return (a * b).sum() / (a.norm() * b.norm() + 1e-9)

    offsets = [torch.zeros(1, 1, max(h // f, 2), max(w // f, 2), device=device, requires_grad=True) for f in REFINE_GRIDS]
    opt = torch.optim.Adam(offsets, lr=REFINE_LR)
    up = lambda o: F.interpolate(o, size=(h, w), mode="bicubic", align_corners=True)[0, 0]
    # Only the land moves, and not below the floor.
    moved = lambda d: torch.where(lnd, torch.clamp(H0 + d, min=floor / 2), H0)
    history = []
    for it in range(iters + 1):
        d = sum(up(o) for o in offsets)
        shadow, shade, hard = render(moved(d))
        l_shadow = F.binary_cross_entropy(shadow[lnd].clamp(1e-4, 1 - 1e-4), obs[lnd])
        l_shade = 1 - corr(shade[lnd], lum[lnd])
        gy, gx = torch.gradient(d)
        l_smooth = (gx**2 + gy**2).mean()
        l_curve = (along_sun(d) ** 2).mean()
        loss = l_shadow + shading * l_shade + 0.02 * l_smooth + curvature * l_curve
        if it % 50 == 0 or it == iters:
            inter = (hard & obs.bool() & lnd).sum().item()
            union = ((hard | obs.bool()) & lnd).sum().item()
            history.append({"step": it, "loss": loss.item(), "iou": inter / max(union, 1), "shade_corr": 1 - l_shade.item(), "curvature": l_curve.item()})
            log(f"refine {it:4d}: cast-shadow IoU {history[-1]['iou']:.3f}, shading correlation {history[-1]['shade_corr']:.3f}, curvature {l_curve.item():.4f}")
        if it == iters:
            break
        opt.zero_grad()
        loss.backward()
        opt.step()
    with torch.no_grad():
        d = sum(up(o) for o in offsets)[None, None] * 2  # full-size pixels
        d = F.interpolate(d, size=H.shape, mode="bicubic", align_corners=True)[0, 0].cpu().numpy()
    return np.where(land, np.maximum(H + d, floor), H), history


def sunlight(normal, shadow, weight, azimuth, elevation):
    """The sun's part of the light the renderer gives the art at the art's
    own sun, from the renderer's own normals and shadow: the slope term
    times the cast shadow, the shadow counted as far as the art is in
    shadow (shadow_weight()). Where the heights cast a shadow the art does
    not have, the art is taken as lit."""
    a, e = np.radians(azimuth), np.radians(elevation)
    sun = np.array([np.cos(a) * np.cos(e), -np.sin(a) * np.cos(e), np.sin(e)], np.float32)
    direct = np.clip(normal @ sun, 0, None) / sun[2]
    return (1 - AMBIENT) * direct * (1 - weight * (1 - shadow))


def unlit(rgb, sun, occlusion=1.0):
    """The art without its light: divided by the light the renderer gives
    it, the ambient times the occlusion plus the sun's part (sunlight()).
    A render at the original sun then gives back the art, and a relight
    does not shade the slopes twice. 0..1 RGB.

    The occlusion is fit_occlusion()'s, no darker than occlusion_floor().
    Left out of the division, the renderer darkened the occluded ground a
    second time: with it, 15-39% of the land drew more than 20% darker
    than the art, mostly in the shadows under cliffs, the occlusion's
    darkest (D59). Where the light is still too little for the art, the
    colour is scaled, not clipped, to 1: clipped a channel at a time, a
    brown under too little light turned grey or teal."""
    light = AMBIENT * occlusion + sun
    return rgb / np.maximum(np.maximum(light, rgb.max(2)), 1e-3)[..., None]


def occlusion_floor(rgb, sun):
    """The least occlusion the art allows: the ambient under it and the sun
    must light the colour, at most 1, to the art's brightest channel. The
    originals had no occlusion, and Flux's darkest (50 of 255 on le01's lit
    banks) would ask the colour to be brighter than white."""
    return np.clip((rgb.max(2) - sun) / AMBIENT, 0, 1)


def bed_light(shadow, occlusion=1.0):
    """The light the renderer gives the bed under the water: its normal is
    straight up, its shadow cast on the water's surface."""
    return AMBIENT * occlusion + (1 - AMBIENT) * shadow


def fit_occlusion(occlusion, detected, land):
    """The occlusion layer (terrain:occlusion) made to agree with the art.
    The originals had none: the art's light across a shadow's edge is the
    ambient alone (0.37-0.47 of the lit ground's; AMBIENT is 0.44). But
    Flux reads the cast shadows still faint in the colour as occlusion: its
    layer is 0.53-0.78 in the art's shadows, 0.82-0.90 on the lit ground
    beside them. Divided out as it is, a relight shows every shadow as a
    bright ghost (le03's colour 1.46 times as bright inside its shadows'
    edges as outside). So inside the shadows the occlusion is divided by
    that offset, the local mean inside over the local mean beside, over
    OCCLUSION_REACH: the crevices within a shadow keep their contrast, its
    whole area does not. On le03 the edge is then 1.04 (8, 24 and 64 px
    were alike). 0..1."""
    inside = (detected & land).astype(np.float32)
    beside = (~detected & land).astype(np.float32)
    mean = lambda w: ndi.gaussian_filter(occlusion * w, OCCLUSION_REACH) / np.maximum(ndi.gaussian_filter(w, OCCLUSION_REACH), 1e-6)
    offset = np.clip(mean(inside) / np.maximum(mean(beside), 1e-3), 0.05, 1)
    return np.where(detected, np.clip(occlusion / offset, 0, 1), occlusion)


def render_layers(renderer: str, project: Path, cache: Path):
    """The renderer's normals (x east, y down the rows, z up) and shadow
    (1 lit) for a project, drawn headless (tools/terrain)."""
    cmd = [renderer, "render", str(project), str(cache / "light"), "-output=all"]
    if shutil.which("xvfb-run"):
        cmd = ["xvfb-run", "-a", "-s", "-screen 0 1280x1024x24", *cmd]
    subprocess.run(cmd, env=dict(os.environ, DISPLAY="", WAYLAND_DISPLAY=""), check=True, stdout=subprocess.DEVNULL)
    n = np.asarray(Image.open(cache / "light.normal.png").convert("RGB"), np.float32) / 255 * 2 - 1
    shadow = np.asarray(Image.open(cache / "light.shadow.png").convert("L"), np.float32) / 255
    return n / np.linalg.norm(n, axis=2, keepdims=True), shadow


def canopy_mask(rgb8, cache: Path, device: str):
    """How likely each pixel is to be tree canopy, 0..1: CLIPSeg asked for
    CANOPY_PROMPT on overlapping square windows the map's width, feathered
    together. It finds cam1's autumn trees and the jungle alike, and leaves
    grass, sand and rock, where k-means on colour and texture could not
    tell grass from jungle or trees from cliffs."""
    h, w = rgb8.shape[:2]
    key = hashlib.sha256(rgb8.tobytes() + CANOPY_REVISION.encode() + CANOPY_PROMPT.encode()).hexdigest()[:16]
    path = cache / f"canopy-{key}.npy"
    if path.exists():
        return np.load(path)
    import torch
    from huggingface_hub import snapshot_download
    from transformers import CLIPSegForImageSegmentation, CLIPSegProcessor

    if torch.version.hip:
        torch.backends.cudnn.enabled = False  # MIOpen's convolutions fail on gfx1151
    files = snapshot_download(CANOPY_MODEL, revision=CANOPY_REVISION, allow_patterns=["*.json", "*.txt", "model.safetensors"])
    proc = CLIPSegProcessor.from_pretrained(files)
    model = CLIPSegForImageSegmentation.from_pretrained(files).to(device).eval()
    side, stride = w, w // 2
    starts = list(range(0, max(h - side, 0) + 1, stride))
    if starts[-1] + side < h:
        starts.append(h - side)
    ramp = np.minimum(np.arange(side) + 1, side - np.arange(side)).astype(np.float32)
    ramp = np.minimum(ramp / (side - stride), 1)[:, None]
    prob = np.zeros((h, w), np.float32)
    weight = np.zeros((h, 1), np.float32)
    for y0 in starts:
        inputs = proc(text=[CANOPY_PROMPT], images=[Image.fromarray(rgb8[y0 : y0 + side])], return_tensors="pt").to(device)
        with torch.no_grad():
            logits = model(**inputs).logits
        p = torch.sigmoid(logits.reshape(1, 1, *logits.shape[-2:]))
        p = torch.nn.functional.interpolate(p, size=(side, w), mode="bilinear", align_corners=False)[0, 0].cpu().numpy()
        prob[y0 : y0 + side] += p * ramp
        weight[y0 : y0 + side] += ramp
    prob /= np.maximum(weight, 1e-6)
    cache.mkdir(parents=True, exist_ok=True)
    np.save(path, prob)
    return prob


def fill(H, known):
    """H where `known`, and elsewhere the known values around, smoothed:
    each pixel from the smallest Gaussian (8 to 512 px) that reaches enough
    of them."""
    out = np.where(known, H, 0).astype(np.float32)
    todo = ~known
    for sigma in (8, 16, 32, 64, 128, 256, 512):
        if not todo.any():
            break
        wt = ndi.gaussian_filter(known.astype(np.float32), sigma)
        val = ndi.gaussian_filter(np.where(known, H, 0).astype(np.float32), sigma) / np.maximum(wt, 1e-9)
        take = todo & (wt > 0.05)
        out[take] = val[take]
        todo &= ~take
    out[todo] = H[known].mean() if known.any() else 0
    return out


def split_canopy(H, canopy, land):
    """The heights as ground and canopy, losslessly. The ground under the
    canopy is the lower of two guesses: filled in from the ground around
    it (a canopy standing above its surroundings), and the heights' own
    lower envelope, a grey opening a crown wide, smoothed (crowns in a
    canopy the refinement lowered below them). The cover is the canopy's
    rise above that ground, over canopy_height (the rise's 99th
    percentile), so ground + cover * canopy_height is H again. Returns the
    ground, the cover (0-255) and canopy_height."""
    trees = (canopy > 0.5) & land
    yy, xx = np.mgrid[-CROWN : CROWN + 1, -CROWN : CROWN + 1]
    envelope = ndi.gaussian_filter(ndi.grey_opening(H, footprint=xx * xx + yy * yy <= CROWN * CROWN), CROWN / 2)
    ground = np.where(trees, np.minimum(H, np.minimum(fill(H, ~trees), envelope)), H)
    rise = (H - ground)[trees]
    top = float(np.percentile(rise, 99)) if rise.size else 0.0
    if top <= 0:
        return H, np.zeros(H.shape, np.uint8), 0.0
    cover = np.where(trees, np.clip((H - ground) / top, 0, 1), 0)
    cover = (cover * 255 + 0.5).astype(np.uint8)
    return H - cover / 255 * top, cover, top


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


def windows(h):
    """The first rows of the WINDOW-row windows over a map `h` rows long."""
    starts = list(range(0, max(h - WINDOW, 0) + 1, STRIDE))
    if starts[-1] + WINDOW < h:
        starts.append(h - WINDOW)
    return starts


def stitch(h, w, parts):
    """Windows' heights, each known only up to scale and offset, into one:
    each fitted to what is already there on the overlap, then feathered.
    0..1, high is near."""
    out = np.zeros((h, w), np.float32)
    weight = np.zeros((h, 1), np.float32)
    for y0, d in parts:
        d = (d - d.min()) / max(d.max() - d.min(), 1e-6)
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
    out /= np.maximum(weight, 1e-6)
    return (out - out.min()) / max(out.max() - out.min(), 1e-6)


def marigold_version(home: Path):
    """The checkout's commit and the weights' snapshots, as installed."""
    commit = subprocess.run(["git", "-C", str(home / "src"), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    ckpt = home / "assets" / "checkpoints"
    return {"commit": commit, **{n: Path(os.path.realpath(ckpt / n)).name for n in ("Marigold-V2", "Qwen-Image-Edit-2509")}}


def seed_marigold(rgb8, cache: Path, home: Path, version):
    """Marigold V2 depth on each window, in its own checkout's pipeline:
    affine log depth, far is large, so height is its negative."""
    h = rgb8.shape[0]
    work = cache / f"marigold-{hashlib.sha256(rgb8.tobytes() + json.dumps(version).encode()).hexdigest()[:16]}"
    starts = windows(h)
    found = lambda: {p.stem: p for p in (work / "out").rglob("predictions_npy/**/*.npy")}
    if len(found()) < len(starts):
        (work / "in").mkdir(parents=True, exist_ok=True)
        for y0 in starts:
            Image.fromarray(rgb8[y0 : y0 + WINDOW]).save(work / "in" / f"w{y0:05d}.png")
        py = home / "venv" / "bin" / "python"
        if not py.exists():
            py = home / "venv" / "Scripts" / "python.exe"
        env = dict(
            os.environ,
            DEPTH_ASSETS_DIR=str(home / "assets"),
            TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL="1",
            PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True",
            HF_HUB_OFFLINE="1",
        )
        subprocess.run(
            [str(py), "scripts/infer.py", "--modality", "depth", "--image_dir", str(work / "in"), "--output_dir", str(work / "out")],
            cwd=home / "src", env=env, check=True,
        )
    npy = found()
    return stitch(h, rgb8.shape[1], [(y0, -np.load(npy[f"w{y0:05d}"]).astype(np.float32).squeeze()) for y0 in starts])


def seed_depth_anything(rgb8, cache: Path, device: str):
    """Depth Anything V2 Large on each window: relative depth, high is near."""
    key = hashlib.sha256(rgb8.tobytes() + DEPTH_REVISION.encode()).hexdigest()[:16]
    path = cache / f"depth-{key}.npy"
    if path.exists():
        return np.load(path)
    import torch
    from transformers import AutoModelForDepthEstimation

    model = AutoModelForDepthEstimation.from_pretrained(DEPTH_MODEL, revision=DEPTH_REVISION).to(device).eval()
    parts = []
    for y0 in windows(rgb8.shape[0]):
        tile = Image.fromarray(rgb8[y0 : y0 + WINDOW])
        with torch.no_grad():
            d = model(pixel_values=model_input(tile).to(device)).predicted_depth
        d = torch.nn.functional.interpolate(d[:, None], size=(tile.height, tile.width), mode="bicubic", align_corners=False)
        parts.append((y0, d[0, 0].float().cpu().numpy()))
        print(f"depth rows {y0}-{y0 + WINDOW}", flush=True)
    out = stitch(*rgb8.shape[:2], parts)
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
    ap.add_argument("--renderer", required=True, help="the terrain tool (tools/terrain), which draws the light the colour is divided by")
    ap.add_argument("--seed", choices=("marigold", "depth-anything"), default="marigold", help="the depth model the heights start from")
    ap.add_argument("--marigold", default=os.environ.get("DR_MARIGOLD"), help="Marigold V2's setup (terrain:marigold-setup; default DR_MARIGOLD)")
    ap.add_argument("--device", default=None, help="torch device for the refinement and Depth Anything (default cuda when available)")
    ap.add_argument("--azimuth", type=float, default=AZIMUTH, help="the sun's azimuth, degrees from east toward north")
    ap.add_argument("--elevation", type=float, default=ELEVATION, help="the sun's elevation, degrees")
    ap.add_argument("--iters", type=int, default=REFINE_ITERS, help="refinement steps (0: the seed as it is)")
    ap.add_argument("--curvature", type=float, default=REFINE_CURVATURE, help="weight of the change's curvature along the sun")
    ap.add_argument("--shading", type=float, default=REFINE_SHADING, help="weight of the Lambert shading's fit to the art's light")
    ap.add_argument("--lidar", help="a folder with dem.npy and dsm.npy (elevation.py): the ground is the DEM's, the trees' height the DSM's, and the buildings' roofs Marigold's depth scaled to the DSM's; no shadow fit or refinement")
    ap.add_argument("--relight", action="store_true", help="only the colour, of the project already in --out, divided by its light with its occlusion layer (terrain:occlusion) fitted to the art; no model runs")
    args = ap.parse_args()
    if args.relight:
        return relight(args)
    if args.seed == "marigold" and not (args.marigold and (Path(args.marigold) / "src").is_dir()):
        ap.error("no Marigold V2 setup: run 'mise run terrain:marigold-setup', or pass --seed depth-anything")
    if args.device is None:
        import torch

        args.device = "cuda" if torch.cuda.is_available() else "cpu"
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    t0 = time.time()

    rgb8, water, mask_water, detected, weight, opacity = art(args, out)
    rgb = rgb8.astype(np.float32) / 255
    h, w = rgb.shape[:2]
    land = ~water

    if args.seed == "marigold":
        seed = {"model": "marigold-v2 depth (Log-stage2)", **marigold_version(Path(args.marigold))}
        depth = seed_marigold(rgb8, out / "cache", Path(args.marigold), seed)
    else:
        seed = {"model": DEPTH_MODEL, "revision": DEPTH_REVISION, "device": args.device}
        depth = seed_depth_anything(rgb8, out / "cache", args.device)

    canopy = None
    if args.lidar:
        dem = fill_gaps(np.load(Path(args.lidar) / "dem.npy"))
        dsm = fill_gaps(np.load(Path(args.lidar) / "dsm.npy"))
        if dem.shape != (h, w):
            raise SystemExit(f"the elevation is {dem.shape[::-1]}, the map {(w, h)}: fetch it for the same strip")
        rise = np.maximum(dsm - dem, 0)
        canopy = canopy_mask(rgb8, out / "cache", args.device)
        trees = (canopy > 0.5) & land
        H = dem + building_heights(depth, rise, trees, land)
        fits, best = {}, 0
        seed = {"model": "LINZ LiDAR DEM and DSM, 1 m, with marigold-v2 depth for the roofs", **{k: v for k, v in seed.items() if k != "model"}}
    else:
        # The height range whose shadows fit the art's best, at half size.
        half = lambda a: a[::2, ::2]
        fits = {}
        for r in RANGES:
            fits[r] = float(iou(cast_shadows(half(depth) * r / 2, args.azimuth, args.elevation), half(detected), half(land)))
            print(f"height range {r:4d} px: cast-shadow IoU {fits[r]:.3f}", flush=True)
        # The shortest range about as good as the best: past some range the
        # score barely moves, and taller only lengthens the small objects'
        # shadows, which depth already makes too tall.
        best = min(r for r in RANGES if fits[r] >= max(fits.values()) - 0.01)
        H = depth * best

    # Water is level, and the stitched depth drifts along the map: take out
    # the drift of the ground under the water, row by row, smoothed.
    if water.any() and not args.lidar:
        rows = water.sum(1)
        under = np.array([np.percentile(H[y][water[y]], 90) if rows[y] else 0 for y in range(h)], np.float32)
        wsum = ndi.gaussian_filter1d(rows.astype(np.float32), 150, mode="nearest")
        trend = ndi.gaussian_filter1d(under * rows, 150, mode="nearest") / np.maximum(wsum, 1e-6)
        # Far from any water the weight vanishes and the trend with it, a
        # cliff (le07's, 141 px, at row 2794): hold it at its nearest value.
        known = np.flatnonzero(wsum > 1e-3 * wsum.max())
        trend = np.interp(np.arange(h), known, trend[known])
        H = H - trend[:, None]
        H -= H.min()

    # Water just above the ground under it; land kept above it, before the
    # refinement and after: left free, the bed under the water would rise
    # and take the level up with it.
    level_h = float(np.percentile(H[water], 90)) + 0.5 if water.any() else 0.0
    floor = level_h + 0.25 if water.any() else 0.0
    if water.any():
        H = np.where(water, np.minimum(H, level_h - 0.5), np.maximum(H, floor))

    if args.lidar:
        history = []  # the LiDAR is not fitted to the art's shadows
    else:
        H, history = refine(H, detected, land, rgb, args.device, args.azimuth, args.elevation, floor, args.iters, args.curvature, args.shading)
    water_colour = [int(v) for v in np.median(rgb8[water], 0)] if water.any() else [0, 0, 0]

    if args.lidar:
        # Trees stand as far above the ground as the DSM says; the ground is
        # H (DEM and buildings) and the cover the share of the tallest.
        top = float(np.percentile(rise[trees], 99)) if trees.any() else 0.0
        cover = (np.where(trees, np.clip(rise / max(top, 1e-6), 0, 1), 0) * 255 + 0.5).astype(np.uint8)
        ground, canopy_height = H, top
    else:
        canopy = canopy_mask(rgb8, out / "cache", args.device)
        ground, cover, canopy_height = split_canopy(H, canopy, land)

    level = json.loads(Path(args.level).read_text())
    level["lighting"] = {
        "sun_azimuth_degrees": args.azimuth,
        "sun_elevation_degrees": args.elevation,
        "sun_colour": [255, 255, 255],
        "ambient_colour": [255, 255, 255],
        "ambient": AMBIENT,
        "softness": 3,
    }
    level["water"] = {"height": level_h, "colour": water_colour, "visible": bool(water.any())}
    stem = level.get("id", args.map)
    Image.fromarray(np.clip(ground / HEIGHT_UNIT + 0.5, 0, 65535).astype(np.uint16)).save(out / f"{stem}.height.png")
    Image.fromarray(rgb8).save(out / f"{stem}.albedo.png")  # until unlit() below
    Image.fromarray(cover).save(out / f"{stem}.canopy.png")
    project = {
        "format": "deimos-rising.level-project",
        "version": 1,
        "width": w,
        "length": h,
        "height": f"{stem}.height.png",
        "height_unit": HEIGHT_UNIT,
        "albedo": f"{stem}.albedo.png",
        "splat": "",
        "canopy": f"{stem}.canopy.png",
        "canopy_height": canopy_height,
        "canopy_material": -1,
        "materials": [],
        "cliff": {"material": -1, "from": 0, "to": 0},
        "shore": {"material": -1, "from": 0, "to": 0},
        "level": level,
    }
    (out / f"{stem}.drproj.json").write_text(json.dumps(project, indent=2) + "\n")
    # No occlusion yet: terrain:occlusion bakes it from this colour, and
    # --relight then divides it out.
    colour_layers(args.renderer, out, stem, project, rgb, water, weight, opacity)

    import torch
    import transformers

    manifest = {
        "map": args.map,
        "mask": args.mask,
        "seed": seed,
        "unlit": "divided by the renderer's light at the original sun, its cast shadow as far as the art is in shadow, no occlusion (--relight adds it)",
        "canopy": {"model": CANOPY_MODEL, "revision": CANOPY_REVISION, "prompt": CANOPY_PROMPT, "share_of_land": float((canopy > 0.5)[land].mean()), "height": canopy_height},
        "window": WINDOW,
        "stride": STRIDE,
        "sun": {"azimuth": args.azimuth, "elevation": args.elevation, "ambient": AMBIENT},
        "height_range_fits": fits,
        "height_range": best,
        "water_drift_removed": bool(water.any()),
        "shoreline_moved_share": float((water != mask_water).mean()),
        "water_layer": {"deep": WATER_DEEP, "reach": WATER_REACH, "mean_opacity": float(opacity[water].mean()) if water.any() else None},
        "refinement": {"iters": args.iters, "lr": REFINE_LR, "grids": REFINE_GRIDS, "ray_steps": REFINE_STEPS, "curvature": args.curvature, "shading": args.shading, "history": history},
        "device": args.device,
        "water_height": level_h,
        "detected_shadow_share": float(detected[land].mean()),
        "versions": {
            "python": platform.python_version(),
            "numpy": np.__version__,
            "torch": torch.__version__,
            "transformers": transformers.__version__,
        },
        "seconds": round(time.time() - t0, 1),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {out / (stem + '.drproj.json')} (height range {best} px, water at {level_h:.1f})")


ROOF_MIN_RISE = 2.0  # the DSM above the DEM, in metres, that makes a building
ROOF_BLEND = 0.5  # the share of a roof that is Marigold's shape (the rest is the DSM's)


def fill_gaps(a):
    """An elevation grid with its NaN gaps filled from around them."""
    known = ~np.isnan(a)
    return fill(np.where(known, a, 0), known) if not known.all() else a


def building_heights(depth, rise, trees, land):
    """The buildings' height above the ground: where the DSM stands over the
    DEM and it is not canopy. Marigold's depth gives each roof's shape,
    taken above the ground around the building and scaled so its median is
    the DSM's; the roof is ROOF_BLEND of it and the rest the DSM itself."""
    built = ndi.binary_opening((rise > ROOF_MIN_RISE) & ~trees & land, iterations=1)
    labels, n = ndi.label(built)
    out = np.zeros(depth.shape, np.float32)
    for i, box in enumerate(ndi.find_objects(labels), 1):
        y0, y1 = max(box[0].start - 8, 0), min(box[0].stop + 8, depth.shape[0])
        x0, x1 = max(box[1].start - 8, 0), min(box[1].stop + 8, depth.shape[1])
        mine = labels[y0:y1, x0:x1] == i
        if mine.sum() < 12:
            continue
        ring = ndi.binary_dilation(mine, iterations=6) & ~ndi.binary_dilation(mine, iterations=2) & ~built[y0:y1, x0:x1] & land[y0:y1, x0:x1]
        d, r = depth[y0:y1, x0:x1], rise[y0:y1, x0:x1]
        base = np.median(d[ring]) if ring.any() else d[mine].min()
        shape = np.maximum(d - base, 0)
        target, have = np.median(r[mine]), np.median(shape[mine])
        scaled = shape * np.clip(target / have, 0.2, 5.0) if have > 1e-6 else r
        out[y0:y1, x0:x1][mine] = np.minimum(ROOF_BLEND * scaled[mine] + (1 - ROOF_BLEND) * r[mine], 1.5 * r[mine].max())
    return out


def art(args, out: Path):
    """The map (8-bit RGB), its water moved to the art's shoreline and the
    media mask's as it is, the detected shadows, how far it is in shadow
    (shadow_weight()) and the water's opacity. The light against the lit
    ground's and the opacity are slow, so cached in OUT/cache/ by the art,
    the water and their settings."""
    rgb8 = np.asarray(Image.open(Path(args.images) / f"{args.map}.png").convert("RGB"))
    h, w = rgb8.shape[:2]
    m = np.asarray(Image.open(Path(args.images) / f"{args.mask}.png").convert("RGB"))
    cell = w // m.shape[1]
    mask_water = np.kron((m[..., 2] == 255) & (m[..., 0] == 0), np.ones((cell, cell), bool))[:h, :w]
    water = shoreline(rgb8, mask_water, cell)
    rgb = rgb8.astype(np.float32) / 255

    def cached(name, make):
        path = out / "cache" / f"{name}.npy"
        if path.exists():
            return np.load(path)
        a = make()
        path.parent.mkdir(parents=True, exist_ok=True)
        np.save(path, a)
        return a

    key = hashlib.sha256(rgb8.tobytes() + water.tobytes()).hexdigest()[:16]
    ratio = {size: cached(f"shadow-ratio-{hashlib.sha256(rgb8.tobytes() + repr(size).encode()).hexdigest()[:16]}", lambda: shadow_ratio(rgb, size)) for size in (SHADOW_WINDOW, SHADOW_WIDE)}
    detected = detect_shadows(ratio[SHADOW_WINDOW], water)
    weight = shadow_weight(ratio[SHADOW_WINDOW], ratio[SHADOW_WIDE], detected)
    opacity = cached(f"water-opacity-{hashlib.sha256(key.encode() + repr((WATER_DEEP, WATER_REACH)).encode()).hexdigest()[:16]}", lambda: water_opacity(rgb, water))
    return rgb8, water, mask_water, detected, weight, opacity


def colour_layers(renderer: str, out: Path, stem: str, project: dict, rgb, water, weight, opacity, occlusion=None):
    """The project's colour, divided by the light the renderer gives it
    (unlit()), and its water as a layer over its bed, the bed in the colour
    under it (water_layer()): written beside the project, and the project
    with them. With an occlusion layer, that too, raised on the land to
    occlusion_floor(); returned as written, 0..1."""
    lighting = project["level"]["lighting"]
    normal, shadow = render_layers(renderer, out / f"{stem}.drproj.json", out / "cache")
    sun = sunlight(normal, shadow, weight, lighting["sun_azimuth_degrees"], lighting["sun_elevation_degrees"])
    if occlusion is not None:
        occlusion = np.where(water, occlusion, np.maximum(occlusion, occlusion_floor(rgb, sun)))
        # Rounded up to the 8 bits the renderer reads, so still enough.
        occlusion = np.ceil(np.clip(occlusion, 0, 1) * 255 - 1e-3).astype(np.uint8)
        Image.fromarray(occlusion).save(out / project["occlusion"])
        occlusion = occlusion.astype(np.float32) / 255
    colour = unlit(rgb, sun, 1.0 if occlusion is None else occlusion)
    if water.any():
        layer, bed = water_layer(rgb, colour, water, opacity, bed_light(shadow, 1.0 if occlusion is None else occlusion))
        colour = np.where(water[..., None], bed, colour)
        Image.fromarray((layer * 255 + 0.5).astype(np.uint8), "RGBA").save(out / f"{stem}.water.png")
        project["water"] = f"{stem}.water.png"
    Image.fromarray((colour * 255 + 0.5).astype(np.uint8)).save(out / f"{stem}.albedo.png")
    (out / f"{stem}.drproj.json").write_text(json.dumps(project, indent=2) + "\n")
    return occlusion


def relight(args):
    """--relight: the colour of the project recovered in --out, again, now
    with its occlusion layer divided out as well, the layer fitted to the
    art (fit_occlusion()). The heights, canopy and water stay as they are.
    The fitted layer replaces the project's, and the layer as it was is
    kept in OUT/cache/occlusion-baked.png: a rerun fits that again rather
    than its own last fit, unless the project's layer has changed since
    (a new bake, or an edit), which is then the one fitted. Nothing here
    runs a model."""
    out = Path(args.out)
    t0 = time.time()
    rgb8, water, _, detected, weight, opacity = art(args, out)
    rgb = rgb8.astype(np.float32) / 255
    stem = json.loads(Path(args.level).read_text()).get("id", args.map)
    project = json.loads((out / f"{stem}.drproj.json").read_text())
    manifest_path = out / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    occlusion = None
    if project.get("occlusion"):
        layer = np.asarray(Image.open(out / project["occlusion"]).convert("L"))
        digest = lambda a: hashlib.sha256(a.tobytes()).hexdigest()
        baked = out / "cache" / "occlusion-baked.png"
        last = (manifest.get("relight") or {}).get("occlusion") or {}
        if baked.exists() and last.get("fitted_pixels") == digest(layer):
            layer = np.asarray(Image.open(baked).convert("L"))
        else:
            Image.fromarray(layer).save(baked)
        raw = layer.astype(np.float32) / 255
        occlusion = fit_occlusion(raw, detected, ~water)
    occlusion = colour_layers(args.renderer, out, stem, project, rgb, water, weight, opacity, occlusion)
    fit = None
    if occlusion is not None:
        shade, lit = detected & ~water, ~detected & ~water
        fit = {
            "reach": OCCLUSION_REACH,
            "fitted_pixels": digest((occlusion * 255 + 0.5).astype(np.uint8)),
            "baked": {"in_shadow": float(raw[shade].mean()), "lit": float(raw[lit].mean())},
            "fitted": {"in_shadow": float(occlusion[shade].mean()), "lit": float(occlusion[lit].mean())},
        }
    manifest["relight"] = {"occlusion": fit, "seconds": round(time.time() - t0, 1)}
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"relit {out / (stem + '.drproj.json')}" + (f" (occlusion in the art's shadows {fit['baked']['in_shadow']:.2f} -> {fit['fitted']['in_shadow']:.2f})" if fit else " (no occlusion layer)"))


if __name__ == "__main__":
    main()
