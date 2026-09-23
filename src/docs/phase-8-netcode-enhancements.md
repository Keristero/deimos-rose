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

**Stage 2 is done.** The host's `.Connected` view (`game/netplay.odin`) grew
a level row above the Ready button: `<`/`>` `Text_Button`s (a new
`text_button_at_x`, `game/menu.odin`, centring on an arbitrary x instead of
always the screen's midpoint, for the two side-by-side arrows) cycle
`Netplay.level_index` through `Flow.defs.levels`, wrapping circularly like
Level Select's own carousel. `LEVEL: <name>` turns into red `LEVEL: NO
ACCESS` and the Ready button greys out (`text_button_draw`'s existing
`enabled` param) once `level_index >= Flow.highest_reached` — the same
unlocked check Level Select itself uses (`ls.center < fl.highest_reached`,
`game/menu_level_select.odin`), so a level unlocked in single-player is
unlocked here too. Readying locks the choice in: the arrows stop responding
to clicks once `local_ready` is set, matching the notes' "readying locks in
any options that have been made". The guest never gets arrows — it only
ever mirrors `level_index` from an inbound `Level_Choice` packet
(`net/packet.odin`: kind 10, unreliable, one byte, resent every lobby frame
the same way Input packets are redundant against loss rather than acked)
and shows a read-only `HOST HAS CHOSEN: <name>` line instead. Readying is
never guest-gated by the guest's own progress on the host's chosen level —
see D24 for why.

`Start`'s level field (already present on the wire since Phase 6 stage 5,
always sent as 0 until now) carries the host's real `level_index`, so
`netplay_begin_session` needed no change at all — it already took whatever
level index `Start` decoded to.

Verified by `mise run ci` (86 tests — `tests/net_test.odin` grew
`packet_level_choice_round_trips`) and `mise run netplay:loopback` (still
passes; `tools/netplay/loopback_check.sh`'s hardcoded Ready-button click
coordinates moved with the button, see its own updated comment), plus by
eye: `run_menu_shot` grew `"netplay_lobby_connected_host"` (arrows, level
name, enabled Ready) and `"netplay_lobby_connected_host_locked"`
(`highest_reached` forced below `level_index` — red NO ACCESS, greyed
Ready) alongside the existing guest-side `"netplay_lobby_connected"`
(now showing `HOST HAS CHOSEN: ...`), all three viewed directly via
`mise run netplay:lobby-shots`: no overlap between the new level row and
either the ping line above or the Ready button below, in any of the three
states.
