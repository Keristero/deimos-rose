# Phase 5 — Presentation

Draw what the simulation decided, play what it emitted, and wrap it in enough
game flow to play from the title screen to the end of the last level.

The rule from Phase 4 still holds: `sim/` decides, `game/` shows. Nothing in
this phase may change a simulation value, and the film replay must keep
matching the original exactly while it happens — `mise run oracle:diff` is the
regression test for every commit here.

## What the original does

Read out of the binary, not guessed:

**One frame** (`FUN_00420740` builds the lists, `G_GameInterface::Draw`
composites them):

```
build:    entities, motion blur, both players, notices, score bar
composite: sprite layers 0-1
           terrain            (G_Bgnd_CopyToFrontBuffer)
           sprite layers 2-5
           particles          (G_Particle_Draw)
           sprite layers 6-15
```

`U_Sprite_RenderLists_Draw(group)` is what fixes the grouping:
group 0 is layers 0-1, group 1 is layers 2-5, group 2 is layers 6-15. Within a
layer, insertion order.

**Layers** come from the object's `drawLayer_ID`, mapped in
`G_GameObject::Priv_Draw`:

| id | layer | | id | layer |
|---|---|---|---|---|
| `defa` (ground) | 3 | | `play` | 10 |
| `grou` | 3 | | `plsh` | 11 |
| `grhi` | 5 | | `plef` | 12 |
| `defa` (air) | 7 | | `plui` | 13 |
| `ailo` | 7 | | `atmo` | 14 |
| `aihi` | 8 | | `hud ` | 15 |
| `plwe` | 9 | | motion blur | 1 |

An empty or `none` layer becomes `defa`.

**One object** draws up to three sprites (`G_GameObject::Priv_Draw`), in order:
its shadow (when `castsShadow` and the shadows option is on), the sprite
itself, then a tint pass when `tint > 0` and a glow pass when glowing. Nothing
draws at all while `visibility <= 0`. Ground objects are offset by
`G_Bgnd_GetUpdateRectTop()` and shifted 32 right; air objects are offset by the
side scroll.

**Text** is a sprite font: `G_Text_Draw` maps each character to a frame of one
sprite group (`FUN_0043eb70` is the table) and draws it like any other sprite.
So text needs no font file, only the plate and that mapping.

## Assets

Everything the game needs is already extracted under `src/assets/` — 125
sprite plates and 45 images as RGBA PNGs, 99 sounds as WAV, every definition
record as JSON with its complete key list, and the four demo films. The game
reads *those*, not the original install: an installed copy stays necessary
only for `oracle:*` and for re-running `extract`.

Two pieces are missing and this phase adds them:

- **Frame rectangles.** A plate is a grid of boxes; `data/sprite_plate.odin`
  cuts it and Phase 4 verified all 1,037 frames against the running original.
  That scan is baked into `assets/sprites/index.json` at extract time so the
  game does not rescan 125 plates at startup.
- **A definition loader for the extracted JSON.** The records keep every
  `key = value` pair, so the same reflection fill (`def_fill`) that reads the
  original's tagged text reads them. The test that matters: the `sim.Defs`
  built from `assets/` must equal the one built from the original install,
  field for field.

## Stages

1. **Assets** — frame index, JSON definition loader, `Defs` equality test.
2. **Renderer** — layers, sprites, terrain scroll, shadows, tint, glow.
3. **Effects** — particles, debris, motion blur, driven by what the sim emits.
4. **Interface** — score bar, notices, text.
5. **Audio** — sound events and music.
6. **Flow** — title, attract demos, level transitions, game over, pause.

## Exit

Playable single-player from the title screen to the end of the last level,
with `oracle:diff` still exact and `mise run ci` green.

## Progress

Nothing built yet; this document is the plan.
