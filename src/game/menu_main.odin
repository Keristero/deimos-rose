package game

// Phase 7 stage 1: the original's actual main menu, not the plain-text
// stand-in D18 shipped with (superseded by D21). `G_Interface_025fd0.c`'s
// button-list build (`FUN_004277e0`) confirmed the exact button->frame
// mapping used below, and `Interface_Btn_StartYLoc`/`VerticalGap` the
// vertical layout. See docs/phase-7-faithful-menus.md for the full trace.
//
// Not pinned to a perm float in the decompiled corpus: the logo's position
// and each button's horizontal centring (`FUN_00427cb0` only allocates the
// button record; the layout math lives in draw/hit-test helpers that were
// not fully traced). Centred horizontally here, logo placed at a plausible
// LOGO_Y -- provisional until checked against a live screenshot of the
// original.
//
// Register/Activate (frame 7, shown only when unregistered) and the exit-time
// ad are excluded per D21. High Scores opens its own screen (stage 4,
// game/menu_high_scores.odin), Preferences this port's own Preferences screen
// (game/menu_preferences.odin). Netplay (game/netplay.odin), which once sat
// behind Preferences, is a separate text item below the original six --
// hidden under classic mode, since the original has no such entry (D30).

import rl "vendor:raylib"

import "dr:sim"

GALO :: sim.Res_ID{'g', 'a', 'l', 'o'}

BTN_GAP :: 30 // Interface_Btn_VerticalGap -- the row-to-row spacing matches this exactly.
// Interface_Btn_StartYLoc (168) is not, on its own, where the first row's rect
// sits: measured against a real screenshot of the original
// (tools/oracle/menu_shot.sh MENU=main, compared via menu_compare.sh -- see
// docs/phase-7-faithful-menus.md "Verification"), the first row's rendered
// label centres at y=198, one whole VerticalGap below StartYLoc, and each
// later row is another exact VerticalGap down (228, 258, 288, 318, 348, plus
// 378 for the excluded Register row) -- confirming the *gap* but not
// StartYLoc's own meaning. FUN_004277e0's layout call was never fully traced
// (see the file-level comment), so this reproduces the measured rect position
// (btn 0's frame top, back-computed from its label's rendered centre using
// this port's own MEBU frame-to-label offset) rather than re-deriving
// StartYLoc's exact original semantics.
// Baked in at build time by tools/version/version.sh via mise.toml's build
// tasks (-define:DR_VERSION): the release tag, e.g. "v0.1.72", or with
// "-local" for a build outside CI. "dev" when built without the task.
GAME_VERSION :: #config(DR_VERSION, "dev")

BTN_FIRST_ROW_Y :: 186
// Netplay takes the seventh row -- where the excluded Register button sat --
// its 20px Text_Button centred on that row's measured label centre (378).
NETPLAY_ROW_Y :: BTN_FIRST_ROW_Y + 6 * BTN_GAP + 2
// Measured the same way (column-brightness scan of a real screenshot vs.
// ours): the globe's bright limb starts at y=47 in the original, y=40 at the
// value this used to have -- moved down 7px accordingly.
LOGO_Y :: 47

// FUN_004277e0's button-list build, in order: frame indices into MEBU/MEBH.
// Index 3 is real plate art (a 14-frame plate, this main menu uses 6 of its
// 7 non-register slots) but is never referenced by any button here -- its
// baked text is "CONTROLS" (confirmed by cropping the frame directly during
// stage 2's research pass; not "REPLAY LAST GAME" as an earlier pass here
// guessed), with no confirmed menu entry point found. Not wired; revisit if a
// use turns up.
@(private = "file")
MAIN_MENU_FRAMES := [6]i32{0, 1, 2, 4, 5, 6}

@(private = "file")
Main_Menu_Slot :: enum {
	One_Player,
	Two_Player,
	Preferences,
	High_Scores,
	Play_Demo,
	Quit,
}

Main_Menu :: struct {
	buttons:      [6]Menu_Button,
	website:      Text_Link,
	copyright:    Text_Link,
	netplay:      Text_Button, // new content: not drawn or clickable under classic mode
	// "Visit the Deimos Rising Website Now?" (stli/inte.json #20) -- the
	// original gates U_App_LaunchURL behind a confirm dialog; reproduced as
	// a minimal text prompt rather than a native dialog.
	confirm_website: bool,
}

main_menu_init :: proc(m: ^Main_Menu, t: ^Textures) {
	for slot in Main_Menu_Slot {
		m.buttons[slot] = menu_button_at(t, MAIN_MENU_FRAMES[slot], BTN_FIRST_ROW_Y + f32(slot) * BTN_GAP)
	}
}

