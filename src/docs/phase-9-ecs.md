# Phase 9 — ECS refactor and mods

The simulation had grown by accretion. First came the reverse engineering,
then easy mode, the passives, the loadout and the new weapons, each wired
into `sim/` wherever it touched. [`notes/ecs-refactor.md`](../../notes/ecs-refactor.md)
asks for three things:
- data in components and behaviour in systems;
- the render pass as systems too, in its own loop;
- Deimos Rose's additions split into plugins that a Mods page in
  Preferences turns on and off.

The notes expect "a broad refactor first, then restore accuracy". Accuracy
never had to be restored: every commit kept `oracle:diff` exact and the
golden fingerprints unchanged.

## Exit

- The simulation's state lives in an ECS world, stepped by registered
  systems.
- New content is in plugins with dependencies, toggled from a Mods page.
- `mise run ci` is green.
- `oracle:diff` is still exact (42,446 / 81,184 / 112,286 / 95,085).
- `tests/golden/fingerprints.txt` is unchanged since it was recorded.

All five hold. What the notes ask for and this phase did not finish is
under [Still open](#still-open).

## How it was kept honest

**Golden fingerprints came first** (`tests/golden_test.odin`, before any
refactoring). The test replays the four shipped demos, plus three seeded
sessions with the additions on:
- easy mode's reward screen after stage 1;
- New Weapons' loadout screens at stages 7 and 10.

It runs on the committed assets and never needs the original game. Every
500 steps it hashes the state by value, and it hashes every random draw.
The recording was never rewritten after the first commit. Each step of
the refactor had to reproduce it bit for bit, alongside `oracle:diff`
against the original's own traces.

Only one thing moved: the checksum itself (`sim.checksum`, used by
rollback). Once the state lived in the world, the checksum hashed all of
it, including side_scroll and player fields it had skipped before. Two
rollback tests had ended with each side guessing the other's last input.
The old checksum missed the difference. They now keep the last send.

## What was built

### The world (D39)

odecs is vendored unmodified in `third_party/odecs/`. `sim/ecs.odin` wraps
it:
- a process-wide component catalog;
- fixed entities: the session (1), the players (2–3), the crosshairs
  (4–5), the 1,024 groups, then the 1,000-slot entity pool;
- snapshots, restore and hashing from the world's contents alone.

Every entity is created when the world is, in the same order, and is
never destroyed. Spawning adds components to a pool slot, and freeing
removes them. So an entity's id is the same on every machine and after
every rollback.

32 component types cover what `State` held, among them:
- the session singletons: clock, RNG, film cursor, level info, game
  status, background, debris, notices, level end;
- the players' Ship, Purse, Hull, Overload and Weapon_Handler;
- the pool's Game_Object, Actor, Anim, Motion and so on;
- the plugins' own.

`State` keeps only:
- the session settings;
- the schedule;
- this step's output queues (sounds, particles, stamps, blurs, beams,
  notices), which presentation reads and each step clears;
- debugging records.

### Systems

A step is the registered systems run in order (`sim/systems.odin`). There
are three registries:
- **systems**, of three kinds:
  - Step: the game step, FUN_00420280, in its 12 parts;
  - Session: around the game step in a played session, such as the level
    change and the plugins' screens;
  - Setup: once as a session starts, where a plugin gives the session's
    entities its components;
- **player stages**: G_Player::Process in 7 parts, run for one player at
  a time;
- **entity stages**: G_EG_Process's body in 19 parts, run for one entity
  at a time, in group order.

Stages run one player or entity at a time because running one stage over
all of them before the next would reorder the random draws.

A system places itself by naming what it runs `after` and `before`
(`sim/schedule.odin`); otherwise registration order holds. That way the
core's order is the original's, and a plugin can slot a system into the
middle of it. As the notes ask, this ordering is run order only, not data
access.

`schedule_build` orders the core's systems and those of the session's
plugins once, when the session starts. The schedule is therefore the same
on every peer.

### Render systems

`build_frame` is a loop over render systems (`game/render_systems.odin`),
ordered the same way:
- clearing the layers;
- terrain;
- the score bar;
- the view;
- entities;
- players;
- motion blur;
- notices.

Self Outline is a system of its own, registered by the Accent Color
plugin, and placed before the ships. `render_schedule_build` leaves it out
when the plugin is off. Every layer's items matched the previous
`build_frame`'s for all 3,000 steps of each demo film, with and without
accents.

### Plugins (D40)

Each plugin is a folder under `plugins/` that registers itself, its
components, its systems and its hooks from an `@(init)` procedure:

| Plugin | Needs | In the session | On by default |
|---|---|---|---|
| Extra Preferences (`extra_prefs`) | — | no | with its dependants |
| Passive Upgrades (`passives`) | Extra Preferences | yes | no |
| Easy Mode (`easy_mode`) | Passive Upgrades | yes | no |
| Loadout (`loadout`) | Extra Preferences | yes | with New Weapons |
| New Weapons (`new_weapons`) | Extra Preferences, Loadout | yes | yes |
| Accent Color (`accent`) | Extra Preferences | no | yes |
| 30FPS Unlock (`fps_unlock`) | Extra Preferences | no | no |
| Netplay (`netplay`) | — | online only | yes |

