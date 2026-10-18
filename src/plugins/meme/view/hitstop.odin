package meme_view

// Hitstop. Each step, the collisions the simulation recorded (sim.Hit_Queue)
// hold the game still for as many steps as their damage earns (rules.odin);
// the main loop does the holding (Renderer.hold), between steps, so the
// simulation never knows. A kill that deals more than three times what the
// unit had left holds longer, and the kill cam zooms the finished frame in
// on the unit with TAKEDOWN over it, as a post pass (render/post.odin) that
// runs after the others and is the only thing that draws while it is up.
//
// Provisional: the lengths, the zoom and the look of the text were picked by
// eye. The held steps are the game's own 30 a second, so on a monitor
// faster than that the kill cam is smooth only because it runs on the clock.

import "core:math"

import rl "vendor:raylib"

import "dr:plugins/meme"
import "dr:render"
import "dr:sim"

@(private)
Cam :: struct {
	on:    bool,
	start: f64,     // the clock, in seconds, when it began
	at:    sim.Vec, // the unit, as it was hit
	side:  bool,    // `at` follows the sideways scroll
	power: f32,     // shake_power of the blow
	slow:  f32,     // slow_power of the blow
	streak: int,    // the kill streak it announces
	who:    int,    // the player who has it
	fixed: Maybe(f32), // stand at this point of the cam (the screenshots, shots.odin)
}

register :: proc() {
	render.effect_system_register({name = "hitstop", plugin = meme.id(), step = step, clear = clear})
	render.post_pass_register({
		name    = "hitstop kill cam",
		plugin  = meme.id(),
		after   = {"lighting"},
		enabled = enabled,
		apply   = apply,
		destroy = destroy,
	})
	render.post_pass_register({
		name    = "hitstop combo",
		plugin  = meme.id(),
		after   = combo_after[:],
		enabled = combo_enabled,
		apply   = combo_apply,
	})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/meme/view register", register)
}

@(private = "file")
destroy :: proc() {
	boom_destroy()
	announcer_destroy()
	horn_destroy()
	reverb_destroy()
}

// Starts the kill cam for streak 1 on `at`, standing at `progress` of the
// way through it, at full strength (the screenshots').
cam_hold_at :: proc(at: sim.Vec, progress: f32, streak := 1) {
	shared.staged = Cam{true, 0, at, false, 1, 1, streak, 0, progress}
}

// Player 1's combo as if `count` kills in, a quarter of its window gone (the
// screenshots'; the cam, as ever, is a separate thing).
combo_hold_at :: proc(count: int) {
	shared.staged_combo = count
}

// Player 1's style gauge at `g` (the screenshots').
style_hold_at :: proc(g: f32) {
	shared.staged_style = g
}

@(private = "file")
clear :: proc() {
	shared.cam = {}
	shared.streak, shared.last_kill, shared.steps, shared.style, shared.reached = {}, {}, 0, {}, {}
}

// Takes the step's collisions: each kill of an enemy goes on its killer's
// streak and (re)starts the kill cam, which announces it; the rest hold the
// game for the longest of them, unless the cam is on, which has its own
// slow-motion.
@(private = "file")
step :: proc(r: ^render.Renderer, s: ^sim.State, p: ^render.Particles) {
	shared.steps += 1
	if c, ok := shared.staged.?; ok {
		shared.cam, shared.staged = c, nil
	}
	if g, ok := shared.staged_style.?; ok {
		shared.style[0].gauge, shared.staged_style = g, nil
	}
	if n, ok := shared.staged_combo.?; ok {
		shared.streak[0], shared.last_kill[0], shared.staged_combo = n, shared.steps - STREAK_WINDOW / 4, nil
	}
	for &st in shared.style {
		style_step(&st)
	}
	shared.ground_live = ground_target_on_screen(s)
	strength := r.setting[shared.strength]
	hold := 0
	took: Maybe(sim.Hit_Event)
	for ev in s.hits.events[:s.hits.count] {
		if ev.player && ev.victim >= 0 && int(ev.victim) < sim.MAX_PLAYERS {
			style_struck(&shared.style[ev.victim])
			shared.last_kill[ev.victim] = streak_struck(shared.streak[ev.victim], shared.last_kill[ev.victim])
		} else if ev.enemy && ev.by >= 0 && int(ev.by) < sim.MAX_PLAYERS && ev.source >= 0 {
			style_hit(&shared.style[ev.by], ev.source, ev.killed, rl.GetTime())
		}
		if is_takedown(ev) && strength > 0 {
			who := clamp(int(ev.by), 0, sim.MAX_PLAYERS - 1)
			shared.streak[who] = streak_after(shared.streak[who], shared.last_kill[who], shared.steps)
			shared.last_kill[who] = shared.steps
			if shared.streak[who] <= shared.reached[who] {
				hold = max(hold, hold_steps(ev.damage, strength)) // seen already: an ordinary hit
				continue
			}
			shared.reached[who] = shared.streak[who]
			shared.cam = {true, rl.GetTime(), ev.loc, ev.scrolls_sideways, shake_power(ev.damage), slow_power(ev.damage), shared.streak[who], who, nil}
			took = ev
			continue
		}
		hold = max(hold, hold_steps(ev.damage, strength))
	}
	if took != nil {
		r.hold = 0
		vol := r.textures.sfx_volume
		boom_play(vol * volume_scale(r.setting, shared.boom_volume))
		announce(shared.cam.streak, vol * volume_scale(r.setting, shared.announcer_volume), announcer_of(shared.cam.who))
		horn_play(shared.cam.streak, vol * volume_scale(r.setting, shared.horn_volume))
	} else if !shared.cam.on {
		r.hold = max(r.hold, hold)
	}
}

