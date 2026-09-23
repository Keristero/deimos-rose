package game

// Phase 7 stage 4: the post-game name-entry prompt, shown once per qualifying
// player right after Game Over/Complete. Traced from FUN_0043bb00.c (read in
// full, the per-player name-entry screen) and its callers
// G_Scores_GetPlayerNamesAndDisplay_03b3a0.c and G_Scores_IsAHighScore
// _03b360.c (both read in full) -- see docs/phase-7-faithful-menus.md's
// Stage 4 notes.
//
// Same fade-in/fade-out shape as Credits and the plain viewer
// (menu_credits.odin, menu_high_scores.odin), but with an "Editing" state in
// the middle instead of a passive hold: FUN_0043bb00 runs its own text-entry
// loop (backspace/enter/escape/printable char), each keystroke immediately
// re-rendering that one row in place. Reimplemented here with raylib's
// GetCharPressed (proper keyboard-layout-aware text input) rather than
// replicating the original's raw scan-code branches (8/10/13/0x5e5b) --
// this project's established practice for input-adjacent code that has no
// simulation determinism to preserve (see e.g. menu_level_select.odin).
//
// Escape (FUN_0043bb00's `local_8d = '\0'` on scan-code 0x5e5b, which skips
// straight past the hold-and-save path) is simplified to cancel this whole
// name-entry sequence outright -- not committing the row currently being
// edited, and not attempting the remaining queued player -- rather than
// reproducing the original's byte-for-byte partial-table-shift-undo, which
// the decompiled corpus doesn't make fully traceable (see the summary this
// stage's research left in docs/phase-7-faithful-menus.md). Any earlier
// player in the same session who already pressed Enter has already been
// persisted (high_scores_save is called immediately on each commit, not
// batched to the end), so cancelling the second player's turn never loses
// the first player's saved entry.

import "core:fmt"
import "core:strings"

import rl "vendor:raylib"

import "dr:sim"

@(private = "file") HSE_TICK_HZ :: 60.0
@(private = "file") HSE_FADE_SECONDS :: 32.0 / HSE_TICK_HZ
@(private = "file") HSE_HOLD_SECONDS :: 25.0 / HSE_TICK_HZ  // Scores_DurationBetweenPlayers, perm float 0x4f
@(private = "file") HSE_BLINK_ON_SECONDS :: 30.0 / HSE_TICK_HZ  // Scores_PromptFlashDelayAfterKeyHit, perm float 0x52
@(private = "file") HSE_BLINK_OFF_SECONDS :: 10.0 / HSE_TICK_HZ // Scores_PromptDelayBetweenFlashes, perm float 0x53
@(private = "file") HSE_NAME_MAX :: 20 // acStack_61's 0x14 length cap

@(private = "file") HSE_INCL_SOUND :: sim.Res_ID{'i', 'n', 'c', 'l'} // backspace (idx 2) and commit (idx 4) -- both "incl"
@(private = "file") HSE_TYPE_SOUND :: sim.Res_ID{'c', 'l', 'i', 'c'} // ordinary character, idx 0
@(private = "file") HSE_FULL_SOUND :: sim.Res_ID{'s', 'h', 'w', 'a'} // buffer full, idx 15 ("ScoreEntryFailure")
// idx 9 ("HighScoreAchieved"), played once when a player's screen opens, is
// "none" in idli/gaso.json -- no actual sound resource, so there is nothing
// to play here at all.

// Same layout constants as the plain viewer (menu_high_scores.odin) -- the
// row this player is editing draws at the same column positions, since both
// screens share FUN_0043c480's row builder and its perm floats 0x4c-0x51.
Score_Entry_State :: enum {
	Fading_In,
	Editing,
	Held,
	Fading_Out,
}

Score_Entry :: struct {
	state:     Score_Entry_State,
	t:         f32,
	table:     [HIGH_SCORE_SLOTS]High_Score_Entry, // working copy; persisted on each commit
	last_name: [2]string,
	ranks:     [2]int, // this session's insertion rank per player, -1 if that player didn't qualify
	player_i:  int,    // which of ranks[] is currently being edited
	name_buf:  [HSE_NAME_MAX]u8,
	name_len:  int,
	blink_on:  bool,
	blink_t:   f32,
	done:      bool, // no more queued players -- flow.odin returns to Title
}

