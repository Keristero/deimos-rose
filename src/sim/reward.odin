package sim

// Easy mode's reward screen: new content, not the original's. After each
// level's tally, before the next level starts, every player still in the
// game picks one passive (sim/passives.odin) from a shared set of options.
//
// It is part of the simulation, not the presentation, so that netplay
// needs nothing new: the choices are made with ordinary inputs, stepped by
// session_step like play, snapshotted and rolled back like play, and
// resynced on reconnect with the rest of State. Game time, entities and
// the playfield stand still meanwhile; only the frame count and the RNG
// (drawn once, for the options) move.

MAX_REWARD_OPTIONS :: MAX_PLAYERS + 1

// Steps every chooser has to have been ready for before play resumes: a
// beat to see the last lock land, and to take it back. Provisional.
REWARD_RESUME_DELAY :: 10

// At most this many options to a row (game/reward.odin draws the grid the
// same way); more wrap onto further rows.
REWARD_MAX_COLUMNS :: 6

Reward :: struct {
	active:     bool,
	count:      i32,
	options:    [MAX_REWARD_OPTIONS]Passive,
	choosing:   [MAX_PLAYERS]bool, // in the game when the screen opened
	cursor:     [MAX_PLAYERS]i32,  // index into options
	locked:     [MAX_PLAYERS]bool,
	held:       [MAX_PLAYERS]Buttons, // last step's input, for press edges
	ready_time: i32,
}

// The menu's own sounds (game/menu.odin, game/menu_level_select.odin).
REWARD_SOUND_MOVE :: Res_ID{'m', 'b', 'r', 'o'}
REWARD_SOUND_LOCK :: Res_ID{'l', 's', 's', 'e'}
REWARD_SOUND_REFUSE :: Res_ID{'l', 's', 'n', 'a'}
REWARD_SOUND_UNLOCK :: Res_ID{'i', 'n', 'c', 'l'}

@(private = "file") SITE_REWARD_SHUFFLE :: Site(0xe0000010)

reward_grid_columns :: proc "contextless" (count: i32) -> i32 {
	return clamp(count, 1, REWARD_MAX_COLUMNS)
}

reward_chooser :: #force_inline proc "contextless" (p: ^Player) -> bool {
	return p.active && p.state != .Gone
}

// Whether the session stops for a reward screen after this step: easy
// mode, the level counted, and another level to come.
reward_due :: proc "contextless" (s: ^State) -> bool {
	return s.session.easy && s.level_end.complete && !s.game_over && !s.reward.active &&
		int(s.level_number) < len(s.defs.levels)
}

// Opens the reward screen: one option per chooser plus one, drawn without
// repeats from the passives someone can still take on the next level.
// false, and no screen, when nobody is choosing or nothing is left.
reward_begin :: proc(s: ^State, input: Frame_Input) -> bool {
	r := &s.reward
	r^ = {}
	choosers: i32
	for &p, i in s.players {
		r.choosing[i] = reward_chooser(&p)
		choosers += r.choosing[i] ? 1 : 0
	}
	if choosers == 0 {
		return false
	}
	next := s.defs.levels[s.level_number].number
	pool: [len(Passive)]Passive
	n: i32
	for pa in Passive {
		if !passive_available(s.defs, pa, next) {
			continue
		}
		for &p, i in s.players {
			if r.choosing[i] && !passive_maxed(&p.passives, pa) {
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
		j := random_int(&s.rng, k, n - 1, SITE_REWARD_SHUFFLE)
		pool[k], pool[j] = pool[j], pool[k]
		r.options[k] = pool[k]
	}
	r.cursor[0] = 0
	for i in 1 ..< MAX_PLAYERS {
		r.cursor[i] = r.count - 1
	}
	r.held = input
	r.active = true
	return true
}

// Whether `player` may lock option k: not already at its top level for
// them, and not locked by another player.
reward_selectable :: proc "contextless" (s: ^State, player: int, k: i32) -> bool {
	r := &s.reward
	if k < 0 || k >= r.count || passive_maxed(&s.players[player].passives, r.options[k]) {
		return false
	}
	for j in 0 ..< MAX_PLAYERS {
		if j != player && r.choosing[j] && r.locked[j] && r.cursor[j] == k {
			return false
		}
	}
	return true
}

// A player is ready once locked in, or when nothing is left to lock.
reward_ready :: proc "contextless" (s: ^State, player: int) -> bool {
	r := &s.reward
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
reward_move :: proc "contextless" (cursor, count: i32, pressed: Buttons) -> i32 {
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
reward_step :: proc(s: ^State, input: Frame_Input) -> bool {
	clear_step_events(s)
	s.frame += 1
	r := &s.reward
	for i in 0 ..< MAX_PLAYERS {
		pressed := input[i] - r.held[i]
		r.held[i] = input[i]
		if !r.choosing[i] {
			continue
		}
		if r.locked[i] {
			if .Fire_Ground in pressed {
				r.locked[i] = false
				reward_sound(s, REWARD_SOUND_UNLOCK)
			}
			continue
		}
		if c := reward_move(r.cursor[i], r.count, pressed); c != r.cursor[i] {
			r.cursor[i] = c
			reward_sound(s, REWARD_SOUND_MOVE)
		}
		if .Fire_Air in pressed {
			if reward_selectable(s, i, r.cursor[i]) {
				r.locked[i] = true
				reward_sound(s, REWARD_SOUND_LOCK)
			} else {
				reward_sound(s, REWARD_SOUND_REFUSE)
			}
		}
	}
	all_ready := true
	for i in 0 ..< MAX_PLAYERS {
		all_ready &&= reward_ready(s, i)
	}
	if !all_ready {
		r.ready_time = 0
		return true
	}
	r.ready_time += 1
	if r.ready_time < REWARD_RESUME_DELAY {
		return true
	}
	for i in 0 ..< MAX_PLAYERS {
		if r.choosing[i] && r.locked[i] {
			s.players[i].passives[r.options[r.cursor[i]]] += 1
		}
	}
	r.active = false
	return false
}

// A menu sound: no draws, played at full volume whether or not it is
// already playing (loop = true, as the weapon-switch sound does).
@(private = "file")
reward_sound :: proc "contextless" (s: ^State, id: Res_ID) {
	if s.sounds.count < MAX_SOUND_EVENTS {
		s.sounds.events[s.sounds.count] = {id, 100, 0, 1, true}
		s.sounds.count += 1
	}
}
