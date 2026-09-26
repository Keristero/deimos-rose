package easy_mode

import "base:runtime"
import "dr:plugins/passives"
import _ "dr:sim/core"
import "dr:sim"

// Easy mode's reward screen: new content, not the original's. After each
// level's tally, before the next level starts, every player still in the
// game picks one passive (plugins/passives) from a shared set of options.
//
// A screen in the simulation (sim/screens.odin): game time, entities and
// the playfield stand still meanwhile; only the frame count and the RNG
// (drawn once, for the options) move.

Passive :: passives.Passive

MAX_REWARD_OPTIONS :: sim.MAX_PLAYERS + 1

// At most this many options to a row (game/reward.odin draws the grid the
// same way); more wrap onto further rows.
REWARD_MAX_COLUMNS :: 6

// On the session entity.
Reward :: struct {
	active:     bool,
	count:      i32,
	options:    [MAX_REWARD_OPTIONS]Passive,
	choosing:   [sim.MAX_PLAYERS]bool, // in the game when the screen opened
	cursor:     [sim.MAX_PLAYERS]i32,  // index into options
	locked:     [sim.MAX_PLAYERS]bool,
	held:       [sim.MAX_PLAYERS]sim.Buttons, // last step's input, for press edges
	ready_time: i32,
}

@(private = "file") SITE_REWARD_SHUFFLE :: sim.Site(0xe0000010)

reward_grid_columns :: proc "contextless" (count: i32) -> i32 {
	return clamp(count, 1, REWARD_MAX_COLUMNS)
}

// The session's reward screen; nil when easy mode is not on.
reward_of :: #force_inline proc "contextless" (s: ^sim.State) -> ^Reward {
	return sim.get(s.ecs, sim.SESSION_ENTITY, Reward)
}

// Whether the reward screen is open.
reward_open :: proc "contextless" (s: ^sim.State) -> bool {
	r := reward_of(s)
	return r != nil && r.active
}

// Whether the session stops for a reward screen after this step: the level
// counted, and another level to come.
reward_due :: proc "contextless" (s: ^sim.State) -> bool {
	return sim.single(s, sim.Level_End).complete && !sim.single(s, sim.Game_Status).game_over && !reward_of(s).active &&
		int(sim.single(s, sim.Level_Info).number) < len(s.defs.levels)
}

// Opens the reward screen: one option per chooser plus one, drawn without
// repeats from the passives someone can still take on the next level.
// false, and no screen, when nobody is choosing or nothing is left.
reward_begin :: proc(s: ^sim.State, input: sim.Frame_Input) -> bool {
	r := reward_of(s)
	r^ = {}
	choosers: i32
	for p, i in sim.players_of(s) {
		r.choosing[i] = sim.screen_chooser(p)
		choosers += r.choosing[i] ? 1 : 0
	}
	if choosers == 0 {
		return false
	}
	next := s.defs.levels[sim.single(s, sim.Level_Info).number].number
	pool: [len(Passive)]Passive
	n: i32
	for pa in Passive {
		if !passives.passive_available(s, pa, next) {
			continue
		}
		for i in 0 ..< sim.MAX_PLAYERS {
			if r.choosing[i] && !passives.passive_maxed(passives.levels_of(s, i), pa) {
				pool[n] = pa
				n += 1
				break
			}
		}
	}
	if n == 0 {
		return false
	}
	r.count = min(choosers + 1, n)
	// A partial Fisher-Yates shuffle: the first `count` of the pool.
	for k in 0 ..< r.count {
		j := sim.roll_int(s, k, n - 1, SITE_REWARD_SHUFFLE)
		pool[k], pool[j] = pool[j], pool[k]
		r.options[k] = pool[k]
	}
	r.cursor[0] = 0
	for i in 1 ..< sim.MAX_PLAYERS {
		r.cursor[i] = r.count - 1
	}
	r.held = input
	r.active = true
	return true
}

// Whether `player` may lock option k: not already at its top level for
// them, and not locked by another player.
reward_selectable :: proc "contextless" (s: ^sim.State, player: int, k: i32) -> bool {
	r := reward_of(s)
	if k < 0 || k >= r.count || passives.passive_maxed(passives.levels_of(s, player), r.options[k]) {
		return false
	}
	for j in 0 ..< sim.MAX_PLAYERS {
		if j != player && r.choosing[j] && r.locked[j] && r.cursor[j] == k {
			return false
		}
	}
	return true
}

