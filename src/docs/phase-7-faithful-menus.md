# Phase 7 — Faithful menus

Replaces Flow's plain-text stand-in (D18, Phase 5) with the original's actual
menu screens: real backgrounds, sprite-plate buttons, the level-select
carousel with preview thumbnails, credits, high scores, and a minimal pause
that matches the original's own (near-total) absence of one. New menu items
(Phase 6's netplay lobby) are added in the same visual style and hidden
whenever `-classic` is passed. See D21 for the scope decision and its
exclusions.

## What the original does

Read from the decompiled corpus, not guessed (a background research pass read
every function named below in full; see D21 for the full method note):

`_WinMain_16` calls `G_Interface()` once; that single call is the whole
running game (menus and gameplay together), returning only at quit.
`G_Interface_025fd0.c` is two things at once: the native Win95 menubar/window
chrome (out of scope, unchanged from today), and the dispatcher for a
**custom-drawn main menu** built by `FUN_004277e0` and its sibling
`FUN_00427xxx` helpers — this is the real title screen, not a separate
function.

**Main Menu / Title** — full-screen background (`back.png`), a static logo
sprite (`GALO`, sprite plate, 1 frame), a vertical stack of baked-text button
plates (`MEBU`/`MEBH`, 14 frames each — normal/hilited pairs — one frame per
button; the button-list build (`FUN_004277e0`) fixes the mapping):

| slot | frame (MEBU/MEBH idx) | label | handler |
|---|---|---|---|
| 1 | 0 | 1 PLAYER | `FUN_004284d0` |
| 2 | 1 | 2 PLAYER | `FUN_00428500` |
| 3 | 2 | PREFERENCES | `FUN_00428590` → native `U_Prefs_Dialog` |
| 4 | 4 | HIGH SCORES | `FUN_004285c0` → `G_Scores_Display` |
| 5 | 5 | PLAY DEMO | `FUN_00428530` |
| 6 | 6 | QUIT | inline (sets quit flag) |
| 7 | 7 | REGISTER/ACTIVATE | `FUN_00428930` — **excluded**, only shown unregistered |

Frame index 3 exists in both plates but is never referenced by the main
menu's button list — its baked text is "CONTROLS" (confirmed by cropping the
frame directly during Stage 2's research pass, correcting an earlier guess of
"REPLAY LAST GAME"), but no confirmed menu entry point calls it (not
blocking, revisit if a use turns up). Two more links
draw as plain text, not plate buttons: a website URL (`U_App_LaunchURL`) and
a copyright line that opens Credits — the same line the excluded registration
nag periodically overwrites with its own message, confirming the nag is
layered onto this link rather than being a separate screen.

Layout: `Interface_Btn_StartYLoc` (168) + `Interface_Btn_VerticalGap` (30) per
slot, `Interface_Btn_HiliteDelay` (10 ticks) before a hover counts as
"hilited". Exact logo position and per-button X centering were not pinned to
a perm float (`FUN_00427cb0` only allocates the button record; layout math
lives in the draw/hit-test helpers, `FUN_00426cc0`/`FUN_00427dc0`, not fully
traced) — built by best inference (centered horizontally, logo near the top)
and treated as provisional until checked against a live screenshot of the
original (see Stage 1).

**Level Select** — `G_LevelSelect_GetStartingLevelIDFromUser` (read in full)
plus `Priv_Preview` (all files read in full): a 3-slot horizontal carousel,
background `lese.png`, left/right arrows rotate it, the center slot is
"current". Clicking center either accepts (unlocked: grow-pulse animation,
`LevSel_Acceptance_MaxScale` 2.0 / `ScalingRate` 0.18, sound `LevelSelectChoose`
— perm sound 0xc) or rejects (locked, gated by highest level reached or by
`G_Level_GetNumLevelsInDemo` in a shareware build: pulse animation,
`LevSel_Failure_MaxScale` 2.0 / `ScalingRate` 0.25, sound `LevelSelectFailure`
— perm sound 0xe) the level. Each level record already carries its own
`preview_image` (`src/assets/data/levels/le0N.json`), resolving directly to
`src/assets/images/im16/{cap,isp,jup,inp}{1,2,3}.png`. Positioning:
`LevSel_FirstPreviewXLoc/YLoc` (55, 76), `PreviewXSpacing/YSpacing` (191, 0).
Selection feedback text reuses the in-game `G_Notice` popup mechanism
(`LevelSelect_Notice_*` perm floats), not a separate widget.

