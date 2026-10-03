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

TAKEDOWN_TEXT :: "TAKEDOWN"

@(private = "file")
Cam :: struct {
	on:    bool,
	start: f64,     // the clock, in seconds, when it began
	at:    sim.Vec, // the unit, as it was hit
	side:  bool,    // `at` follows the sideways scroll
	fixed: Maybe(f32), // stand at this point of the cam (the screenshots, shots.odin)
}

@(private = "file") cam: Cam

register :: proc() {
	render.effect_system_register({name = "hitstop", plugin = hitstop.ID, step = step, clear = clear})
	render.post_pass_register({
		name    = "hitstop kill cam",
		plugin  = hitstop.ID,
		after   = {"lighting"},
		enabled = enabled,
		apply   = apply,
	})
}

@(init)
register_step :: proc "contextless" () {
	sim.register_step(.View, "plugins/hitstop/view register", register)
}

// Starts the kill cam on `at`, standing at `progress` of the way through it
// (the screenshots').
cam_hold_at :: proc(at: sim.Vec, progress: f32) {
	staged = Cam{true, 0, at, false, progress}
}

// Kept until the next step, as a level start forgets what is already up.
@(private = "file") staged: Maybe(Cam)

@(private = "file")
clear :: proc() {
	cam = {}
}

// Takes the step's collisions: the longest hold of them, or the kill cam.
@(private = "file")
step :: proc(r: ^render.Renderer, s: ^sim.State, p: ^render.Particles) {
	if c, ok := staged.?; ok {
		cam, staged = c, nil
	}
	if cam.on {
		return
	}
	strength := r.setting[STRENGTH]
	hold := 0
	for ev in s.hits.events[:s.hits.count] {
		if is_takedown(ev) && strength > 0 {
			cam = {true, rl.GetTime(), ev.loc, ev.scrolls_sideways, nil}
			r.hold = TAKEDOWN_STEPS
			return
		}
		hold = max(hold, hold_steps(ev.damage, strength))
	}
	r.hold = max(r.hold, hold)
}

// The kill cam is up while its hold is: the hold ending (or being dropped,
// by a pause or netplay) ends it.
@(private = "file")
enabled :: proc(r: ^render.Renderer) -> bool {
	if cam.on && r.hold <= 0 && cam.fixed == nil {
		cam = {}
	}
	return cam.on
}

@(private = "file")
progress :: proc() -> f32 {
	if at, ok := cam.fixed.?; ok {
		return at
	}
	return clamp(f32((rl.GetTime() - cam.start) * STEP_HZ / TAKEDOWN_STEPS), 0, 1)
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
	rl.DrawTexturePro(src, {view[0], h - view[1] - view[3], view[2], -view[3]}, {field[0], field[1], field[2], field[3]}, {}, 0, rl.WHITE)

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

// TAKEDOWN in the game's own font, centred low in the field, red with a
// black shadow, shaking as it lands.
@(private = "file")
draw_takedown :: proc(r: ^render.Renderer, field: [4]f32, scale: f32, p: f32) {
	width: f32
	for c in TAKEDOWN_TEXT {
		if _, src, ok := render.frame_rect(&r.textures, render.FONT, render.glyph_of(byte(c))); ok {
			width += src.width * scale
		}
	}
	shake := 6 * max(0, 0.32 - p) / 0.12
	x := field[0] + (field[2] - width) / 2 + math.sin(p * 400) * shake
	y := field[1] + field[3] * 0.74 + math.cos(p * 530) * shake
	alpha := u8(255 * (1 - clamp((p - 0.92) / 0.08, 0, 1)))
	for pass in 0 ..< 2 {
		pen := x
		offset := pass == 0 ? 0.04 * scale * 3 : f32(0)
		tint := pass == 0 ? rl.Color{0, 0, 0, alpha} : rl.Color{255, 52, 40, alpha}
		for c in TAKEDOWN_TEXT {
			tex, src, ok := render.frame_rect(&r.textures, render.FONT, render.glyph_of(byte(c)))
			if !ok {
				continue
			}
			rl.SetTextureFilter(tex, .POINT)
			rl.DrawTexturePro(tex, src, {pen + offset, y + offset, src.width * scale, src.height * scale}, {}, 0, tint)
			pen += src.width * scale
		}
	}
}
