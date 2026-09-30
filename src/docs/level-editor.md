# Level editor and remastered levels

Progress on [notes/level-editor-plan.md](../../notes/level-editor-plan.md),
stage by stage. The decisions are D51–D60 in [decisions.md](decisions.md).

| Stage | Status | Where |
|---|---|---|
| 1 — Plugins own their content folders | **complete** | D51 |
| 2 — Data plugins found at startup | **complete** | D52 |
| 3 — Campaigns; the originals become Classic Levels | **complete** | D53 |
| 4 — Optional level fields, launch flags | **complete** | D54 |
| 5 — Terrain renderer, le07 proof of concept | **complete** | D55, below |
| 6 — Recovering the 12 originals' heightmaps | **complete** | D56, D57, below |
| 7 — The editor | **complete** | D58, below |
| 8 — Materials, structures, placement | placement, materials and level properties **complete**; structures and helpers not started | D60, D61, below |
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

`mise run terrain:recover`, `terrain:occlusion`, `terrain:relight` and
`terrain:report` on all twelve, 2026-10-01, sun 36° and 40° up for each.
The shadow IoU is drawn with the occlusion layer, as the game draws it (the
plan's bar: 0.75). `terrain:relight` fits the colour to that layer (D59),
so the draw without it is darker in the art's shadows than the art and is
kept for reference. The water is scored by its mean colour difference from
the art, in levels of 255, and its grain as a share of the art's (D57).

| Level | Map | Shadow IoU | Without occlusion | Shadow light, render / art | Fitted azimuth (cast IoU) | Water: levels off, grain |
|---|---|---|---|---|---|---|
| le01 | `cam1` | **0.973** | 0.833 | 0.43 / 0.43 | 36° (0.791) | 0.2, 1.02 |
| le02 | `cam2` | **0.844** | 0.758 | 0.42 / 0.41 | 38° (0.670) | 0.3, 0.95 |
| le03 | `ism1` | **0.977** | 0.841 | 0.38 / 0.37 | 36° (0.785) | 0.1, 1.00 |
| le04 | `cam3` | **0.974** | 0.778 | 0.44 / 0.44 | 36° (0.754) | 0.1, 1.00 |
| le05 | `jum3` | **0.897** | 0.741 | 0.44 / 0.43 | 36° (0.642) | 0.3, 1.02 |
| le06 | `inm3` | **0.977** | 0.815 | 0.46 / 0.46 | 36° (0.784) | 0.2, 0.98 |
| le07 | `jum2` | **0.968** | 0.880 | 0.38 / 0.38 | 36° (0.718) | 0.2, 0.98 |
| le08 | `ism3` | **0.957** | 0.887 | 0.34 / 0.33 | 36° (0.792) | 0.3, 0.98 |
| le09 | `ism2` | **0.976** | 0.831 | 0.38 / 0.38 | 36° (0.773) | 0.1, 1.00 |
| le10 | `inm2` | **0.951** | 0.804 | 0.48 / 0.48 | 36° (0.744) | 0.2, 0.92 |
| le11 | `jum1` | **0.929** | 0.805 | 0.44 / 0.43 | 38° (0.690) | 0.2, 0.99 |
| le12 | `inm1` | **0.949** | 0.811 | 0.47 / 0.46 | 36° (0.740) | 0.4, 0.96 |

All twelve pass, and the shadow is as dark against the ground around as
the art's to within 0.01. The fitted azimuth lands on the measured 36°
or next to it, so the heights cast their shadows where the art's fall.

- **le02 and le05 are the weakest**, and their heights' cast IoU is the
  lowest too (0.670, 0.642): more of their shadow is kept by the colour
  than cast by the heights.
- **le09's range fit reached 960 px**, the most the fit tries, so its
  relief may be clipped short; its IoU is 0.976 all the same.
- The water is a translucent layer over the bed (D57), as the originals'
  shallows show the sand through, its surface unshadowed. It is within
  0.4 levels of the art and 0.92 to 1.02 of its grain, where flat water
  was up to 6.2 levels off with a fifth to a half of the grain. Its edge
  follows the ground under it, not the smoothed ground, so the shore
  matches the art's (D59).
- **Before the relight (D59)** the colour was divided without the
  occlusion, which the game then added, so the shadows under cliffs drew
  darker than the art: 15–39% of the land was more than 20% darker, now
  0.1–3.5%. The IoU without occlusion was then 0.800–0.964, and with it
  0.714–0.890.

`mise run terrain:mod` packages the twelve as a mod, Recovered Levels
(`plugins/recovered_levels`, off by default): each project drawn lit, with
its occlusion, as the level's map, and the original's level record
otherwise. It is a campaign on Level Select beside Classic Levels.
`terrain:mod` draws the maps again after a relight.

Each level's scores are in `work/recovered/leNN/compare.txt` and
`compare-occlusion.txt`, with side-by-sides. `work/` is not committed: it
holds the original art. The projects are a starting point for artists, not
finished levels.

## Stage 7: the editor

`deimos-editor` (`editor/`) sculpts a level project's ground, and sets its
light, water and wind. `mise run editor [project]` builds and opens it: on
a project, or a new level 480 wide and 3600 long (`-new=ROWS` for another
length). `mise run editor:shot` draws one frame headlessly, with flags for
the view and the tab. `build:linux` and `build:windows` build it beside the
game, and `dist` puts it in the release zip.

The window is the panel on the left, the level in the middle, the whole
level on the right with the part in view outlined, and a status line. The
panel has Open, Save, Undo, Redo and New, then seven tabs:

- **Terrain:** the brush. Raise, Lower, Flatten toward a target height, or
  Smooth, in a round, square or rough shape, with a size, a strength and a
  soft edge. Right-click takes the ground's height as the target.
- **Paint** (Stage 8, below): the materials and their brush.
- **Light:** live lighting on or off, the sun's direction and height, the
  ambient share and colours, the softness. Copy and Paste carry the light
  between levels as JSON on the clipboard (a level record's light pastes
  too), and Reset to original loads the measured light.
- **Water:** its height, shown or hidden, its colour; and the wind's
  direction and strength.
- **View:** 1x or 2x, and a tilted view to look at the relief.
- **Units** (Stage 8, below): the level's units.
- **Level** (Stage 8, below): the level's names, words, music and sky, and
  the weapons it starts with.

The wheel scrolls up and down the level, Shift+wheel across it at 2x,
middle-drag pans, and clicking the overview goes there. Ctrl+Z, Ctrl+Y and
Ctrl+S undo, redo and save; 1-4 pick the brush, `[` and `]` size it, `L`
and `T` toggle the light and the tilt. A project dropped on the window
opens.

### How it draws

The viewport is the Stage 5 renderer drawing the rows in view into a
texture of their size (`render_into`), again only when they scroll or
change. A dab uploads just the region it changed (`renderer_update`): the
ground is smoothed by σ 1 on the CPU, so a change spreads by the
smoothing's radius, m = ⌈3σ⌉. The region is grown by m and computed from
the heights grown by 2m. The renderer's test draws an edited region
uploaded this way and the whole project uploaded afresh, and they are the
same bytes in all four outputs. The editor's test finds the same after a
stroke, its undo and its redo.

The tilted view is the lit rows on a mesh of the heights, one vertex every
2 px or more, under 65,535. It is framed on the ground's mean height and
backed off by the relief above it. It is for looking at: the brush works
on the top-down view.

The renderer's refactor leaves its output as it was: le07 drawn by the
committed tool and the new one compares byte for byte, IoU 0.937 without
the occlusion and 0.890 with it, as the Stage 6 report has.

### Undo

A stroke keeps the 32 x 32 tiles of the heights and the water layer it
touches, as they were before its first dab. Undoing swaps them back, so
the edit then holds what was undone, for redo. A change of the light,
water or wind keeps the settings before it, and a slider's drag records
once, when it is let go. Undo keeps 256 edits, or 512 MB of tiles,
whichever comes first, and always the newest. A tile was 8 KiB, so a
stroke over the whole of an original level kept 14 MB. With Stage 8's
material weights a tile is 12 KiB, and the whole level 21 MB.

### Water that follows the ground

Ground lowered under the water, where the water layer has none, gets the
level's water colour, opaque. Ground raised out of it loses its water.
Recovered water's colour and opacity are otherwise left alone: some
recovered pixels under the water are legitimately clear (on le05, 2670 of
them), so the renderer cannot read "no water" into a clear pixel. A level
without a water layer shows the water colour wherever the ground is under
it, as before.

### Closing with unsaved changes

raylib cannot take back a window's close, so the editor does not ask.
Unsaved work is written beside the project as
`<level>.unsaved.drproj.json`, and Open and New ask for a second press
before they discard it.

### Verified

`tests/editor` (under xvfb-run in `mise run test`):
- strokes of every mode and shape, across tiles and the water line, undo to
  the bytes they started from and redo to the bytes they left;
- undo keeps to its budget;
- the water follows the ground;
- the settings undo as one;
- the light's JSON round-trips, a level record's light parses;
- the editor's shot of a fixture project has in its viewport the
  renderer's own lit rows, value for value, and a panel drawn;
- a stroke through the editor draws as a fresh upload, and so do its undo
  and redo;
- Stage 7's exit, when `work/recovered/le07` is there: open le07's
  project, sculpt in each mode, relight, change the wind, save, open again,
  and find the heights, water layer, light, wind and water as saved.

### Not as planned

- **`sim.register_all()` waits for Stage 8.** The editor reads no unit
  definitions until it places units.
- **Undo keeps the heights and the water layer**, not the splat weights:
  nothing paints materials until Stage 8's brush, which will add them to the
  tiles.
- **The project format** was Stage 5's, and needed no change. The placements
  arrive with Stage 8.
- **A Stage 5 bug** read the 16-bit PNGs as twice their length
  (`transmute` keeps the byte count); it now uses `slice.reinterpret`.

### Still open

- Brushing on the tilted view.
- The frame time with a large brush is not measured: only software GL
  under xvfb was at hand, and a dab redraws the rows in view.

## Stage 8: placement

The Units tab places the level's units. The Paint tab's materials and the
Level tab's properties follow, below. Structure footprints and the
placing helpers are still to come.

- **The palette** lists every unit with a preview face
  (`editorPreviewSpriteFace_ID` not `none`), by name: 134 of the
  originals' 386, among them all 114 types the twelve levels place, and
  any data plugin's. Both, Ground and Air filter the palette and the map.
  The chosen unit is shown as it will look.
- **On the map:** a click on a unit selects it, and a drag moves it. A
  click elsewhere puts down the palette's unit and selects it, and the
  same drag positions it. Right-click a unit to make its kind the
  palette's. Delete removes the selected one, Q and E turn it by 15°
  (Shift: 1°), Esc selects none, and U shows or hides the units in every
  tab. Outside the Units tab they are drawn fainter, and the brush works
  as before.
- **The selected unit:** its id, name, point and layer. It has a heading
  slider when the level sets its heading. Its Stationary checkbox shows
  where its unit allows one (papu, pasc, tala, tapu) or the level already
  sets it. It has a Terrain effects checkbox and a Delete button. Under
  them is what follows from the record: the row the screen's top reaches
  when it spawns (the unit's row + 64, which is also drawn across the
  map), its group size and chance where the unit has them, and the units
  its first state spawns.
- **The overview** shows a dot per unit: amber on the ground, blue in the
  air.

`mise run editor:shot -- -tab=units -select=N` draws the level's Nth unit
selected, with the view on it.

### Where a unit is

A ground placement's x is the map's column. An air placement's x is the
play field's, which starts 32 columns into the map (`DAT_004e34b8`, now
`sim.GROUND_PLACEMENT_SHIFT`). y is the map row for both. Whether a
placement is on the ground is decided by its unit's `isGroundBased_BOOL`,
as the spawn decides it. The record's layer (`grnd` or `air `) is written
from that when a unit is placed, and is used only for a unit this build
does not have. A sprite is drawn centred on its point, as `U_Sprite_Draw`
draws it. On le07, the recovered map's baked pads sit under their bases.

