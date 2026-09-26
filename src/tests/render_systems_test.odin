package tests

import "core:testing"

import "dr:game"
import "dr:plugins/accent"
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
