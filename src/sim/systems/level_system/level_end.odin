package level_system

// The end of a level: the ground-accuracy tally (FUN_00420930 sets it up,
// FUN_00420d90 runs it) and then each player's money counter. Both are mostly
// presentation, but they adjust the score, which can award a life -- and a
// life spawns a unit, so the order of these steps is part of the simulation.
// Their sounds use the U_Sound_Play(id, priority, volume, loop) overload,
// which does not draw from the RNG.
//
// The tally has eleven states. 1..8 are the accuracy readout; 9 and 10 are
// the perfect-game bonus, reached only when every level of the list has been
// finished at 100% accuracy.

import "dr:sim"
import "dr:sim/lifecycle"
import "dr:sim/systems/collision_system"

@(private = "file")
pf :: proc "contextless" (s: ^sim.State, i: int) -> i32 {
	return sim.trunc_i32(s.defs.perm_floats[i])
}

// The G_Bgnd_Process() == 1 branch of FUN_00420280, run once the background
// reports the level has scrolled to its end.
level_end_step :: proc(s: ^sim.State, time: i32) {
	l := sim.single(s, sim.Level_End)
	sim.single(s, sim.Level_Info).ending = true
	if !l.started {
		if sim.single(s, sim.Game_Status).game_over {
			l.started = true
			return
		}
		level_end_begin(s, time)
		return
	}
	if !level_end_process(s, time) {
		return
	}
	// The tally is done: start each in-game player's money counter, the
	// second one offset below the first, and run them until both finish.
	all_done := true
	offset := false
	for p in sim.players_of(s) {
		if p.active && !money_counter_active(p) {
			offset = money_counter_start(s, p, time, offset)
			all_done = false
		}
	}
	for p in sim.players_of(s) {
		if p.active && !money_counter_process(s, p, time) {
			all_done = false
		}
	}
	if all_done {
		l.complete = true
	}
}

@(private = "file")
level_end_begin :: proc(s: ^sim.State, time: i32) {
	l := sim.single(s, sim.Level_End)
	n := i32(len(s.defs.levels))
	if sim.single(s, sim.Level_Info).number == n && sim.single(s, sim.Level_Info).played == n {
		l.all_done = true
	}
	notice := s.defs.perm_objects[l.all_done ? 0x17 : 0x16]
	if notice != sim.NONE {
		req := sim.spawn_request(notice)
		req.loc = {
			s.defs.perm_floats[sim.PF_VISIBLE_GAME_WIDTH] / 2,
			s.defs.perm_floats[sim.PF_VISIBLE_GAME_HEIGHT] / 2,
		}
		lifecycle.eg_request_spawn(s, req)
	}
	l.started = true
	l.started_time = time
	for p in sim.players_of(s) {
		if p.active {
			p.invulnerable = true
		}
	}

	// FUN_00420930: the tally's opening state.
	l.state = 1
	l.state_time = time
	l.count_time = time
	percent: f32 = 0
	if sim.single(s, sim.Accuracy).targets >= 1 {
		percent = f32(sim.single(s, sim.Accuracy).destroyed) / f32(sim.single(s, sim.Accuracy).targets) * 100
	}
	l.percent = sim.trunc_i32(percent)
	// The thresholds step down from 100 by whole multiples of perm float
	// 0xbc, worked out as integers and compared as floats.
	gap := pf(s, 0xbc)
	tier: int
	switch {
	case percent >= 100:
		// Remembered for the next level's accuracy reward.
		sim.single(s, sim.Accuracy).perfect_level = true
		tier = 0xbd
	case percent >= f32(100 - gap):
		tier = 0xbe
	case percent >= f32(100 - gap * 2):
		tier = 0xbf
	case percent >= f32(100 - gap * 3):
		tier = 0xc0
	case percent >= f32(100 - gap * 4):
		tier = 0xc1
	case:
		tier = 0xc2
	}
	l.bonus = pf(s, tier) * sim.single(s, sim.Level_Info).number
	l.bonus_total = l.bonus
	l.bonus_step = count_step(s, l.bonus)
}

// The countdown step shared by the tally and the money counters: 2% of the
// total (perm float 0xc8), but never less than perm float 0xc7.
@(private = "file")
count_step :: proc "contextless" (s: ^sim.State, total: i32) -> i32 {
	if total < 1 {
		return 0
	}
	step := s.defs.perm_floats[0xc8] * f32(total)
	if min := pf(s, 0xc7); step < f32(min) {
		step = f32(min)
	}
	return sim.trunc_i32(step)
}