// Called from flow.odin once Game Over/Complete's hold timer runs out (or is
// skipped). Builds the insertion queue for both players up front -- ranking
// only depends on score, not on the name eventually typed, so both players'
// slots can be reserved (with their cached last-used name as a placeholder,
// exactly as FUN_0043bb00 pre-fills its edit buffer) before either screen
// runs, matching G_Scores_GetPlayerNamesAndDisplay's own two-pass shape.
// Returns false (and leaves se untouched) if neither player qualifies, so
// the caller can skip the mode switch entirely.
score_entry_start :: proc(se: ^Score_Entry, player_scores: [sim.MAX_PLAYERS]int, player_active: [sim.MAX_PLAYERS]bool, sector: string) -> bool {
	save := high_scores_load()
	table := save.table
	ranks := [sim.MAX_PLAYERS]int{-1, -1}
	any := false
	for i in 0 ..< sim.MAX_PLAYERS {
		if !player_active[i] {
			continue
		}
		if rank, ok := high_scores_insert(&table, save.last_name_player[i], player_scores[i], sector); ok {
			ranks[i] = rank
			any = true
		}
	}
	if !any {
		return false
	}
	se^ = Score_Entry{table = table, last_name = save.last_name_player, ranks = ranks, player_i = -1}
	score_entry_advance(se)
	return true
}

@(private = "file")
score_entry_advance :: proc(se: ^Score_Entry) {
	for {
		se.player_i += 1
		if se.player_i >= sim.MAX_PLAYERS {
			se.done = true
			return
		}
		if se.ranks[se.player_i] >= 0 {
			break
		}
	}
	name := se.last_name[se.player_i]
	if len(name) > HSE_NAME_MAX {
		name = name[:HSE_NAME_MAX]
	}
	se.name_len = copy(se.name_buf[:], name)
	se.state, se.t = .Fading_In, 0
	se.blink_on, se.blink_t = true, 0
}

@(private = "file")
score_entry_typed :: proc(se: ^Score_Entry) -> string {
	return string(se.name_buf[:se.name_len])
}

// Called once per render frame from flow_handle_input's .Score_Entry case.
score_entry_update :: proc(fl: ^Flow, r: ^Renderer, se: ^Score_Entry) {
	dt := rl.GetFrameTime()
	se.t += dt

	switch se.state {
	case .Fading_In:
		if se.t >= HSE_FADE_SECONDS {
			se.state, se.t = .Editing, 0
		}

	case .Editing:
		score_entry_blink(se, dt)

		for c := rl.GetCharPressed(); c != 0; c = rl.GetCharPressed() {
			if c < 0x20 || c > 0x7e {
				continue // _isprint -- ASCII-only, matching the original's own charset
			}
			if se.name_len < HSE_NAME_MAX {
				se.name_buf[se.name_len] = u8(c)
				se.name_len += 1
				menu_play_sound(r, HSE_TYPE_SOUND)
			} else {
				menu_play_sound(r, HSE_FULL_SOUND)
			}
		}
		if rl.IsKeyPressed(.BACKSPACE) && se.name_len > 0 {
			se.name_len -= 1
			menu_play_sound(r, HSE_INCL_SOUND)
		}
		if rl.IsKeyPressed(.ESCAPE) {
			se.done = true
			se.state, se.t = .Fading_Out, 0
		} else if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
			score_entry_commit(se)
			menu_play_sound(r, HSE_INCL_SOUND)
			se.state, se.t = .Held, 0
		}

	case .Held:
		if rl.GetKeyPressed() != .KEY_NULL || rl.IsMouseButtonPressed(.LEFT) || se.t >= HSE_HOLD_SECONDS {
			se.state, se.t = .Fading_Out, 0
		}

	case .Fading_Out:
		if se.t >= HSE_FADE_SECONDS {
			if se.done {
				fl.mode = .Title
			} else {
				score_entry_advance(se)
			}
		}
	}
}

