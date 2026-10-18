# 3d to 2d pipeline: Task 1 findings

Task 1 of [headless-3d-to-2d-pipeline.md](headless-3d-to-2d-pipeline.md):
look for surviving 3D art, and learn how the original levels were built.
Investigated 2026-09-28.

**[V]** means verified from bytes, code or images, with the evidence named.
**[I]** means inferred. Working files are in `work/pipeline-investigation/`
(ignored by git). That folder holds two longer reports,
`editor-findings.md` and `provenance-findings.md`, plus the archived
making-of article in `web/` and the comparison images.

## Bottom line

- **No 3D source survives in anything we have [V].** The PAKs, `Data/Local`,
  the installer, both binaries and the new addons archive hold only final
  renders and text records. There are no Bryce or Cinema 4D scenes, and no
  heightmaps, meshes or textures. Anything 3D has to be rebuilt.
- **The developers named their tools [V].** "The Making of Deimos Rising",
  by Sheryn and David Wareing, appeared in Inside Mac Games on 2002-03-26.
  It is archived at
  <https://web.archive.org/web/20190131092913/http://www.insidemacgames.com/features/view.php?ID=122&Page=1>
  (pages 1–5). What it says:
  - Terrain and buildings were made in **Bryce 3D**, as top-down renders.
  - Sprites were made in **Cinema 4D XL**, with separately rendered alpha.
- **The level editor only placed units [V].** Terrain was never edited in
  the game's tools. A level is:
  - one pre-rendered 480x3600 image;
  - a 96x720 water mask;
  - a 146x306 preview;
  - a flat list of unit placements.

  No record holds height, lighting, tile or texture-layer data.
- **The editor is not in either shipped build [V].** Its art and data fields
  ship; its code does not. This corrects D21 in `src/docs/decisions.md`.
- **Rebuilding the scene from the image is feasible as a starting point
  [V].** Depth estimation followed by shadow-matched refinement reproduces
  91% of the art's cast shadows (IoU). The ground textures never repeat, so
  they have to be resynthesised rather than cut out as tiles. For details
  see "Recovering the 3D scene from the image" below.

## What the developers said about the art

All of this comes from the making-of article; the text is in
`web/making_all.txt`.

- **Bryce, top-down.** "Using Bryce for top-down rendering was unexplored
  territory." The scenes were "huge", took "sometimes over 24 hours" to
  render, and crashed Bryce. They worked on textures "to avoid that
  distinctive 'Bryce' look".
- **Stylised, not realistic.** They started from satellite-photo realism
  and moved to "a slightly abstract, even cartoonish look… broad areas of
  colour". They also removed clutter and roads.
- **Exaggerated height for shadows.** "Terrain height was exaggerated to
  produce stronger shadow lines, giving a better impression of height and
  contrast in an otherwise 2D image."
- **Buildings baked into the render.** "The main part of the building was
  created or imported in Bryce, placed on the terrain and rendered to
  achieve consistent lighting and shadows." At runtime a sprite is laid
  over the baked base.
- **The palette was chosen to suit the effects.** "Sheryn designed the
  background palette to enhance the game's special effects."
- **The scene layout.** The article's `Bryce1.jpg` is a top-view wireframe
  of a scene (`web/img/`). It shows a grid of tiled terrain objects,
  instanced tree clusters, and building objects. Bryce terrain objects are
  greyscale heightmaps, so our heightmap-plus-sun guess matches the
  original method.
- **Sprites.** The 2000 deimosrising.com tank page (in `web/dr2000/`) says
  tank bases are "rotated in 16 directions" and turrets "rotate over 24
  frames". The Shuriken is a 6-frame loop with its alpha rendered
  separately.

## How a level is built

### The level record [V]

The record is parsed by `FUN_00429b70` in G_Level.cc and decoded into
`src/assets/data/levels/*.json`.

**Header fields:**

- name, identifier, description, copyright;
- `background_RECT`, always `0,0,480,3600`;
- background, preview, music, media mask and briefing IDs.

