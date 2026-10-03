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

@(test)
the_slowdown_deepens_with_the_damage :: proc(t: ^testing.T) {
	testing.expect(t, abs(view.slow_speed(0) - 0.30) < 1e-5)
	testing.expect(t, abs(view.slow_speed(1) - 0.01) < 1e-5)
	testing.expect(t, view.slow_speed(view.slow_power(4)) < view.slow_speed(view.slow_power(0.5)), "more damage, slower")
	testing.expect_value(t, view.slow_power(9), 1)
	testing.expect_value(t, view.speed_at(0, 1), 1) // real time before it
	testing.expect(t, abs(view.speed_at(0.4, 1) - 0.01) < 1e-5) // the bottom of it
	testing.expect_value(t, view.speed_at(1, 1), 1) // and back after
	testing.expect(t, view.speed_at(0.4, 0) >= 0.3 - 1e-6)
	testing.expect(t, view.speed_at(0.85, 1) > 0.01 && view.speed_at(0.85, 1) < 1, "easing out")
}

@(test)
the_sound_slows_and_gets_reverb_with_the_damage :: proc(t: ^testing.T) {
	testing.expect_value(t, view.audio_slow_at(0, 1), 0)
	testing.expect(t, view.audio_slow_at(0.4, 1) > view.audio_slow_at(0.4, 0))
	testing.expect(t, view.audio_slow_at(0.4, 1) < 1)
	testing.expect(t, view.reverb_at(0.4, 1) > view.reverb_at(0.4, 0))
	testing.expect_value(t, view.reverb_at(0, 1), 0)
	testing.expect_value(t, view.reverb_at(1, 1), 0)
}

@(test)
streaks_are_named_as_the_game_calls_them :: proc(t: ^testing.T) {
	want := [8]string{"Takedown", "Multi Kill", "Oh Baby, a Triple", "Quad Kill", "Annihilation", "Six Kills", "Killamanjaro", "Project Octopath Killer"}
	for name, i in want {
		testing.expect_value(t, view.streak_phrase(i + 1), name)
	}
	testing.expect_value(t, view.streak_text(3), "OH BABY A TRIPLE")
	testing.expect_value(t, view.streak_phrase(50), "Half Century Of Hell")
	testing.expect_value(t, view.streak_phrase(51), "Super Takedown")
	testing.expect_value(t, view.streak_phrase(100), "Super Half Century Of Hell")
	testing.expect_value(t, view.streak_phrase(101), "Super Duper Takedown")
	testing.expect_value(t, view.streak_phrase(205), "Super Duper Annihilation")
	for n in 1 ..= 50 {
		testing.expect(t, view.streak_title(n) != "", "every streak to 50 has a title")
	}
	testing.expect_value(t, view.streak_title(50 + 1), view.streak_title(1))
}

@(test)
a_streak_lapses_after_its_window :: proc(t: ^testing.T) {
	testing.expect_value(t, view.streak_after(0, 0, 5), 1)
	testing.expect_value(t, view.streak_after(1, 10, 10 + view.STREAK_WINDOW), 2)
	testing.expect_value(t, view.streak_after(4, 10, 10 + view.STREAK_WINDOW + 1), 1)
}

@(test)
every_streak_has_a_clip :: proc(t: ^testing.T) {
	for n in 1 ..= 160 {
		clips := view.announcer_clips(n, context.temp_allocator)
		testing.expect(t, len(clips) >= 1 && len(clips) <= 2)
	}
	testing.expect_value(t, len(view.announcer_clips(1, context.temp_allocator)), 1)
	testing.expect_value(t, len(view.announcer_clips(51, context.temp_allocator)), 2)
	testing.expect_value(t, view.announcer_clips(101, context.temp_allocator)[0], "super_duper")
	testing.expect_value(t, view.announcer_clips(8, context.temp_allocator)[0], "08")
}

@(test)
the_reverb_leaves_silence_alone_and_rings_after_a_click :: proc(t: ^testing.T) {
	rv := new(view.Reverb)
	defer free(rv)
	quiet := make([]f32, 2000, context.temp_allocator)
	view.reverb_process(rv, quiet, 1)
	for v in quiet {
		testing.expect_value(t, v, 0)
	}
	click := make([]f32, 8000, context.temp_allocator)
	click[0], click[1] = 1, 1
	view.reverb_process(rv, click, 0.8)
	tail: f32
	for v in click[4000:] {
		tail = max(tail, abs(v))
	}
	testing.expect(t, tail > 0.001, "a tail well after the click")
	testing.expect(t, tail < 1, "and it does not run away")
	dry := make([]f32, 400, context.temp_allocator)
	dry[10], dry[11] = 0.5, 0.5
	view.reverb_process(rv, dry, 0)
	testing.expect_value(t, dry[10], 0.5) // no wet, no change
}

@(test)
the_embedded_clips_decode :: proc(t: ^testing.T) {
	for n in 1 ..= 50 {
		for name in view.announcer_clips(n, context.temp_allocator) {
			testing.expect(t, view.announcer_frames(name) > 2000, "a spoken clip")
		}
	}
	testing.expect(t, view.announcer_frames("super") > 2000)
	testing.expect(t, view.announcer_frames("super_duper") > 2000)
	testing.expect_value(t, view.announcer_frames("nope"), 0)
}