### How a unit looks

The original editor is not in the release, so what its preview flags mean
is our reading:

- the preview face and frame, when `usePreviewAppearanceInPlacementEditor`
  is set or the unit's first state draws nothing (pause markers and
  detectors: the paw and scroll icons of `EDPR`, and `grob`'s red square);
- otherwise the first state's sprite. Where
  `initialHeadingSetInEditor` is set it faces the heading, by the game's
  own rounding (`sim.state_frame_for_angle`, which
  `G_Entity::GetFrameForAngle` now calls too). Otherwise it shows its
  least frame: the game rolls a frame between the least and the most.

Only units with `initialHeadingSetInEditor` take the level's heading: the
spawn gives the others their own. So only they get the slider and the
keys. A heading another unit's record already has is kept as it is.

The units a unit spawns (a platform's turrets, for one) are not drawn:
they come from its states, not from the level.

### Undo

A change to the units keeps the whole list before it, a few hundred
records at most (le07 has 38). An undo swaps the list back, as the tiles
are swapped. A drag, a heading slide, a placement and a deletion each
record once, when the mouse is let go. A change that ends where it began
records nothing.

### Loading the units

`main` now calls `sim.register_all()` first (D50). It discovers the data
plugins, declares them and registers every registry, then loads the
definitions and sprite plates from `$DR_ASSETS` (or `./assets`) and the
plugins. A plate's texture loads when it is first drawn. Without the
assets tree the palette is empty and the tab says so. The editor imports
no compiled plugin, so the chaingun's and New Weapons' units, which have
no preview faces anyway, are not in it.

The project keeps the units as a list of their own, which the editor
grows and shrinks. It is lifted out of the level record on open and
written back on save, so the file format is unchanged.

### Verified

`tests/editor`, on fixture units, without the original data:
- the palette is the units with a preview face, sorted by name, and the
  layer filter keeps the ground's or the air's;
- ground and air placements map to the map and back, and a unit this
  build lacks goes by its layer;
- the look follows the flags: least frame, heading frame (8 directions:
  90° is frame 2, 350° wraps to 0), preview when asked for or when the
  state draws nothing;
- placing, a ten-step drag, a turn and a deletion each undo to the list
  before and redo to the list after; a change back to the start records
  nothing;
- the history's byte count follows the lists as they swap;
- picking takes air over ground and the later over the earlier, and
  obeys the filter and the frame's size (at least 6 px);
- placements save into the level record and open as they were;
- a unit placed in view is drawn there, its frame centred on its point;
- in Stage 7's le07 case, le07's 38 placements come back from save and
  reopen unchanged.

`oracle:diff` is exact after the two changes to `sim/`, and tests/golden
is unchanged.

### Not as planned

- **The palette is the editor build's units:** the originals' and every
  data plugin's. A compiled plugin's units appear only if the editor
  imports that plugin, and none does. Export recording a plugin
  dependency waits for Stage 9, which writes the plugin.
- **The stationary checkbox also shows where the level already sets
  it**, so that a stationary unit can be seen and cleared.

## Stage 8: materials

The Paint tab lays the ground's materials, up to four a level. A
material is either a plain colour or an image tinted by its colour.

- **The list:** the level's materials, with their colours. Add a colour
  adds a plain one, and Remove takes the chosen one away. Its Tint is the
  colour an image is multiplied by. An image's Tile is how many map
  pixels one copy of it covers.
- **An image dropped on the window** is added as a material. It is named
  after the file, lower case and dashed (`Rock Face.png` becomes
  `rock-face`). It is scaled to fit 1024 px, and tiles at its own width,
  or at most 256 px. It is kept in memory and written to the project's
  `materials/` when the project is saved, so a project stands alone, and
  Stage 9's export takes the folder with it.
- **The library:** materials to start a level from. Add from the library
  copies one into the project as a dropped image is copied.
- **The brush:** Paint moves every weight toward the chosen material, and
  Erase takes that material away. Both use the Terrain brush's shapes,
  size, strength and falloff. Keys 1 and 2 pick Paint or Erase.
- **Laid by the ground:** Steep lays a material by the slope, By water by
  the height above the water, and Under trees under a recovered level's
  canopy. These rules were the renderer's since Stage 5; now they can be
  edited.

A level's weights start empty. The first stroke makes them: an RGBA layer,
one channel a material, saved beside the project as
`<level>.splat.png`, as the plan's project format has it. Where the
weights sum under full, the unlit colour shows through. A level without
one, as a new level is, shows its first material there. So a weight at
half shows half, and not all, of the one painted.

### Tiling that does not repeat

The originals' ground never repeats (the findings: autocorrelation peaks
0.03–0.04). A tiled image repeats every tile. The renderer hex-tiles an
image material (Mikkelsen, "Practical Real-Time Hex-Tiling", JCGT 2022):
- A triangle grid is laid over the image, about 3.5 corners a tile.
- Each corner's copy of the image is moved by its own random offset.
- The three nearest are blended by how near each corner is, sharpened by
  their brightness (contrast 0.6, exponent 7). So they meet along the
  image's features rather than fading through each other.

