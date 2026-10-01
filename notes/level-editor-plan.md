# Level editor and remastered levels: implementation plan

This plan covers Tasks 2 and 3 of
[headless-3d-to-2d-pipeline.md](headless-3d-to-2d-pipeline.md), its Level
Editor Specs, and its New Features (HD export and deferred-lighting layers).
The facts it builds on are in
[headless-3d-to-2d-findings.md](headless-3d-to-2d-findings.md).
Written 2026-09-30.

**[V]** means verified in the code or data (the evidence is named). **[I]**
means inferred or proposed. Paths are under `src/` unless they start with
`notes/` or `.github/`.

## The shape of it

1. The terrain is built again as data: a heightmap, painted material weights,
   a water height, vegetation and a sun. This data is the level's source. The
   480-wide map image, the water mask and the preview are exports of it, just
   as the original's were exports of a Bryce scene.
2. One terrain renderer, a raylib 3D package, draws the scene in three
   places:
   - the editor's live view;
   - the headless export;
   - the Task 2 comparison against the original art.
3. Levels come from plugins:
   - The 12 originals move into a Classic Levels plugin.
   - Rebuilt versions go into a Remastered Levels plugin.
   - The editor exports new levels as plugins of the same kind.
4. Exported plugins are data only, since the editor can't compile Odin. So
   the game has to discover plugin folders at runtime. Today it can't
   (below).

Stages 1 to 3 change the game and leave the editor for later. They go first,
because every later stage writes the plugin format they define. Each stage
ends green under `mise run ci`, with `oracle:diff` exact and
`tests/golden/*.txt` unchanged, as AGENTS.md requires.

## Where we start [V]

**Levels:**
- **The level record.** `data/level.odin:18-43` parses 11 header tags and
  7 tags per placement:
  - unit, layer, x, y, heading;
  - `is_stationary`, `terrain_effects`.
- **What the 12 levels hold.** They have 565 placements (353 `grnd`, 212
  `air `). `isStationary` is false in all of them. `terrain_effects` is true
  in 33, all tanks.
- **No level holds** waves, triggers, lighting or weapons. Timing comes from
  the map row and each unit's definition.
- **Play order is hard-coded.** `LEVEL_ORDER` is at `data/defs.odin:31`,
  taken from the table at 0x4e7ba9 in the executable.
  `assets_defs_load_rest` (`data/assets.odin:609-657`) keeps only levels
  named in it.
- **Levels load only from the core tree:**
  - records from `assets/data/levels/`;
  - maps, masks and previews from `assets/images/im16/`;
  - sounds from `assets/audio/`.

  There is no concept of a level set or campaign.
- **Map height comes from the data.** `bgnd_reset`
  (`sim/systems/background_system/background.odin:38-46`) scrolls from
  `background.bottom`. Outside comments, no code contains 3600, so longer or
  shorter levels should work. Width is fixed at 480: a 416 play field plus
  ±32 of side scroll.
- **Spawning is by row.** `eg_spawn_map_row` (`sim/lifecycle/spawn.odin:66-89`)
  spawns a placement once its row is 64 rows above the view's top. Ground
  units are shifted `x -= 32` (`:59-61`).
- **Weapons at level start** come from each weapon's
  `minimumLevelAvailable`/`maximumLevelAvailable`
  (`sim/systems/weapon_system/weapons.odin:29-51, 89-98`), by play-order
  number. A plugin can override them with `weapon_chooser_register`.
- **No way in from the command line.**
  - `game/settings.odin:32-46` parses only `-classic`, `-highrefreshrate`,
    `-diagnostics` and `-fullscreen`.
  - The only way to start part-way through a level is
    `level_skip_to_end` (`sim/systems/level_system/level.odin:144`),
    reached only through the `DR_NETPLAY_END` test hook.

**Plugins:**
- **All compiled in.** `game/plugins.odin` imports every plugin. `Plugin`
  (`sim/plugins.odin:26-40`) has no manifest.
