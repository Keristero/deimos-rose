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
  a time, each for the players whose components match its `with` and
  `without` (the passives' stages ask for Passive_State);
- **entity stages**: G_EG_Process's body in 28 parts, run for one entity
  at a time, in group order. Each stage names the components an entity
  must have for it to run (see [Prefabs and queries](#prefabs-and-queries-d45)).

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

### Packages (D44)

`dr:sim` is now only the host: the components, the world, the registries,
the schedule, the output queues, rollback and the definitions. It knows
no game. The behaviour is in packages under it, each owning its systems,
stages and components, in the spirit of Orion's `systems/` folder:

| Package | What it does |
|---|---|
| `sim/stats` | the numbers plugins can change, and the mechanics that follow them |
| `sim/lifecycle` | spawning, state changes, destruction and freeing: every system that changes the pool goes through it |
| `sim/systems/debris_system` | wreckage on the ground |
| `sim/systems/notice_system` | on-screen notices and their sounds |
| `sim/systems/background_system` | the scroll |
| `sim/systems/collision_system` | contacts, hits and player damage |
| `sim/systems/movement_system` | the movement AI, following the owner, the move |
| `sim/systems/entity_system` | G_EG_Process: timers, rules, look, spawners |
| `sim/systems/weapon_system` | the weapon handler, the crosshair, the new weapons' shots |
| `sim/systems/player_system` | G_Player |
| `sim/systems/level_system` | level start, end, game over, the move to the next level |
| `sim/core` | the original's order: registers all of the above |

Each package imports only those listed above it, so there is no cycle,
and each system's dependencies are visible in its imports. `sim/core` is
the only package that knows the original's order, the way FUN_00420280
and G_Player::Process read. Importing it is what puts the original game
in a build. A plugin places its systems against the core's by name.

`mise run purity` covers every package under `sim/`, and `mise run
check` vets each one on its own.

### Prefabs and queries (D45)

The original chooses what an entity does from flags in its unit and
state definitions, tested inside long procedures ("if the state orbits
its owner, orbit"). Those flags are now components, and the stages that
act on them ask for them.

Each unit is a **prefab entity**, and so is each of its states, in a
world of their own (`sim/prefabs.odin`). Builders, registered by the
package that owns each component, read the definitions when a session
starts and give each prefab its components: `Emits_Particles` for a state
with particles, `Orbits_Owner` for one that orbits,
`Constrained_To_Play_Area` for a unit that bounces off the edges, and so
on. A component holds the parameters its stage reads, copied from the
definition, and a tag (no fields) is a behaviour with nothing to set.

An entity then has three sets of components: its own (the pool slot's),
its unit's and its current state's. A stage declares `with` and
`without` sets, and runs for an entity only when the union matches. So
changing state changes which systems an entity takes part in, and two
units that share a component share the behaviour. A plugin can give an
existing behaviour to any unit or state by adding the component in a
builder of its own, and its builders run only in sessions with it on.

| Package | Components |
|---|---|
| `entity_system` | `Emits_Particles`, `Entry_Sound`, `Follows_Rules`, `Follows_Owner_Look`, `Pauses_Scrolling`, `Destructs_While_Scrolling`, `Motion_Blur` |
| `movement_system` | `Deleted_Without_Players`, `Destructs_Without_Players`, `Flees_Without_Players`, `Cyclic_Motion`, `Constrained_To_Play_Area`, `Locked_To_Owner`, `Linked_To_Owner`, `Orbits_Owner` |
| `collision_system` | `Collides`, `Collides_With_Players`, `Harmless_To_Players`, `Passes_Hits_To_Owner`, `Blocked_By_Wreckage`, `Ground_Based`, `Player_Projectile`, `Hittable_By_Player_Shots` |
| `weapon_system` | `Targetable` |

Components are shared between systems, not owned by one. What a shot can
hit is a query (`collision_system.shot_query`): Collides and
Hittable_By_Player_Shots, not Harmless_To_Players, and on the ground if
the shot is. The Chaingun's aim and the Discharge Beam ask the same
components (`air_shot_targets`), and a ground crosshair locks onto what
has Ground_Based, Hittable_By_Player_Shots and the state's Targetable.
The shot collision stage itself runs only for entities with Collides and
Harmless_To_Players. The original tested every colliding entity against
every other and found nothing for the rest, so the tests run in 40% less
time.

Where a procedure did several things by flag, it became one stage per
thing. DoMovementAI is now eight stages: flee steering, sensing the
nearest player, the three reactions to there being none, cyclic motion,
keeping to the play area and the hunt. Following the owner is three.
The sighting is kept in the entity's step (`Entity_Step.nearest`), so the
stages after it act on the same one, as the original's locals did.

Why prefabs rather than components on each entity:
- **An entity changes state mid-step.** Adding and removing its
  components then would move it between odecs archetypes, which swaps
  rows and would leave other systems' views stale (D39). A prefab's
  components never move; only which prefab the entity's state names does.
- **They are not state.** Prefabs follow from the definitions and the
  session's plugins, neither of which changes in a session. Snapshots
  leave them out, like `defs`, and the golden fingerprints did not move.
- **The step's local.** G_EG_Process holds the state in a local that it
  refreshes only at some points. The step's mask is refreshed at the same
  points (`entity_step_state`), so a stage sees the state the original's
  code would have read.

Lookups: `step_component` and `step_has` answer for the entity as the
step sees it; `entity_component` and `entity_has` for the entity as it
is now, which is what code outside the step, such as a hit, reads.
Either looks at the entity's own components first, then its state's,
then its unit's.

### Render systems

`build_frame` is a loop over render systems (`render/render_systems.odin`),
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

### Presentation packages (D46)

Presentation is split the way the simulation is, so that plugins can
draw without the game:

| Package | What it holds |
|---|---|
| `render` | assets, the renderer and its render systems, text, the score bar, the effects (particles, blurs, beams, notices), sounds, the screen's size |
| `ui` | the menus' widgets, and the overlay registry |
| `plugins/*/view` | each plugin's presentation: its settings, render systems, overlays and effects |
| `game` | the flow between screens, the menus, preferences, netplay, `main` |

Each imports only those above it in the table. A plugin's view registers
what it draws from its `@(init)`, through three registries:
- **render systems** (`render.render_system_register`): Accent Color's
  Self Outline;
- **overlays** (`ui.overlay_register`), drawn over the play field after
  the frame: Easy Mode's reward screen and the loadout;
- **effect systems** (`render.effect_system_register`), stepped with the
  particles after each sim step: the passives' motes and sparks.

Each runs only while its plugin is on. The game names no plugin's screen:
`game/plugins.odin` imports each plugin and its view, which is all it
takes to put one in the build. The screens' only use of the game had been
the players' names from the lobby, which the game now hands to every
overlay (`ui.Player_Names`).

The Mods page used to list mods in registration order, which is the order
packages initialise in, so moving packages reordered it. It now lists
each mod under the mod it needs most deeply, siblings by label
(`mods_order`).

Draw lists matched the previous build for all four demo films, and every
menu shot was pixel-identical, apart from the Mods page and the version
string.

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

- `mise run ci`: 165 tests. The new ones are the prefab builds (their
  components follow the definitions' flags, and a plugin's builder runs
  only with the plugin on), and the golden runs, plugin
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

- **The renderer still knows about accents.** `Renderer.accents` and
  the accent shader are the renderer's own, and `game` sets them from
  Accent Color's settings. Moving them into the plugin's view would need
  a hook in `draw_object` for recolouring.
- **Game-side screens still ask for mods by ID** where the original's
  menus gained a switch: the Easy Mode toggle on Level Select and in the
  lobby, and the netplay button on the title screen.
- **Entity stages still run entity by entity.** A stage is matched
  against each entity in group order, and the entity goes through every
  stage before the next starts. Running one stage over all its entities
  first would visit them in a different order relative to the others'
  draws, and the random draws depend on it (D39). Stages that neither
  draw nor read what another entity's stages write could run system by
  system, but none has been proved so yet.
- **Some flags are still read directly.** The spawn sets are walked from
  the definitions, and lifecycle procedures such as change_state read
  their state's flags. Each can move to components the same way.
- **Behavioural coverage is not measured.** The golden runs cover four
  demos and three sessions with the additions on. There is no coverage
  tool to say which paths they miss.
- **A session with the passives but not Easy Mode** has no way to earn a
  passive. It runs, and is the same as neither.
- **The new Start is untested between two builds** and on two machines,
  as is all of Phase 6 stage 6. `tools/netplay/loopback_check.sh` was not
  run.
