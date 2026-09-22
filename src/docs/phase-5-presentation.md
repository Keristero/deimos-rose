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
| `plwe` | 9 | | | |

An empty or `none` layer becomes `defa`. `draw_to_terrain` objects (a
state's `stateDrawToTerrain` -- live tank tracks and craters, not the
permanent wrecks `destructDrawToTerrain` stamps into the map at destruction)
skip this switch entirely and always land in layer 1, regardless of
`drawLayer_ID` -- confirmed against `G_GameObject::Priv_Draw`, not guessed
from the name.

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
3. **Effects** — particles, motion blur, driven by what the sim emits. (Debris
   has no draw of its own in the original — `G_Debris` is a pure collision
   rectangle, checked against the full decompiled corpus, which has no draw
   proc for it at all.)
4. **Interface** — score bar, notices, text.
5. **Audio** — sound events and music.
6. **Flow** — title, attract demos, level transitions, game over, pause.

## Exit

Playable single-player from the title screen to the end of the last level,
with `oracle:diff` still exact and `mise run ci` green.

## Progress

**Assets and Renderer are done** (commits 77e6970, 84deaf7). The frame index
and JSON definition loader from the "Assets" section above are built and
tested against the original, field for field. The renderer composites all
sixteen layers, the scrolling terrain, shadows, tint and glow, and the sprite
font, verified against the original with a new tool: a gdb harness
(`tools/oracle/shot.py`, `mise run oracle:shot`) freezes the running original
at an exact game step and photographs it, which `mise run shots:compare`
compares pixel-for-pixel against our own headless capture of the same step.
That comparison — not just the call-trace diff — found four real gaps no
behavioural test had caught: the sideways view scroll was never ported, swept
units with `destructDrawToTerrain` were never stamped into the map (the
Lucena fortress was simply missing), the hit glow was being treated as
presentation-only when it is deterministic per-step state, and a tint colour
field was never read (tinted objects rendered black). All four are fixed in
`sim/`; `oracle:diff` still matches the original call for call on all four
demos and the test suite is green.

**The 60 FPS double-speed bug is fixed.** `FPS_MaxRate`/`FPS_Delay` (perm
floats 0x20/0x21) show the original runs at a fixed 30 FPS; the live loop in
`game/main.odin` now steps the simulation on a fixed-timestep accumulator
gated to that rate (see decisions.md D17) instead of once per render call.
A `-highrefreshrate` flag presents at the monitor's native refresh rate
without changing gameplay speed. A `-classic`/`Settings.classic` flag exists
per D16 for a future fidelity choice to gate on; nothing uses it yet.

**Effects are done.** `sim/blur.odin` and `sim/particles.odin` (already
present in `sim/destroy.odin`/`eg_process.odin`) emit `Blur_Event`/
`Particle_Event`s; `game/blur.odin` and `game/particles.odin` turn those into
drawable state — a motion-blur ghost is a frozen clone of the object that
fades exactly as `G_MotionBlur_Process` does, while particles fan out and fade
on a simplified curve rather than the original's exact direction table, since
particle motion is cosmetic and never feeds back into gameplay or RNG (the
draw *count* still matches, via the same `particle_count` the RNG burst in
`sim/destroy.odin` used). Debris needed no draw work — see the Stage 3 note
above. `oracle:diff` is still exact on all four demos and the test suite is
green.

**Interface is done.** The original presents a 640x480 screen, not the
416x480 play field alone: a real screenshot of the running original
(`work/wine/cmp/orig-00900.png`) shows the 416-wide play field inset at
`VIEW_X = 32`, and a 160-wide score bar panel immediately to its right
(x=448..608, exactly `assets/images/im16/scor.png`'s own width), with a
symmetric 32px margin on both far edges. `game/render.odin`,`main.odin` and
`particles.odin` widen the window to that true size and apply `VIEW_X` only
at the final blit stage, so every upstream draw call keeps working in its
existing 0-416 local space. `game/scorebar.odin` draws the panel backdrop
plus each player's score, extra-lives count, and shields/power bars, using
rects from `assets/data/reli/inre.json` matched positionally against
`G_ScoreBar_Init`'s `G_Res_GetPermRect(0..15)` call order rather than
transliterating `G_ScoreBar_Draw`'s raw offset arithmetic; colours and layout
were checked pixel-for-pixel against the real screenshot. Both panel halves
draw unconditionally, matching `G_ScoreBar_Init` — a single-player game still
shows "player 2, 0/0", not a blank lower half, which a screenshot comparison
caught after an initial `Player.active`-gated version left it empty. Not yet
drawn: the life icon and the three weapon icons, whose sprite selection is
data-driven per player/weapon definition and wasn't traced.

`text_panel`'s anchoring was wrong, caught after the fact by a closer look at
the panel: every rect in `inre.json` is an oversized bounding box, not a tight
fit around its text (life count's is 46x44 for one digit that belongs in a
~30px round badge cutout), and text was drawn at the rect's raw top-left
corner. The score rect happens to be barely taller than its text, so the bug
was nearly invisible there, but it left the life count digit floating well
above its badge. Measured pixel-for-pixel against `orig-00900.png`: centering
horizontally and anchoring to the rect's bottom edge lands both exactly where
the original draws them. A second, subtler gap turned up alongside it once
the first was fixed and the score digits were re-checked: `text_panel` drew
consecutive digits with no gap, while a column-brightness scan of the
original's "0001250" found a consistent 3px gap between glyphs (matching
`game/text.odin`'s existing `spacing` convention, which `text_panel` had never
picked up). Both fixes verified by re-measuring digit-ink column positions in
a fresh screenshot: the score run that started ~11px off after the first fix
alone now differs from the original by 1-2px, within antialiasing noise.

