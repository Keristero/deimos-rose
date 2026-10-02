"""Fill a recovered level project with unit placements, after the patterns
of the classic levels.

The player starts at the south and the map scrolls north, so the encounters
harden toward y = 0. On open ground (smooth grass, clear of water, canopy
and buildings) the script makes strongholds: turrets (Laser and Pulse tanks
and Panzers emplaced, swivel guns, popups, twin guns, radars) with a bonus
station and a hidden secret behind them. Between them it puts air waves,
which the classic levels place ahead of a ground group, a scroll-pausing
script at the middle (03p2, Flippers until the ground is cleared) and the
end script (04e1) on dry land near the north. Which units come where is
fixed by the seed, so a rerun gives the same level.

    populate.py PROJECT.drproj.json MAP.png MASK.png
"""

import argparse
import json
import random
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

CELL = 5
SITE_REACH = 120  # open-ground disks this close make one stronghold
MIN_DISK = 14  # the smallest open disk's radius, in pixels
SITE_GAP = 350  # strongholds are at least this far apart along the map
UNIT_SEP = 26
EDGE_MARGIN = 48  # ground units keep this far from the screen's left and right edges

# Turrets by how late in the level they are: (unit, stationary, terrain effects).
EASY = [("tala", True, False), ("sggr", False, False), ("papu", True, True), ("sggr", False, False)]
HARD = [("pola", False, False), ("popu", False, False), ("twgu", False, False), ("pasc", True, True), ("car2", False, False), ("plla", False, False)]
AIR_EARLY = ["flip", "bu01", "bu02"]
AIR_LATE = ["blha", "shur", "flip"]


def open_ground(rgb8, water, canopy):
    rgb = rgb8.astype(np.float32) / 255
    luma = rgb @ np.array([0.299, 0.587, 0.114], np.float32)
    mean = ndi.uniform_filter(luma, 9)
    texture = np.sqrt(np.maximum(ndi.uniform_filter(luma * luma, 9) - mean * mean, 0))
    green = (rgb[..., 1] > rgb[..., 0] * 1.02) & (rgb[..., 1] > rgb[..., 2] * 1.05)
    grass = green & (texture < 0.03) & (canopy < 0.3) & ~water
    return ndi.distance_transform_edt(ndi.binary_opening(grass, iterations=2))


def sites(dist):
    """Strongholds as (x, y, reach): the open disks, merged, the largest first,
    kept SITE_GAP apart along y."""
    disks, work = [], dist.copy()
    yy, xx = np.ogrid[: dist.shape[0], : dist.shape[1]]
    while True:
        y, x = np.unravel_index(work.argmax(), work.shape)
        if work[y, x] < MIN_DISK:
            break
        disks.append((int(x), int(y), float(work[y, x])))
        work[(yy - y) ** 2 + (xx - x) ** 2 < max(work[y, x], 30) ** 2] = 0
    groups = []
    for x, y, r in disks:
        for g in groups:
            if (g["x"] - x) ** 2 + (g["y"] - y) ** 2 < SITE_REACH**2:
                g["disks"].append((x, y, r))
                break
        else:
            groups.append({"x": x, "y": y, "disks": [(x, y, r)]})
    out = []
    for g in sorted(groups, key=lambda g: -sum(r * r for _, _, r in g["disks"])):
        if all(abs(g["y"] - o[1]) >= SITE_GAP for o in out):
            reach = max(40.0, max(((x - g["x"]) ** 2 + (y - g["y"]) ** 2) ** 0.5 + r for x, y, r in g["disks"]))
            out.append((g["x"], g["y"], reach))
    return sorted(out, key=lambda s: -s[1])  # south first