// FUN_00420d90. Returns true once the tally has run its course, which is when
// the money counters start.
@(private = "file")
level_end_process :: proc(s: ^sim.State, time: i32) -> bool {
	l := sim.single(s, sim.Level_End)
	switch l.state {
	case 0:
		return true
	case 1:
		wait := pf(s, l.all_done ? 0xc4 : 0xc3)
		if l.state_time + wait < time {
			l.state, l.state_time = 2, time
			level_end_sound(s, 0x14, 0x32)
		}
	case 2:
		for _ in 0 ..< pf(s, 0xcb) {
			if l.fade != 0 {
				l.fade -= 1
			}
		}
		if l.state_time + pf(s, 0xc5) < time {
			l.state, l.state_time = 3, time
			level_end_sound(s, 0x14, 0x32)
		}
	case 3:
		if l.state_time + pf(s, 0xc5) < time {
			l.state, l.state_time = 4, time
			level_end_sound(s, 0x14, 0x32)
		}
	case 4:
		if l.state_time + pf(s, 0xc5) < time {
			l.state, l.state_time = 5, time
			if l.percent == 100 {
				l.perfect_levels += 1
				level_end_sound(s, 0x16, 0x32)
			} else if l.bonus == 0 {
				level_end_sound(s, 0x15, 0x32)
			} else {
				level_end_sound(s, 0x14, 0x32)
			}
		}
	case 5:
		if l.state_time + pf(s, 0xc5) < time {
			l.state, l.state_time = 6, time
		}
	case 6:
		if l.bonus < 1 {
			l.state, l.state_time = 7, time
		} else if l.count_time + pf(s, 0xc6) < time {
			l.count_time = time
			l.bonus -= l.bonus_step
			if l.bonus < 0 {
				l.bonus = 0
			}
			for p in sim.players_of(s) {
				collision_system.player_score(s, p, l.bonus_step, false)
			}
			level_end_sound(s, 0x14, 0x32)
		}
	case 7:
		if l.state_time + pf(s, 0xc9) < time {
			l.state, l.state_time = 8, time
		}
	case 8:
		if l.fade < 0x20 {
			l.fade += pf(s, 0xcc)
			if l.fade > 0x20 {
				l.fade = 0x20
			}
		}
		if time <= l.state_time + pf(s, 0xca) {
			return false
		}
		if l.perfect_levels == i32(len(s.defs.levels)) {
			// Every level finished at 100%: the perfect-game bonus.
			l.perfect = true
			l.perfect_count = 0
			l.state, l.state_time, l.fade = 9, time, 0
			level_end_sound(s, 0x17, 100)
			return false
		}
		return true
	case 9:
		if l.state_time + pf(s, 0xce) < time {
			l.state, l.state_time = 10, time
			l.fade = 0x20
		}
	case 10:
		if !l.perfect {
			return true
		}
		if time <= l.state_time + pf(s, 0xcf) {
			return false
		}
		l.perfect_count += 1
		for p in sim.players_of(s) {
			collision_system.player_score(s, p, pf(s, 0xcd), true)
		}
		if pf(s, 0xd0) <= l.perfect_count {
			l.perfect = false
			return false
		}
		l.state, l.state_time, l.fade = 9, time, 0
		return false
	}
	return false
}

@(private = "file")
level_end_sound :: proc "contextless" (s: ^sim.State, perm: int, priority: i32) {
	id := s.defs.perm_sounds[perm]
	if id == sim.NONE || s.sounds.count >= sim.MAX_SOUND_EVENTS {
		return
	}
	s.sounds.events[s.sounds.count] = {id = id, volume = 100, priority = priority, pitch = 1}
	s.sounds.count += 1
}

// G_Player::MoneyCounter_Start: the money the player is carrying converts to
// score at a per-level multiplier. Returns whether a counter was started, so
// the caller offsets the second player's readout below the first.
money_counter_start :: proc(s: ^sim.State, p: sim.Player, time: i32, offset: bool) -> bool {
	if !p.active {
		return false
	}
	m := &p.counter
	m.state = 1
	m.state_time = time
	m.count_time = time
	m.multiplier = pf(s, 0xab)
	if pf(s, 0xaa) != 0 {
		m.multiplier *= sim.single(s, sim.Level_Info).number
	}
	m.money = p.money
	m.value = m.money * m.multiplier
	m.step = count_step(s, m.value)
	d := sim.player_def(s, p)
	if d.active_money_counter_spawn != sim.NONE {
		req := sim.spawn_request(d.active_money_counter_spawn)
		req.loc = {s.defs.perm_floats[0xb3], s.defs.perm_floats[0xb4]}
		if offset {
			m.offset = pf(s, 0xb5)
			req.loc.y += f32(m.offset)
		}
		req.owner_player = p.number
		lifecycle.eg_request_spawn(s, req)
	}
	return true
}

money_counter_active :: proc "contextless" (p: sim.Player) -> bool {
	return p.counter.state != 0
}

// G_Player::MoneyCounter_Process. Returns true once this player's counter has
// finished.
money_counter_process :: proc(s: ^sim.State, p: sim.Player, time: i32) -> bool {
	m := &p.counter
	switch m.state {
	case 0:
		return true
	case 1:
		if m.state_time + pf(s, 0xac) < time {
			m.state, m.state_time = 2, time
			level_end_sound(s, 0x14, 0x32)
		}
	case 2:
		for _ in 0 ..< pf(s, 0xb1) {
			if m.fade != 0 {
				m.fade -= 1
			}
		}
		if m.state_time + pf(s, 0xad) < time {
			m.state, m.state_time = 3, time
			level_end_sound(s, 0x14, 0x32)
		}
	case 3:
		if m.state_time + pf(s, 0xad) < time {
			m.state, m.state_time = 4, time
			level_end_sound(s, 0x14, 0x32)
		}
	case 4:
		if m.state_time + pf(s, 0xad) < time {
			m.state, m.state_time = 5, time
			level_end_sound(s, m.value < 1 ? 0x15 : 0x14, 0x32)
		}
	case 5:
		if m.state_time + pf(s, 0xad) < time {
			m.state, m.state_time = 6, time
		}
	case 6:
		if m.value < 1 {
			m.state, m.state_time = 7, time
		} else if m.count_time + pf(s, 0xb0) < time {
			m.count_time = time
			if p.active {
				p.money -= 1
			}
			collision_system.player_score(s, p, m.step, false)
			m.value -= m.step
			level_end_sound(s, 0x14, 0x32)
		}
	case 7:
		if m.state_time + pf(s, 0xae) < time {
			m.state, m.state_time = 8, time
		}
	case 8:
		if m.state_time + pf(s, 0xaf) < time {
			return true
		}
	}
	return false
}
