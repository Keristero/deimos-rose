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

**Stage 2 is done.** `net/` (package `netplay` -- `core:net` already declares
`package net`, and two packages in one program can't share a name, so callers
alias the import: `import net "dr:net"`) has the wire format and the socket
wrapper. `net/packet.odin` encodes every `Packet_Kind` (Hello, Ready, Goodbye,
Ping, Pong, Input) by hand into fixed little-endian bytes rather than
transmuting a struct, so the layout doesn't depend on either end's compiler;
an Input packet carries up to `MAX_INPUT_FRAMES` (32) consecutive frames of
one player's `sim.Buttons`, the redundancy that lets the gameplay channel
tolerate lost packets without a generic ack/retransmit layer underneath it.
`net/socket.odin` wraps `core:net`'s UDP socket as non-blocking, with
`local_endpoint` (`core:net.bound_endpoint`, confirmed implemented on Linux,
Windows, FreeBSD and the generic POSIX/other backends) for reading back which
port the OS handed an ephemeral (`port = 0`) bind — what a joining client
uses, a host binds its well-known port instead. `tests/net_test.odin` proves
the packet encode/decode round-trips (including that Ping and Pong, which
share a layout, never cross-decode into each other, and that a truncated
buffer is rejected rather than read out of bounds) and, in
`socket_sends_and_receives_on_loopback`, opens two real UDP sockets on
loopback and exchanges an actual Input packet between them -- the first test
in the project that touches a socket at all.

`net/reliable.odin` adds the small reliable channel: `Reliable_Channel` is
stop-and-wait, one message in flight at a time (all a two-player handshake
ever needs) -- `send_hello`/`send_ready`/`send_goodbye` queue a seq-numbered
packet and send it immediately, `reliable_tick` resends it once
`RELIABLE_RETRY` (200ms) passes with no ack and reports the channel dead
after `RELIABLE_MAX_RETRIES` (20, ~4s) with none, `reliable_accept` on the
receiving side always acks and tells the caller whether a seq is new or a
repeat so a resent Hello isn't handled twice, and `reliable_handle_ack`
clears the pending send. Odin has no closures, which is why `send_hello` /
`send_ready` / `send_goodbye` each repeat their own small bookkeeping around
`encode_hello`/`encode_ready`/`encode_goodbye` rather than sharing it through
a callback. Hello/Ready/Goodbye's wire format grew a seq byte to carry this
(D20 predates this addition; nothing external depends on the old layout yet).
`tests/net_test.odin` proves the full Hello→accept→Ack→cleared-pending loop
over real loopback sockets, that a repeated seq is rejected as not-new, that
a tick past the retry interval actually resends (backdating `sent_at` with
`time.time_add` rather than sleeping, to keep the test fast), and that
`RELIABLE_MAX_RETRIES` exceeded reports the channel dead. Stage 2 is now
complete as scoped. `mise run ci` is green (79 tests).

Stages 3-6 (prediction/rollback wiring onto real network input, desync
detection, lobby, two-machine playtest) are unstarted.
