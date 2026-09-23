package game

// Phase 7 stage 4: the 15-slot high score table shared by the plain viewer
// (menu_high_scores.odin) and the post-game name-entry prompt
// (menu_high_score_entry.odin). Traced from G_Scores_GetPlayerNamesAndDisplay
// _03b3a0.c, G_Scores_IsAHighScore_03b360.c and FUN_0043c480.c (all read in
// full): a fixed 15-entry table of (name, score, sector) triples, sorted
// descending by score, no rank number ever drawn as text (rank is implied by
// row position alone).
//
// This reimplementation's persistence (an XDG data file, like progress.odin's
// "highest level reached") stands in for the original's U_Prefs blob, which
// the real game backs with the Win32 registry -- see progress.odin's own
// file-header note for why this project picked that convention.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

HIGH_SCORE_SLOTS :: 15

High_Score_Entry :: struct {
	name:   string,
	score:  int,
	sector: string,
}

// The default table's names, recovered from U_Prefs_SetHighScoresToDefaults
// _0085d0.c (read in full): a static cleartext table at DAT_004d9577 is
// XOR/nibble-swap "encrypted" (U_Utils_String_Encrypt_00f740.c, read in
// full -- an involution, so decrypting is the same transform) into the live
// prefs blob on first run. Recovered by applying that same transform to the
// raw bytes peeked directly from the executable (python3 tools/decomp/peek.py),
// not guessed. Every default slot's sector is "New Atlantis" and scores
// descend 15000..1000 in flat 1000-point steps (also read directly from
// U_Prefs_SetHighScoresToDefaults's `iVar1 * -1000 + 16000`). These are
// Deimos Rising dev-team nicknames, the same pool Credits and the name-entry
// easter eggs draw from (menu_credits.odin's CREDITS_PAGES, menu_high_score
// _entry.odin's substitution table).
@(private = "file")
HIGH_SCORE_DEFAULT_NAMES := [HIGH_SCORE_SLOTS]string {
	"Mars", "Supercobra", "Neurotik", "El B", "Dilvish", "Sam", "Vodi", "Fisj",
	"Alex", "h'biki", "Goldenberry", "Leadfeather", "Troll", "Thomas", "Electrofryer",
}

high_scores_default :: proc() -> [HIGH_SCORE_SLOTS]High_Score_Entry {
	table: [HIGH_SCORE_SLOTS]High_Score_Entry
	for i in 0 ..< HIGH_SCORE_SLOTS {
		table[i] = {HIGH_SCORE_DEFAULT_NAMES[i], (HIGH_SCORE_SLOTS - i) * 1000, "New Atlantis"}
	}
	return table
}

// Player 1/2's last-entered name (U_Prefs_SetHighScoresToDefaults's "Player
// %i" sprintf, at the two slots FUN_0043bb00 reads/writes at offset 0x1233 --
// immediately after the 15-slot name table ends, confirmed contiguous:
// 0x10f8 + 15*0x15 == 0x1233). FUN_0043bb00 pre-fills the name-entry text box
// from this cache before the player types anything, and updates it as they
// type -- reproduced in menu_high_score_entry.odin.
high_scores_default_last_name :: proc(player: int) -> string {
	return fmt.tprintf("Player %d", player + 1)
}

// File format: one line per field, 15 entries (score, name, sector) followed
// by the two last-entered-name cache lines -- plain and line-oriented like
// progress.odin's save file, not the original's binary U_Prefs layout, since
// nothing outside this reimplementation ever reads it.
High_Scores_Save :: struct {
	table:            [HIGH_SCORE_SLOTS]High_Score_Entry,
	last_name_player: [2]string,
}

high_scores_load :: proc() -> High_Scores_Save {
	fallback := High_Scores_Save {
		table            = high_scores_default(),
		last_name_player = {high_scores_default_last_name(0), high_scores_default_last_name(1)},
	}
	path := user_data_path("highscores", context.temp_allocator)
	if path == "" {
		return fallback
	}
	bytes, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return fallback
	}
	lines := strings.split(strings.trim_right(string(bytes), "\n"), "\n", context.temp_allocator)
	if len(lines) != HIGH_SCORE_SLOTS * 3 + 2 {
		return fallback
	}
	out: High_Scores_Save
	for i in 0 ..< HIGH_SCORE_SLOTS {
		score, ok := strconv.parse_int(lines[i * 3])
		if !ok {
			return fallback
		}
		out.table[i] = {strings.clone(lines[i * 3 + 1]), score, strings.clone(lines[i * 3 + 2])}
	}
	out.last_name_player[0] = strings.clone(lines[HIGH_SCORE_SLOTS * 3])
	out.last_name_player[1] = strings.clone(lines[HIGH_SCORE_SLOTS * 3 + 1])
	return out
}

high_scores_save :: proc(save: ^High_Scores_Save) {
	sb := strings.builder_make(context.temp_allocator)
	for e in save.table {
		fmt.sbprintf(&sb, "%d\n%s\n%s\n", e.score, e.name, e.sector)
	}
	fmt.sbprintf(&sb, "%s\n%s\n", save.last_name_player[0], save.last_name_player[1])
	user_data_write("highscores", strings.to_string(sb))
}

// G_Scores_IsAHighScore_03b360.c (read in full): `local_22cf < param_1`,
// where local_22cf is the current 15th/lowest slot's score -- "does this
// score beat the current lowest entry."
high_scores_qualifies :: proc(table: ^[HIGH_SCORE_SLOTS]High_Score_Entry, score: int) -> bool {
	return table[HIGH_SCORE_SLOTS - 1].score < score
}

// G_Scores_GetPlayerNamesAndDisplay_03b3a0.c (read in full): computes
// insertion rank, shifts lower entries down one slot, drops the old last
// slot. Ties keep the existing entry ranked higher (strict `<` in
// high_scores_qualifies above, mirrored here).
high_scores_insert :: proc(table: ^[HIGH_SCORE_SLOTS]High_Score_Entry, name: string, score: int, sector: string) -> (rank: int, ok: bool) {
	if !high_scores_qualifies(table, score) {
		return -1, false
	}
	rank = HIGH_SCORE_SLOTS - 1
	for rank > 0 && table[rank - 1].score < score {
		rank -= 1
	}
	for i := HIGH_SCORE_SLOTS - 1; i > rank; i -= 1 {
		table[i] = table[i - 1]
	}
	table[rank] = {name, score, sector}
	return rank, true
}
