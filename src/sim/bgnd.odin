package sim

// G_Bgnd: the scrolling background. Only the scroll bookkeeping belongs to the
// simulation -- it decides when map placements spawn and how ground entities
// move -- so drawing stays in game/.
//
// Rows are map coordinates, 0 at the top of the level and growing downward;
// the view scrolls *up* the map one row per step. At level start in le07 the
// view is rows 3120..3600 (verified in the detailed oracle trace).

Bgnd :: struct {
	view_top:    i32,  // DAT_004de6f4 (also G_Bgnd_GetUpdateRectTop)
	view_bottom: i32,  // DAT_004de6fc
	map_bottom:  i32,  // DAT_004de6ec: the level's background rect bottom
	progress:    i32,  // DAT_004de704: rows revealed so far
	speed:       i32,  // DAT_004de708: rows per step, 0 while paused
	finished:    bool, // DAT_004de70c: reached the top of the map
	scrolled:    i32,  // DAT_004de71e: rows scrolled this step
	// DAT_004de70d: how far the view has slid sideways, -32..31, and
	// DAT_004de711, which way it moved this step. Only drawing reads them,
	// but a player's input moves them, so they belong to the state.
	side_scroll:     i32,
	side_scroll_dir: i32,
}

// Visible play area (perm floats 0x36, 0x37).
view_width :: proc "contextless" (d: ^Defs) -> i32 {
	return trunc_i32(d.perm_floats[PF_VISIBLE_GAME_WIDTH])
}

view_height :: proc "contextless" (d: ^Defs) -> i32 {
	return trunc_i32(d.perm_floats[PF_VISIBLE_GAME_HEIGHT])
}

// G_Bgnd_AdjustSideScroll: the view slides one pixel a step while a player
// holds left or right, to 32 pixels either way, and simply stays where it was
// left -- there is no recentring. Both players push the same view.
bgnd_adjust_side_scroll :: proc "contextless" (s: ^State, right: bool) {
	b := &s.bgnd
	b.side_scroll_dir = 0
	if right {
		b.side_scroll += 1
		if b.side_scroll < 32 {
			b.side_scroll_dir = 1
		} else {
			b.side_scroll = 31
		}
	} else {
		b.side_scroll -= 1
		if b.side_scroll < -32 {
			b.side_scroll = -32
		} else {
			b.side_scroll_dir = -1
		}
	}
}

// G_Bgnd_ResetAtLevelStart.
bgnd_reset :: proc "contextless" (s: ^State, level: ^Level_Def) {
	b := &s.bgnd
	h := view_height(s.defs)
	b^ = Bgnd{speed = 1}
	b.map_bottom = level.background.bottom
	b.view_top = b.map_bottom - h
	b.view_bottom = h + b.view_top
	b.progress = h + 1
}

// G_Bgnd_DoInitialMapSpawns: everything from the bottom of the map to 65 rows
// above the view.
bgnd_initial_spawns :: proc(s: ^State) {
	b := &s.bgnd
	n := b.view_bottom - (b.view_top - 65)
	for i in 0 ..< n {
		eg_spawn_map_row(s, b.view_bottom - i)
	}
}

// FUN_00410490: advance the scroll.
//
// The original also clamps the view to the bounds of a pixel buffer; that
// buffer covers the whole map in every level, so the clamp never fires (the
// trace shows the view scrolling from 3120 without interruption).
bgnd_scroll :: proc "contextless" (s: ^State) {
	b := &s.bgnd
	before := b.view_top
	if b.speed == 0 {
		b.scrolled = 0
		return
	}
	b.view_top -= b.speed
	b.view_bottom -= b.speed
	b.progress = clamp(b.progress + b.speed, 0, b.map_bottom)
	if b.view_top < 1 {
		b.view_top = 0
		b.view_bottom = view_height(s.defs)
	}
	b.scrolled = before - b.view_top
}

// G_Bgnd_Process. Returns true on the step the top of the map is reached.
bgnd_process :: proc(s: ^State) -> (level_done: bool) {
	b := &s.bgnd
	bgnd_scroll(s)
	if b.speed == 0 {
		return b.finished
	}
	if b.progress < b.map_bottom {
		eg_spawn_map_row(s, b.view_top - 64)
		return false
	}
	b.progress = b.map_bottom
	b.finished = true
	b.speed = 0
	return true
}

bgnd_stop :: proc "contextless" (s: ^State) {
	s.bgnd.speed = 0
}

bgnd_resume :: proc "contextless" (s: ^State) {
	if !s.bgnd.finished {
		s.bgnd.speed = 1
	}
}
