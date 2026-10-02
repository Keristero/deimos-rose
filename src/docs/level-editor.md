# Level editor and remastered levels

Progress on [notes/level-editor-plan.md](../../notes/level-editor-plan.md),
stage by stage. The decisions are D51–D63 in [decisions.md](decisions.md).

| Stage | Status | Where |
|---|---|---|
| 1 — Plugins own their content folders | **complete** | D51 |
| 2 — Data plugins found at startup | **complete** | D52 |
| 3 — Campaigns; the originals become Classic Levels | **complete** | D53 |
| 4 — Optional level fields, launch flags | **complete** | D54 |
| 5 — Terrain renderer, le07 proof of concept | **complete** | D55, below |
| 6 — Recovering the 12 originals' heightmaps | **complete** | D56, D57, below |
| 7 — The editor | **complete** | D58, below |
| 8 — Materials, structures, placement, scenery models | **complete** but for the exit, which is Stage 9's | D60, D61, D62, D63, below |
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
panel has Open, Save, Undo, Redo and New, then eight tabs. Open shows the
system's file dialog for a level project; where there is none, it opens
the path typed in above it, as Save saves to it.

- **Terrain:** the brush. Raise, Lower, Flatten toward a target height, or
  Smooth, in a round, square or rough shape, with a size, a strength and a
  soft edge. Right-click takes the ground's height as the target.
- **Paint** (Stage 8, below): the materials and their brush.
- **Models** (Stage 8, below): trees, grass and rocks as 3D models, put
  down with a profile's brush.
- **Light:** live lighting on or off, the sun's direction and height, the
  ambient share and colours, the softness. Copy and Paste carry the light
  between levels as JSON on the clipboard (a level record's light pastes
  too), and Reset to original loads the measured light.
- **Water:** its height, shown or hidden, its colour; and the wind's
  direction and strength.
- **View:** the zoom, from a quarter to 4x, by presets or a slider; and a
  tilted view to look at the relief.
- **Units** (Stage 8, below): the level's units.
- **Level** (Stage 8, below): the level's names, words, music and sky, and
  the weapons it starts with.

The wheel and a touchpad's two fingers scroll up and down the level and
across it when it is wider than the view (Shift turns the wheel across),
middle-drag pans, and clicking or dragging on the overview centres the
view there. The overview's box is the part in view, its width as well
as its rows when zoomed in. Ctrl+wheel, a touchpad's pinch, and Ctrl+=
and Ctrl+- zoom about the mouse, and Ctrl+0 goes back to 1x. Ctrl+Z, Ctrl+Y and
Ctrl+S undo, redo and save; 1-4 pick the brush, `[` and `]` size it, `L`
and `T` toggle the light and the tilt. A project dropped on the window
opens.

### The file dialog

Open, the Paint tab's Add an image and the Models tab's Import a model
show the system's own file dialog, starting in the project's folder, and
take its file as a dropped one is taken. While it is open the editor
draws but takes no input.

On Linux it is the desktop portal's (`org.freedesktop.portal.FileChooser`
over D-Bus), so KDE's or GNOME's own dialog, and the same from a sandbox.
OpenFile answers at once with a request; the request's Response signal,
when the dialog closes, carries the file as a `file://` URI. Both are read
off the bus each frame. libdbus is loaded when the editor starts rather
than linked; without it, or without a portal (the bus answers
ServiceUnknown), Open opens the typed path and the others ask for a drop.
On Windows it is the common Open dialog, which runs its own message loop
until it closes, so the editor waits for it (untried on Windows). On other
systems there is none.

The test plays the portal: on a D-Bus of its own (`mise run test` starts
one with dbus-run-session), it takes the portal's name, answers OpenFile
as the portal does, and checks what the editor asked for (its token, the
level filter and the folder) and that it takes the chosen file, or none
when the dialog is cancelled. It never runs on the desktop's bus, where
the real portal would show a dialog. The case of no portal at all is not
tested: a bus of its own would start the real portal, which it can.

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

Zoomed in past 1x, the rows are rendered at 2 px a map pixel, so the
models' finer layer shows, and drawn larger from there with their pixels
kept sharp; at 1x or out, at 1 px, and drawn smaller through mipmaps, so
the ground's detail is not aliased into noise. The texture is a whole
number of 64 rows high, at most the level's length, so a zoom remakes it
only now and then; zooming out far, a short level is drawn its own height
on the view's background.

