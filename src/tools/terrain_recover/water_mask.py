"""Recover a media mask's water for an aerial map.

An original level ships its water as a mask texture; aerial imagery has none.

With --osm LAT LON (the map's northernmost point, as aerial.py takes it) the
water is OpenStreetMap's: its natural=water and waterway=riverbank ways and
multipolygons, drawn into the map's pixels. recover.py then moves the shores
to the art's own, as it does a mask's. OpenStreetMap is ODbL: credit it.

Without it the water is found by colour. Water is the one surface that is smooth at the scale of a pixel and holds one
colour: seeds are the smooth pixels whose colour is blue-green (b > g > r),
the water's colour is the median of the seeds, and the water is every smooth
pixel near that colour, in regions that hold a seed. Shadowed forest is as
dark but textured, and so is left out.

    water_mask.py MAP.png MASK.png [--preview PREVIEW.png]

writes MASK.png as the media mask recover.py reads (CELL-pixel cells, water
blue with no red, land green).
"""

import argparse
import time
import requests
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi

CELL = 5  # the media mask's cell, in map pixels
WINDOW = 5  # the texture's window, in pixels
SEED_TEXTURE = 0.012  # local standard deviation of the luminance, at a seed
GROW_TEXTURE = 0.018  # and where the water is grown to
GROW_DISTANCE = 12  # Lab distance from the water's colour
MIN_REGION = 1500  # pixels in the smallest water kept


def texture(luma):
    mean = ndi.uniform_filter(luma, WINDOW)
    return np.sqrt(np.maximum(ndi.uniform_filter(luma * luma, WINDOW) - mean * mean, 0))


def water_pixels(rgb8):
    """The water as a boolean array the map's size, and its colour."""
    from skimage.color import rgb2lab

    rgb = rgb8.astype(np.float32) / 255
    luma = rgb @ np.array([0.299, 0.587, 0.114], np.float32)
    tex = texture(luma)
    lab = rgb2lab(rgb8).astype(np.float32)
    blue = (rgb[..., 2] > rgb[..., 1]) & (rgb[..., 1] > rgb[..., 0])
    seeds = blue & (tex < SEED_TEXTURE) & (luma < 0.5)
    seeds = ndi.binary_opening(seeds, iterations=3)
    if seeds.sum() < MIN_REGION:
        return np.zeros(luma.shape, bool), None
    colour = np.median(lab[seeds], 0)
    near = np.linalg.norm(lab - colour, axis=2) < GROW_DISTANCE
    grown = near & (ndi.uniform_filter(tex, 3) < GROW_TEXTURE)
    grown = ndi.binary_closing(ndi.binary_opening(grown, iterations=2), iterations=3)
    labels, n = ndi.label(grown)
    held = np.unique(labels[seeds])
    keep = np.isin(labels, held[held > 0])
    sizes = np.bincount(labels.ravel())
    keep &= (sizes[labels] >= MIN_REGION)
    return ndi.binary_fill_holes(keep), colour


OVERPASS = ("https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter")
OSM_WATER = ['["natural"="water"]', '["waterway"="riverbank"]']


def rings(members):
    """The member ways of a multipolygon joined end to end into rings (lists
    of (lon, lat)); a chain left open is closed as it is."""
    chains = [[(p["lon"], p["lat"]) for p in m["geometry"]] for m in members if m.get("geometry")]
    done = []
    while chains:
        ring = chains.pop()
        while ring[0] != ring[-1]:
            for i, c in enumerate(chains):
                if c[0] == ring[-1]:
                    ring += c[1:]
                elif c[-1] == ring[-1]:
                    ring += c[::-1][1:]
                elif c[-1] == ring[0]:
                    ring = c[:-1] + ring
                elif c[0] == ring[0]:
                    ring = c[::-1][:-1] + ring
                else:
                    continue
                del chains[i]
                break
            else:
                break
        done.append(ring)
    return done


