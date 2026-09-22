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