**Cut, not built**: a mission-briefing screen has full text/timing perm data
(`Briefing_*`) but zero code reads it, and every shipped level sets
`briefing: "none"`. Not part of this phase.

**Credits** — `G_Credits_Display` (read in full): background reuses `back.png`
(same as the main menu, not a dedicated image), text from PAK table `cred`
(`src/assets/data/stli/cred.json`), `<title>`/`<page NNN>` markers control
per-page duration, fade in/out, layout `Credits_TitleYLoc` (130) /
`Credits_VerticalGap` (16). Any key/click advances; **N** exits straight into
a new 1-player game (same convention high scores uses).

**High Scores** — two screens, both read in full: `G_Scores_Display` (a pure
viewer, 15-row table, background `back.png` again) and
`G_Scores_GetPlayerNamesAndDisplay`/`FUN_0043bb00` (name entry, shown
automatically when a game-over score makes the top 15 — no separate "results"
screen exists in between; the caller chain goes straight from `G_Game_Play` to
this). Name entry has a live blinking-caret text field and hard-coded joke
substitutions for specific typed names (e.g. "DILVISH" → "Just Ship It, Baby",
an empty name → "Jar Jar Must Die") — worth preserving as an authentic detail.
**N** exits into a new game here too.

**Pause** — `G_Interface_PauseGame` (read in full, 71 lines): stops sound,
plays a pause cue, pauses music, freezes in an idle spin, then darkens the
screen borders. **No "PAUSED" text is drawn anywhere in this function**, and
nothing else in the corpus draws one either. Per the project owner's call
(D21), the faithful version matches this: freeze + darken, no label.

**Preferences** — a genuine native Win32 `DialogBoxParamA` (`U_Prefs_Dialog` →
`U_Configuration_Configure`), standard OS controls. Nothing to port
pixel-for-pixel; `-classic`'s settings screen (netplay host/join, etc.) is
designed fresh in the same button style as the rest of this phase instead.

**Confirmed not in scope** (D21): the registration nag (`U_Registration`/RT3)
and the exit-time ad (`G_Interface_DisplayAd`) — shareware-only, excluded;
the dev/cheat console (`G_Console`) and the level editor — real UI, but
hidden developer tools, deferred to a "Bonus — Developer tools" phase
(`docs/README.md`) rather than being part of faithful player-menu recreation.

## Stages

1. **Menu widget plumbing + Main Menu** — a generic loader for full-screen
   `im16` images not tied to a level (`back.png`, `lese.png`, …); a button
   widget wrapping a plate frame pair (normal/hilite) with hover/click
   detection; the Main Menu screen itself with the 6 in-scope buttons plus
   the two text links, replacing `flow.odin`'s `draw_title`. Verified
   interactively (`xvfb-run` + `xdotool` + screenshots), the same method
   Phase 5's Flow work used.
2. **Level Select** — the 3-slot carousel, preview thumbnails, accept/reject
   pulse animation and sounds, lock-gating by highest level reached. Wired in
   ahead of session start for the 1/2-player buttons (today, Flow starts a
   session directly and always plays levels in list order — this is what
   changes).
3. **Credits** — paged text display, background reuse, N-to-new-game.
4. **High Scores** — the 15-row viewer and the name-entry screen with its
   easter-egg substitutions, wired in after a game ends.
