package sim

// New Weapons' loadout: new content, not the original's (the design is
// notes/new-weapons.md, what was built docs/new-weapons.md). A player holds
// air weapons in a loadout of three, which Change_Air cycles through, and
// keeps the rest as spares. At the start of every stage after the first,
// once the stage's title has faded, a loadout screen opens:
//
// - Weapons unlocked since the last screen are handed over. While a
//   loadout slot is free a new weapon goes straight into it; the rest wait
//   in a row of their own and have to be placed before the player can
//   ready up.
// - Otherwise the player can rearrange, or just confirm.
//
// Like the reward screen (reward.odin) it is part of the simulation: the
// choices are made with ordinary inputs, stepped by session_step,
// snapshotted and rolled back like play, so netplay needs nothing new.
// Nothing moves while it is open but the frame count; it draws nothing
// from the RNG.

LOADOUT_SLOTS :: 3
MAX_SPARE :: 8 // spares one player can keep; the data has five air weapons in all
LOADOUT_CELLS :: LOADOUT_SLOTS + MAX_SPARE

Loadout_Row :: enum i32 {
	Fresh, // weapons new this stage, still to be placed
	Slots, // the loadout
	Spare,
	Ready, // one cell: ready up
}

// One player's screen. A row that is not shown has no cells.
Loadout_Board :: struct {
	cells:    [Loadout_Row][LOADOUT_CELLS]i32, // a weapon, or NO_WEAPON
	width:    [Loadout_Row]i32,
	row:      Loadout_Row,
	col:      i32,
	holding:  bool, // a weapon has been picked up from hold_row/hold_col
	hold_row: Loadout_Row,
	hold_col: i32,
	ready:    bool,
}

Loadout :: struct {
	active:     bool,
	shown:      bool,       // this stage's screen has been, or was not needed
	title:      Entity_Ref, // the stage's title notice: the screen waits for it
	choosing:   [MAX_PLAYERS]bool,
	boards:     [MAX_PLAYERS]Loadout_Board,
	held:       [MAX_PLAYERS]Buttons, // last step's input, for press edges
	ready_time: i32,
}

// A weapon a New Weapons player may hold by `level`. The last level it is
// available on does not count: a weapon, once held, is kept (the original
// takes the Ion Cannon away after level 3).
loadout_unlocked :: #force_inline proc "contextless" (w: ^Weapon, level: i32) -> bool {
	return w.type == WEP_AIR && w.minimum_level_available <= level
}

loadout_holds :: proc "contextless" (h: ^Weapon_Handler, weapon: i32) -> bool {
	for w in h.loadout {
		if w == weapon {
			return true
		}
	}
	for w in h.spare {
		if w == weapon {
			return true
		}
	}
	return false
}

// The weapons unlocked by `level` that `h` does not hold yet, in the order
// they unlock (and data order within a level). Returns how many.
loadout_unlocks :: proc "contextless" (s: ^State, h: ^Weapon_Handler, level: i32, out: []i32) -> (n: int) {
	for &w, i in s.defs.weapons {
		if !loadout_unlocked(&w, level) || loadout_holds(h, i32(i)) || n == len(out) {
			continue
		}
		// Insertion by unlock level: stable, and the list is tiny.
		k := n
		for k > 0 && w.minimum_level_available < s.defs.weapons[out[k - 1]].minimum_level_available {
			out[k] = out[k - 1]
			k -= 1
		}
		out[k] = i32(i)
		n += 1
	}
	return
}

// A new session's weapons: whatever is unlocked at the starting stage goes
// into the loadout while it has room, and the rest is handed over by the
// first loadout screen. Returns the weapon to fly with.
loadout_new_game :: proc "contextless" (s: ^State, h: ^Weapon_Handler, level: i32) -> i32 {
	unlocks: [LOADOUT_CELLS]i32
	n := loadout_unlocks(s, h, level, unlocks[:])
	for k in 0 ..< min(n, LOADOUT_SLOTS) {
		h.loadout[k] = unlocks[k]
	}
	return h.loadout[0]
}

