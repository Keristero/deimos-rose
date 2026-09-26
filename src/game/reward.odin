package game

// Easy mode's reward screen, drawn over the frozen play area while
// its screen is open (plugins/easy_mode holds it and takes the choices). New content: no original screen to match. Everything is read
// from the state, so both netplay peers draw the same screen from the same
// frame.
//
// A grid of icons, as many columns and rows as the options need, above a
// description box of fixed size that the grid never runs into. Each player
// choosing has a border in their accent round the option they are on, dull
// until they lock it in; players on the same option nest their borders,
// player 1 innermost. The box describes, for each player, the option they
// are on: every stat it changes at the level it would give them, current
// value to new.

import "core:fmt"

import rl "vendor:raylib"

import "dr:prefs"
import "dr:plugins/easy_mode"
import "dr:plugins/passives"
import "dr:sim"

@(private = "file") CX :: VIEW_X + PLAY_W / 2
@(private = "file") TITLE_Y :: 48
@(private = "file") HINT_Y :: 68
@(private = "file") GRID_TOP :: 96
@(private = "file") GRID_BOTTOM :: 240 // the grid shrinks its cells to stay above the box
@(private = "file") GRID_SIDE :: 24    // margin inside the play area
@(private = "file") CELL_MAX :: 60
@(private = "file") CELL_GAP :: 20     // room for two nested borders each side
@(private = "file") BORDER_FIRST :: 3  // the innermost border's distance out from the cell
@(private = "file") BORDER_STEP :: 4
@(private = "file") BORDER_WIDTH :: 2
@(private = "file") BOX_X :: VIEW_X + 16
@(private = "file") BOX_W :: PLAY_W - 32
@(private = "file") BOX_Y :: 256
@(private = "file") BOX_H :: 208
@(private = "file") BOX_PAD :: 10
@(private = "file") LINE :: 14

// The border and text colours: an accent, dull until locked in.
@(private = "file")
reward_accent :: proc(hue: f32, locked: bool) -> rl.Color {
	return locked ? rl.ColorFromHSV(hue, ACCENT_SATURATION, 1) : rl.ColorFromHSV(hue, 0.35, 0.55)
}

@(private = "file")
reward_player_label :: proc(fl: ^Flow, i: int) -> string {
	if fl.session_named {
		return prefs.name_string(&fl.session_names[i])
	}
	return i == 0 ? "P1" : "P2"
}

// Where option k's cell sits, in menu coordinates.
@(private = "file")
reward_cell :: proc(count, k: i32) -> rl.Rectangle {
	cols := easy_mode.reward_grid_columns(count)
	rows := (count + cols - 1) / cols
	cell := min(f32(CELL_MAX),
		(f32(PLAY_W - 2 * GRID_SIDE) - f32(cols - 1) * CELL_GAP) / f32(cols),
		(f32(GRID_BOTTOM - GRID_TOP) - f32(rows - 1) * CELL_GAP) / f32(rows))
	row, col := k / cols, k % cols
	in_row := min(cols, count - row * cols) // a short last row is centred on its own
	width := f32(in_row) * cell + f32(in_row - 1) * CELL_GAP
	height := f32(rows) * cell + f32(rows - 1) * CELL_GAP
	top := f32(GRID_TOP) + (f32(GRID_BOTTOM - GRID_TOP) - height) / 2
	return {CX - width / 2 + f32(col) * (cell + CELL_GAP), top + f32(row) * (cell + CELL_GAP), cell, cell}
}

@(private = "file")
window_rect :: proc(r: rl.Rectangle) -> rl.Rectangle {
	return {r.x * WINDOW_SCALE, r.y * WINDOW_SCALE, r.width * WINDOW_SCALE, r.height * WINDOW_SCALE}
}