**Each placement:**

- unit, layer (`grnd` or `air `), x, y, heading;
- `isStationary`, FALSE in all 565 placements;
- `enableTerrainEffects`.

**No height, lighting or texture data exists** in level, unit or any
other records.

Scenery features are placed units, not terrain data:

- Scenery collision uses 33 invisible `grob` "Ground Obstacle" units.
- The gas vents are `geys` units.
- The baked shapes in the image are only art.

### Art sets [V]

There are 4 themes × 3 variants, and each variant has three 16-bit
(xRGB1555) TGAs:

| Theme | Map (480x3600) | Mask (96x720) | Preview (146x306) |
|---|---|---|---|
| Canyon | `cam1-3` | `cat1-3` | `cap1-3` |
| Industrial | `inm1-3` | `int1-3` | `inp1-3` |
| Island | `ism1-3` | `ist1-3` | `isp1-3` |
| Jungle | `jum1-3` | `jut1-3` | `jup1-3` |

- **Every map is a separate render;** 12 levels use 12 maps.
- **Level 1 in play order is `le07` "Mariner Valley":** map `jum2`, mask
  `jut2`, preview `jup2`. The order is in `sim/defs.odin`, from 0x4e7ba9.
- **Every level is credited "Map by Sheryn Wareing."**
- **Which tool saved each file [V].** The PAK ZIP entries keep Mac creator
  codes:
  - The maps and masks were saved by GraphicConverter (GKON), each mask
    within minutes of its map, between Sep and Nov 2001.
  - The previews were saved by Photoshop (8BIM). Only the previews carry a
    TGA 2.0 footer.

### Media (water) mask [V]

- **Scale.** `G_Bgnd_Load` (0x40fe40) asserts that the mask has the map's
  aspect ratio. Each mask pixel covers 480/96 = 5×5 map pixels.
- **Values.** A pixel is water only if it is exactly 0x001F, pure blue
  (`G_Bgnd_MediaMask_GetSurfaceAtLoc`, 0x410120). All 12 shipped masks are
  white and pure blue, apart from one stray grey pixel in `int3`.
- **What it does.** Its only effect: a ground unit dying over water leaves
  a splash (`MediaImpact_Water_*`) instead of wreckage. The port already
  does this in `src/sim/lifecycle/destroy.odin`.
- **How it was made [I].** It was probably painted over the finished map,
  judging by the save times. It is not a render pass: its edges are blocky
  at 5 px.

### Preview [V]

- **It is a crop of the map, not a new render.** Each preview is a
  438x918 crop of its map, downscaled exactly 3×, then given a vignette and
  a warmer, softer tone. Template matching at scale 3.00 finds all 12, with
  scores from 0.93 to 0.97.
- **Two came from earlier renders.** `jup2` (0.88) and `jup3` (0.73) match
  worse. Their files are dated months before their maps, so they were cut
  from earlier renders.
- **The game loads it as-is.** It is a separate TGA (`FUN_0042b4e0`);
  nothing generates it at runtime.
- **A correction.** I first read `cap1` as a perspective render because
  its silos looked side-on. The uniform 3× scale on both axes rules that
  out.

### Runtime changes to the terrain [V]

The only changes are sprites stamped into the single terrain buffer:

- `stateDrawToTerrain` draws tracks and craters.
- `destructDrawToTerrain` stamps wrecks, from 32 units.

## The level editor and developer tools

**What ships [V]:**

- The editor's panel `edpa` (112x480, reading "Map Info / Layer / Unit
  Info") and the background `BIGR`.
- Its button sheet `EDBU`: New, Open, Save, Quit, ground and air layer,
  scroll up and down, rotate left and right, obstacle, tick, info.
- Its preview icons `EDPR`, the `EDUT` icons, and the string list
  `stli/edit` ("New Level Settings", "Level Info").
- The unit-definition fields `usePreviewAppearanceInPlacementEditor`,
  `allowStationaryOptionInPlacementEditor`, `initialHeadingSetInEditor` and
  `editorPreviewSprite*`. They are parsed and ignored.

