package game

// Phase 7 stage 2: the level-select carousel, reached from Main Menu's
// "1 PLAYER"/"2 PLAYER" (menu_main.odin's One_Player/Two_Player cases set
// Flow.pending_game_type and switch to .Level_Select rather than starting a
// session directly). Traced from G_LevelSelect_GetStartingLevelIDFromUser and
// Priv_Preview -- see docs/phase-7-faithful-menus.md's "Verification"
// section for the research pass this is built from.
//
// Background lese.png, three preview thumbnails (each level's own
// Level_Media.preview, an im16 image already sized to the click rect
// pixel-for-pixel -- no separate frame/border sprite around them), left/right
// rotate the carousel one level at a time (circular: this wraps at both ends,
// confirmed by G_LevelSelect's own index arithmetic, not clamped), clicking
// the centre either accepts (unlocked) or rejects (locked) it.
//
// Not reproduced (dead code for the registered build this ports, per
// U_Registration::Is() always returning true here): the shareware level-count
// gate (G_Level_GetNumLevelsInDemo) and its "Registration Required" message --
// only the "Sector Not Reached" locked case is real for a registered install.

import "core:fmt"

import rl "vendor:raylib"

import "dr:data"
import "dr:plugins/easy_mode"
import "dr:render"
import "dr:sim"
import "dr:ui"

LESE :: "lese"

// LevSel_Button_Previous/Current/Next (reli/inre.json perm rects 0x12-0x14).
// These rects *are* the preview thumbnails -- there is no separate arrow
// widget layered over them; clicking the left/right preview rotates the
// carousel, clicking the centre one accepts/rejects it.
@(private = "file")
LS_RECTS := [3]rl.Rectangle {
	{55, 76, 145, 306}, // previous
	{246, 76, 146, 306}, // current
	{438, 76, 145, 306}, // next
}

// LevelSelect_Notice_*_X/Y (perm floats 0x5a-0x5f): fixed icon positions,
// drawn regardless of carousel content. LevelSelect_SpriteFrame_* (perm
// floats 0x60-0x63) name MEBU/MEBH frames 10-13: 10 is the baked-text
// "START" (shown centred when the current level is unlocked), 11 is baked
// "NO ACCESS" (shown centred when locked), 12/13 are small left/right-facing
// arrow glyphs (shown at the side slots unconditionally).
@(private = "file")
LS_ICON_POS := [3]rl.Vector2{{128, 228}, {320, 228}, {511, 228}}
@(private = "file") LS_FRAME_PREV :: 12
@(private = "file") LS_FRAME_START :: 10
@(private = "file") LS_FRAME_NOACCESS :: 11
@(private = "file") LS_FRAME_NEXT :: 13

// LevSel_Acceptance/Failure_ScalingRate/MaxScale (perm floats 0x2c-0x2f).
// Rates are per original 30Hz tick, converted to per-second because menu
// screens run at render rate, not the sim's fixed step.
@(private = "file") LS_ACCEPT_RATE :: 0.18 * 30
@(private = "file") LS_ACCEPT_MAX_SCALE :: 2.0
@(private = "file") LS_FAIL_RATE :: 0.25 * 30
@(private = "file") LS_FAIL_MAX_SCALE :: 2.0

// "Video Grid" (idli/gasp.json perm sprite ID 0) -- see level_select_draw_grid.
@(private = "file") VIGR :: sim.Res_ID{'v', 'i', 'g', 'r'}

// InterfaceMenuButtonRollover/LevelSelectSelector/Choose/Failure (idli/gaso.json).
@(private = "file") ROLLOVER :: sim.Res_ID{'m', 'b', 'r', 'o'}
@(private = "file") SELECTOR :: sim.Res_ID{'l', 's', 'c', 'h'}
@(private = "file") CHOOSE :: sim.Res_ID{'l', 's', 's', 'e'}
@(private = "file") FAILURE :: sim.Res_ID{'l', 's', 'n', 'a'}

