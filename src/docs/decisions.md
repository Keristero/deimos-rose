# Decision log

Cross-cutting choices, with the reasoning, so they can be revisited on
evidence rather than re-argued from memory.

### D1 — Reimplement in Odin; do not decompile to match

The goal is a game that behaves like the original, not a byte-identical
rebuild. Decompiler output is reference material. This removes the need for
Metrowerks CodeWarrior and deletes ~1,474 of 1,942 functions from scope.

### D2 — raylib provides the engine layer

Rendering, audio, input, windowing. The original is a software blitter writing
16-bit pixels into a DIB, so there is no GPU behaviour to reproduce — a pixel
buffer uploaded as a texture is sufficient and faithful.

### D3 — `sim/` is pure; everything else is free

`sim/` imports no raylib, no I/O, no wall clock, no ambient RNG. Enforced by
`mise run purity` in CI. Film replay, rollback and fast tests all depend on it.

### D4 — Faithful in `sim/`, modern everywhere else

Gameplay-visible behaviour matches the original where films can prove it.
Rendering, audio, UI, netcode and tooling are written the way we would write
them today.

### D5 — Rollback over ENet rather than vendor:ggpo — *provisional*

`vendor/ggpo/ggpo.odin` contains a single unconditional
`foreign import lib "GGPO.lib"`, no `when ODIN_OS` branches and no Linux
library: it cannot link on Linux as shipped. The hard part of rollback is
deterministic state save/restore, which `sim/` must provide regardless and
which GGPO would not supply. Revisit at Phase 6; keep the binding as an
alternative backend behind the same interface.

### D6 — WAV over OGG for extracted audio

No Vorbis encoder is available in Odin's vendored libraries. Lossless and
universally readable beats a build dependency for 99 sound effects.

### D7 — Definition records pass through byte-exact in Phase 1

Decoding `unde`/`leve`/`wede`/`plde` requires format work that belongs with the
data layer. Phase 1 catalogues them in the manifest instead.

### D8 — Original game data is never committed

`assets/`, `build/` and `.deps/` are gitignored, as are `orig/` and `game/` in
the parent repository. Everything is regenerated from a local copy of the
installer.

### D9 — The decompilation corpus is reference material, never a source

Files under `work/decomp/export/` are read to understand behaviour. Nothing is
transliterated from them into `src/`. Every exported file carries that note in
its header.

### D10 — Ghidra and its corpus live outside the tracked tree

Ghidra goes in `~/.cache/deimos-rising/`; the project and corpus in a
gitignored `work/`. Not `src/build/`, because `mise run clean` would discard
minutes of analysis. Not a dotted path, because the headless analyser rejects
any path element beginning with `.`.

### D11 — Typed loaders only where the format is proven

Levels, films and all three definition families get typed structs because their
layouts are recovered. Fields that are merely present, not understood, stay
reachable by name: every scope keeps its tags verbatim alongside the typed
view, so an incomplete schema never loses data. The remaining tagged-text
families are exported as ordered key/value JSON.

### D12 — Guesses are marked in the code, not just the docs

`BIT_TO_BUTTON` and `Game_Type.Co_Op` carry PROVISIONAL comments naming what
would resolve them. Two Phase 0 guesses (`Single = 0`, `level_id: u16`) turned
out wrong; marking them in the source is what makes them cheap to fix.

### D13 — Parse by scope, not by position

Unit definitions are read by field name with `stateName_STR`,
`stateSpawnSetName_STR` and `stateRuleName_STR` opening scopes. A positional
reader derived from one record handles 359 of 386 and then fails on optional
fields. Declared counts are validated afterwards rather than trusted to drive
the walk.

### D14 — The simulation reproduces the original RNG exactly

MSL `rand()` and the two `U_Utils` helpers, including their early-outs and the
reversed-bounds quirk in `RandomFloat`. Replaces the Phase 0 xorshift
placeholder, which could never have replayed a film.

### D15 — Sound and particle RNG draws happen in `sim/`

The original's audio and particle code consume the gameplay RNG. `sim/` makes
those draws and emits events carrying the results; presentation executes them
and draws nothing itself.

### D16 — Accurate by default, but not accurate at the expense of looking worse

