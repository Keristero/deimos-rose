# Working methodology

Guidance for anyone — human or agent — continuing this project. Update it when
a rule turns out to be wrong or a new one earns its place; it is a living
document, not a charter.

## What this repository is

Two things, kept separate:

- **Analysis of the original 2003 Windows build** — `orig/`, `game/`,
  `symbols/`, `notes/`, `tools/`. Read-only archaeology.
- **A new game in Odin** — `src/`. The actual deliverable.

`src/docs/` records progress per phase. `notes/odin-rewrite-plan.md` is the
overall plan. `src/docs/decisions.md` logs cross-cutting choices.

## The core habit: verify, then build

Almost every significant finding in this project contradicted a reasonable
assumption. Check before building on it.

- 7-Zip "supports NSIS" — it cannot open this NSIS 2.0b1 installer at all.
- The CodeView blob "should" hold struct layouts — `sstGlobalTypes` is 8 bytes
  and empty.
- `vendor:ggpo` "is available in Odin" — it is Windows-only and will not link.
- The IA sprite plate "is an alpha mask" — it is, but *inverted*, and assuming
  otherwise produced 125 sprites on solid green.
- The original "launched and stayed running" under Wine — it was actually
  blocked on a "QuickTime could not be initialized" dialog. A process that does
  not exit is not a process that works.
- QuickTime "installs with winetricks" — its verb crashes and rolls back. The
  real cause, a missing Apple Application Support MSI, only showed up in a
  `+module,+seh` trace. When an installer fails, trace the failing load
  instead of retrying variations of the same install.
- A port that is "missing something" is usually doing *too much*. Both of the
  last divergences in Phase 4 were code the port added: invulnerability the
  original never granted, and an `unported()` marker on a function that in
  fact does nothing. Before adding a mechanism, check the original is not
  simply silent there.

**A false gap is worse than no gap.** `unported(site)` tells the diff that a
divergence beyond that point is expected, so a marker on code that does
nothing hides a real bug. Only mark a site after reading what it does.

The cost of checking is minutes. The cost of not checking is a phase built on
sand. When a claim matters, find the bytes that prove it and put the evidence
in the commit message or the phase doc.

**Compare state, not just behaviour.** The call diff says when a divergence
happened; the event diff says which entity; only a snapshot of the state
itself — shields, money, lives, position, step by step — says why. Values
drift silently for thousands of frames before they reach the RNG, so the
first *observable* difference is usually far from the cause. Extend the
oracle to record whatever you are guessing about; it is cheaper than guessing.

**Look at the output.** The sprite inversion was caught by opening the PNG, not
by reading code, and the QuickTime failure by taking a screenshot rather than
trusting an exit code. Decode a file, render an image, play a sound, print the
numbers. Counts passing is not the same as content being correct.

## Sources of truth, in order

1. **The original binary and its data.** `symbols/functions.csv` (1,942 names,
   99.9% boundary-validated), the PAKs, the shipped `DeimosRisingWin32.log`.
2. **Ghidra output** for behaviour that is not obvious from names.
3. **The clean-room remaster project** — genuinely useful format research in
   its `reverse/formats/`, and usable to us without restriction. But it was
   produced in 23 commits over two days and its "binary-confirmed" labels are
   self-asserted. **Where it and the binary disagree, the binary wins.**

Never let 3 override 1 silently. If you take a structural claim from the
remaster, say so and note whether you confirmed it.

## Rules that hold

**Every task lives in `src/mise.toml`.** If you ran a command to build,
extract, check or verify something, it belongs there as a task. Ad-hoc shell
invocations are how a project becomes unbuildable by anyone else.

**Add every new package to the `check` task.** A refactor once broke
`tools/extract` while `mise run check` stayed green, because the task did not
cover `tools/`. This is the one part of the scaffold that fails silently.

**`sim/` stays pure.** No `vendor:raylib`, no `core:os`, `core:fmt`,
`core:time`, `core:math/rand`, `core:thread` or `core:net`. It takes inputs and
a seed and produces state. `mise run purity` enforces it. Film replay, rollback
and fast tests all die without it, and it cannot be retrofitted cheaply.

**RNG lives in the state.** An ambient global generator desyncs rollback
silently. `G_Film::GetRandomSeed` shows the original made the same choice.

**Tests must not require the original game data.** Use synthetic fixtures.
Integration checks against `game/` are fine but must skip cleanly when absent,
so CI runs for someone without a copy of the game.

**Never commit game content.** `orig/`, `game/`, `src/assets/`, `src/build/`
and `src/.deps/` are ignored. Tooling, derived symbol listings, manifests and
notes are tracked. Everything regenerates from a local installer copy.

**Do not push to any remote.** Standing instruction from the project owner.
Commit locally; that is all.

## Writing the code

The goal is a codebase that is a pleasure to read.

- Name things after what the original called them when the name is good
  (`G_Player`, `U_Pak`), and after what they do when it is not.
- Comments explain *why*, and record evidence: which address, which file, which
  observation. `data/tga.odin` and `tools/extract/main.odin` are the style —
  they say what was verified and against what.
- Mark provisional decisions as provisional, in the code, with what would
  resolve them.
- Prefer allocation-free designs where they are natural. Odin's test runner
  reports leaks; treat that as a failure, not noise.
- Keep faithful behaviour in `sim/` and write everything else the modern way.

## Finishing a phase

1. `mise run ci` green, and the phase's own verification task green.
2. Write `src/docs/phase-N-*.md` while it is fresh: what was built, what the
   original turned out to do, what was decided and why, what is still open.
   Record the concrete numbers — they are the regression baseline.
3. Update the status table in `src/docs/README.md`.
4. Add any cross-cutting choice to `src/docs/decisions.md`.
5. Correct the plan if the phase proved it wrong. Phase 1 in the original plan
   claimed definition records would round-trip through JSON; that was
   misscoped and moved to Phase 3. Say so rather than quietly dropping it.

## Reporting

Say what was verified and how. Distinguish "the counts match" from "I decoded
it and looked at it". When something is unproven, say it is unproven. When an
earlier statement turns out to be wrong, correct it plainly once and move on —
several claims in `notes/` have already been corrected this way, and the notes
are better for it.
