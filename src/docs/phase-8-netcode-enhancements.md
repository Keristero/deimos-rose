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

**Stages 3 and 4 are done**, built together (`game/netplay.odin`,
`net/packet.odin`, `net/reliable.odin`) since pause-on-disconnect and
reconnect are two faces of the same failure. A new `Link_State` enum
(`Live -> Waiting_Reconnect -> Resync_Sending`(survivor) /
`Resync_Receiving`(rejoiner) `-> Live`) drives both whether
`netplay_playing_step` advances the sim (only `.Live` does — this *is* the
freeze) and what banner `flow_draw` shows.

Losing a peer is detected by silence rather than only by a clean `Goodbye`:
`Netplay.last_peer_seen` is stamped on every accepted packet while `.Live`,
and `netplay_playing_poll` moves to `.Waiting_Reconnect` once
`NETPLAY_LIVE_TIMEOUT` (3s) passes without one — this is what catches a
SIGKILLed or network-dropped peer, not just one that says goodbye. On
entering `.Waiting_Reconnect` the survivor closes and rebinds its socket to
the well-known `NETPLAY_PORT`, so a reconnecting client always aims at the
same address regardless of whether the survivor was originally Host or
Guest (D25). `flow_handle_input` grew an F5 "continue alone" branch, active
only while `link_state != .Live`: it needed zero new sim-side code, since
the existing non-netplay path of `flow_step` already only ever fills player
0's input and leaves player 1's at `{}` every tick — flipping
`netplay_active` off is the entire fix, and the vacated player just sits
idle from then on, same as ordinary single-player.

A reconnecting client is just an ordinary `Join Game` — the survivor's
`Hello` handler recognises it's in `.Waiting_Reconnect`, replies, and (once
the handshake is new) starts sending its live `sim.State` via a `Resync_Start`
packet (carrying the rejoining client's assigned player slot — no wire
sentinel needed, `Hello`'s own player field was already unused, D25)
followed by `State_Chunk` packets. The state is transferred as raw bytes in
1 KiB chunks, sent in bursts of up to `STATE_CHUNK_BURST` unacked chunks per
frame rather than one-at-a-time stop-and-wait (D25 has the throughput story:
stop-and-wait measured at 25-30s for the ~655-chunk/670KB transfer, the burst
scheme brings it to well under a second on loopback). The receiver applies
chunks into a `[]bool` bitmap as they arrive (order not guaranteed, since the
sender bursts several per frame) and finishes once every chunk is accounted
for; a raw copy back into `fl.state` needs the same pointer fixup as any
cross-process state transfer: `defs` re-pointed at this process's own (never
sent), `level` re-resolved via `sim.level_by_id(defs, state.session.level_id)`
(the same lookup `sim.init` itself uses), `events` force-nilled. Because
`net/session.odin` operates purely on `state.frame`, resuming
`rollback_session_init` at whatever frame the freeze happened on needed no
special-casing at all.

`netplay_disconnect_banner` (`game/netplay.odin`) supplies the frozen-session
banner text — `"DISCONNECTED, WAITING FOR CONNECTIONS -- ESC TO EXIT, F5 TO
CONTINUE ALONE"` while waiting, a live send-progress percentage while
transferring — drawn by `flow_draw`'s new `.Playing` case. The mirror-image
receive-progress percentage is drawn by `netplay_lobby_draw`, since the
rejoining client sees this from inside `Netplay_Lobby` (`fl.mode` doesn't
flip to `.Playing` until the transfer finishes).

Verified by `mise run ci` (89 tests, green — `tests/net_test.odin` grew
`packet_resync_start_round_trips`, `packet_state_chunk_round_trips_a_full_and_partial_chunk`,
`packet_state_chunk_ack_round_trips`), `mise run netplay:loopback` (still
green — stages 1/2/normal handshake unaffected), and the new
`mise run netplay:reconnect` (`tools/netplay/reconnect_check.sh`): a
three-real-process loopback test that starts a normal two-instance session,
SIGKILLs the guest mid-session (not a clean `Goodbye` — this specifically
exercises the silence-timeout path), confirms the survivor logs "peer lost,
waiting for a reconnect", launches a third instance that joins exactly like
any ordinary guest, and confirms both sides log the resync completing with
no desync-monitor warning afterward. Passes in ~18s wall-clock total, almost
all of it Xvfb/build/handshake overhead and the test's own scripted
`sleep`s — the resync transfer itself is no longer the bottleneck.

**Stage 5 is done**, as a first cut marked provisional (D26) — the notes'
own wording for this stage is looser than every other item ("hard to measure
who is behind", no algorithm specified), so this trades GGPO's fuller
time-sync scheme for something simple built on a signal the rollback session
already had for free. `net/session.odin` grew
`Rollback_Session.remote_confirmed_frame` (the highest remote input frame
ever *confirmed*, not merely predicted, tracked incrementally inside
`rollback_session_receive`) and two new procs:
`rollback_session_frame_advantage` (this machine's frame count minus the
peer's last confirmed one — GGPO's own "frame advantage": the peer can't
have generated input for a frame it hasn't simulated, so this is a direct
proxy for how far behind it actually is) and
`rollback_session_should_stall(rs, threshold, min_every)`, which turns that
number into a go/no-go for the current tick: below `threshold`, never
stalls; above it, stalls on a period that shrinks as the lead grows, floored
at `min_every` so a very large lead throttles rather than fully freezes
local input. `game/netplay.odin`'s `netplay_playing_step` calls it
(`NETPLAY_SYNC_STALL_THRESHOLD :: 5`, `NETPLAY_SYNC_MIN_STALL_EVERY :: 2`)
and returns immediately on a stall tick — no sim advance, no input/checksum
send — which lets `game/main.odin`'s existing fixed-step accumulator do the
actual "increase the duration of its updates" the notes ask for, with no
second timing mechanism needed.

Both new procs live in `net/session.odin` rather than `game/netplay.odin`
specifically so the throttle math is unit-testable without a live socket or
render loop — `netplay_should_stall` (`game/netplay.odin`) is a two-line
wrapper supplying the constants. Deliberately *not* independently verified
over real network latency: loopback's near-zero round trip means frame
advantage rarely exceeds a couple of frames in practice, so the stall path
is essentially inert in `mise run netplay:loopback` and
`netplay:reconnect` (both still green — this stage changes nothing about
the handshake, resync or disconnect paths those exercise) and can only be
demonstrated by driving a `Rollback_Session` directly.

Verified by `mise run ci` (91 tests — `tests/rollback_session_test.odin`
grew `rollback_session_frame_advantage_tracks_the_confirmed_remote_frame`
and `rollback_session_should_stall_throttles_only_once_over_threshold`,
both driving a session through exact frame counts and confirming the
advantage and stall-period math frame-by-frame rather than only checking an
end state) and `mise run netplay:loopback` / `netplay:reconnect` (both
still green, confirming this stage didn't regress anything stages 1-4
already covered). The threshold and floor constants are explicitly untuned
against real latency — see D26 for what would resolve that.

## Exit, revisited

All five stages of `notes/netcode-enhancements.md` are implemented and
`mise run ci` is green. Stage 5's constants remain provisional pending a
real (non-loopback) playtest — see D26.
