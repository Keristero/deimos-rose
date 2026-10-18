#!/usr/bin/env python3
"""Fetches the level editor's scenery models from Poly Haven (CC0) into a cache.

    fetch.py SOURCES.json CACHE_DIR

For each model SOURCES.json names, asks Poly Haven's API which files make
its 1k glTF (the .gltf, its .bin and its textures), and downloads each one
whose MD5 does not match. The models are then CACHE_DIR/<id>/<id>_1k.gltf,
as tools/models (`mise run models:library`) reads them. Only the base
colour texture is used, but every texture is fetched so the glTF stays whole
for anyone opening it.

Poly Haven's plants keep their leaves' alpha in a map of its own that their
glTF does not name: island_tree_01's leaves_alpha, fern_02's Alpha, beside
a JPEG base colour with none. Unmasked, each leaf card is a dark square.
So each map named *alpha is fetched too, as a PNG into the textures
folder, where the library builder pairs X_alpha_1k.png with X_diff_1k.jpg.
And the model's info, as CACHE_DIR/<id>/info.json, for its name and authors
in the library's credits.

Poly Haven's terms ask API users to send a User-Agent of their own and to
credit them ("Powered by Poly Haven"); the library's CREDITS.md does.
Everything is CC0: https://polyhaven.com/license.
"""

import hashlib
import json
import os
import sys
import urllib.request

API = "https://api.polyhaven.com/files/"
INFO = "https://api.polyhaven.com/info/"
AGENT = "deimos-rising-level-editor/1 (model library fetch)"
RESOLUTION = "1k"


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": AGENT})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def md5_of(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(url, md5, path):
    """Downloads url to path unless path already has md5. True if fetched."""
    if os.path.exists(path) and md5_of(path) == md5:
        return False
    blob = get(url)
    if hashlib.md5(blob).hexdigest() != md5:
        raise RuntimeError(f"{url}: the download's MD5 is not Poly Haven's {md5}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(blob)
    os.replace(tmp, path)
    return True


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sources = json.load(open(sys.argv[1]))
    cache = sys.argv[2]
    fetched = kept = 0
    for m in sources["models"]:
        ident = m["id"]
        files = json.loads(get(API + ident))
        gltf = files["gltf"][RESOLUTION]["gltf"]
        dest = os.path.join(cache, ident)
        todo = [(gltf["url"], gltf["md5"], os.path.join(dest, os.path.basename(gltf["url"])))]
        for rel, inc in gltf.get("include", {}).items():
            # The .gltf names its files relative to itself.
            if os.path.isabs(rel) or ".." in rel.split("/"):
                raise RuntimeError(f"{ident}: an include outside its folder: {rel}")
            todo.append((inc["url"], inc["md5"], os.path.join(dest, rel)))
        for key, resolutions in files.items():
            if key.lower().endswith("alpha"):
                png = resolutions[RESOLUTION]["png"]
                todo.append((png["url"], png["md5"], os.path.join(dest, "textures", os.path.basename(png["url"]))))
        for url, md5, path in todo:
            if fetch(url, md5, path):
                fetched += 1
            else:
                kept += 1
        info = get(INFO + ident)
        with open(os.path.join(dest, "info.json"), "wb") as f:
            f.write(info)
        print(f"{ident}: {len(todo)} files")
    print(f"fetched {fetched}, already had {kept}, in {cache}")


if __name__ == "__main__":
    main()
