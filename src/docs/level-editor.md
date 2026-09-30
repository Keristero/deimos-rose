# Level editor and remastered levels

Progress on [notes/level-editor-plan.md](../../notes/level-editor-plan.md),
stage by stage. The decisions are D51–D56 in [decisions.md](decisions.md).

| Stage | Status | Where |
|---|---|---|
| 1 — Plugins own their content folders | **complete** | D51 |
| 2 — Data plugins found at startup | **complete** | D52 |
| 3 — Campaigns; the originals become Classic Levels | **complete** | D53 |
| 4 — Optional level fields, launch flags | **complete** | D54 |
| 5 — Terrain renderer, le07 proof of concept | **complete** | D55, below |
| 6 — Recovering the 12 originals' heightmaps | in progress | below |
| 7 — The editor | not started | |
| 8 — Materials, structures, placement | not started | |
| 9 — Export and Play | not started | |
| 10 — HD layers, Remastered Levels | not started | |

## Stage 5: the terrain renderer

`terrain/` holds the project format, the renderer and the shadow analysis
(D55); `tools/terrain` drives them from the command line:

```
LEVEL=le07 mise run terrain:recover              # work/terrain/le07/le07.drproj.json
PROJECT=../work/terrain/le07/le07.drproj.json mise run terrain:render    # every output
PROJECT=../work/terrain/le07/le07.drproj.json mise run terrain:compare   # numbers + side by side
```

All three run headlessly. `terrain:render` takes `OUTPUT` and `SCALE`;
`terrain:compare` finds the original map and mask by the level's own image
ids.

### The le07 proof of concept

`tools/terrain_recover/recover.py` is Stage 6's tool begun. For le07
(Mariner Valley, map `jum2`, mask `jut2`) it:

1. seeds the heights with Depth Anything V2 Large (revision `7581137e`),
   on six overlapping 480x900 windows, each fitted to the last on the
   overlap;
2. fits the height range by casting shadows at the measured sun (36°,
   28°) against the shadows detected in the art;
3. takes the water from the mask, removes the depth's drift along the
   map under the water so the river lies level, and sets one water height
   just above the ground under it;
4. makes a crude unlit colour: the art with its detected shadows divided
   by 0.44.

A first run takes under a minute and a half on the Strix Halo GPU; the
depth and the detected shadows are cached for the next.

Height range fit (cast-shadow IoU, half size, whole map):

| Range (px) | 80 | 120 | 160 | 240 | 320 | **480** | 640 | 960 |
|---|---|---|---|---|---|---|---|---|
| IoU | 0.107 | 0.204 | 0.287 | 0.419 | 0.478 | **0.499** | 0.502 | 0.503 |

The score flattens past about 480 px, so the tool takes the shortest range
within 0.01 of the best. The findings fitted about 640 px on `cam1`.

`terrain:compare` on the result, whole map, 2026-09-30:

| Measure | Original | Render |
|---|---|---|
| Land in detected shadow | 38.3% | 40.8% |
| Shadow light, median, of the ground around | 0.38 | 0.39 |
| Shadow IoU, detected against detected | 0.500 | |
| Fitted sun azimuth (cast shadows) | 36° measured | 30° (IoU 0.515) |

Its side-by-side (original, render, overlap: white both, red the
original's only, blue the render's only) is
`work/terrain/le07/le07.compare.png`. It is not committed: it holds the
original art. A 4x lit export (1920x14400, four strips) takes 39 s under
xvfb's software GL.

What the numbers say:

- **The light matches.** Shadow on the render is as dark against its
  surroundings as the art's (0.39 against 0.38), and flat lit ground comes
  out as its unlit colour, as designed.
- **The geometry is the depth model's.** 0.50 is where the findings put
  Depth Anything V2 Large before refinement (0.50 on `cam1`); Stage 6's
  shadow refinement is what moves it (0.76 at 1/4 resolution there).
- **Jungle is the hard case**, as the findings warned: a third of le07's
  land reads as shadow in the art, much of it dark canopy rather than
  cast shadow, and the depth model turns the canopy into bumpy ground.
  Stage 6 masks canopy and rebuilds it as vegetation.
- **The unlit colour still holds the art's shading**, so slopes are shaded
  twice. Stage 6 divides the shadows by the recovered heights' own light
  instead (below).
- The fitted azimuth, 30°, sits below the measured 36° because the depth
  model's shapes, not the sun, set where their shadows fall; it is a
  check on the geometry more than on the light.

## Stage 6: recovering the originals

`tools/terrain_recover/` (its README says how to run and set it up)
seeds the heights with Marigold V2, fits their range, removes the water's
drift, refines them against the detected shadows and divides the shadows
out of the colour. The recipe is in `recover.py`'s docstring, and the whole
pipeline, with a flow diagram, is in
[level-recovery-pipeline.md](level-recovery-pipeline.md).

### The unlit colour

It is needed only to relight the originals faithfully: a level made in the
editor is painted unlit. Tried on le07, scored by the share of the art's
detected shadow still detected in the colour, and by the shadow's light
against the lit ground's (the art: 100%, 0.30):