The screenshot-comparison harness (Phase 5) is ground truth for correctness,
not a mandate to reproduce every original limitation. Where matching the
original would reduce fidelity for no gameplay reason -- and subtle Wine
colour-grading differences from the original's own presentation, which stay
unaddressed until after Phase 6 -- the higher-fidelity choice wins by default.
A `-classic` flag (`game/settings.odin`) exists for anyone who wants the
closest possible match instead; it is lower priority than reaching ~95%
accuracy across the whole game, which comes first. Nothing has used the flag
to diverge yet -- Stage 3 onward is where a real fidelity choice will show up.

### D17 — The simulation steps on a fixed clock, independent of the render rate

`FPS_MaxRate`/`FPS_Delay` (perm floats 0x20/0x21) show the original targets
30 FPS and paces itself with a busy-wait in `G_GameInterface::Draw`, stepping
once per drawn frame. `game/main.odin` reproduces the 30 Hz step rate with a
fixed-timestep accumulator instead of one step per render call, so gameplay
speed no longer depends on how often the frame is presented: `SetTargetFPS(60)`
had been running the simulation at double speed. `-highrefreshrate` raises the
*presentation* rate to the monitor's native refresh; the accumulator still
gates `sim.step` to 30 Hz either way.

### D18 — Flow's screens are plain text, not a reconstruction of the original's menus

The original's title, pause and game-over/level-complete screens are built
from button graphics and (for level-select) preview thumbnails whose layout
was never traced (`assets/data/flli/gafl.json`'s `LevSel_*`/`Interface_Btn_*`
perm floats describe it, unbuilt). None of that is simulation-visible or
RNG-affecting, so `game/flow.odin` draws plain text with raylib's own font
instead (the same shortcut `draw_debug` already takes for its dev overlay) and
defers the level-select screen entirely — levels always play in list order
within a session regardless (see the Flow progress note in
phase-5-presentation.md), so nothing is lost by not building a picker for it
yet. Consistent with D16: accurate where it affects the simulation or a
screenshot comparison, not obligated to match everywhere else.

### D19 — Flow reacts to `game_over` directly, not only through `level_end.complete`

`FUN_00420280` sets `DAT_004e4826` (`s.game_over`) the instant the last player
leaves play, independent of whether the level has finished scrolling;
`level_end_step` only learns about it later, once the background reports
scroll-complete, and then just short-circuits straight to `complete` with no
tally to show. Waiting for `level_end.complete` alone to show a game-over
screen would mean it never appears if the level's scroll never finishes (e.g.
losing early, far from the level's end point). `game/flow.odin` checks
`state.game_over` every step and transitions immediately, `level_end.complete`
being for the normal "finished a level" path only.


### D20 — Hand-rolled UDP on `core:net`, not `vendor:ENet`

Supersedes D5's "provisional" choice of ENet. `vendor:ENet` links via
`foreign import ENet "system:enet"` on Linux, which needs a system-installed
`libenet.so` — confirmed entirely absent on this host (`ldconfig -p`,
`pkg-config`, `rpm -qa`, `find` all came up empty), unlike raylib's X11/GL
deps, which `tools/setupdeps/setup.sh` can always find already on the host and
just symlinks; ENet would be the project's first dependency on a package the
user has to `dnf install` themselves. Asked directly, the user chose a
hand-rolled UDP protocol on `core:net` instead: it must build on both Linux
and Windows (`core/net` has `socket_linux.odin`/`socket_windows.odin`/
`socket_posix.odin`, so this is a real cross-platform API, not Linux-only),
and should be written with a possible future WebSocket transport (for a
hypothetical WASM build) in mind, without building that abstraction now.

### D21 — Faithful menu recreation supersedes D18; scope and exclusions

Supersedes D18. The project owner asked for all of the original's menus to be
recreated faithfully (button graphics, layout, behaviour), except "activate",
with new (netplay) menu items added in the same style but hidden under
`-classic`. A research pass reading the relevant decompiled functions in full
(`G_Interface_025fd0.c` and its `FUN_004277e0`/`FUN_00427cb0`/`FUN_00427dc0`/
`FUN_00428240` helpers, `G_LevelSelect_GetStartingLevelIDFromUser_02a0c0.c`,
`Priv_Preview/*`, `G_Credits_Display_0120e0.c`, `G_Scores_Display_03b7c0.c`,
`FUN_0043bb00.c`, `G_Interface_PauseGame_026510.c`, `U_Registration/*`,
`G_Console/*`) settled the scope:

- **"Activate" confirmed** as the main menu's 7th button (only shown when
  `U_Registration::Is()` is false), which opens the `U_Registration`/RT3
  shareware-registration nag. Excluded, as asked.
- **`G_Interface_DisplayAd`** (a full-screen ad shown once at quit if
  unregistered) is a separate function from the registration nag but the same
  shareware category. Excluded too, by the project owner's call.
- **The dev/cheat console (`G_Console`) and the level editor** are real UI the
  original binary can show but are hidden developer tools, not normal player
  menus. Deferred to a new "Bonus — Developer tools" phase rather than
  in scope for faithful player-menu recreation (see `docs/README.md`).
- **Pause has no on-screen "PAUSED" text in the original at all** —
  `G_Interface_PauseGame` only stops sound, pauses music and darkens the
  borders (`U_Display::DrawBlackBorders`) while idling. The project owner
  chose to match this exactly: the faithful pause screen drops the "PAUSED"
  banner Flow currently draws.
- **A mission-briefing screen has full text/timing perm data defined
  (`Briefing_*`) but is never read by any code, and every shipped level sets
  `briefing: "none"`.** Cut content — not part of the recreation.
- **In scope**: Main Menu/Title, Level Select (carousel + previews + accept/
  reject animation), Credits, High Scores (view + name entry), Pause (minimal,
  as above). Preferences is a native Win32 dialog with no bespoke art to
  port — `-classic` gets a fresh, simply-styled settings screen instead of a
  pixel port of OS chrome.

Full inventory, function-by-function, in
[phase-7-faithful-menus.md](phase-7-faithful-menus.md).

### D22 — Netplay lobby: full live integration, always level 1, no local pause

Phase 7 stage 6 (the netplay lobby, folding in Phase 6's deferred stage 5) had
an open question this project couldn't resolve alone: a lobby needs more than
UI to actually be useful — starting a real game means wiring `net/` into
`game/`'s live loop, which raises a presentation-side-effect problem (sounds/
particles would replay on every rollback resimulation if wired naively).
Asked how far to take it, the project owner chose **full live integration**
over a UI-only/handshake-only cut: Ready-up genuinely starts a synced
two-player session over UDP, not a stub. The side-effect problem turned out
to already be solved by Phase 6 stage 3's `Rollback_Session` design (its
private `rollback_to` never calls a presentation function, only
`rollback_session_advance` does) — no new architecture, just correct
sequencing in the new glue code. See
[phase-7-faithful-menus.md](phase-7-faithful-menus.md#stage-6--done) for the
full design.

Two scope simplifications made in the same stage, recorded here since they
are cross-cutting rather than implementation detail:

- **Netplay always starts at level 1** (the host-picked `Start` packet's
  level field is always 0 for now). The wire format itself doesn't hard-code
  this — a level-select step for netplay is a natural, low-risk future
  addition, not a redesign. **Superseded by D24**: Phase 8 stage 2 added it.
- **No local-only pause during a netplay session**: Escape disconnects
  outright rather than pausing, since freezing only one machine's rendering
  can't stop input still arriving from the peer. The project owner's own
  pre-existing design notes (`notes/netcode-enhancements.md`, not part of
  this reimplementation) sketch a future pause-on-*disconnect* behaviour for
  the unplanned-drop case, which is a different feature from this and was not
  attempted here.

### D23 — Diagnostics overlay: tumbling window, not a sliding one

`notes/netcode-enhancements.md` asks for "rolling average" ping/rollback/
update stats. A true sliding window (a ring buffer of per-frame samples,
averaged over the trailing N seconds) updates smoothly every frame but costs
memory and bookkeeping proportional to the window length. A 1-second tumbling
window — count events, divide by elapsed time, reset, repeat — is one counter
and one timer, and for a debug overlay a reader glances at rather than reads
continuously, the visible cost (the numbers hold steady for a second, then
jump) is not worth paying a real ring buffer to avoid. `game/diagnostics.odin`
documents this in its header as the simplification it is, with the actual
sliding-window upgrade path named in case a real session ever makes the
stepping visibly distracting. See
[phase-8-netcode-enhancements.md](phase-8-netcode-enhancements.md).

### D24 — Netplay level select: host's own progress gates only the host

`notes/netcode-enhancements.md` specifies the host picks a level from its own
unlocked list and can't ready on a locked one, but says nothing about what a
*guest* whose own single-player progress hasn't reached that level should do.
Two options: block the guest's Ready too (needs a second Level_Choice-style
exchange, this time guest progress -> host, and a new failure mode to explain
to the host — "your guest can't play this level"), or leave the guest
ungated, trusting the host's own choice. Chosen: **leave the guest
ungated** — a guest playing a level ahead of its own local single-player
save, in a co-op session the host already vouches for, isn't an integrity
problem this port needs to solve (the original has no concept of a
per-account server-enforced unlock either; `progress` is just a local file).
Revisit if a real playtest finds it surprising. See
[phase-8-netcode-enhancements.md](phase-8-netcode-enhancements.md)'s stage 2.