**What doesn't ship [V]:**

- **No editor code.** In the Windows exe, the copies of `edpa` and `edit`
  in its tag tables are never read, and `edbu`, `edut`, `edpr` and `BIGR`
  never appear. A scan of the Mac 1.0.6 PPC code finds no editor FourCC.
- **No record writer.** Its "// Do not edit … by hand" banners are left in
  `.rdata` with no references.
- **No way in.** No key, menu or flag reaches the editor.

**How the editor ran [I].**

- **It was a developer build of the game.** 169 `unde` and 5 `leve`
  records carry the game's own creator code (`Deim`), so they were saved
  by it. The rest were hand-edited in CodeWarrior (`CWIE`).
- **It placed units and nothing else.** The editor used the 480-wide map
  view beside the 112-px panel. You dragged units onto the finished image
  and set their heading and flags. "Level Info" set the header fields.
- **The unit, player and sprite editors were separate.** The making-of
  shows them, and none of them ships either.

**The console [V].**

- **How it opens.** Tilde opens it (`G_GameInterface::Process_StartFrame`,
  0x4230f0).
- **What is registered.** `G_Console_RegisterCommand` (0x4114e0) skips
  every debug-only command. Only 10 remain: FPS, VERSION/VERS, the cheat
  unlock, and LIFE, ACCURACY, FUNDS, SCORE, SHIELDS, MULT.
- **The dead terrain commands.** BACKSIZE, ERASEBACK, JUMP, SCROLL, ROW,
  LOGMEDIA, MEDIASIZE, MEDIA, LEVELSPAWNS and REVERSE are compiled in but
  never registered.
  - None of them edits terrain.
  - MEDIA overlays the mask on the map.
  - ERASEBACK blanks the map to white, "useful for testing unit
    positions".
- **The full table** is in `editor-findings.md` §2.

## What the images show about the lighting

I measured these on the maps. They are the targets for Task 2.

- **Camera [V/I].**
  - It is orthographic and top-down. The previews' uniform 3× scale and
    the maps' parallel cliff shadows both show this.
  - The map is 480 px wide, and the play area scrolls it.
- **Sun direction [V on cam1].**
  - Silo shadows in `cam1` fall toward the lower left of the image, so
    the sun is at the upper right.
  - Cliff shadows on the other maps look the same by eye. I did not
    measure them.
  - I have not estimated the sun's elevation, because the silo height is
    unknown. The making-of's exaggerated height suggests a fairly low sun
    [I].
- **Ambient light [V on cam1].** Grass in a silo shadow is 0.44× the
  brightness of lit grass beside it, on all three channels equally:
  (46, 41, 25) against (106, 93, 55). So the ambient or sky light is
  neutral, not blue, and the shadow keeps about 44% of full light.
- **Shadow edges [V].** They are slightly soft, with a penumbra a few
  pixels wide.
- **Materials [V by eye].**
  - Broad blended regions of grass, dirt, sand and rock.
  - A sand band where land meets water.
  - A darker fringe in the shallow water.
  - Slopes get cliff or dirt textures.
  - Colours are grainy rather than smooth, from texture noise and the
    1555 quantisation.
- **Water [V by eye].** A flat teal plane that meets the terrain at the
  shore.
- **Vegetation [V by eye].** Instanced trees and palms, as the wireframe
  shows. Jungle canopy can fill whole regions (`jum*`).
- **Buildings [V].** Silo and base footprints are baked into the render,
  with their shadows.

## What this means for Task 2 and the new features

These are all inferences [I].

- **Rebuilding is the only route.** An HD re-export of the original art
  would require rebuilding it; upscaling can't add the missing detail.
- **What a faithful rebuild needs:**
  - a heightmap terrain with exaggerated vertical scale;
  - an orthographic top-down camera covering 480 px of width;
  - a directional sun from the upper right of the image, plus neutral
    ambient at about 0.44 of full light;
  - soft cast shadows;
  - materials blended by height, slope and painted weights;
  - a flat water plane with a sand band;
  - instanced trees.