5. **Pause, faithfully minimal** — drop Flow's "PAUSED" banner; freeze and
   darken only, matching the original's actual (near-total) absence of a
   label.
6. **`-classic` gating for new items** — the settings screen and Phase 6's
   netplay lobby (host/join, ready-up, ping) are the only "new" menu items
   this project adds; built in the same button/plate style as stages 1-5,
   hidden whenever `settings.classic` is set (`game/render.odin`'s
   `Renderer.classic` already carries this flag through; nothing has read it
   until now).

## Exit

Every original menu in scope (Main Menu, Level Select, Credits, High Scores,
Pause) renders with the original's actual art and behaves per the traced
functions above; `-classic` hides only the new netplay items, never any of
the faithfully-recreated originals; `oracle:diff` and the existing test suite
stay green throughout, since none of this touches `sim/`.

## Progress

**Stage 1 — done.** `game/menu.odin` (shared widgets: `Menu_Button`/`Text_Link`
hover+click detection, `menu_draw_text` — a direct-draw glyph proc for screens
outside the `Renderer` layer/present pipeline, `menu_draw_background`,
`menu_image` caching in `game/assets.odin`) and `game/menu_main.odin` (the Main
Menu itself: `back.png` background, `GALO` logo, the 6 in-scope buttons at
`Interface_Btn_StartYLoc`/`VerticalGap`, website/copyright text links, a
minimal text-based "visit website?" confirm in place of the original's native
dialog). `flow.odin`'s `draw_title` is gone; `.Title` now runs through
`main_menu_update`/`main_menu_draw`, and `flow_init` takes the `Renderer` it
needs to load textures. `flow_start_session`/`flow_load_demo`/
`flow_random_seed` were un-privatized for the menu's buttons to call.

