package tests

import "core:testing"

import net "dr:net"
import "dr:plugins/easy_mode"
import "dr:plugins/passives"
import "dr:sim"

// Two rollback peers through a level's end into easy mode's reward screen
// and out the other side, with the packets between them late and some
// dropped: the guest mispredicts the host's presses on the screen and rolls
// back across its opening and closing. Both must agree throughout, and every
// read the screen's view makes (plugins/easy_mode/view) must be good on
// both.
@(test)
netplay_peers_agree_through_the_reward_screen :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	levels := make([]sim.Level_Def, 3, context.temp_allocator)
	for &l, i in levels {
		l = defs.levels[0]
		l.id = sim.level_id(i == 0 ? "le01" : i == 1 ? "le02" : "le03")
		l.number = i32(i + 1)
		l.background.bottom = 700
	}
	defs.levels = levels
	defs.perm_floats[0x20] = 30
	session := sim.Session{seed = 0xE45E, level_id = levels[0].id, game_type = .Co_Op, mods = session_mods(true, false, online = true)}

	state_a := new(sim.State, context.temp_allocator)
	defer sim.destroy(state_a)
	state_b := new(sim.State, context.temp_allocator)
	defer sim.destroy(state_b)
	sim.init(state_a, session, defs)
	sim.init(state_b, session, defs)
	rs: [2]net.Rollback_Session
	net.rollback_session_init(&rs[0], state_a, 0, context.temp_allocator)
	net.rollback_session_init(&rs[1], state_b, 1, context.temp_allocator)
	defer net.rollback_session_destroy(&rs[0], context.temp_allocator)
	defer net.rollback_session_destroy(&rs[1], context.temp_allocator)

	Delivery :: struct {
		at:  int,
		buf: [128]byte,
		n:   int,
	}
	LATENCY :: 4
	WINDOW :: 8
	queues: [2][dynamic]Delivery // to each peer
	for &q in queues {
		q = make([dynamic]Delivery, context.temp_allocator)
	}

	r := sim.rand_init(77)
	opened, closed := 0, 0
	was_open := false
	FRAMES :: 6000
	for tick in 0 ..< FRAMES {
		for &q, k in queues {
			w := 0
			for &d in q {
				if d.at > tick {
					q[w] = d
					w += 1
				} else if pkt, ok := net.decode_input(d.buf[:d.n]); ok {
					net.rollback_session_receive(&rs[k], pkt)
				}
			}
			resize(&q, w)
		}
		for k in 0 ..< 2 {
			// Short presses, often, so the reward screen sees moves, locks
			// and changes, and the peer mispredicts them.
			b := sim.Buttons{}
			for btn in ([]sim.Button{.Left, .Right, .Up, .Down, .Fire_Air, .Fire_Ground}) {
				if sim.random_int(&r, 0, 6, 0) == 0 {
					b += {btn}
				}
			}
			net.rollback_session_advance(&rs[k], b)
			if tick % 5 == 4 && tick < FRAMES - 1 {
				continue // dropped
			}
			win: [WINDOW]sim.Buttons
			start, count := net.rollback_session_local_window(&rs[k], WINDOW, win[:])
			if count > 0 {
				d := Delivery{at = tick + LATENCY}
				d.n = net.encode_input(d.buf[:], u8(k), start, win[:count])
				append(&queues[1 - k], d)
			}
		}
		for s in ([]^sim.State{state_a, state_b}) {
			reward_view_reads(t, s)
		}
		open := easy_mode.reward_open(state_a)
		if open && !was_open {
			opened += 1
		} else if !open && was_open {
			closed += 1
		}
		was_open = open
	}
	testing.expect(t, opened > 0, "the reward screen never opened")
	testing.expect(t, closed > 0, "the reward screen never closed")
	testing.expect(t, rs[1].rollback_count > 0, "the guest never rolled back")
}

// What plugins/easy_mode/view's reward_draw reads, without drawing.
@(private = "file")
reward_view_reads :: proc(t: ^testing.T, s: ^sim.State) {
	rw := easy_mode.reward_of(s)
	if rw == nil || !rw.active {
		return
	}
	testing.expect(t, rw.count > 0 && int(rw.count) <= len(rw.options))
	for i in 0 ..< sim.MAX_PLAYERS {
		if !rw.choosing[i] {
			continue
		}
		testing.expect(t, rw.cursor[i] >= 0 && rw.cursor[i] < rw.count, "a cursor off the options")
		pa := rw.options[rw.cursor[i]]
		levels := passives.levels_of(s, i)
		testing.expect(t, levels != nil, "no passive levels for a choosing player")
		_ = passives.passive_maxed(levels, pa)
		_ = easy_mode.reward_ready(s, i)
		_ = easy_mode.reward_selectable(s, i, rw.cursor[i])
	}
}
