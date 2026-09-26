package tests

import "core:testing"

import net "dr:net"
import netplay_plugin "dr:plugins/netplay"
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
	defer sim.destroy(state_a)
	state_b := new(sim.State, context.temp_allocator)
	defer sim.destroy(state_b)
	sim.init(state_a, session, defs)
	sim.init(state_b, session, defs)

	rs_a, rs_b: net.Rollback_Session
	net.rollback_session_init(&rs_a, state_a, 0, context.temp_allocator)
	net.rollback_session_init(&rs_b, state_b, 1, context.temp_allocator)
	defer net.rollback_session_destroy(&rs_a, context.temp_allocator)
	defer net.rollback_session_destroy(&rs_b, context.temp_allocator)

	dm_a, dm_b: net.Desync_Monitor

	Delivery :: struct {
		deliver_at: int,
		buf:        [128]byte,
		n:          int,
	}
	LATENCY :: 4
	WINDOW :: 8
	CHECKSUM_LAG :: 20 // well under ROLLBACK_DEPTH (64); see rollback_session_checksum_at

	to_a := make([dynamic]Delivery, context.temp_allocator)
	to_b := make([dynamic]Delivery, context.temp_allocator)

	// A delivered buffer can be an Input or a Checksum packet; dispatch on
	// its kind exactly as a real poll loop would.
	deliver_due :: proc(queue: ^[dynamic]Delivery, tick: int, rs: ^net.Rollback_Session, dm: ^net.Desync_Monitor) {
		w := 0
		for &d in queue {
			if d.deliver_at <= tick {
				switch kind, kok := net.peek_kind(d.buf[:d.n]); {
				case kok && kind == .Input:
					if pkt, ok := net.decode_input(d.buf[:d.n]); ok {
						net.rollback_session_receive(rs, pkt)
					}
				case kok && kind == .Checksum:
					if frame, sum, ok := net.decode_checksum(d.buf[:d.n]); ok {
						net.desync_monitor_receive(dm, frame, sum)
					}
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
		deliver_due(&to_a, i, &rs_a, &dm_a)
		deliver_due(&to_b, i, &rs_b, &dm_b)

		net.rollback_session_advance(&rs_a, inputs0[i])
		net.rollback_session_advance(&rs_b, inputs1[i])

		send_count += 1
		// Drop this tick's send in both directions -- but not the last
		// tick's: nothing sends after it, so the last frame's input would
		// never arrive and each side would end on its own guess.
		if send_count % 5 == 0 && i < FRAMES - 1 {
			continue
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

		// Each side reports (and records, for comparison against the peer's
		// own report) the checksum for a frame CHECKSUM_LAG behind -- old
		// enough that no in-flight packet could still roll it back.
		if u32(i) >= CHECKSUM_LAG {
			cf := u32(i) - CHECKSUM_LAG
			if sum, ok := net.rollback_session_checksum_at(&rs_a, cf); ok {
				net.desync_monitor_record(&dm_a, cf, sum)
				d: Delivery
				d.n = net.encode_checksum(d.buf[:], cf, sum)
				d.deliver_at = i + LATENCY
				append(&to_b, d)
			}
			if sum, ok := net.rollback_session_checksum_at(&rs_b, cf); ok {
				net.desync_monitor_record(&dm_b, cf, sum)
				d: Delivery
				d.n = net.encode_checksum(d.buf[:], cf, sum)
				d.deliver_at = i + LATENCY
				append(&to_a, d)
			}
		}
	}

	// Drain whatever is still in flight so both sessions see every frame's
	// real input before the final comparison.
	for i in FRAMES ..< FRAMES + LATENCY + 1 {
		deliver_due(&to_a, i, &rs_a, &dm_a)
		deliver_due(&to_b, i, &rs_b, &dm_b)
	}

	testing.expect_value(t, sim.frame_of(state_a), u32(FRAMES))
	testing.expect_value(t, sim.checksum(state_a), sim.checksum(state_b))
	// Otherwise this test would prove nothing: with inputs changing this
	// often against 4 frames of latency, prediction must have guessed wrong
	// and triggered a rollback along the way.
	testing.expect(t, rs_a.rollback_count > 0, "test never exercised a rollback")
	testing.expect(t, rs_b.rollback_count > 0, "test never exercised a rollback")
	// And the desync monitor, fed real checksums exchanged the whole way
	// through, must never have flagged the two peers as diverged.
	testing.expect(t, !dm_a.desynced, "desync monitor false-positived on a")
	testing.expect(t, !dm_b.desynced, "desync monitor false-positived on b")
}

@(test)
rollback_session_local_window_caps_to_what_has_actually_been_played :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	state := new(sim.State, context.temp_allocator)
	defer sim.destroy(state)
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

// Phase 8 stage 5: rollback_session_frame_advantage is the signal
// netplay_should_stall throttles on -- it must read 0 before anything has
// been heard from the peer (not a huge false lead), then track the actual
// gap between frames simulated locally and the highest remote frame
// confirmed by rollback_session_receive, and must not count a still-
// predicted (not yet confirmed) remote frame as closing that gap.
@(test)
rollback_session_frame_advantage_tracks_the_confirmed_remote_frame :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	state := new(sim.State, context.temp_allocator)
	defer sim.destroy(state)
	sim.init(state, sim.Session{seed = 1, level_id = sim.level_id("le01"), game_type = .Co_Op}, defs)

	rs: net.Rollback_Session
	net.rollback_session_init(&rs, state, 0, context.temp_allocator)
	defer net.rollback_session_destroy(&rs, context.temp_allocator)

	testing.expect_value(t, net.rollback_session_frame_advantage(&rs), 0)

	// Simulate 6 local frames (0..5, sim.frame_of(state) becomes 6) with nothing at
	// all confirmed from the peer yet -- still predicting throughout.
	for i in 0 ..< 6 {
		net.rollback_session_advance(&rs, {})
	}
	testing.expect_value(t, net.rollback_session_frame_advantage(&rs), 0)

	// The peer confirms frames 0..2: this side has simulated frames 0..5
	// (sim.frame_of(state) == 6) but only knows the peer's real input through frame
	// 2, i.e. it is 3 frames ahead of what it can confirm (6 - 2 - 1 == 3).
	frames: [3]sim.Buttons
	buf: [64]byte
	n := net.encode_input(buf[:], 1, 0, frames[:])
	pkt, ok := net.decode_input(buf[:n])
	testing.expect(t, ok)
	net.rollback_session_receive(&rs, pkt)
	testing.expect_value(t, net.rollback_session_frame_advantage(&rs), 3)

	// Advancing further without any new confirmation widens the lead.
	for i in 0 ..< 2 {
		net.rollback_session_advance(&rs, {})
	}
	testing.expect_value(t, net.rollback_session_frame_advantage(&rs), 5)
}

// Phase 8 stage 5: rollback_session_should_stall is the throttle
// netplay_playing_step gates a whole tick on. Drives a Rollback_Session's
// frame straight to a chosen value (rather than replaying real ticks) via
// repeated no-input advances, so each case's frame_advantage is exact and
// the period math can be checked directly against sim.frame_of(rs.state)'s parity.
@(test)
rollback_session_should_stall_throttles_only_once_over_threshold :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	state := new(sim.State, context.temp_allocator)
	defer sim.destroy(state)
	sim.init(state, sim.Session{seed = 1, level_id = sim.level_id("le01"), game_type = .Co_Op}, defs)

	rs: net.Rollback_Session
	net.rollback_session_init(&rs, state, 0, context.temp_allocator)
	defer net.rollback_session_destroy(&rs, context.temp_allocator)

	THRESHOLD :: 5
	MIN_EVERY :: 2

	// No peer input confirmed at all yet -- frame_advantage reads 0
	// (rollback_session_frame_advantage_tracks_the_confirmed_remote_frame
	// above), well under THRESHOLD, so never stalls regardless of how many
	// frames have been simulated locally.
	for i in 0 ..< 10 {
		net.rollback_session_advance(&rs, {})
		testing.expect(t, !net.rollback_session_should_stall(&rs, THRESHOLD, MIN_EVERY))
	}

	// Confirm frame 3: sim.frame_of(state) is 10, so frame_advantage == 10-3-1 == 6,
	// one over THRESHOLD -- every == max(5-1, 2) == 4. 10 % 4 == 2, not a
	// stall point.
	frames: [4]sim.Buttons
	buf: [64]byte
	n := net.encode_input(buf[:], 1, 0, frames[:])
	pkt, ok := net.decode_input(buf[:n])
	testing.expect(t, ok)
	net.rollback_session_receive(&rs, pkt)
	testing.expect_value(t, net.rollback_session_frame_advantage(&rs), 6)
	testing.expect(t, !net.rollback_session_should_stall(&rs, THRESHOLD, MIN_EVERY))

	// Advancing without any further confirmation widens the lead each tick,
	// which shrinks (more aggressive) the throttle period each tick too:
	// at sim.frame_of(state) 11, advantage 7, every == max(5-2, 2) == 3 (11 % 3 == 2,
	// no stall); at sim.frame_of(state) 12, advantage 8, every == max(5-3, 2) == 2
	// (12 % 2 == 0, a stall point).
	net.rollback_session_advance(&rs, {}) // sim.frame_of(state) -> 11
	testing.expect(t, !net.rollback_session_should_stall(&rs, THRESHOLD, MIN_EVERY))
	net.rollback_session_advance(&rs, {}) // sim.frame_of(state) -> 12
	testing.expect(t, net.rollback_session_should_stall(&rs, THRESHOLD, MIN_EVERY))
}

// The desync behind notes/netcode-enhancements.md's "transitions between
// levels desync": game/flow.odin used to apply the level change after
// rollback_session_advance returned -- outside the snapshots and outside any
// resimulation -- so a rollback reaching back past it replayed the finished
// level without moving on, and each peer then changed level on whichever
// frame it happened to notice. Two peers here play through several short
// levels under latency and loss, pausing and unpausing along the way (the
// pause is a sim input too, and must converge the same way). After each
// advance they apply sim.level_transition exactly as the old flow did: with
// the level change inside session_step that is a no-op, and without it this
// test fails.
@(test)
rollback_session_converges_across_level_changes_and_pauses :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	levels := make([]sim.Level_Def, 3, context.temp_allocator)
	for &l, i in levels {
		l = defs.levels[0]
		l.number = i32(i + 1)
		l.background.bottom = 700 // a ~220-step scroll per level
	}
	defs.levels = levels
	session := sim.Session{seed = 0xC0FFEE, level_id = levels[0].id, game_type = .Co_Op, mods = session_mods(false, false, online = true)}

	FRAMES :: 1100
	LATENCY :: 6
	WINDOW :: 8
	inputs := [2][]sim.Buttons{make([]sim.Buttons, FRAMES, context.temp_allocator), make([]sim.Buttons, FRAMES, context.temp_allocator)}
	r := sim.rand_init(77)
	for i in 0 ..< FRAMES {
		for p in 0 ..< 2 {
			b: sim.Buttons
			if sim.random_int(&r, 0, 2, 0) == 0 { b += {p == 0 ? .Left : .Right} }
			if sim.random_int(&r, 0, 3, 0) == 0 { b += {.Fire_Air} }
			inputs[p][i] = b
		}
	}
	// Each player pauses and unpauses once: a short hold, some frames apart,
	// placed in the middle of levels and across a level end.
	hold :: proc(b: []sim.Buttons, at: int) {
		for f in at ..< at + 3 { b[f] += {.Pause} }
	}
	hold(inputs[0][:], 150)
	hold(inputs[1][:], 190) // player 2 unpauses what player 1 paused
	hold(inputs[1][:], 520)
	hold(inputs[0][:], 560)

	states := [2]^sim.State{new(sim.State, context.temp_allocator), new(sim.State, context.temp_allocator)}
	defer for st in states { sim.destroy(st) }
	rs: [2]net.Rollback_Session
	for p in 0 ..< 2 {
		sim.init(states[p], session, defs)
		net.rollback_session_init(&rs[p], states[p], p, context.temp_allocator)
	}
	defer for p in 0 ..< 2 { net.rollback_session_destroy(&rs[p], context.temp_allocator) }

	Delivery :: struct {
		deliver_at: int,
		pkt:        net.Input_Packet,
	}
	queues := [2][dynamic]Delivery{make([dynamic]Delivery, context.temp_allocator), make([dynamic]Delivery, context.temp_allocator)}
	paused_frames := 0
	max_level: i32 = 0

	for i in 0 ..< FRAMES + LATENCY + 1 {
		for p in 0 ..< 2 {
			w := 0
			for d in queues[p] {
				if d.deliver_at <= i {
					net.rollback_session_receive(&rs[p], d.pkt)
				} else {
					queues[p][w] = d
					w += 1
				}
			}
			resize(&queues[p], w)
		}
		if i >= FRAMES {
			continue // just draining what is still in flight
		}
		for p in 0 ..< 2 {
			net.rollback_session_advance(&rs[p], inputs[p][i])
			_ = sim.level_transition(states[p]) // what game/flow.odin used to do here
			if i % 5 == 4 {
				continue // lose this tick's packet
			}
			win: [WINDOW]sim.Buttons
			start, count := net.rollback_session_local_window(&rs[p], WINDOW, win[:])
			if count > 0 {
				buf: [64]byte
				n := net.encode_input(buf[:], u8(p), start, win[:count])
				pkt, _ := net.decode_input(buf[:n])
				append(&queues[1 - p], Delivery{i + LATENCY, pkt})
			}
		}
		if netplay_plugin.paused(states[0]) {
			paused_frames += 1
		}
		max_level = max(max_level, sim.single(states[0], sim.Level_Info).number)
	}

	testing.expect(t, rs[0].rollback_count > 0 && rs[1].rollback_count > 0, "test never exercised a rollback")
	testing.expect(t, max_level >= 3, "test never reached the third level")
	testing.expect(t, paused_frames > 0, "test never paused")
	testing.expect_value(t, sim.single(states[0], sim.Level_Info).number, sim.single(states[1], sim.Level_Info).number)
	testing.expect_value(t, sim.single(states[0], sim.Clock).time, sim.single(states[1], sim.Clock).time)
	testing.expect_value(t, netplay_plugin.paused(states[0]), netplay_plugin.paused(states[1]))
	testing.expect_value(t, sim.checksum(states[0]), sim.checksum(states[1]))
}