The pinch and the smooth scroll come from X, not GLFW, which tells of no
gestures and of scrolling only as whole wheel clicks, so a touchpad's
scroll would move in steps. The editor opens a connection of its own
beside GLFW's, asks it for XInput 2.4 and selects the pinch on the
editor's window and the pointer's raw motion on the root window. The raw
motion carries the pointer's scroll axes, which move by fractions of a
click; once one has moved, the wheel is read from them and GLFW's clicks
are left, or a scroll would count twice. Raw motion comes wherever the
pointer is, so only what comes while it is over the window counts. It is
raw motion and not the window's own motion events because X gives a
pointer's event on a window to one selection, XInput's first: selecting
motion there took it from GLFW, raylib's mouse stood still, and the
panel's buttons stopped answering. A test warps Xvfb's pointer onto the
window with the gestures selected and checks raylib follows it. Under
Wayland this is XWayland, which makes X's pinch from
the compositor's (XWayland 22.1 and later). libX11 and libXi are loaded
when the editor starts rather than linked, so without them there is just
GLFW's wheel, and stderr says why. Xvfb has no touchpad and its pointers
no scroll axes, so the test finds the events selected and reads made-up
raw motions' axes; whether real ones arrive needs a touchpad. On Windows a
precision touchpad's pinch arrives as Ctrl and the wheel, which zooms as
well, and its scroll as the wheel in fractions (untried on Windows).

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

The Units tab places the level's units. The Paint tab's materials, the
Level tab's properties, the structures' baked bases and the placing
helpers follow, below.

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
- **An image dropped on the window**, or chosen by Add an image, is added
  as a material. It is named
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

## Stage 8: structure footprints

The original baked each structure's base into the map's render, and the
game draws the unit's sprite on top of it (making-of; findings). The
editor draws that base under its unit, where the unit is. So a structure
moved, or placed on a new level, shows its pad as it will look once
Stage 9 bakes it in.

`mise run levels:bases` (`tools/bases`) measures which units have one:
1. For every ground placement of the twelve levels, it crops the map
   under the unit: the unit's frame and 8 px around.
2. It groups the crops by unit type, taking each crop's brightness
   relative to its own mean and spread. A base is drawn in each map's
   light and tint, so its colours differ from desert to grass where its
   shapes do not.
3. The score is the crops' mean correlation over the frame, pair by pair:
   1 when they are alike, 0 when unrelated. It is compared with the same
   score for crops of the ground a crop's width beside them.
4. A type is baked when its crops score 0.5 or more, and 0.25 over the
   ground beside them. Its base is the crops' median colour where the
   pairs agree, smoothed and filled in. Each base is written to
   `assets/bases/<unit>.png`, centred on the unit's point, and listed in
   `index.json`.

Types placed once agree with nothing, and are undecided. Of the 38 types
placed twice or more, 12 have one base:

| Unit | Name | Placed | At x | At x − 32 | Beside |
|---|---|---|---|---|---|
| `cair` | Cap - Iris | 3 | 0.92 | 0.59 | 0.03 |
| `came` | Cap - Metal | 2 | 0.92 | 0.28 | −0.09 |
| `car2` | Cap - Radar Mk 2 | 10 | 0.86 | 0.71 | −0.02 |
| `cara` | Cap - Radar | 2 | 0.71 | 0.64 | 0.18 |
| `csht` | Cap - Shield Station | 2 | 0.83 | 0.55 | 0.44 |
| `fgnu` | Flare Gun Nuke | 3 | 0.85 | 0.70 | −0.03 |
| `hosp` | Hospital | 2 | 0.82 | 0.88 | 0.01 |
| `irm2` | Iris - Mine 2 | 2 | 0.94 | 0.81 | 0.10 |
| `jg02` | Juno Gun 2 | 3 | 0.93 | 0.74 | 0.11 |
| `ns02` | Nuke Station Mk 2 | 7 | 0.80 | 0.58 | −0.02 |
| `nust` | Nuke Station | 3 | 0.73 | 0.48 | 0.02 |
| `popu` | Popup | 8 | 0.89 | 0.69 | 0.01 |

And some that do not:

| Unit | Name | Placed | At x | At x − 32 | Beside | By eye |
|---|---|---|---|---|---|---|
| `bala` | Base - Laser | 9 | 0.30 | 0.52 | 0.04 | baked pads, at angles of their own |
| `plla` | Platform - Laser | 6 | 0.24 | 0.38 | 0.01 | baked pads, at angles of their own |
| `twgu` | Twin Gun | 5 | 0.30 | 0.24 | −0.04 | baked pads, at angles of their own |
| `pola` | Popup - Large | 7 | 0.49 | 0.44 | −0.05 | baked, in two looks |
| `geys` | Geyser | 9 | 0.43 | −0.03 | 0.01 | a vent, drawn into different ground |
| `swgu` | Swivel Gun | 2 | 0.12 | 0.59 | 0.16 | no base: the same kind of rock slope |
| `bsde` | Bonus Station - Desert | 31 | 0.01 | 0.19 | 0.03 | no base: on dune edges |

