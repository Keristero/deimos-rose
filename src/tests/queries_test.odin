package tests

import vmem "core:mem/virtual"
import "core:testing"

import "dr:plugins/fps_unlock"
import "dr:sim"
import "dr:sim/systems/entity_system"

// Component queries (docs/phase-9-ecs.md, D45): a stage runs for the
// entities whose unit's and state's components match it, so a plugin can
// give any unit a core behaviour, and a state's component overrides its
// unit's. The test builders and stages here belong to 30FPS Unlock, which
// no real session carries (it is not a session plugin), so they reach only
// the sessions below, which name it.

Test_Mark :: struct {
	v: i32,
}

@(private = "file")
MINE :: sim.Res_ID{'m', 'i', 'n', 'e'}

@(private = "file")
player_stage_runs: [sim.MAX_PLAYERS]int

// Called from setup.odin, after the build\'s own registration.
register_query_tests :: proc() {
	sim.component_register(Test_Mark)
	sim.prefab_builder_register({
		name = "test_queries",
		plugin = fps_unlock.ID,
		build = proc(p: sim.Prefab, u: ^sim.Unit, st: ^sim.Unit_State) {
			if u.id != MINE {
				return
			}
			// The mine holds the scroll, as a state that pauses it does. A
			// value the builder gives twice keeps the later: the state's,
			// over the unit's.
			sim.prefab_add(p, Test_Mark{1})
			sim.prefab_add(p, entity_system.Pauses_Scrolling{})
			sim.prefab_add(p, Test_Mark{2})
		},
	})
	sim.player_stage_register({
		name = "test_player_stage",
		plugin = fps_unlock.ID,
		run = proc(s: ^sim.State, p: sim.Player, ps: ^sim.Player_Step) -> bool {
			player_stage_runs[p.number] += 1
			return true
		},
	})
}

@(private = "file")
Query_Fixture :: struct {
	arena: vmem.Arena,
	defs:  sim.Defs,
	s:     ^sim.State,
}

// Stage 1 once the ship is in play, with or without the test builders.
@(private = "file")
query_fixture :: proc(t: ^testing.T, f: ^Query_Fixture, builders: bool) -> bool {
	f.defs = assets_defs(t, &f.arena) or_return
	alloc := vmem.arena_allocator(&f.arena)
	f.s = new(sim.State, alloc)
	context.allocator = alloc
	mods := builders ? sim.Mods{int(fps_unlock.ID)} : {}
	return play_start(t, f.s, sim.Session{seed = 1, level_id = f.defs.levels[0].id, game_type = .Single, mods = mods}, &f.defs)
}

@(test)
a_plugins_builder_gives_a_unit_a_core_behaviour :: proc(t: ^testing.T) {
	for builders in ([2]bool{false, true}) {
		f: Query_Fixture
		defer vmem.arena_destroy(&f.arena)
		if !query_fixture(t, &f, builders) {
			return
		}
		if _, ok := unit_spawn(t, f.s, MINE, {200, 100}, stationary = true); !ok {
			return
		}
		sim.session_step(f.s, {})
		sim.session_step(f.s, {})
		// A mine never holds the scroll itself; with the builder, every one
		// of its states has Pauses_Scrolling, and the scroll stops.
		held := sim.single(f.s, sim.Bgnd).speed == 0
		testing.expectf(t, held == builders, "with the builder %v, the scroll held %v", builders, held)
	}
}

@(test)
a_later_value_overrides_an_earlier :: proc(t: ^testing.T) {
	f: Query_Fixture
	defer vmem.arena_destroy(&f.arena)
	if !query_fixture(t, &f, true) {
		return
	}
	e, ok := unit_spawn(t, f.s, MINE, {200, 100}, stationary = true)
	if !ok {
		return
	}
	es := sim.entity_step(f.s, e, 0)
	testing.expect_value(t, es.prefab, sim.prefab_of(f.s, e))
	testing.expect_value(t, sim.prefab_component(f.s, es.prefab, Test_Mark).v, i32(2))
	testing.expect(t, sim.prefab_has(f.s, es.prefab, entity_system.Pauses_Scrolling))
	testing.expect(t, !sim.prefab_has(f.s, es.prefab, entity_system.Motion_Blur))
}

// A plugin's player stage runs for every player in play, and only in a
// session with the plugin on.
@(test)
a_plugins_player_stage_runs_with_its_plugin :: proc(t: ^testing.T) {
	for builders in ([2]bool{false, true}) {
		f: Query_Fixture
		defer vmem.arena_destroy(&f.arena)
		if !query_fixture(t, &f, builders) {
			return
		}
		player_stage_runs = {}
		sim.session_step(f.s, {})
		want := builders ? 1 : 0
		testing.expect_value(t, player_stage_runs[0], want)
	}
}