Level_Select_Pulse :: enum {
	None,
	Accept,
	Fail,
}

Level_Select :: struct {
	center:  int, // 0-based index into Flow.defs.levels -- the "current" slot
	hover:   [3]f32,
	pulse:   Level_Select_Pulse,
	scale:   f32, // 1.0..MaxScale; only the centre preview is ever drawn scaled
	growing: bool,
	// Not the original's: the Easy_Mode extra's toggle, under the level
	// name, and only outside classic mode.
	easy:    ui.Text_Button,
}

@(private = "file") LS_EASY_Y :: 440

@(private = "file")
level_select_easy_layout :: proc(fl: ^Flow, r: ^render.Renderer, ls: ^Level_Select) {
	label := prefs_mod_on(fl.prefs, easy_mode.ID) ? "EASY MODE: ON" : "EASY MODE: OFF"
	ui.text_button_relabel(r, &ls.easy, label, render.SCREEN_W / 2, LS_EASY_Y)
}

// Always opens on the first level: G_LevelSelect_GetStartingLevelIDFromUser's
// own carousel index starts at 0 every time the screen is entered, it does
// not remember where a previous visit left off.
level_select_init :: proc(ls: ^Level_Select) {
	ls^ = Level_Select{}
}

level_select_update :: proc(fl: ^Flow, r: ^render.Renderer, ls: ^Level_Select) {
	dt := rl.GetFrameTime()
	n := len(fl.defs.levels)

	if ls.pulse != .None {
		finished, accepted := level_select_step_pulse(ls, dt)
		if finished && accepted {
			flow_start_session(fl, flow_random_seed(), fl.pending_game_type, ls.center)
			return
		}
		if ls.pulse == .Accept {
			// The original ignores all further input once an accept pulse
			// starts (its DAT_004e8673 latch), all the way until the pulse
			// finishes and the level loads -- a failure pulse does not latch
			// this way, so falls through to normal input handling below.
			return
		}
	}

	if rl.IsKeyPressed(.ESCAPE) {
		fl.mode = .Title
		return
	}

	mouse := ui.menu_mouse_pos()
	if !r.classic {
		level_select_easy_layout(fl, r, ls)
		if ui.text_button_update(r, &ls.easy, mouse, dt) {
			prefs_mod_toggle(fl.prefs, easy_mode.ID)
		}
	}
	for i in 0 ..< 3 {
		was_hovering := ls.hover[i] > 0
		clicked := ui.update_hover_click(LS_RECTS[i], &ls.hover[i], mouse, dt)
		if ls.hover[i] > 0 && !was_hovering {
			ui.menu_play_sound(r, ROLLOVER)
		}
		if !clicked {
			continue
		}
		switch i {
		case 0:
			ls.center = (ls.center - 1 + n) % n
			ui.menu_play_sound(r, SELECTOR)
		case 2:
			ls.center = (ls.center + 1) % n
			ui.menu_play_sound(r, SELECTOR)
		case 1:
			if ls.center < fl.highest_reached {
				ls.pulse, ls.growing = .Accept, true
				ui.menu_play_sound(r, CHOOSE)
			} else {
				ls.pulse, ls.growing = .Fail, true
				ui.menu_play_sound(r, FAILURE)
			}
		}
	}
}

