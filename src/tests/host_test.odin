package tests

import "core:testing"

import "dr:sim"

// The simulation host's own edges (sim/state.odin, rand.odin, input.odin,
// events.odin), on synthetic definitions.

// A state is read only from bytes this build wrote: anything shorter than
// a state, or whose world is not one this build's catalog wrote, is refused
// and changes nothing.
@(test)
state_read_refuses_what_is_not_a_state :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	s := new(sim.State)
	defer free(s)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 3, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	for _ in 0 ..< 50 {
		sim.step(s, {})
	}
	buf := make([dynamic]byte, context.temp_allocator)
	sim.state_write(s, &buf)
	sim.step(s, {})
	before := sim.checksum(s)

	testing.expect(t, !sim.state_read(s, buf[:size_of(sim.State) - 1]), "a short state must be refused")
	bad := make([]byte, len(buf), context.temp_allocator)
	copy(bad, buf[:])
	bad[size_of(sim.State)] ~= 0xff // the world's header: another build's catalog
	testing.expect(t, !sim.state_read(s, bad), "another build's world must be refused")
	testing.expect(t, !sim.state_read(s, buf[:len(buf) - 1]), "a world cut short must be refused")
	testing.expect_value(t, sim.checksum(s), before)

	// And the bytes as written go back to the state they came from.
	testing.expect(t, sim.state_read(s, buf[:]))
	testing.expect(t, sim.checksum(s) != before)
}

// A button is pressed on the step it goes down and released on the step it
// comes up, not while it is held.
@(test)
presses_and_releases_are_edges :: proc(t: ^testing.T) {
	held := sim.Buttons{.Fire_Air}
	testing.expect(t, sim.pressed(held, {}, .Fire_Air))
	testing.expect(t, !sim.pressed(held, held, .Fire_Air))
	testing.expect(t, sim.released({}, held, .Fire_Air))
	testing.expect(t, !sim.released(held, held, .Fire_Air))
	testing.expect(t, !sim.released({}, {}, .Fire_Air))
}

// Over the whole range of an i32 the span (hi - lo + 1) wraps to zero,
// which the original divides by. The port still draws, so the sequence
// moves on as it would have, and answers lo.
@(test)
random_int_over_every_i32_still_draws :: proc(t: ^testing.T) {
	r := sim.rand_init(42)
	v := sim.random_int(&r, min(i32), max(i32), 0)
	testing.expect_value(t, v, min(i32))
	testing.expect(t, r.next != 42, "a draw must be made")
}

// A full event log counts what it drops rather than overwriting.
@(test)
a_full_event_log_counts_what_it_drops :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	events := sim.Event_Log{events = make([]sim.Event, 2, context.temp_allocator)}
	s := new(sim.State)
	defer free(s)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 3, level_id = sim.level_id("le01"), game_type = .Single}, defs, nil, &events)
	events.count, events.dropped = 0, 0
	for _ in 0 ..< 5 {
		sim.record_event(s, sim.Event{kind = .Sound})
	}
	testing.expect_value(t, events.count, 2)
	testing.expect_value(t, events.dropped, 3)
}
