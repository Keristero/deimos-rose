package loadout

import "base:runtime"
// Imported for its registration: a dependency is always in the build.
import _ "dr:plugins/extra_prefs"
import _ "dr:sim/core"
import "dr:sim"
import "dr:sim/systems/weapon_system"
import "dr:sim/systems/player_system"

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
// A screen in the simulation (sim/screens.odin). Nothing moves while it is
// open but the frame count; it draws nothing from the RNG.
//
// Which weapons unlock is the original's rules, save that a player keeps
// every weapon once held; the new weapons join in with plugins/new_weapons
// (sim.weapon_allowed).

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

// On the session entity.
Loadout :: struct {
	active:     bool,
	// Level_Info.played when this stage's screen was shown, or found not
	// needed: the stage's screen has been once it matches.
	shown:      i32,
	choosing:   [MAX_PLAYERS]bool,
	boards:     [MAX_PLAYERS]Loadout_Board,
	held:       [MAX_PLAYERS]Buttons, // last step's input, for press edges
	ready_time: i32,
}

// On each player's entity: the air weapons held, those switched between
// and the rest.
Loadout_Slots :: struct {
	loadout: [LOADOUT_SLOTS]i32,
	spare:   [MAX_SPARE]i32,
}

MAX_PLAYERS :: sim.MAX_PLAYERS
NO_WEAPON :: sim.NO_WEAPON
Buttons :: sim.Buttons

// The session's loadout screen; nil when the plugin is not on.
loadout_of :: #force_inline proc "contextless" (s: ^sim.State) -> ^Loadout {
	return sim.get(s.ecs, sim.SESSION_ENTITY, Loadout)
}

// Whether the loadout screen is open.
loadout_open :: proc "contextless" (s: ^sim.State) -> bool {
	l := loadout_of(s)
	return l != nil && l.active
}

// A player's slots; nil when the plugin is not on.
slots_of :: #force_inline proc "contextless" (s: ^sim.State, player: $I) -> ^Loadout_Slots {
	return sim.get(s.ecs, sim.player_entity(i32(player)), Loadout_Slots)
}

// A weapon a player may hold by `level`. The last level it is available on
// does not count: a weapon, once held, is kept (the original takes the Ion
// Cannon away after level 3).
loadout_unlocked :: #force_inline proc "contextless" (s: ^sim.State, w: ^sim.Weapon, level: i32) -> bool {
	return w.type == sim.WEP_AIR && sim.weapon_allowed(s, w) && w.minimum_level_available <= level
}

