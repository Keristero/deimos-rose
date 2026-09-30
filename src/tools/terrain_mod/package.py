"""Packages the recovered levels as a campaign plugin, Recovered Levels.

    package.py --recovered DIR --classic DIR --renderer TERRAIN --out DIR

For each level recovered in DIR/leNN/leNN.drproj.json it draws the project
lit, with its occlusion, into OUT/images/im16/rlNN.png, and writes the
original's level record to OUT/data/levels/leNN.json with only its map
changed: the same units, previews, masks and music. The manifest lists the
levels in the originals' play order and is off by default. Run it
headless (tools/terrain opens a hidden window).
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

MANIFEST = {
    "label": "Recovered Levels",
    "description": "The original twelve sectors on maps redrawn from their recovered 3D terrain",
    "version": "1",
    "default_on": False,
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--recovered", type=Path, required=True)
    ap.add_argument("--classic", type=Path, required=True, help="the Classic Levels plugin folder")
    ap.add_argument("--renderer", type=Path, required=True, help="tools/terrain's binary")
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()

    classic = json.loads((a.classic / "plugin.json").read_text())
    images = a.out / "images/im16"
    records = a.out / "data/levels"
    images.mkdir(parents=True, exist_ok=True)
    records.mkdir(parents=True, exist_ok=True)

    packed = {}
    for path in sorted((a.classic / "data/levels").glob("le*.json")):
        stem = path.stem
        project = a.recovered / stem / f"{stem}.drproj.json"
        if not project.exists():
            print(f"{stem}: not recovered, left out")
            continue
        record = json.loads(path.read_text())
        image = "rl" + stem[2:]
        subprocess.run([str(a.renderer), "render", str(project), str(images / image), "-output=lit"], check=True)
        record["background_image"] = image
        (records / path.name).write_text(json.dumps(record, indent=4, ensure_ascii=False) + "\n")
        packed[record["identifier"]] = stem

    if not packed:
        sys.exit("no recovered levels found in %s" % a.recovered)
    manifest = dict(MANIFEST, levels=[i for i in classic["levels"] if i in packed])
    (a.out / "plugin.json").write_text(json.dumps(manifest, indent=4) + "\n")
    print(f"packed {len(packed)} levels into {a.out}")


if __name__ == "__main__":
    main()
