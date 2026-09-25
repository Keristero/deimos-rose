package tests

import "core:log"
import "core:os"
import "core:testing"
import vmem "core:mem/virtual"

import "dr:data"
import "dr:sim"

// Whole-session regression tests for the level skip: finishing one level
// used to chain through every remaining level in as many steps, straight to
// ALL LEVELS COMPLETE, because level_end.complete survived level_advance.
// These drive sim.level_transition -- the exact decision game/flow.odin's
// flow_step makes after every step -- rather than level_advance alone.

Session_Result :: struct {
	outcome:     sim.Level_Transition, // how the session ended
	level_steps: [dynamic]i32,         // steps spent on each level, in play order
	levels_seen: [dynamic]i32,         // level_number of each level, in play order
}

// Plays from `start` until the session ends, keeping every player in play
// so the only way out is finishing levels. `max_steps` bounds a hang.
@(private = "file")
play_session :: proc(defs: ^sim.Defs, start: sim.Level_ID, max_steps: int, allocator := context.allocator) -> Session_Result {
	r := Session_Result {
		level_steps = make([dynamic]i32, allocator),
		levels_seen = make([dynamic]i32, allocator),
	}
	s := new(sim.State)
	defer sim.destroy(s)
	defer free(s)
	sim.init(s, sim.Session{seed = 7, level_id = start, game_type = .Single}, defs)
	append(&r.levels_seen, sim.single(s, sim.Level_Info).number)
	steps: i32 = 0
	for _ in 0 ..< max_steps {
		for &p in s.players {
			p.invulnerable_always = true
			p.invulnerable = true
		}
		sim.step(s, {})
		steps += 1
		switch sim.level_transition(s) {
		case .None:
		case .Advanced:
			append(&r.level_steps, steps)
			append(&r.levels_seen, sim.single(s, sim.Level_Info).number)
			steps = 0
		case .Game_Over, .All_Complete:
			append(&r.level_steps, steps)
			r.outcome = sim.level_transition(s)
			return r
		}
	}
	r.outcome = .None // ran out of steps
	return r
}

@(test)
every_level_is_played_in_full_synthetic :: proc(t: ^testing.T) {
	// Three short levels. Each must take at least as long as its background
	// takes to scroll to the end -- a skipped level takes one step.
	defs := synthetic_defs()
	levels := make([]sim.Level_Def, 3, context.temp_allocator)
	for &l, i in levels {
		l = defs.levels[0]
		l.number = i32(i + 1)
		l.background.bottom = 1200
	}
	defs.levels = levels
	scroll := i32(1200) - i32(defs.perm_floats[sim.PF_VISIBLE_GAME_HEIGHT]) - 1

	r := play_session(defs, levels[0].id, 100_000)
	defer delete(r.level_steps)
	defer delete(r.levels_seen)

	testing.expect_value(t, r.outcome, sim.Level_Transition.All_Complete)
	testing.expect_value(t, len(r.levels_seen), 3)
	for n, i in r.levels_seen {
		testing.expectf(t, n == i32(i + 1), "level %d played as level_number %d", i + 1, n)
	}
	for n, i in r.level_steps {
		testing.expectf(t, n >= scroll, "level %d lasted %d steps, under the %d its scroll takes", i + 1, n, scroll)
	}
}

@(test)
every_level_is_played_in_full_real_data :: proc(t: ^testing.T) {
	// The same check against the shipped level list (src/assets, committed
	// per D29), from level 1 to ALL LEVELS COMPLETE. Every level's map is
	// 3600 rows, so none can finish in under ~3000 steps; before the fix,
	// levels 2..12 each lasted a single step.
	if !os.exists("assets/data/index.json") {
		log.info("skipped: needs the extracted assets tree")
		return
	}
	arena: vmem.Arena
	testing.expect(t, vmem.arena_init_growing(&arena) == nil)
	defer vmem.arena_destroy(&arena)
	alloc := vmem.arena_allocator(&arena)

	defs, _ := data.assets_defs_load("assets", alloc)
	if !testing.expect(t, len(defs.levels) > 1, "the level list must load") {
		return
	}
	r := play_session(&defs, defs.levels[0].id, 1_000_000, alloc)

	testing.expect_value(t, r.outcome, sim.Level_Transition.All_Complete)
	testing.expect_value(t, len(r.levels_seen), len(defs.levels))
	for n, i in r.levels_seen {
		testing.expectf(t, n == i32(i + 1), "level %d played as level_number %d", i + 1, n)
	}
	for n, i in r.level_steps {
		testing.expectf(t, n >= 3000, "level %d lasted only %d steps", i + 1, n)
	}
}
