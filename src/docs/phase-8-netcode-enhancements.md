# Phase 8 — Netcode enhancements

Five follow-ups to Phase 6's netplay, requested directly by the project owner
in [`notes/netcode-enhancements.md`](../../notes/netcode-enhancements.md)
rather than drawn from the original plan — there is no original behaviour to
match for any of them, same as Phase 6 itself. Kept as its own phase rather
than folded into `phase-6-netplay.md` (whose own stage 6, the two-machine
playtest, is unrelated and still open) or `phase-7-faithful-menus.md` (already
closed out complete), matching the precedent of `docs/README.md`'s "Bonus"
row for work that wasn't in the original numbered plan.

## Stages

1. **Diagnostics overlay** — `-diagnostics` launch flag shows a rolling
   FPS/ping/rollback-rate readout in the bottom-right corner.
2. **Netplay level select** — the host picks a starting level from their
   unlocked list before readying up; locked levels are greyed out and block
   the host's own ready.
3. **Pause on disconnect** — losing the peer mid-session freezes the local
   sim automatically rather than desyncing or crashing forward; both
   survivors become reconnect-acceptors.
4. **Reconnect** — a reconnecting client receives the current `sim.State`
   from a survivor and resumes rather than restarting.
5. **Synchronised pausing / slow update loop while ahead** — a client running
   further ahead of the peer's last-known frame than a threshold stalls its
   own update rate slightly to let the peer close the gap, rather than
   letting the rollback window (and prediction error) grow unbounded.

Ordered by dependency, not by the notes' own order: level select only touches
the lobby (already-solid ground from Phase 6 stage 5 / Phase 7 stage 6);
pause-on-disconnect and reconnect are two faces of the same failure and are
built together; time-sync is last because it's the least specified of the
five ("hard to measure who is behind", the notes admit) and benefits most
from everything else already being solid under it.

## Exit

All five items in `notes/netcode-enhancements.md` implemented, `mise run ci`
green, `tools/netplay/loopback_check.sh` still passing.

## Progress

**Stage 1 is done.** `game/diagnostics.odin` adds `Diagnostics`: a 1-second
tumbling window (count events, divide by elapsed time, reset — not a true
continuously-sliding average, simple enough for a debug readout and
documented as such in the file header) tracking updates/sec and
rollbacks/sec, plus the always-available FPS and (in a netplay session) ping.
`diagnostics_note_update` is called once per real simulation tick from
`game/main.odin`'s fixed-step loop — specifically only while `flow.mode ==
.Playing` was true *before* the step, and only once per tick regardless of
how many frames a misprediction resimulates inside
`net/session.odin`'s `rollback_to` — which is what makes "excluding
rollbacks" true without any extra bookkeeping in `net/`.
`diagnostics_tick` rolls the window over once per render frame (so the
numbers keep decaying toward zero even at the title screen or mid-lobby, not
just while playing) and reads `rollback_count` off
`flow.netplay.rs` when a netplay session is active. `-diagnostics`
(`game/settings.odin`, and `mise run run --diagnostics`) gates the whole
thing off by default.

"Highest ping client" (the notes' phrasing, aimed at a future >2-player
session) is currently just the one peer's `Netplay.ping_ms`, since a session
is still exactly two players — nothing to pick a maximum over yet.

Verified by `mise run ci` (85 tests, green) and by eye: `run_menu_shot` grew
a `"diagnostics"` case (`game/main.odin`) that renders the overlay over the
connected-lobby screen with hand-set sample numbers (there's no sim loop
ticking `Diagnostics` in a single static frame, same reasoning as the
Phase 7 stage 6 lobby shots) via `mise run netplay:lobby-shots` →
`work/shots/menus/diagnostics/ours.png`, viewed directly: all three lines
readable in the bottom-right corner, no clipping against the panel edge, no
overlap with the lobby UI above it.