// Whether a ground unit that can still be shot is in the play field.
@(private = "file")
ground_target_on_screen :: proc(s: ^sim.State) -> bool {
	side := f32(sim.single(s, sim.Bgnd).side_scroll)
	w, h := f32(sim.view_width(s.defs)), f32(sim.view_height(s.defs))
	walk := sim.walk_entities(s)
	for e in sim.walk_next(&walk) {
		u := &s.defs.units[e.unit]
		if !u.is_ground_based || u.player_projectile || u.harmless_to_players || e.draw_to_terrain || e.appear_delay >= 1 || e.shields <= 0 || u.score <= 0 {
			continue
		}
		x := e.loc.x - (e.scrolls_sideways ? side : 0)
		if x >= 0 && x <= w && e.loc.y >= 0 && e.loc.y <= h {
			return true
		}
	}
	return false
}

// The kill cam is up for TAKEDOWN_SECONDS. Each frame it also sets the
// game's slowdown, its sound and the reverb for where it has got to, and
// lets go of them when it ends.
@(private = "file")
enabled :: proc(r: ^render.Renderer) -> bool {
	if shared.cam.on && shared.cam.fixed == nil && rl.GetTime() - shared.cam.start >= TAKEDOWN_SECONDS {
		shared.cam = {}
	}
	if shared.cam.on {
		p := progress()
		r.slowdown = (1 - speed_at(p, shared.cam.slow)) * intensity(r.setting, shared.slowmo)
		r.textures.audio_slow = audio_slow_at(p, shared.cam.slow) * intensity(r.setting, shared.slowmo)
		reverb_set(reverb_at(p, shared.cam.slow) * intensity(r.setting, shared.reverb))
		shared.driven = true
	} else if shared.driven {
		r.slowdown, r.textures.audio_slow = 0, 0
		reverb_set(0)
		shared.driven = false
	}
	return shared.cam.on
}

@(private = "file")
progress :: proc() -> f32 {
	if at, ok := shared.cam.fixed.?; ok {
		return at
	}
	return clamp(f32((rl.GetTime() - shared.cam.start) / TAKEDOWN_SECONDS), 0, 1)
}

