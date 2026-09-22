# Phase 4 — Deterministic simulation

**Status: readiness assessed; oracle blocker resolved — the original now runs
under Wine (see "Resolved: the original runs"). Next: the gdb trace.**

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

## Blocker (resolved): there is no reference trace

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

Path 1 was chosen and has worked; see below.

## Resolved: the original runs

`mise run oracle:fetch && mise run oracle:prefix && mise run oracle:run`
builds a network-isolated 32-bit Wine prefix and screenshots the original at
its title menu (1 PLAYER / 2 PLAYER / PREFERENCES / SCORES / DEMOS / QUIT /
REGISTER). Three findings got it there, each checked with a trace or a
screenshot:

1. **The obvious install fails.** `QuickTimeInstaller.exe` (7.6.9, SHA-256
   pinned to winetricks' `c2dcda76…`) run silently, and winetricks'
   `quicktime76` verb, which runs it the same way, crash in the
   `QuickTimePostInstallMSIProc_deferred` custom action. The MSI then rolls
   back every file. Same result on Wine 8.0 and 10.0.
2. **Copying the files in by hand isn't enough either.** With `msiextract`'s
   output placed in the prefix and the `QuickTime.qts folder` registry value
   set, `WINEDEBUG=+module,+seh` shows `QuickTime.qts` loading, looking up
   `CoreFoundation.dll`, and then jumping to address 0
   (`ecx=c000007a`, procedure not found). QuickTime 7.6.9 needs Apple
   Application Support, which the bootstrapper bundles as a separate MSI. That
   missing DLL is also why the custom action crashed.
3. **Install `AppleApplicationSupport.msi` first**, then `QuickTime.msi`, and
   both succeed (rc 0, no rollback). The game then gets past QTML.

After QuickTime, the game needs an audio device. With none, DirectSound fails
("sound is disabled"), and then the game faults in the Ambrosia SSP music code
(null read at `0x453a7a`, inside the region named `SSP_IsMusicFading`). A
PulseAudio null sink in the container fixes it. Running with sound disabled
would not have skewed the RNG anyway: `U_Sound_Play` makes its random draws
before touching the device, and skips them only for the `'none'` sound id.
But the crash makes the question moot.

The shared image (`tools/Containerfile`) moved to Debian trixie (Wine 10) and
gained `msitools`, `gdb`, `xdotool`, `pulseaudio` and `winetricks`. Installer
extraction was re-run on the new image, and all files match `game/SHA256SUMS`.

## The reference trace

`mise run oracle:trace` attaches gdb to the running original, clicks DEMOS
(held for 0.3 s, since the game polls button state and misses an instant XTest
click), and logs from `tools/oracle/trace.py`:

| line | hook | records |
|---|---|---|
| `S` | `srand` 0x461620 | seed |
| `D` | `rand` 0x4615e0 | one LCG step |
| `N` | `U_Utils_RandomInt` 0x40f7e0 | caller, lo, hi |
| `F` | `U_Utils_RandomFloat` 0x40f840 | caller, a, b (f32 bits) |
| `I` | `G_Film::GetInputs` 0x41e300 | player, step |

The LCG is exact, so RNG state follows from the seed plus the draw count. The
trace therefore records callers and bounds rather than values. That is
cheaper, and it is also a stronger check: the bounds come from definition
data and arithmetic, so a mismatch in either shows up.

Verified on de01, not assumed:

- The traced `srand` argument is **289218 (0x469c2)**, the seed our parser
  reads from `de01.film`'s header.
- `G_Film::GetInputs` runs **4,810** times for the film's **4,809** frames. The
  extra call is the one that finds the film exhausted.
- Every `rand` call in the film comes through `U_Utils_RandomInt`/
  `RandomFloat` (no unattributed draws), all on the game thread.
- Clicking DEMOS again plays the next film: de01, de02, … in order.

de01 makes **40,892** RandomInt/RandomFloat calls from about 30 call sites.
Most have equal bounds and draw nothing (state timers `(40, 40)`, sound
volume `(100, 100)`), which is itself useful: those bounds are our parsed
definition values, checked against the running game.

## The frame loop

`G_Game_Play` runs one simulation step whenever
`G_GameInterface::Process_StartFrame` says so, then advances game time
(`DAT_004e4836`). The step is `FUN_00420280`:

1. `G_Input_CachePlayerInputs` (film playback supplies these)
2. `G_Notice_Process`, `G_Debris_Process`, `G_Particle_Process`,
   `G_MotionBlur_Process`
3. `G_Player::Process` for both players
4. `G_ScoreBar_Process`
5. Level-end logic: spawn the end-of-level unit (`G_Res` object 0x18),
   `G_Bgnd_Process` (scrolling and level status), money counters
6. `G_EG_Process` (every entity group), which also stops or resumes
   vertical scrolling

`FUN_004207f0` handles the transition to the next level. The per-render-frame
work (`FUN_00420740`: `G_EG_BuildDrawList`, `G_Player::BuildDrawList`,
`G_Notice_BuildDrawList`, `G_ScoreBar_Draw`) makes **no** random calls in the
trace. So the gameplay RNG does not depend on frame rate, and all of the
above belongs in `sim.step`.

## The diff harness

- `sim.Rand` carries an optional, caller-owned `Draw_Log`, nil in play and
  netplay.
- `random_int`/`random_float` take the original call site's return address
  (`Site`) and record every call, including equal-bounds calls.
- `oracle/` parses traces and diffs call sequences exactly: site, kind,
  bounds bit for bit, and step.
- `mise run oracle:diff` replays each demo and prints matched calls and the
  first divergence by original function name.

Baseline at the start of porting:

```
de01  seed 289218  4809 frames  4810 steps traced
    calls matched 0 / 40892 (0.0%)
    first divergence at call 0
      original:   RandomInt(400, 2000) at step 0 from G_Player::ResetAtLevelStart+0xfa
```

## Porting aids

- **File-static functions.** CodeView names public symbols only, so
  `G_EG_CheckIntegrity` appeared to be 15,568 bytes, and call sites in G_EG's
  statics were misattributed to it. The Ghidra export now also emits the
  **655** functions the map does not name (2,597 in total, 0 failures), and
  `oracle:diff` names call sites from that index.
- **Definition layouts.** `mise run decomp:layout` scrapes the five definition
  loaders' `U_Token_Get*` calls into `symbols/layouts/*.tsv`, mapping key →
  type → byte offset (98 unit, 103 unit-state, 55 weapon, 54 player and 8
  level keys). This is how `*(float *)(def + 0x268)` in the corpus reads as
  `#initialSpeedMin_FLOAT`. Full key strings come from the executable, since
  Ghidra truncates the labels.

## Port plan

Port in trace order: make the next divergence go away, rerun, repeat. Roughly:

1. Session setup (step 0): players (`G_Player::SetUpAtNewGameStart`,
   `ResetAtLevelStart`), level load and initial placements, the first entity
   state changes and sounds.
2. The entity core: `G_EG_Process`, `G_Entity::ChangeState`, `SpawnControl`,
   `Priv_DoCyclicMotion`, spawn velocity (`FUN_0041c840`), rules.
3. Particles, debris and sound as RNG-consuming sim events.
4. Players: movement, weapons (`G_WeaponHandler`, `G_WepDef`), shields,
   money, collisions.
5. Level flow: background scroll, level end, transitions.

The typed definitions the sim uses are generated from our JSON records, with
`symbols/layouts` as the schema.

## Progress: the world port

Ported against the trace, in `sim/`:

- **World and lists.** Entity pool of 1,000, groups, and U_LinkedList
  semantics (tail append, cursor steps back on delete). `State` is about
  0.5 MB: only the current state's spawn records are kept, because the
  original only ever reads those.
- **Level start.** Player reset (the nag-timer draw), background scroll
  state, required groups from placements (ground units shifted 32 left),
  initial map rows, and the level-notice unit.
- **Spawning.** `G_EG_RequestSpawn`, group size, spawn location and velocity,
  entity init, and `FUN_0041cbc0` cyclic drift.
- **Entities.** `G_Entity::ChangeState` (timer, frame and scale draws, speed
  approach, counter-driven recursion), animation, rules (all 17
  conditions, with two range checks still stubbed), spawn control, the
  deletion sweep.
- **Player.** Set-up, the entry sequence and film input. Only a player in
  state 4 reads input, so film frames are consumed per step in play, and the
  trace's step numbers count film reads.
- **Sounds** as RNG-consuming events. The original passes `min_volume` as
  both RandomInt bounds.

Findings along the way:

- **Level order.** Levels are numbered by matching their identifier against
  12 encrypted names in the executable (0x4e7ba9): Lucena (le07) is 1, and
  the four demos play levels 1–4.
- **Rect order.** `background_RECT` text is left, top, right, bottom;
  `U_Rect` in memory is top, left, bottom, right.
- **Integer parsing.** `_INT` values are read with `sscanf("%i")`:
  `"100.000000"` is 100, and leading `0` means octal. No shipped value has a
  leading zero.
- **Rules.** A rule's action is a state name passed to ChangeState. Those
  naming no state do nothing, which explains Phase 3's "inert actions".
- **Dimensions bug.** CalculateDimensions does nothing unless the dirty flag
  is already set, so a state's new sprite keeps the old size until animation
  or scaling marks it. Reproduced.
- **First-state reads.** An entity's first ChangeState reads "previous
  state" fields at a negative offset. Those bytes are verifiably zero.
- **Call sites.** There are 58 RandomInt/RandomFloat call sites in the whole
  executable (`mise run decomp:sites`). Porting them all is the measurable
  scope of this phase.

Code not yet ported calls `unported(site)`; `oracle:diff` reports the first
site reached. Status now:

```
de01  calls matched 55 / 42447   next: player movement and weapons (plbo at step 89)
de02  calls matched 55 / 81185
de03  calls matched 48 / 112287  next: canBeSpawnedOnlyWhenPlayersActive
de04  calls matched 55 / 95085
```