// Grows the centre preview to MaxScale then shrinks it back to 1.0;
// `finished` fires once back at rest, `accepted` says whether this was the
// Accept pulse (which starts the session) or a Fail one (which just clears
// back to idle so the player can try again). The original also fades in a
// coloured strip under the preview during this (green for accept, red for
// fail, FUN_0042c430's separate alpha-ramp counter) -- its exact rate was not
// pinned down in the decompiled corpus (see docs/phase-7-faithful-menus.md),
// so level_select_draw tints the scaled preview directly instead of
// reproducing a separate strip; the scale animation itself is exact.
@(private = "file")
level_select_step_pulse :: proc(ls: ^Level_Select, dt: f32) -> (finished, accepted: bool) {
	rate: f32 = ls.pulse == .Accept ? LS_ACCEPT_RATE : LS_FAIL_RATE
	max_scale: f32 = ls.pulse == .Accept ? LS_ACCEPT_MAX_SCALE : LS_FAIL_MAX_SCALE
	if ls.growing {
		ls.scale += rate * dt
		if ls.scale >= max_scale {
			ls.scale, ls.growing = max_scale, false
		}
	} else {
		ls.scale -= rate * dt
		if ls.scale <= 1.0 {
			was := ls.pulse
			ls.pulse, ls.scale = .None, 1.0
			return true, was == .Accept
		}
	}
	return false, false
}

level_select_draw :: proc(r: ^render.Renderer, fl: ^Flow, ls: ^Level_Select) {
	ui.menu_draw_background(r, LESE)

	n := len(fl.defs.levels)
	unlocked := ls.center < fl.highest_reached
	for i in 0 ..< 3 {
		idx := ((ls.center + i - 1) % n + n) % n
		level := &fl.defs.levels[idx]
		media := data.assets_level_media(&r.textures.assets, level.id)
		if media == nil {
			continue
		}
		tex, ok := render.menu_image(&r.textures, media.preview)
		if !ok {
			continue
		}
		rect := LS_RECTS[i]
		if i == 1 && ls.pulse != .None {
			tint := ls.pulse == .Accept ? rl.Color{140, 255, 140, 255} : rl.Color{255, 140, 140, 255}
			level_select_draw_scaled(tex, rect, ls.scale, tint)
		} else {
			dst := rl.Rectangle {
				rect.x * render.WINDOW_SCALE, rect.y * render.WINDOW_SCALE,
				rect.width * render.WINDOW_SCALE, rect.height * render.WINDOW_SCALE,
			}
			rl.DrawTexturePro(tex, {0, 0, f32(tex.width), f32(tex.height)}, dst, {0, 0}, 0, rl.WHITE)
		}
		// G_Game_DrawGridInRect(&rect, false, false), unconditional in the
		// original for every slot -- perm sprite 0 ("vigr", "Video Grid"),
		// frame 0 (VideoGrid_NormalFrame, perm float 0x54): a translucent
		// horizontal-line texture tiled across the rect, giving the preview
		// its "monitor screen" look. Stays at the slot's fixed rect even
		// while the centre preview is pulse-scaled (the original draws it
		// from the same un-scaled rect the CopyTo/PixelScale call above used).
		level_select_draw_grid(r, rect)
		if i == 1 {
			// lsnu/lsde (unlocked, teal) vs lsnn/lsna (locked, red) -- drawn
			// here with the port's own glyph font rather than the original's
			// baked tefo text styling, matching the convention menu.odin's
			// Text_Link already uses for non-plate text.
			color := unlocked ? rl.Color{99, 197, 214, 255} : rl.Color{255, 0, 0, 255}
			ui.menu_draw_text(r, fmt.tprintf("%02d", level.number), render.SCREEN_W / 2, 38, color, .Centre)
			label := unlocked ? media.name : "NO ACCESS"
			ui.menu_draw_text(r, label, render.SCREEN_W / 2, 407, color, .Centre)
		}
		// The hover border stops once an accept pulse has latched (matching
		// DAT_004e8673 gating it off in the original); a fail pulse doesn't
		// block it.
		if ls.hover[i] > 0 && ls.pulse != .Accept {
			level_select_draw_hover_border(rect)
		}
	}

	level_select_draw_icon(r, LS_ICON_POS[0], LS_FRAME_PREV, ls.hover[0] > 0)
	level_select_draw_icon(r, LS_ICON_POS[1], unlocked ? LS_FRAME_START : LS_FRAME_NOACCESS, ls.hover[1] > 0)
	level_select_draw_icon(r, LS_ICON_POS[2], LS_FRAME_NEXT, ls.hover[2] > 0)
	if !r.classic {
		level_select_easy_layout(fl, r, ls)
		ui.text_button_draw(r, &ls.easy)
	}
}