// Change_Air's next weapon: the next held slot after `current`'s, wrapping.
// From a weapon not in the loadout, the first held slot.
loadout_next :: proc "contextless" (h: ^Weapon_Handler, current: i32) -> i32 {
	at := -1
	for w, k in h.loadout {
		if w == current && current != NO_WEAPON {
			at = k
		}
	}
	for j in 1 ..= LOADOUT_SLOTS {
		if w := h.loadout[(at + j) %% LOADOUT_SLOTS]; w != NO_WEAPON {
			return w
		}
	}
	return NO_WEAPON
}

// Whether the session stops for the loadout screen after this step: a New
// Weapons session past its first stage, this stage's title gone, and the
// stage still being played.
loadout_due :: proc "contextless" (s: ^State) -> bool {
	l := single(s, Loadout)
	return s.session.loadout && !l.active && !l.shown && single(s, Level_Info).number > 1 && !ref_valid(s, l.title) &&
		!single(s, Level_Info).ending && !single(s, Level_End).complete && !single(s, Game_Status).game_over
}

// Opens the loadout screen for every player still in the game. false, and
// no screen, when nobody is.
loadout_begin :: proc(s: ^State, input: Frame_Input) -> bool {
	l := single(s, Loadout)
	title := l.title
	l^ = {shown = true, title = title}
	any := false
	for p, i in players_of(s) {
		l.choosing[i] = reward_chooser(p)
		if l.choosing[i] {
			loadout_board_init(s, &l.boards[i], p.weapons)
			any = true
		}
	}
	if !any {
		return false
	}
	l.held = input
	l.active = true
	return true
}

loadout_board_init :: proc "contextless" (s: ^State, b: ^Loadout_Board, h: ^Weapon_Handler) {
	b^ = {}
	for &row in b.cells {
		row = NO_WEAPON
	}
	fresh: [LOADOUT_CELLS]i32
	n := loadout_unlocks(s, h, single(s, Level_Info).number, fresh[:])
	held: i32
	for w, k in h.loadout {
		b.cells[.Slots][k] = w
		held += w != NO_WEAPON ? 1 : 0
	}
	for w in h.spare {
		if w != NO_WEAPON {
			b.cells[.Spare][b.width[.Spare]] = w
			b.width[.Spare] += 1
			held += 1
		}
	}
	// New weapons fill free slots first, in unlock order.
	for w in fresh[:n] {
		placed := false
		for &c in b.cells[.Slots][:LOADOUT_SLOTS] {
			if c == NO_WEAPON {
				c = w
				placed = true
				break
			}
		}
		if !placed {
			b.cells[.Fresh][b.width[.Fresh]] = w
			b.width[.Fresh] += 1
		}
	}
	// A spare cell for every weapon beyond the loadout, so that once the
	// new row is empty and the loadout full, the spares hold the rest.
	b.width[.Slots] = LOADOUT_SLOTS
	b.width[.Spare] = min(max(held + i32(n) - LOADOUT_SLOTS, 0), MAX_SPARE)
	b.width[.Ready] = 1
	b.row = b.width[.Fresh] > 0 ? .Fresh : .Ready
}

@(private = "file")
board_count :: proc "contextless" (b: ^Loadout_Board, row: Loadout_Row) -> (n: i32) {
	for w in b.cells[row][:b.width[row]] {
		n += w != NO_WEAPON ? 1 : 0
	}
	return
}

// Whether a player may ready up: nothing left in the new row, and the
// loadout as full as the weapons held allow.
loadout_can_ready :: proc "contextless" (b: ^Loadout_Board) -> bool {
	total := board_count(b, .Fresh) + board_count(b, .Slots) + board_count(b, .Spare)
	return !b.holding && board_count(b, .Fresh) == 0 && board_count(b, .Slots) == min(total, LOADOUT_SLOTS)
}