The dependencies are the notes' list. A plugin is on only while every
plugin it needs is on (`sim.mods_resolve`). A plugin imports those it
needs, which is what lets it use their components, and the import also
guarantees they are linked and registered.

A session plugin changes the simulation, so it is part of `sim.Session`
and the same on every peer. Any other plugin is the player's own, such as
how the game looks or the Extras page, and never reaches the simulation.

The core reaches plugins only through hooks (`sim/hooks.odin`, D41):
- stat providers: the passives' modifiers;
- holds: a screen that keeps the level from moving on;
- a weapon chooser: the loadout's;
- weapon filters: New Weapons lets the new weapons in.

The core never names a plugin. A plugin's `get` returns nil when it is
off, and the core's code reads the same as before the plugins existed.

Three changes were needed to lift the plugins out cleanly. None of them
changes behaviour:
- **Hull.calm** replaces the passives' regen interrupts. It counts the
  steps in play since the last shield loss, appear, level reset or setup,
  and a core `calm` stage keeps it. Shield Regen, now the passives' own
  stage, resets its accumulator when calm is 0, as the interrupt did.
  Recharge_Delay level 3 is 0, so without the reset the two differ.
- **The level change no longer checks the reward screen.** The screen
  always ends the step, or closes itself, before the level change runs,
  so the check was never reached.
- **The core strips Pause from the players' input itself.** The netplay
  pause system used to, in every session. It now runs only online, and
  the game still never sees the button.

### Mods page and settings (D42)

Preferences has a NEW CONTENT row with two buttons:
- **MODS** opens a page with every registered plugin: its label, what it
  does and what it needs, and a switch. Turning a mod on turns on what it
  needs, and turning one off turns off what needs it (`prefs.mod_toggle`).
  So the saved set can always run.
- **EXTRAS** opens the Extra Preferences plugin's page, and is greyed out
  while that mod is off.

The Extras page lists the settings of the mods that are on, and scrolls
when they do not fit. Page Up, Page Down and the mouse wheel move it.

A plugin registers its settings from its `view/` package
(`prefs.setting_register`). The plugin's own package cannot do it: it
runs in the simulation and is held to the purity rule, while `prefs`
formats text. `mise run purity` exempts `view/` folders, and `mise run
check` covers them. Accent Color is the first plugin with settings: both
players' hues and Self Outline, under the keys they always had.

The four extras that switched a feature on or off became mods:
- High Refresh Rate became 30FPS Unlock;
- Accent Colours became Accent Color;
- Easy Mode and New Weapons became their mods.

Mods are saved by name, since a plugin's ID is only its place in the
build's registry. A save file from before has no `mods=` line, and its
four old lines are read into mods. Once a `mods=` line is saved, it
supersedes them.

The title screen's Netplay button follows the Netplay mod. The Easy Mode
toggle on Level Select and the lobby switches the mod. Classic mode turns
every mod off.

### Start carries the mods (D43)

The host's session plugins travel in Start and Level_Choice, as four
bytes after the flags byte. So a session with the loadout but not New
Weapons, or the passives alone, reaches the guest as the host has it.
The flags are still sent, so a build that reads only them sees what it
did before. A Start from such a build has no mods, and the game makes
them from its flags (`mods_from_flags`).

## Verification

- `mise run ci`: 163 tests. The new ones are the golden runs, plugin
  dependencies and order, render schedule, mods and settings save format,
  legacy keys, dependency toggling, packets with mods, and a Loadout-only
  session.
- `mise run oracle:diff`: 42,446 / 81,184 / 112,286 / 95,085, exact at
  every commit.
- `tests/golden/fingerprints.txt`: unchanged since it was recorded.
- Looked at: menu shots of Preferences, the Mods page, the Extras page,
  the netplay lobby states, the reward and loadout screens, and the
  Chaingun in play.

## Still open

- **Plugin presentation still lives in `game/`.** Only the settings
  moved: the reward, loadout and passives screens (`game/reward.odin`,
  `game/loadout.odin`, `game/passives.odin`) and the outline render
  system are still game code gated by plugin ID. Moving them into their
  plugins' `view/` needs the renderer's types in a package below `game`,
  so a view package can register a render system without importing
  `game`.
- **Systems are the original's function-sized parts, not small queries.**
  A movement system over "everything with a velocity" would visit
  entities in archetype order. The random draws depend on the original's
  list order (D39), so the stages walk the group lists instead. Splitting
  them further is possible where nothing draws, but was not attempted.
- **Behavioural coverage is not measured.** The golden runs cover four
  demos and three sessions with the additions on. There is no coverage
  tool to say which paths they miss.
- **A session with the passives but not Easy Mode** has no way to earn a
  passive. It runs, and is the same as neither.
- **The new Start is untested between two builds** and on two machines,
  as is all of Phase 6 stage 6. `tools/netplay/loopback_check.sh` was not
  run.
