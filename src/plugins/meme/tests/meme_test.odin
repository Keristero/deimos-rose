package meme_tests

// The Meme Mod's hitstop (plugins/meme): how long a hit holds the game, what earns the
// kill cam, and where the zoom looks. Plain numbers: no window, no level.

import "core:testing"

import view "dr:plugins/meme/view"
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
	testing.expect_value(t, view.streak_phrase(151), "Mega Takedown")
	testing.expect_value(t, view.streak_phrase(205), "Ultra Annihilation")
	testing.expect_value(t, view.streak_phrase(2000), "Final Half Century Of Hell")
	testing.expect_value(t, view.streak_phrase(5000), "Final Half Century Of Hell")
	testing.expect_value(t, view.streak_tier(2000), view.STREAK_MAX_TIER)
	for tier in 1 ..= view.STREAK_MAX_TIER {
		testing.expect(t, view.streak_modifier(tier) != "", "every tier to 2000 has a modifier")
	}
	testing.expect_value(t, view.streak_modifier(view.STREAK_MAX_TIER + 1), "")
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
	for tier in 1 ..= view.STREAK_MAX_TIER {
		testing.expect(t, view.announcer_frames(view.streak_modifier_clip(tier)) > 2000, "a spoken modifier")
	}
	testing.expect_value(t, view.announcer_frames("nope"), 0)
}

@(test)
combo_left_drains_and_ends :: proc(t: ^testing.T) {
	testing.expect_value(t, view.combo_left(1, 0, 0, 0), 0) // a lone kill is no combo
	testing.expect_value(t, view.combo_left(3, 10, 10, 0), 1)
	testing.expect(t, abs(view.combo_left(3, 10, 10 + view.STREAK_WINDOW / 2, 0) - 0.5) < 0.001)
	testing.expect_value(t, view.combo_left(3, 10, 10 + view.STREAK_WINDOW, 0), 0)
}

@(test)
style_grades_and_gain :: proc(t: ^testing.T) {
	testing.expect_value(t, view.style_rank(0), 0)
	testing.expect_value(t, view.style_rank(0.5), 3)
	testing.expect_value(t, view.style_rank(1), 7)
	testing.expect(t, abs(view.style_progress(0.325) - 0.5) < 0.001)
	// A tool not used lately earns the most; one spammed, a tenth of it.
	hist: [view.STYLE_HISTORY]i32
	testing.expect(t, abs(view.style_gain(hist, 0, 7) - 0.05) < 0.0001)
	hist = {7, 7, 7, 7, 7, 7}
	testing.expect(t, abs(view.style_gain(hist, 6, 7) - 0.005) < 0.0001)
	testing.expect(t, view.style_gain(hist, 6, 8) > view.style_gain(hist, 6, 7))
	// It drains faster the higher it stands, and a hit taken costs a third.
	testing.expect(t, view.style_drain(1) > view.style_drain(0))
	st := view.Style{gauge = 1}
	view.style_struck(&st)
	testing.expect(t, abs(st.gauge - 0.65) < 0.0001)
	// Spamming one weapon cannot reach the top, mixing four can.
	spam, mix := view.Style{}, view.Style{}
	for i in 0 ..< 600 {
		view.style_step(&spam)
		view.style_step(&mix)
		if i % 10 == 0 {
			view.style_hit(&spam, 1, false, 0)
			view.style_hit(&mix, i32(i / 10 % 4), false, 0)
		}
	}
	testing.expect(t, spam.gauge < mix.gauge)
	testing.expect(t, view.style_rank(spam.gauge) < 4)
}

@(test)
horns_blast_more_and_higher_with_the_streak :: proc(t: ^testing.T) {
	testing.expect_value(t, view.horn_blasts(1), 1)
	testing.expect_value(t, view.horn_blasts(4), 2)
	testing.expect_value(t, view.horn_blasts(9), 3)
	testing.expect(t, view.horn_pitch(9) > view.horn_pitch(1))
	one := view.horn_samples(1, context.temp_allocator)
	three := view.horn_samples(8, context.temp_allocator)
	testing.expect(t, len(three) > len(one))
	peak: f32
	for v in three {
		testing.expect(t, abs(v) <= 1)
		peak = max(peak, abs(v))
	}
	testing.expect(t, peak > 0.5, "loud enough to hear")
}

@(test)
being_struck_takes_a_little_off_a_streak :: proc(t: ^testing.T) {
	testing.expect_value(t, view.streak_struck(0, 100), 100) // no streak, nothing to lose
	now := 100 + view.STREAK_WINDOW / 2
	before := view.combo_left(3, 100, now, 0)
	after := view.combo_left(3, view.streak_struck(3, 100), now, 0)
	testing.expect(t, after < before && after > 0.2, "a hit costs a little, not the whole combo")
}

@(test)
a_bigger_combo_burns_hotter_to_2000 :: proc(t: ^testing.T) {
	testing.expect_value(t, view.flame_heat(0), 0)
	testing.expect_value(t, view.flame_heat(20), 1)
	testing.expect(t, view.flame_heat(21) > 1)
	testing.expect(t, view.flame_heat(500) > view.flame_heat(100))
	testing.expect(t, view.flame_heat(2000) > view.flame_heat(500))
	testing.expect_value(t, view.flame_heat(9999), view.flame_heat(2000))
	testing.expect(t, view.flame_rise(view.flame_heat(2000)) < view.flame_heat(2000))
	testing.expect_value(t, view.flame_rise(0.5), 0.5)
}

@(test)
player_two_has_an_australian_who_gets_angrier :: proc(t: ^testing.T) {
	testing.expect_value(t, view.announcer_of(0), view.Announcer.Husky)
	testing.expect_value(t, view.announcer_of(1), view.Announcer.Aussie)
	testing.expect_value(t, view.rage_stage(1), 0)
	testing.expect_value(t, view.rage_stage(5), 0)
	testing.expect_value(t, view.rage_stage(6), 1)
	testing.expect_value(t, view.rage_stage(100), 3)
	testing.expect_value(t, view.rage_stage(2000), view.RAGE_STAGES - 1)
	testing.expect(t, view.rage_pitch(200) > view.rage_pitch(10))
	testing.expect(t, view.rage_gain(200) > view.rage_gain(10))
	testing.expect_value(t, view.rage_pitch(1), 1)
	// He says the title and then a line for his temper; the husky one does not.
	clips := view.announcer_clips(8, context.temp_allocator, .Aussie)
	testing.expect_value(t, len(clips), 2)
	testing.expect_value(t, clips[0], "08")
	testing.expect_value(t, len(view.announcer_clips(8, context.temp_allocator)), 1)
	// Shouting from stage 3.
	testing.expect_value(t, view.announcer_clips(40, context.temp_allocator, .Aussie)[0], "40_mad")
	testing.expect_value(t, view.announcer_clips(40, context.temp_allocator)[0], "40")
}

@(test)
the_australians_clips_are_all_embedded :: proc(t: ^testing.T) {
	for n in 1 ..= 2000 {
		for name in view.announcer_clips(n, context.temp_allocator, .Aussie) {
			testing.expect(t, view.announcer_frames(name, .Aussie) > 2000, "a spoken clip")
		}
	}
}