@(private = "file")
apply :: proc(r: ^render.Renderer, f: ^render.Post_Frame, src: rl.Texture2D) {
	p := progress()
	field := [4]f32{render.VIEW_X * f.scale, 0, render.PLAY_W * f.scale, render.PLAY_H * f.scale}
	x := shared.cam.at.x - (shared.cam.side ? f.side : 0)
	at := [2]f32{(x + render.VIEW_X) * f.scale, (shared.cam.at.y) * f.scale}
	z := shared.ground_live ? 1 : 1 + (zoom_at(p) - 1) * intensity(r.setting, shared.zoom_amount)
	view := zoom_rect(field, at, z)
	// The scene texture is bottom-up: the rows count from its foot.
	h := f32(src.height)
	rl.SetTextureFilter(src, .BILINEAR)
	// Shaken hard: the picture is drawn a little larger than the field, moved
	// and turned about its centre, and the play field's scissor trims the rest.
	shake := shared.ground_live ? 0 : shake_at(p, shared.cam.power) * intensity(r.setting, shared.shake) // no shaking larger or turned while there is a fight
	t := f32(rl.GetTime())
	jx, jy := math.sin(t * 91) + math.sin(t * 57 + 1), math.cos(t * 83) + math.cos(t * 61 + 2)
	roll := math.sin(t * 67) * 0.045 * shake
	reach := 1 + 0.2 * shake
	dw, dh := field[2] * reach, field[3] * reach
	centre := rl.Vector2{field[0] + field[2] / 2 + jx * 0.5 * SHAKE_PX * f.scale * shake, field[1] + field[3] / 2 + jy * 0.5 * SHAKE_PX * f.scale * shake}
	rl.DrawTexturePro(src, {view[0], h - view[1] - view[3], view[2], -view[3]}, {centre.x, centre.y, dw, dh}, {dw / 2, dh / 2}, math.to_degrees(roll), rl.WHITE)

	// Bars and a dimming of the rest, as the shot sets up.
	frame := frame_at(p)
	bar := field[3] * 0.11 * frame
	rl.DrawRectangleRec({field[0], field[1], field[2], bar}, rl.Color{0, 0, 0, 255})
	rl.DrawRectangleRec({field[0], field[1] + field[3] - bar, field[2], bar}, rl.Color{0, 0, 0, 255})
	rl.DrawRectangleGradientV(i32(field[0]), i32(field[1] + bar), i32(field[2]), i32(field[3] * 0.18), rl.Color{0, 0, 0, u8(150 * frame)}, rl.Color{0, 0, 0, 0})
	rl.DrawRectangleGradientV(i32(field[0]), i32(field[1] + field[3] - bar - field[3] * 0.18), i32(field[2]), i32(field[3] * 0.18), rl.Color{0, 0, 0, 0}, rl.Color{0, 0, 0, u8(150 * frame)})

	if k := text_scale_at(p); k > 0 {
		draw_takedown(r, field, k * f.scale * 3, p)
	}
}

// The streak's name in the game's own font, centred low in the field, red
// (gold from Super, violet from Super Duper, then round the colour wheel) with a black shadow, shaking as
// it lands; as large as `scale` asks unless that is wider than the field.
@(private = "file")
draw_takedown :: proc(r: ^render.Renderer, field: [4]f32, scale: f32, p: f32) {
	text := streak_text(shared.cam.streak)
	width: f32
	for c in transmute([]u8)text {
		if _, src, ok := render.frame_rect(&r.textures, render.FONT, render.glyph_of(c)); ok {
			width += src.width
		}
	}
	fit := min(scale, field[2] * 0.94 / max(width, 1))
	width *= fit
	shake := 6 * max(0, 0.32 - p) / 0.12
	x := field[0] + (field[2] - width) / 2 + math.sin(p * 400) * shake
	y := field[1] + field[3] * 0.74 + math.cos(p * 530) * shake
	alpha := u8(255 * (1 - clamp((p - 0.92) / 0.08, 0, 1)))
	colour := tier_colour(streak_tier(shared.cam.streak), alpha)
	for pass in 0 ..< 2 {
		pen := x
		offset := pass == 0 ? 0.12 * fit : f32(0)
		tint := pass == 0 ? rl.Color{0, 0, 0, alpha} : colour
		for c in transmute([]u8)text {
			tex, src, ok := render.frame_rect(&r.textures, render.FONT, render.glyph_of(c))
			if !ok {
				continue
			}
			rl.SetTextureFilter(tex, .POINT)
			rl.DrawTexturePro(tex, src, {pen + offset, y + offset, src.width * fit, src.height * fit}, {}, 0, tint)
			pen += src.width * fit
		}
	}
}

// The colour of a streak's name: red, gold, violet, then a hue for each tier
// further round the wheel.
tier_colour :: proc(tier: int, alpha: u8) -> rl.Color {
	switch tier {
	case 0:
		return {255, 52, 40, alpha}
	case 1:
		return {255, 200, 40, alpha}
	case 2:
		return {200, 90, 255, alpha}
	}
	c := rl.ColorFromHSV(f32(tier * 47 % 360), 0.75, 1)
	c.a = alpha
	return c
}