reward_draw :: proc(fl: ^Flow, r: ^Renderer) {
	s := fl.state
	rw := easy_mode.reward_of(s)
	if rw == nil || !rw.active {
		return
	}
	white := rl.Color{255, 255, 255, 255}
	dim := rl.Color{170, 170, 170, 255}
	header := rl.Color{HIGH_SCORES_HEADER_RGB[0], HIGH_SCORES_HEADER_RGB[1], HIGH_SCORES_HEADER_RGB[2], 255}
	rl.DrawRectangleRec(window_rect({VIEW_X, 0, PLAY_W, PLAY_H}), {0, 0, 0, 170})
	menu_draw_text(r, "CHOOSE AN UPGRADE", CX, TITLE_Y, header, .Centre)
	menu_draw_text(r, "MOVE TO PICK -- FIRE AIR LOCKS IN -- FIRE GROUND CHANGES", CX, HINT_Y, dim, .Centre)

	for k in 0 ..< rw.count {
		cell := reward_cell(rw.count, k)
		rl.DrawRectangleRec(window_rect(cell), {16, 20, 28, 230})
		rl.DrawRectangleLinesEx(window_rect(cell), WINDOW_SCALE, {70, 80, 92, 255})
		reward_draw_icon(r, rw.options[k], cell)
		// The borders of everyone on this option, nested in player order.
		ring := 0
		for i in 0 ..< sim.MAX_PLAYERS {
			if !rw.choosing[i] || rw.cursor[i] != k {
				continue
			}
			out := f32(BORDER_FIRST + ring * BORDER_STEP)
			b := rl.Rectangle{cell.x - out, cell.y - out, cell.width + 2 * out, cell.height + 2 * out}
			rl.DrawRectangleLinesEx(window_rect(b), BORDER_WIDTH * WINDOW_SCALE, reward_accent(r.accents[i].hue, rw.locked[i]))
			ring += 1
		}
	}

	rl.DrawRectangleRec(window_rect({BOX_X, BOX_Y, BOX_W, BOX_H}), {10, 12, 18, 235})
	rl.DrawRectangleLinesEx(window_rect({BOX_X, BOX_Y, BOX_W, BOX_H}), WINDOW_SCALE, {90, 100, 112, 255})
	y := i32(BOX_Y + BOX_PAD)
	left, right := i32(BOX_X + BOX_PAD), i32(BOX_X + BOX_W - BOX_PAD)
	for i in 0 ..< sim.MAX_PLAYERS {
		if !rw.choosing[i] {
			continue
		}
		pa := rw.options[rw.cursor[i]]
		levels := passives.levels_of(s, i)
		def := &passives.PASSIVES[pa]
		accent := reward_accent(r.accents[i].hue, true)
		menu_draw_text(r, reward_player_label(fl, i), left, y, accent)
		status := rw.locked[i] ? "LOCKED IN" : easy_mode.reward_ready(s, i) ? "NOTHING LEFT TO TAKE" : "CHOOSING"
		menu_draw_text(r, status, right, y, rw.locked[i] ? accent : dim, .Right)
		y += LINE
		if passives.passive_maxed(levels, pa) {
			menu_draw_text(r, fmt.tprintf("%s: AT ITS HIGHEST LEVEL", PASSIVE_NAMES[pa]), left, y, dim)
			y += LINE + LINE / 2
			continue
		}
		next := levels[pa] + 1
		menu_draw_text(r, fmt.tprintf("%s  LEVEL %d/%d", PASSIVE_NAMES[pa], next, def.levels), left, y, white)
		y += LINE
		if !easy_mode.reward_selectable(s, i, rw.cursor[i]) {
			menu_draw_text(r, "TAKEN BY THE OTHER PLAYER", left, y, dim)
			y += LINE
		}
		after := levels^
		after[pa] = next
		for m in def.mods {
			// A stat the new level leaves as it was is not listed.
			if m.at[next - 1] == passives.X {
				continue
			}
			menu_draw_text(r, STAT_DISPLAY[m.stat].label, left + 8, y, dim)
			change := fmt.tprintf("%s -> %s", stat_text(levels, m.stat, def.weapon), stat_text(&after, m.stat, def.weapon))
			menu_draw_text(r, change, right, y, white, .Right)
			y += LINE
		}
		y += LINE / 2
	}
}

// The option's icon, centred in its cell at the largest whole multiple of
// its size, in window pixels, that fits.
@(private = "file")
reward_draw_icon :: proc(r: ^Renderer, pa: passives.Passive, cell: rl.Rectangle) {
	tex, ok := passive_icon(&r.textures, pa)
	if !ok {
		return
	}
	room := (cell.width - 12) * WINDOW_SCALE
	k := max(f32(int(min(room / f32(tex.width), room / f32(tex.height)))), 1)
	w, h := f32(tex.width) * k, f32(tex.height) * k
	at := window_rect(cell)
	dst := rl.Rectangle{at.x + (at.width - w) / 2, at.y + (at.height - h) / 2, w, h}
	rl.DrawTexturePro(tex, {0, 0, f32(tex.width), f32(tex.height)}, dst, {0, 0}, 0, rl.WHITE)
}
