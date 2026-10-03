# Hitstop

`plugins/hitstop` (presentation only, off in classic mode, never in netplay).

- Every collision that hurts something is recorded by the core in `sim.Hit_Queue`
  (`sim/queue_hits.odin`, from `entity_hit` and `player_hit`). Like the other
  queues it is cleared each step and is not state or checksummed.
- The plugin's view turns each step's hits into a hold: `Renderer.hold` steps
  during which `flow_held` (game/flow.odin) skips the simulation step, so the
  simulation itself is untouched. The length is `round(sqrt(damage) / 2)` steps
  (at least 1, at most 10), scaled by the HITSTOP setting.
- A kill that deals more than 3x what the unit had left starts the kill cam:
  54 steps held, a post pass zooms the finished frame in on the unit (with
  letterbox bars) and draws TAKEDOWN in the game font.
- `mise run test` covers the numbers (`plugins/hitstop/tests`). For a look:
  `MENU=hitstop DR_HITSTOP_AT=0.5 mise run menu-shot` (the cam started by
  hand, 0 to 1 through it).
- Provisional: lengths, zoom and styling were picked by eye.
