# Phase 4 — Deterministic simulation

**Status: readiness assessed; one blocker open.**

The exit criterion is that the shipped films replay through the Odin
simulation to a state trace matching the original. A readiness pass found the
foundations sound, fixed one outright error, uncovered one architectural
constraint, and hit one blocker.

## Ready

| Prerequisite | Evidence |
|---|---|
| Session parameters | film seed, level id, game type — all verified (Phases 2–3) |
| Input model | one byte per player per step; bit→button mapping proven |
| Fixed-step model | `G_Game_Play` advances game time `DAT_004e4836` once per sim step |
| Data | every definition family loads and reconciles (Phase 3) |
| Behaviour reference | 1,942 decompiled functions (Phase 2) |

**Time base.** `U_App_GetTickCount` emulates the Mac OS 60 Hz `TickCount` on
Windows: it accumulates `GetTickCount() * 256` and emits one tick per `0x10aa`
units, i.e. every 16.66 ms. `G_GameInterface::Draw` then gates each sim step
with a frame-skip counter (`999` means paused). Wall-clock pacing is therefore
a presentation concern; the simulation only needs `step()`, and films advance
it one input byte at a time.

## Fixed: the simulation's RNG was the wrong algorithm

Phase 0 used xorshift32 as a placeholder. The original uses the Metrowerks
Standard Library `rand()`/`srand()`, recovered from `_rand` and `_srand`:

```
next = next * 1103515245 + 12345
return (next >> 16) & 0x7fff
```

— the classic ANSI C generator. `srand(1)` reproduces the well-known reference
sequence (16838, 5758, 10113, …), an independent check on the constants.

Game code never calls `rand()` directly outside two helpers, both now in
`sim/rand.odin`:

- `U_Utils_RandomInt(lo, hi)` — `lo + rand() % (hi - lo + 1)`, returning early
  without drawing when the bounds are equal.
- `U_Utils_RandomFloat(a, b)` — `(b - a) * rand() / 32767.0 + min(a, b)`. The
  divisor was read from the binary (`0x4de12c` = `32767.0f`). When `a > b` the
  result lands in `[2b − a, b]`, not `[b, a]`; that bug is reproduced
  deliberately.

Both early-outs change how many numbers are consumed, so both are tested. Seven
tests pin the generator to reference vectors, including the seed recorded in
Demo 01.

## Constraint: presentation code draws from the gameplay RNG

The single generator is consumed by gameplay (`G_Entity::ChangeState`,
`::SpawnControl`, `::Animate`, `::Flee`, `G_EG_Process`, `G_Player`, …) **and**
by particles (`G_Particle_NewGroup`, `G_Particle_Init`) **and** by sound
(`U_Sound_Play` draws pitch and volume with both helpers).

Every randomised sound therefore advances the sequence gameplay depends on. For
a film to replay faithfully, the simulation must make those draws itself, in
the original order. The design consequence:

- `sim/` decides *that* a sound plays or a particle burst spawns, draws its
  random parameters, and emits an event carrying them;
- `audio/` and `render/` execute those events and draw nothing.

`sim/` stays pure, and the draw order stays the original's. Deciding this now
is cheap; discovering it after the entity system exists would not be.

## Open risk: floating point

Positions and speeds are `float` (`G_GameObject::SetLoc(float, float)`), and
the original is x87 code (`math_x87.obj`, `ansifp_x86.obj`). Odin computes
`f32` on SSE with a rounding per operation; x87 may carry wider intermediates
between stores. Over thousands of steps that can diverge. Whether it does is an
empirical question that needs the reference oracle below.

## Blocker: there is no reference trace

Films record inputs, not state. Replaying one through our simulation proves
our simulation is *deterministic*, not that it is *correct*. Proving
correctness needs the original's state at each step — which means running the
original.

**The original does not run under Wine as things stand.** Under Xvfb it stops
at a modal dialog:

> QuickTime could not be initialzed. Visit http://www.apple.com/quicktime to
> download.

The game statically links QTML, but QTML still needs the QuickTime runtime
components, and the Read Me lists QuickTime 5.0 or later as a requirement. An
earlier note in this project reported that the game "launched and stayed
running" under Wine. That was wrong: it was sitting on this dialog.

### Paths forward

1. **Install QuickTime for Windows into the isolated Wine prefix**, then drive
   the demo films under a debugger. With the recovered symbol map, `gdb`
   attached to the Wine process can break at `G_Film::GetInputs` (`0x41e300`)
   once per step and read the RNG state and player positions. Strongest
   verification. Effort uncertain — QuickTime under Wine is notoriously
   fragile — and it means fetching an archived Apple installer.
2. **Proceed without an end-to-end oracle.** Port behaviour from the corpus and
   verify function by function against the decompiled logic, with RNG-draw
   accounting as the main cross-check. Faster to start; film fidelity stays
   unproven.

The RNG state is the most valuable thing the oracle would provide: if
`rand.next` matches at every step, every random draw happened in the original
order, which transitively validates a great deal of behaviour at once.