@(private = "file")
score_entry_blink :: proc(se: ^Score_Entry, dt: f32) {
	se.blink_t += dt
	threshold := se.blink_on ? f32(HSE_BLINK_ON_SECONDS) : f32(HSE_BLINK_OFF_SECONDS)
	if se.blink_t >= threshold {
		se.blink_on = !se.blink_on
		se.blink_t = 0
	}
}

// FUN_0043bb00's easter-egg substitution chain (all five substring checks
// run unconditionally in this exact order, last match wins; the empty-name
// fallback is checked against the *original* typed text, independent of any
// substitution already applied) -- see docs/phase-7-faithful-menus.md's
// Stage 4 notes for how these were recovered (python3 tools/decomp/peek.py
// against the raw executable strings, cross-checked against Credits' own
// dev-team nicknames).
@(private = "file")
score_entry_commit :: proc(se: ^Score_Entry) {
	typed := score_entry_typed(se)
	upper := strings.to_upper(typed, context.temp_allocator)
	final := typed
	if strings.contains(upper, "BIKI") {
		final = "Filthy Communist"
	}
	if strings.contains(upper, "DILVISH") {
		final = "Just Ship It, Baby"
	}
	if strings.contains(upper, "SUPERCOBRA") {
		final = "Munkis Rool J00"
	}
	if strings.contains(upper, "PYTHOS") {
		final = "Leonard Cohen Rules J00"
	}
	if strings.contains(upper, "FISJ") {
		final = "Daikajinn!!"
	}
	if upper == "" {
		final = "Jar Jar Must Die"
	}

	rank := se.ranks[se.player_i]
	se.table[rank].name = final
	se.last_name[se.player_i] = final

	save := High_Scores_Save{table = se.table, last_name_player = se.last_name}
	high_scores_save(&save)
}

score_entry_draw :: proc(r: ^Renderer, se: ^Score_Entry) {
	menu_draw_background(r, "back")

	alpha: f32
	switch se.state {
	case .Fading_In:
		alpha = clamp(se.t / HSE_FADE_SECONDS, 0, 1)
	case .Editing, .Held:
		alpha = 1
	case .Fading_Out:
		alpha = 1 - clamp(se.t / HSE_FADE_SECONDS, 0, 1)
	}
	a := u8(alpha * 255)
	header := rl.Color{HIGH_SCORES_HEADER_RGB[0], HIGH_SCORES_HEADER_RGB[1], HIGH_SCORES_HEADER_RGB[2], a}
	// FUN_0043c480 gives the actively-edited row its own preset (0xe/0x11/0x14)
	// distinct from every other name-entry-mode row (0xf/0x12/0x15), but
	// neither has a decompiled colour value -- both draw the same plain white
	// here as the viewer's rows. The blinking cursor is the only thing that
	// marks the active row.
	row_color := rl.Color{HIGH_SCORES_ROW_RGB[0], HIGH_SCORES_ROW_RGB[1], HIGH_SCORES_ROW_RGB[2], a}

	menu_draw_text(r, "Name", HIGH_SCORES_NAME_X, HIGH_SCORES_HEADER_Y, header)
	menu_draw_text(r, "Score", HIGH_SCORES_SCORE_X, HIGH_SCORES_HEADER_Y, header)
	menu_draw_text(r, "Sector", HIGH_SCORES_SECTOR_X, HIGH_SCORES_HEADER_Y, header)
	y := f32(HIGH_SCORES_ROW0_Y)

	rank := se.ranks[se.player_i]
	for i in 0 ..< HIGH_SCORE_SLOTS {
		e := se.table[i]
		name := e.name
		color := row_color
		if i == rank {
			name = score_entry_typed(se)
			if se.state == .Editing && se.blink_on && len(name) < HSE_NAME_MAX {
				name = strings.concatenate({name, "_"}, context.temp_allocator) // perm game string 7
			}
		}
		menu_draw_text(r, name, HIGH_SCORES_NAME_X, i32(y), color)
		menu_draw_text(r, fmt.tprintf("%d", e.score), HIGH_SCORES_SCORE_X, i32(y), color)
		menu_draw_text(r, e.sector, HIGH_SCORES_SECTOR_X, i32(y), color)
		y += HIGH_SCORES_ROW_GAP
	}
}
