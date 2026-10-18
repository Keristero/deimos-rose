# Deimos Rose

A rebuild of **Deimos Rising**, Ambrosia Software's 2003 vertical shooter,
written from the ground up in Odin from a study of the original Windows
build (1.0.2). It plays the original exactly, and adds everything new as
plugins you can take or leave.

**Website: [keristero.github.io/deimos-rose](https://keristero.github.io/deimos-rose/)**: downloads, every plugin with a screenshot, and what changed in each release.

![The main menu](src/docs/images/main-menu.png)

## Play

Download the game for Windows or Linux from
[the website](https://keristero.github.io/deimos-rose/) or
[the releases](https://github.com/Keristero/deimos-rose/releases). Unzip it
and run `deimos` (Linux) or `deimos.exe` (Windows) from inside the `deimos`
folder.

The game zip is the original, on its own: all twelve sectors, played from
the title screen to the end. Each plugin is a download of its own. Unzip it
over the same `deimos` folder, then turn it on from the **Mods** page in
Preferences. A plugin's zip carries any other plugins it needs.

**Classic mode** switches every enhancement off, so the game looks and
plays as the 2003 build did.

**Netplay** (the Netplay plugin) uses UDP port 60902.

## What's in it

### The original, exactly

The core of the game is the original and nothing more. Its simulation is
checked against the original binary: all four demo films that shipped with
the game, and 19 films recorded by players across every level, replay
random call for random call, 2.5 million calls in all
([phase 4](src/docs/phase-4-sim.md)). Sprites, colours, frames, text and
timing come from the original's own data files.

### Plugins

Everything Deimos Rose adds is a plugin.
[The website's plugin page](https://keristero.github.io/deimos-rose/plugins.html)
shows each one.

| | Plugin | What it does |
|---|---|---|
| **Content** | Classic Levels | The original twelve sectors. Comes with the game. |
| | Recovered Levels | The same sectors on maps redrawn from their recovered 3D terrain |
| **Presentation** | Extra Preferences | A page of settings for the other plugins |
| | 30FPS Unlock | Smoother motion at your display's refresh rate |
| | Accent Color | Each player's own colour on their ship and shots |
| | Realtime Lighting | Shots and explosions light what is round them, and glow |
| | Moving Water | Waves, a sky and its clouds, and the sun's glint on the water |
| | Wind | The level's wind blows sparks and smoke |
| | HD Textures | Sprites and menu pictures redrawn at twice their size (built from source only, for now) |
| **Multiplayer** | Netplay | Two players over the network, with rollback, desync detection and reconnection |
| **Gameplay** | Passive Upgrades | Upgrades to the ship and its weapons, a level at a time |
| | Easy Mode | A passive upgrade to choose after every level |
| | Loadout | Three air weapons at hand, chosen at the start of each stage |
| | New Weapons | New air weapons to unlock, stage by stage |
| | Chaingun | An air weapon from stage 7 whose charge fires aimed volleys |
| | New Weapon Upgrades | Passive upgrades for the new weapons |

### Level editor

`deimos-editor`, a download of its own, edits levels as 3D terrain:
sculpt, paint, light, place units and scenery, and add water and wind. A
set of levels made in it exports as a plugin the game plays. Recovered
Levels was made this way.

## Status

The game is playable from start to finish. Work still open:

- **Netplay** has been tested mostly on one machine, over loopback. A
  playtest between two machines is still to do, and the constants that
  pace a peer that runs ahead are provisional.
- **The level editor** is at stage 9 of 10
  ([level-editor.md](src/docs/level-editor.md)).
- **HD Textures** is not in the downloads yet. Build it locally with
  `mise run hd:textures`.
- **Known issue:** after a reconnect in netplay, a player may see the wrong
  level's background.
- **Planned:** an endless roguelike mode, with procedural levels, new guns
  and new biomes.

[src/docs/README.md](src/docs/README.md) has every phase's status.

## How it's built

- **Odin and raylib.** The game, the editor and the tools are all Odin.
- **A pure, deterministic simulation.** `src/sim/` takes inputs and a seed
  and produces the next state. It touches no files, clock, network or
  global random number generator, and a check enforces this. That purity
  is what lets demo films replay exactly, tests run fast, and netplay roll
  back.
- **An entity component system.** The simulation's state is an
  [odecs](https://github.com/NateTheGreatt/odecs)
  world. Behaviour comes from systems registered in a fixed order, so every
  build and every peer steps the same way
  ([phase 9](src/docs/phase-9-ecs.md)).
- **Plugins are libraries.** The game loads each plugin's library at
  startup. A plugin reaches the game only through extension points: a
  system, a hook, a screen, a setting, a render pass. The core names no
  plugin, and the game and its tests run with none installed
  ([phase 10](src/docs/phase-10-plugin-split.md)).
- **Rollback netplay** over its own UDP transport: snapshots of the whole
  state, rollback and resimulation, and checksums to detect a desync
  ([phase 6](src/docs/phase-6-netplay.md),
  [phase 8](src/docs/phase-8-netcode-enhancements.md)).

### The repository

| Folder | What it holds |
|---|---|
| `src/` | The game: the core, `plugins/`, the editor, the tools, the tests, the website |
| `src/docs/` | One write-up per phase, and [decisions.md](src/docs/decisions.md), the log of design choices |
| `notes/`, `symbols/`, `tools/` | The study of the original build: 1,942 named functions, file formats, the plan |
| `orig/`, `game/` | The original release and its unpacked game. Not committed: bring your own copy |

[AGENTS.md](AGENTS.md) is how the project is worked on: verifying before
building, branches and pull requests, and the rules the code keeps.

### Building from source

Install [mise](https://mise.jdx.dev) and Odin (`brew install odin`; CI
uses Odin dev-2026-09). Then, from `src/`:

```sh
mise run run      # build and run the game
mise run editor   # build and run the level editor
mise run test     # the test suite
mise run ci       # everything CI checks
```

The game's converted data is committed in `src/assets/`, so building needs
no copy of the original. With the original installer in `orig/`,
`mise run assets:all` regenerates it.

## Related work

[adamjvr/Deimos-Rising-Remastered](https://github.com/adamjvr/Deimos-Rising-Remastered)

## Legal

Deimos Rising is © 2001–2003 Swoop Software and Ambrosia Software, Inc.
The game is currently classified as abandonware.