loadout_holds :: proc "contextless" (h: ^Loadout_Slots, weapon: i32) -> bool {
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
loadout_unlocks :: proc "contextless" (s: ^sim.State, h: ^Loadout_Slots, level: i32, out: []i32) -> (n: int) {
	for &w, i in s.defs.weapons {
		if !loadout_unlocked(s, &w, level) || loadout_holds(h, i32(i)) || n == len(out) {
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
loadout_new_game :: proc "contextless" (s: ^sim.State, w: sim.Weapons, level: i32) -> i32 {
	h := slots_of(s, w.player)
	h.loadout = NO_WEAPON
	h.spare = NO_WEAPON
	unlocks: [LOADOUT_CELLS]i32
	n := loadout_unlocks(s, h, level, unlocks[:])
	for k in 0 ..< min(n, LOADOUT_SLOTS) {
		h.loadout[k] = unlocks[k]
	}
	return h.loadout[0]
}

// Change_Air's next weapon (the weapon chooser's `next`).
loadout_next :: proc "contextless" (s: ^sim.State, w: sim.Weapons, current: i32) -> i32 {
	return slots_next(slots_of(s, w.player), current)
}

// The next held slot after `current`'s, wrapping. From a weapon not in the
// loadout, the first held slot.
slots_next :: proc "contextless" (h: ^Loadout_Slots, current: i32) -> i32 {
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

// Whether the session stops for the loadout screen after this step: past
// the first stage, this stage's title gone, and the stage still being
// played.
loadout_due :: proc "contextless" (s: ^sim.State) -> bool {
	l := loadout_of(s)
	info := sim.single(s, sim.Level_Info)
	return !l.active && l.shown != info.played && info.number > 1 && !sim.ref_valid(s, info.title) &&
		!info.ending && !sim.single(s, sim.Level_End).complete && !sim.single(s, sim.Game_Status).game_over
}

// Opens the loadout screen for every player still in the game. false, and
// no screen, when nobody is.
loadout_begin :: proc(s: ^sim.State, input: sim.Frame_Input) -> bool {
	l := loadout_of(s)
	l^ = {shown = sim.single(s, sim.Level_Info).played}
	any := false
	for p, i in sim.players_of(s) {
		l.choosing[i] = sim.screen_chooser(p)
		if l.choosing[i] {
			loadout_board_init(s, &l.boards[i], slots_of(s, i))
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

loadout_board_init :: proc "contextless" (s: ^sim.State, b: ^Loadout_Board, h: ^Loadout_Slots) {
	b^ = {}
	for &row in b.cells {
		row = NO_WEAPON
	}
	fresh: [LOADOUT_CELLS]i32
	n := loadout_unlocks(s, h, sim.single(s, sim.Level_Info).number, fresh[:])
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
loadout_step :: proc(s: ^sim.State, input: sim.Frame_Input) -> bool {
	sim.clear_step_events(s)
	sim.single(s, sim.Clock).frame += 1
	l := loadout_of(s)
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
				sim.screen_sound(s, sim.SCREEN_SOUND_UNLOCK)
			}
			continue
		}
		row, col := b.row, b.col
		loadout_move(b, pressed)
		if b.row != row || b.col != col {
			sim.screen_sound(s, sim.SCREEN_SOUND_MOVE)
		}
		if .Fire_Ground in pressed && b.holding {
			b.holding = false
			sim.screen_sound(s, sim.SCREEN_SOUND_UNLOCK)
		}
		if .Fire_Air not_in pressed {
			continue
		}
		switch {
		case b.row == .Ready:
			if loadout_can_ready(b) {
				b.ready = true
				sim.screen_sound(s, sim.SCREEN_SOUND_LOCK)
			} else {
				sim.screen_sound(s, sim.SCREEN_SOUND_REFUSE)
			}
		case b.holding:
			from, to := &b.cells[b.hold_row][b.hold_col], &b.cells[b.row][b.col]
			from^, to^ = to^, from^
			b.holding = false
			sim.screen_sound(s, sim.SCREEN_SOUND_LOCK)
		case b.cells[b.row][b.col] != NO_WEAPON:
			b.holding = true
			b.hold_row, b.hold_col = b.row, b.col
			sim.screen_sound(s, sim.SCREEN_SOUND_LOCK)
		case:
			sim.screen_sound(s, sim.SCREEN_SOUND_REFUSE)
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
	if l.ready_time < sim.SCREEN_RESUME_DELAY {
		return true
	}
	for i in 0 ..< MAX_PLAYERS {
		if l.choosing[i] {
			loadout_apply(s, sim.player_at(s, i), &l.boards[i])
		}
	}
	l.active = false
	return false
}

// Hands a board's choices to the player. The weapon flown is kept if it is
// still in the loadout, else the first slot's is taken up.
loadout_apply :: proc(s: ^sim.State, p: sim.Player, b: ^Loadout_Board) {
	h := slots_of(s, p.number)
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
	in_loadout :: proc "contextless" (h: ^Loadout_Slots, w: i32) -> bool {
		for held in h.loadout {
			if w != NO_WEAPON && w == held {
				return true
			}
		}
		return false
	}
	wh := p.weapons
	if !in_loadout(h, weapon_system.air_weapon_shown(wh)) && first != NO_WEAPON {
		weapon_system.change_weapon(s, wh, sim.WEP_AIR, in_loadout(h, wh.air.weapon) ? wh.air.weapon : first)
	}
	player_system.player_sprite_from_weapon(s, p)
}

// While the screen is open it takes the step.
@(private = "file")
screen_system :: proc(s: ^sim.State, step: ^sim.Step) {
	if loadout_of(s).active {
		loadout_step(s, step.input)
		step.done = true
	}
}

// The stage's title gone, the screen opens.
@(private = "file")
open_system :: proc(s: ^sim.State, step: ^sim.Step) {
	if loadout_due(s) && loadout_begin(s, step.input) {
		step.done = true
	}
}

@(private = "file")
setup_system :: proc(s: ^sim.State, step: ^sim.Step) {
	sim.add(s.ecs, sim.SESSION_ENTITY, Loadout{})
	for i in 0 ..< i32(MAX_PLAYERS) {
		h := sim.add(s.ecs, sim.player_entity(i), Loadout_Slots{})
		h.loadout = NO_WEAPON
		h.spare = NO_WEAPON
	}
}

@(private = "file")
held :: proc "contextless" (s: ^sim.State) -> bool {
	return loadout_of(s).active
}

ID: sim.Plugin_ID

@(private = "file", rodata)
DEPS := []string{"extra_prefs"}
// The screen runs ahead of the game step, after a pause and the reward
// screen have had their say; the opening after it, in the same order.
@(private = "file", rodata)
SCREEN_AFTER := []string{"netplay_pause", "reward_screen"}
@(private = "file", rodata)
SCREEN_BEFORE := []string{"step_events"}
@(private = "file", rodata)
OPEN_AFTER := []string{"reward_open"}
@(private = "file", rodata)
OPEN_BEFORE := []string{"level_transition"}

// Its components go on the session's entities once they exist, and before
// the players are set up with them.
@(private = "file", rodata)
SETUP_AFTER := []string{"session_setup"}
@(private = "file", rodata)
SETUP_BEFORE := []string{"players_setup"}

@(init)
register :: proc "contextless" () {
	context = runtime.default_context()
	ID = sim.plugin_register({
		name        = "loadout",
		label       = "LOADOUT",
		description = "Three air weapons at hand, chosen at the start of each stage",
		deps        = DEPS,
		session     = true,
	})
	sim.component_register(Loadout, 1)
	sim.component_register(Loadout_Slots, MAX_PLAYERS)
	sim.system_register({name = "loadout_setup", after = SETUP_AFTER, before = SETUP_BEFORE, plugin = ID, kind = .Setup, run = setup_system})
	sim.system_register({
		name   = "loadout_screen",
		after  = SCREEN_AFTER,
		before = SCREEN_BEFORE,
		plugin = ID,
		kind   = .Session,
		run    = screen_system,
	})
	sim.system_register({
		name   = "loadout_open",
		after  = OPEN_AFTER,
		before = OPEN_BEFORE,
		plugin = ID,
		kind   = .Session,
		run    = open_system,
	})
	sim.hold_register({plugin = ID, held = held})
	sim.weapon_chooser_register({plugin = ID, new_game = loadout_new_game, next = loadout_next})
}