- **Outputs to match the original:**
  - the map, quantised to 1555;
  - a mask at 1/5 scale, with water as pure 0x001F blue;
  - a preview: a 438x918 crop downscaled 3×, with a vignette.
- **The deferred-rendering outputs come nearly free.** A raylib render
  already has albedo, normals, height and a shadow term. The notes' request
  for a separate shadow mask maps directly onto the shadow term. The
  original bakes shadows into its colours, so they can't be separated from
  the shipped art. That is another reason to rebuild rather than
  post-process.
- **How to compare a rebuild.** Compare `jum2` against a render of a
  hand-built `le07` heightmap. Use the 0.44 shadow ratio and the sun
  direction as the numbers to hit, before judging by eye.

## Recovering the 3D scene from the image: a feasibility check

This was a quick headless try on 2026-09-28, to see whether known
techniques can recover terrain from the art. Scripts and images are in
`work/pipeline-investigation/recon/`. Everything ran on CPU, in a few
minutes.

**Method.** The test crop is `cam1` rows 1100–2000. Each candidate
heightmap was re-lit with ambient light at 0.44. A grid search then fitted
height scale and sun angle, scoring each fit two ways:

- how well its cast shadows overlap the shadows detected in the art
  (IoU);
- how well its shading correlates with the original's luminance.

Flat terrain and smoothed noise are the baselines.

| Heightmap | Shadow IoU | Shading correlation |
|---|---|---|
| Flat | 0.00 | — |
| Smoothed noise | 0.27 | 0.02 |
| Linear shape-from-shading (Pentland) | 0.29 | 0.21 |
| Depth Anything V2 Small, fitted | **0.46** | **0.51** |

**Findings:**

- **Shape-from-shading fails [V].** It scores no better than noise, and
  its heightmap is streaks along the light direction. The broad painted
  colour areas swamp the shading, as the developers intended.
- **Monocular depth works as a starting point [V].**
  - Depth Anything recovers the terraces, the river valley, the silos and
    the tree canopy.
  - Its best fit lands on sun azimuth 36°, the direction measured by hand
    on the silos, with elevation about 25–30°.
  - The fitted height range is about 640 px over a 480-px-wide map. That
    is strongly exaggerated, as the making-of says.
- **Where it misses [V]:**
  - Small objects come out too tall; the silo shadows are far too long.
  - One global height scale can't fit every cliff.
  - On jungle (`jum2`, level 1), the canopy becomes bumpy terrain. It
    would need masking off and rebuilding as instanced trees.
- **Shadow removal half-works [V].** Dividing the detected shadows by
  0.44 gives a plausible unlit colour layer, but leaves halos at the
  shadow edges.

**What it would take [I].** Rebuilding from the images is feasible as a
base, not as a one-click result. A usable pipeline would take the depth
estimate and then:

- refine it against the detected shadows, by optimising heights so that
  the cast shadows match;
- classify vegetation and water separately;
- let an artist fix the rest in the Task 3 editor.

For the proof of concept, a depth-seeded heightmap of `le07` is a
reasonable place to start. So is sculpting one by hand, using the numbers
above as targets.

### Second round: bigger models, shadow refinement, textures

This round also ran on 2026-09-28, on the same crop and scoring. The
geometry and de-lighting models ran on CPU (diffusers, transformers,
torch). The generative models ran on the local lemonade server (Strix
Halo GPU). The scripts are in `work/pipeline-investigation/recon/`:
`models.py`, `refine*.py`, `delight_eval.py`, `textures.py`, `quilt.py`,
`upscale.py`, `vlm.py`.

**Geometry [V].**

| Heightmap | Shadow IoU | Shading correlation |
|---|---|---|
| Depth Anything V2 Large, fitted | 0.50 | 0.58 |
| Marigold depth v1.1 | 0.41 | 0.41 |
| Marigold normals, integrated (Frankot–Chellappa) | 0.35 | 0.15 |
| DA-V2-Large + shadow refinement, per pixel | **0.91** | **0.85** |
| DA-V2-Large + shadow refinement, 1/4-res offsets | 0.76 | 0.80 |
| same, fitted to the Marigold IID shading | 0.76 | 0.75 (0.88 vs IID shading) |

