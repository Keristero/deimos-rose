# HD map upscaler

`upscale.py` makes a 4x version of a level's 480x3600 background (level 1,
map `jum2`, becomes 1920x14400). It keeps the original's colours and layout
exactly, and takes only fine texture from an image model. Output goes to
`work/hd/<map>/`, which is gitignored: this tool is not in the game build.

## Run it

```sh
cd src
mise run assets:extract              # once: puts the maps in plugins/classic_levels/images/im16/
mise run hd:setup                    # once: venv at ~/.cache/deimos-rising/hd-venv
MAP=jum2 mise run hd:upscale         # all 32 tiles, then assemble
```

Extra flags go after `--`:

```sh
MAP=jum2 mise run hd:upscale -- --limit 2          # render two tiles, assemble a preview
MAP=jum2 mise run hd:upscale -- --only 0,0 892,224 # particular tiles (source-pixel origins, listed in the manifest)
MAP=jum2 mise run hd:upscale -- --assemble-only    # no GPU; rebuild from cached tiles
MAP=jum2 mise run hd:upscale -- --offload          # less VRAM, slower (see peak_vram_gb in the manifest)
```

The first run downloads FLUX.2 [klein] 4B, about 16 GB, into the Hugging Face
cache (`HF_HOME`, default `~/.cache/huggingface`). It is Apache-2.0 and not
gated, so no login is needed. The revision is pinned in `upscale.py`.

Runs resume. Each finished tile is saved under
`work/hd/<map>/tiles-<hash>/`, and the hash covers every setting that changes
a tile (model, revision, prompt, seed, steps, guidance, scale, tile size). A
run with different settings gets a new folder and never mixes tiles. Missing
tiles are filled with plain bicubic, so a partial run still assembles:
`jum2_4x_partial5of32.png`, and `jum2_4x.png` once every tile is done.

### GPU and torch

`hd:setup` installs torch from `TORCH_INDEX`, then the pinned
`requirements.txt`.

| GPU | `TORCH_INDEX` |
|---|---|
| NVIDIA (default) | `https://download.pytorch.org/whl/cu128` |
| AMD Strix Halo (gfx1151) | `https://rocm.nightlies.amd.com/v2/gfx1151/` |
| Other AMD | the PyTorch ROCm index, or AMD's index for your gfx target (untested) |

```sh
TORCH_INDEX=https://rocm.nightlies.amd.com/v2/gfx1151/ mise run hd:setup
```

On ROCm the script turns on flash attention
(`TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1`) and turns off MIOpen convolution,
because on gfx1151 it fails with `miopenStatusUnknownError`. Both changes are
harmless elsewhere. The weights are about 16 GB in bf16. The manifest records
the peak VRAM of a run: 20.8 GB without offload on the test GPU. `--offload` keeps only the active component on the
GPU, for cards with less memory.

## How it works

1. Cut the map into 256 px tiles that overlap by at least 32 px. `jum2` needs
   16 rows of 2 tiles.
2. Upscale each tile 4x with bicubic, then give it to Flux as the reference
   image. Every tile uses the same seed and this prompt: *"A sharper,
   higher-resolution version of this exact image. Do not add, remove or move
   anything."*
3. From Flux's output, keep only the detail finer than a Gaussian of σ = 1.5
   source px (6 output px). This is the output minus its blurred copy.
4. Add that detail onto the blurred bicubic upscale of the original.
   Neighbouring tiles blend across a linear feather in the overlaps.

The original therefore supplies every colour, shadow and position. Flux only
sharpens edges and adds grain. Flux on its own restyles the terrain, so its
low frequencies are never used.

## Checks it reports

`work/hd/<map>/manifest.json` records the settings, software versions, GPU,
per-tile times and these checks:

| Check | What it means |
|---|---|
| `layout_psnr`, per tile | Raw Flux output compared with its input, both blurred at σ 3 source px. A tile well below the others probably had content added or moved: look at it first. The run prints the five lowest. |
| `shrink_back_mean_abs_levels` | The result box-shrunk back to 480x3600 and compared with the original, in 8-bit levels. Plain bicubic already scores about 2.4. Single tiles with the prompt above score 2-5. A prompt that let Flux invent ferns and a pool on bare rock scored 11. |
| `mean_colour_shift_levels` | Shift in the average colour. It should stay under about 1. |

Delete a bad tile's PNG and rerun with a different `--seed` to re-render it.
The seed is part of the hash, so that seed's tiles go to a new folder.
Alternatively, leave the tile missing and accept bicubic there.

## Results so far

Tested 2026-09-28 on a Radeon 8060S (Strix Halo, gfx1151, ROCm 7.13 nightly,
torch 2.11) with five tiles of `jum2`. One tile takes 58-63 s at 1024 px and 4
steps. The same model under stable-diffusion.cpp (lemonade) took about 200 s,
so the whole map is about 32 minutes here. A faster NVIDIA card should be
several times quicker.

| Tile (y,x) | Content | Layout PSNR | Shrink-back error | Detail vs bicubic |
|---|---|---|---|---|
| 0,0 | rock plateau, gully | 23.8 dB | 5.4 levels | 2.1x |
| 0,0 (lemonade, for comparison) | | 23.8 dB | 4.3 levels | 1.7x |
| 892,224 | jungle, bunker, palms | 26.8 dB | 5.0 levels | 1.4x |
| 3344,0 | lake shore | 29.6 dB | 2.2 levels | 1.7x |

(Shrink-back and detail are measured on the tile alone here. The manifest
measures the whole map.) Nothing was added or moved in any of them: the
bunker keeps its rim, corner lights and stairs, now sharp, and the palms get
separate fronds. The one loss is the original's dither speckle in dark
jungle floor, which the blur removes and Flux doesn't replace. It looks like
dither in the 16-bit art rather than detail. Tile overlaps showed no seams. Earlier tests
and the prompts tried are in `notes/headless-3d-to-2d-findings.md`.

## Caveats

- diffusers and stable-diffusion.cpp use different samplers and noise, so a
  tile from this script is not bit-identical to the lemonade tests, only
  similar in character. The same versions, seed and GPU vendor should
  reproduce a tile. GPU kernels are not bit-exact across vendors.
- The in-game camera scrolls a 480-wide window up the map. At 4x that is a
  1920 px screen, so the upscale has to hold up at full-screen viewing
  distance. Check the whole strip, not only the crops.