What it settled:
- **A ground placement's x is the map's column**, as `spawn.odin` reads
  it. Crops at x − 32 score less for 11 of the 12. The hospital's pad is
  so wide that a crop 32 px along still holds most of it. The x − 32
  scores that come out higher are the laser base's and the platform's
  pads, whose edge and shadow fill half such a crop, and units always
  put on the same kind of slope. By eye, every pad is centred on x.
- **A base does not turn with its unit's heading.** The hospital's two
  agree unturned at different headings. Turning each crop back by its
  heading, either way, makes every type agree less: the laser base
  drops from 0.30 to 0.05. The laser base's, platform's and twin gun's
  pads are baked at angles that are not their headings, so no one image
  is theirs, and they are left out.

The editor reads `assets/bases` with the units and draws a base under its
unit, unturned, at the unit's point, in every tab. On a recovered level
the map already has the base there, so it draws over its own image. A
base moved away also leaves the recovered map's copy behind, until
Stage 9's export bakes the level afresh.

## Stage 8: the placing helpers

Under the palette, **Obstacle** and **Vent** pick the invisible obstacle
(`grob`, 33 in the originals) and the vent (`geys`).

**The vents' detector** follows the originals' rule:
- A destroyed vent leaves a flag, `gedf`.
- A detector waits until exactly its number of flags have appeared,
  anywhere in the level: `gebd` 2, `05gb` 3, `gbd2` 4, by their rules'
  ranges. Then it pays out.
- The three levels with vents each have one detector, for all their
  vents, on the northmost vent, the last the player reaches:
  - le05's `gbd2` is on its vent at (122, 165);
  - le07's `gebd` is 2 px from its vent at (264, 443);
  - le11's `05gb` is 1 px from its vent at (158, 1410).

So when a change to the units changes the vents, the editor removes the
detectors, then puts the one for their number on the northmost vent, as
part of the same undo. With one vent, or more than four, there is none,
and the tab says so. A level whose vents are not touched keeps its
detectors where they are, so an original opens and saves as it was.

**Enemies from other plugins** are in the palette: every data plugin's
units with a preview face, as the placement section says.

### Verified

- `mise run levels:bases`: the table above. Each base was checked by eye
  against montages of its crops, and on le09 in the editor, under its
  units.
- `tests/editor`: a unit's base is drawn under its frame, its own size,
  and moves with it. The vents' detector is gebd for two and gbd2 for
  four, each on the northmost vent, and none for five. It comes back
  with an undo, and is left where it was moved while the vents do not
  change.

### Not as planned

- **Only 12 structures have one base.** Three more (the laser base, the
  laser platform, the twin gun) have baked pads, but not one image. Their
  pads could be turned to match, once what sets their angle is known.
- **The bases are measured from the maps, not the plan's crops "at both
  x and x − 32" to decide the shift.** The shift was already settled
  (D60). The tool reports x − 32 as a check, and it agrees.
- **The obstacle and vent tools are buttons that pick the unit**: placing,
  moving and deleting them is the palette's. What the vent group adds is
  the detector, kept by the originals' rule.

### Still open

- Baking a base, and the structure's height, into the map on export
  (Stage 9).
- The turned pads of the laser base, laser platform and twin gun, and
  the large popup's two looks.
- A recovered level keeps its baked bases in its unlit colour; a moved
  structure leaves its old one there.

## Stage 8: scenery models

Vegetation is hard to paint. The recovered levels' unlit colour has the
originals' trees baked into it, rendered from models. A new albedo with
trees that good would mean painting each one, light and all. So the
editor puts real 3D models on the ground instead: trees, grass, shrubs and
rocks. The renderer draws them into the level's light, so their shadows
fall on the ground, on each other and on themselves, and the map Stage 9
exports has them baked in.

The **Models** tab has three modes, keys 1 to 3:
- **Scatter:** the brush puts down the chosen profile's models. A dab
  fills the brush's circle to the profile's density, so dragging over
  ground already full adds nothing.
- **Erase:** the brush takes away the profile's models in its circle, and
  no others.
- **Select:** a click picks the model on top under the cursor, and a drag
  moves it. The panel sets its model, lift, turn, lean and scale. Q and E
  turn it 15°, or 1° with Shift; Delete removes it; Escape lets it go.

