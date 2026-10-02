"""Make the inputs recover.py takes from LINZ aerial imagery: the map, a
media mask with OpenStreetMap's water, and a level record.

The strip is LENGTH metres long and WIDTH wide, one map pixel to a metre by
default, and runs south from the GPS point, which is its northernmost point.
The imagery is LINZ's open 0.2 m West Coast mosaic (CC BY 4.0, "Sourced
from LINZ"); to use another region pass --collection with the URL of its
rgb/2193/ folder.
"""

import argparse
import json
import os
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import requests
from PIL import Image
from water_mask import cells_of, mask_image, osm_water

COLLECTION = "https://nz-imagery.s3.ap-southeast-2.amazonaws.com/west-coast/west-coast_2024-2026_0.2m/rgb/2193/"


def fetch(lat, lon, width, length, metres, collection):
    import rasterio
    from pyproj import Transformer
    from rasterio.enums import Resampling
    from rasterio.windows import from_bounds

    os.environ.setdefault("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
    to_nztm = Transformer.from_crs(4326, 2193, always_xy=True)
    cx, cy = to_nztm.transform(lon, lat)
    x0, x1 = cx - width * metres / 2, cx + width * metres / 2
    y0, y1 = cy - length * metres, cy
    coll = requests.get(collection + "collection.json", timeout=60).json()
    out = np.zeros((length, width, 3), np.uint8)
    got = np.zeros((length, width), bool)

    def item_of(link):
        for attempt in range(5):
            try:
                return requests.get(collection + link[2:], timeout=60).json()
            except requests.RequestException:
                time.sleep(2 * (attempt + 1))
        raise SystemExit(f"cannot read {link}")

    def covers(item):
        west, south, east, north = item["bbox"]
        ax, ay = to_nztm.transform(west, south)
        bx, by = to_nztm.transform(east, north)
        return not (bx < x0 or ax > x1 or by < y0 or ay > y1)

    with ThreadPoolExecutor(16) as pool:
        items = [i for i in pool.map(item_of, [l["href"] for l in coll["links"] if l["rel"] == "item"]) if covers(i)]
    for item in items:
        href = item["assets"]["visual"]["href"]
        url = href if href.startswith("http") else collection + href[2:]
        print("tile", item["id"], flush=True)
        with rasterio.open(url) as ds:
            l, b, r, t = ds.bounds
            ix0, ix1, iy0, iy1 = max(x0, l), min(x1, r), max(y0, b), min(y1, t)
            if ix0 >= ix1 or iy0 >= iy1:
                continue
            px0, px1 = round((ix0 - x0) / metres), round((ix1 - x0) / metres)
            py0, py1 = round((y1 - iy1) / metres), round((y1 - iy0) / metres)
            win = from_bounds(ix0, iy0, ix1, iy1, ds.transform)
            data = ds.read([1, 2, 3], window=win, out_shape=(3, py1 - py0, px1 - px0), resampling=Resampling.average)
            out[py0:py1, px0:px1] = np.moveaxis(data, 0, -1)
            got[py0:py1, px0:px1] = True
    if not got.all():
        raise SystemExit(f"the imagery covers {got.mean():.0%} of the strip")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("lat", type=float, help="latitude of the strip's northernmost point")
    ap.add_argument("lon", type=float, help="longitude of the strip's northernmost point")
    ap.add_argument("--id", required=True, help="the level's id, e.g. greymouth")
    ap.add_argument("--name", default=None)
    ap.add_argument("--out", required=True, help="folder for images/ and the level record")
    ap.add_argument("--width", type=int, default=480)
    ap.add_argument("--length", type=int, default=3600)
    ap.add_argument("--metres", type=float, default=1.0, help="metres to a map pixel")
    ap.add_argument("--collection", default=COLLECTION)
    args = ap.parse_args()

    out = Path(args.out)
    images = out / "images"
    images.mkdir(parents=True, exist_ok=True)
    rgb8 = fetch(args.lat, args.lon, args.width, args.length, args.metres, args.collection)
    Image.fromarray(rgb8).save(images / f"{args.id}_map.png")
    water = osm_water(args.width, args.length, args.lat, args.lon, args.metres)  # the mask aerial imagery lacks: see water_mask.py
    mask_image(cells_of(water)).save(images / f"{args.id}_mask.png")
    level = {
        "id": args.id,
        "name": args.name or args.id,
        "identifier": args.id,
        "description": "",
        "copyright": "Imagery sourced from LINZ (CC BY 4.0); water from OpenStreetMap contributors (ODbL).",
        "briefing": "none",
        "background": [0, 0, args.width, args.length],
        "background_image": f"{args.id}_map",
        "preview_image": "",
        "music": "mu03",
        "media_mask": f"{args.id}_mask",
        "placements": [],
        "start_weapons": {"air": "", "ground": ""},
        "wind": {"direction_degrees": 0.0, "strength": 0.0},
        "water": {"height": 0.0, "colour": [0, 0, 0], "visible": False},
        "skybox": "",
        "layers": {"albedo": "", "normal": "", "height": "", "shadow_mask": "", "hd_map": "", "specular": ""},
    }
    (out / f"{args.id}.json").write_text(json.dumps(level, indent=2) + "\n")
    print(f"wrote {images}/{args.id}_map.png, {args.id}_mask.png and {out / (args.id + '.json')}")


main()
