package tests

import "core:testing"

import net "dr:net"
import "dr:sim"

// Phase 6 stage 3's real guarantee: two independent Rollback_Sessions, each
// driving one local player and predicting the other, must end up bit-
// identical even when the "network" between them delays every packet and
// drops some outright -- no real socket involved, just two sessions handed
// each other's encoded Input packets on a delay, exactly as net/socket.odin
// would deliver them for real.
@(test)
rollback_session_converges_under_latency_and_loss :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	session := sim.Session{seed = 0x51DE, level_id = sim.level_id("le01"), game_type = .Co_Op}

	FRAMES :: 120
	inputs0 := make([]sim.Buttons, FRAMES, context.temp_allocator)
	inputs1 := make([]sim.Buttons, FRAMES, context.temp_allocator)
	r := sim.rand_init(55)
	for i in 0 ..< FRAMES {
		a, b := sim.Buttons{}, sim.Buttons{}
		if sim.random_int(&r, 0, 2, 0) == 0 { a += {.Left} }
		if sim.random_int(&r, 0, 2, 0) == 0 { a += {.Fire_Ground} }
		if sim.random_int(&r, 0, 2, 0) == 0 { b += {.Right} }
		if sim.random_int(&r, 0, 2, 0) == 0 { b += {.Fire_Air} }
		inputs0[i], inputs1[i] = a, b
	}

	state_a := new(sim.State, context.temp_allocator)
	state_b := new(sim.State, context.temp_allocator)
	sim.init(state_a, session, defs)
	sim.init(state_b, session, defs)

	rs_a, rs_b: net.Rollback_Session
	net.rollback_session_init(&rs_a, state_a, 0, context.temp_allocator)
	net.rollback_session_init(&rs_b, state_b, 1, context.temp_allocator)
	defer net.rollback_session_destroy(&rs_a, context.temp_allocator)
	defer net.rollback_session_destroy(&rs_b, context.temp_allocator)

	Delivery :: struct {
		deliver_at: int,
		buf:        [128]byte,
		n:          int,
	}
	LATENCY :: 4
	WINDOW :: 8

	to_a := make([dynamic]Delivery, context.temp_allocator)
	to_b := make([dynamic]Delivery, context.temp_allocator)

	deliver_due :: proc(queue: ^[dynamic]Delivery, tick: int, rs: ^net.Rollback_Session) {
		w := 0
		for &d in queue {
			if d.deliver_at <= tick {
				if pkt, ok := net.decode_input(d.buf[:d.n]); ok {
					net.rollback_session_receive(rs, pkt)
				}
			} else {
				queue[w] = d
				w += 1
			}
		}
		resize(queue, w)
	}

	send_count := 0
	for i in 0 ..< FRAMES {
		// Whatever the peer sent earlier that is due by this tick arrives
		// before this tick's local advance, exactly as a real poll loop
		// would process it ahead of stepping the simulation.
		deliver_due(&to_a, i, &rs_a)
		deliver_due(&to_b, i, &rs_b)

		net.rollback_session_advance(&rs_a, inputs0[i])
		net.rollback_session_advance(&rs_b, inputs1[i])

		send_count += 1
		if send_count % 5 == 0 {
			continue // drop this tick's send in both directions
		}

		win: [WINDOW]sim.Buttons
		start_a, count_a := net.rollback_session_local_window(&rs_a, WINDOW, win[:])
		if count_a > 0 {
			d: Delivery
			d.n = net.encode_input(d.buf[:], 0, start_a, win[:count_a])
			d.deliver_at = i + LATENCY
			append(&to_b, d)
		}

		win_b: [WINDOW]sim.Buttons
		start_b, count_b := net.rollback_session_local_window(&rs_b, WINDOW, win_b[:])
		if count_b > 0 {
			d: Delivery
			d.n = net.encode_input(d.buf[:], 1, start_b, win_b[:count_b])
			d.deliver_at = i + LATENCY
			append(&to_a, d)
		}
	}

	// Drain whatever is still in flight so both sessions see every frame's
	// real input before the final comparison.
	for i in FRAMES ..< FRAMES + LATENCY + 1 {
		deliver_due(&to_a, i, &rs_a)
		deliver_due(&to_b, i, &rs_b)
	}

	testing.expect_value(t, state_a.frame, u32(FRAMES))
	testing.expect_value(t, sim.checksum(state_a), sim.checksum(state_b))
	// Otherwise this test would prove nothing: with inputs changing this
	// often against 4 frames of latency, prediction must have guessed wrong
	// and triggered a rollback along the way.
	testing.expect(t, rs_a.rollback_count > 0, "test never exercised a rollback")
	testing.expect(t, rs_b.rollback_count > 0, "test never exercised a rollback")
}

@(test)
rollback_session_local_window_caps_to_what_has_actually_been_played :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	state := new(sim.State, context.temp_allocator)
	sim.init(state, sim.Session{seed = 1, level_id = sim.level_id("le01"), game_type = .Single}, defs)

	rs: net.Rollback_Session
	net.rollback_session_init(&rs, state, 0, context.temp_allocator)
	defer net.rollback_session_destroy(&rs, context.temp_allocator)

	buf: [8]sim.Buttons
	_, before_count := net.rollback_session_local_window(&rs, 8, buf[:])
	testing.expect_value(t, before_count, 0)

	net.rollback_session_advance(&rs, {.Left})
	net.rollback_session_advance(&rs, {.Right})
	net.rollback_session_advance(&rs, {.Up})

	start, count := net.rollback_session_local_window(&rs, 8, buf[:])
	testing.expect_value(t, count, 3)
	testing.expect_value(t, start, u32(0))
	testing.expect_value(t, buf[0], sim.Buttons{.Left})
	testing.expect_value(t, buf[1], sim.Buttons{.Right})
	testing.expect_value(t, buf[2], sim.Buttons{.Up})

	start2, count2 := net.rollback_session_local_window(&rs, 2, buf[:])
	testing.expect_value(t, count2, 2)
	testing.expect_value(t, start2, u32(1))
	testing.expect_value(t, buf[0], sim.Buttons{.Right})
	testing.expect_value(t, buf[1], sim.Buttons{.Up})
}