A model's foot is centred on its point, at the ground's height there plus
its lift (negative sinks it). It follows the ground as the ground is
sculpted. A stroke, a move or an edit is one undo.

### Profiles

A profile is a brush's recipe:
- **its models**, each with a chance, a scale range and a lift range. An
  entry is either one model of a set (a file of variants) or "any of
  them";
- **a spacing**: no two of the profile's models are put nearer than this,
  in map pixels;
- **a density**: how full of them a dab leaves the circle, as a share of
  as many as can be packed;
- **a turn range and a lean range**, in degrees;
- **a steepest slope**, and whether to keep out of the water.

A dab wants density × 0.697 × πr² / spacing² models in all. 0.697 is the
share a random sequential packing fills before it jams (Feder, 1980).
Each is tried at up to 30 random points in the circle. A point is kept
if it keeps the spacing, the slope is gentle enough and the ground is
dry. Each model's entry, scale, lift, turn and lean are then drawn from
the profile's ranges.

Six profiles come with the library (`tools/models/profiles.json`):

| Profile | Spacing | Density | Models |
|---|---|---|---|
| Jungle Trees | 18 px | 0.9 | island trees, searsia burchellii |
| Jungle Undergrowth | 7 px | 0.7 | fern, calathea, anthurium, mossy rocks |
| Grasses | 4 px | 0.8 | two grasses, a weed, nettles |
| Shrubs | 9 px | 0.6 | rooibos, two shrubs, pine saplings |
| Sparse Rocks | 14 px | 0.25 | boulders, rocks and stones, a little sunk |
| Dry Scrub | 12 px | 0.35 | rooibos, searsia lucida, quiver trees, dry branches, a dead trunk and a stump |

