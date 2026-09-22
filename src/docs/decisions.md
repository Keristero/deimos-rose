# Decision log

Cross-cutting choices, with the reasoning, so they can be revisited on
evidence rather than re-argued from memory.

### D1 — Reimplement in Odin; do not decompile to match

The goal is a game that behaves like the original, not a byte-identical
rebuild. Decompiler output is reference material. This removes the need for
Metrowerks CodeWarrior and deletes ~1,474 of 1,942 functions from scope.

### D2 — raylib provides the engine layer

Rendering, audio, input, windowing. The original is a software blitter writing
16-bit pixels into a DIB, so there is no GPU behaviour to reproduce — a pixel
buffer uploaded as a texture is sufficient and faithful.

### D3 — `sim/` is pure; everything else is free

`sim/` imports no raylib, no I/O, no wall clock, no ambient RNG. Enforced by
`mise run purity` in CI. Film replay, rollback and fast tests all depend on it.

### D4 — Faithful in `sim/`, modern everywhere else

Gameplay-visible behaviour matches the original where films can prove it.
Rendering, audio, UI, netcode and tooling are written the way we would write
them today.

### D5 — Rollback over ENet rather than vendor:ggpo — *provisional*

`vendor/ggpo/ggpo.odin` contains a single unconditional
`foreign import lib "GGPO.lib"`, no `when ODIN_OS` branches and no Linux
library: it cannot link on Linux as shipped. The hard part of rollback is
deterministic state save/restore, which `sim/` must provide regardless and
which GGPO would not supply. Revisit at Phase 6; keep the binding as an
alternative backend behind the same interface.

### D6 — WAV over OGG for extracted audio

No Vorbis encoder is available in Odin's vendored libraries. Lossless and
universally readable beats a build dependency for 99 sound effects.

### D7 — Definition records pass through byte-exact in Phase 1

Decoding `unde`/`leve`/`wede`/`plde` requires format work that belongs with the
data layer. Phase 1 catalogues them in the manifest instead.

### D8 — Original game data is never committed

`assets/`, `build/` and `.deps/` are gitignored, as are `orig/` and `game/` in
the parent repository. Everything is regenerated from a local copy of the
installer.

### D9 — The decompilation corpus is reference material, never a source

Files under `work/decomp/export/` are read to understand behaviour. Nothing is
transliterated from them into `src/`. Every exported file carries that note in
its header.

### D10 — Ghidra and its corpus live outside the tracked tree

Ghidra goes in `~/.cache/deimos-rising/`; the project and corpus in a
gitignored `work/`. Not `src/build/`, because `mise run clean` would discard
minutes of analysis. Not a dotted path, because the headless analyser rejects
any path element beginning with `.`.

### D11 — Typed loaders only where the format is proven

Levels, films and all three definition families get typed structs because their
layouts are recovered. Fields that are merely present, not understood, stay
reachable by name: every scope keeps its tags verbatim alongside the typed
view, so an incomplete schema never loses data. The remaining tagged-text
families are exported as ordered key/value JSON.

### D12 — Guesses are marked in the code, not just the docs

`BIT_TO_BUTTON` and `Game_Type.Co_Op` carry PROVISIONAL comments naming what
would resolve them. Two Phase 0 guesses (`Single = 0`, `level_id: u16`) turned
out wrong; marking them in the source is what makes them cheap to fix.

### D13 — Parse by scope, not by position

Unit definitions are read by field name with `stateName_STR`,
`stateSpawnSetName_STR` and `stateRuleName_STR` opening scopes. A positional
reader derived from one record handles 359 of 386 and then fails on optional
fields. Declared counts are validated afterwards rather than trusted to drive
the walk.

### D14 — The simulation reproduces the original RNG exactly

MSL `rand()` and the two `U_Utils` helpers, including their early-outs and the
reversed-bounds quirk in `RandomFloat`. Replaces the Phase 0 xorshift
placeholder, which could never have replayed a film.