@(private = "file")
level_select_draw_scaled :: proc(tex: rl.Texture2D, rect: rl.Rectangle, scale: f32, tint: rl.Color) {
	cx := rect.x + rect.width / 2
	cy := rect.y + rect.height / 2
	w := rect.width * scale
	h := rect.height * scale
	dst := rl.Rectangle {
		(cx - w / 2) * render.WINDOW_SCALE, (cy - h / 2) * render.WINDOW_SCALE,
		w * render.WINDOW_SCALE, h * render.WINDOW_SCALE,
	}
	rl.DrawTexturePro(tex, {0, 0, f32(tex.width), f32(tex.height)}, dst, {0, 0}, 0, tint)
}

// lsbo, #00ffff -- approximated as a translucent stroked rectangle rather
// than the original's own border sprite (not extracted as a standalone
// asset; the plate swap on the icon below carries most of the same "you're
// over this slot" feedback).
@(private = "file")
level_select_draw_hover_border :: proc(rect: rl.Rectangle) {
	dst := rl.Rectangle {
		rect.x * render.WINDOW_SCALE, rect.y * render.WINDOW_SCALE,
		rect.width * render.WINDOW_SCALE, rect.height * render.WINDOW_SCALE,
	}
	rl.DrawRectangleLinesEx(dst, 3 * render.WINDOW_SCALE, rl.Color{0, 255, 255, 160})
}

// Tiles VIGR frame 0 across `rect`, native size (no stretch to fit, matching
// U_Sprite_Draw's own 1:1 placement), clipped to the rect. The original
// centres its tile grid on the rect rather than flushing the first tile to
// the top-left corner (G_Game_DrawGridInRect's own local_64[1]/[2] math);
// since the pattern is a uniform periodic one, that sub-tile phase
// difference is not visually distinguishable, so this starts flush instead
// of reproducing the centring arithmetic exactly.
@(private = "file")
level_select_draw_grid :: proc(r: ^render.Renderer, rect: rl.Rectangle) {
	tex, src, ok := render.frame_rect(&r.textures, VIGR, 0)
	if !ok {
		return
	}
	dst := rl.Rectangle {
		rect.x * render.WINDOW_SCALE, rect.y * render.WINDOW_SCALE,
		rect.width * render.WINDOW_SCALE, rect.height * render.WINDOW_SCALE,
	}
	tw := src.width * render.WINDOW_SCALE
	th := src.height * render.WINDOW_SCALE
	rl.BeginScissorMode(i32(dst.x), i32(dst.y), i32(dst.width), i32(dst.height))
	for y := dst.y; y < dst.y + dst.height; y += th {
		for x := dst.x; x < dst.x + dst.width; x += tw {
			rl.DrawTexturePro(tex, src, {x, y, tw, th}, {0, 0}, 0, rl.WHITE)
		}
	}
	rl.EndScissorMode()
}

@(private = "file")
level_select_draw_icon :: proc(r: ^render.Renderer, pos: rl.Vector2, frame: i32, hovered: bool) {
	plate := hovered ? ui.MEBH : ui.MEBU
	tex, src, ok := render.frame_rect(&r.textures, plate, frame)
	if !ok {
		return
	}
	dst := rl.Rectangle {
		(pos.x - src.width / 2) * render.WINDOW_SCALE, (pos.y - src.height / 2) * render.WINDOW_SCALE,
		src.width * render.WINDOW_SCALE, src.height * render.WINDOW_SCALE,
	}
	rl.DrawTexturePro(tex, src, dst, {0, 0}, 0, rl.WHITE)
}
