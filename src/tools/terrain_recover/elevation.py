"""Fetch LINZ's open LiDAR elevation for a strip: the ground (DEM) and the
surface (DSM: ground, buildings and treetops), one pixel to METRES metres,
as aerial.py's map. CC BY 4.0, "Sourced from LINZ".

    elevation.py LAT LON --out DIR

writes DIR/dem.npy and DIR/dsm.npy (float32 metres; gaps are NaN). The strip
is the one aerial.py makes: its northernmost point is at LAT, LON. Pass
--collection with another region's .../dem_1m/2193/ URL (its dsm_1m is
beside it).
"""

import argparse
from pathlib import Path

import numpy as np

from aerial import fetch

COLLECTION = "https://nz-elevation.s3.ap-southeast-2.amazonaws.com/west-coast/west-coast_2020-2022/dem_1m/2193/"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("lat", type=float)
    ap.add_argument("lon", type=float)
    ap.add_argument("--out", required=True)
    ap.add_argument("--width", type=int, default=480)
    ap.add_argument("--length", type=int, default=3600)
    ap.add_argument("--metres", type=float, default=1.0)
    ap.add_argument("--collection", default=COLLECTION)
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for name, url in (("dem", args.collection), ("dsm", args.collection.replace("/dem_1m/", "/dsm_1m/"))):
        a = fetch(args.lat, args.lon, args.width, args.length, args.metres, url, bands=1)
        np.save(out / f"{name}.npy", a)
        print(f"{name}: {np.nanmin(a):.1f} to {np.nanmax(a):.1f} m, {np.isnan(a).mean():.1%} gaps")


if __name__ == "__main__":
    main()