| Method | Still shadow | Shadow / lit | Notes |
|---|---|---|---|
| Detected shadows ÷ 0.44 (Stage 5) | 40% | 0.68 | canopy gaps turn to bright speckle |
| ÷ the rendered light everywhere | 59% | 0.50 | brightens 12% of the lit ground, under false shadows |
| **÷ the rendered light, in the detected shadows** | **50%** | **0.53** | lit ground unchanged; no speckle |
| ÷ Marigold IID shading (`marigold-iid-lighting-v1-1`) | 83% | 0.37 | removes them on 256 px tiles only |
| Flux 2 [klein] 4B, 12 prompts, 512 and 1024 px | | | keeps the scene only where it keeps the shadows |

The third is used: no parameters beyond the ambient, and the light it
divides by is the one the renderer will put back. What stays dark is
mostly canopy, which is dark in its own colour, and shadows the heights
do not cast.

### le07

`terrain:compare`, whole map, 2026-09-30 (sun 36°, 40° up):

| Measure | Stage 5 | Stage 6 |
|---|---|---|
| Rendered shadow IoU (the plan's bar: 0.75) | 0.500 | **0.770** |
| Shadow light, of the ground around (the art: 0.38) | 0.39 | 0.37 |
| Cast-shadow IoU of the heights alone | 0.499 | 0.704 |
| Fitted sun azimuth (measured 36°) | 30° | 36° |

The rendered IoU is above the cast one partly because the colour keeps
the shadows the heights miss. No ridge streaks show in the height image.
A water-drift bug found on the way: far from the water the smoothed trend
fell to zero, a 141 px cliff across le07 at row 2794; it is now held at its
nearest value.

### The twelve

`mise run terrain:recover`, `terrain:occlusion` and `terrain:report` on
all twelve, 2026-10-01, sun 36° and 40° up for each. The shadow IoU is
drawn without the occlusion, as the originals were (the plan's bar: 0.75);
with it, the added darkening reads as more shadow and the score falls.
The water is scored by its mean colour difference from the art, in levels
of 255, and its grain as a share of the art's (D57).

| Level | Map | Shadow IoU | With occlusion | Shadow light, render / art | Fitted azimuth (cast IoU) | Water: levels off, grain (flat water) |
|---|---|---|---|---|---|---|
| le01 | `cam1` | **0.918** | 0.818 | 0.43 / 0.43 | 36° (0.791) | 1.7, 1.05 (5.3, 0.48) |
| le02 | `cam2` | **0.800** | 0.714 | 0.42 / 0.41 | 38° (0.670) | 1.1, 0.99 (4.2, 0.56) |
| le03 | `ism1` | **0.961** | 0.879 | 0.38 / 0.37 | 36° (0.785) | 1.1, 1.03 (4.7, 0.43) |
| le04 | `cam3` | **0.917** | 0.832 | 0.44 / 0.44 | 36° (0.754) | 1.1, 1.02 (6.2, 0.48) |
| le05 | `jum3` | **0.828** | 0.771 | 0.44 / 0.43 | 36° (0.642) | 1.5, 1.00 (2.0, 0.38) |
| le06 | `inm3` | **0.964** | 0.840 | 0.46 / 0.46 | 36° (0.784) | 0.6, 0.99 (4.6, 0.17) |
| le07 | `jum2` | **0.937** | 0.890 | 0.39 / 0.38 | 36° (0.718) | 0.3, 0.98 (2.8, 0.19) |
| le08 | `ism3` | **0.946** | 0.889 | 0.34 / 0.33 | 36° (0.792) | 2.2, 1.04 (6.0, 0.44) |
| le09 | `ism2` | **0.946** | 0.864 | 0.39 / 0.38 | 36° (0.773) | 1.1, 1.13 (4.8, 0.54) |
| le10 | `inm2` | **0.923** | 0.817 | 0.48 / 0.48 | 36° (0.744) | 0.7, 0.98 (3.6, 0.48) |
| le11 | `jum1` | **0.892** | 0.824 | 0.44 / 0.43 | 38° (0.690) | 1.1, 1.11 (2.4, 0.45) |
| le12 | `inm1` | **0.936** | 0.823 | 0.47 / 0.46 | 36° (0.740) | 0.6, 0.98 (3.1, 0.42) |

All twelve pass, and the shadow is as dark against the ground around as
the art's to within 0.01. The fitted azimuth lands on the measured 36°
or next to it, so the heights cast their shadows where the art's fall.

- **le02 and le05 are the weakest**, and their heights' cast IoU is the
  lowest too (0.670, 0.642): more of their shadow is kept by the colour
  than cast by the heights.
- **le09's range fit reached 960 px**, the most the fit tries, so its
  relief may be clipped short; its IoU is 0.945 all the same.
- The water is a translucent layer over the bed (D57), as the originals'
  shallows show the sand through, its surface unshadowed. It is within
  2.2 levels of the art and its grain, where flat water was up to 6.2
  levels off with a fifth to a half of the grain. le01's shallows under
  the right-hand cliff read darker than the art.

`mise run terrain:mod` packages the twelve as a mod, Recovered Levels
(`plugins/recovered_levels`, off by default): each project drawn lit, with
its occlusion, as the level's map, and the original's level record
otherwise. It is a campaign on Level Select beside Classic Levels. Its maps
were drawn before the water layer, with the water flat; `terrain:mod`
draws them again with it.

Each level's scores are in `work/recovered/leNN/compare.txt` and
`compare-occlusion.txt`, with side-by-sides. `work/` is not committed: it
holds the original art. The projects are a starting point for artists, not
finished levels.
