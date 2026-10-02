# Terrain recovery

`recover.py` rebuilds a level project (`terrain/project.odin`) from one of the
original maps: a heightmap, the water and its translucent layer, the canopy,
and an unlit colour layer. The result is
a starting point an artist opens in the level editor. It is not a finished
level. Output goes to `work/terrain/<level>/`, which is gitignored, because it
is made from the original art. See Stage 6 of `notes/level-editor-plan.md`.

## Run it

```sh
cd src
mise run assets:extract              # once: puts the maps in plugins/classic_levels/images/im16/
mise run terrain:marigold-setup      # once: Marigold V2 in ~/.cache/deimos-rising/marigold-v2
LEVEL=le07 mise run terrain:recover  # work/terrain/le07/le07.drproj.json
PROJECT=../work/terrain/le07/le07.drproj.json mise run terrain:compare
```

Extra flags go after `--`. For example, `-- --seed depth-anything` seeds the
heights from Depth Anything V2 Large instead of Marigold V2. That model is
1.3 GB and downloads on first use.

`mise run terrain:recover-all` recovers all 12 levels into
`work/recovered/<level>/`, bakes each one's occlusion layer
(`tools/terrain_occlusion/`, which needs `mise run hd:setup`), refits the
colour to it (`terrain:relight`), and then runs `terrain:report`, which
writes each one's `terrain:compare` scores to `work/recovered/report.md`
(`LEVELS='le01 le07'` for some). The scores are taken with the occlusion
layer, as the game draws it and as the relit colour expects, and the
report also gives the IoU without it. The canopy mask comes from CLIPSeg
(`CIDAS/clipseg-rd64-refined`, 0.6 GB), which also downloads on first use.

`LEVEL=le07 mise run terrain:relight` (or `-- --relight`) redoes only
the colour of a project already recovered: the occlusion layer is fitted
to the art and divided out of the colour, and the water layer fitted
again over its lit bed. It runs no model, and takes about 45 s on the
CPU. The occlusion as baked is kept in `OUT/cache/occlusion-baked.png`, so
a rerun fits it again rather than its own last fit.

The recovery draws the project with `tools/terrain` (built by the task) to
divide the renderer's own light out of the colour, headless under
`xvfb-run` when it is installed.

## From aerial imagery

```sh
LAT=-42.4398918 LON=171.1968841 ID=greymouth NAME=Greymouth mise run terrain:aerial
```

makes a level project from LINZ's open aerial imagery (CC BY 4.0, so the
level's copyright credits LINZ). The GPS point is the northernmost point of
the strip, which runs 3600 m south and 480 m wide, a metre to a map pixel.
`aerial.py` fetches the map; `water_mask.py` makes the media mask that
aerial imagery lacks, from OpenStreetMap's water (`natural=water` and
`waterway=riverbank`, through Overpass; credit OpenStreetMap, ODbL), and
`OUT/water-preview.png` shows it over the map. Without `--osm` it finds the
water by colour instead, which shadows can fool. Then `recover.py` runs as
for the originals, moving the shores to the art's own, with Marigold on the
CPU (`DEVICE=cuda` to change). The project is in `work/aerial/<id>/project/`.
Place units in the editor. The sun's angle is not known: pass
`-- --azimuth A --elevation E`.

## Setup

`terrain:marigold-setup` follows the upstream `setup/setup_env.sh`, with a
plain venv in place of conda. Everything goes into `DR_MARIGOLD`:

- `src/`: the Marigold V2 repository at a pinned commit, with
  `marigold-v2.patch` applied;
- `venv/`: Python 3.10, made by `uv` when it is installed and otherwise by
  `python3.10`. Torch comes from `TORCH_INDEX`, then the package is installed
  with upstream's pinned dependencies;
- `assets/checkpoints/`: links into the Hugging Face cache (`HF_HOME`), where
  the weights are downloaded at pinned revisions. That is about 45 GB, most of
  it the Qwen-Image-Edit-2509 transformer. The run quantises it to 4 bits.

| GPU | `TORCH_INDEX` | `TORCH_SPEC` |
|---|---|---|
| NVIDIA (default) | `https://download.pytorch.org/whl/cu128` | `torch==2.10.0 torchvision==0.25.0` (upstream's) |
| AMD Strix Halo (gfx1151) | `https://rocm.nightlies.amd.com/v2/gfx1151/` | `torch torchvision` (the nightly) |

```sh
TORCH_INDEX=https://rocm.nightlies.amd.com/v2/gfx1151/ TORCH_SPEC="torch torchvision" mise run terrain:marigold-setup
```

The patch changes one thing. On ROCm it turns MIOpen convolution off, because
its algorithm search fails on gfx1151. On CUDA it does nothing. On ROCm the
setup also replaces upstream's bitsandbytes 0.49.2 with 0.50.2. 0.49.2 has no
build for ROCm newer than 7.2 and no way to choose one; 0.50.2 falls back to
its 7.2 build. Rerunning the
setup is safe, because each step is skipped once done.

The manifest records the commit and the weight snapshots actually installed.
Depth is cached under `OUT/cache/marigold-<hash>/`, keyed by those versions,
so a rerun with the same setup only refits.

## How it works

The docstring at the top of `recover.py` gives the steps. `OUT/manifest.json`
records the settings, versions and fits.
