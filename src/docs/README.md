# Rewrite documentation

Progress notes for the Odin reimplementation. One file per phase, written as
the phase completes, recording what was built, what the original turned out to
do, and which decisions are still open.

| Phase | Status | Notes |
|---|---|---|
| 0 — Scaffold | **complete** | [phase-0-scaffold.md](phase-0-scaffold.md) |
| 1 — Asset pipeline | **complete** | [phase-1-assets.md](phase-1-assets.md) |
| 2 — Decomp corpus | **complete** | [phase-2-decomp.md](phase-2-decomp.md) |
| 3 — Definition & data layer | **complete** | [phase-3-data.md](phase-3-data.md) |
| 4 — Deterministic simulation | **complete** — all four shipped demos replay call for call (42,446 / 81,184 / 112,286 / 95,085 random calls), and so do the players' 19 films of every level (`mise run oracle:diff:saved`, 2.5 million calls in all) | [phase-4-sim.md](phase-4-sim.md) |
| 5 — Presentation | **complete** — playable title screen to end of last level, `oracle:diff` still exact | [phase-5-presentation.md](phase-5-presentation.md) |
| 6 — Netplay | in progress — stages 1-5 done (snapshot ring, UDP transport, rollback, desync detection, lobby + live synced session); stage 6 (two-machine playtest) still needs a second physical machine | [phase-6-netplay.md](phase-6-netplay.md) |
| 7 — Faithful menus | **complete** — all six stages done (Main Menu, Level Select, Credits, High Scores, minimal Pause, `-classic`/netplay-lobby gating) | [phase-7-faithful-menus.md](phase-7-faithful-menus.md) |
| 8 — Netcode enhancements | **complete** — all five stages done (diagnostics overlay, netplay level select, pause-on-disconnect, reconnect, synchronised pausing); stage 5's throttle constants are provisional pending a real-latency playtest (D26) | [phase-8-netcode-enhancements.md](phase-8-netcode-enhancements.md) |
| Easy mode & passive upgrades | **complete** — reward screen after each level's tally, nine passives, netplay lobby toggle; `oracle:diff` still exact; several constants provisional pending a hand playtest | [passive-upgrades.md](passive-upgrades.md) |
| New Weapons | **complete** — loadout screen at the start of every stage after the first, the Chaingun (stage 7) with its aimed charge, the Discharge Beam (stage 10), an instant laser that carries leftover damage through kills, netplay lobby toggle; `oracle:diff` still exact; both weapons' numbers are provisional pending a hand playtest (the beam's are balanced against the DPS report) | [new-weapons.md](new-weapons.md) |
| DPS report | **complete** — `mise run dps:report`: every weapon's DPS in the sim alone, single target, cluster, target behind and a killable wave, as primary fire and as charge shots, with each passive at each level, as a dated HTML report; first run's numbers recorded | [dps-report.md](dps-report.md) |
| 9 — ECS refactor & mods | **complete** — the sim's state in a fixed odecs world built through its public API and stepped by registered systems, behaviour in packages of systems gated by queries on merged unit-and-state prefabs, render systems in their own loop, presentation in `render` and `ui` packages below the game with each plugin drawing its own screens from its view package, Deimos Rose's additions split into eight plugins toggled from a Mods page, an Extras page of plugin-registered settings; `oracle:diff` and the golden fingerprints unchanged throughout | [phase-9-ecs.md](phase-9-ecs.md) |
| Level editor & remastered levels | in progress — stages 1-8 of 10 done: plugins own their content, data plugins found at startup, campaigns with the originals as the Classic Levels plugin, optional level fields and launch flags, the terrain renderer, all 12 originals recovered as level projects (shadow IoU 0.84-0.98), and the first usable editor, `deimos-editor`, shipped in the zip: sculpt, light, water and wind, with undo; stage 8: placing units (place, move, turn and delete them from a palette of every placeable unit), painting materials (colours, dropped images and a library quilted from the originals' ground, hex-tiled so they do not repeat), the level's properties, structures' baked bases measured from the maps and drawn under their units, the obstacle and vent helpers, and scenery models (trees, grass and rocks as 3D models whose shadows are in the map, scattered by brush profiles, from a CC0 library of 27 that ships in the zip, with more importable) | [level-editor.md](level-editor.md) |
| Bonus — Developer tools | not started — dev/cheat console; deferred, no exit criterion set yet | — |

The overall plan lives in [../../notes/odin-rewrite-plan.md](../../notes/odin-rewrite-plan.md).
Working methodology is in [../../AGENTS.md](../../AGENTS.md).

Cross-cutting decisions are logged in [decisions.md](decisions.md).
