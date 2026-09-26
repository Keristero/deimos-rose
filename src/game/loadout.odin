package game

// New Weapons' loadout screen, drawn over the frozen play area while
// its screen is open (plugins/loadout holds it and takes the choices). New content: no original screen to match. Everything is read
// from the state, so both netplay peers draw the same screen from the same
// frame.
//
// One panel for each player choosing, stacked. A panel has a row of cells
// for each of the board's rows that is shown: the new weapons still to be
// placed, the loadout, the spares; then READY. A weapon new this stage is
// lit in the header's colour wherever it sits, so one placed straight into a
// free slot shows where it went. The cursor has a border in the player's
// accent. A weapon picked up keeps its cell, lit in the
// accent, until it is put down. Under the rows, the weapon under the cursor
// (or the one being moved) is named and described.

import "core:fmt"
import "core:strings"

import rl "vendor:raylib"

import "dr:plugins/loadout"
import "dr:prefs"
import "dr:render"
import "dr:sim"
import "dr:ui"

@(private = "file") CX :: render.VIEW_X + render.PLAY_W / 2
@(private = "file") TITLE_Y :: 48
@(private = "file") HINT_Y :: 68
@(private = "file") PANELS_TOP :: 84
@(private = "file") PANEL_X :: render.VIEW_X + 16
@(private = "file") PANEL_W :: render.PLAY_W - 32
@(private = "file") PANEL_GAP :: 8
@(private = "file") PAD :: 6
@(private = "file") LINE :: 14
@(private = "file") LABEL_W :: 72 // row labels, left of the cells
@(private = "file") CELL :: 28    // a weapon symbol is 26 pixels square
@(private = "file") CELL_GAP :: 6
@(private = "file") ROW_H :: CELL + 6
@(private = "file") READY_W :: 72
@(private = "file") READY_H :: 18
@(private = "file") BORDER :: 2

@(private = "file")
ROW_LABELS := [loadout.Loadout_Row]string {
	.Fresh = "NEW",
	.Slots = "LOADOUT",
	.Spare = "SPARE",
	.Ready = "",
}

@(private = "file")
loadout_accent :: proc(hue: f32, bright: bool) -> rl.Color {
	return bright ? rl.ColorFromHSV(hue, render.ACCENT_SATURATION, 1) : rl.ColorFromHSV(hue, 0.35, 0.55)
}

@(private = "file")
loadout_player_label :: proc(fl: ^Flow, i: int) -> string {
	if fl.session_named {
		return prefs.name_string(&fl.session_names[i])
	}
	return i == 0 ? "P1" : "P2"
}

@(private = "file")
window_rect :: proc(r: rl.Rectangle) -> rl.Rectangle {
	return {r.x * render.WINDOW_SCALE, r.y * render.WINDOW_SCALE, r.width * render.WINDOW_SCALE, r.height * render.WINDOW_SCALE}
}

// A panel's height: its header, a line for each row shown, READY, and the
// weapon's name and two lines of description. Two full panels (three rows
// each) just fit the play area.
@(private = "file")
panel_height :: proc(b: ^loadout.Loadout_Board) -> f32 {
	h := f32(PAD + LINE)
	for row in loadout.Loadout_Row {
		if row != .Ready && b.width[row] > 0 {
			h += ROW_H
		}
	}
	return h + READY_H + 4 + 3 * LINE + PAD
}

