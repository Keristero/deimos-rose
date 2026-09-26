package tests

import "base:runtime"
import "core:testing"

import "dr:plugins/new_weapons"
import "dr:sim"

// The simulation host's own edges (sim/state.odin, rand.odin, input.odin,
// events.odin, queue_effects.odin), on synthetic definitions.

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

// A state read in from a session with other plugins brings its own world,
// with those plugins' components, and plays on as the writer does. Read
// into a state with no world yet, as a guest's is before its first state
// arrives, it builds one. A read that fails leaves the reader's world, and
// its plugins, as they were.
@(test)
a_state_read_across_mods_builds_its_own_world :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	a := new(sim.State)
	defer free(a)
	defer sim.destroy(a)
	b := new(sim.State)
	defer free(b)
	defer sim.destroy(b)
	fresh := new(sim.State)
	defer free(fresh)
	defer sim.destroy(fresh)
	sim.init(a, sim.Session{seed = 5, level_id = sim.level_id("le01"), game_type = .Co_Op, mods = session_mods(true, false)}, defs)
	sim.init(b, sim.Session{seed = 6, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	fresh.defs = defs
	testing.expect(t, sim.level_def(fresh) == nil, "a state with no world has no level")
	press := sim.Frame_Input{{.Fire_Air}, {.Right}}
	for _ in 0 ..< 30 {
		sim.session_step(a, press)
	}
	buf := make([dynamic]byte, context.temp_allocator)
	sim.state_write(a, &buf)

	before := sim.checksum(b)
	testing.expect(t, !sim.state_read(b, buf[:len(buf) - 1]))
	testing.expect_value(t, sim.checksum(b), before)
	testing.expect_value(t, b.session.mods, sim.Mods{})

	testing.expect(t, sim.state_read(b, buf[:]))
	testing.expect(t, sim.state_read(fresh, buf[:]))
	testing.expect_value(t, b.session.mods, a.session.mods)
	for i in 0 ..< 30 {
		sim.session_step(a, press)
		sim.session_step(b, press)
		sim.session_step(fresh, press)
		testing.expectf(t, sim.checksum(b) == sim.checksum(a), "step %d after reading: diverged", i + 1)
		testing.expectf(t, sim.checksum(fresh) == sim.checksum(a), "step %d after reading fresh: diverged", i + 1)
	}
}

// Netplay's pause holds play still, so the presentation freezes too, until
// either player presses Pause again.
@(test)
a_netplay_pause_holds_the_session :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	s := new(sim.State)
	defer free(s)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 2, level_id = sim.level_id("le01"), game_type = .Co_Op, mods = session_mods(false, false, online = true)}, defs)
	sim.session_step(s, {})
	testing.expect(t, !sim.session_frozen(s))
	sim.session_step(s, {{.Pause}, {}})
	testing.expect(t, sim.session_frozen(s), "a pause holds play")
	sim.session_step(s, {})
	sim.session_step(s, {{}, {.Pause}})
	testing.expect(t, !sim.session_frozen(s), "the other player's press lets it go")
}

// A test's own kind of effect event, beside New Weapons' beams.
Test_Effect :: struct {
	n: i32,
}

@(private = "file")
TEST_EFFECT: sim.Effect_Kind

@(init)
register_test_effect :: proc "contextless" () {
	context = runtime.default_context()
	TEST_EFFECT = sim.effect_kind_register(Test_Effect)
}

// Each kind of effect event reads back only its own, in the order pushed;
// a full queue drops what does not fit, and the next step starts empty.
@(test)
effect_events_keep_to_their_kind_and_their_step :: proc(t: ^testing.T) {
	defs := synthetic_defs()
	s := new(sim.State)
	defer free(s)
	defer sim.destroy(s)
	sim.init(s, sim.Session{seed = 4, level_id = sim.level_id("le01"), game_type = .Single}, defs)
	sim.clear_step_events(s)
	for i in 0 ..< sim.MAX_EFFECT_EVENTS + 3 {
		sim.effect_push(s, TEST_EFFECT, Test_Effect{i32(i)})
	}
	walk := sim.effects_of(s, TEST_EFFECT, Test_Effect)
	n: i32
	for ev in sim.effects_next(&walk) {
		testing.expect_value(t, ev.n, n)
		n += 1
	}
	testing.expect_value(t, int(n), sim.MAX_EFFECT_EVENTS)
	testing.expect_value(t, len(new_weapons.beam_shots(s)), 0)
	sim.step(s, {})
	walk = sim.effects_of(s, TEST_EFFECT, Test_Effect)
	_, any := sim.effects_next(&walk)
	testing.expect(t, !any, "a step starts with no events")
}
