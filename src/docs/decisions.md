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
  *Corrected:* the level editor is not in the binary. Its art (`edpa`,
  `EDBU`, `EDPR`, `EDUT`, `BIGR`), its string list and its unit-def fields
  ship, but no code in the Windows 1.0.2 or Mac 1.0.6 build reads the
  editor tags, and no key, menu or flag reaches it. It ran in a developer
  build. Only 10 console commands are registered: `G_Console_RegisterCommand`
  (0x4114e0) drops the 54 debug-only ones. Evidence in
  `notes/headless-3d-to-2d-findings.md`.
- **Pause has no "PAUSED" banner in the original.** *Corrected:* this
  first said it showed no text at all, which was wrong.
  `G_GameInterface::Process_StartFrame` (0x4230f0) pauses on Caps Lock and
  requests a notice of game string 0, "Press Caps Lock". It uses text
  preset 0x31 in CEGA alignment, with no fade-in, then calls
  `G_Interface_PauseGame` (0x426510).
  - PauseGame stops every sound, plays perm sound 8 ("incl"), pauses the
    music and idles, redrawing the frozen frame.
  - `DrawBlackBorders` only repaints the margins; nothing is darkened.
  - Resuming plays nothing, and the notice fades out at perm float 0x49
    (4/32) a step.

  Classic mode matches this except for the key. The port pauses on
  Escape, and the notice names whichever key is bound ("Press Escape").
  raylib cannot read Caps Lock as a key: its GLFW key callback forces the
  key down while the lock is on, so only every other tap registered and
  a pause could not be undone. Otherwise a Main Menu button is added
  under the notice, since the original has no way out from there — its
  Escape, a separate key, ends the game.
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
  (D32), with P as player 1's default. It was briefly unbindable with
  Escape as the only pause key. Now it is bindable again as `pause_key`,
  defaulting to Escape for player 1 (D21 says why not Caps Lock, the
  original's key). Player 2
  gets none by default. A saved `pause=` line,
  from the P era, is ignored so it cannot keep anyone off the default. A default still gives way to a key a saved file already uses. Binding a key takes it off any
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

Other branches build and release too, so a branch can be tried from its
zips before it is merged. Their versions end in `-<branch>`
(`tools/version/branch.sh`), which keeps them from taking the tag main
will use for the same commit count and shows in the menu where a build
came from. A branch release is never marked latest; its notes are the
`Changelog:` blocks of the branch's own commits, with a link to the
latest release of main, which they are changes on top of. A branch is
expected to be rebased, so a branch tag already on another commit is
replaced, where on main it is an error.

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

The netplay pause (player 1's Pause binding, Escape by default) is a
`Pause` input bit, not a network message: it reaches the peer and is replayed on rollback
like any button, so both sides pause on the same frame, and either can
resume. While paused only `frame` advances (the rollback ring's key); game
time, the RNG and entities stand still. It is new content — the original's
pause is outside the simulation — so single-player keeps flow's `.Paused`.
Both show the original's pause notice (D21). Outside classic
mode they also show a Main Menu button; netplay has no classic mode. Leaving a netplay game from it sends
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
luminance is carried onto a rose hue (`render/assets.odin`'s
`menu_image_rose`), so the art's detail and lighting survive. Built once
per image at first use. Classic mode draws the original colours.

The oracle comparisons (`tools/oracle/menu_compare.sh`, `compare.sh`) now
run our side with `-classic`, since this port restyles some things the
original has outside classic mode and a comparison is only meaningful
without them. `mise run menu-shot` stays non-classic: it is for looking at
this port's own screens, which classic hides.

### D35 — Extras: one table for every enhancement, off in classic mode

*Superseded by D42: the extras are now mods and the settings they register.*

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

### D36 — Easy mode's reward screen and passives live in the simulation

Easy mode (an extra, D35) stops the session after each level's tally for a
reward screen where every player still in the game picks a passive upgrade
(docs/passive-upgrades.md). The screen is `sim/` state, stepped by
`session_step` with the players' ordinary inputs, not a presentation-side
menu: choices made on it change the next level's simulation, so they have
to be rolled back, resimulated and resynced exactly as play is, and keeping
them in `State` gets all three for nothing. The alternative -- a menu in
`game/` that sent its choices as new netplay messages -- would have needed
its own agreement protocol and its own reconnect path.

Passives are held as a level per passive (`Player.passives`) and every
modified stat is recomputed from them where it is used. Nothing stores a
modified value, so passives touching one stat stack by construction, and
each hook returns the original computation untouched when no passive
applies -- `oracle:diff` stays exact, and `sim.checksum` only mixes the new
fields in easy mode. Easy mode itself travels in `sim.Session` and the
netplay `Start` packet's new flags byte.

### D37 — New content lives in its own tree, appended after the originals

New Weapons (docs/new-weapons.md) adds records and sprites the original
never had. They live in `assets/extra` (since D51, in each plugin's own
folder), laid out like `assets/`, rather than beside the extracted
records. `data.extra_defs_load` appends them after
the original definitions, and `assets_open` reads the extra sprite index
beside the game's own.

Why a separate tree:
- `assets/` stays exactly what the extractor writes. `assets:verify` and
  the equality test against the original (`tests/assets_test.odin`) keep
  meaning what they did.
- Every original unit, weapon and sprite keeps its index, so films and
  `oracle:diff` are untouched.

New content is loaded in every session, classic included. It is kept out
of play by marking it rather than by not loading it:
- each weapon from the extra tree has `Weapon.extra` set;
- the original's weapon selection (`best_air_weapon`, `level_air_weapon`,
  `next_weapon_of_type`) skips any weapon marked `extra`;
- only a New Weapons session's loadout (`sim/loadout.odin`) hands them
  out.

A record's new behaviour goes in an `x_`-prefixed tag, such as
`x_AimedRelease_BOOL`. The generated `Wep_Def` stays the original's
layout. *Since D48, the plugin that reads a tag registers it and the loader
fills it generically.*

The extra records are hand-authored source: each was cloned from its
nearest original record and then edited. The extra sprites are derived from
the extracted ones by `mise run assets:extra`, so they can be rebuilt like
the rest of `assets/`.

The loadout screen follows D36: it is simulation state, stepped with
ordinary inputs. New Weapons travels in `sim.Session.loadout` and in
`net.START_LOADOUT`, the next bit of the flags byte that `Start` and
`Level_Choice` already carry.

### D38 — The Discharge Beam is an instant hit, not a projectile

The Discharge Beam (docs/new-weapons.md) hits everything on its line on the
step it fires. The original has nothing like it: every shot is an entity
that flies and collides. The beam is not one. `sim/beam.odin` casts the line
when the weapon fires, hits the targets through `entity_hit` nearest first,
and pushes a `Beam_Event` onto `State.beams`, a per-step queue like the
particle and blur requests. *Since D48 all of it is the New Weapons
plugin's, and the queue is the plugins' generic effect queue.* Presentation draws each event and lets it fade.

Why not a very fast, very long projectile:
- a projectile takes steps to cross the screen, and one fast enough to
  seem instant would jump past thin targets between steps;
- carrying leftover damage from one kill to the next target needs an
  ordered pass over the line, which the collision loop does not make;
- a beam drawn "up to what it hit" needs where it stopped, which the
  event carries.

Nothing new is kept between steps. What the beam did lives in the
entities it hit, which are ordinary state, so snapshots, rollback and
`sim.checksum` needed no change. *For a while a charge also left motes,
ordinary units too; they were taken out again
(notes/extra-weapons-and-passives-3.md).* *The wind-up
added one field, `Weapon_Handler.air_windup`, which is hashed with the
rest.* The queue is
presentation input only, cleared each step, and not hashed. The target
filter (`air_shot_can_hit`) is the one the Chaingun's aiming already uses,
so the beam can hit exactly what an air shot can.

The weapon still charges through the ordinary power-up state machine. A
beam weapon's release calls `beam_release` in place of the release spawn
timing, so Improved Charge and Auto Charge apply unchanged.

### D39 — The simulation's state lives in odecs, created once in a fixed order

*The first rule is tightened by D47: a slot now gets its components when
the world is built, and nothing is added or removed after.*

notes/ecs-refactor.md moves the sim to an entity component system: data in
components, behaviour in systems, and new content in plugins that add their
own of each. The ECS is odecs (NateTheGreatt/odecs), vendored unmodified in
`third_party/odecs/` and held to the purity rule (D3).

Why odecs rather than our own:
- it is a small, plain Odin archetype ECS with typed queries, so systems
  read as ordinary loops over component columns;
- it takes an allocator, so a world can live in the session's arena like
  the rest of the state;
- it is MIT and small enough (about 3,500 lines) to vendor and read.

odecs was not written for rollback, so the sim uses it under three rules:
- **Every entity is created at world creation, in a fixed order, and never
  destroyed.** The original has fixed pools (1,000 entities, 1,024 groups),
  and `Entity_Ref` identifies a slot plus a spawn number. Spawning adds
  components to a slot, and freeing removes them. So entity ids are the
  same in every world, on every machine, and after every restore.
- **No behaviour depends on archetype or row order.** odecs moves rows
  when components come and go, and the rows' order depends on history. The
  original's update order is its linked lists (groups in activation order,
  entities in group order), and the RNG draws depend on it, so those lists
  stay, as components, and anything order-sensitive walks them.
- **Pointers into odecs never outlive a structural change.** Columns are
  byte arrays that grow and swap-remove. A system that adds or removes
  components re-fetches what it holds.

### D40 — Deimos Rose's additions are plugins, and a session names the ones it runs

notes/ecs-refactor.md splits new content into plugins, each in a folder of
its own under `plugins/`, with dependencies between them. A plugin
registers itself (`sim.plugin_register`), its components, its systems and
its hooks from an `@(init)` procedure (a registration step since D50). A
plugin's ID is its place in the registry, and a set of plugins is
`sim.Mods`, a 32-bit set.

- **A plugin is on only while everything it needs is.** `mods_resolve`
  drops the rest. The Mods page turns dependencies on with a plugin, and
  dependants off with it, so a saved set never relies on resolving.
- **A plugin imports the plugins it needs.** The import is what lets it
  use their components, and it guarantees they are linked, so their
  `@(init)` registers them. `import _` is enough where nothing is used.
- **A session plugin is part of `sim.Session`.** It changes the
  simulation, so peers must agree on it. The session's systems are
  ordered once, when it starts (`schedule_build`). Any other plugin, such
  as how the game looks, is the player's own and never reaches the
  simulation.
- **A plugin's sim half is held to D3.** `mise run purity` checks every
  plugin folder except `view/`, where its presentation goes.

Plugin IDs follow registration order, which is fixed for a build. Peers
agree on them only when they run the same build, which netplay already
requires (D43).

### D41 — The core reaches plugins only through hooks

`sim/` must not name a plugin: the core is the original game, and runs
alone in classic mode, in films and for the oracle. Where the original's
code has to give way to a plugin, the plugin registers a hook
(`sim/hooks.odin`):
- a stat provider: a modifier on a player or weapon stat (the passives);
- a hold: a screen that keeps the level from moving on (the reward and
  loadout screens);
- a weapon chooser: which air weapon a new game or Change_Air picks (the
  loadout);
- a weapon filter: which of the new weapons the rules may choose (New
  Weapons).

A hook runs only while its plugin is on in the session (`mod_on`). With
none on, each query returns the original's answer untouched, so
`oracle:diff` stays exact by construction.

The alternative was for the core to call each plugin directly. That would
have had `sim/` import the plugins, so they could not depend on the core
without a cycle, and a new plugin would mean editing the core.

### D42 — Mods replace the extras; their settings are registered by the mods

This supersedes D35's table. Each of the four extras that switched a
feature on or off is now a mod. High Refresh Rate is 30FPS Unlock,
Accent Colours is Accent Color, and Easy Mode and New Weapons are their
mods. What is left of the extras are the mods' settings. A plugin
registers them with `prefs.setting_register`, and the Extras page (the
Extra Preferences plugin's) lists those of the mods that are on.

- **Settings are registered from a plugin's `view/` package.** The plugin
  itself cannot register them: `prefs` formats text, which D3 keeps out
  of anything the simulation runs.
- **Mods are saved by name** (`mods=accent,new_weapons,...`), since an ID
  is only a place in one build's registry. A name the build does not know
  is dropped.
- **Older saves carry over.** Without a `mods=` line, the four old keys
  (`high_refresh_rate`, `accent_colours`, `easy_mode`, `new_weapons`) turn
  their mods on or off. Settings keep the keys they had (`accent_hue`,
  `accent_hue_p2`, `self_outline`).
- **Classic mode turns every mod off** whatever is saved (`prefs_mods`),
  as it did every extra.

A new player starts with Accent Color, New Weapons and Netplay on, as
the extras' defaults had them, plus what those need.

### D43 — Start carries the session's mods by ID, after the old flags

Start and Level_Choice gained four bytes after the flags byte (D36): the
host's session plugins as a `sim.Mods`. They supersede the flags, which
are still sent. A build that reads only the flags then sees what it did
before. A Start from such a build has no mods, and `mods_from_flags`
turns on what its flags turned on then.

The mods travel by registry ID, not by name. Names would not fit the
reliable channel's buffer, which is sized for Hello, and the IDs already
have to agree: peers must run the same build for their simulations to
agree at all. Netplay's own plugin is added exactly when the session is
online (`session_from_mods`), whatever either player has on.

### D44 — Behaviour lives in packages of systems; the host knows no game

`dr:sim` keeps the state, the registries, the schedule and the
definitions. The systems moved into packages under `sim/systems/`, with
`sim/stats` and `sim/lifecycle` beneath them and `sim/core` above, which
registers the original's systems in its order. A package imports only
those below it (phase-9-ecs.md has the order), so dependencies between
systems are explicit and acyclic.

`sim/lifecycle` is the one way to spawn, change state, destroy or free an
entity, so the pool and its group lists change in one place. The
alternative, leaving the systems in `sim/` split by file, kept every
system able to call every other, which is what the refactor set out to
end.

### D45 — Definition flags are components on prefab entities, and stages query them

*Revised by D47: one prefab per (unit, state), holding both levels'
components, and stages match through queries run once at build.*

Each unit and each of its states is a prefab entity in a world owned by
the state but not part of it. Builders registered by the system packages
turn the definitions' flags into components on those prefabs when a
session starts, with the session's plugins. An entity's components, for
a stage, are its own plus its unit's plus its current state's. A stage
declares `with` and `without` sets and runs only on entities that match.

- **Prefabs, not components on each entity.** An entity changes state
  mid-step. Changing its components would move it between archetypes,
  and odecs swaps rows when it does (D39). The prefab's components stay
  put, and only the state index changes.
- **Not state.** Prefabs follow from the definitions and the mods, fixed
  for a session. Snapshots, checksums and the golden fingerprints leave
  them out. A state read in from elsewhere builds its own.
- **The step's view.** A stage is matched against the state G_EG_Process
  holds in its local, refreshed where the original refreshes it, not the
  entity's state at that instant. The two differ after the movement AI
  changes state, and the stages after it read the old one, as the
  original does.
- **Order is still the original's.** Stages run entity by entity in group
  order, since the random draws depend on it. A query decides whether a
  stage runs for an entity, not the order entities are visited in.

### D46 — Presentation is in packages below the game, and plugins draw their own

`render` (the renderer, assets, text, effects and render systems) and `ui`
(menu widgets and overlays) sit below `game`. Each plugin's presentation
is in its `view/` package, which registers its render systems, overlays
and effect systems itself. The game imports each plugin and view in one
file (`game/plugins.odin`) and names none of their screens.

Before this, `game` drew the reward, loadout and passives screens and the
Self Outline, each gated by plugin ID, because a view package could not
reach the renderer's types without importing `game`, and `game` imports
the views. Moving the renderer down removed the cycle. `sim` and the
plugins' simulation halves may not import `render` or `ui`
(`mise run purity`).

### D47 — odecs through its public API only: a fixed world, merged prefabs

The first ECS pass wrapped odecs in its own machinery: it read the
world's records and archetype signatures, moved entities between
archetypes itself, reserved column rows, did arithmetic on entity ids,
and matched stages with a component bitmask of its own. It worked, but
it depended on internals odecs does not promise, and duplicated what the
library's API already does.

Now the sim calls only odecs's public procedures: `create_world`,
`delete_world`, `register_component`, `add_entity`, `add_component`
(building prefabs only), `get_component`, `has_component`, `query_raw`,
`get_table`, `get_entities` and `get_entity_archetype`. `mise run purity`
fails on any use of its internals or of its encoded query terms outside
`third_party/`.

- **A fixed world, built through the API.** Every entity is made once,
  with `add_entity`, carrying every component its kind (session, player,
  crosshair, group, pool slot) will ever need for the session's mods, the
  way the original's pools are fixed. Nothing is added or removed after,
  so the world never changes shape in a session: the pointers and tables
  taken after the last `add_entity` stay good (odecs's own rule), and the
  ids are the same on every peer without depending on how odecs numbers
  them. A plugin contributes components to a kind (`kind_component`)
  instead of adding them in a setup system.
- **Snapshots walk the tables.** For each component, in catalog order,
  the archetype tables `query_raw` finds, row by row. The rows are in
  creation order and never move, so two worlds with the same mods lay out
  the same. The header carries the catalog's and the world's shapes, and
  a read into a world of another shape is refused.
- **One prefab per (unit, state).** Builders get the unit and the state
  together and add the unit's components first, so the state's value is
  the one kept, as flecs's Inherit trait overrides. Each stage's `with`
  and `without` become a prefab query, run once over the prefab world
  when it is built; each prefab keeps the set of queries it matches, so
  whether a stage runs for an entity is one bit test.
- **No encoded terms.** odecs builds `not`, `or` and pair terms through
  a package-global counter that each query resets, which parallel tests
  race on, and its query cache keys `or` groups ambiguously. `without` is
  done by subtracting archetype sets instead.

Writing every slot of the fixed world made each snapshot 617 KB, where
the first pass wrote only live rows: 64 µs to save and 168 µs to
checksum, and two-thirds of every replayed frame's cost. So the
pool and the groups, which are nearly all of it, are written only as far
as they have been used. Both are handed out lowest first, and
`Pool.slots_touched` and `groups_touched` mark one past the highest ever
handed out this session. They never go down, not even at a level's
start, because a freed slot keeps what its last entity left, which a
stale `Entity_Ref` still reads. Everything above the marks has never
been used and holds its start values, so the snapshot's header carries
the marks and a read puts rows above them back to their start values.
Mid-level on level 6 the world is now 48 KB: a snapshot takes 6 µs, a
checksum 13 µs and a 10-frame rollback 80 µs. The fullest level of the
benchmark's sessions (level 11, 170 slots) takes 109 KB, 12 µs, 30 µs and
252 µs. The one rule this adds: nothing may write to a slot or group that
has not been handed out, since the snapshot would not see it.

### D48 — New weapons live in their plugin, through four extension points

Adding the Discharge Beam touched seven places outside anything it owned:
a field and a struct on the core's `Weapon`, parsing in the loader, two
branches in the weapon handler, a queue on `State`, its clearing, and
drawing and clearing in the renderer and the game. The Chaingun's aimed
release added another field and branch. None of it could be switched off
with its plugin, and the next weapon would have touched the same places.

Now the core has one generic way for each of those, and the Beam and the
aimed release are entirely `plugins/new_weapons` and its `view/`:
- **Definition keys** (`sim/def_keys.odin`). A plugin registers the `x_`
  keys it reads, typed by their suffix, and the loader fills every
  registered key of every weapon into `Weapon.keys`, knowing none of them.
- **Weapon_Fire** (`sim/hooks.odin`). A plugin fires the weapons whose
  keys it recognises: with each press, as a charge's release all at once,
  or as each of a charge's volleys. Unlike the other hooks it is not
  gated by the session's mods: how a weapon fires belongs to the weapon,
  which only reaches play through its plugin's filter, and a tool that
  flies it alone (`tools/dps`) should see it fire.
- **Effect events** (`sim/queue_effects.odin`). A plugin registers a kind
  with the type it carries and pushes values for its view, a per-step
  queue like the core's, left out of snapshots and checksums.
- **Effect systems that draw** (`render/render_systems.odin`). A plugin's
  view keeps its effects, draws them over the draw layer it names, and
  forgets them when a level starts.

The Beam's and the Chaingun's DPS figures, the golden fingerprints and
`oracle:diff` are unchanged. A new weapon with new behaviour now needs a
plugin and its data, and no core change unless it needs a kind of hook
the core does not have yet.

### D49 — A plugin owns its content and its screenshots

Making the Chaingun a plugin of its own showed what D48 had left shared.
Its records and sprites sat in one `assets/extra` tree with the Discharge
Beam's, let in by New Weapons' filter that allowed every extra weapon.
Its recolour plates were in a recipe with the Beam's. Its screenshot
scenarios, like every plugin's, were cases in `game/main.odin`, which
imported the plugins to write them. Three extension points now make a
weapon, or any content, one plugin:

- **Content trees.** A plugin's content is `assets/extra/<plugin name>`
  (since D51, `plugins/<plugin name>/` beside its code), laid out as
  `assets/` is. `data.extra_defs_load` reads the tree of each
  plugin in the build, and orders what it loads by id rather than by
  plugin, so moving a record between plugins renumbers nothing. Each
  weapon records its plugin (`Weapon.plugin`), and `weapon_allowed` lets
  it into play while that plugin is on. A plugin marked `content` is left
  out of a session when its tree did not load (`sim.mods_with_content`),
  where flow used to check for New Weapons by name. Each recolour recipe
  names its plugin and writes into its tree; `assets:extra` runs them
  all. A tool that registers no plugin (`tools/simbench`) loads no
  content, which suits it: it runs the core alone.
- **Screenshot scenarios** (`ui/shots.odin`). A plugin's view registers a
  named scenario: its plugin, the level and players, a setup procedure,
  and phases of held buttons played with the presentation following.
  `mise run menu-shot MENU=<name>` runs it. `game/main.odin` names no
  plugin's scenario; only Level Select's Easy Mode switch remains, which
  waits for a menu-item extension point.
- **`loadout.loadout_give`**, handing a player a weapon as if chosen on
  the loadout screen, for scenarios and tests.

The Chaingun (`plugins/chaingun`) needs New Weapons, which hands the new
weapons over and gives the aim its targets (`air_shot_can_hit`). It is on
by default and lists under New Weapons on the Mods page, where it can be
turned off alone. Turning New Weapons off takes it too, as with any
dependant. The lobby has one New Weapons switch, so turning that on
brings back the default-on plugins that need it
(`sim.mods_default_dependants`); an older build's Start flag reads the
same way. The Mods page keeps its rule that turning a mod on turns on
only what it needs, since the dependants have rows of their own there.

The split was proved neutral at each step: the extra units and weapons
load at the same indexes (only the extra sprites' order changed, and
sprites are only found by id); the golden fingerprints, `coop_extras_l6`
among them, are unchanged; both weapons' `dps:report` pages are
byte-identical; and every moved scenario renders byte-identical, bar the
three whose particles take random directions, which differ from before
by no more than two runs of one build differ from each other.

The Discharge Beam could follow the same pattern, leaving New Weapons
as the shared part: the loadout hand-over, the targets and the beam's
effect queue if a second weapon ever wants it.

### D50 — Registration runs in a fixed order, and peers compare builds

A Windows player joining a Linux host crashed when Easy Mode's reward
screen opened at the end of the first level, and again on rejoining.
Both machines ran v0.1.166. The cause was the order the packages'
`@(init)` procedures ran in. Odin runs a package's after those of the
packages it imports, but orders unrelated packages differently for
different targets. The Linux and Windows objects of one commit, compiled
with `-build-mode:obj`, call them in different orders:

- the components: movement, entity, collision on Linux; collision,
  entity, movement on Windows (with winsock's start-up between them);
- the plugins: passives 4, netplay 5, Easy Mode 6, Loadout 7 on Linux;
  netplay 4, passives 5, Loadout 6, Easy Mode 7 on Windows.

Every registry hands out ids in the order it fills: plugins, components,
effect kinds, weapon keys and prefab queries. It also breaks ties
between systems by that order, and the state keeps the schedule as
indexes into the registries. So a Linux host's mods meant other plugins
to a Windows guest. The host's Easy Mode was the guest's Loadout, and
the guest had no reward screen for the host's to hold. On rejoining, the
guest's catalog check refused the host's snapshot ("the game state
received is not from this build"). The guest played on without a world
and page-faulted. That was reproduced: a Windows v166 build under Wine
rejoined a Linux v166 host held at the reward screen. The Linux release
rejoined the same host cleanly.

- **An `@(init)` only names a step.** `sim.register_step(stage, name,
  proc)` records it, and `sim.register_all`, first thing in every
  `main` and in the tests' set-up, runs the steps by stage (core,
  plugins, presentation, views), then by name. A view runs after every
  plugin, so it may read its plugin's ids. A plugin's step reads
  nothing another plugin registers. `sim.init` asserts that
  registration ran. The order no longer depends on the compiler, so a
  plugin's id follows its name (`plugins_ids_follow_their_names`).
- **Peers compare builds in their Hello.** `sim.registration_hash`
  digests the catalog, the plugins, the systems, the stages and the
  weapon keys, in id order. The Hello carries it after the name, where
  older builds ignore it. A host that meets another build answers with
  its own Hello and waits for a peer it can play with. A guest that
  meets one returns to the lobby menu saying "the host runs a different
  version of the game". An older build sends no digest and is refused
  the same way.
- **A snapshot that does not read ends the connection.** Before, the
  resync logged the failure and played on.

Saved preferences name their mods, so the new ids leave them as they
were. The golden fingerprints are unchanged, and the Chaingun's
`dps:report` page is byte-identical. `mise run netplay:level-end` plays
two instances to the reward screen headlessly. `HOST_BIN` or `GUEST_BIN`
runs one side on another build: v166 as the host is refused by the new
guest, and v166 as the guest by the new host. A Windows build is not
linked locally (D27), so the fix is unproven on Windows itself until a
release's Windows build joins a Linux host.

### D51 — A plugin's content sits beside its code

The level editor (notes/level-editor-plan.md) exports levels as plugins,
and a plugin with levels brings maps, masks, previews and perhaps music.
Under D49 content lived apart from its plugin, in `assets/extra/<name>`,
and could only be records and sprites. Now:

- **Where.** A plugin's content is in `plugins/<name>/`, beside its
  `.odin` files: `data/` and `sprites/` as before, and now `images/im16/`
  and `audio/`. Odin compiles only the folders something imports, so
  content subfolders are ignored by the build. A plugin folder with none
  of these four has no content (`data.plugin_content_dir`).
- **The plugins root** is `$DR_PLUGINS`, or `plugins` in the working
  directory. mise sets it to `src/plugins`. A release has
  `deimos/plugins/<name>/` holding only each plugin's content: `mise run
  dist` copies every file of `src/plugins` that is not Odin source, and
  CI zips that folder.
- **Sprite paths** in a plugin's `sprites/index.json` are relative to the
  plugin's folder (`sprites/im08/PL1K.png`). `data.Sprite_Plate.image` now
  holds the joined path, which the renderer and `tools/icons` load as it
  is.
- **Images and sounds add, never replace.** `assets_open` lists each
  plugin's `images/im16/*.png` and `audio/*.wav` by id, and
  `assets_image_path` and `assets_audio_path` find a plugin's file before
  the core tree's. An id the core tree already has is not taken from a
  plugin. Content is loaded in every session, classic included (D37), so
  a plugin able to replace an original image would change classic mode.
  A plugin that wants another look for an original ships it under a new
  id and points its own records at that.
  A plugin's sounds may be `.ogg` or `.mp3` as well (D76).

`assets/extra` is gone. The recoloured plates, rebuilt with `mise run
assets:extra` into the new folders, are byte-identical to the moved ones.
The golden fingerprints, `oracle:diff:saved` and the Chaingun and
Discharge Beam `dps:report` pages are unchanged. The two weapons load in
a laid-out release run with neither `DR_ASSETS` nor `DR_PLUGINS` set.

### D52 — Data plugins are found at startup, after the compiled ones

The level editor cannot compile Odin, so what it exports has to be a
plugin the game finds at run time.

- **A data plugin** is a folder under a plugins root (D51) with a
  `plugin.json`: label, description, version, deps, `default_on` and
  `session`. Its name is the folder's: lower-case letters, digits and
  underscores. `data.plugins_discover` reads them, in name order, taking
  a name from the first root that has it, and reports any it cannot read.
  `game/main` declares them (`sim.plugins_declare`) before
  `sim.register_all`, which registers them after every compiled plugin
  and before the presentation's steps. So compiled plugins keep their ids
  whatever folders are installed, and two machines with the same folders
  agree on every id.
- **A compiled plugin's folder may have a `plugin.json` too.** It then
  only gives the plugin its label, description and version.
- **Every data plugin is `content`.** It is dropped from a session when
  its content did not load, like the Chaingun without its folder. One that
  needs a plugin not in the build can never be on: the Mods page shows N/A
  and names the missing plugin (`sim.plugin_missing_dep`).
- **Peers compare content.** `data.plugins_digest` hashes every file of
  each plugin's content folder but Odin source (XXH3, by relative path and
  contents), and `registration_hash` covers each plugin's version and
  digest. Two peers with different level packs refuse each other at Hello
  rather than desync.
- **`Mods` is 64 bits** (`MAX_PLUGINS` 63). Start carries it in 8 bytes
  and Level_Choice is 11 bytes long. Both still read the 4-byte form, but
  an older build is refused at Hello anyway (D50), which is deliberate.
- **Tests.** `tests/fixtures/plugins` holds synthetic plugins: one unit,
  one depending on it, one with a missing dependency, a relabel of Accent
  and a badly named folder. `tests/data_plugins` is a test package of its
  own, which declares them before registering, so the main suite still
  sees the ids a game sees. `DR_PLUGINS=$PWD/tests/fixtures/plugins:$PWD/plugins
  mise run menu-shot MENU=preferences_mods_end` shows them on the Mods
  page. `DR_PLUGINS` may list several roots, split by `:` (`;` on
  Windows), searched in order; since D53 the original levels are in
  `plugins/`, so a run needs that root too.

The Session is not part of the hashed world, so widening `Mods` moved no
golden fingerprint. The Mods page as a new player finds it is
pixel-identical.

### D53 — Campaigns, and the original levels as the Classic Levels plugin

A level pack the editor exports has to play as its own campaign, without
taking the place of the original twelve.

- **The move.** The twelve level records and their maps, masks and
  previews are in `plugins/classic_levels/` (`data/levels/`,
  `images/im16/`), a data plugin that is on by default. Its
  `plugin.json` lists the levels in play order; `LEVEL_ORDER` keeps its
  provenance and is what `defs_load` (the PAK loader the oracle uses)
  still reads, and a test holds the two lists equal. `assets:extract`,
  `assets:records` and `assets:verify` take the plugins root, and the
  asset manifest names the plugin each level image belongs to. Music
  `mu03` is shared, so it stays in the core.
- **A campaign is a plugin with `levels`**, its manifest's list of
  identifiers in play order. `Level_Def.campaign` names it (CORE for the
  originals) and `number` counts within it. `defs.levels` holds the
  originals first, then each campaign's, each run contiguous:
  `sim.campaign_levels` returns one, `level_by_id` looks only within one,
  and a campaign's `le01` is not the original's.
- **The session carries it.** `sim.Session.campaign` picks the levels a
  game plays; `sim.session_levels` returns them, and level advance, the
  last-level check and Easy Mode's reward use it. Start (17 bytes) and
  Level_Choice (12) carry it in their last byte, and the shorter forms
  read as CORE.
- **Level Select** shows a switch above the level number when more than
  one campaign is offered: Classic Levels while it is on, then each other
  campaign plugin that is on, in the Mods page's order. Classic mode
  offers only the originals, and with nothing else installed the screen
  is as before. A level without a preview shows an empty slot under its
  identifier. The campaign's name steps to the next, and the `<` and `>`
  either side of it step either way, round either end.
- **The netplay lobby** shows the campaign above CONNECTED while the host
  is offered more than one, or plays another than the originals: the host
  steps it with `<` and `>` as on Level Select (which starts the level
  choice over), and the guest reads the host's choice. A pack may reuse
  the originals' level names, so the level alone does not say which.
- **Progress is per campaign**: `progress` for the originals, as before,
  and `progress-<plugin>` for each other. High scores are one table, as
  in the original.
- **The level title** (`Notice_Level_01`..`12`) is only shown for level
  numbers the original has.

Films, `DR_SHOT` and the oracle play the originals, whose ids, order and
numbers are unchanged. `oracle:diff` and `oracle:diff:saved` are exact,
the goldens unchanged, and Level Select, with and without Easy Mode, and
the main menu are pixel-identical to before. `tests/fixtures/plugins/
fixture_campaign` is a two-level campaign whose manifest order is the
reverse of its file names; `tests/data_plugins` plays it through to the
end, and `MENU=level_select_campaigns` shows it on Level Select and
`MENU=netplay_lobby_campaigns` in the host's lobby.

### D54 — Optional level fields, and launching straight into a level

The editor's levels carry what the originals never did, and its Play
button needs the game to start one without the menus.

- **Level fields**, each optional; no original level has any, so the
  twelve load exactly as before.
  - `start_weapons` (`air`, `ground`: weapon ids) sets what players start
    the level with, at a new game and at the level's start, in place of
    the weapon its number brings. It changes play, so it is in the sim
    (`Level_Def.start_air`, `start_ground`, zero for none). A plugin's
    weapon chooser still chooses when it is on: the loadout is the
    player's.
  - `wind` (`direction_degrees`, as placements' headings, `strength`),
    `water` (`height`, `colour`, `visible`), `lighting`
    (`sun_azimuth_degrees`, `sun_elevation_degrees`, `sun_colour`,
    `ambient_colour`, `ambient`, `softness` in map pixels), `skybox` (an
    im16 id) and `layers` (`albedo`, `normal`, `height`, `shadow_mask`,
    `hd_map`: im16 ids) are the presentation's and the editor's, on
    `data.Level_Media`. The sim still reads only the media mask. Light a
    level leaves out is `LIGHTING_MEASURED`, the originals' as measured on
    their maps (notes/headless-3d-to-2d-findings.md): a white sun at
    azimuth 36°, 40° up, and neutral shadow at 0.44 (the silos alone said
    28° up; D55 fitted 40).
- **Launch flags**, in `game/settings.odin` and the `run` task's usage:
  - `-campaign <plugin>` picks a campaign, and turns its plugin on for the
    run as `-highrefreshrate` does 30FPS Unlock. Alone it only picks what
    Level Select shows. Classic mode refuses any but the originals.
  - `-level <identifier or id>` plays that level at once, and `-row <n>`
    from map row n (the view's top); either alone plays the campaign's
    first level. A name that is not installed exits with a message.
    With `DR_SHOT` they pick the level the shots play (`launch_level`).
  - `-plugins <dir>` adds a plugins root searched before `$DR_PLUGINS`.
- **`level_start_at_row`** is `level_skip_to_end` under a name for what it
  does: the view's top at the row, the entities cleared and the rows in
  and 64 above the view spawned, as at a level's start. What lies below is
  never met, which is fine for testing a level. Netplay's
  `DR_NETPLAY_END` still uses it.

`tests/level_start_test.odin` starts le07 at row 1500 and finds exactly
its placements from rows 1436 to 1980 spawned, and checks the start
weapons rule on the synthetic fixture. The fixture campaign's first level
names start weapons and a wind, and `tests/data_plugins` plays it with
them. Goldens, `oracle:diff` and `oracle:diff:saved` are unchanged.

### D55 — The terrain renderer and the level project

A level's terrain is data again (notes/level-editor-plan.md, Stage 5):
the editor saves it, and one renderer draws it for the editor, for
exports and for comparison with the original art.

- **The project**, `terrain/project.odin`: `<level>.drproj.json` beside
  its side files, each one PNG pixel per map pixel.
  - the heightmap, 16-bit grey in 1/32 map pixel (up to 2048 high);
  - optionally the unlit colour (RGB), four materials' weights (RGBA),
    the canopy cover (grey), with the canopy's height and material, the
    occlusion (grey, D56) and the water (RGBA, D57);
  - up to four materials (a colour, or a tiling image tinted by it, and
    tags such as `original-derived`), and the cliff and shore rules that
    lay one automatically by slope or by height above the water;
  - the level record itself, as the game reads it, lighting, water and
    wind included (D54): nothing is kept twice.

  Saving the same project writes the same bytes, JSON and PNGs alike
  (`terrain/png.odin` writes its own PNGs: raylib's are 8-bit only).
  Maps, masks, previews and HD layers are exports of it.
- **The renderer**, `terrain/render.odin`: from straight above, one
  fragment shader per output pixel, placed by `gl_FragCoord` and not by
  interpolation, so a map drawn in strips of at most 4096 rows is the map
  drawn at once, bit for bit. A 4x le07 (1920x14400) is four strips.
  - Light: ambient, plus the sun by how squarely it meets the ground,
    scaled so flat ground in the sun is exactly its unlit colour, times
    the share of the sun not blocked.
  - Shadow: a march toward the sun over the height texture, a map pixel at
    a time, from a whole pixel past the penumbra; the deepest the ray goes
    under the surface sets a smoothstep `softness` pixels wide. No shadow
    maps, so strips have no seams and the shadow layer comes free.
  - Outputs: lit, albedo, normal, height (16-bit), shadow and occlusion
    (D56), at any whole scale, each optionally through the originals'
    15-bit colour.
  - Textures go through `DrawMesh`'s material maps, seven slots, since
    rlgl's batch binds only four; the height texture is RGBA32F (surface
    with canopy, cover, bare ground, then the surface unsmoothed). The
    editor's tilted view (Stage 7) will feed the same shader a mesh.
  - Geometry is drawn smoothed: a Gaussian of `GEOMETRY_SMOOTHING` (1 map
    pixel) over the surface and ground on upload, so a heightmap's
    per-pixel steps shade as a smooth surface, as smooth vertex normals
    would. Done on the CPU, it keeps strips identical to the whole; the
    height output is the project's own heights; `-smoothing=0` turns it
    off.
- **`terrain/analysis.odin`** finds shadows as the findings did (much
  darker than the 85th percentile of the 81-pixel square around, not
  water, opened by a 3x3 cross), for `tools/terrain compare`.
- **Headless only.** The tool and `tests/terrain` open a hidden window;
  the mise tasks run them under `xvfb-run` with `DISPLAY` and
  `WAYLAND_DISPLAY` cleared, and without xvfb the GL tests skip. CI
  installs xvfb and Mesa's software GL.

`tests/terrain` checks the analytic cases (flat ground unshadowed and its
own colour; a wall's shadow h/tan(e) long; strips and row ranges equal to
the whole; 2x averaged down within quantisation of 1x; heights back
exactly), the save-load-save round trip and the 15-bit colour. Goldens,
`oracle:diff` and `oracle:diff:saved` are unchanged: nothing in the game
uses the package yet.

### D56 — Recovered levels: the renderer's light divided out, and a baked occlusion layer

Stage 6 of notes/level-editor-plan.md turns each original map back into a
level project (`tools/terrain_recover/`). Three choices in it hold beyond
the originals.

- **The colour is divided by the renderer's own light.** The recovery
  writes the project, has `tools/terrain` draw its normals and shadow at
  the art's sun, and divides the art by ambient + (1 − ambient) × slope
  term × shadow, with the shadow counted only where the art is detected in
  shadow. A render at the original sun then gives the art back, apart
  from shadows the heights cast wrongly, and a relight does not shade the
  slopes twice. Dividing out only the detected shadows had left the art's
  slope shading in the colour: le01 rendered at shadow IoU 0.709, 0.920
  with this. The light is the renderer's, not a copy of it in Python: a
  copy from the refinement's half-size shadow gave 0.887.
- **Canopy is a layer, not height.** CLIPSeg's zero-shot "trees" finds
  it, and the heights are split under it into a smooth ground and the
  cover above it. The split is lossless: ground + cover × canopy_height is
  the heights, so the render does not change, and the editor can treat
  the trees as vegetation.
- **Ambient occlusion is a baked project layer, `occlusion`** (grey,
  255 open to the sky, optional). The renderer multiplies only the
  ambient light by it. It is baked, by `tools/terrain_occlusion` with
  FLUX.2 [klein] 4B from the renderer's albedo, rather than computed from
  the heights, because the texture shows what the heights lack: stones,
  cracks, the gaps between crowns. GTAO on the heights saw only the
  geometry, and was heavy on the jungle. Marigold V2 normals of the
  colour added under a pixel of relief (work/reports/level-recovery.md,
  chapter 6). A painted level bakes its layer the same way.
  - It rides in the albedo texture's alpha: `DrawMesh` binds material
    slots 7–9 as cubemaps, so an eighth texture would need a gap in the
    slots. The white stand-in texture reads as fully open when neither
    layer is present.
  - It is an output of the renderer too, for the deferred layers of
    Stage 10.

### D57 — Recovered water: a translucent layer over the bed, its surface unshadowed

The originals' water is not flat colour. Their shallows show the sand
through, and the surface has a fine grain. A level drawn with flat water,
the median water colour (Stage 6 before this), was 2.0 to 6.2 levels of
255 from the art under the water, with 0.17 to 0.56 of its grain. The
recovery now bakes the water as a project layer, `water` (RGBA: the
water's own unlit colour, and how opaque it is; optional).

- **What the art shows.** Fitting art ≈ s × ((1 − A) × bed + A × W) per
  pixel, with the bed the land within 4 px of the shore carried in and W
  the deep water's colour, the water is mostly opaque (le01's A about
  0.9, le03's 0.96). The see-through part is a band at the shore. A
  follows the distance from the shore (correlation 0.56), not the depth
  the heights give (0.08), so it is baked from the art and not computed
  from the heights. The grain is white noise, so the layer's colour is
  the art with the lit bed taken out and divided by A, and keeps it.
- **The surface takes no cast shadow.** The heights put 52% of le01's
  water in shadow, yet the fitted light on it, s, is 0.99. The renderer
  mixes the bed, lit and shadowed as the land is, with the layer lit by
  the same sun without the shadow:
  mix(bed × light, layer × light unshadowed, A). The shadow shows only
  through the shallows, as in the art.
- **The colour under the water is the bed.** It was the art's water
  colour divided by the light; it is now the unlit bed carried in from
  the shore, so a painted level edits the bed and the water apart.
- **Without the layer** the water is the level's water colour, opaque,
  and now unshadowed too. That moved le01's shadow IoU from 0.920 to
  0.918; the others moved by at most 0.003.
- **Slot 10.** The layer is the renderer's eighth texture. `DrawMesh`
  binds slots 7–9 as cubemaps, so it is bound to slot 10 (BRDF,
  `map_slot()`).

With it the twelve are 0.3 to 2.2 levels from the art under the water,
with 0.98 to 1.13 of its grain (`terrain:compare` prints both, and
`terrain:report` has them per level). The weak spot is le01's shallows
under the right-hand cliff, which read darker than the art: the bed in
the cliff's shadow shows through thin water there, where the art's
shallows are lit. The layer is a still frame. An animated water shader
(Stage 10, or the renderer's own with no wind) would take it as its
colour and opacity.

### D58 — The level editor: a binary of its own, drawn by the terrain renderer, undo by tiles

Stage 7's editor is `deimos-editor`, built from `editor/` beside the game
and shipped in the same zip. It is a program of its own, not a screen of
the game: it opens GL windows of any size, needs no assets and no
simulation, and its UI is raygui, which the game does not use.

- **The viewport is the renderer.** `terrain.render_into` draws rows of a
  project into a render texture the caller owns, which `render` now draws
  its strips through too. `terrain.renderer_update` uploads one region
  again after an edit: grown by the smoothing's radius (⌈3σ⌉) and
  computed from the heights grown by twice it, so the upload is the same
  bytes as the whole project's (tests/terrain `an_update_is_a_new_upload`).
  The renderer's `max_height` became `surface_max`, which only rises: the
  shadow march reads it as a bound, so a bound too high marches further
  and changes no pixel, and an edit never has to scan the map for it.
  le07 renders byte for byte as before (the committed tool against the
  new, the whole map).
- **Undo keeps tiles, not maps.** A stroke keeps the 32 x 32 tiles of the
  heights and water layer it touches, before its first dab; undo swaps
  them back, so the same edit then redoes. Settings keep their value
  before, and a drag records once. 256 edits or 512 MB, the newest always
  kept. Stage 8's paint brush adds the splat weights to the tiles.
- **The water layer follows the ground.** Ground lowered under the water
  where the layer is clear gets the water's colour, opaque; raised out, it
  loses it. A shader rule that read a clear pixel as "no water" would have
  been simpler, but recovered layers hold clear pixels under water (2670 on
  le05), so it would have changed their render.
- **No prompt on close.** raylib cannot cancel a window close, so unsaved
  work is written to `<level>.unsaved.drproj.json` beside the project;
  Open and New discard only on a second press.
- **`sim.register_all()` is not called yet** (D50): the editor reads no
  unit definitions until Stage 8 places units, which will call it first.

### D59 — Recovered colour relit to its occlusion; water on the unsmoothed ground

Recovered levels drew darker than the art in the shadows under cliffs,
their shallows read wrong at the shore, and le03's open water showed
rocks the art does not have. Diffs of every level against its original
(the renders with the occlusion layer, as the game draws them) traced
each to a cause.

- **The colour is relit to the occlusion it is drawn with.**
  `terrain:recover` divides the art by the light the renderer will give
  it, but the occlusion is baked afterwards (by Flux, from that colour),
  so it was never in the division, and the game then darkened the art's
  shadows twice. The new `terrain:relight` step (`recover.py --relight`,
  CPU, no model) runs after `terrain:occlusion`. It fits the baked layer
  and divides the art again with it in the light. The fit: Flux reads
  the art's shadows as occluded (0.53–0.78, against 0.82–0.90 just
  beside them), so inside the detected shadows the layer is divided by
  its mean there over its mean within 24 px outside. Outside the water,
  it is floored where the art is brighter than the light would allow.
  The baked layer is kept as `cache/occlusion-baked.png` and a relight
  starts from it again, so it can be rerun. A new bake is needed only
  after `terrain:recover`, not after a relight.
- **The division keeps the hue.** Where the light is below the art, the
  colour is scaled by its brightest channel, not clipped per channel,
  which had turned bright land teal or grey.
- **The shadow's weight is soft and as wide as the shadow.** The penumbra
  the detector misses now counts in proportion to its ratio (0.66
  detected to 0.9 lit), which removes the dashed dark line at shadow
  rims. The ratio is the lower one of an 81 px and a 241 px window,
  because a shadow as wide as the small window darkens its own
  reference (0.83–1.03 on le01's cliff foot). Detection itself is
  unchanged.
- **The water layer lies over the bed as the renderer lights it**, with
  the shadow and occlusion, instead of the bed unlit. The first water
  pixel at the shore was 5–21 levels off and is now 1.5–5.
- **The water surface takes no occlusion.** Flux bakes occlusion onto
  the water too, from whatever texture it reads there, and le03's open
  water drew those rocks (deep water 2.9 levels off, now 0.07). The
  surface is lit by the sky and sun alone. Only the bed under it is
  occluded. This beats skipping the occlusion away from shores, because
  it needs no distance and no threshold, and a shore bed keeps its
  shading.
- **Water is decided on the unsmoothed ground.** The smoothed ground put
  the waterline up to the smoothing's radius into the bank, so a bank
  read as water, or the water as land, and only 44.5% of le01's
  shoreline matched the layer's mask. It now matches 100%, and agrees
  with the editor's water brush, which compares the raw heights. The
  land's normal comes from its visible surface, the water's height
  where the water is higher, so a bank's slope stops at the waterline.
  tests/terrain `water_follows_the_ground`.
- **No soft edge on the water mask.** With the layer over the lit bed
  and the waterline on the raw ground, the shore is already within a few
  levels of the art, and the layer's own opacity is the soft edge.

On all twelve, the share of land more than 20% darker than the art went
from 15–39% to 0.1–3.5%, and the land's error from 3.1–8.8 levels to
0.3–2.1. The art's old shadows, relit under an overhead sun, went from
0.45–0.90 of the ground beside them to 0.65–1.07. `terrain:report` now
scores the draw with the occlusion layer (shadow IoU 0.844–0.977,
before 0.714–0.890). The draw without it is kept as a reference column
(0.741–0.887): the colour now expects the layer. Weak spots: le02, le05
and le08's banks (about 9–10 levels off within 2 px of the water);
le07's jungle, whose shadows still read darker in the colour (0.74 of
the ground beside them); and le06 and le10, a little brighter
(1.2).

### D60 — Unit placement: the level's own list, undone whole, shown by the unit's flags

Stage 8's placement is the editor's Units tab (docs/level-editor.md).

- **The project holds the units as a list of its own.**
  `terrain.Project.placements` is lifted out of `level.placements` on open
  and written back on save, so the file format is unchanged. The record's
  slice is fixed and in the project's arena; the editor's list grows and
  shrinks.
- **Undo keeps the whole list, not a diff.** The list is a few hundred
  records at most (le07's 38 are 2 KB), and a copy cannot go wrong the
  way a diff of moves, deletions and insertions can. It uses the
  sliders' settle pattern: the list is kept once when a change starts,
  and recorded when the mouse is let go, if it differs. So a drag, a
  slide, a placement or a deletion is one undo, and a change back to the
  start is none. The history counts its bytes as the lists swap.
- **A placement's point is the one the spawn reads.** Ground x is the
  map's column; air x is the play field's, 32 columns into the map
  (`DAT_004e34b8`, named `sim.GROUND_PLACEMENT_SHIFT` for this). Whether
  a unit is on the ground is its unit's `is_ground_based`, which is what
  `spawn.odin` reads, not the record's layer. The layer is written from
  that on placing, and read only for a unit this build lacks.
- **The palette is the units with a preview face**: 134 of the 386,
  among them all 114 the twelve levels place. The chaingun's and New
  Weapons' units have none, and the editor imports no compiled plugin.
  The core names neither.
- **The look is a reading, not a recovery.** The original editor is not
  in the release. The preview face is used where
  `use_preview_appearance_in_placement_editor` asks for it or the first
  state draws nothing; otherwise the first state's sprite. That sprite
  faces the heading where `initial_heading_set_in_editor` is set, and
  shows its least frame elsewhere (the game rolls one). The heading's
  frame is the game's own: `sim.state_frame_for_angle` holds
  `G_Entity::GetFrameForAngle`'s rounding, and `lifecycle.frame_for_angle`
  calls it.
- **Only a heading that counts is editable.** The spawn takes the
  placement's heading only for `initial_heading_set_in_editor` units, so
  only they get the slider and the Q and E keys.
- **`sim.register_all()` arrives** (D50). The editor's `main` discovers
  and declares the data plugins and registers, then loads the definitions
  and sprite plates from `$DR_ASSETS`. Without them the palette is empty
  and the tab says so.

The two changes to `sim/` move code and name a constant. `oracle:diff`
is exact, and tests/golden is unchanged.

### D61 — Materials: images kept beside the project, hex-tiled, a library quilted from the recovered ground

Stage 8's materials are the editor's Paint tab (docs/level-editor.md).

- **A material's image lives beside the project**, under `materials/`,
  written by `terrain.project_save` from the image in memory. A dropped
  file is copied, not referred to, so a project stands alone and an
  export takes the folder whole. It is scaled to 1024 px at most.
- **Image materials are always hex-tiled** (Mikkelsen 2022), with
  offsets but no turns. The originals' ground never repeats, and an
  image repeating every tile was the first thing to see. Turns would
  scatter a photograph's light. Provisional: a per-material switch for
  turns, if a material wants them.
- **Without an unlit colour, the first material is the ground under the
  rest.** What the weights leave short of full is its. Before this, the
  weights were scaled up to full, so a light stroke showed as all of its
  material. A recovered level keeps its unlit colour under the weights,
  as before.
- **Undo keeps the weights in the heights' tiles**, 12 KiB a tile now.
  Adding or removing a material keeps the materials as a value, with
  their images and the rules that name them. The images are in the
  project's memory, which outlives the history.
- **The library is made from the recovered levels, not the installer.**
  `mise run materials:library` quilts it from `work/recovered`, into
  `assets/materials`, committed as the assets tree is (D29). `assets:all`
  cannot make it: it needs the recovery's models. Every entry is tagged
  `original-derived` and records its level, window and size.
- **Quilting takes a block within 30% of the best**, not the paper's
  10%, which repeated the red dust's pebbles in a 256 px tile. The quilt
  wraps, so it tiles on its own before the hex-tiling.
- **The level record keeps the originals' description, copyright and
  briefing**, which the records had and the game's type dropped. The
  Level tab edits them; the game does not show them yet.

The game's code is unchanged but for the three fields it reads and does
not use. `oracle:diff` is exact, and tests/golden is unchanged.

### D62 — Structure bases measured from the maps by correlation; the vents' detector kept by rule

Stage 8's structure footprints and helpers (docs/level-editor.md).

- **A base is found by how its crops correlate, not by their colours.**
  The same base is drawn in each map's light and tint, so crops of it on
  desert and on grass differ in colour, and a colour test missed 7 of
  the 10 bases a montage showed. Each crop's brightness is taken
  relative to its own mean and spread. A type is baked when its crops
  score 0.5 or more and 0.25 over the ground beside them. Provisional:
  the bar is set from the one table there is, where the single-image
  bases score 0.71–0.94 and the rest 0.49 or less.
- **The bases are committed assets**, in `assets/bases`, made by `mise
  run levels:bases` from the Classic Levels maps, which are themselves
  extracted (D29). They are regenerable from an installer copy.
- **A base is drawn unturned**, whatever its unit's heading: the maps
  show no base turning with its heading (the hospital's agree unturned;
  turning crops by heading lowers every score).
- **The vents' detector is the editor's to keep.** In every original,
  the one detector counts all the level's vents and sits on the
  northmost. When the vents change, the editor puts it back on that rule
  in the same edit, and leaves it alone otherwise, so an original opens
  and saves unchanged. The detectors' counts are hardcoded
  (`editor/helpers.odin`), from their rules' ranges.

The game is unchanged. `oracle:diff` is exact, and tests/golden is
unchanged.

### D63 — Scenery models: meshes drawn into the map's light, a CC0 library shipped, profiles in the user's data

Stage 8's scenery models (docs/level-editor.md).

- **Vegetation is 3D models, not painted colour.** The originals' trees
  were rendered from models into their maps, and an albedo that good is
  far harder to paint than models are to scatter. Each instance is its
  mesh drawn straight down into a layer of colour, top height, normal
  and underside height. The terrain shader lights the layer, and the
  sun's march is blocked between underside and top. So the models'
  shadows are in the lit map that Stage 9 exports. The models are not
  baked into sprites, as the plan had it: the project owner wanted
  their real shadows. A lean is then just a rotation.
- **3 map pixels a metre**, models life size: le11's palm crowns are
  about 30 px across, and a real one is 8-10 m. Provisional, until
  Stage 9's export is compared with the originals.
- **The library is committed and ships in the zip.** It is in
  `assets/models`, 27 Poly Haven models (CC0) in 16 MB. The project owner
  wants the editor usable from the release zip as it comes. The library
  is regenerable: `models:fetch` downloads the sources into a cache
  outside the repository, and `models:library` rebuilds the same bytes.
  To keep it small, its images are 256 px, with the cutout's coverage
  kept (Castaño 2010), and its models are under 10,000 triangles, or
  20,000 for a tree. CREDITS.md credits every model and carries Poly
  Haven's "Powered by Poly Haven".
- **Heavy models are simplified by clustering, with leaves treated as
  leaves.** Vertex clustering is quick and keeps the cover from above,
  which is all the layer draws. Pieces smaller than two cells are
  clustered on their own grid, and thinned with the kept ones grown, so
  a crown keeps its cover. Imports are brought under 60,000 triangles.
  Provisional: no frame-time budget has been measured.
- **The cutout reads the full-size texels**, not the mipmaps, whose
  averaged alpha drops thin leaves under the cutoff.
- **Profiles and imported models are the author's, in the user's
  data**, as the game's progress is: `editor/brush-profiles.json` and
  `editor/models/`. A project keeps a copy of each model it uses, in
  `models/`, so it stands alone. The user-data path moved from `game/`
  to `prefs/`, so the game and the editor share it.

The game is unchanged. `oracle:diff` is exact, and tests/golden is
unchanged.

### D64 — Campaigns built in the editor: a campaign file, exports the editor marks as its own, ids that carry the campaign

Stage 9's export and Play (docs/level-editor.md).

- **A campaign is a file of its own**, `<name>.drcampaign.json`, holding
  the plugin's words and switches and its levels' projects in play
  order, saved relative to it. A campaign's levels are its own
  projects, and one project can be in two campaigns, so the list is
  not part of any project. The plugin is the export, made again from
  the file at any time, and the projects are not copied into it.
- **The editor writes only into a plugin it made.** Its `plugin.json`
  carries `"made_with": "deimos-rising level editor"`. An export into a
  folder whose manifest lacks it is refused. So is the name
  `classic_levels`. Within its own folder, an export removes the records
  and images of levels taken out, which would otherwise still be found
  by identifier.
- **Image ids carry the campaign's name**, as `<campaign>_leNN_map`,
  `_preview` and `_mask`. im16 ids are one namespace across all plugins,
  the first found winning (data.plugin_media_add). Level ids stay
  `le01` to `le99` in play order, as a campaign's levels are its own
  (D53).
- **Nothing is written while a level cannot play.** Every level is
  checked first: its identifier, unique in the campaign; its width; its
  units and start weapons, whose plugins become the campaign's
  dependencies; and provenance. Warnings (no name, no music) do not
  stop it.
- **Provenance is by tag and by layer.** "Free of the originals' art"
  is refused when a material or model is tagged `original-derived`, or
  when the project has a colour, water or occlusion layer. Only the
  recovery tools make those layers, from the original maps. A layer the
  editor can make itself will need a mark of its own.
- **Play is an export into the user's data**, as the campaign
  `editor_play` in `editor-play/`, never into a plugins folder the game
  searches unasked. The game is started beside the editor with
  `-plugins`, `-campaign`, `-level` and `-row` (D54). Its view's bottom
  is where the editor's is.
- **The preview's look is fitted, not hand-tuned**, by `tools/preview_fit`
  from the originals and generated into `terrain/preview_look.odin`. The
  crop is the project's own (project version 3).

The game is unchanged. `oracle:diff` is exact, and tests/golden is
unchanged.

### D65 — Recovered Levels is an editor campaign, exported as any other

Recovered Levels was packaged by a script of its own
(`tools/terrain_mod/package.py`), which drew each recovered project's map
and copied the original's record with only its map changed. The record
named the original's preview and mask, but the game reads a campaign's
masks only from the campaign's own folder (data.levels_append), so the
levels played with no water.

- **It is now a campaign file**,
  `tools/terrain_mod/recovered_levels.drcampaign.json`, and
  `terrain:mod` is the editor's `-export`. Recovered Levels gets what
  every editor campaign gets, and fixes to the export reach it too: a
  media mask from the project's water, a preview, the checks, and a
  `plugin.json` the editor marks as its own.
- **The preview crop is the original's.** `terrain preview` sets each
  project's crop where its original preview was cut from its original
  map, with `terrain.preview_locate`, the template match
  `tools/preview_fit` uses. `terrain:recover-all` runs it, so a crop
  chosen later in the editor is not overwritten by `terrain:mod`.
- **Level ids follow play order** (`le01` is Lucena), as in every
  editor campaign (D53, D64), and no longer the originals' numbers. The
  game numbers levels by play order, and high scores and `-level` find
  them by identifier. Only `-level` given an id (`le01`) now names
  another level.

The maps are pixel for pixel the ones the script drew. The masks match the
originals' at 0.945–0.981 IoU. The game is unchanged.

### D66 — Companion plugins: what two plugins add together

Some content belongs to two plugins at once: upgrades for New Weapons'
weapons need Passive Upgrades for the upgrades and New Weapons for the
weapons. Neither plugin should carry it, or a player could not keep
both and turn it off. As a plugin of its own that depends on both, the
existing kinds fit badly. Default-on, it would bring Passive Upgrades
in for every new player, and the lobby's New Weapons switch would turn
Passive Upgrades on. Off by default, nobody would find it.

- **A companion** (`sim.Plugin.companion`) is on wherever its
  dependencies all are, and never brings them in. It comes on as the
  last of them does (`sim.mods_switch_on`), which is what every "turn
  this on" path now calls: the Mods page, the lobby, Level Select's
  Easy Mode switch, launch flags, and an older build's Start flags. A
  player turns it off alone. Turning something else on does not bring
  it back while its dependencies stayed on.
- **Saved as off, not on.** Preferences list a companion on a
  `mods_off=` line when its dependencies are on and it is off. One
  that the file does not mention comes on with its dependencies, so a
  companion new to the build reaches a player who already has them. An
  older build ignores the line.
- **New Weapon Upgrades** (`plugins/new_weapon_passives`) is the first.
  It registers Weapon 5 and 6 (`passives.passive_register`), which
  Passive Upgrades carried before. They keep their names, so the icons
  and the golden runs, which go by name, are unchanged.
- **A plugin owns its tests**, in `plugins/<name>/tests`, a package with
  its own `@(init)`. `mise run test` runs each, `check` vets them, and
  `coverage` counts them. The helpers every package shares are in
  `tests/support`. A test in `tests/` that asked for a plugin's content
  moves there as that plugin's tests are next touched.
- **Every plugin folder with code must be imported by
  `game/plugins.odin`**, or nothing registers it. A test now says so:
  the new plugin was missing at first, and only a golden run's reward
  pool showed it.

### D67 — A weapon's charge is a stat scope of its own

notes/extra-weapons-and-passives-3.md asks for passives that change each
weapon's charge attack, beside the passives that already change its shots.
The two must not leak into each other. The Ion Cannon's passive makes its
shots start slow, and its charge's bullets must not; a charge passive's
extra damage must not reach the shots.

- **Two scopes.** A stat provider is asked for a weapon's stat either
  for its shots or for its charge (`sim.Stat_Provider`'s `charge`). The
  charge covers how it climbs (Maximum_Charge, Charge_Rate, the overheat)
  and the shots its release fires.
- **Tagged at the release.** The shots a release fires are tagged with
  the scope (`stats.shape_spawn`, `Shaped.shaped_charge`), and what they
  spawn inherits it, as it inherits the weapon. So the same stat
  (Projectile_Damage, say) means the shots' in one scope and the
  charge's in the other.
- **Passives.** A charge passive (`Passive_Def.charge`) counts in the
  charge scope only, any other weapon passive in the shots' only, and a
  ship passive in both (`passives.passive_applies`). No shipped passive
  changed scope: the weapon passives touch no charge stat, and Improved
  Charge is a ship passive.
- **The Discharge Beam's release** is a plugin's own (`Weapon_Fire.release`)
  and keeps reading its damage and width in the shots' scope. Its passive
  was tuned with the release sharing them, as plugins/new_weapon_passives
  records.

### D68 — The ground weapon's charge is a plugin's, apart from its power-up

notes/extra-weapons-and-passives-3.md gives the ground weapon a charge
attack, aimed by a crosshair that turns about the ship. The original's
one ground weapon has no power-up, and the ground power-up it might have
had (0x44741a) is not ported.

- **Its own state.** The charge is held in `Weapon_Handler.ground_charged`,
  not in `ground_powerup`. The original's release of a ground power-up
  also ends the air one's overload. Kept apart, the charge cannot reach
  that, or be mistaken for the unported power-up.
- **Only where there is no power-up.** A ground weapon whose data has a
  power-up still reports it unported, charge or not.
- **Its stats are the charge's scope (D67).** The bomb it drops is tagged
  as the charge's, so a passive that makes it heavier leaves the burst as
  it was.
- **The crosshair's turn is the handler's** (`ground_aim`), so a rollback
  restores it with the rest. At 0 the crosshair is placed by the
  original's code untouched.
- **Ready after half a second.** Let go sooner, the charge drops nothing
  (`stats.ground_charge_ready`). The DPS report's first runs had a heavy
  bomb dropped the moment a charge began, straight ahead, outdo the burst
  it was added to; it now comes when the crosshair is round behind.

### D69 — Alternative passives give each other up

The notes ask for a second ground charge that "replaces other passive when
picked", and for the first to replace it the same way.

- **A group, not a pair.** `Passive_Def.exclusive` names a group; any
  passive may join one, another plugin's too. Taking a passive of a
  group drops every other held (`passives.passive_take`).
- **From level 1.** The one taken starts at level 1, as any new passive
  does. Carrying the levels over would let a player switch for free, and
  the two charges are tuned level for level, not as one.
- **Offered as before.** An alternative is offered while its own levels
  are not maxed, whatever its group holds. The reward screen names the
  passive it would give up.
- **The gain behind.** The ground charges add DPS only behind the ship,
  where the bare bomb reaches nothing. The DPS report's Gain is now the
  change in DPS averaged over all four scenarios, so that counts. It was
  averaged over the scenarios the bare weapon reaches, with the backwards
  bomb measured behind against its single target ahead. No other
  passive's Gain changed: none of them reaches a scenario its bare
  weapon cannot.

### D70 — A beam is a list of runs, and its chain is a stat

notes/extra-weapons-and-passives-3.md asks for a Discharge Beam charge
upgrade whose beam "chains to the next closest enemy that has not already
been hit" in place of piercing straight on.

- **Runs, not one line.** `beam_fire` pushes one `Beam_Event` for each
  straight run, from `from` to `to`, and the view draws each at any
  angle. A straight beam is still one run, from the gun to where it
  stopped, so the event a beam was before is the first run of a chain.
  The events and the log (`Beam_Log`, up from 32 to 64 entries for a
  chain's runs) are presentation; the state and the goldens are as
  before.
- **A core stat.** `Chains` is a toggle in the core's Stat enum, read in
  the beam's scope (D67), so a pulse passive or a charge passive can
  turn it on. It names a way a shot cast as a line behaves, not the
  passive that grants it.
- **The nearest from the kill, on screen.** "Next closest" is measured
  from the target just killed, among those an air shot can hit that are
  on screen and not yet hit. Ties go to the lower entity number, so a
  rollback picks the same target.
- **The same stops.** A chain ends where a straight beam would: a target
  left standing, one the hit delay protects, or the damage spent. Its
  damage is carried the same way, so against one tough target a chained
  beam deals what a straight one does.

### D71 — A release ramps up to the hit delay, not past it

notes/extra-weapons-and-passives-3.md asks for a Chaingun charge upgrade
whose "firing speed ramps up as it fires".

- **A core stat.** `Release_Ramp` is a percentage each spawn a release
  has fired adds to its pace (`stats.powerup_release_due`), in the
  charge's scope. At 0 the release is timed by the original's own test.
  The Powerup counts the spawns (`released`) and the pace restarts each
  time it lets go (`weapon_system.powerup_let_go`, now the one place the
  air and ground power-ups and a release at max let go).
- **Capped at the hit gap.** One target takes a hit every
  `sim.hit_gap` steps at most (the original's Entity_HitDelay, now
  named `PF_ENTITY_HIT_DELAY`). Ramped to a spawn a step, the Chaingun's
  release lost 20% of its DPS in every DPS report scenario, the wave
  too. The shots past one target's hits were wasted, and the release
  was spent sooner. So the ramp stops at a spawn every hit gap.


### D72 — Overcharge lanes fan out from the release's level

notes/extra-weapons-and-passives-3.md asks for a Photon Beam charge
upgrade whose release "gains 2 extra projectiles for every x charge over
the base amount", falling back to the base "as the charge level
depletes".

- **A core stat.** `Overcharge_Projectiles` is a toggle in the charge's
  scope (D67). `stats.overcharge_lanes` turns the level a release fires
  a spawn at into 2 lanes for every `OVERCHARGE_STEP` (25%) of the
  weapon's own max power level it stands over. A release counts its
  levels down, so the count falls with it, and only a higher max charge
  takes a release over at all.
- **Carried on the spawn.** The release's spawner is spawned at one
  level and fires its lanes later, when the handler's level is no longer
  its own, so the count is a field on it (`Shaped.overcharge`, set from
  the spawn request) rather than a stat it reads. `shaped_spawn_child`
  adds the pairs after `Extra_Projectiles`' lanes, from the outermost,
  each `OVERCHARGE_FAN` degrees wider. They are not passed on to what
  the lanes spawn.
- **The default release only.** A weapon whose release a plugin fires
  (`weapon_fire_register`) has its own volley, and does not fan out.
  Without the stat the field is 0, and every release is the original's:
  the goldens did not change until the passive was offered.

### D73 — A wearing shot gives its damage and takes no hits

notes/extra-weapons-and-passives-3.md asks for a Rear Gun charge upgrade
whose bubbles "reduce in size when they damage enemies until they run out
of damage to give", each level making them "larger and longer lasting".

- **Two core stats.** `Shot_Scale` multiplies a shaped projectile's
  states' scales (`Shaped.size`, in `appearance_stage`), and so what it
  reaches. `Wears_Down` is a toggle: the shot has its damage times its
  size to give (`stats.wear_pool`, kept in `Shaped.wear`). Both are
  read in the shot's own scope (D67), so a pulse passive or a charge
  passive can grant them, and name how a shot behaves, not the bubble.
- **No hits taken.** In the original a shot meeting a target takes the
  target's damage against its own shields, so a bubble nearly always
  bursts on its first hit. A wearing shot takes none, either way round
  (a player's shot or one an enemy's shot can hit). Its own hit gives no
  more than it has left and spends what the hit dealt, so one turned
  away by the target's hit delay flies on with all of it
  (collision_system's `shot_hit`).
- **Its size shows what is left.** The shot shrinks in proportion to
  what it has left, to no less than `WEAR_MIN_SIZE`. Once spent it is
  destroyed, as the hit back would have destroyed it, with its own
  destruction effects.
- Without the stats both fields are 0 and every collision is the
  original's two hits: the goldens did not change until the passive was
  offered.

### D74 — A shot's hit can leave something behind; lingering harm is not a hit

notes/extra-weapons-and-passives-3.md asks for a Bacta Gun charge upgrade
whose hits "create corrosive clouds which linger for (2 seconds base)",
which "deal small amounts of damage to enemies inside them".

- **A hook after a shot's hit.** `Shot_Hit` (`shot_hit_register`, in
  `sim/hooks.odin`) is run by collision_system after a shaped player
  shot's hit, with the damage it dealt: 0 when the target's hit delay
  turned it away. The core names no cloud: a plugin decides what follows
  a hit, in the shot's own scope (D67).
- **Lingering harm is not a hit.** `collision_system.entity_damage`
  takes shields without the hit's delay, glow, sound, particles or
  collision spawn, and emptying them does what a hit's would (score,
  then destruction or the depletion state, now `entity_depleted`, shared
  with `entity_hit`). Using `entity_hit` for a cloud would start the
  target's 2-step hit delay each step and turn the shots away, so the
  cloud would cost more than it gave.
- **The clouds are plugin state.** Passive Upgrades keeps them in the
  session (`passives.Clouds`, a ring of `MAX_CLOUDS`), so a rollback
  restores them, and harms from its own system between the entities and
  the sweep. Its view reads them from there, so a rollback's clouds draw
  as they are. Two stats name what the passive grants: `Hit_Cloud` and
  `Cloud_Lifetime`.
- Nothing calls a `Shot_Hit` that no plugin registers, and
  `entity_damage` has no caller in the core: oracle:diff and the goldens
  did not change until the passive was offered.

### D75 — An air shot can hit the ground, for a share of its damage

notes/extra-weapons-and-passives-3.md asks for an Ion Cannon charge
upgrade whose "fired projectiles can also hit ground targets, damage is
reduced but the penalty goes down each level".

- **Two core stats.** `Hits_Ground` lets a shaped air shot hit ground
  targets as well as air ones. `Ground_Damage` scales its damage to
  them. Both are read in the shot's own scope (D67). The share is set on
  the shot as it spawns (`Shaped.ground`, `stats.ground_share`), so
  `entity_collisions` tests it against the ground targets it overlaps
  (`ground_shot_targets`, the ground's counterpart of
  `air_shot_targets`), and `collide_entities` scales the damage it deals
  them.
- **A hit like any other.** The target hits the shot back, as an air
  target would, so a shot spent on a tank does not fly on to the air
  enemy past it. Air shots and ground units are drawn on different
  layers, but they share the play field's coordinates, so the overlap is
  the same test.
- **Measured on its own target.** The DPS report adds a ground target
  for an air weapon with such a passive. The bare weapon deals nothing
  there, so it adds only what the passive reaches, and the averages
  stay over the four scenarios, as a target behind does: no other
  passive's row changes.
- Without the stat the share is 0 and every shot's candidates and
  damage are the original's: the goldens did not change until the
  passive was offered.

### D76 — A plugin's audio may be compressed

The level editor is to import music into the levels it exports, and a
track kept as WAV is about 10 MB a minute: `mu03`, 196 s, is 34 MB. D6
kept the extracted audio WAV because nothing in Odin's vendored libraries
encodes Vorbis, but the game only has to decode, and raylib as built
decodes WAV, Ogg Vorbis and MP3 (its FLAC decoder is not built in).

- **What.** A plugin's `audio/` may hold `<id>.wav`, `<id>.ogg` or
  `<id>.mp3` (`data.AUDIO_EXTENSIONS`). An id with more than one is the
  first of those; the first plugin with an id still keeps it.
- **The core tree stays WAV**, as extracted. A plugin's file is not taken
  for an id the core has a `.wav` of, whatever its own extension, so
  images and sounds still add and never replace (D51).
- **Nothing else changes.** Plugin audio was already loaded by path, as a
  stream for music and decoded whole for a sound effect, and both of
  raylib's loaders take all three.
- `plugin_audio_kinds_decode` loads a quarter second of each from
  `tests/fixtures/audio`, made with ffmpeg, so a raylib built without one
  fails on CI's Linux and Windows runs.