loadout_draw :: proc(fl: ^Flow, r: ^render.Renderer) {
	s := fl.state
	l := loadout.loadout_of(s)
	if l == nil || !l.active {
		return
	}
	dim := rl.Color{170, 170, 170, 255}
	header := rl.Color{ui.HIGH_SCORES_HEADER_RGB[0], ui.HIGH_SCORES_HEADER_RGB[1], ui.HIGH_SCORES_HEADER_RGB[2], 255}
	rl.DrawRectangleRec(window_rect({render.VIEW_X, 0, render.PLAY_W, render.PLAY_H}), {0, 0, 0, 170})
	ui.menu_draw_text(r, "LOADOUT", CX, TITLE_Y, header, .Centre)
	ui.menu_draw_text(r, "FIRE AIR PICKS UP AND PUTS DOWN -- FIRE GROUND PUTS BACK", CX, HINT_Y, dim, .Centre)

	y := f32(PANELS_TOP)
	for i in 0 ..< sim.MAX_PLAYERS {
		if !l.choosing[i] {
			continue
		}
		b := &l.boards[i]
		h := panel_height(b)
		loadout_draw_panel(fl, r, i, b, {PANEL_X, y, PANEL_W, h})
		y += h + PANEL_GAP
	}
}

@(private = "file")
loadout_draw_panel :: proc(fl: ^Flow, r: ^render.Renderer, i: int, b: ^loadout.Loadout_Board, panel: rl.Rectangle) {
	s := fl.state
	white := rl.Color{255, 255, 255, 255}
	dim := rl.Color{170, 170, 170, 255}
	header := rl.Color{ui.HIGH_SCORES_HEADER_RGB[0], ui.HIGH_SCORES_HEADER_RGB[1], ui.HIGH_SCORES_HEADER_RGB[2], 255}
	hue := r.accents[i].hue
	accent := loadout_accent(hue, true)
	rl.DrawRectangleRec(window_rect(panel), {10, 12, 18, 235})
	rl.DrawRectangleLinesEx(window_rect(panel), render.WINDOW_SCALE, {90, 100, 112, 255})

	left, right := i32(panel.x) + PAD, i32(panel.x + panel.width) - PAD
	y := i32(panel.y) + PAD
	ui.menu_draw_text(r, loadout_player_label(fl, i), left, y, accent)
	status := b.ready ? "READY" : b.holding ? "MOVING A WEAPON" : "CHOOSING"
	ui.menu_draw_text(r, status, right, y, b.ready ? accent : dim, .Right)
	y += LINE

	for row in loadout.Loadout_Row {
		if row == .Ready || b.width[row] == 0 {
			continue
		}
		ui.menu_draw_text(r, ROW_LABELS[row], left, y + (CELL - LINE) / 2 + 2, row == .Fresh ? header : dim)
		for col in 0 ..< b.width[row] {
			cell := rl.Rectangle{f32(left + LABEL_W + col * (CELL + CELL_GAP)), f32(y), CELL, CELL}
			held := b.holding && b.hold_row == row && b.hold_col == col
			w := b.cells[row][col]
			// Until the screen closes the player's handler still has only
			// what they held before it.
			fresh := w != sim.NO_WEAPON && !loadout.loadout_holds(loadout.slots_of(s, i), w)
			fill, edge := rl.Color{16, 20, 28, 230}, rl.Color{70, 80, 92, 255}
			if fresh {
				fill, edge = {header.r / 3, header.g / 3, header.b / 3, 230}, header
			}
			if held {
				fill = loadout_accent(hue, false)
			}
			rl.DrawRectangleRec(window_rect(cell), fill)
			rl.DrawRectangleLinesEx(window_rect(cell), render.WINDOW_SCALE, edge)
			if w != sim.NO_WEAPON {
				loadout_draw_symbol(r, &s.defs.weapons[w], cell, held ? 150 : 255)
			}
			if !b.ready && b.row == row && b.col == col {
				out := f32(3)
				ring := rl.Rectangle{cell.x - out, cell.y - out, cell.width + 2 * out, cell.height + 2 * out}
				rl.DrawRectangleLinesEx(window_rect(ring), BORDER * render.WINDOW_SCALE, accent)
			}
		}
		y += ROW_H
	}

	// READY, under the cells.
	ready := rl.Rectangle{f32(left + LABEL_W), f32(y), READY_W, READY_H}
	on := b.row == .Ready && !b.ready
	can := loadout.loadout_can_ready(b)
	fill := b.ready ? loadout_accent(hue, false) : rl.Color{16, 20, 28, 230}
	rl.DrawRectangleRec(window_rect(ready), fill)
	rl.DrawRectangleLinesEx(window_rect(ready), (on ? BORDER : 1) * render.WINDOW_SCALE, on || b.ready ? accent : rl.Color{70, 80, 92, 255})
	ui.menu_draw_text(r, "READY", i32(ready.x + ready.width / 2), y + (READY_H - LINE) / 2 + 2, can || b.ready ? white : dim, .Centre)
	y += READY_H + 4

	// What the cursor is on.
	switch {
	case b.ready:
		ui.menu_draw_text(r, "WAITING -- FIRE GROUND TO CHANGE", left, y, dim)
	case b.row == .Ready:
		if !can {
			fresh := false
			for w in b.cells[.Fresh][:b.width[.Fresh]] {
				fresh ||= w != sim.NO_WEAPON
			}
			why := b.holding ? "PUT THE WEAPON DOWN FIRST" : fresh ? "PLACE THE NEW WEAPONS FIRST" : "FILL THE LOADOUT FIRST"
			ui.menu_draw_text(r, why, left, y, dim)
		}
	case:
		w := b.holding ? b.cells[b.hold_row][b.hold_col] : b.cells[b.row][b.col]
		if w == sim.NO_WEAPON {
			ui.menu_draw_text(r, "EMPTY", left, y, dim)
			break
		}
		def := &s.defs.weapons[w]
		name := loadout_weapon_name(def)
		if b.holding {
			name = fmt.tprintf("MOVING %s", name)
		}
		ui.menu_draw_text(r, name, left, y, white)
		loadout_draw_wrapped(r, strings.to_upper(strings.trim_space(def.description1), context.temp_allocator), left, y + LINE, right - left, 2, dim)
	}
}

