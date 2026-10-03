package hitstop_tests

// Hitstop (plugins/hitstop): how long a hit holds the game, what earns the
// kill cam, and where the zoom looks. Plain numbers: no window, no level.

import "core:testing"

import view "dr:plugins/hitstop/view"
import "dr:sim"

@(test)
harder_hits_hold_longer :: proc(t: ^testing.T) {
	testing.expect_value(t, view.hold_steps(0, 100), 0)
	testing.expect_value(t, view.hold_steps(0.5, 100), 3) // a shot is felt
	testing.expect_value(t, view.hold_steps(1, 100), 4)
	testing.expect_value(t, view.hold_steps(10, 100), 10)
	testing.expect(t, view.hold_steps(40, 100) > view.hold_steps(10, 100))
	testing.expect_value(t, view.hold_steps(1e9, 100), view.MAX_HOLD)
}

@(test)
the_setting_scales_the_hold_and_zero_turns_it_off :: proc(t: ^testing.T) {
	testing.expect_value(t, view.hold_steps(1, 0), 0)
	testing.expect_value(t, view.hold_steps(1, 50), 2)
	testing.expect(t, view.hold_steps(1, 200) > view.hold_steps(1, 100))
}

@(test)
a_takedown_is_a_kill_of_over_three_times_the_shields :: proc(t: ^testing.T) {
	kill := sim.Hit_Event{damage = 31, shields = 10, killed = true, enemy = true}
	testing.expect(t, view.is_takedown(kill))
	kill.damage = 30
	testing.expect(t, !view.is_takedown(kill), "exactly three times is not more")
	kill.damage = 31
	kill.killed = false
	testing.expect(t, !view.is_takedown(kill), "a blow that left it standing")
	kill.killed = true
	kill.player = true
	testing.expect(t, !view.is_takedown(kill), "never a player")
	kill = {damage = 31, shields = 10, killed = true}
	testing.expect(t, !view.is_takedown(kill), "scenery, a shot or a bonus is not an enemy")
	kill = {damage = 5, shields = 0, killed = true, enemy = true}
	testing.expect(t, !view.is_takedown(kill), "nothing left to take")
}

@(test)
the_kill_cam_dives_in_and_comes_back :: proc(t: ^testing.T) {
	testing.expect_value(t, view.zoom_at(0), 1)
	testing.expect(t, view.zoom_at(0.5) > view.ZOOM)
	testing.expect_value(t, view.zoom_at(1), 1)
	testing.expect_value(t, view.text_scale_at(0.1), 0)
	testing.expect(t, view.text_scale_at(0.21) > view.text_scale_at(0.5), "slams in large, settles")
	testing.expect_value(t, view.text_scale_at(0.5), 1)
	testing.expect_value(t, view.frame_at(0), 0)
	testing.expect_value(t, view.frame_at(0.5), 1)
}

@(test)
the_zoom_stays_inside_the_field :: proc(t: ^testing.T) {
	field := [4]f32{32, 0, 416, 480}
	r := view.zoom_rect(field, {240, 240}, 2)
	testing.expect_value(t, r, [4]f32{136, 120, 208, 240})
	corner := view.zoom_rect(field, {0, 0}, 2)
	testing.expect_value(t, corner, [4]f32{32, 0, 208, 240})
	far := view.zoom_rect(field, {1000, 1000}, 2)
	testing.expect_value(t, far, [4]f32{240, 240, 208, 240})
	whole := view.zoom_rect(field, {100, 100}, 1)
	testing.expect_value(t, whole, field)
}