The copies are moved but not turned: a dropped photograph's light has a
direction, which a turn would scatter. This is provisional; a per-material
switch for turns would settle it, and nothing needs one yet. The images
are mipmapped and read with the map's own derivatives.

### The starting library

`mise run materials:library` makes it, from the recovered levels' unlit
colour (`work/recovered`, `mise run terrain:recover-all`), into
`assets/materials`. That is where the editor looks, and it is committed
with the rest of the assets tree. `tools/materials/library.json` is the
recipe. For each material, the most uniform 128 px window inside a box of
one level's albedo is found. Most uniform means the least spread of its
16 px blocks' mean colours, so the window is one ground and not an edge
between two. The window is quilted (Efros and Freeman 2001) into a 256 px
image that tiles, and listed in `index.json` with where it came from,
tagged `original-derived`:

| Material | From (x,y, size) | Tile |
|---|---|---|
| red dust | le01 256,904, 128 | 256 |
| rust plain | le02 224,1212, 128 | 256 |
| olive silt | le03 176,1584, 128 | 256 |
| slate | le05 64,608, 128 | 256 |
| tan sand | le06 288,976, 128 | 256 |
| grey rock | le07 0,196, 128 | 256 |
| jungle | le07 256,1160, 192 | 384 |
| dry grass | le10 160,0, 128 | 256 |