- **Shadow refinement is the big win.** The refinement is a
  differentiable renderer in torch:
  - a soft horizon test along the sun ray (logsumexp over 120 steps, then
    a sigmoid);
  - plus Lambert shading.

  It optimises the heights so that the rendered shadows match the detected
  ones and the shading matches the image, with a smoothness penalty on the
  change. Starting from Depth Anything, 300 Adam steps take under a
  minute on CPU. Shadow IoU goes from 0.50 to 0.91.
- **Per-pixel refinement cheats.** It carves hatching along the sun
  direction, making thin ridges that cast exactly the shadows wanted.
  Optimising a 1/4-resolution offset instead gives cleaner terrain at
  IoU 0.76, but still leaves some diagonal streaks. A proper version
  would need a stronger shape prior: a multi-scale offset, or a penalty on
  curvature along the sun direction.
- **Marigold v1.1 loses to Depth Anything** on this art for both depth and
  normals. Marigold V2 does not; see below. The integrated normals are the weakest. Marigold's normals are
  tuned for photographs and read the painted colour areas as slopes.

**De-lighting [V].** Each unlit colour layer is scored two ways:

- *Shadow contrast:* luminance inside the detected shadows divided by
  luminance in a ring just outside them (1.0 = shadow gone).
- *Shading correlation:* the layer's correlation with the refined
  heightmap's shading (0 = lighting gone).

| Unlit layer | Shadow contrast | Shading corr |
|---|---|---|
| Original art | 0.46 | 0.81 |
| Detected shadows ÷ 0.44 | 0.98 | 0.42 |
| Original ÷ refined-height shading | 0.76 | 0.30 |
| Marigold IID albedo | 0.91 | **0.25** |
| Original ÷ Marigold IID shading | 0.84 | 0.39 |

- **Marigold IID albedo** (`marigold-iid-lighting-v1-1`) removes the most
  lighting. Its material regions are clean: grass, dirt, sand, water and
  the silos. It also blurs the fine grain, because it runs at 768 px.
- **Dividing the original by the IID shading** keeps the full-resolution
  grain and still removes most shadows. It leaves faint halos where the
  shadows were. As an unlit base for texture work, this is the best of
  the layers.
- **The IID shading layer** looks like a clean hillshade of the terrain.
  As the refinement target it fits the lighting better (0.88 against
  0.85), but it does not improve the shadow IoU.

**Textures: nothing repeats [V].** This test ran on the whole `cam1`
map, de-shadowed. K-means (six clusters on Lab colour plus local texture
energy) roughly separates sand, dirt, grass, cliffs and trees, though
noisily. Two repetition tests were run on the flattest 96x96 patch of each
material:

- *Autocorrelation:* the highest peak away from the centre is 0.03–0.04.
  The one exception is 0.33 on the dark cluster, and that peak is only 5 px
  from the centre, so it is grain size, not a repeat.
- *Template search:* a 24x24 template's best match anywhere else on the
  map is 0.22–0.28. A tiled texture would score near 1.0.

So no image tile was repeated. The ground textures are non-tiling,
consistent with Bryce's procedural materials. Texture recovery therefore
means resynthesis, not extracting a tile.

- **Image quilting** (Efros–Freeman: 32 px blocks, 8 px overlap, min-cut
  seams) grows convincing dirt and grass from 96x96 exemplars:
  - dirt keeps its mean colour to within about 1 level, with a spectrum
    log-ratio of 0.18;
  - grass has a spectrum log-ratio of 0.11.

  The exemplars must come from a clean unlit layer. The dark cluster's
  exemplar was a shadow remnant and is unusable.

**Upscaling, lemonade RealESRGAN-x4plus [V].**

- Upscaling the real 480-px art 4x looks convincing: sharp silo rims and
  plausible grass grain.