// A player is ready once locked in, or when nothing is left to lock.
reward_ready :: proc "contextless" (s: ^sim.State, player: int) -> bool {
	r := reward_of(s)
	if !r.choosing[player] || r.locked[player] {
		return true
	}
	for k in 0 ..< r.count {
		if reward_selectable(s, player, k) {
			return false
		}
	}
	return true
}

// Moves a grid cursor: left and right step along the options and wrap,
// up and down move a row and stop at the edges.
reward_move :: proc "contextless" (cursor, count: i32, pressed: sim.Buttons) -> i32 {
	c := cursor
	cols := reward_grid_columns(count)
	if .Left in pressed {
		c = (c - 1 + count) % count
	}
	if .Right in pressed {
		c = (c + 1) % count
	}
	if .Up in pressed && c - cols >= 0 {
		c -= cols
	}
	if .Down in pressed && c + cols < count {
		c += cols
	}
	return c
}

// One step of the reward screen. Returns true while it stays open; on
// false the choices have been applied and the session moves on.
reward_step :: proc(s: ^sim.State, input: sim.Frame_Input) -> bool {
	sim.clear_step_events(s)
	sim.single(s, sim.Clock).frame += 1
	r := reward_of(s)
	for i in 0 ..< sim.MAX_PLAYERS {
		pressed := input[i] - r.held[i]
		r.held[i] = input[i]
		if !r.choosing[i] {
			continue
		}
		if r.locked[i] {
			if .Fire_Ground in pressed {
				r.locked[i] = false
				sim.screen_sound(s, sim.SCREEN_SOUND_UNLOCK)
			}
			continue
		}
		if c := reward_move(r.cursor[i], r.count, pressed); c != r.cursor[i] {
			r.cursor[i] = c
			sim.screen_sound(s, sim.SCREEN_SOUND_MOVE)
		}
		if .Fire_Air in pressed {
			if reward_selectable(s, i, r.cursor[i]) {
				r.locked[i] = true
				sim.screen_sound(s, sim.SCREEN_SOUND_LOCK)
			} else {
				sim.screen_sound(s, sim.SCREEN_SOUND_REFUSE)
			}
		}
	}
	all_ready := true
	for i in 0 ..< sim.MAX_PLAYERS {
		all_ready &&= reward_ready(s, i)
	}
	if !all_ready {
		r.ready_time = 0
		return true
	}
	r.ready_time += 1
	if r.ready_time < sim.SCREEN_RESUME_DELAY {
		return true
	}
	for i in 0 ..< sim.MAX_PLAYERS {
		if r.choosing[i] && r.locked[i] {
			passives.levels_of(s, i)[r.options[r.cursor[i]]] += 1
		}
	}
	r.active = false
	return false
}

// While the screen is open it takes the step. On the step it closes the
// rest of the step is frozen, so that the level moves on.
@(private = "file")
screen_system :: proc(s: ^sim.State, step: ^sim.Step) {
	if !reward_of(s).active {
		return
	}
	if reward_step(s, step.input) {
		step.done = true
	} else {
		step.frozen = true
	}
}

// A counted level opens the screen.
@(private = "file")
open_system :: proc(s: ^sim.State, step: ^sim.Step) {
	if reward_due(s) && reward_begin(s, step.input) {
		step.done = true
	}
}

@(private = "file")
setup_system :: proc(s: ^sim.State, step: ^sim.Step) {
	sim.add(s.ecs, sim.SESSION_ENTITY, Reward{})
}

@(private = "file")
held :: proc "contextless" (s: ^sim.State) -> bool {
	return reward_of(s).active
}

ID: sim.Plugin_ID

@(private = "file", rodata)
DEPS := []string{"passives"}
// The screen runs ahead of the game step, after a pause has had its say;
// the opening after it, ahead of the level change the screen holds back.
@(private = "file", rodata)
SCREEN_AFTER := []string{"netplay_pause"}
@(private = "file", rodata)
SCREEN_BEFORE := []string{"step_events"}
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
		name        = "easy_mode",
		label       = "EASY MODE",
		description = "A passive upgrade to choose after every level",
		deps        = DEPS,
		session     = true,
	})
	sim.component_register(Reward, 1)
	sim.system_register({name = "reward_setup", after = SETUP_AFTER, before = SETUP_BEFORE, plugin = ID, kind = .Setup, run = setup_system})
	sim.system_register({
		name   = "reward_screen",
		after  = SCREEN_AFTER,
		before = SCREEN_BEFORE,
		plugin = ID,
		kind   = .Session,
		run    = screen_system,
	})
	sim.system_register({name = "reward_open", before = OPEN_BEFORE, plugin = ID, kind = .Session, run = open_system})
	sim.hold_register({plugin = ID, held = held})
}
