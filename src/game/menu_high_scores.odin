package game

// Phase 7 stage 4: the plain High Scores viewer, reached from Main Menu's
// "High Scores" button. Traced from G_Scores_Display_03b7c0.c (read in full)
// and the shared row-builder it calls, FUN_0043c480.c (also read in full) --
// see docs/phase-7-faithful-menus.md's Stage 4 notes for the full research
// pass.
//
// Structurally the same fade-in/hold/fade-out shape as Credits
// (menu_credits.odin), but single-page: one fixed hold duration (perm float
// 0x4e, Scores_Duration = 600 ticks at the ~60Hz U_App_GetTickCount timebase
// Stage 3 established = 10s) instead of Credits' per-page durations, and
// fifteen fixed rows instead of paged text. Unlike Credits, only 'N' plays a
// sound on exit here (G_Res_GetPermSoundID(2), "incl") -- a plain click or
// any other keypress ends the screen silently (G_Scores_Display's own
// case-1/case-2/3 fallthrough: the sound-and-flag block is inside the N/n
// check, not shared by the fallthrough itself).

import "core:fmt"

import rl "vendor:raylib"

import "dr:sim"

@(private = "file") HIGH_SCORES_N_SOUND :: sim.Res_ID{'i', 'n', 'c', 'l'}

HIGH_SCORES_TICK_HZ :: 60.0
HIGH_SCORES_FADE_SECONDS :: 32.0 / HIGH_SCORES_TICK_HZ
HIGH_SCORES_HOLD_SECONDS :: 600.0 / HIGH_SCORES_TICK_HZ // Scores_Duration, perm float 0x4e

HIGH_SCORES_ROW0_Y :: 107.0 // Scores_YLoc, perm float 0x4d -- the first *data* row, not the header
HIGH_SCORES_ROW_GAP :: 19.0 // Scores_VerticalGap, perm float 0x4c -- confirmed exact against a live capture

// The header row's own Y has no perm float backing at all: FUN_0043c480
// never writes its three header nodes' G_Text_Settings+0x104 Y field, only
// each per-row node's -- the header keeps whatever Y its own preset
// (10/0xb/0xc) bakes in. Measured directly against a live Wine capture, like
// the column X positions below (see docs/phase-7-faithful-menus.md's Stage 4
// notes: G_Text_GetPermTextSetting's preset table has no decompiled
// semantics for either).
HIGH_SCORES_HEADER_Y :: 85

// Column left edges and colours, measured against a live Wine capture --
// like Credits, G_Text_GetPermTextSetting's own X/colour fields have no
// decompiled semantics to read directly, only a raw preset-table struct
// copy. Shared by the header and every data row (confirmed against the same
// capture).
HIGH_SCORES_NAME_X :: 111
HIGH_SCORES_SCORE_X :: 346
HIGH_SCORES_SECTOR_X :: 464
HIGH_SCORES_HEADER_RGB :: [3]u8{0, 255, 189}
HIGH_SCORES_ROW_RGB :: [3]u8{255, 255, 255}

High_Scores_State :: enum {
	Fading_In,
	Holding,
	Fading_Out,
}

High_Scores :: struct {
	state:    High_Scores_State,
	t:        f32,
	new_game: bool,
	table:    [HIGH_SCORE_SLOTS]High_Score_Entry,
}

high_scores_view_init :: proc(hs: ^High_Scores) {
	save := high_scores_load()
	hs^ = High_Scores{table = save.table}
}

// Called once per render frame from flow_handle_input's .High_Scores case.
high_scores_view_update :: proc(fl: ^Flow, r: ^Renderer, hs: ^High_Scores) {
	dt := rl.GetFrameTime()
	hs.t += dt

	switch hs.state {
	case .Fading_In:
		if hs.t >= HIGH_SCORES_FADE_SECONDS {
			hs.state, hs.t = .Holding, 0
		}

	case .Holding:
		// U_App_Event_GetNext, polled only while holding -- same as Credits
		// and every other G_Text fade-driven screen (see menu_credits.odin).
		key := rl.GetKeyPressed()
		clicked := rl.IsMouseButtonPressed(.LEFT)
		if key != .KEY_NULL || clicked {
			if key == .N {
				menu_play_sound(r, HIGH_SCORES_N_SOUND)
				hs.new_game = true
			}
			hs.state, hs.t = .Fading_Out, 0
		} else if hs.t >= HIGH_SCORES_HOLD_SECONDS {
			hs.state, hs.t = .Fading_Out, 0
		}

	case .Fading_Out:
		if hs.t >= HIGH_SCORES_FADE_SECONDS {
			if hs.new_game {
				flow_start_session(fl, flow_random_seed(), .Single, 0)
			} else {
				fl.mode = .Title
			}
		}
	}
}

high_scores_view_draw :: proc(r: ^Renderer, hs: ^High_Scores) {
	menu_draw_background(r, "back")

	alpha: f32
	switch hs.state {
	case .Fading_In:
		alpha = clamp(hs.t / HIGH_SCORES_FADE_SECONDS, 0, 1)
	case .Holding:
		alpha = 1
	case .Fading_Out:
		alpha = 1 - clamp(hs.t / HIGH_SCORES_FADE_SECONDS, 0, 1)
	}
	a := u8(alpha * 255)
	header := rl.Color{HIGH_SCORES_HEADER_RGB[0], HIGH_SCORES_HEADER_RGB[1], HIGH_SCORES_HEADER_RGB[2], a}
	row_color := rl.Color{HIGH_SCORES_ROW_RGB[0], HIGH_SCORES_ROW_RGB[1], HIGH_SCORES_ROW_RGB[2], a}

	menu_draw_text(r, "Name", HIGH_SCORES_NAME_X, HIGH_SCORES_HEADER_Y, header)
	menu_draw_text(r, "Score", HIGH_SCORES_SCORE_X, HIGH_SCORES_HEADER_Y, header)
	menu_draw_text(r, "Sector", HIGH_SCORES_SECTOR_X, HIGH_SCORES_HEADER_Y, header)
	y := f32(HIGH_SCORES_ROW0_Y)

	for e in hs.table {
		menu_draw_text(r, e.name, HIGH_SCORES_NAME_X, i32(y), row_color)
		menu_draw_text(r, fmt.tprintf("%d", e.score), HIGH_SCORES_SCORE_X, i32(y), row_color)
		menu_draw_text(r, e.sector, HIGH_SCORES_SECTOR_X, i32(y), row_color)
		y += HIGH_SCORES_ROW_GAP
	}
}
