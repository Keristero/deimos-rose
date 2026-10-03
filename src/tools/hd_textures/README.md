# HD textures

Redraws the game's sprite plates and interface images at twice their size, on
the CPU, for the HD Textures plugin (`plugins/hd_textures`).

    mise run hd:textures:setup     # once: a CPU-only venv
    mise run hd:textures:bench     # compare upscalers (N=sprites in the sample)
    mise run hd:textures           # write plugins/hd_textures/textures/ (about a minute)

## The choice: Nomos SPAN 2x

`bench.py` shrinks a sample of the game's own art 2x, brings it back with each
upscaler and scores it against the original (80 samples: sprites cropped to
their busiest window, plus a menu backdrop). Mean over the samples:

| upscaler | PSNR dB | SSIM | s per input MP (CPU) |
|---|---|---|---|
| lanczos (no model) | 28.13 | 0.9380 | 0.06 |
| **2xNomosUni SPAN** | 28.12 | 0.9402 | 12 |
| 2xNomosUni Compact | 26.60 | 0.9411 | 5.5 |
| 2xNomosUni ESRGAN | 27.97 | 0.9327 | 40 |
| Real-ESRGAN x4plus | 26.11 | 0.9085 | 96 |

SPAN matches Lanczos on PSNR and beats it on SSIM, without Compact's colour
drift or Real-ESRGAN's invented texture, and is fast enough that the whole game
takes under a minute. Weights: `Phips/2xNomosUni_span_multijpg`, CC-BY-4.0
(credit the author where the plugin is distributed).

What the numbers do not say:

- The test restores a shrunken image, a finer scale than the real job (2x of
  the original). The ranking is the evidence, `work/hd_textures/bench/sheet.png`
  the check, and the final look is the user's call: `hd:textures` takes
  `--model` to try another.
- The art is soft, pre-rendered 3D, which is why plain Lanczos scores so
  close; a model's gain is mostly cleaner edges.
- HFA2k SPAN was in the candidate list but is not in the results.

## What is and is not redrawn

Redrawn: every sprite plate (`sprites/im08`) and the interface images
(`images/im16` of the core: menus, score bar). Frame rectangles stay the
original's: the game draws the plate at its own size with more pixels in it.

Not redrawn: the level maps. The terrain's burn marks are written into a CPU
buffer at the map's resolution, so a 2x map would need a different terrain
pipeline. The ship's accent trim (`ship_trim`) is built from the original
PNGs and stays as it was.

Classic mode never uses the plugin.
