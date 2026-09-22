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
menu's button list — an open question (possibly "REPLAY LAST GAME", which the
underlying machinery supports via `FUN_00428560` but which has no confirmed
menu entry point; not blocking, revisit if a use turns up). Two more links
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

One provisional layout value was corrected by looking at the output rather
than guessing further: `LOGO_Y` (the logo's un-pinned-by-perm-float vertical
position) was first set to 101, which a screenshot showed overlapping "1
PLAYER"/"2 PLAYER"; moved to 40, re-screenshotted, confirmed clear.

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

**Stage 5 — done, folded into stage 1's `flow.odin` edit.** Flow's old
`.Paused` case (`draw_banner("PAUSED", ...)`) is replaced by
`draw_paused_borders`, a screen dim with no text — see D21 and the file
comment on `draw_paused_borders` for the exact-vs-approximated caveat
(the original blacks out two perm-float-sized strips via
`U_Display::DrawBlackBorders`; this approximates that as a full-screen dim
rather than claiming pixel-exact border geometry).

Stages 2-4 (Level Select, Credits, High Scores) and 6 (`-classic` gating,
which Phase 6's lobby is waiting on) are unstarted.