New, Copy, Delete and Save edit them. The author's own profiles, and
their changes to the library's, are saved to the user's data
(`editor/brush-profiles.json`, beside the game's progress), so they are
there for every level.

### Importing a model

A glTF, GLB or OBJ file dropped on the window, or chosen by Import a
model, is imported:
1. It is read into memory: its triangles, and each material's base
   colour, texture and alpha cutout.
2. It is brought under 60,000 triangles (below).
3. It is kept in the user's data, `editor/models/<name>.glb`, so it is in
   the library for every level after.

A file with several models at its root, as Poly Haven lays out a set,
is one model with variants. Models are life size, at 3 map pixels a
metre: le11's palm crowns are about 30 px across, and a palm's crown is
8-10 m. The first time a model is put down, it is copied into the
project and saved beside it in `models/`, so a project stands alone.

### How they are drawn

Each instance's triangles are drawn straight down, orthographically,
into a layer over the whole map at 2 texels a map pixel. The layer holds:
- the model's colour;
- the height and normal of its top;
- the height of its underside, from a second pass with the depth test
  reversed.

The terrain shader lights the layer as it lights the ground. The sun's
march is blocked where a ray passes between a model's underside and its
top, so a canopy's shadow has light under it. A turn about the vertical,
a lean, a scale and a lift are all just the instance's matrix.

The alpha cutout reads the texture's full-size texels, not its mipmaps.
A mipmap averages a grass blade's alpha below the cutoff, and the grass
vanished (grass_medium_02 did).

### The library

`assets/models` is committed with the rest of the assets tree, so it is
in the release zip. 27 models from Poly Haven, all CC0, take 16 MB:

| | Models |
|---|---|
| Trees | island_tree_01, island_tree_02, searsia_lucida, searsia_burchellii, quiver_tree_02, pine_sapling_small |
| Shrubs and plants | shrub_02, shrub_03, wild_rooibos_bush, fern_02, calathea_orbifolia_01, anthurium_botany_01, nettle_plant, weed_plant_02 |
| Grass | grass_medium_01, grass_medium_02 |
| Rocks | rock_07, rock_09, stone_01, boulder_01, namaqualand_boulder_02, namaqualand_boulder_05, namaqualand_stones_01, rock_moss_set_01 |
| Debris | dead_tree_trunk_02, dry_branches_medium_01, tree_stump_01 |

It is made in two steps:
- **`mise run models:fetch`** (`tools/models/fetch.py`) downloads each
  model's 1k glTF into `~/.cache/deimos-rising/models`, about 200 MB.
  The downloads are checked against the API's MD5s, and the tool sends
  its own User-Agent, as Poly Haven's terms ask.
- **`mise run models:library`** (`tools/models`) builds `assets/models`
  from the cache, the same bytes each time. For each model it:
  1. merges the leaves' alpha into the colour;
  2. makes each image 256 px, keeping the cutout's coverage;
  3. brings the triangles under 10,000, or 20,000 for a tree;
  4. writes the result as a GLB.

  It also writes `index.json` (each model's tags and credit),
  `profiles.json` (after checking that every entry's model and variant
  exist) and `CREDITS.md`, headed "Powered by Poly Haven".

Poly Haven's plants keep their leaves' alpha in a map of its own, which
the glTF does not name. Without it, every leaf card is an opaque square.
`fetch.py` fetches each `*alpha` map, and the builder pairs it with the
diffuse image beside it. Shrinking an alpha-tested texture thins its
leaves, because the averaged alpha falls under the cutoff. So each image
is shrunk with its alpha scaled to keep the share of texels over the
cutoff (Castaño, "Computing Alpha Mipmaps", 2010).

| Model | Triangles | Kept |
|---|---|---|
| island_tree_01 | 1,599,403 | 19,094 |
| island_tree_02 | 1,072,213 | 18,664 |
| searsia_burchellii | 616,336 | 18,886 |
| pine_sapling_small | 398,144 | 18,607 |
| boulder_01 | 66,122 | 6,760 |
| grass_medium_01 (17 clumps) | 24,730 | 9,212 |

### Fewer triangles

`terrain/simplify.odin` uses vertex clustering (Rossignac and Borrel,
1993). Each part's vertices are gathered into the cells of a grid and
merged at their mean, and a triangle with two corners in one cell is
dropped. The cell starts at 1/1024 of the model's size and grows by √2 a
try until the model fits. Clustering keeps a solid's outline and its
cover from above, which is all the layer draws. A cell also groups by
UV, so a texture's seam stays a seam: island_tree_01's bark wraps 15
times round.

A crown is not a solid. island_tree_01's is 44,168 leaves of 24
triangles each, 5 cm across. A grid fine enough to keep a leaf keeps a
million triangles, and one coarse enough to fit folded every leaf to
nothing, leaving bare branches. So a piece (a run of triangles joined
at their corners) smaller than two cells is a leaf:
- it is clustered on a grid of its own, three cells across it;
- where the leaves are still too many, an even share of them is kept,
  and each kept leaf is grown by the square root of what was dropped, so
  the crown covers as much from above. This is how foliage is thinned
  for distance (Cook, Halstead, Planck and Ryu, "Stochastic
  Simplification of Aggregate Detail", 2007).

By eye, the library's trees, shrubs, grass and rocks match their full
models from above.

### Verified

- `tests/terrain`:
  - a model reads from glTF with its extent and colours;
  - a set's root nodes become variants;
  - KHR_texture_transform moves the UVs, and a second UV set is not read;
  - a lifted slab shades the ground with light under it;
  - a turn turns the footprint, and a lean tips it;
  - a cutout has holes, and water hides a model under it;
  - a model follows the ground, and saves and reopens the same.
- `tests/terrain`, simplify: a dome of 59,400 triangles is brought under
  2,000 with both parts and its extent kept. It covers the same points
  from above, its top is within 2.4 px, and no triangle spans the seam.
- `tests/editor`:
  - the library and profiles load, and a user's profile is saved and
    read again;
  - a scatter keeps out of the water, puts 80-100% of the wanted count,
    keeps the spacing and uses each entry;
  - it draws as a fresh upload does, and undoes and redoes;
  - the eraser takes the brush's circle;
  - an instance is set and deleted with undo;
  - an import is kept in the user's data;
  - a project saves and reopens the same.

  With `assets/models` present, every library model is under its budget
  and credited, and every profile's entries resolve.
- By eye: each profile scattered on a new level, and the Models tab drawn
  by `editor:shot`. The editor drawn from inside `dist/deimos`, with no
  `DR_ASSETS` and an empty user data folder, has the library and its six
  profiles.

### Not as planned

- **Real meshes, not baked sprites.** The plan baked each model once into
  a sprite of its colour, normal and top and underside heights. The
  project owner asked for the models' own shadows, so the meshes are
  drawn into the layer every time the map is drawn. A lean is then just a
  rotation, and is offered. The editor's tilted view does not draw them:
  the map's lit image is the point.
- **glTF is read by `terrain/gltf.odin`, not cgltf.** raylib bundles its
  own cgltf, and the vendor package's symbols collide with it at link
  time. OBJ goes through raylib.
- **No palm.** Poly Haven has no CC0 palm. A palm from elsewhere can be
  imported.

### Still open

- An imported glTF whose leaves' alpha is a separate map its material
  does not name imports opaque. Only the library's builder pairs those
  maps.
- The export of the models' shadows into the level's map is Stage 9's.