### D15 — Sound and particle RNG draws happen in `sim/`

The original's audio and particle code consume the gameplay RNG. `sim/` makes
those draws and emits events carrying the results; presentation executes them
and draws nothing itself.

### D16 — Accurate by default, but not accurate at the expense of looking worse

The screenshot-comparison harness (Phase 5) is ground truth for correctness,
not a mandate to reproduce every original limitation. Where matching the
original would reduce fidelity for no gameplay reason -- and subtle Wine
colour-grading differences from the original's own presentation, which stay
unaddressed until after Phase 6 -- the higher-fidelity choice wins by default.
A `-classic` flag (`game/settings.odin`) exists for anyone who wants the
closest possible match instead; it is lower priority than reaching ~95%
accuracy across the whole game, which comes first. Nothing has used the flag
to diverge yet -- Stage 3 onward is where a real fidelity choice will show up.

### D17 — The simulation steps on a fixed clock, independent of the render rate

`FPS_MaxRate`/`FPS_Delay` (perm floats 0x20/0x21) show the original targets
30 FPS and paces itself with a busy-wait in `G_GameInterface::Draw`, stepping
once per drawn frame. `game/main.odin` reproduces the 30 Hz step rate with a
fixed-timestep accumulator instead of one step per render call, so gameplay
speed no longer depends on how often the frame is presented: `SetTargetFPS(60)`
had been running the simulation at double speed. `-highrefreshrate` raises the
*presentation* rate to the monitor's native refresh; the accumulator still
gates `sim.step` to 30 Hz either way.

### D18 — Flow's screens are plain text, not a reconstruction of the original's menus

The original's title, pause and game-over/level-complete screens are built
from button graphics and (for level-select) preview thumbnails whose layout
was never traced (`assets/data/flli/gafl.json`'s `LevSel_*`/`Interface_Btn_*`
perm floats describe it, unbuilt). None of that is simulation-visible or
RNG-affecting, so `game/flow.odin` draws plain text with raylib's own font
instead (the same shortcut `draw_debug` already takes for its dev overlay) and
defers the level-select screen entirely — levels always play in list order
within a session regardless (see the Flow progress note in
phase-5-presentation.md), so nothing is lost by not building a picker for it
yet. Consistent with D16: accurate where it affects the simulation or a
screenshot comparison, not obligated to match everywhere else.

### D19 — Flow reacts to `game_over` directly, not only through `level_end.complete`

`FUN_00420280` sets `DAT_004e4826` (`s.game_over`) the instant the last player
leaves play, independent of whether the level has finished scrolling;
`level_end_step` only learns about it later, once the background reports
scroll-complete, and then just short-circuits straight to `complete` with no
tally to show. Waiting for `level_end.complete` alone to show a game-over
screen would mean it never appears if the level's scroll never finishes (e.g.
losing early, far from the level's end point). `game/flow.odin` checks
`state.game_over` every step and transitions immediately, `level_end.complete`
being for the normal "finished a level" path only.


### D20 — Hand-rolled UDP on `core:net`, not `vendor:ENet`

Supersedes D5's "provisional" choice of ENet. `vendor:ENet` links via
`foreign import ENet "system:enet"` on Linux, which needs a system-installed
`libenet.so` — confirmed entirely absent on this host (`ldconfig -p`,
`pkg-config`, `rpm -qa`, `find` all came up empty), unlike raylib's X11/GL
deps, which `tools/setupdeps/setup.sh` can always find already on the host and
just symlinks; ENet would be the project's first dependency on a package the
user has to `dnf install` themselves. Asked directly, the user chose a
hand-rolled UDP protocol on `core:net` instead: it must build on both Linux
and Windows (`core/net` has `socket_linux.odin`/`socket_windows.odin`/
`socket_posix.odin`, so this is a real cross-platform API, not Linux-only),
and should be written with a possible future WebSocket transport (for a
hypothetical WASM build) in mind, without building that abstraction now.