### D25 — Reconnect: fixed-port rebind, no wire sentinel, burst chunk transfer

Three design questions came up implementing pause-on-disconnect + reconnect
(stages 3/4, `game/netplay.odin`):

**Where does a reconnecting client aim?** The survivor always rebinds to the
well-known `NETPLAY_PORT` (54217) on losing its peer, regardless of whether it
was originally Host or Guest. The alternative — the survivor keeping its
original ephemeral port and somehow publishing it — needs a side channel that
doesn't exist. Fixed-port rebind means a reconnecting client just uses the
ordinary "Join Game" flow with no foreknowledge beyond the survivor's address,
which is already what a player would have.

**How does the reconnecting client learn its assigned player slot?** No new
wire-protocol sentinel was needed: `Hello`'s player field was already unused
by the receiver (a pre-existing fact, confirmed by reading `net/packet.odin`
before adding anything). The real assignment instead travels in the new
`Resync_Start` packet's `assigned_player` field, computed by the survivor as
`1 - local_player`. Simpler than teaching `Hello` a second meaning for its
existing field.

**How is the frozen `sim.State` transferred?** Sent as raw bytes in
1 KiB (`STATE_CHUNK_SIZE`) chunks over new unreliable `State_Chunk` /
`State_Chunk_Ack` packets, since `sim.State` is much larger than one UDP
packet (~670 KB → ~655 chunks) and the reliable channel (`net/reliable.odin`)
is built for single small messages, not a bulk transfer. The first attempt
sent one chunk, waited for its specific ack, then sent the next — simple, but
measured at roughly one chunk per render frame (one network round trip per
frame), meaning a full transfer took 25-30 seconds even over loopback:
unacceptable for a feature whose whole point is a *brief* freeze. Replaced
with a burst/bitmap scheme: the sender resends every not-yet-acked chunk (up
to `STATE_CHUNK_BURST` per frame) rather than waiting on one ack before
sending the next; the receiver accepts chunks into a `[]bool` "got" bitmap
since bursting means they can arrive out of order; the per-chunk retry count
was replaced with a single "no progress at all for `STATE_RESYNC_TIMEOUT`"
give-up check, since individual unacked chunks are just retried as part of
the next burst rather than tracked separately. This brought the full transfer
down to well under a second on loopback (`tools/netplay/reconnect_check.sh`).
`sim/`'s frame-agnostic design (`net/session.odin` operates purely on
`state.frame`) meant nothing in `sim/` or `net/session.odin` needed to change
to resume at an arbitrary non-zero frame — only the transfer mechanism itself
was the hard part.

One bug worth recording since it slipped past the compiler: Odin's untyped
float constants coerce silently to a `time.Duration`'s unit, which is
nanoseconds. `NETPLAY_LIVE_TIMEOUT :: 3.0` compiled cleanly but meant "3
nanoseconds", not three seconds, causing both sides of a session to
spuriously self-trigger the disconnect path within microseconds of a normal
session start. `odin check` does catch this for some constants (a narrower
`STATE_CHUNK_RETRY :: 0.1` in this same stage was rejected as a truncation
error) but not this one, since `Duration(3)` is an exact value with nothing
to truncate. Fix: always declare a duration constant via explicit
multiplication against a `time` unit (`3 * time.Second`), never a bare
number, matching the pattern `net/reliable.odin`'s `RELIABLE_RETRY` already
used. See [phase-8-netcode-enhancements.md](phase-8-netcode-enhancements.md)'s
stage 3/4.
