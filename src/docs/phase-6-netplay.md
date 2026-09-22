# Phase 6 — Netplay

Two players over a network, each simulating locally and rolling back when a
remote input arrives later than predicted. There is no original behaviour to
match here — the original game is single-machine only — so this phase is new
engineering on top of what Phase 4 and 5 already guarantee: a deterministic,
POD `sim.State` that steps identically given the same session and inputs.

## Design

Local two-player co-op already exists in `sim/` (`Game_Type.Co_Op` activates
`players[1]`, `Frame_Input :: [MAX_PLAYERS]Buttons` carries both players'
buttons every step) but `game/`'s `gather_input` only ever fills player 1's
slot (`sim.Frame_Input{b, {}}`, `game/main.odin`) — nothing currently supplies
player 2's input at all, local or remote. Netplay's job is to fill that second
slot from the network instead of from a second local device, while keeping
`sim.step` itself exactly as it is: it already takes a `Frame_Input` for both
players every call and has no notion of "local" or "remote".

Rollback, not lockstep: rather than stall until both players' input for a
frame is confirmed (lockstep) or send every frame at a fixed low rate (which
adds input lag equal to the round trip), each side predicts the remote
player's next input (repeat-last is the standard first cut), steps ahead
immediately on the predicted input, and corrects by rolling back to the last
confirmed frame and resimulating forward once the real input arrives and
turns out to differ. This is the same approach GGPO popularised and is why
Stage 1 built the snapshot ring before anything else: prediction is worthless
without a cheap way to rewind.

Transport is hand-rolled UDP on `core:net`, not `vendor:ENet` — see D20.
Rollback netcode's own input stream is naturally loss-tolerant (each packet
can carry several recent frames of input, so one dropped packet is invisible
as long as a later one arrives before the rollback window closes), which is
why a full generic reliable-UDP layer isn't needed for gameplay input itself.
Handshake and lobby control messages (connect, ready, disconnect) are
low-frequency enough that a small stop-and-wait reliable channel on top of the
same socket is sufficient for those, rather than building a second transport.

Where this lives: the snapshot ring is in `sim/` (`sim/rollback.odin`) since
it is pure data movement, no I/O. Everything that touches a socket — the UDP
transport, input-prediction bookkeeping, the lobby — belongs in the
previously-empty `src/net/` package, keeping the same `sim/` vs. everything
else boundary Phase 4 and 5 already established (D3, D4). `game/` remains
the only place a `Frame_Input` is either read from a device or handed to
`sim.step`; `net/` supplies the remote half of it.

## Stages

1. **Snapshot ring** — fixed-depth `sim.State` ring buffer keyed by frame
   number, save/restore, proven by rolling back and resimulating a session
   against an uninterrupted reference run.
2. **UDP transport** — `net/` package on `core:net`: socket setup, a framed
   packet format, the loss-tolerant redundant input channel, the small
   reliable channel for control messages. Builds and is exercised
   loopback-to-loopback on this machine first (no second machine needed yet).
3. **Input prediction + rollback integration** — buffer local and remote
   input per frame, predict missing remote input, detect misprediction when
   the real input arrives, trigger rollback-and-resimulate from the ring.
4. **Desync detection** — periodic `sim.checksum()` exchange between peers;
   surfaced somewhere visible rather than silently ignored.
5. **Lobby** — host/join by address, ready-up, ping display. Almost certainly
   another `Flow_Mode`-shaped state layered in front of the existing
   `game/flow.odin` states rather than a separate system.
6. **Two-machine playtest** — the phase's actual exit criterion, run for
   real rather than simulated loopback.

## Exit

Two machines play a full level with induced latency and no desync.

## Progress

**Stage 1 is done** (commit 6258e44). `sim/rollback.odin` adds
`Snapshot_Ring`: a `[]State` indexed by `frame % depth`, so restore is a
direct slot lookup with no scan — the cost is that only the last `depth`
frames are reachable, which is exactly the rollback window a caller needs
anyway. A parallel `written []bool` avoids a zero-value collision where an
untouched slot's `State{}` (`frame == 0`) would otherwise misread as a valid
snapshot of frame 0. `tests/rollback_test.odin` steps a synthetic session 30
frames while snapshotting every step, restores frame 20, resimulates with the
same recorded inputs, and checks every resulting `checksum()` against an
uninterrupted reference run all the way past where the first pass had
reached — plus the two failure paths (an aged-out frame, an untouched ring).
`mise run ci` is green (70 tests).