- In a shrink-and-restore test (256 → 64 → 256 px) it scores 23.2 dB PSNR
  against bicubic's 24.0.
  - It invents a smooth photographic look and drops the grass grain.
  - Its high-frequency energy is 0.24 of the original, against bicubic's
    0.11.

It sharpens detail that exists, but can't recover detail that doesn't.
That is as expected: an HD map needs a rebuild, and ESRGAN can at best
sharpen one.

**Generative edits, lemonade Flux-2-Klein-4B [V].** The input was a
256x256 region with the silos, sent at 512 px. Each edit took about 30 s.
"Layout PSNR" compares the result with the original, both shrunk back and
blurred (σ 3).

| Edit | Shadow contrast | Layout PSNR | Colour shift | Detail vs bicubic |
|---|---|---|---|---|
| Original | 0.47 | — | — | 1.00 |
| "Remove all shadows and lighting" | 0.95 | 10.2 dB | 91 levels | 0.07 |
| "Same terrain under overcast sky" | 0.88 | 13.8 dB | 49 levels | 0.96 |
| "Re-render at high detail" | 0.41 | 15.7 dB | 37 levels | 2.54 |
| **Original colour + Flux detail** | 0.45 | **46.5 dB** | **0** | **2.52** |

- **De-lighting by prompt fails.** Asked to remove the lighting, Flux
  erased the terrain to flat grey and kept only the silos. The overcast
  prompt does drop the cast shadows, but it washes the colours out and
  reshapes the ground.
- **High-detail re-rendering works when split by frequency.**
  - On its own, the "HD" edit keeps the layout and the sun direction, but
    restyles the ground: bright lawn grass, grey gravel.
  - Taking only its fine detail (image minus a σ 3 blur) and adding that
    to the original's blurred colours gives a convincing 2x map. It keeps
    the original's colours, layout and baked shadows exactly, and has real
    grass blades, pebbles and sharp silo rims.

  This is the one route found to an HD version of the *existing* art. It
  is unproven beyond one tile. A whole map (480x3600, about 30 overlapping
  tiles, about 15 minutes) needs seam blending, and the detail style must
  stay consistent from tile to tile.

  **Update: now a tool [V].** `mise run hd:upscale` (in
  `src/tools/hd_upscale/`) runs this at 4x over a whole map, using
  diffusers instead of lemonade. It uses 256 px tiles with feathered
  overlaps, a resumable tile cache, and a manifest with per-tile checks. A
  prompt listing the materials made Flux invent ferns and a pool on bare
  rock (shrink-back error 11 levels). The conservative prompt "A sharper,
  higher-resolution version of this exact image. Do not add, remove or
  move anything." kept every tile tested faithful (2-5 levels), bunkers
  and palms included. On the Radeon 8060S a tile takes about 60 s, and
  `jum2` (level 1) is 32 tiles. The README has the measurements.

**Material labels, lemonade Qwen3.8-27B vision [V].** Each 60x60 cell of
the crop (120 cells, about 2 s each) got one word from a fixed list.

- Sand, dirt, grass and trees mostly land where they should.
- Against the water mask, it found 7 of the 15 water cells, with no false
  alarms. It calls the teal river "grass" at this tile size.
- It never labelled a cell with the silos in it "building".

It is no better than k-means for materials, and much slower. The shipped
water mask is exact anyway, so the model is only worth using for
questions a cluster can't answer: naming objects, or finding vegetation
to replace with instanced trees.

**Marigold V2 [V].** `huawei-bayerlab/marigold-v2-0` was released
2026-09-08. It is a set of LoRAs on Qwen-Image-Edit-2509 (a 20B DiT), with
a fine-tuned VAE decoder per task. It does depth, normals and albedo in a
single step.

It ran on the Strix Halo GPU (gfx1151), not CPU, using:

- the official code, with the base quantised to NF4 as it was trained;
- torch 2.11 from AMD's ROCm nightlies;
- bitsandbytes 0.50 on its ROCm 7.2 binary.