- **Limits.** `MAX_PLUGINS` is 31, and `Mods` is a `bit_set` on a `u32`.
- **Content folders.** `assets/extra/<name>/` (D49) is the only
  plugin-owned content, and only chaingun and new_weapons have one. It holds
  units, weapons and sprites.
  - Sprite paths in its `index.json` are relative to the assets root
    (`"extra/chaingun/sprites/im08/PL1K.png"`, read at
    `render/assets.odin:330`).
- **Classic mode** turns every mod off (`game/extras.odin:25-28`).
- **Netplay** compares `registration_hash` across peers (D50).

**Rendering and tools:**
- **2D only.** No `BeginMode3D`, `Camera3D` or `LoadModel` appears outside
  `third_party/`. The one shader is `ACCENT_SHADER`
  (`render/render.odin:155`).
- **Runtime marks.** The renderer keeps each level's map in a render texture
  (`render/render.odin:210-221`). Craters and tracks (`terrain_burn`) and
  wrecks (`terrain_stamp`) are burned into it.
- **No UI toolkit in use.** But raygui ships in this Odin install's
  `vendor:raylib` (`raygui.odin`, `linux/libraygui.a`).
- **Nearest second binary.** `tools/clips/main.odin` is a raylib program
  that draws into the renderer's canvas.
- **Shipping.** Only `deimos[.exe]` ships, beside `assets/`
  (`.github/workflows/build.yml:58-62, 118-122`).

## Decisions to take first

Each has a proposed answer, and the stages below assume it. Change the
answer and the stages change. Record each as a `decisions.md` entry, from D51
onwards.

1. **Where plugin content lives.**
   - Proposal: a plugin's content sits in its own source folder,
     `plugins/<name>/{plugin.json,data,sprites,images,audio}`, beside its
     `.odin` files. Odin ignores subfolders that nothing imports.
   - The release zip gets `deimos/plugins/<name>/` holding only the content.
   - The game reads `DR_PLUGINS`, falling back to `plugins`, relative to the
     working directory. That already matches the dev layout, because mise
     tasks run from `src/`.
   - `assets/extra/` goes away.
2. **What a level plugin is.**
   - Proposal: a data-only plugin whose `plugin.json` lists its levels in play
     order: a **campaign**.
   - It appears on the Mods page like any plugin. Its identity goes in
     `sim.Session` as a campaign id beside `level_id`, not as a `Mods` bit.
     So classic mode can still turn every mod off and force the Classic
     Levels campaign.
   - If several campaigns are enabled, Level Select offers a choice.
   - Films and the oracle always use Classic Levels.
3. **Remastered as the default.** Proposal: once the Remastered Levels plugin
   exists it becomes the default campaign outside classic mode, and Classic
   Levels stays installed.
4. **Heightmap resolution.**
   - Proposal: one height sample per 2 map pixels (240x1800 for a standard
     level), 16-bit, in map pixels.
   - Height is exaggerated, as the originals are: about 640 px of range
     fitted on `cam1`.
   - Finer detail comes from the material and normal textures.
5. **Assets derived from the originals.**
   - Material exemplars quilted from the shipped art, and structure
     footprints cut from it, are derivatives of the original.
   - Proposal: every asset carries a `provenance` of `original-derived` or
     `new`. Export refuses to mark a plugin `original_free` when any asset is
     `original-derived`. That keeps a future all-new Deimos Rose campaign
     honest.
6. **Classic mode means the shipped images.**
   - Classic mode draws Classic Levels' original TGAs, never a re-render,
     however faithful.
   - The Remastered re-renders and HD maps belong to mods, as AGENTS.md
     requires for anything the port adds.

## Stage 1: plugins own their content folders

**The move:**
- Move `assets/extra/chaingun` and `assets/extra/new_weapons` into
  `plugins/<name>/`.
- `data.plugin_content_dir` (`data/assets.odin:592`) resolves against the
  plugins root.
- Sprite `image` paths become relative to the plugin folder. That touches
  `tools/recolour/main.odin` and `render/assets.odin:330`.

**Where content can live:**
- Let a content folder also hold `images/` (im16 PNGs) and `audio/`. Today
  those load only from the core tree (`render/assets.odin:145, 195, 231`;
  `data/assets.odin:291-302`).
- Lookups go plugin first, then core, and only for ids the plugin declares.

