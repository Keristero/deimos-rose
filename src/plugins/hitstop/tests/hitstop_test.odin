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
a_takedown_is_any_kill_of_an_enemy :: proc(t: ^testing.T) {
	kill := sim.Hit_Event{damage = 0.1, shields = 10, killed = true, enemy = true}
	testing.expect(t, view.is_takedown(kill), "however little it dealt")
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

@(test)
the_screen_shakes_hardest_at_the_blow_and_settles :: proc(t: ^testing.T) {
	testing.expect_value(t, view.shake_at(0, 1), 1)
	testing.expect(t, view.shake_at(0.3, 1) < view.shake_at(0.1, 1))
	testing.expect(t, view.shake_at(0.7, 1) > 0, "a rumble under the text")
	testing.expect_value(t, view.shake_at(1, 1), 0)
	testing.expect_value(t, view.shake_at(0, 0.5), 0.5)
}

@(test)
the_shake_follows_the_damage :: proc(t: ^testing.T) {
	testing.expect(t, view.shake_power(0.5) >= 0.4, "a shot still shakes hard")
	testing.expect(t, view.shake_power(4) > view.shake_power(0.5))
	testing.expect_value(t, view.shake_power(9), 1)
	testing.expect_value(t, view.shake_power(1e6), 1)
	testing.expect(t, view.shake_power(0) >= 0.25)
}

@(test)
the_boom_is_deep_loud_and_dies_away :: proc(t: ^testing.T) {
	s := view.boom_samples(context.temp_allocator)
	testing.expect_value(t, len(s), int(view.BOOM_RATE * view.BOOM_SECONDS))
	peak :: proc(s: []f32) -> (m: f32) {
		for v in s {
			m = max(m, abs(v))
		}
		return
	}
	for v in s {
		testing.expect(t, v >= -1 && v <= 1)
	}
	testing.expect(t, peak(s[:view.BOOM_RATE / 4]) > 0.9, "loud at the start")
	testing.expect(t, peak(s[len(s) - 2000:]) < 0.2, "gone by the end")
	// Deep: slow zero crossings in the body (under 100 Hz).
	crossings := 0
	body := s[view.BOOM_RATE / 2:view.BOOM_RATE]
	for i in 1 ..< len(body) {
		if (body[i - 1] < 0) != (body[i] < 0) {
			crossings += 1
		}
	}
	hz := f32(crossings) / 2 / (f32(len(body)) / view.BOOM_RATE)
	testing.expect(t, hz < 100 && hz > 15, "a low boom")
}