Two provisional layout values (both un-pinned to a perm float — see "What the
original does" above) were corrected against a real screenshot of the
original rather than guessed further; see "Verification" below for the
pipeline and the final `BTN_FIRST_ROW_Y :: 186` / `LOGO_Y :: 47` values.

Verified interactively (`mise run build`, then `xvfb-run` +
`xdotool`/`import`, the same method Phase 5's Flow work used, not just a
headless build):
- Background/logo/buttons/links all render with no overlap.
- Hovering a button (mousemove to its computed rect, e.g. "SCORES") shows the
  MEBH hilite plate in place of MEBU.
- Clicking (via `xdotool mousedown`/`mouseup` — `xdotool click` alone did not
  register; the window needs `xdotool windowfocus --sync` first, an
  xvfb/xdotool quirk, not a game bug) dispatches correctly: "1 PLAYER"
  transitions `.Title` → `.Playing` (a level starts, HUD renders), and "QUIT"
  sets `fl.quit` and the process exits cleanly.

`mise run check`, `mise run test` (85 tests) and `mise run build` all green;
nothing under `sim/` touched.

## Verification

Interactive `xvfb`/`xdotool` checks (above) confirm behaviour, but not
pixel-accurate layout — the plan is to eventually hold every faithfully-ported
menu to a real screenshot of the original, the same way `tools/oracle/shot.sh`
+ `compare.sh` already do for gameplay frames. Stage 1 built the menu
equivalent of that pair:

- `mise run oracle:menu-shot MENU=main` (`tools/oracle/menu_shot.sh`) drives
  the original under Wine/Xvfb to a named menu screen (a `case "$MENU"` click-
  through sequence per screen — "main" needs nothing, since the original boots
  straight to it) and captures it to `work/wine/menus/<name>/orig.png`.
- `mise run menu-shots:compare MENU=main` (`tools/oracle/menu_compare.sh`)
  builds our binary, renders the same named screen headlessly via
  `DR_MENU_SHOT=<name>` (`game/main.odin`'s `run_menu_shot`, which drives
  `Flow` to the right mode and exports one frame — a menu has no simulation to
  step, so there's exactly one frame, unlike `DR_SHOT`'s per-step gameplay
  captures), and writes `work/shots/menus/<name>/{ours,ours-norm,side,diff}.png`
  plus an ImageMagick `compare -metric AE` score. Per AGENTS.md ("Look at the
  output"), the AE score is a quick regression signal, not a pass/fail gate —
  `side.png`/`diff.png` are the actual check.

Both tasks depend on Wine (`oracle:menu-shot`) or a full build+Xvfb round trip
(`menu-shots:compare`) and take several seconds to tens of seconds, so neither
is in `[tasks.ci]` — same convention as the existing `oracle:*`/`shots:compare`
gameplay tasks, which `mise run ci` (`check`+`purity`+`test`) already excludes.

Running this against Stage 1's Main Menu found two real layout bugs the
interactive check above had missed, both fixed by measuring column-brightness
profiles of `orig.png` vs. `ours-norm.png` (`magick ... -crop 1xH+X+0 txt:-` to
find where a bright run — a button label or the logo's limb — starts) rather
than eyeballing:
- Button rows rendered a full `Interface_Btn_VerticalGap` (30px) too high.
  `BTN_START_Y :: 168` (the raw perm float) plus naive `slot * gap` was wrong;
  the real first-row rect sits at `BTN_FIRST_ROW_Y :: 186`, one whole gap below
  the perm float, back-computed from the label's measured centre (198) via
  this port's own frame-to-label offset. `StartYLoc`'s exact original meaning
  was never fully re-derived (`FUN_004277e0`'s layout call wasn't fully
  traced); this reproduces the measured position instead.
- The logo sat 7px too high: the globe's bright limb starts at y=47 in the
  original, not the guessed y=40 (now `LOGO_Y :: 47`).

After both fixes, `menu-shots:compare MENU=main` shows only antialiasing-level
edge noise on buttons/logo, a faint uniform outline on the background
watermark (a raylib-vs-native-GDI rendering/colorspace difference, not a
position bug), and the expected, correctly-absent REGISTER row (D21) — judged
a good match by inspecting `side.png`/`diff.png` directly.

**Stage 5 — done, folded into stage 1's `flow.odin` edit.** Flow's old
`.Paused` case (`draw_banner("PAUSED", ...)`) is replaced by
`draw_paused_borders`, a screen dim with no text — see D21 and the file
comment on `draw_paused_borders` for the exact-vs-approximated caveat
(the original blacks out two perm-float-sized strips via
`U_Display::DrawBlackBorders`; this approximates that as a full-screen dim
rather than claiming pixel-exact border geometry).

**Stage 2 — done.** `game/menu_level_select.odin`: the 3-slot carousel
(`LS_RECTS`, `LevSel_Button_Previous/Current/Next`), left/right rotates
`Level_Select.center` circularly through `fl.defs.levels` (play order, *not*
the alphabetical-by-filename order `data.Assets.levels` happens to load in —
looked up per level via `data.assets_level_media`, never assumed parallel),
center click either accepts (grow-pulse to `MaxScale` 2.0, tint green, starts
the session via `flow_start_session`) or rejects (grow-pulse tint red, no
session) depending on lock state. Wired from Main Menu's 1/2 Player buttons
(`menu_main.odin`, stashing `fl.pending_game_type` and switching to the new
`.Level_Select` `Flow_Mode` instead of starting a session directly) and from
`Level_Select` back into `flow_start_session`, which now takes the chosen
0-based level index rather than always starting at list position 0.

Two things found during this stage's research pass, beyond what "What the
original does" above already covered:

- **"Video Grid" (VIGR)**: every preview thumbnail gets a translucent
  scanline texture tiled over it (`G_Game_DrawGridInRect`, perm sprite 0
  "vigr"/"Video Grid", frame 0), giving it a "monitor screen" look — not
  mentioned in the original research pass, found by comparing a first,
  plain-thumbnail render against a real screenshot and tracing the call chain
  from `Priv_Preview`. Reproduced by `level_select_draw_grid`, tiled flush
  from the rect's corner rather than reproducing the original's own
  tile-centring arithmetic (a periodic pattern, so the sub-tile phase
  difference isn't visually distinguishable — confirmed by direct comparison,
  not assumed).
- **"Highest level reached" persistence**: confirmed by a research pass
  through `FUN_00426d80.c` (the post-session update, `U_Prefs_SetInt(3, ...)`)
  and `Priv_Preview`/`FUN_0042b4e0.c` (the gate that reads it back) that the
  original tracks **one global counter**, shared across Single and Co-Op, not
  per game type — a session's max level reached across whichever player slots
  were active feeds the same one value, monotonically increased, only when
  the session started at list position 1 (jumping in via Level Select never
  raises it, even past levels played along the way). The original persists
  this via `U_Prefs` slot 3 (Win32 registry); this reimplementation had no
  save-file infrastructure at all before this stage, so `game/progress.odin`
  adds the first one — a plain integer written to
  `$XDG_DATA_HOME/deimos-rising/progress` (or `~/.local/share/deimos-rising/progress`
  when `XDG_DATA_HOME` is unset), loaded once in `flow_init` and saved
  whenever `Flow.highest_reached` advances. No existing save-path convention
  to follow anywhere in the tree, so this picks the ordinary XDG location
  rather than inventing a project-specific one; best-effort (a read-only home
  directory just means progress doesn't persist that run, not a crash).

Verified via `mise run menu-shot MENU=level_select` (a new task, wrapping our
own headless render in `xvfb-run` the same way `shots`/`menu-shots:compare`
already do — running `$DR_BUILD/deimos` directly picks up the real desktop's
`DISPLAY` and pops a visible window, so always go through this task or an
equivalent `xvfb-run` wrapper for a one-off look) with a scratch `HOME`
pre-seeded with a saved progress file, confirming a level past the default
unlocks correctly (teal "START"/level name vs. red "NO ACCESS", per
`level_select_draw`'s `unlocked` check). `mise run menu-shots:compare
MENU=level_select` against a real screenshot of the original: AE 24641.7 of
307200 (8.02%), close visually per `side.png`/`diff.png` — the remaining
difference is mostly the VIGR scanline pattern's sub-tile phase (see above),
not a structural gap.

**Stage 3 — done.** `game/menu_credits.odin`: reached from Main Menu's
copyright text link (`menu_main.odin`'s `Text_Link` case, previously inert).
Traced from `G_Credits_Display_0120e0.c` and the `G_Text_FadeListIn/Out` fade
helpers it calls (all read in full) into a page-by-page state machine —
`Fading_In` → `Holding` (the only state that polls input) → `Fading_Out` →
`Waiting` (a 1s settle pause) → next page — driven off real elapsed time each
render frame rather than transliterating the original's own nested blocking
loops. `U_App_GetTickCount` (read in full) turned out to derive a ~60Hz tick
from Win32 `GetTickCount()`, distinct from the simulation's fixed 30Hz step;
the `<page NNN>` markers in `cred.json` and the fade animation's fixed
32-frame ramp are both counted in that timebase (`CREDITS_TICK_HZ :: 60.0`).
Any keypress or click ends Credits outright (there is no "advance to next
page" input at all) — confirmed by reading `G_Credits_Display`'s event
handling directly: both the `N`/non-`N` branches jump to the same exit path,
`N` only additionally starting a new 1-player game instead of returning to
Title. The credits text itself (`assets/data/stli/cred.json`) is
hand-transcribed into `CREDITS_PAGES` rather than read at runtime, matching
this port's existing convention for `.stli` tables (nothing in
`data/assets.odin`'s runtime loader reads `.stli` JSON at all).

Two things found during this stage's research pass:

- **Perm floats recovered but perm text-setting colours/positions were not**:
  `Credits_TitleYLoc` (130.0) and `Credits_VerticalGap` (16.0) came straight
  out of `gafl.json`, but `G_Text_GetPermTextSetting`'s preset table (8 for
  the title line, 9 for body lines) is a raw binary struct array in the
  executable's data section with no decompiled semantics — colour, X
  position and alignment couldn't be read out of the corpus. Recovered
  instead by column-brightness/colour-sampling a real Wine capture
  (`mise run oracle:menu-shot MENU=credits`), the same method Stage 1 used
  for `BTN_FIRST_ROW_Y`/`LOGO_Y`: left-aligned (not centred) at `CREDITS_X ::
  121`, title in a solid teal `(0, 255, 189)`, body lines plain white.
- **Blank `.stli` lines are significant and were silently dropped**:
  `tagged_parse` (`data/tagged_text.odin`) skips blank lines while decoding a
  resource into records, correct for every `#key value` format, but the
  original's raw "cred" resource turns out to *use* blank `.stli` lines as
  vertical spacing within a page — lost from the already-decoded
  `cred.json`. Found by comparing the first render against a real
  screenshot: the gap after a page's title, and before its trailing website
  URL (when it has one), measured 32px (two `VerticalGap` steps) rather than
  the expected uniform 16px. Confirmed live against three pages for the
  after-title gap (Swoop Software, Additional Unit Art, Geek Support) and two
  for the before-URL gap (the two pages that end in one); reproduced as a
  fixed extra gap after every title plus a hand-placed `""` entry in
  `Credits_Page.lines` before each of the two confirmed trailing URLs — not
  individually reverified page by page for the other seven.

Verified via `mise run menu-shot MENU=credits` (visual sanity check — the
static single-frame case fast-forwards past the initial pause/fade-in
straight to a settled `.Holding` state on page 0, since `run_menu_shot` draws
exactly one frame) and `mise run menu-shots:compare MENU=credits` against a
real screenshot of the original (`tools/oracle/menu_shot.sh`'s new `credits`
click-through case, clicking the copyright link then waiting 2.5s to land
inside page 0's hold): AE 19351.7 of 307200 (6.30%), a closer match than
Stage 2's Level Select — `side.png` shows matching position, colour and line
spacing, with the residual difference being background noise/antialiasing,
not a structural gap.

`mise run check`, `mise run purity`, `mise run test` (85 tests) all green.

## Stage 4 — done.

The High Scores viewer (`game/menu_high_scores.odin`, reached from Main
Menu's button) and the post-game name-entry prompt
(`game/menu_high_score_entry.odin`, reached automatically from Game
Over/Complete via `flow_finish_session` in `game/flow.odin`). Traced from
`G_Scores_Display_03b7c0.c`, `G_Scores_GetPlayerNamesAndDisplay_03b3a0.c`,
`G_Scores_IsAHighScore_03b360.c`, `FUN_0043bb00.c` (the name-entry screen)
and `FUN_0043c480.c` (the shared row-builder both screens call) — all read
in full — plus `U_Prefs_SetHighScoresToDefaults_0085d0.c` for the default
table and `U_Utils_String_Encrypt_00f740.c` for the cipher protecting it.

- **The 15-slot table**: `game/highscores.odin`. Each slot is (name, score,
  sector), sorted descending by score, persisted the same way as
  `progress.odin`'s "highest level reached" (an XDG data file, not the
  original's registry-backed `U_Prefs` blob — nothing outside this
  reimplementation ever reads it, so the file format is our own, not a
  byte-for-byte `U_Prefs` layout).
- **Default table names were encrypted in the executable, not plaintext**:
  `U_Prefs_SetHighScoresToDefaults` copies a static table at `DAT_004d9577`
  through `U_Utils_String_Encrypt` before writing it into the live prefs
  blob. That function turns out to be a byte-wise nibble-swap-then-XOR-0xFF
  transform, which is its own inverse — applying it a second time recovers
  the cleartext. Verified by peeking the raw bytes
  (`python3 tools/decomp/peek.py $DR_EXE <va>`) and decrypting them in a
  throwaway script rather than guessing: all 15 names are Deimos Rising
  dev-team nicknames, several already known from Credits (Supercobra,
  Dilvish, Vodi, Fisj, h'biki). Default scores are a flat 15000 down to 1000
  in 1000-point steps (`U_Prefs_SetHighScoresToDefaults`'s own
  `iVar1 * -1000 + 16000`), and every default slot's sector is
  "New Atlantis".
- **Perm floats, all read via `gafl.json` once their indices were confirmed
  from call sites** (the same two-step process Stage 3 used):
  `Scores_VerticalGap` (0x4c, 19.0, row gap), `Scores_YLoc` (0x4d, 107.0,
  first *data* row's Y — not the header's, see below),
  `Scores_Duration` (0x4e, 600 ticks = 10s, the plain viewer's hold),
  `Scores_DurationBetweenPlayers` (0x4f, 25 ticks ≈ 0.42s) — corrects an
  earlier guess (recorded mid-research, before the value was actually looked
  up) that this was a *longer* "admire your score" pause; it's the opposite,
  a brief pace-setting gap so a two-player session's second name-entry
  screen follows on quickly — `Scores_SymbolXLoc`/`YLoc` (0x50/0x51, 73.0/7.0
  — turned out to be the position of a small per-row ship-icon sprite
  FUN_0043c480 optionally draws next to the row being edited, *not* text
  column offsets as an earlier pass here assumed; skipped as a minor visual
  flourish, see below), `Scores_PromptFlashDelayAfterKeyHit`/
  `PromptDelayBetweenFlashes` (0x52/0x53, 30/10 ticks, the name-entry
  cursor's blink on/off durations).
- **Perm sounds, resolved via `idli/gaso.json`**: index 2/4 both name
  "InterfaceClick"/"CommandConfirmation", the same `incl` clip (backspace
  and Enter-to-commit); index 0 "ButtonClick" `clic` (an ordinary typed
  character); index 15 "ScoreEntryFailure" `shwa` (buffer full, a keystroke
  rejected); index 9 "HighScoreAchieved" is `none` — no sound resource at
  all, despite being played (as a no-op) once when a qualifying player's
  screen opens, so this reimplementation plays nothing there either.
- **The row-builder's preset branching** (`FUN_0043c480`, shared by both
  screens): 3 header nodes ("Name"/"Score"/"Sector", raw strings peeked
  directly from the executable, not read through any `.stli` table) then 15
  rows, each a 3-way preset branch (plain viewer / name-entry-but-not-this-
  row / this-is-the-actively-edited-row) — 9 presets total
  (`0xd` through `0x15`), none with decompiled colour/position semantics.
  No rank number is ever drawn as text for any row; rank is implied by
  position alone.
- **The optional per-row ship icon was skipped**: each row's `FUN_0043c480`
  iteration also builds a second, non-text struct (a byte-for-byte copy of a
  fixed static template) whose two fields get overridden — only for the row
  currently being edited during name entry — with a player definition's
  sprite ID. Read as a small "your ship" decoration beside the active row;
  judged safe to skip given the effort/fidelity tradeoff (a minor visual
  flourish, never shown in the plain viewer at all, and this reimplementation
  already omits comparable flourishes elsewhere — see Credits' own skipped
  per-line fade stagger).
- **Column X positions and the header's Y have no perm-float backing at
  all** (same situation as Credits' `CREDITS_X`/colours): recovered by
  colour/position-sampling a live Wine capture
  (`mise run oracle:menu-shot MENU=high_scores`) the same way Stage 3 did.
  Name/Score/Sector columns sit at x=111/346/464 (shared by the header and
  every data row); the header row itself draws at y≈85, while the first
  *data* row's y=107 does come from `Scores_YLoc` — `FUN_0043c480` never
  writes the three header nodes' Y field at all, only each per-row node's,
  so the header keeps whatever Y its own preset bakes in, independent of
  `Scores_YLoc`. Header colour is the same solid teal `(0, 255, 189)` as
  Credits' title; body rows plain white.
- **The name-entry screen's input handling is a from-scratch text box, not a
  transliteration of `FUN_0043bb00`'s raw scan-code branches** (8/10/13,
  and a `0x5e5b` constant for Escape that doesn't map to any obvious literal
  VK code): reimplemented with raylib's `GetCharPressed` (proper
  keyboard-layout-aware character input) plus `IsKeyPressed` for
  Backspace/Enter/Escape, consistent with this project's established
  practice for input-adjacent, non-simulation code (see Level Select's own
  click handling).
- **The easter-egg substitution chain** (`FUN_0043bb00`, on Enter): five
  unconditional substring checks against the uppercased typed name — `BIKI`
  → "Filthy Communist", `DILVISH` → "Just Ship It, Baby", `SUPERCOBRA` →
  "Munkis Rool J00", `PYTHOS` → "Leonard Cohen Rules J00", `FISJ` →
  "Daikajinn!!" — each unconditionally overwriting the name if it matches
  (last match wins, since there's no early exit), then an empty-name
  fallback → "Jar Jar Must Die", checked against the *original* typed text
  regardless of any substitution already applied. All eleven strings
  (5 match substrings + 5 replacements + the empty-name fallback) were read
  directly from the executable's raw bytes via `peek.py`, not guessed, and
  cross-checked against the dev nicknames already in Credits and the default
  score table.
- **Escape's exact original semantics were not fully reproduced**: in
  `FUN_0043bb00`, Escape (`local_8d = '\0'`) skips straight past the
  hold-and-save path, discarding only *that* player's entry — but
  reconstructing the precise partial-table-shift-undo this implies (two
  players' insertion ranks were computed together, up front, before either
  screen ran) wasn't fully traceable from the decompiled corpus alone.
  Simplified here: Escape cancels the *entire* name-entry sequence, not just
  the current player's turn. Since each commit (`Enter`) persists
  immediately via `high_scores_save` rather than batching to the end of the
  whole sequence, an earlier player's already-confirmed entry in the same
  session is never lost by a later player cancelling.
- **`FUN_00426d80.c`** (read in full, the post-session flow the original
  runs after a level ends) confirmed where this all hooks in: once the
  fade-back-to-menu finishes, it checks every active player's score against
  `G_Scores_IsAHighScore` and, if any qualifies, calls
  `G_Scores_GetPlayerNamesAndDisplay` before finally returning to the menu.
  Reproduced as `flow_finish_session` in `game/flow.odin`, called from both
  paths that used to go straight from Game Over/Complete to Title (the
  hold-timer elapsing, and the player skipping ahead with
  Space/Enter/Escape) — a qualifying score now routes through
  `.Score_Entry` instead of straight to `.Title`.

Verified via `mise run oracle:menu-shot MENU=high_scores` (clicking Main
Menu's High Scores button) and `mise run menu-shots:compare MENU=high_scores`:
AE 22914.3 of 307200 (7.46%), in the same range as Credits' 6.30% — `side.png`
shows matching column positions and colours, with the residual difference
being this Wine prefix's own already-dirtied save data (one real high score
entry from earlier testing, not present in this reimplementation's fresh
default table) plus background antialiasing noise, not a structural gap. The
name-entry screen itself has no practical oracle click-through (it needs an
actual completed session with a qualifying score, not scriptable through
`xdotool` the way every other screen here is) — spot-checked instead via
`mise run menu-shot MENU=score_entry`, which stands up a synthetic qualifying
score the same way `flow_finish_session` does, for a visual sanity check
rather than a pixel comparison.

`mise run ci` (check, purity, test) and `mise run oracle:diff` (all four
demos still matching the original call for call) both green.

Stage 6 (`-classic` gating, which Phase 6's lobby is waiting on) is
unstarted.
