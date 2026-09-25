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
| 4 — Deterministic simulation | **complete** — all four shipped demos replay call for call (42,446 / 81,184 / 112,286 / 95,085 random calls) | [phase-4-sim.md](phase-4-sim.md) |
| 5 — Presentation | **complete** — playable title screen to end of last level, `oracle:diff` still exact | [phase-5-presentation.md](phase-5-presentation.md) |
| 6 — Netplay | in progress — stages 1-5 done (snapshot ring, UDP transport, rollback, desync detection, lobby + live synced session); stage 6 (two-machine playtest) still needs a second physical machine | [phase-6-netplay.md](phase-6-netplay.md) |
| 7 — Faithful menus | **complete** — all six stages done (Main Menu, Level Select, Credits, High Scores, minimal Pause, `-classic`/netplay-lobby gating) | [phase-7-faithful-menus.md](phase-7-faithful-menus.md) |
| 8 — Netcode enhancements | **complete** — all five stages done (diagnostics overlay, netplay level select, pause-on-disconnect, reconnect, synchronised pausing); stage 5's throttle constants are provisional pending a real-latency playtest (D26) | [phase-8-netcode-enhancements.md](phase-8-netcode-enhancements.md) |
| Easy mode & passive upgrades | **complete** — reward screen after each level's tally, nine passives, netplay lobby toggle; `oracle:diff` still exact; several constants provisional pending a hand playtest | [passive-upgrades.md](passive-upgrades.md) |
| New Weapons | **complete** — loadout screen at the start of every stage after the first, the Chaingun (stage 7) with its aimed charge, netplay lobby toggle; `oracle:diff` still exact; the Chaingun's numbers are provisional pending a hand playtest | [new-weapons.md](new-weapons.md) |
| Bonus — Developer tools | not started — dev/cheat console, level editor; deferred, no exit criterion set yet | — |

The overall plan lives in [../../notes/odin-rewrite-plan.md](../../notes/odin-rewrite-plan.md).
Working methodology is in [../../AGENTS.md](../../AGENTS.md).

Cross-cutting decisions are logged in [decisions.md](decisions.md).
