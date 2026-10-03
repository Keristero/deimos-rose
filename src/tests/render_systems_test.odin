package tests

import "core:log"
import vmem "core:mem/virtual"
import "core:testing"

// Every plugin, as the game links them: their render systems are the ones
// placed against each other here.
import _ "dr:game"
import "dr:plugins/accent"
import lighting_view "dr:plugins/lighting/view"
import "dr:plugins/wind"
import wind_view "dr:plugins/wind/view"
import "dr:prefs"
import "dr:render"
import "dr:sim"

// The render systems place themselves against each other by name, as the
// simulation's do: a misspelt name would silently leave one unplaced.
@(test)
render_systems_name_only_registered_systems :: proc(t: ^testing.T) {
	items := make([dynamic]sim.Order_Item, context.temp_allocator)
	for sys in render.registered_render_systems() {
		append(&items, sim.Order_Item{sys.name, sys.after, sys.before})
	}
	testing.expect_value(t, len(sim.schedule_unknown(items[:], context.temp_allocator)), 0)
	_, ok := sim.schedule(items[:], context.temp_allocator)
	testing.expect(t, ok, "the render systems' order has a cycle")
}

// Self Outline rings the ship from underneath, so it must be drawn into
// the ship's layer before the ship is.
@(test)
render_schedule_draws_the_outline_under_the_ships :: proc(t: ^testing.T) {
	sched: render.Render_Schedule
	render.render_schedule_build(&sched, ~sim.Mods{})
	registered := render.registered_render_systems()
	at :: proc(sched: ^render.Render_Schedule, registered: []render.Render_System, name: string) -> int {
		for idx, i in sched.order[:sched.count] {
			if registered[idx].name == name {
				return i
			}
		}
		return -1
	}
	outline, players := at(&sched, registered, "outline"), at(&sched, registered, "players")
	testing.expect(t, outline >= 0 && players >= 0, "outline and players are both scheduled")
	testing.expect(t, outline < players, "the outline is drawn before the ships")
	testing.expect_value(t, at(&sched, registered, "layers_clear"), 0)
}

// The outline is the Accent Color plugin's: without it, it is not drawn at
// all.
@(test)
render_schedule_leaves_the_outline_to_its_plugin :: proc(t: ^testing.T) {
	registered := render.registered_render_systems()
	has_outline :: proc(sched: ^render.Render_Schedule, registered: []render.Render_System) -> bool {
		for idx in sched.order[:sched.count] {
			if registered[idx].name == "outline" {
				return true
			}
		}
		return false
	}
	sched: render.Render_Schedule
	render.render_schedule_build(&sched, {})
	testing.expect(t, !has_outline(&sched, registered), "the outline is drawn with no plugins on")
	render.render_schedule_build(&sched, {int(accent.ID)})
	testing.expect(t, has_outline(&sched, registered), "the outline is not drawn with Accent Color on")
}

// A presentation plugin of the player's own (Renderer.mods) runs its effect
// systems though the session does not carry it; nothing runs without it.
@(test)
effect_systems_run_for_the_players_own_plugins :: proc(t: ^testing.T) {
	r: render.Renderer
	s: sim.State
	testing.expect(t, !render.effect_on(&r, &s, wind.ID), "off with neither the session nor the player")
	r.mods = {int(wind.ID)}
	testing.expect(t, render.effect_on(&r, &s, wind.ID))
}

// The Percent settings of the post-pass plugins stay in 0..100.
@(test)
percent_settings_are_clamped :: proc(t: ^testing.T) {
	testing.expect_value(t, prefs.setting_clean(lighting_view.LIGHT_STRENGTH, 250), 100)
	testing.expect_value(t, prefs.setting_clean(lighting_view.GLOW_STRENGTH, -3), 0)
	testing.expect_value(t, prefs.setting_clean(wind_view.STRENGTH, 40), 40)
}

// A shot to the ground runs from the ship's height to the ground over its
// flight: its fall climbs from 0 to 1 and a landed one stays at 1.
@(test)
fall_runs_from_zero_to_one_over_the_flight :: proc(t: ^testing.T) {
	testing.expect_value(t, render.fall_progress(0, 19, false), 0)
	testing.expect_value(t, render.fall_progress(9.5, 19, false), 0.5)
	testing.expect_value(t, render.fall_progress(19, 19, false), 1)
	testing.expect_value(t, render.fall_progress(40, 19, false), 1)
	testing.expect_value(t, render.fall_progress(0, 19, true), 1)
	testing.expect_value(t, render.fall_progress(0, 0, false), 1)
}

// The Plasma Bomb, against the shipped content: it comes down over its
// flight and never rises, it has landed when it hits, and a unit that is
// not a shot to the ground does not fall at all.
@(test)
a_plasma_bomb_falls_from_the_ship_to_the_ground :: proc(t: ^testing.T) {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	defs, loaded := assets_defs(t, &arena)
	if !loaded {
		return
	}
	alloc := vmem.arena_allocator(&arena)
	s := new(sim.State, alloc)
	context.allocator = alloc // the state's world goes in the arena too
	if !play_start(t, s, sim.Session{seed = 1, level_id = defs.levels[0].id, game_type = .Single}, &defs) {
		return
	}
	if sim.player_at(s, 0).weapons.ground.weapon == sim.NO_WEAPON {
		log.info("skipped: no ground weapon in the first stage")
		return
	}
	bomb := sim.res_id("plbo")
	first, last: f32 = -1, -1
	steps_seen, rises := 0, 0
	for i in 0 ..< 60 {
		_ = sim.session_step(s, i < 4 ? sim.Frame_Input{{.Fire_Ground}, {}} : sim.Frame_Input{})
		walk := sim.walk_entities(s)
		for e in sim.walk_next(&walk) {
			u := &s.defs.units[e.unit]
			if u.id != bomb {
				continue
			}
			fall := render.fall_of(s, e, u)
			testing.expect(t, fall >= 0 && fall <= 1, "a bomb falls, between 0 and 1")
			if steps_seen == 0 {
				first = fall
			}
			if fall < last {
				rises += 1
			}
			last = fall
			steps_seen += 1
		}
	}
	testing.expect(t, steps_seen > 10, "the bomb is in the air for most of 20 steps")
	testing.expect(t, first < 0.2, "a bomb starts high")
	testing.expect_value(t, last, 1)
	testing.expect_value(t, rises, 0)
	// The ship itself is a player's, in the air, and not a shot to the ground.
	ship := sim.player_at(s, 0)
	testing.expect_value(t, ship.obj.is_air, true)
}