def place(project, rgb8, mask):
    h, w = rgb8.shape[:2]
    water = np.kron((mask[..., 2] == 255) & (mask[..., 0] == 0), np.ones((CELL, CELL), bool))[:h, :w]
    canopy = np.asarray(Image.open(project["_dir"] / project["canopy"]).convert("L")).astype(np.float32) / 255
    dist = open_ground(rgb8, water, canopy)
    dist[:, :EDGE_MARGIN] = 0
    dist[:, w - EDGE_MARGIN :] = 0
    from_water = ndi.distance_transform_edt(~water)
    rnd = random.Random(2026)
    out = []

    def add(unit, layer, x, y, heading=0, stationary=False, effects=False):
        out.append({"unit": unit, "layer": layer, "x": int(x), "y": int(y), "heading_degrees": int(heading) % 360, "is_stationary": stationary, "terrain_effects": effects})

    def nearest(x0, y0, ok, taken, span=150):
        """The closest pixel to (x0, y0) where OK, clear of the TAKEN points."""
        ys, xs = np.mgrid[max(0, y0 - span) : min(h, y0 + span), max(0, x0 - span) : min(w, x0 + span)]
        score = np.where(ok[ys, xs], (ys - y0) ** 2 + (xs - x0) ** 2, 1e9)
        for tx, ty in taken:
            score = np.where((xs - tx) ** 2 + (ys - ty) ** 2 < UNIT_SEP**2, 1e9, score)
        i = np.unravel_index(score.argmin(), score.shape)
        return (int(xs[i]), int(ys[i])) if score[i] < 1e9 else None

    def air(kinds, y, count):
        step = (w - 100) / max(count, 1)
        unit = rnd.choice(kinds)
        for i in range(count):
            add(unit, "air ", 70 + step * (i + 0.5), y + rnd.randint(-20, 20))

    taken = []
    stands = sites(dist)
    for n, (sx, sy, reach) in enumerate(stands):
        progress = 1 - sy / h
        count = 4 + round(10 * progress)
        pool = EASY if progress < 0.5 else EASY + HARD
        units = [rnd.choice(pool) for _ in range(count)]
        for unit, stationary, effects in units:
            for _ in range(300):
                x, y = sx + rnd.uniform(-reach, reach), sy + rnd.uniform(-reach, reach)
                xi, yi = int(min(max(x, 0), w - 1)), int(min(max(y, 0), h - 1))
                if dist[yi, xi] >= 5 and all((x - a) ** 2 + (y - b) ** 2 >= UNIT_SEP**2 for a, b in taken):
                    break
            else:
                continue
            taken.append((x, y))
            add(unit, "grnd", x, y, 180 + rnd.choice([-45, -30, -15, 0, 15, 30, 45]), stationary, effects)
        for unit in ("bsgr", "sess" if progress < 0.7 else "sels"):
            spot = nearest(sx, sy, dist >= 4, taken)
            if spot:
                taken.append(spot)
                add(unit, "grnd", *spot)
        # Air ahead of the stronghold (south of it), harder the later it is.
        air(AIR_LATE if progress > 0.5 else AIR_EARLY, min(h - 60, sy + 330), 3 + round(2 * progress))
    # Air between: a gauntlet every SITE_GAP not covered by a stronghold.
    covered = [s[1] for s in stands]
    for y in range(h - 250, 150, -SITE_GAP // 2):
        if all(abs(y - c) > 200 for c in covered):
            air(AIR_LATE if y < h / 2 else AIR_EARLY, y, 3 + (1 if y < h / 2 else 0))
    dry = (from_water > 12) & (dist >= 0)
    dry[:, :EDGE_MARGIN] = False
    dry[:, w - EDGE_MARGIN :] = False
    mid = nearest(w // 2, h // 2, dry, [], span=300)
    end = nearest(w // 2, min(150, h // 4), dry, [], span=200)
    for unit, spot in (("03p2", mid), ("04e1", end)):
        if spot:
            add(unit, "grnd", *spot)
    out.sort(key=lambda p: -p["y"])
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project")
    ap.add_argument("map")
    ap.add_argument("mask")
    ap.add_argument("--level", help="also write the placements into this level record (the project's level is always written)")
    args = ap.parse_args()
    path = Path(args.project)
    project = json.loads(path.read_text())
    project["_dir"] = path.parent
    placements = place(project, np.asarray(Image.open(args.map).convert("RGB")), np.asarray(Image.open(args.mask).convert("RGB")))
    del project["_dir"]
    project["level"]["placements"] = placements
    path.write_text(json.dumps(project, indent=2) + "\n")
    if args.level:
        rec = Path(args.level)
        level = json.loads(rec.read_text())
        level["placements"] = placements
        rec.write_text(json.dumps(level, indent=2) + "\n")
    ground = sum(p["layer"] == "grnd" for p in placements)
    print(f"{len(placements)} placements ({ground} ground, {len(placements) - ground} air) -> {path}")


if __name__ == "__main__":
    main()
