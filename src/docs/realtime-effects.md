# Realtime lighting and effects

What was built from notes/realtime-lighting-and-effects.md, and what is
still open. The extension point and its reasons are in decisions.md D78.

## Built

- `render/post.odin`: the post-pass chain, free when unused.
- `plugins/lighting` (+ `view/`): LIGHT STRENGTH and GLOW STRENGTH sliders on
  the Extras page (default 60 and 50, plugin off by default). Lights come
  from `Item.emit` and bright particles, each in its sprite's colour, up to
  96 a frame; the glow is the same things blurred.
- Ground layers for the lighting, exported with every level (`layers.specular`
  and `layers.normal`, full-resolution PNGs beside the map, from
  `terrain/specular.odin`): a **specular mask** (a material's `gloss`, else a
  guess from the colour; trees dull it; ground under the water is wet, the
  shore damp) and a **normal mask** (from the heights and canopy, unsmoothed).
  The lighting shades the ground by the normal against where a light is (taken
  from the light map's slope, since the map does not keep each light) and adds
  a highlight in the light's colour where the ground is glossy and faces
  halfway to the eye. A level without them gets flat ground of default gloss.
  `plugins/recovered_levels` is re-exported (`mise run terrain:mod`) with them
  (about 40 MB of normals, 14 MB of specular). Verify: `deimos -campaign
  recovered_levels` with `MENU=lighting`.
- `plugins/wind` (+ `view/`): WIND STRENGTH slider; blows the visual
  particles by the level's wind.
- `plugins/water` (+ `view/`): WATER STRENGTH slider (default 60, off by
  default). One shader quad over the play field, masked by the level's media
  mask, drawn over the ground and under the air units: wind-driven waves, a
  sky with drifting clouds reflected and bent by them, the sun's glint.
  Costs nothing outside the water. `MENU=water` shows stage 5's river.
- `mise run menu-shot MENU=lighting` shows a shot in flight with the lighting
  on (stage 7).

## Still open

- Export resolution 0.5x to 2x and the High Resolution mode (editor export).
- HD textures and their masks (the best local model; `tools/hd_upscale` uses
  FLUX on a GPU, so it runs on the project owner's machine).
- A gloss control per material in the paint panel (the field exists in the
  project; nothing sets it yet), and a smoothing pass on the normals if
  the heights' grain shows under light (tried, set aside).
- Sprite albedo, emissive and normal recovery, units "more metallic" than
  terrain; enemy fire's emissive textures (their shots do not shine yet).
- Water: ripples from ground shots, refraction of the bed and a
  transparency control (the art already has the water translucent over the
  bed); drawn in the effects order, so an air unit's shadow over water is
  tinted too.
- The level's skybox and real clouds in the reflection (the sky is
  procedural for now).
- The optional realtime 3D mode with lighting by height.
- A wind control in the editor (no level has any wind, so the wind plugin
  does nothing in a shipped level yet).
- Stage 10 layer export from the editor.