`sim/notice.odin` now ports `G_Notice_Request`/`G_Notice_Process` for real,
replacing the stale `unported` markers in both `notice.odin` and
`destroy.odin`. This turned out to be dead code in the shipped game —
`entryNotice_STR` and `destructNotice_STR` are empty on all 386 unit
definitions, checked directly — so it's ported for completeness (a unit
*could* set either field, and the sound draw has to be RNG-correct if one
ever does) rather than because any level needs it. Since no demo film
exercises the path, `sim_test.odin` drives `notice_request`/`notice_process`
directly with a synthetic unit instead, and caught a real bug in the
process: `Sound_Settings{}`'s zero value is `Res_ID{0,0,0,0}`, not `NONE`
(the fourcc `"none"`), so the destruct-notice path was comparing against the
wrong sentinel and would have played a spurious sound. `game/notice.odin`
shows the notice text as a banner across the top of the play field; since
the path is unreachable with real data, its exact position
(`G_Text_GetPermTextSetting`) and typewriter reveal/fade timing
(`G_Res_GetPermFloat 0x47-0x49`) weren't traced — neither affects the RNG
stream, and neither can be screenshot-verified against a path the real game
never takes.

`oracle:diff` is still exact on all four demos and the test suite is green.

**Audio plays.** `U_Sound_Play` (`FUN_0044fab0`) is a maze of raw offsets,
skipped per its own header, but its behaviour is simple: play a clip at a
volume (0-100, clamped) and pitch (roughly a 0.4-2.0 multiplier, checked
across every unit definition's Min/MaxPitch fields) the simulation already
draws from the gameplay RNG (`sim/sound.odin`, pre-existing), either always
retriggering or skipping when the same id is already playing. Checking the
decompiled `G_EG_Process` caller settled a real question: that skip check
runs *before* `U_Sound_Play`, so it would skip the RNG draw too, not just the
audio -- and since `soundAllowOnlyOneInstance` is false on all 386 unit
definitions, every state, the skip branch never fires with real data. The
stale `unported(0x418614)` marker for it is replaced with that finding
(always retriggering, matching the never-taken branch) rather than left
as a placeholder, the same call made for notices.

Genuine looping sounds (`stateSoundLoop_BOOL`) are a different mechanism
entirely, already modelled in `sim/eg_process.odin` as periodic one-shot
retriggers on a timer -- so `game/` needs no real audio-loop support, only a
one-shot player. `game/sound.odin` drains the simulation's `Sound_Queue`
each step; `game/assets.odin` loads each clip as a few alias voices
(`rl.LoadSoundAlias`) so a retrigger layers instead of always cutting the
previous instance off, since the original's own channel-stealing-by-priority
has no equivalent worth building when raylib/miniaudio mixes far more voices
than its channel budget ever allowed.

Music is a separate, simpler case than the decompiled `U_Music`/`_ambrosia_SSP`
streaming layer suggests: every one of the 12 levels' `music` field extracts
to the same track, `mu03` -- a 196s stereo file, next to 98 sub-second mono
sound effects in the same `audio/` folder, told apart by duration rather than
guessed. `data/assets.odin` now lists every `audio/*.wav` id except the ones
a level names as music; `game/assets.odin` streams the excluded one lazily
per level (`LoadMusicStream`/`UpdateMusicStream`), reusing the terrain
texture loader's existing lazy-per-level-asset pattern. Fading between
tracks (`SSP_FadeMusicDown`) is a level-transition concern for Stage 6, not
built yet.

Verified by actually running the game, not just `DR_SHOT`: raylib's own log
confirms the audio device initialized against PulseAudio, all 98 effect
clips loaded, and `mu03.wav` loaded exactly once as a music stream rather
than a duplicate sound effect. A `DR_SHOT` run (`shots:compare`, `oracle:shot`)
now skips `InitAudioDevice` and all sound/music loading entirely — those runs
happen under `xvfb-run` with no PulseAudio session behind them, and nothing
is there to hear the result either way, so there is no reason to open a
device or log its absence on every headless capture.

`oracle:diff` is still exact on all four demos and the test suite is green.

Still open: Flow.
