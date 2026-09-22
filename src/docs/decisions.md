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