def osm_water(width, length, lat, lon, metres):
    """OpenStreetMap's water over the map, which is WIDTH x LENGTH pixels of
    METRES, its north edge at LAT, LON and running south."""
    from pyproj import Transformer

    to_nztm = Transformer.from_crs(4326, 2193, always_xy=True)
    to_wgs = Transformer.from_crs(2193, 4326, always_xy=True)
    cx, cy = to_nztm.transform(lon, lat)
    x0, y1 = cx - width * metres / 2, cy
    corners = [to_wgs.transform(x, y) for x in (x0, x0 + width * metres) for y in (y1, y1 - length * metres)]
    south, north = min(c[1] for c in corners), max(c[1] for c in corners)
    west, east = min(c[0] for c in corners), max(c[0] for c in corners)
    box = f"({south},{west},{north},{east})"
    query = "[out:json][timeout:90];(" + "".join(f"{kind}{tag}{box};" for tag in OSM_WATER for kind in ("way", "rel")) + ");out geom;"
    for attempt in range(6):  # the public servers are often busy: 429, 504
        r = requests.post(OVERPASS[attempt % len(OVERPASS)], data={"data": query}, headers={"User-Agent": "deimos-rising-terrain-recover/1.0"}, timeout=120)
        if r.ok:
            break
        time.sleep(10 * (attempt + 1))
    r.raise_for_status()

    def pixels(ring):
        xs, ys = to_nztm.transform([p[0] for p in ring], [p[1] for p in ring])
        return [((x - x0) / metres, (y1 - y) / metres) for x, y in zip(xs, ys)]

    img = Image.new("L", (width, length), 0)
    draw = ImageDraw.Draw(img)
    for e in r.json()["elements"]:
        if e["type"] == "way":
            draw.polygon(pixels([(p["lon"], p["lat"]) for p in e["geometry"]]), fill=255)
        else:
            for role, fill in (("outer", 255), ("inner", 0)):
                for ring in rings([m for m in e["members"] if m["role"] == role]):
                    draw.polygon(pixels(ring), fill=fill)
    return np.asarray(img) > 0


def cells_of(water, cell=CELL):
    h, w = water.shape
    return water[: h // cell * cell, : w // cell * cell].reshape(h // cell, cell, w // cell, cell).mean((1, 3)) > 0.5


def mask_image(cells):
    mask = np.zeros(cells.shape + (3,), np.uint8)
    mask[cells] = (0, 0, 255)
    mask[~cells] = (0, 255, 0)
    return Image.fromarray(mask)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("map")
    ap.add_argument("mask")
    ap.add_argument("--osm", nargs=2, type=float, metavar=("LAT", "LON"), help="the map's northernmost point; the water is OpenStreetMap's, not found by colour")
    ap.add_argument("--metres", type=float, default=1.0, help="metres to a map pixel (with --osm)")
    ap.add_argument("--preview", help="the map with its water in red, to check it by eye")
    args = ap.parse_args()
    rgb8 = np.asarray(Image.open(args.map).convert("RGB"))
    if args.osm:
        water, colour = osm_water(rgb8.shape[1], rgb8.shape[0], *args.osm, args.metres), None
    else:
        water, colour = water_pixels(rgb8)
    cells = cells_of(water)
    mask_image(cells).save(args.mask)
    print(f"water {cells.mean():.1%} of the map (colour Lab {None if colour is None else colour.round(0).tolist()}) -> {args.mask}")
    if args.preview:
        p = rgb8.copy()
        w = np.kron(cells, np.ones((CELL, CELL), bool))
        full = np.zeros(water.shape, bool)
        full[: w.shape[0], : w.shape[1]] = w
        p[full] = (p[full] * 0.4 + np.array([255, 0, 0]) * 0.6).astype(np.uint8)
        Image.fromarray(p).save(args.preview)


if __name__ == "__main__":
    main()