// Called once per render frame from flow_handle_input's .Title case.
main_menu_update :: proc(fl: ^Flow, r: ^Renderer, m: ^Main_Menu) {
	// Link rects are sized from text_width, which needs a loaded font plate
	// -- built lazily on first update rather than in main_menu_init, which
	// only receives a Textures, not a Renderer.
	if m.website.rect.width == 0 {
		m.website = text_link_at(r, "WWW.DEIMOSRISING.COM", 426)
		m.copyright = text_link_at(r, "COPYRIGHT 2001-2002 SWOOP SOFTWARE & AMBROSIA SOFTWARE, INC.", 447)
		m.netplay = text_button_at(r, "NETPLAY", NETPLAY_ROW_Y)
	}

	dt := rl.GetFrameTime()
	mouse := menu_mouse_pos()

	if m.confirm_website {
		if rl.IsKeyPressed(.Y) || rl.IsKeyPressed(.ENTER) {
			rl.OpenURL("http://www.deimosrising.com") // stli/inte.json #19, the game's own string
			m.confirm_website = false
		} else if rl.IsKeyPressed(.N) || rl.IsKeyPressed(.ESCAPE) {
			m.confirm_website = false
		}
		return
	}

	for slot in Main_Menu_Slot {
		if menu_button_update(r, &m.buttons[slot], mouse, dt) {
			main_menu_activate(fl, r, slot)
		}
	}
	if !r.classic && text_button_update(r, &m.netplay, mouse, dt) {
		fl.mode = .Netplay_Lobby
		netplay_lobby_init(&fl.netplay, r)
	}
	if text_link_update(&m.website, mouse, dt) {
		m.confirm_website = true
	}
	if text_link_update(&m.copyright, mouse, dt) {
		// FUN_004287f0 -- opens Credits (game/menu_credits.odin).
		fl.mode = .Credits
		credits_init(&fl.credits)
	}
}

@(private = "file")
main_menu_activate :: proc(fl: ^Flow, r: ^Renderer, slot: Main_Menu_Slot) {
	switch slot {
	case .One_Player:
		fl.pending_game_type = .Single
		fl.mode = .Level_Select
		level_select_init(&fl.level_select)
	case .Two_Player:
		fl.pending_game_type = .Co_Op
		fl.mode = .Level_Select
		level_select_init(&fl.level_select)
	case .Play_Demo:
		flow_load_demo(fl, 0)
	case .High_Scores:
		fl.mode = .High_Scores
		high_scores_view_init(&fl.high_scores)
	case .Quit:
		fl.quit = true
	case .Preferences:
		// The original's own Preferences is a native Win32 dialog with no
		// bespoke art to port; this opens the port's replacement in every
		// mode, classic included -- it is where classic mode is turned
		// back off (D30).
		fl.mode = .Preferences
		preferences_init(&fl.preferences)
	}
}

main_menu_draw :: proc(r: ^Renderer, m: ^Main_Menu) {
	// Links and the Netplay item are built on the first update; a frame
	// drawn before then (a menu capture) just omits them.
	menu_draw_background(r, "back")
	if tex, src, ok := frame_rect(&r.textures, GALO, 0); ok {
		dst := rl.Rectangle {
			(SCREEN_W - src.width) / 2 * WINDOW_SCALE, LOGO_Y * WINDOW_SCALE,
			src.width * WINDOW_SCALE, src.height * WINDOW_SCALE,
		}
		rl.DrawTexturePro(tex, src, dst, {0, 0}, 0, rl.WHITE)
	}
	for slot in Main_Menu_Slot {
		menu_button_draw(r, &m.buttons[slot])
	}
	text_link_draw(r, &m.website)
	text_link_draw(r, &m.copyright)
	if !r.classic && m.netplay.rect.width > 0 {
		text_button_draw(r, &m.netplay)
	}
	// New content, but shown in classic mode too: it is what a bug report
	// needs, and sits in the corner clear of every original element.
	menu_draw_text(r, GAME_VERSION, SCREEN_W - 6, SCREEN_H - 14, rl.Color{120, 120, 120, 255}, .Right)

	if m.confirm_website {
		menu_draw_text(r, "VISIT THE DEIMOS RISING WEBSITE NOW?", SCREEN_W / 2, SCREEN_H / 2 - 10,
			rl.Color{255, 255, 255, 255}, .Centre)
		menu_draw_text(r, "Y TO LAUNCH, N TO CANCEL", SCREEN_W / 2, SCREEN_H / 2 + 10,
			rl.Color{190, 190, 190, 255}, .Centre)
	}
}