The quilt lays 40 px blocks overlapping by 8. Each block is one of those
of the exemplar within 30% of the best's error at the overlap, chosen at
random, and joined along the cheapest seam. The blocks wrap around the
image's edges: the last in a row or column is joined to the first as to
its neighbours, so the image tiles. The paper's 10% repeated the red
dust's pebbles within one tile; 30% did not, with seams no worse. The
jungle's trees repeat inside 128 px, so its exemplar is 192. A scrub
material from le11 was dropped: its quilt repeated in visible blocks.

### Undo

A stroke keeps the weights with the heights and water in its 32 x 32
tiles. Adding or removing a material keeps the materials before it, with
their images and the rules that name them. Removing one also keeps every
tile of the weights, because the channels above it move down one. The
rules renumber to follow them, and a rule for the removed material is
cleared. A tint, a tile size or a rule is a setting, undone as the light
is.

## Stage 8: the level's properties

The Level tab edits:
- the level record's name and identifier;
- its description and copyright, the words the originals' campaign
  screens had;
- its music, briefing and sky;
- the air and ground weapons a player starts it with (D54), from the
  weapons of each kind, or none for what the level's number brings.

A text box's change counts once it is left, and undoes as a setting. The
wind stays in the Water tab, where Stage 7 put it.

The description, copyright and briefing were in the originals' records
and in `plugins/classic_levels/data/levels/`, but the game's level
record did not read them, so a project lost them. It now keeps them.
The game does not show them yet.

