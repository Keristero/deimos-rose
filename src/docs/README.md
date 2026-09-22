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
| 6 — Netplay | in progress — snapshot ring done | [phase-6-netplay.md](phase-6-netplay.md) |

The overall plan lives in [../../notes/odin-rewrite-plan.md](../../notes/odin-rewrite-plan.md).
Working methodology is in [../../AGENTS.md](../../AGENTS.md).

Cross-cutting decisions are logged in [decisions.md](decisions.md).