**Shipping:** CI copies each plugin's content (everything that isn't
`.odin`) into `dist/deimos/plugins/<name>/`. Update D49, the AGENTS.md
extension table row, and the release note text at `build.yml:173`.

**Exit:**
- Chaingun and Discharge Beam load from their plugin folders.
- `dps:report` numbers and the chaingun menu-shot are unchanged.
- The Linux release zip, unpacked, runs with both weapons.
- Golden fingerprints are unchanged.

## Stage 2: data-only plugins, found at runtime

**Discovery:**
- At startup, before `sim.register_all`, `game/main` lists the plugins root.
- A folder with a `plugin.json` but no compiled plugin of that name is
  registered as a data plugin:
  - name, label, description;
  - version and `deps`;
  - `default_on`, `content = true`, `session`;
  - what it provides.
- Folders are registered in name order, so ids are the same on every machine
  (D50's reason).
- A compiled plugin with a `plugin.json` just reads its label and
  description from it.

**Changes this needs:**
- Raise `MAX_PLUGINS` and widen `Mods` (`sim/plugins.odin:13, 24`). Check
  the netplay Start message that carries `Mods` (D43).
- `registration_hash` digests each data plugin's name, version and a hash of
  its content files. Two peers with different level packs must refuse to
  connect, not desync.
- A plugin that depends on a missing plugin stays off, and the Mods page says
  why.

**Tests** (synthetic fixtures only, as AGENTS.md requires):
- `tests/fixtures/plugins/` with a one-unit data plugin: it registers and
  loads.
- A second fixture with a missing dependency stays off.
- Changing one byte of content changes the registration hash.

**Exit:** the fixture plugins load from `DR_PLUGINS=tests/fixtures/plugins`,
and the goldens are unchanged.

## Stage 3: campaigns and the Classic Levels plugin

**The move:**
- Move the 12 level JSONs and their maps, masks and previews into
  `plugins/classic_levels/`. Music `mu03` is shared, so it stays in the core.
- `LEVEL_ORDER` becomes the manifest's `levels` list, keeping its provenance
  comment (0x4e7ba9).
- `Level_Def.number` is the index in the campaign's list.

**The campaign becomes a session value:**
- `sim.Session` gains a campaign id. `flow_start_session`
  (`game/flow.odin:647-654`) takes it, and `players_setup_system` resolves
  `level_id` within it.
- Level Select (`game/menu_level_select.odin`) walks the active campaign.
- `highest_reached` is saved per campaign in prefs.
- Classic mode, films, `DR_SHOT` and the oracle use Classic Levels.
- The oracle's PAK loader, `defs_load` (`data/defs.odin:294-340`), is
  unchanged. It reads the originals directly.

**Exit:**
- `oracle:diff` and `oracle:diff:saved` are exact.
- Films and goldens are unchanged.
- `menu-shots:compare` shows Level Select identical in classic mode.
- A fixture campaign with two small levels plays both in order.

## Stage 4: level format extensions and launch flags

**New optional fields on a level JSON.** Classic levels leave them all
absent, so nothing changes there.

| Field | Used by | Notes |
|---|---|---|
| `start_weapons` (air, ground) | sim | Overrides the min/max-level rule for this level only. It changes play, so it sits in the core, gated on the field being present. |
| `wind` (direction, strength) | presentation | Read by particles and a future water shader. Nothing in the sim. |
| `water` (height, colour, visible) | editor, presentation | The mask is still exported, and the sim reads only the mask. |
| `lighting` (sun azimuth and elevation, colours, ambient, softness) | editor, deferred lighting later | Defaults to the measured originals. |
| `skybox` | presentation | For reflective surfaces, later. |
| `layers` (albedo, normal, height, shadow mask, HD map) | presentation mods | Optional exports; see Stage 10. |

**Launch flags:**
- `-campaign <plugin>`, `-level <identifier>` and `-row <n>` in
  `game/settings.odin`, and in the `run` task's usage block that must match
  it.
- `-plugins <dir>` adds a second plugins root, which the editor's play
  button uses.
- `-row` reuses `level_skip_to_end`
  (`sim/systems/level_system/level.odin:144`) under a name for what it does,
  such as `level_start_at_row`. It already puts the view's top at a given
  row, fixes `progress` and re-runs the initial spawns. Units that would
  have spawned below the start row and still be alive are never met, which
  is acceptable for testing a level.

**Exit:**
- A headless test starts `le07` at row 1500 and checks that exactly the
  placements with y from 1436 to 1980 spawned. That is the 480-row view plus
  the 64 rows above it (`bgnd_initial_spawns`,
  `background_system/background.odin:50-56`).
- A fixture level with `start_weapons` starts with them.
- Classic goldens are unchanged.

## Stage 5: the terrain renderer (Task 2's core)

A new package, `terrain/`, that draws a level scene with raylib 3D, headless
or in a window. It is shared by the export tool and the editor.

**The scene:**
- A heightfield mesh from the heightmap, drawn in chunks.
- An orthographic camera looking straight down. One world unit is one map
  pixel, and the width is 480.
- A water plane at the water height.
- Materials blended from splat weights, with automatic cliff-on-slope and
  sand-at-shore rules.
- Vegetation as canopy height plus a canopy material.
- Structure footprints (Stage 8).

**Shadows:**
- Cast by marching the sun ray over the **height texture** in the fragment
  shader: the soft horizon test from the findings' refinement renderer.
  Shadow maps aren't used.
- The march reads heights, not screen pixels, so an export rendered in
  strips has no shadow seams. That matters at 4x: 1920x14400 is beyond some
  GPUs' texture size limit.
- It also gives the shadow-mask layer, which the New Features section asks
  for, directly.

**Lighting:**
- One directional sun.
- Neutral ambient at 0.44 of full light, measured on `cam1`.
- A penumbra a few pixels wide.

**Outputs, any scale:**
- lit colour;
- albedo;
- normal;
- height;
- shadow mask.

Each output has the option of 1555 quantisation, to match the originals.

**Task 2 proof of concept on `le07` (map `jum2`):**
- A `terrain:render PROJECT=...` mise task.
- A `terrain:compare` task that scores a render against the original:
  - shadow IoU, with the shadows detected as in the findings;
  - the lit/shadow ratio against 0.44;
  - fitted sun azimuth against 36°.

  It writes a side-by-side PNG, so the numbers and the look can be checked
  together.

**Tests** (analytic, no game data):
- A flat heightfield casts no shadow.
- A block of height h casts a shadow h / tan(elevation) long.
- Rendering the same scene at 1x and at 2x-then-shrunk agrees to within
  quantisation.
- Two strips assemble to the single-pass image.

**Check first:**
- 3D and 16-bit or float textures work under xvfb (Mesa) in CI, as
  `menu-shot` already does for 2D.
- raygui's library is in the Windows runner's Odin install.

**Exit:** `terrain:compare` on the le07 PoC reports its numbers in a phase
doc, next to a side-by-side image. There is no target number for the PoC. It
is there to learn how close the lighting gets (Task 2's own words).

## Stage 6: recovering heightmaps for the 12 originals

This is a Python tool, `tools/terrain_recover/`, built like
`tools/hd_upscale/`:
- a mise setup task and a venv in `~/.cache/deimos-rising`;
- pinned model revisions;
- a resumable cache in `work/`;
- a manifest of checks.

It turns the findings' recipe into a tool:

1. **Seed** the heights with Marigold V2 depth (Depth Anything V2 Large as
   the fallback).
2. **Refine** them against the detected shadows with the differentiable
   renderer:
   - a multi-scale offset;
   - a curvature penalty along the sun direction, against the ridge carving
     the findings saw.

   Per-pixel refinement reached IoU 0.91 by cheating. The 1/4-resolution
   version reached 0.76.
3. **Water** comes from the shipped mask, which is exact. Set the water
   height just above the terrain under it. *Corrected in Stage 6:* the mask is exact
   only to its 5 px cells, so every shore stepped; near the cells' edge
   the water is moved to the art's shoreline by colour.
4. **Canopy** is masked with k-means, or the vision model where the
   clusters fail (findings: jungle canopy became bumpy terrain). It becomes
   vegetation, not height. *Corrected in Stage 6:* k-means clusters
   mixed grass with jungle, and cam1's autumn trees with its cliffs, so
   the mask is CLIPSeg's zero-shot "trees", and the heights under it are
   split into ground and canopy cover without changing the surface.
5. **Unlit colour** is the original with its shadows divided out: where
   the art is in shadow, divided by the light the refined heights give it.
   It is the exemplar source for materials (Stage 7). *Corrected in Stage
   6:* dividing by the Marigold IID shading removed the shadows on small
   tiles but left 83% of le07's over the whole map, and Flux edits kept the
   scene only where they kept the shadows (docs/level-editor.md). Dividing
   out only the shadows left the art's slope shading in the colour, so
   relit slopes were shaded twice (le01 at IoU 0.709): the colour is now
   divided by the renderer's whole light at the art's sun, the slope term
   and its shadow, the shadow only where detected (0.920).
6. **Output** is an editor project (Stage 7's format) per level.

**Verification**, as the pipeline task's update asks: the tool renders each
project with the Stage 5 renderer and reports the shadow IoU against the
original. Proposed bar: IoU ≥ 0.75, with no ridge streaks visible in the
height image. Tune the bar on le07 before running all 12.

**Exit:** 12 projects in `work/recovered/`, with each IoU recorded in a
report. They are a starting point for artists, not finished levels.

## Stage 7: the editor, first usable version

**Build and ship:**
- A new binary from `editor/`: `mise run editor`, `build:editor` (which
  `build:linux` and `build:windows` also cover), and CI copying
  `deimos-editor[.exe]` into the zip.
- Add `editor/` to `check`.
- Its `main` calls `sim.register_all()` first (D50), since it reads unit
  definitions. *Corrected in Stage 7:* it reads none until Stage 8 places
  units, so the call arrives with placement. *Done in Stage 8:* `main`
  discovers and declares the data plugins, calls it, then loads the
  definitions.
- The UI uses raygui panels. The viewport is Stage 5's renderer, with an
  optional tilted camera for inspecting relief. *As built:* the tilted view
  is the lit top-down render on a mesh of the heights, for looking at; the
  brush works on the top-down view.

**The project file** is what the editor saves: `<level>.drproj.json` plus
side files:
- the heightmap as a 16-bit PNG;
- splat weights as RGBA PNGs;
- the canopy density;
- lighting, water and wind;
- the placements and the level properties.

Exported plugins include it, so they can be reopened.

**Tools in this version:**
- **New level:** 480 wide and 3600 long by default, with any length
  allowed.
- **Open, save and undo.** Undo stores changed regions of the heightmap and
  splat layers, not whole copies. *As built:* 32 x 32 tiles of the heights
  and the water layer; the splat weights join them with Stage 8's paint
  brush, the first thing to change them.
- **Scrolling** up and down the level, like the original editor's panel
  (`EDBU`: scroll, rotate, layer, obstacle, info).
- **Terrain brush:**
  - set a target height, then raise, lower, flatten or smooth;
  - round, square and rough shapes (rough is noise-modulated);
  - soft falloff;
  - size and strength.
- **Lighting:**
  - live lighting on or off;
  - a lighting panel with copy and paste between levels as JSON on the
    clipboard;
  - "Reset to original" loads the measured defaults.
- **Water:** a height, with a toggle to show or hide it. Terrain lowered
  below it is covered by water.
- **Wind:** direction and strength.

**Tests:**
- A project round-trips through save and load, byte-identical.
- A brush stroke is undone exactly.
- A headless editor shot (the `menu-shot` pattern) shows a fixture project.

**Exit:** open a Stage 6 project for le07, sculpt, relight, save and reopen.

## Stage 8: textures, structures and placement

**Materials:**
- Drag and drop an image onto the window (raylib `IsFileDropped`). It is
  copied into the project's `materials/` and bundled on export. *As
  built:* kept in memory and written there on save, scaled to 1024 px at
  most.
- A paint brush sets per-material weights. *As built:* where they sum
  under full the unlit colour shows, or without one the first material;
  the cliff, shore and canopy rules, the renderer's since Stage 5, are
  edited beside it.
- Sampling breaks up tiling (for example, hex-tile blending), because the
  originals' ground never repeats (findings: autocorrelation peaks
  0.03-0.04). *As built:* hex-tiling, offsets only, always on (D61).
- The starting library is exemplars quilted from the unlit layer (the
  findings' Efros-Freeman test), tagged `original-derived`. *As built:*
  eight, by `mise run materials:library` from the recovered projects into
  `assets/materials`, not by `assets:all`: it needs the recovery's models.
  Quilted with a 30% tolerance, not the paper's 10%.

**Structure footprints:**
- The original baked each structure's base into the map render, and the
  runtime sprite sits on top of it (making-of; findings).
- First, measure which units: a `levels:bases` tool crops the map under
  every ground placement (allowing for the `x -= 32` shift) and groups the
  crops by unit type. A type whose crops match across its placements has a
  baked base. The tool extracts each footprint.
- In the editor, a structure's footprint is shown live and moves with the
  unit. On export it is baked in with the scene's lighting, as a decal plus
  a height block so it casts its shadow. That covers the spec's "ground unit
  sprites only baked on export".
- *As built:* crops at x and x − 32 settled nothing new (D60 had: ground x
  is the map's column). The crops are compared by correlation, since a
  base takes each map's light and tint. 12 types have one base, in
  `assets/bases`. The laser base's, laser platform's and twin gun's pads
  are baked at angles that are not their headings, so they have none yet
  (D62).

**Placement:**
- A unit palette drawn from every enabled plugin's definitions. *Corrected
  in Stage 8:* from the units with a preview face (134 of the originals'
  386, all 114 the levels place) in the editor's build: the originals' and
  the data plugins'. A compiled plugin's units appear only if the editor
  imports it; none does, and the chaingun's and New Weapons' units have no
  preview faces.
- Previews use the original editor's own unit fields:
  - `use_preview_appearance_in_placement_editor` and
    `editor_preview_sprite_face/frame`, which are parsed and unused today;
  - `initial_heading_set_in_editor` decides whether heading is editable.
    *As built:* it also turns the preview to the heading, by the game's
    rounding; other units show their first state's least frame. The spawn
    takes the level's heading only for these units.
- The layer is set from `is_ground_based`.
- The stationary checkbox appears only where
  `allow_stationary_option_in_placement_editor` is set (papu, pasc, tala and
  tapu). *Corrected in Stage 8:* and where the level already sets it, so it
  can be cleared.
- A `terrain_effects` checkbox.

**The spawner panel** has no wave options to show, because the record holds
only the 7 placement fields. It shows what follows from them (*as built:*
under the selected unit, with the spawn row drawn across the map):
- the row at which the unit spawns (64 rows ahead of the view);
- group size and chance, from the unit definition;
- its spawn sets.

**Helpers:**
- **Obstacle tool:** places the invisible `grob` units that give scenery
  collision (33 in the originals). *As built:* a button that picks it in
  the palette.
- **Vent group:** places `geys` vents with the matching bonus detector
  (`gebd`, `05gb` or `gbd2`, which fire at 2, 3 or 4 destroyed vents).
  *As built:* a Vent button; the detector follows the vents, one for
  their number on the northmost, as in every original.
- **Level properties:** name, identifier, description, music, briefing,
  `start_weapons`, wind, skybox. *As built:* the Level tab, with the
  copyright too; the wind stays in the Water tab. The game's level record
  now keeps description, copyright and briefing, which it had dropped.
- **Custom enemies** from another plugin appear in the palette. Export
  records that plugin as a dependency.

**Scenery models** (added after the rest of Stage 8, at the project
owner's request). Painted vegetation needs albedos like the originals'
baked trees, which are hard to make. Models scattered over the ground are
easier. [I] unless marked.
- **Seen from straight above, a model is an impostor.** An orthographic
  view straight down commutes with a turn about the vertical, so a model's
  look from above, turned, is the model turned. Each model is therefore
  baked once, when it is imported, into a sprite:
  - its colour and coverage;
  - its normal;
  - the heights of its top and of its underside, which a view from below
    gives.

  An instance is that sprite drawn turned, scaled and lifted, into a
  map-space layer. A turn about the vertical, a scale, and an offset from
  the ground are what it can take. A tilt cannot be drawn this way; none
  is offered. *As built:* no sprites. At the project owner's direction,
  each instance's mesh is drawn straight down into the layer every time
  the map is drawn, for its real shadows. So a lean is offered too
  (D63).
- **The renderer lights the layer as the ground.** It uses the same sun,
  and the same shadow march over the ground plus the models. A model
  blocks a ray between its underside and its top, so a canopy casts its
  shadow with light under it. The layer is at 2x the map. Edges are
  antialiased from its 2x2 texels. Exports carry the models, since they
  come from the same render. *As built:* so; the cutout reads the
  texture's full-size texels, not its mipmaps, which lose thin leaves.
- **A model is imported from glTF or GLB, through cgltf** (vendor:cgltf).
  raylib's loader is not used, for two reasons [V: its build here reads no
  JPEG, and Poly Haven's textures are JPEG; it truncates 32-bit indices to
  16]. A set of variants, one node each, becomes one model a node, as Poly
  Haven lays its sets out. The size is 3 map pixels a metre [V: le11's
  palm crowns are about 30 px across; a palm's crown is 8-10 m].
  *As built:* not cgltf. raylib's bundled cgltf collides with the vendor
  package at link time, so `terrain/gltf.odin` reads glTF and GLB itself,
  with KHR_texture_transform. OBJ goes through raylib. Imports are
  simplified under 60,000 triangles, with leaves kept as leaves.
- **A project keeps each model's two images under `models/`**, as it keeps
  its materials' under `materials/`. It also keeps the instances in its
  JSON: model, point, offset, turn and scale. *As built:* it keeps each
  model as a GLB under `models/`, and each instance's lean as well.
- **Brush profiles** ("Jungle Trees", "Grasses", "Sparse Rocks") hold:
  - weighted entries of models, each with a scale range and an offset
    range;
  - a turn range, a spacing, a density, a steepest slope, and whether to
    keep out of the water.

  The brush fills the circle to the density with a spacing test among the
  profile's own models. An erase mode takes those models away. Sample
  profiles come with the library; the author's own are saved in the user
  data directory. *As built:* so, with a lean range too. Six samples:
  Jungle Trees, Jungle Undergrowth, Grasses, Shrubs, Sparse Rocks and Dry
  Scrub.
- **A select mode** picks an instance by its sprite's coverage, the
  highest on top. It drags it, and sets its offset, turn and scale. An
  instance follows the ground as it is sculpted. *As built:* it picks by
  the mesh's top seen from above, and sets the lean and model too.
- **The library** is CC0 models from Poly Haven. They are fetched and
  baked by a tool into `assets/models`, with their licence and the API's
  "Powered by Poly Haven" credit. *As built:* 27 models in 16 MB,
  committed and shipped in the release zip (D63). Poly Haven has no CC0
  palm; one can be imported.

**Exit:** a level with painted materials, a baked structure and placements
from two plugins exports and plays (Stage 9).

## Stage 9: export and the play button

**Export** writes a data plugin (Stage 2): `plugin.json`, `levels/<id>.json`
and the project. Each level also gets:
- the map at 480 wide, 1555-quantised when the plugin wants the classic look;
- the water mask at 1/5 scale, pure 0x001F blue where terrain is under the
  water height;
- the preview;
- optionally HD maps and the deferred layers (Stage 10).

**The preview is generated as the originals were made:**
- a 438x918 crop, downscaled 3x to 146x306;
- then a vignette and a warmer, softer tone.

Fit the tone curve from the 12 original crop and preview pairs. The findings'
template matching scored 0.93-0.97 on the originals, so a generated preview
of an original map should reach the same range. The editor lets the author
move the crop.

**Validation before writing:**
- every unit resolves;
- every dependency is listed;
- the sizes are right: mask exactly 1/5, preview 146x306;
- the level's identifier is unique within the campaign;
- the provenance flag (decision 5).

**Play:**
- Exports to a scratch plugins folder.
- Launches the game binary beside the editor with
  `-plugins <scratch> -campaign <name> -level <id> -row <current view row>`.
- In development, it uses `build/deimos`.

**Tests:**
- Exporting a fixture project yields a plugin that Stage 2's loader accepts.
- Its mask matches a mask computed from the fixture's heights.
- A generated preview of a fixture map matches a hand-made reference.

**Exit:** from the editor, play a new level starting at the current scroll
position.

## Stage 10: HD and deferred-rendering layers, then Remastered Levels

**Layers:**
- Export renders any scale in strips (Stage 5).
- The deferred layers are the renderer's albedo, normal, height, shadow
  mask and occlusion at the same scale (the occlusion layer was added in
  Stage 6, D56). The shadow mask is a separate layer, so later
  lighting can brighten shadowed areas, as the New Features section asks.

**The Remastered Levels plugin:**
- The 12 recovered projects, cleaned up in the editor.
- Exported at 1x and 4x, and made the default campaign outside classic mode
  (decision 3).
- Placements are copied unchanged from the originals, so the levels play the
  same.

**For each remastered level**, check shadow IoU against the original, and
also check it by eye.

**A separate route to HD.** `hd:upscale`, the Flux detail transfer that
exists already, gives HD copies of the original art without a rebuild. It
can back a "HD classic maps" mod, since it isn't classic mode, while the
remaster is being made.

**Exit:**
- All 12 remastered levels play.
- Classic mode still shows the original art.
- The goldens are unchanged, because the placements and masks are.

## Later, outside this plan

The runtime features that use the exported layers are separate mods, each in
[enhanced-graphics.md](enhanced-graphics.md):
- 2D deferred lighting from albedo, normal and shadow mask;
- the water shader, using the mask and the level's wind;
- sky reflections from the level's skybox.

This plan only makes sure the export carries what they will need.

## What each stage touches outside plugins [I]

AGENTS.md asks for this count before building. These are the core changes
this plan expects. Each should be its own commit that changes nothing
observable, before the feature that uses it.

| Stage | Core changes |
|---|---|
| 1 | `data/assets.odin` (content dir, image and audio lookup), `render/assets.odin` (paths), `tools/recolour`, CI copy step, D49 |
| 2 | `sim/plugins.odin` (limit, data plugins), `sim/registry.odin` (hash), `game/main.odin` (discovery), netplay Start message |
| 3 | `sim.Session` (campaign), `data/defs.odin` (`LEVEL_ORDER` out), `data/assets.odin`, `game/flow.odin`, `game/menu_level_select.odin`, prefs |
| 4 | `data/level.odin` and `data/assets.odin` (fields), the weapon grant in `weapon_system`, `game/settings.odin`, `level_system` (start at row), the `run` task |
| 5-10 | New packages (`terrain/`, `editor/`, `tools/terrain_recover/`) and tasks; nothing else in the core |

## Risks and open questions [I]

- **Shadow refinement's shape bias** is the weakest part of Stage 6. If the
  1/4-resolution offsets with a curvature prior don't clear the IoU bar
  without streaks, remastered heightmaps will need more hand sculpting.
  Budget editor time accordingly.
- **Vegetation is under-specified.** The originals have instanced trees and
  palms, and we have no models. Canopy height plus a canopy material is the
  cheap first version. Modelled low-poly trees are a later option once Task
  2 shows how far the cheap version gets.
- **A remastered level can't look like its original until the structures
  are right.** Stage 8's `levels:bases` measurement decides how many
  structure footprints need making.
- **Plugin id and netplay compatibility.** Widening `Mods` changes the Start
  message. Old and new builds refusing each other is fine, since D50 already
  compares builds, but it should be deliberate.
- **Texture limits and memory.** A 4x map is 1920x14400. As a render
  texture that is about 110 MB, and it is beyond some GPUs' size limit. Any
  runtime HD mod must tile the terrain buffer, not only the export.

## Where to record progress

- Add a row to the status table in `src/docs/README.md`, replacing "Bonus —
  Developer tools" for the editor part.
- Write a `src/docs/` phase doc as each stage lands, with the numbers from
  `terrain:compare` and the recovery report as the regression baseline.
- Mark Tasks 2 and 3 done in
  [headless-3d-to-2d-pipeline.md](headless-3d-to-2d-pipeline.md) as they are
  finished.