// "Air - Bacta Gun" is shown as BACTA GUN.
loadout_weapon_name :: proc(w: ^sim.Weapon) -> string {
	name := strings.trim_prefix(w.name, "Air - ")
	return strings.to_upper(name, context.temp_allocator)
}

// The weapon's score bar symbol, centred in its cell at the largest whole
// multiple of its size, in window pixels, that fits.
@(private = "file")
loadout_draw_symbol :: proc(r: ^render.Renderer, w: ^sim.Weapon, cell: rl.Rectangle, alpha: u8) {
	tex, src, ok := render.frame_rect(&r.textures, w.score_bar_preview_face, w.score_bar_preview_frame)
	if !ok {
		return
	}
	room := cell.width * render.WINDOW_SCALE
	k := max(f32(int(min(room / src.width, room / src.height))), 1)
	ww, hh := src.width * k, src.height * k
	at := window_rect(cell)
	dst := rl.Rectangle{at.x + (at.width - ww) / 2, at.y + (at.height - hh) / 2, ww, hh}
	rl.DrawTexturePro(tex, src, dst, {0, 0}, 0, {255, 255, 255, alpha})
}

// Word-wrapped text, at most `lines` lines of `width`; what is left over
// is dropped.
@(private = "file")
loadout_draw_wrapped :: proc(r: ^render.Renderer, text: string, x, y, width: i32, lines: int, color: rl.Color) {
	rest := text
	for n in 0 ..< lines {
		if rest == "" {
			return
		}
		fit := len(rest)
		if render.text_width(r, rest) > width {
			fit = 0
			for k in 1 ..= len(rest) {
				if (k == len(rest) || rest[k] == ' ') && render.text_width(r, rest[:k]) <= width {
					fit = k
				}
			}
			if fit == 0 {
				fit = len(rest)
			}
		}
		ui.menu_draw_text(r, rest[:fit], x, y + i32(n) * LINE, color)
		rest = strings.trim_left_space(rest[fit:])
	}
}