### Verified

`tests/terrain` and `tests/editor`, without the original data:
- a material's image is written under `materials/` on save and reads
  back;
- weights made after the renderer's upload, and a region of them
  changed, draw as a fresh upload does;
- without an unlit colour, a weight at half shows half;
- an image material tiled 16 px draws the pixel a tile along alike less
  than 10% of the time (a plain tiling: always);
- a quilt of a pattern that repeats every 8 px is that pattern
  throughout, across its own wrapped edges, and the same seed quilts the
  same; the most uniform window of half flat, half gradient is in the flat
  half;
- a held brush arrives at all of the material, the weights never sum past
  full, erasing takes it away, and nothing outside the brush changes;
- a painted stroke undoes and redoes to the weights' bytes;
- a look, the rules and the properties undo as one setting;
- the properties save and read back;
- a fixture library loads, and so does the committed one: every image
  256 px and tagged `original-derived`;
- through the editor: a library material and a dropped image are added
  and named, two strokes paint, and draw as a fresh upload; removing a
  material moves the weights above it down and draws as a fresh upload,
  and its undo restores the weights and the drawing; the save writes the
  images, and the project opened again has the same weights and the same
  drawing.

### Not as planned

- **The rules were already there.** The cliff, shore and canopy rules
  came with the Stage 5 renderer. They are now edited, as "Laid by the
  ground".
- **The level's wind** is in the Water tab, as Stage 7 built it, not
  under the level's properties.
- **The library is made by `materials:library`, not `assets:all`.** It
  needs the recovered projects, which need the recovery's models, not
  only the installer. It is committed, so it is there without them.

### Still to come in Stage 8

- Structure footprints: the `levels:bases` measurement, the footprint
  shown live under its unit, and baked on export (Stage 9).
- The helpers: the obstacle tool (`grob`) and the vent group (`geys` with
  its detector).
