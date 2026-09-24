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
well-known `NETPLAY_PORT` (60902) on losing its peer, regardless of whether it
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

### D26 — Synchronised pausing: a simple linear stall, marked provisional

`notes/netcode-enhancements.md`'s own wording for stage 5 ("hard to measure
who is behind... in ideal circumstances all clients will be simulating the
exact same tic") stops short of specifying an actual algorithm, unlike every
other item in the notes. Rather than reproducing GGPO's full time-sync
scheme (which reasons about round-trip variance and a client-reported "true"
frame number this codebase's wire protocol has no packet for), the chosen
design reuses a signal the rollback session already tracks for free: the
highest remote input frame ever confirmed
(`net.rollback_session_frame_advantage`, `net/session.odin`) is a direct
proxy for "how far the peer has actually gotten", since the peer cannot have
generated input for a frame it hasn't simulated. When this machine's own
frame count runs more than `NETPLAY_SYNC_STALL_THRESHOLD` ahead of that,
`net.rollback_session_should_stall` skips the current tick's sim advance
entirely on a period that shrinks as the lead grows (floored at
`NETPLAY_SYNC_MIN_STALL_EVERY` so a very large lead throttles rather than
fully freezes local input) — `netplay_playing_step` (`game/netplay.odin`)
just checks it and returns early, reusing the existing fixed-step
accumulator in `game/main.odin` rather than adding a second timing
mechanism.

This is explicitly a first cut, not a tuned one: the thresholds (5 frames,
floor of 2) were chosen to be inert over loopback (where round-trip is near
zero, so frame advantage rarely exceeds a couple of frames) while still
demonstrably triggering in `tests/rollback_session_test.odin`'s
frame-advantage tests, which drive the rollback session directly rather than
through real sockets. Untested against real network latency, where the
"how much stall is enough" question the notes themselves call hard actually
bites. Revisit with real numbers from a real (non-loopback) playtest. See
[phase-8-netcode-enhancements.md](phase-8-netcode-enhancements.md)'s stage 5.

### D27 — Windows cross-build: task added, genuinely blocked on this host

Asked to add build tasks for both Linux and Windows. `build:linux` is trivial
(an alias for the existing `build` task). `build:windows` is real
infrastructure but currently cannot produce a working binary *from this
particular Linux sandbox*, for two independent reasons, both checked
directly rather than assumed:

1. **This Odin install's `vendor:raylib` ships no Windows libraries.**
   `raylib.odin`'s foreign import references `windows/raylib.lib` and
   `windows/raylibdll.lib`, resolved relative to the vendor source file
   itself (not overridable by a `-collection:` flag); this install's
   `vendor/raylib/windows/` directory exists but is empty. Odin's official
   release archives are evidently per-platform, and the Linux archive this
   `mise`-managed toolchain downloaded does not bundle another platform's
   prebuilt libs.
2. **Odin's own linker refuses the cross-link outright**, independent of
   (1): `odin build -target:windows_amd64` on a `linux_amd64` host prints
   `Linking for cross compilation for this platform is not yet supported
   (windows amd64)` — confirmed with `-build-mode:obj`, which *does* succeed
   (proving code generation for the target is fine; only the final link
   step is blocked), and again with `-linker:lld` explicitly, which hits the
   identical message before ever reaching a missing-tool error. No
   mingw-w64, `lld`/`lld-link` or `wine` is installed in this environment
   either, so there is no available external linker to hand the object file
   to instead.

Chosen: **add the task anyway**, with the standard target flags
(`-target:windows_amd64`, no `$DR_LINK`/`setup` dependency — both are
Linux-specific), so it is ready to work the moment either constraint lifts
(a future Odin release supporting this link pair, or running the same task
on/for an actual Windows host, where it becomes an ordinary same-target
build with no cross-linking involved at all). Made the task fail loudly
rather than silently: `odin build` was observed to **exit 0 even when this
exact cross-link failure occurs**, simply producing no output file, so
`build:windows`'s `run` script checks for the binary explicitly afterward
and exits nonzero with a pointer to this entry if it's missing — a task that
reports success while producing nothing would be worse than no task at all.
This is build tooling, not a gameplay feature, so it has no phase doc of its
own — tracked here and in `mise.toml`'s own task description instead.

### D28 — Odin installed via Homebrew, not mise's own plugin

Dropped `odin = "dev-2026-09"` from `mise.toml`'s `[tools]` and installed it
with `brew install odin` instead (also removed the equivalent global pin from
`~/.config/mise.toml`, which was silently reinstalling the mise-managed copy
on top of brew's). Reasons:

- Homebrew's `odin` formula pulls in a matching `raylib`, plus `lld`/`llvm`,
  as real dependencies. mise's plugin installs only the Odin release archive
  and expects the system to already have everything else — the exact gap
  behind D27's missing `vendor:raylib` Windows libs.
- One less tool manager for a single language toolchain; `java` stays on
  mise since Ghidra's `decomp:*` tasks are the only thing that needs it and
  a JDK has no equivalent brew-vs-mise tradeoff here.

Checked, not assumed: `mise run ci` (92 tests, green), `build`, `build:linux`
and `rng:determinism` (still `0071e4eb5e5f0743` — same digest as the
mise-built Odin, now also confirmed across two independently-built Odin
compilers, not just codegen flags) all pass unchanged under brew's Odin.
`build:windows` still fails with the identical "Linking for cross
compilation for this platform is not yet supported" message — brew's bundled
`lld` does not change this, since the failure is Odin's linker *driver*
refusing to invoke any external linker for this target pair at all, not a
missing-linker problem. D27 stands as written.

### D29 — CI publishes a release per push, bundled with `src/assets/`

The project owner asked for a GitHub release on every push to `main`, with a
Linux and a Windows zip that are playable as downloaded. Each OS builds on its
own native runner (sidestepping D27's cross-link block) and zips `deimos` /
`deimos.exe` beside `assets/`; the game finds `assets/` relative to its
working directory (`game/main.odin`), so it runs when launched from the
unzipped folder.

That requires the runners to have the assets, so `src/assets/` (146 MB, 1,222
files, extracted from the original PAKs) is now committed. This reverses the
earlier "never commit game content" rule for that one directory, and it was
the owner's explicit decision after being told the repository is public and
that the data would be redistributed. The raw installer and install (`orig/`,
`game/`) remain ignored.

Verified in CI on both runners: 92 tests pass, and `rng:determinism` prints
`0071e4eb5e5f0743` on Windows as well as Linux — the first confirmation of
sim/'s RNG on two real operating systems, not just codegen variants (D27).

### D30 — Preferences is its own screen; Netplay moves to its own menu item

The main menu's Preferences button used to open the netplay lobby (Phase 7
stage 6), because the original's Preferences was a native Win32 dialog with
nothing to port. The project owner asked for a real Preferences screen —
per-player key bindings, sound and music volume, fullscreen, the diagnostics
overlay and classic mode — and for Netplay to be a separate item below the
original six.

- **Netplay** is a Text_Button on the seventh row, where the excluded
  Register button sat. It is new content, so classic mode hides it (D21).
- **Preferences** (`game/menu_preferences.odin`) opens in every mode,
  classic included: it is the only in-game way to turn classic mode back
  off. Every change saves immediately; there is no apply/cancel step.
- **Settings live in `dr:prefs`**, a raylib-free package, so the save
  format and rebinding rules are unit-tested (`tests/prefs_test.odin`). Key
  codes are stored as raylib's values; `game/prefs.odin` `#assert`s them.
  Saved to `user_data_path("preferences")`, beside progress and high scores.
- **Launch flags switch a setting on for one run** without saving it.
  Changing that setting in Preferences drops the flag and saves the choice,
  so the screen always shows and controls what is live.
- **Player 2 now has keys.** Local 2 Player previously fed player 2 an empty
  input every step. Player 1's defaults are exactly the old hard-coded
  keys; player 2's (IJKL, U/O and ;) are new. Pause became bindable later
  (D32), with P as player 1's default, and was made unbindable again as
  unnecessary: Escape is the one pause key, and a saved `pause=` line is
  ignored. A default still gives way to a key a saved file already uses. Binding a key takes it off any
  other action, for either player. Every button is now read as held,
  including Change Weapon — the sim edge-detects it itself
  (`weapons_process`), and the old one-frame `IsKeyPressed` could drop a
  press that landed on a render frame with no sim step.
- **Fullscreen** is a borderless window covering the monitor
  (`ToggleBorderlessWindowed`), not a video-mode change. To make it — and a
  resized window — show the whole game, the interactive loop now draws each
  frame into a fixed 1280x960 canvas and scales it to fit, letterboxed, with
  raylib's mouse offset/scale mapping clicks back to canvas pixels. At the
  ordinary 1280x960 window the scale is 1 and the output is unchanged.

### D31 — Versioned releases, with patch notes from commit messages

Releases were tagged `build-<sha>`, and the game had no version. Now each
push to `main` is tagged `v<major.minor>.<commits>` (e.g. `v0.1.72`):
`VERSION` holds major.minor and is bumped by hand; the last number is
`git rev-list --count HEAD`. That needs no stored counter and no
coordination — both build jobs and the release job each compute the same
tag for the same commit, and a re-run reuses it. `tools/version/version.sh`
is the one place it is computed; it refuses a shallow clone (which would
count 1), and outside CI appends `-local`. The build bakes it in with
`-define:DR_VERSION`, and the main menu draws it bottom-right, in classic
mode too — it is what a bug report needs.

Patch notes are written where the change is made: a `Changelog:` block in
the commit message (format in AGENTS.md). The release job collects the
blocks of every commit since the previous `v*`/`build-*` tag
(`tools/version/release_notes.sh`). The old `build-*` tags remain; the
first versioned release's notes start from the last of them.

### D32 — Level changes and the netplay pause happen inside the step

Two peers could end up on different levels. `game/flow.odin` applied the
level change after `rollback_session_advance` returned — outside the
snapshot and outside any resimulation — so a rollback reaching back past it
replayed the finished level without moving on, and each peer changed level
on whichever frame it happened to notice.
`rollback_session_converges_across_level_changes_and_pauses` reproduces it:
with the old wiring the peers finish on levels 2 and 1.

`sim.session_step` is now what every played session steps (local and the
rollback session): `step`, then the level change, so resimulation
reproduces it on the same frame. Flow only reads the result. Films, demos
and the oracle tools keep plain `step`, which is unchanged.

The netplay pause (Escape, or the pause menu's
Resume) is a `Pause` input
bit, not a network message: it reaches the peer and is replayed on rollback
like any button, so both sides pause on the same frame, and either can
resume. While paused only `frame` advances (the rollback ring's key); game
time, the RNG and entities stand still. It is new content — the original's
pause is outside the simulation — so single-player keeps flow's `.Paused`.
Both show a Resume / Main Menu menu, except in classic mode, which keeps
the original's text-free pause (D21). Leaving a netplay game from it sends
Goodbye; the peer freezes and can continue alone (F5).

`sim.checksum` now includes the level number, the level-complete flag and
the pause, so peers on different levels are reported as desynced rather
than hashing alike.

### D33 — High refresh rate interpolation is presentation-only

With the high refresh rate setting on (Preferences, or `-highrefreshrate`),
frames are drawn at the monitor's rate while the simulation still steps at
30 Hz (D17). Each frame is drawn interpolated between the state before the
latest step and the state after it, by how far the render loop is towards
the next step. It never extrapolates: nothing is guessed, at the cost of
drawing up to one step (~33 ms) behind the newest state.

It lives entirely outside `sim/`. The main loop copies the state before
each step (only while the setting is on); the renderer blends positions
from that copy — entities matched by slot *and* unique entity number,
players, the vertical and sideways scroll, and particles (which keep their
own previous position). Anything that moved more than 48 px in one step
jumped rather than moved and is drawn where it is; a level change skips
interpolation for that frame. Nothing reads the copy back into the
simulation, so gameplay, films, netplay and checksums cannot change.

With the setting off, interpolation is not just skipped but exact: every
position is the same whole number the renderer always used. A game-frame
capture before and after this change is pixel-identical. The
`interpolated` menu capture (`DR_INTERP_ALPHA`) checks the on path: the
terrain shifts 1 canvas pixel at 0.5 and 2 at 1, its scroll speed.

### D34 — Rose menu backgrounds outside classic mode

Outside classic mode, the menu backgrounds (`back`, and Level Select's
`lese`) are recoloured to rose, fitting the project's name: each pixel's
luminance is carried onto a rose hue (`game/assets.odin`'s
`menu_image_rose`), so the art's detail and lighting survive. Built once
per image at first use. Classic mode draws the original colours.

The oracle comparisons (`tools/oracle/menu_compare.sh`, `compare.sh`) now
run our side with `-classic`, since this port restyles some things the
original has outside classic mode and a comparison is only meaningful
without them. `mise run menu-shot` stays non-classic: it is for looking at
this port's own screens, which classic hides.

### D35 — Extras: one table for every enhancement, off in classic mode

Classic mode is the original game, look and behaviour both. Everything this
port adds on top is an *extra*: listed once in `prefs.EXTRAS` (key, label,
kind, default) and read only through `game/extras.odin`'s `extra_on` /
`extra_value`, which report every extra off under classic mode whatever is
saved. Saving, loading and the Preferences Extras page are built from the
table, so a new extra is an enum entry, a table row and its use site -- no
new save-file code, no new Preferences layout. A row that changes how the
ship looks gets a preview through `EXTRA_PREVIEWS`, drawn with the game's
own `draw_item`, so it cannot drift from play.

First entries: High Refresh Rate (moved from the main Preferences list;
same save key), Accent Hue (the ship's silver/gold trim, the crosshair
while unlocked, and air-to-ground shots) and Self Outline (the local
ship only, off by default). The trim is found by comparing each player 1
ship plate with its player 2 twin: the pairs differ only in the body metal,
so no colour ranges are guessed.

Deliberately not extras: the rose menu backgrounds (D34) and the netplay
lobby, which classic mode already hides by its own switches. Moving them
under the table is possible later; nothing here depends on it.
