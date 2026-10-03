package hitstop_view

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

import "dr:plugins/hitstop"
import "dr:prefs"
import "dr:render"
import "dr:sim"

STRENGTH: prefs.Setting_ID // how long a hit holds, percent of the default

@(private = "file")
Cam :: struct {
	on:    bool,
	start: f64,     // the clock, in seconds, when it began
	at:    sim.Vec, // the unit, as it was hit
	side:  bool,    // `at` follows the sideways scroll
	power: f32,     // shake_power of the blow
	slow:  f32,     // slow_power of the blow
	streak: int,    // the kill streak it announces
	fixed: Maybe(f32), // stand at this point of the cam (the screenshots, shots.odin)
}

@(private = "file") cam: Cam
@(private = "file") driven: bool // the slowdown, sound and reverb are set by the cam

// Each player's kill streak, the step of their last kill, and the step.
@(private = "file") streak: [sim.MAX_PLAYERS]int
@(private = "file") last_kill: [sim.MAX_PLAYERS]int
@(private = "file") steps: int

register :: proc() {
	render.effect_system_register({name = "hitstop", plugin = hitstop.ID, step = step, clear = clear})
	render.post_pass_register({
		name    = "hitstop kill cam",
		plugin  = hitstop.ID,
		after   = {"lighting"},
		enabled = enabled,
		apply   = apply,
		destroy = destroy,
	})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/hitstop/view register", register)
}

@(private = "file")
destroy :: proc() {
	boom_destroy()
	announcer_destroy()
	reverb_destroy()
}

// Starts the kill cam for streak 1 on `at`, standing at `progress` of the
// way through it, at full strength (the screenshots').
cam_hold_at :: proc(at: sim.Vec, progress: f32, streak := 1) {
	staged = Cam{true, 0, at, false, 1, 1, streak, progress}
}

// Kept until the next step, as a level start forgets what is already up.
@(private = "file") staged: Maybe(Cam)

@(private = "file")
clear :: proc() {
	cam = {}
	streak, last_kill, steps = {}, {}, 0
}

// Takes the step's collisions: each kill of an enemy goes on its killer's
// streak and (re)starts the kill cam, which announces it; the rest hold the
// game for the longest of them, unless the cam is on, which has its own
// slow-motion.
@(private = "file")
step :: proc(r: ^render.Renderer, s: ^sim.State, p: ^render.Particles) {
	steps += 1
	if c, ok := staged.?; ok {
		cam, staged = c, nil
	}
	strength := r.setting[STRENGTH]
	hold := 0
	took: Maybe(sim.Hit_Event)
	for ev in s.hits.events[:s.hits.count] {
		if is_takedown(ev) && strength > 0 {
			who := clamp(int(ev.by), 0, sim.MAX_PLAYERS - 1)
			streak[who] = streak_after(streak[who], last_kill[who], steps)
			last_kill[who] = steps
			cam = {true, rl.GetTime(), ev.loc, ev.scrolls_sideways, shake_power(ev.damage), slow_power(ev.damage), streak[who], nil}
			took = ev
			continue
		}
		hold = max(hold, hold_steps(ev.damage, strength))
	}
	if took != nil {
		r.hold = 0
		boom_play(r.textures.sfx_volume)
		announce(cam.streak, r.textures.sfx_volume, 0.85 - 0.25 * cam.slow)
	} else if !cam.on {
		r.hold = max(r.hold, hold)
	}
}

// The kill cam is up for TAKEDOWN_SECONDS. Each frame it also sets the
// game's slowdown, its sound and the reverb for where it has got to, and
// lets go of them when it ends.
@(private = "file")
enabled :: proc(r: ^render.Renderer) -> bool {
	if cam.on && cam.fixed == nil && rl.GetTime() - cam.start >= TAKEDOWN_SECONDS {
		cam = {}
	}
	if cam.on {
		p := progress()
		r.slowdown = 1 - speed_at(p, cam.slow)
		r.textures.audio_slow = audio_slow_at(p, cam.slow)
		reverb_set(reverb_at(p, cam.slow))
		driven = true
	} else if driven {
		r.slowdown, r.textures.audio_slow = 0, 0
		reverb_set(0)
		driven = false
	}
	return cam.on
}

@(private = "file")
progress :: proc() -> f32 {
	if at, ok := cam.fixed.?; ok {
		return at
	}
	return clamp(f32((rl.GetTime() - cam.start) / TAKEDOWN_SECONDS), 0, 1)
}

@(private = "file")
apply :: proc(r: ^render.Renderer, f: ^render.Post_Frame, src: rl.Texture2D) {
	p := progress()
	field := [4]f32{render.VIEW_X * f.scale, 0, render.PLAY_W * f.scale, render.PLAY_H * f.scale}
	x := cam.at.x - (cam.side ? f.side : 0)
	at := [2]f32{(x + render.VIEW_X) * f.scale, (cam.at.y) * f.scale}
	z := zoom_at(p)
	view := zoom_rect(field, at, z)
	// The scene texture is bottom-up: the rows count from its foot.
	h := f32(src.height)
	rl.SetTextureFilter(src, .BILINEAR)
	// Shaken hard: the picture is drawn a little larger than the field, moved
	// and turned about its centre, and the play field's scissor trims the rest.
	shake := shake_at(p, cam.power)
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
// (gold from Super, violet from Super Duper) with a black shadow, shaking as
// it lands; as large as `scale` asks unless that is wider than the field.
@(private = "file")
draw_takedown :: proc(r: ^render.Renderer, field: [4]f32, scale: f32, p: f32) {
	text := streak_text(cam.streak)
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
	colour := [3]rl.Color{{255, 52, 40, alpha}, {255, 200, 40, alpha}, {200, 90, 255, alpha}}[streak_tier(cam.streak)]
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