It needed three local fixes:

- MIOpen switched off, because its conv algorithm search fails on
  gfx1151 (`marigold-v2-rocm.patch`);
- `TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1` for flash attention;
- pandas 2.3.3 rather than 3.x.

Each task takes about 50 s including model load, or about 65 s at 2x
input. The venv is in `~/.cache/marigold-v2`; the weights are in the
Hugging Face cache, about 44 GB, with the text encoder not needed.

| Output | Shadow IoU | Shading corr | Compared with |
|---|---|---|---|
| V2 depth (Log-stage2) | **0.55** | **0.65** | DA-V2-L 0.50 / 0.58 |
| V2 normals, integrated | 0.44 | 0.34 | v1 normals 0.35 / 0.15 |
| V2 depth, input upscaled 2x | 0.55 | 0.54 | no gain |
| V2 depth broad shape + V2 normals detail | 0.53 | 0.50 | no gain |
| Shadow refinement from V2 depth, per pixel / 1/4 grid | 0.89 / 0.76 | 0.86 / 0.78 | from DA-V2-L: 0.91 / 0.76 |
| V2 albedo, shadow contrast / shading corr | 0.91 / 0.27 | | v1 IID 0.91 / 0.25 |

- **V2 depth is the best seed.** It gives the best unrefined heights, with
  crisper cliffs than Depth Anything. It also has a fine grid hatching on
  flat ground, which looks like the DiT's patch grid.
- **Refinement erases the difference between seeds.** After shadow
  refinement, the V2 and Depth Anything seeds end up about equal.
- **V2 normals** are the cleanest surface directions of any model here:
  sharp terraces, flat ground reading as flat, and each tree as its own
  dome. The v1 normals read painted colour as slope. Integrating V2
  normals to heights still loses to V2 depth, because the integration
  drifts at low frequencies. The sign convention was checked; the other
  three sign choices score 0.20–0.24.
- **V2 albedo** keeps the grass grain and each tree's shape, where v1 IID
  blurs them. It scores the same, but renders the river dark navy.
- **2x input doesn't help.** The 480-px crop already works at native size.

**Updated conclusion [I].** The rebuild route now has a working core:

1. seed the heights with Marigold V2 depth (or Depth Anything V2 Large);
2. refine them against the detected shadows with a differentiable
   renderer;
3. de-light with Marigold IID (dividing by its shading);
4. resynthesise ground textures by quilting from the unlit layer;
5. mask vegetation and water separately.

The weak spot is still shape bias in the refinement, which carves ridges
along the sun direction. Separately from the rebuild, frequency-split
Flux detail is a cheap way to an HD *copy* of the original art. That
suits a mod, never classic mode.

## Other sources checked

- **The addons archive** (`orig/deimos_addons.sit`, unpacked by
  `mise run addons:extract` into `work/addons/`) holds nothing first-party
  beyond copies of shipped art:
  - fan sprite mods;
  - demo films;
  - fan desktop pictures, which are the 640x480 menu background upscaled;
  - a fan AppleWorks file of Player Guide crops;
  - a fan's composite of level 12;
  - the soundtrack;
  - the Apple bundle update. Its HFS image holds the Mac 1.0.6 build,
    which needs hfsutils to open.
- **The remaster project** (adamjvr/Deimos-Rising-Remastered) confirms the
  image sizes, the 1/5 mask scale and the water value. It has nothing on
  the art pipeline or the editor.

## Leads not followed

1. **Ask the original artists.** Sheryn and David Wareing (Swoop Software),
   or John Sledd (sledd.com), are the only plausible holders of the Bryce
   and C4D scenes.
2. **The Mac CD**, which the remaster lists as DR-EVID-001, reportedly
   v1.0.3. It probably holds the same PAKs.
3. **Other archive.org captures** of the making-of's missing images:
   LevelEditor, UnitEditor, BryceCloseUp, ShurikenSprites.
4. **The `Cit2` creator code** on all 250 sprite GIFs, which would name
   the sprite export tool.