// Moves the cursor: left and right along a row, wrapping; up and down to
// the next row shown, stopping at the edges.
loadout_move :: proc "contextless" (b: ^Loadout_Board, pressed: Buttons) {
	w := b.width[b.row]
	if .Left in pressed {
		b.col = (b.col - 1 + w) % w
	}
	if .Right in pressed {
		b.col = (b.col + 1) % w
	}
	step :: proc "contextless" (b: ^Loadout_Board, dir: i32) {
		for r := i32(b.row) + dir; r >= 0 && r < len(Loadout_Row); r += dir {
			if row := Loadout_Row(r); b.width[row] > 0 {
				b.row = row
				b.col = min(b.col, b.width[row] - 1)
				return
			}
		}
	}
	if .Up in pressed {
		step(b, -1)
	}
	if .Down in pressed {
		step(b, 1)
	}
}

// One step of the loadout screen. Returns true while it stays open; on
// false the choices have been applied and play resumes.
//
// Fire_Air picks up the weapon under the cursor, and puts it down again
// where the cursor is then, swapping with whatever is there. On READY it
// readies up. Fire_Ground puts a weapon back, or takes a ready back.
loadout_step :: proc(s: ^State, input: Frame_Input) -> bool {
	clear_step_events(s)
	single(s, Clock).frame += 1
	l := single(s, Loadout)
	for i in 0 ..< MAX_PLAYERS {
		pressed := input[i] - l.held[i]
		l.held[i] = input[i]
		if !l.choosing[i] {
			continue
		}
		b := &l.boards[i]
		if b.ready {
			if .Fire_Ground in pressed {
				b.ready = false
				reward_sound(s, REWARD_SOUND_UNLOCK)
			}
			continue
		}
		row, col := b.row, b.col
		loadout_move(b, pressed)
		if b.row != row || b.col != col {
			reward_sound(s, REWARD_SOUND_MOVE)
		}
		if .Fire_Ground in pressed && b.holding {
			b.holding = false
			reward_sound(s, REWARD_SOUND_UNLOCK)
		}
		if .Fire_Air not_in pressed {
			continue
		}
		switch {
		case b.row == .Ready:
			if loadout_can_ready(b) {
				b.ready = true
				reward_sound(s, REWARD_SOUND_LOCK)
			} else {
				reward_sound(s, REWARD_SOUND_REFUSE)
			}
		case b.holding:
			from, to := &b.cells[b.hold_row][b.hold_col], &b.cells[b.row][b.col]
			from^, to^ = to^, from^
			b.holding = false
			reward_sound(s, REWARD_SOUND_LOCK)
		case b.cells[b.row][b.col] != NO_WEAPON:
			b.holding = true
			b.hold_row, b.hold_col = b.row, b.col
			reward_sound(s, REWARD_SOUND_LOCK)
		case:
			reward_sound(s, REWARD_SOUND_REFUSE)
		}
	}
	all_ready := true
	for i in 0 ..< MAX_PLAYERS {
		all_ready &&= !l.choosing[i] || l.boards[i].ready
	}
	if !all_ready {
		l.ready_time = 0
		return true
	}
	l.ready_time += 1
	if l.ready_time < REWARD_RESUME_DELAY {
		return true
	}
	for i in 0 ..< MAX_PLAYERS {
		if l.choosing[i] {
			loadout_apply(s, player_at(s, i), &l.boards[i])
		}
	}
	l.active = false
	return false
}

// Hands a board's choices to the player. The weapon flown is kept if it is
// still in the loadout, else the first slot's is taken up.
loadout_apply :: proc(s: ^State, p: Player, b: ^Loadout_Board) {
	h := p.weapons
	h.spare = NO_WEAPON
	n := 0
	for w in b.cells[.Spare][:b.width[.Spare]] {
		if w != NO_WEAPON {
			h.spare[n] = w
			n += 1
		}
	}
	first := i32(NO_WEAPON)
	for w, k in b.cells[.Slots][:LOADOUT_SLOTS] {
		h.loadout[k] = w
		if first == NO_WEAPON {
			first = w
		}
	}
	in_loadout :: proc "contextless" (h: ^Weapon_Handler, w: i32) -> bool {
		for held in h.loadout {
			if w != NO_WEAPON && w == held {
				return true
			}
		}
		return false
	}
	if !in_loadout(h, air_weapon_shown(h)) && first != NO_WEAPON {
		change_weapon(s, h, WEP_AIR, in_loadout(h, h.air.weapon) ? h.air.weapon : first)
	}
	player_sprite_from_weapon(s, p)
}
